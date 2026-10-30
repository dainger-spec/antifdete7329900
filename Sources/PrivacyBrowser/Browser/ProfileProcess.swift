import AppKit
import BrowserCore
import Foundation
import os

/// One profile, in its own process.
///
/// WHY. Three things websites see are decided once, when a process starts, and cannot be changed
/// afterwards: the language list WebKit sends and reports (`AppleLanguages`, see
/// `WebContentLanguage` — in one process the first profile launched decides for every later one),
/// the time zone (`TZ`), and where Safari's own frameworks keep their state
/// (`CFFIXED_USER_HOME`, which is what lets this app host Safari's chrome at all —
/// `SafariChrome`, docs/SAFARI_PROCESS.md §9.1). A profile in its own process gets all three for
/// itself, natively, rather than through scripts patching what a page can see.
///
/// WHAT IS WHERE. The manager process keeps the profile list, the vault and the master password.
/// The child opens the same vault for its one profile: it is handed that profile's key and entry
/// in the index (`ProfileGrant`) over its standard input — not the vault's master key, so the
/// process that loads websites cannot decrypt any other profile, the proxy list, the settings or
/// the sync keys — never in `argv` (which any process of this user can read) and never in the
/// environment. It then runs the whole launch itself, with its own `ProfileManager`: the proxy
/// lookup, decrypting the WebKit data, the cookies, the window. Sealing happens where the data was
/// decrypted, in the child, on its way out. The index is the manager's alone: what would change
/// it in the child is sent to the manager (`ProfileEvent.configurationSaved`).
///
/// WHAT CROSSES. Everything the manager does to a running profile goes over `ProfileChannel`: its
/// windows, its library, its warm-up, cookies imported into it, the check of where its traffic
/// goes. Files both processes open (the password vault) are shared under a lock. The in-process
/// path stays as it was, for the sandboxed build and as the emergency switch (`isEnabled`).
@MainActor
final class ProfileProcess {
    /// On by default in a build without the App Sandbox — the build that can host Safari's chrome,
    /// which needs a process of its own. `PB_PROFILE_PROCESS=0`, or `defaults write <bundle id>
    /// PBProfileProcess -bool NO`, is the emergency switch back to every profile in this one
    /// process (in our own windows); `=1` / `YES` asks for it in a sandboxed build, where it runs
    /// without Safari's chrome.
    static var isEnabled: Bool {
        if let value = ProcessInfo.processInfo.environment["PB_PROFILE_PROCESS"] { return value == "1" }
        if let stored = UserDefaults.standard.object(forKey: "PBProfileProcess") as? Bool { return stored }
        return !AppEnvironment.isSandboxed
    }

    let profileID: UUID
    /// Running only for a warm-up, without a window, until asked for one (an update's confirmation
    /// lists what a quit would stop).
    private(set) var isForWarmUpOnly: Bool
    private let process: Process
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileProcess")
    /// Called on the main actor when the child has exited, however it exited.
    var onExit: (@MainActor (Int32) -> Void)?
    /// What the profile tells the manager (`ProfileChannel`).
    var onEvent: (@MainActor (ProfileEvent) -> Void)?
    /// Open for as long as the child runs: the key first, then commands.
    private var commands: FileHandle?

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    private init(profileID: UUID, isForWarmUpOnly: Bool, process: Process) {
        self.profileID = profileID
        self.isForWarmUpOnly = isForWarmUpOnly
        self.process = process
    }

    /// How many profile processes this app had to kill (`waitUntilExit`). Such a profile did not
    /// end through its own quit path, and an update is not installed at the end of a quit that had
    /// to do it (docs/UPDATES.md §3).
    private(set) static var forcedExits = 0

