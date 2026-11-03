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

/// One look at the keychains, from inside a process: which of the entitlements that give one this
/// process holds — as the kernel has them, not as a file says — whether it can reach securityd at all,
/// and what each keychain lets it do under a service of the check's own: the data-protection keychain
/// (opened by an application identifier, an access group or an app group) and the account's login
/// keychain (the file-based one, open to any process of the account that securityd answers). The
/// self-test and the release check ask it of a profile's process (`ProfileCommand.checkKeychain`), of
/// processes of the profile's executable and of the app's own outside a profile's sandbox
/// (`--keychain-probe`), and of the app itself.
struct KeychainProbe: Codable, Equatable {
    /// The check's own service: items of no one else's.
    var service: String
    /// An item to add under the service, with this account, in each keychain; nil adds none.
    var add: String?
    /// Afterwards, the items of these accounts to remove. Each process removes only what it kept: an
    /// item of the login keychain is tied to the signature that made it, and removing another's
    /// could ask the person.
    var remove: [String] = []
}

struct KeychainReport: Codable, Equatable {
    /// Of `ProfileExecutable.keychainEntitlements`, those this process holds; nil when the kernel's
    /// answer could not be had at all.
    var held: [String]?
    /// Whether this process holds the camera entitlement every build of the app gives every one of
    /// its executables: the reader's own control — a reader that cannot see that one cannot say
    /// that the others are not there.
    var readerSawItsControl = false
    /// The data-protection keychain: what adding the item answered (`OSStatus`), if one was to be
    /// added; what looking for the service's items answered, and the accounts of those shown; what
    /// removing answered, if asked.
    var added: Int32?
    var found: Int32 = 0
    var seen: [String] = []
    var removed: Int32?
    /// The same in the account's login keychain.
    var loginAdded: Int32?
    var loginFound: Int32 = 0
    var loginSeen: [String] = []
    var loginRemoved: Int32?
    /// Each of securityd's services (`KeychainCheck.securitydServices`) with what looking it up
    /// answered in this process: 0 reached it, anything else did not (1100: the sandbox refused it).
    var lookups: [String: Int32] = [:]

    var heldDescription: String {
        guard let held else { return "could not be read" }
        return held.isEmpty ? "none" : held.joined(separator: ", ")
    }

    /// securityd's services this process reached.
    var reached: [String] { lookups.filter { $0.value == 0 }.map(\.key).sorted() }

    var lookupsDescription: String {
        lookups.keys.sorted().map { name in
            let answer = lookups[name] ?? -1
            return answer == 0 ? "\(name) reached" : "\(name) refused (\(answer))"
        }.joined(separator: ", ")
    }
}

enum KeychainCheck {
    /// Every build of the app signs every executable with it (Resources/*.entitlements).
    static let controlEntitlement = "com.apple.security.device.camera"

    /// securityd's services: the one that serves the account's login keychain, and the XPC one of
    /// the data-protection keychain (`secd`). A profile's process is refused every service of
    /// securityd's by its sandbox (`ProfileNetworkGuard.closeTheProcess`); these two are the ones a
    /// keychain call asks for, looked up to say whether the refusal holds.
    static let securitydServices = ["com.apple.SecurityServer", "com.apple.securityd.xpc"]

    /// `step` is told each step before it is taken (a process asked from outside says them as it
    /// goes: one that stops answering has said where).
    static func run(_ probe: KeychainProbe, step: ((String) -> Void)? = nil) -> KeychainReport {
        var report = KeychainReport()
        step?("entitlements")
        if let task = SecTaskCreateFromSelf(nil) {
            report.held = ProfileExecutable.keychainEntitlements.filter { SecTaskCopyValueForEntitlement(task, $0 as CFString, nil) != nil }
            report.readerSawItsControl = SecTaskCopyValueForEntitlement(task, controlEntitlement as CFString, nil) != nil
        }
        step?("securityd's services looked up")
        for name in securitydServices { report.lookups[name] = lookUp(name) }
        let dataProtection = items(dataProtection: true, probe, step: step)
        report.added = dataProtection.added
        report.found = dataProtection.found
        report.seen = dataProtection.seen
        report.removed = dataProtection.removed
        let login = items(dataProtection: false, probe, step: step)
        report.loginAdded = login.added
        report.loginFound = login.found
        report.loginSeen = login.seen
        report.loginRemoved = login.removed
        return report
    }

