import Foundation
import MachO
import Security

/// The executable a profile's process is started from — and every other process of this app's that
/// runs Safari's code or stands in for a profile: `Contents/MacOS/LumenProfile`, a copy of the app's
/// own executable that `scripts/build-app.sh` signs without the entitlements that give a process a
/// keychain.
///
/// WHY. A process is given the data-protection keychain by its code signature alone: an application
/// identifier, a keychain access group or an app group in its entitlements makes it a member of that
/// group, and the keychain shows it every item the group holds (Apple's TN3137). A build with the
/// network guard (`NE=1`) must carry `com.apple.application-identifier` and the app group
/// `<TEAM_ID>.io.lumenbrowser.Lumen`: the system extension and its filter are the app's, and their
/// provisioning profiles say so. A profile's process used to be that same executable, so Safari's
/// code in it kept its "Safari Defaults" in that group, and every profile could read every other
/// profile's (docs/IDENTITY.md, "The keychain"). Started from LumenProfile it has no keychain at
/// all: the system refuses it (`errSecMissingEntitlement`), as it refuses a build without the guard.
///
/// FAIL-CLOSED. In the app's bundle the profile's executable must be there and its signature must
/// carry none of `keychainEntitlements`, read from the file before every start; otherwise nothing is
/// started from it, and a profile does not open. Outside a bundle (`swift run`, the tests) there is
/// only the one executable, and nothing signs it with any of them.
enum ProfileExecutable {
    /// Its name in `Contents/MacOS`, beside the app's own `Lumen` (`scripts/build-app.sh`).
    static let name = "LumenProfile"

    /// The entitlements that make a process a member of a keychain access group — any of them opens
    /// the data-protection keychain to it, shared with every process that carries the same — and the
    /// team's identifier that comes with the application identifier.
    static let keychainEntitlements = [
        "com.apple.application-identifier",
        "keychain-access-groups",
        "com.apple.security.application-groups",
        "com.apple.developer.team-identifier",
    ]

    /// What the person is told: this copy of the app is not the one that was built (the log has
    /// `description`, which names the file and what is wrong with it).
    enum Refusal: LocalizedError, CustomStringConvertible {
        /// No profile's executable in the bundle (a copy of the app put together by hand).
        case missing(String)
        /// Its signature could not be read.
        case unreadable(String, OSStatus)
        /// Its signature carries entitlements that give a keychain.
        case carries([String])

        var description: String {
            switch self {
            case .missing(let path): return "the profile's executable is missing (\(path))"
            case .unreadable(let path, let status): return "the signature of the profile's executable cannot be read (\(path), \(status))"
            case .carries(let keys): return "the profile's executable is signed with a keychain of its own (\(keys.joined(separator: ", ")))"
            }
        }

        var errorDescription: String? { L("profile.process.executableRefused") }
    }

    /// Where a profile's process, and any process that runs Safari's code for this app, is started
    /// from. Throws rather than ever falling back to the app's own executable.
    static func url() throws -> URL {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            guard let own = Bundle.main.executableURL else { throw Refusal.missing("this process's executable") }
            return own
        }
        let url = bundle.appendingPathComponent("Contents/MacOS/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw Refusal.missing(url.path) }
        let carried = try signedKeychainEntitlements(of: url)
        guard carried.isEmpty else { throw Refusal.carries(carried) }
        return url
    }

