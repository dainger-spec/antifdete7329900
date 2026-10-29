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
/// The child opens the same vault — it is handed the master key over its standard input, never in
/// `argv` (which any process of this user can read) and never in the environment — then runs the
/// whole launch itself, with its own `ProfileManager`: the proxy lookup, decrypting the WebKit
/// data, the cookies, the window. Sealing happens where the data was decrypted, in the child, on
/// its way out.
///
/// WHAT THIS FIRST STEP DOES NOT DO. Features that reach into a running session from the manager
/// process — the warm-up robot, importing cookies into a profile that is already running, the
/// library window — have no way across the process boundary yet, so they are unavailable for a
/// profile started this way. That is why this is off unless asked for (`isEnabled`), and why the
/// in-process path stays exactly as it was.
@MainActor
final class ProfileProcess {
    /// `PB_PROFILE_PROCESS=1`, or `defaults write <bundle id> PBProfileProcess -bool YES`.
    static var isEnabled: Bool {
        if let value = ProcessInfo.processInfo.environment["PB_PROFILE_PROCESS"] { return value == "1" }
        return UserDefaults.standard.bool(forKey: "PBProfileProcess")
    }

    let profileID: UUID
    private let process: Process
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileProcess")
    /// Called on the main actor when the child has exited, however it exited.
    var onExit: (@MainActor (Int32) -> Void)?

    var isRunning: Bool { process.isRunning }

    private init(profileID: UUID, process: Process) {
        self.profileID = profileID
        self.process = process
    }

    /// Starts the profile's process. `home` is the directory Safari's frameworks and the child's
    /// own Application Support lookups resolve into; `languages`, `locale` and `timeZone` are what
    /// the profile's proxy location asks for, as far as it is known before the launch (the child
    /// looks the proxy up again, and a different answer applies at the next launch — the same
    /// limitation the single-process path has, only now it is per profile rather than per run).
    static func start(profileID: UUID,
                      executable: URL,
                      vaultRoot: URL,
                      masterKeyMaterial: Data,
                      home: URL,
                      languages: [String],
                      locale: String?,
                      timeZone: String?) throws -> ProfileProcess {
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

        var environment = ProcessInfo.processInfo.environment
        // Safari's frameworks, and anything else asking for the user's home, land here.
        environment["CFFIXED_USER_HOME"] = home.path
        // ...which would take the vault with them, so it is named explicitly (AppEnvironment).
        environment["PRIVACYBROWSER_VAULT_DIR"] = vaultRoot.path
        if let timeZone { environment["TZ"] = timeZone }
        environment.removeValue(forKey: "PB_PROFILE_PROCESS")
        process.environment = environment

        let keyPipe = Pipe()
        process.standardInput = keyPipe
        try process.run()

        // The master key, and nothing else, then end of file. Written after the fork so that it
        // exists only in the two processes' memory and the pipe buffer.
        var key = masterKeyMaterial
        keyPipe.fileHandleForWriting.write(key)
        try? keyPipe.fileHandleForWriting.close()
        key.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            memset_s(base, bytes.count, 0, bytes.count)
        }

        let child = ProfileProcess(profileID: profileID, process: process)
        // Called on one of Foundation's queues, not the main one.
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { child.onExit?(status) }
            }
        }
        child.log.info("Profile \(profileID.uuidString, privacy: .public) runs as pid \(process.processIdentifier, privacy: .public), home \(home.path, privacy: .public), languages \(languages.joined(separator: ","), privacy: .public), TZ \(timeZone ?? "(system)", privacy: .public)")
        return child
    }

    /// Asks the child to quit, which is what seals its data (`SIGTERM` reaches its own quit path).
    /// `waitUntilExit` is how the manager knows the sealing finished.
    func terminate() {
        guard process.isRunning else { return }
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
