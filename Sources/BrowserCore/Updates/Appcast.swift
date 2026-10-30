#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The update feed (docs/UPDATES.md §2): one static file, the list of releases inside an envelope
/// signed with Ed25519. The app reads nothing of the list before the signature checks with a key it
/// carries (`PBUpdatePublicKeys` in its `Info.plist`).
///
/// ```json
/// {"format": 1, "keyID": "<16 hex>", "payload": "<base64 of the appcast's JSON>", "signature": "<base64 Ed25519 of those bytes>"}
/// ```
public struct AppcastEnvelope: Codable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    /// Which key signed `payload` (`UpdateKeys.keyID(of:)`).
    public var keyID: String
    /// The appcast's JSON: exactly the bytes that were signed.
    public var payload: Data
    /// Ed25519 over `payload`.
    public var signature: Data
}

/// The releases an appcast lists.
public struct Appcast: Codable, Equatable, Sendable {
    /// When the release tooling made it. An appcast older than the newest one the app accepted is
    /// refused: a mirror or a cache replaying an old list, validly signed, cannot hold an update
    /// back for good, nor offer what was already superseded.
    public var generatedAt: Date
    public var items: [AppcastItem]

    public init(generatedAt: Date, items: [AppcastItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }
}

/// One release: a zip of the signed app.
public struct AppcastItem: Codable, Equatable, Sendable {
    /// `CFBundleShortVersionString`: what is shown.
    public var version: String
    /// `CFBundleVersion`: what is compared (`BuildVersion`).
    public var build: String
    /// The oldest macOS it runs on (`LSMinimumSystemVersion`).
    public var minimumSystemVersion: String
    /// Where the zip is: https only.
    public var url: URL
    /// The zip's size in bytes, and its SHA-256 (lowercase hex).
    public var length: Int
    public var sha256: String
    /// The key that signed the zip, and the Ed25519 signature of the zip's bytes.
    public var keyID: String
    public var edSignature: Data
    public var publishedAt: Date
    /// The release notes: plain text, shown as text (never rendered as a page).
    public var notes: String

    public init(version: String, build: String, minimumSystemVersion: String, url: URL, length: Int, sha256: String,
                keyID: String, edSignature: Data, publishedAt: Date, notes: String) {
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.url = url
        self.length = length
        self.sha256 = sha256
        self.keyID = keyID
        self.edSignature = edSignature
        self.publishedAt = publishedAt
        self.notes = notes
    }
}

/// Why an update was not taken. Each is a refusal: nothing is installed after any of them.
public enum UpdateError: Error, Equatable, CustomStringConvertible {
    /// Not an appcast envelope at all.
    case notAnAppcast
    /// An appcast a newer version of the app reads: this one cannot judge it.
    case newerAppcastFormat(Int)
    /// Signed with a key this app does not carry.
    case unknownKey(String)
    /// The signature of the appcast (`what` = "appcast") or of an archive does not check.
    case badSignature(String)
    /// Older than the newest appcast accepted before.
    case staleAppcast(generatedAt: Date, newestAccepted: Date)
    /// An item that cannot be judged: not https, not a build number, not a SHA-256…
    case invalidItem(String)
    /// The release is not newer than the running build: never installed (no downgrade).
    case notNewer(build: String, running: String)
    /// The release needs a newer macOS.
    case needsNewerSystem(String)
    /// The downloaded archive is not the one the item describes.
    case archiveLength(expected: Int, found: Int)
    case archiveHash

    public var description: String {
        switch self {
        case .notAnAppcast: return "not an update feed"
        case .newerAppcastFormat(let format): return "the update feed has format \(format), which a newer version of the app reads"
        case .unknownKey(let id): return "signed with a key this app does not carry (\(id))"
        case .badSignature(let what): return "the signature of the \(what) does not check"
        case .staleAppcast(let generated, let newest):
            return "the update feed is older (\(generated)) than the newest one accepted (\(newest))"
        case .invalidItem(let detail): return "a release in the update feed is invalid: \(detail)"
        case .notNewer(let build, let running): return "build \(build) is not newer than the running build \(running)"
        case .needsNewerSystem(let minimum): return "the update needs macOS \(minimum) or newer"
        case .archiveLength(let expected, let found): return "the download is \(found) bytes, the release says \(expected)"
        case .archiveHash: return "the download's SHA-256 is not the release's"
        }
    }
}

/// The keys an app trusts for updates: key id → raw Ed25519 public key (32 bytes).
public enum UpdateKeys {
    /// A key's id: the first 8 bytes of the SHA-256 of its raw public key, in hex.
    public static func keyID(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The keys an `Info.plist` names (`PBUpdatePublicKeys`: key id → base64). An entry whose id is
    /// not its key's, or that is not a key, is left out.
    public static func fromInfoPlist(_ value: Any?) -> [String: Data] {
        guard let entries = value as? [String: String] else { return [:] }
        var keys: [String: Data] = [:]
        for (id, text) in entries {
            guard let raw = Data(base64Encoded: text), raw.count == 32, keyID(of: raw) == id,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else { continue }
            keys[id] = raw
        }
        return keys
    }
}

/// Checking an update: the appcast, which release to take, and the downloaded archive.
public enum UpdateVerifier {
    /// The appcast in `data`, once the envelope's signature checks with the key it names — one of
    /// `keys`. Nothing of the payload is decoded before; every item is then checked to be one that
    /// can be judged (`invalidItem` refuses the whole appcast otherwise).
    public static func appcast(from data: Data, keys: [String: Data]) throws -> Appcast {
        guard let format = DocumentFormat.declared(in: data) else { throw UpdateError.notAnAppcast }
        guard format <= AppcastEnvelope.currentFormat else { throw UpdateError.newerAppcastFormat(format) }
        guard let envelope = try? JSONCoding.decoder.decode(AppcastEnvelope.self, from: data),
              envelope.format == AppcastEnvelope.currentFormat else { throw UpdateError.notAnAppcast }
        guard let raw = keys[envelope.keyID] else { throw UpdateError.unknownKey(envelope.keyID) }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw UpdateError.badSignature("appcast")
        }
        let appcast: Appcast
        do {
            appcast = try JSONCoding.decoder.decode(Appcast.self, from: envelope.payload)
        } catch {
            throw UpdateError.notAnAppcast
        }
        for item in appcast.items { try check(item) }
        return appcast
    }