    /// Of `keychainEntitlements`, those the signature of the executable at `url` carries.
    static func signedKeychainEntitlements(of url: URL) throws -> [String] {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Refusal.unreadable(url.path, status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let dictionary = information as? [String: Any] else {
            throw Refusal.unreadable(url.path, status)
        }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return keychainEntitlements.filter { entitlements[$0] != nil }
    }

    /// The file this process runs from — not the bundle's `CFBundleExecutable`, which is the app's own
    /// even in a process started from LumenProfile. A process that starts itself again (with a home
    /// of its own) starts this file, never the app's.
    static func ownPath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
}

/// One look at the data-protection keychain, from inside a process: which of the entitlements that
/// give one this process holds — as the kernel has them, not as a file says — and what the keychain
/// lets it do under a service of the check's own. The self-test and the release check ask it of a
/// profile's process (`ProfileCommand.checkKeychain`), of a process of the app's own executable — a
/// profile as it was started before LumenProfile (`--keychain-probe`) — and of the app itself.
struct KeychainProbe: Codable, Equatable {
    /// The check's own service: items of no one else's.
    var service: String
    /// An item to add under the service, with this account; nil adds none.
    var add: String?
    /// Afterwards, remove every item of the service this process can see.
    var removeAfter = false
}

struct KeychainReport: Codable, Equatable {
    /// Of `ProfileExecutable.keychainEntitlements`, those this process holds; nil when the kernel's
    /// answer could not be had at all.
    var held: [String]?
    /// Whether this process holds the camera entitlement every build of the app gives every one of
    /// its executables: the reader's own control — a reader that cannot see that one cannot say
    /// that the others are not there.
    var readerSawItsControl = false
    /// What adding the item answered (`OSStatus`), if one was to be added.
    var added: Int32?
    /// What looking for the service's items answered, and the accounts of the items it was shown.
    var found: Int32 = 0
    var seen: [String] = []
    /// What removing them answered, if asked.
    var removed: Int32?

    var heldDescription: String {
        guard let held else { return "could not be read" }
        return held.isEmpty ? "none" : held.joined(separator: ", ")
    }
}

enum KeychainCheck {
    /// Every build of the app signs every executable with it (Resources/*.entitlements).
    static let controlEntitlement = "com.apple.security.device.camera"

    static func run(_ probe: KeychainProbe) -> KeychainReport {
        var report = KeychainReport()
        if let task = SecTaskCreateFromSelf(nil) {
            report.held = ProfileExecutable.keychainEntitlements.filter { SecTaskCopyValueForEntitlement(task, $0 as CFString, nil) != nil }
            report.readerSawItsControl = SecTaskCopyValueForEntitlement(task, controlEntitlement as CFString, nil) != nil
        }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: probe.service,
                                   kSecUseDataProtectionKeychain as String: true]
        if let account = probe.add {
            var item = base
            item[kSecAttrAccount as String] = account
            item[kSecValueData as String] = Data("lumen keychain check".utf8)
            report.added = SecItemAdd(item as CFDictionary, nil)
        }
        var query = base
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        report.found = SecItemCopyMatching(query as CFDictionary, &result)
        report.seen = ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        if probe.removeAfter {
            report.removed = SecItemDelete(base as CFDictionary)
        }
        return report
    }

    /// `--keychain-probe <service> [--add <account>] [--remove]`: `run` in this process, its report
    /// printed as one line of JSON after `KEYCHAIN-PROBE `.
    static func runFromCommandLine(arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: "--keychain-probe"), arguments.indices.contains(index + 1) else {
            print("KEYCHAIN-PROBE usage: --keychain-probe <service> [--add <account>] [--remove]")
            exit(64)
        }
        var probe = KeychainProbe(service: arguments[index + 1])
        if let add = arguments.firstIndex(of: "--add"), arguments.indices.contains(add + 1) { probe.add = arguments[add + 1] }
        probe.removeAfter = arguments.contains("--remove")
        let report = run(probe)
        guard let data = try? JSONEncoder().encode(report), let line = String(data: data, encoding: .utf8) else { exit(1) }
        print("KEYCHAIN-PROBE \(line)")
        exit(0)
    }

    /// What a `--keychain-probe` run of the executable at `executable` printed, or nil.
    static func probe(_ executable: URL, _ probe: KeychainProbe) async -> KeychainReport? {
        var arguments = ["--keychain-probe", probe.service]
        if let account = probe.add { arguments += ["--add", account] }
        if probe.removeAfter { arguments.append("--remove") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let output: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
        let text = String(decoding: output, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("KEYCHAIN-PROBE {") }) else { return nil }
        return try? JSONDecoder().decode(KeychainReport.self, from: Data(line.dropFirst("KEYCHAIN-PROBE ".count).utf8))
    }

    /// `errSecMissingEntitlement`: the keychain's word for a process none of whose entitlements gives
    /// it a keychain access group.
    static let missingEntitlement: Int32 = -34018
}