    /// Asks the profile to do something. Nothing happens if it has already gone.
    func send(_ command: ProfileCommand) {
        guard let commands, process.isRunning, let data = ProfileChannel.encode(command) else { return }
        switch command {
        case .activate, .openWindow, .openURL, .showLibrary, .showPasswords: isForWarmUpOnly = false
        default: break
        }
        do {
            try commands.write(contentsOf: data)
        } catch {
            log.error("Could not reach profile \(self.profileID.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// Starts the profile's process. `home` is the directory Safari's frameworks and the child's
    /// own Application Support lookups resolve into; `languages`, `locale` and `timeZone` are what
    /// the profile's proxy location asks for, as far as it is known before the launch (the child
    /// looks the proxy up again, and a different answer applies at the next launch — the same
    /// limitation the single-process path has, only now it is per profile rather than per run).
    static func start(profileID: UUID,
                      executable: URL,
                      vaultRoot: URL,
                      grant: ProfileGrant,
                      home: URL,
                      languages: [String],
                      locale: String?,
                      timeZone: String?,
                      forWarmUpOnly: Bool = false,
                      preferences: BrowsingPreferences = BrowsingPreferences()) throws -> ProfileProcess {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        var arguments = ["--profile-session", profileID.uuidString]
        if !languages.isEmpty {
            // How CFPreferences reads a list from a command line: -AppleLanguages "(de-DE, en)".
            arguments += ["-AppleLanguages", "(\(languages.joined(separator: ", ")))"]
        }
        if let locale { arguments += ["-AppleLocale", locale] }
        process.arguments = arguments

        process.environment = try childEnvironment(inheriting: ProcessInfo.processInfo.environment, home: home,
                                                   vaultRoot: vaultRoot, timeZone: timeZone, forWarmUpOnly: forWarmUpOnly,
                                                   preferences: preferences)

        let keyPipe = Pipe()
        process.standardInput = keyPipe
        // What the profile says back. Safari's own frameworks print on this stream too, so only
        // prefixed lines are ours and the rest is passed on to the log as it was.
        let eventPipe = Pipe()
        process.standardOutput = eventPipe
        var record = try grant.encoded()
        defer { ProfileGrant.erase(&record) }
        try process.run()

        // The profile's grant first: its key and its entry in the index, not the vault's master
        // key (`ProfileGrant`). Written after the fork so that it exists only in the two
        // processes' memory and the pipe buffer.
        keyPipe.fileHandleForWriting.write(record)

        let child = ProfileProcess(profileID: profileID, isForWarmUpOnly: forWarmUpOnly, process: process)
        // The same pipe carries the commands after the grant; it stays open until the child exits.
        child.commands = keyPipe.fileHandleForWriting
        ProfileChannel.readLines(from: eventPipe.fileHandleForReading) { [weak child] line in
            guard let event = ProfileChannel.decode(ProfileEvent.self, from: line, prefix: ProfileChannel.eventPrefix) else {
                FileHandle.standardError.write(Data((line + "\n").utf8))
                return
            }
            child?.onEvent?(event)
        }
        // Called on one of Foundation's queues, not the main one.
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { child.onExit?(status) }
            }
        }
        child.log.info("Profile \(profileID.uuidString, privacy: .public) runs as pid \(process.processIdentifier, privacy: .public), home \(home.path, privacy: .private), languages \(languages.joined(separator: ","), privacy: .private), TZ \(timeZone ?? "(system)", privacy: .private)")
        return child
    }

    /// What a profile's process inherits from this one's environment, by name: what the system's
    /// own code expects of any process, and this app's switches that apply to a profile too.
    /// Everything else stays here — a shell's or CI's variables, debug switches, the self-test's
    /// own (`PB_SELFTEST_*`), `PB_PROFILE_PROCESS` — so that what a profile's process does does
    /// not depend on how the manager happened to be started.
    static let inheritedEnvironment: Set<String> = [
        "USER", "LOGNAME", "SHELL", "__CF_USER_TEXT_ENCODING", "COMMAND_MODE",
        "APP_SANDBOX_CONTAINER_ID", "PRIVACYBROWSER_LANG", "PB_SAFARI_CHROME",
    ]

    /// Every name a profile's process can find in its environment (the self-test checks it).
    static let environmentNames = inheritedEnvironment.union([
        "HOME", "TMPDIR", "PATH", "CFFIXED_USER_HOME", "PRIVACYBROWSER_VAULT_DIR", "TZ", "__XPC_TZ", "PB_WARM_UP_ONLY",
        browsingPreferencesVariable,
    ])

    /// The app's browsing settings as the process starts (`BrowsingPreferences`, JSON): its first
    /// window opens by them — its tabs restored, its zoom — before anything arrives on its channel.
    static let browsingPreferencesVariable = "PB_BROWSING"

    /// The environment of a profile's process, built from `inheritedEnvironment` and the profile.
    static func childEnvironment(inheriting parent: [String: String], home: URL, vaultRoot: URL,
                                 timeZone: String?, forWarmUpOnly: Bool,
                                 preferences: BrowsingPreferences = BrowsingPreferences()) throws -> [String: String] {
        var environment = parent.filter { inheritedEnvironment.contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        // Safari's frameworks, and anything else asking for the user's home through Foundation,
        // land here; POSIX code reading HOME as well, and temporary files go into the home too, so
        // that they are sealed with it rather than left in this user's shared temporary folder
        // (`SafariHomeVault` removes them before sealing: they do not outlive the run).
        environment["CFFIXED_USER_HOME"] = home.path
        environment["HOME"] = home.path
        let temporary = SafariHomeVault.temporaryDirectory(inHome: home)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        environment["TMPDIR"] = temporary.path + "/"
        // ...which would take the vault with them, so it is named explicitly (AppEnvironment).
        environment["PRIVACYBROWSER_VAULT_DIR"] = vaultRoot.path
        if let timeZone {
            environment["TZ"] = timeZone
            // And for the WebKit processes the child starts (pages and workers run there): libxpc
            // hands an `__XPC_`-prefixed variable to the services it launches, without the prefix.
            environment["__XPC_TZ"] = timeZone
        }
        // Started to warm the profile up and nothing else: it opens no window of its own and
        // quits when the run ends, which is what seals what the run collected.
        if forWarmUpOnly { environment["PB_WARM_UP_ONLY"] = "1" }
        if let json = try? JSONEncoder().encode(preferences) {
            environment[browsingPreferencesVariable] = String(decoding: json, as: UTF8.self)
        }
        return environment
    }

    /// Asks the child to quit, which is what seals its data. The command is the ordinary way and
    /// `SIGTERM` the fallback for a child that is not reading its input any more; both end up in
    /// the same quit path. `waitUntilExit` is how the manager knows the sealing finished.
    func terminate() {
        guard process.isRunning else { return }
        send(.stop)
        process.terminate()
    }

    /// Returns when the child has exited. After `seconds` it is killed outright: the data it was
    /// sealing is then re-sealed at the next unlock, as the single-process path does when a seal
    /// could not finish.
    func waitUntilExit(timeout seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            log.error("Profile \(self.profileID.uuidString, privacy: .public) did not quit in \(Int(seconds), privacy: .public)s; killing it. Its data is sealed again at the next unlock")
            kill(process.processIdentifier, SIGKILL)
            Self.forcedExits += 1
            while process.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Brings the profile's windows forward: its process is a regular application, so this is the
    /// same as activating any other.
    func bringToFront() {
        NSRunningApplication(processIdentifier: process.processIdentifier)?
            .activate(options: [.activateAllWindows])
    }
}
