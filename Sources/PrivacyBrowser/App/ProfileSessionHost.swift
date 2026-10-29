import AppKit
import BrowserCore
import Foundation
import os

/// The child process of one profile: `PrivacyBrowser --profile-session <uuid>`.
///
/// Started by the manager process (`ProfileProcess`, which explains why), and given the vault's
/// master key on its standard input — nothing else: the profile to run is in `argv`, the language,
/// locale and time zone are in `argv` and the environment where the system reads them at process
/// start, and the key is the one thing that must not be visible to other processes.
///
/// It then does what the manager used to do in-process: open the vault, launch that one profile
/// with its own `ProfileManager` (proxy lookup, decrypting the WebKit data, cookies, window), and
/// on the way out seal it. Quit, ⌘Q and the `SIGTERM` the manager sends all end up in the same
/// place, because sealing is the one thing that must not be skipped.
@MainActor
enum ProfileSessionHost {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileSession")
    private static var delegate: Delegate?

    /// Tells the manager something. One line on standard output, prefixed so that Safari's own
    /// output on the same stream is not read as ours.
    static func send(_ event: ProfileEvent) {
        guard let data = ProfileChannel.encode(event, prefix: ProfileChannel.eventPrefix) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    static func start(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--profile-session"),
              arguments.indices.contains(index + 1),
              let profileID = UUID(uuidString: arguments[index + 1]) else {
            FileHandle.standardError.write(Data("--profile-session needs a profile id\n".utf8))
            exit(2)
        }
        // Everything after the key on this stream is commands from the manager.
        guard let key = readMasterKey() else {
            FileHandle.standardError.write(Data("--profile-session expects the vault master key on stdin\n".utf8))
            exit(2)
        }
        // Before NSApplication exists: hosting Safari's chrome means this process has to *be* the
        // kind of application its chrome expects, starting with NSApp itself.
        if SafariChromeHost.prepareForChildProcess() {
            log.notice("Safari's chrome is hosted in this process")
        }
        let delegate = Delegate(profileID: profileID, masterKeyMaterial: key)
        Self.delegate = delegate
        let application = NSApplication.shared
        application.delegate = delegate
        // A process started only to warm a profile up stays out of the Dock and out of ⌘-Tab: the
        // user asked for a warm-up, not for an app. It becomes an ordinary one the moment a window
        // of the profile is asked for. (Its robot then scrolls from its own script world rather
        // than with wheel events, which need a key window; the robot reports which it used.)
        application.setActivationPolicy(ProcessInfo.processInfo.environment["PB_WARM_UP_ONLY"] == "1" ? .accessory : .regular)
        application.run()
    }

    /// The master key: 32 bytes and end of file. Read before anything else happens, so that a
    /// manager that died meanwhile cannot leave this process waiting with a window open.
    private static func readMasterKey() -> Data? {
        var key = Data()
        while key.count < 32 {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: 32 - key.count), !chunk.isEmpty else { break }
            key.append(chunk)
        }
        return key.count == 32 ? key : nil
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let profileID: UUID
        private var masterKeyMaterial: Data
        private var manager: ProfileManager?
        private var quitCoordinator: QuitCoordinator?
        private var terminationSource: DispatchSourceSignal?
        /// This process was started to warm the profile up and nothing else: it opens no window,
        /// and when the run ends it quits, which is what seals what the run collected.
        private let isForWarmUpOnly = ProcessInfo.processInfo.environment["PB_WARM_UP_ONLY"] == "1"
        /// A window of the profile has been opened (at launch, or asked for since).
        private var showedWindow = false
        /// Quitting has been asked for once: the last cookie count of a run comes back after the
        /// run is over and must not ask again, since quitting is what seals the profile's data.
        private var isQuitting = false
        /// The profile's session exists and commands can be acted on.
        private var isReady = false
        /// Commands that arrived before it did, in the order they came: the manager sends them as
        /// soon as this process exists, which is before the profile is launched inside it.
        private var pendingCommands: [ProfileCommand] = []

        init(profileID: UUID, masterKeyMaterial: Data) {
            self.profileID = profileID
            self.masterKeyMaterial = masterKeyMaterial
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // The manager asks this process to quit with SIGTERM, whose default action would kill
            // it with the profile's data lying decrypted. Routed into the normal quit instead.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            terminationSource = source

            ProfileChannel.readLines(from: FileHandle.standardInput) { [weak self] line in
                guard let command = ProfileChannel.decode(ProfileCommand.self, from: line) else { return }
                self?.handle(command)
            }
            do {
                let vault = try MasterVault.open(in: AppEnvironment.vaultDirectory, masterKeyMaterial: masterKeyMaterial)
                masterKeyMaterial.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    memset_s(base, bytes.count, 0, bytes.count)
                }
                let repository = try ProfileRepository(vault: vault)
                let manager = ProfileManager(repository: repository)
                manager.runsInProfileProcess = true
                manager.onError = { message in
                    ProfileSessionHost.log.error("\(message, privacy: .public)")
                    // Shown by the manager, which is where the user is looking.
                    ProfileSessionHost.send(.error(message))
                }
                // The profile's last window closed: this process exists for that profile only, so
                // it quits — and quitting is what seals the data.
                manager.onReturnToProfiles = { MainActor.assumeIsolated { NSApp.terminate(nil) } }
                manager.onWarmUpProgress = { [weak self, weak manager] id in
                    guard let robot = manager?.warmUpRobot(for: id) else { return }
                    let status = robot.status
                    ProfileSessionHost.send(.warmUp(status))
                    // Warmed up and nothing has asked for a window: there is nothing left for this
                    // process to do, and quitting is what seals the cookies the run collected.
                    if let self, self.isForWarmUpOnly, !self.showedWindow, !status.isRunning, !self.isQuitting {
                        self.isQuitting = true
                        ProfileSessionHost.log.notice("The warm-up is over and this profile has no window: quitting")
                        NSApp.terminate(nil)
                    }
                }
                self.manager = manager
                quitCoordinator = QuitCoordinator(
                    hasActivity: { manager.hasActivity },
                    lockForQuit: {
                        manager.prepareForQuit()
                        await manager.shutDown()
                    },
                    terminate: { NSApp.terminate(nil) })
                Task { @MainActor in
                    do {
                        try await manager.launch(self.profileID, openingWindow: !self.isForWarmUpOnly)
                        self.showedWindow = !self.isForWarmUpOnly
                        self.isReady = true
                        ProfileSessionHost.send(.running(hostsSafariChrome: SafariChromeHost.isHosting))
                        // Whatever the manager asked for while the profile was still starting.
                        let waiting = self.pendingCommands
                        self.pendingCommands = []
                        for command in waiting { self.handle(command) }
                    } catch {
                        ProfileSessionHost.log.error("Launching \(self.profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                ProfileSessionHost.log.error("Could not open the vault for \(self.profileID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                exit(3)
            }
        }

        /// What the manager asked for. Anything that needs the profile's session waits until it
        /// exists: a command can arrive while the launch is still running.
        private func handle(_ command: ProfileCommand) {
            // Only quitting can be done before the profile is launched; everything else needs its
            // session, and waits for it rather than being refused. (A warm-up asked for while the
            // profile was still starting used to be dropped, which looked like a warm-up that
            // simply did nothing.)
            if !isReady, !isImmediate(command) {
                pendingCommands.append(command)
                return
            }
            switch command {
            case .stop:
                NSApp.terminate(nil)
            case .activate:
                NSApp.activate(ignoringOtherApps: true)
                guard let session = manager?.session(for: profileID) else { return }
                if showedWindow { session.bringToFront() } else { openWindow(of: session) }
            case .openWindow:
                NSApp.activate(ignoringOtherApps: true)
                guard let session = manager?.session(for: profileID) else { return }
                openWindow(of: session)
            case .showLibrary(let section):
                guard let section = LibraryView.Section(rawValue: section) else { return }
                manager?.showLibrary(profileID, section: section)
            case .showPasswords:
                // The password window is the manager's own screen; from here the most it can do is
                // bring the profile forward so the two are not fighting over the front.
                NSApp.activate(ignoringOtherApps: true)
            case .importCookies(let cookies):
                Task { @MainActor [weak self] in
                    guard let self, let manager = self.manager else { return }
                    let outcome = try? await manager.importCookies(cookies, into: self.profileID)
                    switch outcome {
                    case .applied(let stored, let refused):
                        ProfileSessionHost.send(.cookiesImported(accepted: stored, refused: refused.count))
                    case .queued(let queued):
                        ProfileSessionHost.send(.cookiesImported(accepted: queued, refused: 0))
                    case nil:
                        ProfileSessionHost.send(.error(L("cookies.error.busy")))
                    }
                }
            case .stopWarmUp:
                manager?.stopWarmUp(profileID)
            case .startWarmUp(let plan):
                if manager?.startWarmUp(profileID, plan: plan) != true {
                    ProfileSessionHost.log.error("Warm-up of \(self.profileID.uuidString, privacy: .public) did not start")
                    let pages = plan.pages().pages.count
                    ProfileSessionHost.send(.warmUp(WarmUpStatus(phase: .stopped, visited: 0, total: pages)))
                    // Nothing else was asked of this process, so it has nothing left to do —
                    // unless a run is already going, which is one reason a second one is refused.
                    if isForWarmUpOnly, !showedWindow, !isQuitting,
                       manager?.warmUpStatus(of: profileID)?.isRunning != true {
                        isQuitting = true
                        NSApp.terminate(nil)
                    }
                }
            }
        }

        /// Whether a command can be acted on before the profile's session exists.
        private func isImmediate(_ command: ProfileCommand) -> Bool {
            if case .stop = command { return true }
            return false
        }

        /// A window of the profile. In Safari's chrome a window is Safari's to open, and it comes
        /// up with the profile's data like every other (`SafariChromeHost`). From here on this
        /// process has a window of its own, so a warm-up ending no longer quits it.
        private func openWindow(of session: BrowserSession) {
            guard !isQuitting else { return } // this process is sealing its data and going
            showedWindow = true
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            if !SafariChromeHost.open(session: session, url: nil) {
                session.openWindow(url: nil)
            }
        }

        /// Closing the window must not quit before the data is sealed; the quit path does that.
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            quitCoordinator?.shouldTerminate(sender) ?? .terminateNow
        }
    }
}