    /// Adds, looks for and removes the probe's items in one keychain. Never a dialog: what would ask
    /// the person answers with an error instead; only attributes are read, never a secret.
    ///
    /// The login keychain is the account's, opened by its path, as any process of the account can
    /// open it — never "the default keychain": in a profile's process, whose home is its own and
    /// holds none, there is no default one, and asking for it left the process waiting on the
    /// system's dialog (CI run 656, both macOS). What can reach the account's keychain is what the
    /// check is about.
    private static func items(dataProtection: Bool, _ probe: KeychainProbe, step: ((String) -> Void)?)
        -> (added: Int32?, found: Int32, seen: [String], removed: Int32?) {
        let which = dataProtection ? "data-protection keychain" : "login keychain"
        var loginKeychain: SecKeychain?
        if !dataProtection {
            step?("login keychain: opened by its path")
            let opened = openLoginKeychain()
            guard let keychain = opened.keychain else {
                // Not opened: nothing was asked of it, and nothing could be kept or shown.
                return (probe.add == nil ? nil : opened.status, opened.status, [], probe.remove.isEmpty ? nil : opened.status)
            }
            loginKeychain = keychain
        }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: probe.service,
                                   kSecUseDataProtectionKeychain as String: dataProtection]
        var added: Int32?
        if let account = probe.add {
            var item = base
            item[kSecAttrAccount as String] = account
            item[kSecValueData as String] = Data("lumen keychain check".utf8)
            if let loginKeychain { item[kSecUseKeychain as String] = loginKeychain }
            step?("\(which): an item added")
            added = SecItemAdd(item as CFDictionary, nil)
        }
        var query = base
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        if let loginKeychain { query[kSecMatchSearchList as String] = [loginKeychain] }
        var result: CFTypeRef?
        step?("\(which): the service's items looked for")
        let found = SecItemCopyMatching(query as CFDictionary, &result)
        let seen = ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        var removed: Int32?
        for account in probe.remove {
            var item = base
            item[kSecAttrAccount as String] = account
            item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            if let loginKeychain { item[kSecMatchSearchList as String] = [loginKeychain] }
            step?("\(which): an item removed")
            let status = SecItemDelete(item as CFDictionary)
            // The first that did not go through, or 0.
            if removed == nil || removed == errSecSuccess { removed = status }
        }
        return (added, found, seen, removed)
    }

    /// The account's login keychain, opened by its path under the account's own home (not this
    /// process's, which a profile's process has of its own), and what opening it answered.
    private static func openLoginKeychain() -> (keychain: SecKeychain?, status: Int32) {
        guard let home = SafariPaths.realHome else { return (nil, errSecNoSuchKeychain) }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(home + "/Library/Keychains/login.keychain-db", &keychain)
        return (status == errSecSuccess ? keychain : nil, status)
    }

    /// What looking `name` up answers in this process: 0 when it reached the service (the right
    /// to send to it is let go at once), the refusal otherwise — 1100 (`BOOTSTRAP_NOT_PRIVILEGED`)
    /// when a sandbox refuses it, -1 when the lookup itself is not there.
    static func lookUp(_ name: String) -> Int32 {
        typealias LookUp = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
        let handle = dlopen(nil, RTLD_NOW)
        guard let symbol = dlsym(handle, "bootstrap_look_up"), let portSymbol = dlsym(handle, "bootstrap_port") else { return -1 }
        let lookUp = unsafeBitCast(symbol, to: LookUp.self)
        let bootstrap = portSymbol.assumingMemoryBound(to: mach_port_t.self).pointee
        var port: mach_port_t = 0
        let status = name.withCString { lookUp(bootstrap, $0, &port) }
        if status == KERN_SUCCESS, port != 0 {
            mach_port_deallocate(mach_task_self_, port)
        }
        return status
    }

    /// `--keychain-probe <service> [--add <account>] [--remove <account>]…`: `run` in this process,
    /// its report printed as one line of JSON after `KEYCHAIN-PROBE `.
    static func runFromCommandLine(arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: "--keychain-probe"), arguments.indices.contains(index + 1) else {
            print("KEYCHAIN-PROBE usage: --keychain-probe <service> [--add <account>] [--remove <account>]…")
            exit(64)
        }
        var probe = KeychainProbe(service: arguments[index + 1])
        if let add = arguments.firstIndex(of: "--add"), arguments.indices.contains(add + 1) { probe.add = arguments[add + 1] }
        probe.remove = arguments.indices.filter { arguments[$0] == "--remove" && arguments.indices.contains($0 + 1) }.map { arguments[$0 + 1] }
        // Each step said as it is taken, at once: a process that stops answering has said where.
        let report = run(probe) { step in
            print("KEYCHAIN-PROBE-STEP \(step)")
            fflush(stdout)
        }
        guard let data = try? JSONEncoder().encode(report), let line = String(data: data, encoding: .utf8) else { exit(1) }
        print("KEYCHAIN-PROBE \(line)")
        exit(0)
    }

    /// What a `--keychain-probe` run of the executable at `executable` printed — or, with no report,
    /// why not. Never longer than `timeout`: a process that has not answered by then is ended, and
    /// the reason names the last step it said it was taking (CI run 662: one of these processes never
    /// answered, and the release check ran out of its four minutes without a word of where).
    static func probe(_ executable: URL, _ probe: KeychainProbe, timeout: TimeInterval = 20) async
        -> (report: KeychainReport?, failure: String) {
        var arguments = ["--keychain-probe", probe.service]
        if let account = probe.add { arguments += ["--add", account] }
        for account in probe.remove { arguments += ["--remove", account] }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = ProbeOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.append(chunk)
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (nil, "could not be started: \(error.localizedDescription)")
        }
        // Its answer, not the end of its output, is what is waited for: an answer is taken as soon as
        // it is printed, whoever else may still hold the other end of the pipe.
        let deadline = Date().addingTimeInterval(timeout)
        while output.report == nil, process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // A process that has just ended: what it printed last, until the pipe says there is no more.
        let drained = Date().addingTimeInterval(2)
        while output.report == nil, !process.isRunning, !output.ended, Date() < drained {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let report = output.report {
            // It ends by itself right after its answer (exit), or is ended: none is left behind.
            let ending = Date().addingTimeInterval(2)
            while process.isRunning, Date() < ending {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { process.terminate() }
            return (report, "")
        }
        let last = output.steps.last ?? "none (it said nothing)"
        if process.isRunning {
            process.terminate()
            return (nil, "no answer in \(Int(timeout)) s, ended; its last step: \(last)")
        }
        return (nil, "ended with \(process.terminationStatus) and no answer; its last step: \(last)")
    }

    /// `errSecMissingEntitlement`: the keychain's word for a process none of whose entitlements gives
    /// it a keychain access group.
    static let missingEntitlement: Int32 = -34018
}

/// What a probe's process has printed so far: its steps, and its report once it is there. Filled
/// from the pipe's own queue, read from the waiting task.
private final class ProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var sawEnd = false

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    /// The pipe said there is no more: every process holding its other end has closed it.
    func finish() {
        lock.lock()
        sawEnd = true
        lock.unlock()
    }

    var ended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawEnd
    }

    /// Decoded whole, never a chunk at a time: a chunk may end in the middle of a character.
    private var lines: [Substring] {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    var steps: [String] {
        lines.filter { $0.hasPrefix("KEYCHAIN-PROBE-STEP ") }.map { String($0.dropFirst("KEYCHAIN-PROBE-STEP ".count)) }
    }

    var report: KeychainReport? {
        guard let line = lines.first(where: { $0.hasPrefix("KEYCHAIN-PROBE {") }) else { return nil }
        return try? JSONDecoder().decode(KeychainReport.self, from: Data(line.dropFirst("KEYCHAIN-PROBE ".count).utf8))
    }
}