    /// Refuses an appcast older than the newest one accepted before (`newestAccepted`); the same one
    /// again, or a newer one, passes.
    public static func checkFreshness(_ appcast: Appcast, newestAccepted: Date?) throws {
        if let newestAccepted, appcast.generatedAt < newestAccepted {
            throw UpdateError.staleAppcast(generatedAt: appcast.generatedAt, newestAccepted: newestAccepted)
        }
    }

    /// The release to offer: the newest whose build is newer than `running`, that runs on `system`,
    /// and whose archive was signed with one of `keys`. Nil when there is none: an older build, or
    /// the same, is never offered.
    public static func update(in appcast: Appcast, running: BuildVersion, system: BuildVersion,
                              keys: [String: Data]) -> AppcastItem? {
        appcast.items
            .compactMap { item -> (item: AppcastItem, build: BuildVersion)? in
                guard (try? checkInstallable(item, running: running, system: system, keys: keys)) != nil,
                      let build = BuildVersion(item.build) else { return nil }
                return (item, build)
            }
            .max { $0.build < $1.build }?.item
    }

    /// Throws unless `item` may be installed over `running` on `system` (checked again right before
    /// an install, whatever was decided when it was offered).
    public static func checkInstallable(_ item: AppcastItem, running: BuildVersion, system: BuildVersion,
                                        keys: [String: Data]) throws {
        try check(item)
        guard let build = BuildVersion(item.build), build > running else {
            throw UpdateError.notNewer(build: item.build, running: running.description)
        }
        guard let minimum = BuildVersion(item.minimumSystemVersion), minimum <= system else {
            throw UpdateError.needsNewerSystem(item.minimumSystemVersion)
        }
        guard keys[item.keyID] != nil else { throw UpdateError.unknownKey(item.keyID) }
    }

    /// The archive at `url` is the one `item` describes: its length, its SHA-256, and the Ed25519
    /// signature of its bytes with the item's key — one of `keys`. Read memory-mapped.
    public static func checkArchive(at url: URL, item: AppcastItem, keys: [String: Data]) throws {
        try check(item)
        guard let raw = keys[item.keyID] else { throw UpdateError.unknownKey(item.keyID) }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count == item.length else { throw UpdateError.archiveLength(expected: item.length, found: data.count) }
        guard hex(SHA256.hash(data: data)) == item.sha256 else { throw UpdateError.archiveHash }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              key.isValidSignature(item.edSignature, for: data) else {
            throw UpdateError.badSignature("archive")
        }
    }

    /// An item this app can judge at all.
    static func check(_ item: AppcastItem) throws {
        guard item.url.scheme?.lowercased() == "https", let host = item.url.host, !host.isEmpty else {
            throw UpdateError.invalidItem("\(item.build): not an https URL")
        }
        guard BuildVersion(item.build) != nil else { throw UpdateError.invalidItem("\(item.build): not a build number") }
        guard BuildVersion(item.minimumSystemVersion) != nil else {
            throw UpdateError.invalidItem("\(item.build): minimum system \(item.minimumSystemVersion)")
        }
        guard item.length > 0 else { throw UpdateError.invalidItem("\(item.build): length \(item.length)") }
        guard item.sha256.count == 64, item.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw UpdateError.invalidItem("\(item.build): not a SHA-256")
        }
        guard item.edSignature.count == 64 else { throw UpdateError.invalidItem("\(item.build): not an Ed25519 signature") }
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Making an update feed: what `scripts/release.sh` does through `pbupdate`, and the tests.
public enum UpdateSigner {
    /// A new Ed25519 key: its raw private and public representations.
    public static func newKey() -> (privateKey: Data, publicKey: Data) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }

    public static func publicKey(of privateKey: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation
    }

    /// The release of the zip at `archive`, signed with `privateKey`.
    public static func item(archive: URL, version: String, build: String, minimumSystemVersion: String, url: URL,
                            notes: String, publishedAt: Date, privateKey: Data) throws -> AppcastItem {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let item = AppcastItem(version: version, build: build, minimumSystemVersion: minimumSystemVersion, url: url,
                               length: data.count, sha256: UpdateVerifier.hex(SHA256.hash(data: data)),
                               keyID: UpdateKeys.keyID(of: key.publicKey.rawRepresentation),
                               edSignature: try key.signature(for: data), publishedAt: publishedAt, notes: notes)
        try UpdateVerifier.check(item)
        return item
    }

    /// The signed envelope of `appcast`, as the file to publish.
    public static func envelope(of appcast: Appcast, privateKey: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        for item in appcast.items { try UpdateVerifier.check(item) }
        let payload = try JSONCoding.encoder.encode(appcast)
        let envelope = AppcastEnvelope(format: AppcastEnvelope.currentFormat,
                                       keyID: UpdateKeys.keyID(of: key.publicKey.rawRepresentation),
                                       payload: payload, signature: try key.signature(for: payload))
        return try JSONCoding.encoder.encode(envelope)
    }
}
