import AppKit
import BrowserCore
import Foundation
import os

/// The child process of one profile: `PrivacyBrowser --profile-session <uuid>`.
///
/// Started by the manager process (`ProfileProcess`, which explains why), and given its profile's
/// grant on its standard input — that profile's key and entry in the index, not the vault's master
/// key (`ProfileGrant`): the profile to run is in `argv`, the language, locale and time zone are in
/// `argv` and the environment where the system reads them at process start, and the key is the one
/// thing that must not be visible to other processes.
///
/// It then does what the manager used to do in-process: open the vault for that one profile, launch it
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
        // Everything after the grant on this stream is commands from the manager. Read before
        // anything else happens, so that a manager that died meanwhile cannot leave this process
        // waiting with a window open.
        let grant: ProfileGrant
        do {
            grant = try ProfileGrant.read { count in try? FileHandle.standardInput.read(upToCount: count) }
        } catch {
            FileHandle.standardError.write(Data("--profile-session expects its profile's grant on stdin\n".utf8))
            exit(2)
        }
        guard grant.profileID == profileID else {
            FileHandle.standardError.write(Data("--profile-session was granted another profile\n".utf8))
            exit(2)
        }
        // The profile's own settings first: what this process may send, and through which proxy,
        // is decided before anything in it can send at all — before Safari's frameworks, which
        // start clients of their own as soon as they load, are even loaded (ProfileNetworkGuard).
        let repository: ProfileRepository
        let stored: ProfileConfiguration
        do {
            let vault = try MasterVault.open(in: AppEnvironment.vaultDirectory, grant: grant)
            repository = try ProfileRepository(vault: vault)
            // The index is the manager's: a saved change of the profile's settings is its to count.
            repository.onRevisionBump = { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ProfileSessionHost.send(.configurationSaved) } }
            }
            stored = try repository.loadConfiguration(profileID)
            try ProfileNetworkGuard.engage(profileID: profileID, proxy: stored.proxy, safeBrowsing: stored.safeBrowsingEnabled,
                                           protectsLocalNetwork: stored.blocksLocalNetwork)
        } catch {
            log.error("Could not open the vault or hold \(profileID.uuidString, privacy: .public) to its proxy: \(String(describing: error), privacy: .private)")
            exit(3)
        }
        // While this process runs, its home is in use: a manager started meanwhile (after a crash
        // of the one that started this) must not seal it from under it.
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            SafariHomeVault.holdWhileRunning(home: URL(fileURLWithPath: home, isDirectory: true))
            // What Safari's chrome saves through the standard defaults is the profile's, in its home.
            SafariUIState.keepInProfileHome(home)
        }
        // A web view that turns out not to be on the profile's data loads nothing (the guard's
        // second lock); the user is told why the page did not open.
        ProfileNetworkGuard.onWebViewOffProfile = {
            ProfileSessionHost.send(.error(L("network.webViewOffProfile")))
        }
        // Before NSApplication exists: hosting Safari's chrome means this process has to *be* the
        // kind of application its chrome expects, starting with NSApp itself.
        if SafariChromeHost.prepareForChildProcess(configuration: stored) {
            log.notice("Safari's chrome is hosted in this process")
        }
        // ⌘, and Settings… in Safari's menu: the manager's Settings, not Safari's.
        SafariChrome.onShowSettings = { ProfileSessionHost.send(.showSettings) }
        // The app's browsing settings as this process starts: its first window opens by them.
        if let json = ProcessInfo.processInfo.environment[ProfileProcess.browsingPreferencesVariable],
           let preferences = try? JSONDecoder().decode(BrowsingPreferences.self, from: Data(json.utf8)) {
            BrowsingPreferences.current = preferences
        }
        let delegate = Delegate(profileID: profileID, repository: repository)
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

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let profileID: UUID
        private let repository: ProfileRepository
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

        init(profileID: UUID, repository: ProfileRepository) {
            self.profileID = profileID
            self.repository = repository
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // The manager asks this process to quit with SIGTERM, whose default action would kill
            // it with the profile's data lying decrypted. Routed into the normal quit instead.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            terminationSource = source

            ProfileChannel.readLines(from: FileHandle.standardInput, onEnd: {
                // The manager is gone (it quit or crashed): nothing can ask this process to seal the
                // profile's data any more, so it does now, the way quitting does.
                ProfileSessionHost.log.notice("The manager closed the channel: quitting, which seals the profile")
                NSApp.terminate(nil)
            }) { [weak self] line in
                guard let command = ProfileChannel.decode(ProfileCommand.self, from: line) else { return }
                self?.handle(command)
            }
            // A process without Safari's chrome has its default store closed here, before the
            // launch builds anything (with the chrome, that happened before its menu came up).
            ProfileNetworkGuard.takeOverDefaultStore()
            // What Safari's chrome needs and this macOS does not have is said where the user is
            // looking, not only in the log: a renamed method can be a feature gone quiet.
            let missing = SafariChrome.missingPieces()
            if !missing.isEmpty {
                ProfileSessionHost.send(.error(String(format: L("safari.chrome.missingPieces"), missing.joined(separator: ", "))))
            }
            let manager = ProfileManager(repository: repository)
            manager.runsInProfileProcess = true
            manager.onError = { message in
                ProfileSessionHost.log.error("\(message, privacy: .private)")
                // Shown by the manager, which is where the user is looking.
                ProfileSessionHost.send(.error(message))
            }
            // The profile's last window closed: this process exists for that profile only, so
            // it quits — and quitting is what seals the data. Safari's windows count as the
            // profile's windows here (SafariChromeHost).
            manager.onReturnToProfiles = { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            SafariChromeHost.onLastWindowClosed = { NSApp.terminate(nil) }
            // How the data was sealed, told to the manager before this process exits.
            manager.onSealed = { _, report in ProfileSessionHost.send(.sealed(report)) }
            // Where the proxy exits could not be found: the manager says so, where the user looks.
            manager.onProxyLocationUnknown = { _ in ProfileSessionHost.send(.proxyLocationUnknown) }
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
                // The manager shows the profile as being encrypted, and Safari's windows go now,
                // not after the seal: a quit that keeps its window up for seconds looks like a hang.
                willSeal: {
                    ProfileSessionHost.send(.sealing)
                    SafariChromeHost.closeEveryWindow()
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
                    ProfileSessionHost.log.error("Launching \(self.profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .private)")
                    NSApp.terminate(nil)
                }
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
            case .openURL(let url):
                NSApp.activate(ignoringOtherApps: true)
                guard let session = manager?.session(for: profileID) else { return }
                openWindow(of: session, url: url)
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
                    ProfileSessionHost.send(.cookiesImported(outcome))
                }
            case .exportCookies:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let store = self.manager?.session(for: self.profileID)?.dataStore?.httpCookieStore else {
                        ProfileSessionHost.send(.cookiesExported(nil))
                        return
                    }
                    ProfileSessionHost.send(.cookiesExported(await CookieStoreSync.exportableCookies(in: store)))
                }
            case .stopWarmUp:
                manager?.stopWarmUp(profileID)
            case .checkNetwork(let probe):
                Task { @MainActor in
                    ProfileSessionHost.send(.networkReport(await ProfileNetworkGuard.report(probe: probe)))
                }
            case .preferences(let preferences):
                BrowsingPreferences.current = preferences
                DockIcon.show(initials: preferences.dockInitials, of: profileName)
            case .walkMenu(let from):
                SafariMenuWalk.start(from: from, session: manager?.session(for: profileID)) { line in
                    ProfileSessionHost.send(.menuWalk(line))
                }
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
            switch command {
            case .stop, .preferences: return true
            default: return false
            }
        }

        /// The profile's name, for its Dock icon.
        private var profileName: String {
            (try? repository.summary(for: profileID).name) ?? ""
        }

        /// A window of the profile. In Safari's chrome a window is Safari's to open, and it comes
        /// up with the profile's data like every other (`SafariChromeHost`). From here on this
        /// process has a window of its own, so a warm-up ending no longer quits it.
        private func openWindow(of session: BrowserSession, url: URL? = nil) {
            guard !isQuitting else { return } // this process is sealing its data and going
            showedWindow = true
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            if !SafariChromeHost.open(session: session, url: url) {
                session.openWindow(url: url)
            }
        }

        /// Closing the window must not quit before the data is sealed; the quit path does that.
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            quitCoordinator?.shouldTerminate(sender) ?? .terminateNow
        }
    }
}
