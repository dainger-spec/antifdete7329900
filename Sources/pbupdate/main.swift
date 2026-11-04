import BrowserCore
import Foundation

// pbupdate — makes and checks the update feed (docs/UPDATES.md §2, §6) with the code the app checks
// it with (BrowserCore's UpdateVerifier). scripts/release.sh runs it; it builds on macOS and Linux.

let usage = """
    usage:
      pbupdate keygen PRIVATE_KEY_FILE
          a new Ed25519 key: the private key into PRIVATE_KEY_FILE (base64, mode 0600; an existing
          file is never written over); prints "<key id> <public key, base64>" for PBUpdatePublicKeys
      pbupdate public-key PRIVATE_KEY_FILE
          prints "<key id> <public key, base64>"
      pbupdate item --key PRIVATE_KEY_FILE --archive ZIP --version V --build B --minimum-system M
                    --url HTTPS_URL [--notes-file FILE] [--published-at ISO8601]
          prints the release of ZIP, signed, as JSON
      pbupdate appcast --key PRIVATE_KEY_FILE --out FILE [--previous APPCAST [--public-key ID=BASE64...]] ITEM_FILE...
          writes the signed appcast of the releases in ITEM_FILEs and of a previous appcast (checked
          with this key, or the keys given), the newest first; a build listed twice is taken once
      pbupdate verify --appcast FILE --public-key ID=BASE64... [--archive ZIP --build B]
          checks the appcast's signature, and a downloaded ZIP against the release with build B
    """

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The arguments after the command: `--name value` options (repeatable) and plain operands.
struct Arguments {
    var options: [String: [String]] = [:]
    var operands: [String] = []

    init(_ arguments: ArraySlice<String>) throws {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument.hasPrefix("--") {
                guard let value = rest.popFirst() else { throw Failure("\(argument) needs a value") }
                options[String(argument.dropFirst(2)), default: []].append(value)
            } else {
                operands.append(argument)
            }
        }
    }

    func one(_ name: String) throws -> String {
        guard let values = options[name], values.count == 1 else { throw Failure("--\(name) is needed, once") }
        return values[0]
    }

    func optional(_ name: String) -> String? { options[name]?.last }
}

func readPrivateKey(_ path: String) throws -> Data {
    let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), raw.count == 32 else { throw Failure("\(path) holds no Ed25519 private key") }
    return raw
}

/// The `--public-key ID=BASE64` options, each checked to be the key its id names.
func publicKeys(_ arguments: Arguments) throws -> [String: Data] {
    var keys: [String: Data] = [:]
    for entry in arguments.options["public-key"] ?? [] {
        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let raw = Data(base64Encoded: parts[1]), UpdateKeys.keyID(of: raw) == parts[0] else {
            throw Failure("--public-key \(entry): not ID=BASE64 of that key")
        }
        keys[parts[0]] = raw
    }
    return keys
}

func keyLine(_ publicKey: Data) -> String {
    "\(UpdateKeys.keyID(of: publicKey)) \(publicKey.base64EncodedString())"
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

func run(_ command: String, _ arguments: Arguments) throws {
    switch command {
    case "keygen":
        guard let path = arguments.operands.first, arguments.operands.count == 1 else { throw Failure(usage) }
        guard !FileManager.default.fileExists(atPath: path) else { throw Failure("\(path) exists; not written over") }
        let key = UpdateSigner.newKey()
        guard FileManager.default.createFile(atPath: path, contents: Data((key.privateKey.base64EncodedString() + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure("cannot write \(path)")
        }
        print(keyLine(key.publicKey))

    case "public-key":
        guard let path = arguments.operands.first, arguments.operands.count == 1 else { throw Failure(usage) }
        print(keyLine(try UpdateSigner.publicKey(of: readPrivateKey(path))))

    case "item":
        guard let url = URL(string: try arguments.one("url")) else { throw Failure("--url is not a URL") }
        var publishedAt = Date()
        if let text = arguments.optional("published-at") {
            guard let date = ISO8601DateFormatter().date(from: text) else { throw Failure("--published-at is not ISO 8601") }
            publishedAt = date
        }
        let notes = try arguments.optional("notes-file").map { try String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let item = try UpdateSigner.item(archive: URL(fileURLWithPath: arguments.one("archive")), version: arguments.one("version"),
                                         build: arguments.one("build"), minimumSystemVersion: arguments.one("minimum-system"),
                                         url: url, notes: notes, publishedAt: publishedAt,
                                         privateKey: readPrivateKey(arguments.one("key")))
        print(String(decoding: try encoder.encode(item), as: UTF8.self))

    case "appcast":
        let privateKey = try readPrivateKey(arguments.one("key"))
        let publicKey = try UpdateSigner.publicKey(of: privateKey)
        var items = try arguments.operands.map { try decoder.decode(AppcastItem.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
        if let previous = arguments.optional("previous") {
            // Checked with this key, or a key it replaces (--public-key).
            var keys = try publicKeys(arguments)
            keys[UpdateKeys.keyID(of: publicKey)] = publicKey
            let old = try UpdateVerifier.appcast(from: Data(contentsOf: URL(fileURLWithPath: previous)), keys: keys)
            let builds = items.map { BuildVersion($0.build) }
            items += old.items.filter { !builds.contains(BuildVersion($0.build)) }
        }
        let newestFirst = try items.map { item -> (item: AppcastItem, build: BuildVersion) in
            guard let build = BuildVersion(item.build) else { throw Failure("\(item.build) is not a build number") }
            return (item, build)
        }.sorted { $0.build > $1.build }.map(\.item)
        let envelope = try UpdateSigner.envelope(of: Appcast(generatedAt: Date(), items: newestFirst), privateKey: privateKey)
        try envelope.write(to: URL(fileURLWithPath: arguments.one("out")), options: .atomic)
        print("appcast: \(newestFirst.count) release(s), signed with \(UpdateKeys.keyID(of: publicKey))")

    case "verify":
        let keys = try publicKeys(arguments)
        let appcast = try UpdateVerifier.appcast(from: Data(contentsOf: URL(fileURLWithPath: arguments.one("appcast"))), keys: keys)
        print("appcast: signature checks; generated \(appcast.generatedAt); builds \(appcast.items.map(\.build).joined(separator: ", "))")
        if let archive = arguments.optional("archive") {
            let build = try arguments.one("build")
            guard let item = appcast.items.first(where: { $0.build == build }) else { throw Failure("no release with build \(build)") }
            try UpdateVerifier.checkArchive(at: URL(fileURLWithPath: archive), item: item, keys: keys)
            print("archive: length, SHA-256 and signature check for build \(build)")
        }

    default:
        throw Failure(usage)
    }
}

let commandLine = CommandLine.arguments
guard commandLine.count >= 2 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
do {
    try run(commandLine[1], Arguments(commandLine.dropFirst(2)))
} catch {
    FileHandle.standardError.write(Data("pbupdate: \(error)\n".utf8))
    exit(1)
}
