import AppKit
import BrowserCore
import CryptoKit
import Foundation
import os
import WebKit

/// What a launcher assigned to this instance: one profile to run (docs/PROCESS_PER_PROFILE.md).
struct ProfileProcessAssignment {
    let connection: ProcessConnection
    /// The launcher's socket (a test operation connects to it again).
    let socketPath: String
    let launchToken: String
    let profileID: UUID
    let profileName: String
    let vaultRoot: URL
    let ephemeral: Bool
    let selfTest: Bool
}

/// The profile process's first step, before any UI: is this instance one a launcher started?
enum ProfileProcessClient {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileProcess")

    /// Asks each launcher of this app (its socket in the container's temporary directory) whether
    /// it started this process; only a launcher whose code is this app's is asked or believed.
    /// Nil when none did: the instance then starts as a launcher itself.
    static func assignment() -> ProfileProcessAssignment? {
        for path in ProcessSocket.launcherPaths() where path != ProcessSocket.launcherPath(for: getpid()) {
            guard let fd = try? ProcessSocket.connect(to: path) else { continue }
            guard let token = ProcessPeer.auditToken(of: fd) else {
                Darwin.close(fd)
                continue
            }
            let status = ProcessPeer.codeStatus(of: token)
            guard status == errSecSuccess else {
                log.error("Ignored a launcher socket whose process is not this app: \(ProcessPeer.describe(status), privacy: .public)")
                Darwin.close(fd)
                continue
            }
            let connection = ProcessConnection(fd: fd, peer: ProcessPeer.identity(of: token))
            // The launcher may hold the hello until LaunchServices has told it this PID.
            connection.setReadTimeout(20)
            do {
                try connection.send(ProcessMessage(.hello))
                guard let reply = try connection.receive() else { continue }
                guard reply.kind == .assign, let launchToken = reply.launchToken, let profileID = reply.profileID,
                      let root = reply.vaultRoot else {
                    connection.close()
                    continue
                }
                return ProfileProcessAssignment(connection: connection, socketPath: path, launchToken: launchToken,
                                                profileID: profileID, profileName: reply.profileName ?? "",
                                                vaultRoot: URL(fileURLWithPath: root, isDirectory: true),
                                                ephemeral: reply.ephemeral ?? false, selfTest: reply.selfTest ?? false)
            } catch {
                connection.close()
            }
        }
        return nil
    }
}

/// A profile's own process: that profile's windows and its WebKit, nothing else.
@MainActor
enum ProfileProcessApp {
    private static var delegate: ProfileProcessDelegate?

    static func run(_ assignment: ProfileProcessAssignment) -> Never {
        let app = NSApplication.shared
        let delegate = ProfileProcessDelegate(runtime: ProfileProcessRuntime(assignment: assignment))
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = ProfileProcessMenu.make(profileName: assignment.profileName)
        app.run()
        exit(0)
    }
}

@MainActor
private final class ProfileProcessDelegate: NSObject, NSApplicationDelegate {
    let runtime: ProfileProcessRuntime
    private lazy var quitCoordinator = QuitCoordinator(
        hasActivity: { [weak self] in self?.runtime.hasActivity ?? false },
        lockForQuit: { [weak self] in await self?.runtime.seal(reportAndExit: false) },
        terminate: { NSApp.terminate(nil) })

    init(runtime: ProfileProcessRuntime) {
        self.runtime = runtime
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The profile's name and initials: each running profile is an app of its own in the Dock.
        NSApp.dockTile.badgeLabel = String(runtime.assignment.profileName.prefix(2))
        runtime.begin()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime.session?.bringToFront()
        return true
    }

    /// ⌘Q here stops this profile: its data is sealed before the process exits (`QuitCoordinator`,
    /// as in the launcher).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitCoordinator.shouldTerminate(sender)
    }
}

/// Runs one profile: key, decrypt, language and locale, session, seal.
@MainActor
final class ProfileProcessRuntime {
    let assignment: ProfileProcessAssignment
    private var key: SymmetricKey?
    private(set) var session: BrowserSession?
    private let vault: WebDataStoreVault
    private var prepared = false
    /// The web data is being decrypted: a seal waits for it.
    private var preparing = false
    private var pendingStart: ProcessMessage?
    private var sealing = false
    private var sealed = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileProcess")

    init(assignment: ProfileProcessAssignment) {
        self.assignment = assignment
        self.vault = WebDataStoreVault(locations: ProfileFileLocations(root: assignment.vaultRoot))
    }

    /// A launch under way, the profile running, or its seal: a quit must wait for the seal.
    var hasActivity: Bool { !sealed }

    func begin() {
        assignment.connection.startReading({ [weak self] message in
            self?.received(message)
        }, onClose: { [weak self] in
            self?.launcherGone()
        })
        var request = ProcessMessage(.keyRequest)
        request.launchToken = assignment.launchToken
        send(request)
    }

    private func send(_ message: ProcessMessage) {
        do {
            try assignment.connection.send(message)
        } catch {
            log.error("Could not tell the launcher \(message.kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func received(_ message: ProcessMessage) {
        switch message.kind {
        case .key:
            guard key == nil, let encoded = message.key, let raw = Data(base64Encoded: encoded) else { return }
            key = SymmetricKey(data: raw)
            Task { await prepare() }
        case .reject:
            log.error("The launcher refused: \(message.reason ?? "?", privacy: .public)")
            exit(1)
        case .start:
            pendingStart = message
            if prepared { Task { await start() } }
        case .stop:
            Task { await seal(reportAndExit: true) }
        case .openWindow:
            session?.openWindow(url: nil)
            NSApp.activate(ignoringOtherApps: true)
        case .activate:
            session?.bringToFront()
        case .test:
            guard assignment.selfTest else { return }
            Task { await runTest(message) }
        default:
            break
        }
    }

    // MARK: Launch

    private func prepare() async {
        guard let key, !sealing, !sealed else { return }
        if !assignment.ephemeral {
            preparing = true
            defer { preparing = false }
            do {
                // Before the data store exists.
                try await vault.prepareForLaunch(profileID: assignment.profileID, key: key)
            } catch {
                prepared = true // whatever was decrypted is sealed again
                fail("could not decrypt the website data: \(error.localizedDescription)")
                return
            }
        }
        prepared = true
        send(ProcessMessage(.prepared))
        if pendingStart != nil { await start() }
    }

    private func start() async {
        guard let message = pendingStart, session == nil, !sealing, let key else { return }
        pendingStart = nil
        guard let configuration = message.configuration else {
            fail("no configuration")
            return
        }
        // Before the first WebKit process: this process's language and locale are the profile's.
        WebContentLanguage.decide(message.language, locale: message.locale)
        if configuration.proxy != nil { await ContentRules.prepare() }
        // A stop that came while the rules compiled wins: no window for a profile being sealed.
        guard !sealing, !sealed else { return }
        do {
            let files = SingleProfileFiles(root: assignment.vaultRoot, profileID: assignment.profileID, key: key)
            let library = ProfileLibrary(history: try files.historyStore(policy: configuration.historyPolicy, persistent: !configuration.ephemeral),
                                         bookmarks: try files.bookmarkStore(), recordsHistory: configuration.historyEnabled)
            // Settings change in the launcher, which writes them (stage 1: AutoFill is off here).
            let passwordSettings = ProfilePasswordSettings(profileName: assignment.profileName, launchConfiguration: configuration,
                                                           load: nil, save: nil)
            let session = try BrowserSession(profileID: assignment.profileID, profileName: assignment.profileName,
                                             configuration: configuration, passwordVault: try files.passwordVault(),
                                             passwordSettings: passwordSettings, library: library)
            session.onAllWindowsClosed = { [weak self] in
                Task { await self?.seal(reportAndExit: true) }
            }
            self.session = session
            session.exitLocation = configuration.lastProxyLocation
            SafariGraph.openFirstWindow(for: session, url: configuration.startURL)
            NSApp.activate(ignoringOtherApps: true)
            send(ProcessMessage(.started))
        } catch {
            fail("could not open the profile: \(error.localizedDescription)")
        }
    }

    private func fail(_ reason: String) {
        log.error("Profile process failed: \(reason, privacy: .public)")
        var message = ProcessMessage(.failed)
        message.reason = reason
        send(message)
        Task { await seal(reportAndExit: true) }
    }

    // MARK: Stop

    /// Closes the windows and seals the web data; then (`reportAndExit`) tells the launcher and
    /// quits. Right before this process exits, so a store WebKit still holds is force-sealed.
    func seal(reportAndExit: Bool) async {
        if sealing || sealed {
            // A second call (stop, then the last window): wait for the first.
            _ = await ProfileProcessHost.poll(timeout: 120) { self.sealed }
            if reportAndExit { NSApp.terminate(nil) }
            return
        }
        sealing = true
        // A decryption under way finishes first; then what it wrote is sealed again.
        _ = await ProfileProcessHost.poll(timeout: 120) { !self.preparing }
        var ok = true
        var reason: String?
        let hadStore = session?.dataStore != nil
        if let session {
            session.onAllWindowsClosed = nil
            if !assignment.ephemeral, let store = session.dataStore {
                await CookieStoreImport.flush(store.httpCookieStore)
            }
            session.shutDown()
            self.session = nil
        }
        if !assignment.ephemeral, let key, prepared {
            vault.forceSealWhenStoreStaysInUse = true
            do {
                try await vault.seal(profileID: assignment.profileID, key: key, activeStore: hadStore)
            } catch {
                ok = false
                reason = error.localizedDescription
                log.error("Sealing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        key = nil
        sealed = true
        sealing = false
        var message = ProcessMessage(.sealed)
        message.ok = ok
        message.reason = reason
        send(message)
        if reportAndExit { NSApp.terminate(nil) }
    }

    /// The launcher ended (or crashed): seal on our own and exit.
    private func launcherGone() {
        guard !sealed else { return }
        log.notice("The launcher is gone: sealing and quitting")
        Task {
            await seal(reportAndExit: false)
            exit(0)
        }
    }

    // MARK: Self-test operations

    private func runTest(_ message: ProcessMessage) async {
        var reply = ProcessMessage(.testResult)
        reply.testID = message.testID
        do {
            reply.value = try await perform(message.operation ?? "", message.argument)
            reply.ok = true
        } catch {
            reply.ok = false
            reply.reason = error.localizedDescription
        }
        send(reply)
    }

    private struct TestError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private func perform(_ operation: String, _ argument: String?) async throws -> String {
        switch operation {
        case "load":
            guard let argument, let url = URL(string: argument), let controller = session?.frontmostWindow,
                  let webView = controller.selectedTab?.webView else { throw TestError("no tab") }
            controller.load(url)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let loaded = await ProfileProcessHost.poll(timeout: 30) {
                !webView.isLoading && webView.url?.host == url.host && webView.url?.path == url.path
            }
            guard loaded else { throw TestError("\(url) did not load (now \(webView.url?.absoluteString ?? "nil"))") }
            return "loaded"
        case "evaluate":
            guard let argument, let webView = session?.frontmostWindow?.selectedTab?.webView else { throw TestError("no tab") }
            let value: Any? = try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(argument, arguments: [:], in: nil, in: .page) { result in
                    continuation.resume(with: result.map { $0 as Any? })
                }
            }
            return value.map { "\($0)" } ?? "nil"
        case "closeWindows":
            // As the user closing each window: the last one stops the profile.
            for controller in session?.windowControllers ?? [] { controller.window?.performClose(nil) }
            return "closing"
        case "killSelf":
            kill(getpid(), SIGKILL)
            return "unreachable"
        case "reportedLanguage":
            // What this process's WebKit makes of `argument` (as Safari's would).
            return WebContentLanguage.reported(argument ?? "")
        case "quit":
            // ⌘Q in this process: the profile is sealed before it exits (`QuitCoordinator`).
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "quitting"
        case "footprint":
            // This process's own memory footprint (what Activity Monitor shows as Memory).
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { throw TestError("task_info: \(status)") }
            return String(info.phys_footprint)
        case "requestKey":
            // Another connection to the launcher asking for the key of the launch `argument`.
            guard let token = argument else { throw TestError("no token") }
            let path = assignment.socketPath
            return await Task.detached { () -> String in
                do {
                    let fd = try ProcessSocket.connect(to: path)
                    guard let peerToken = ProcessPeer.auditToken(of: fd) else { Darwin.close(fd); return "no peer token" }
                    let connection = ProcessConnection(fd: fd, peer: ProcessPeer.identity(of: peerToken))
                    connection.setReadTimeout(20)
                    var request = ProcessMessage(.keyRequest)
                    request.launchToken = token
                    try connection.send(request)
                    guard let reply = try connection.receive() else { return "closed" }
                    return reply.kind == .reject ? "reject: \(reply.reason ?? "")" : "accepted: \(reply.kind.rawValue)"
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }.value
        default:
            throw TestError("unknown operation \(operation)")
        }
    }
}

/// The menu bar of a profile process (the launcher's comes from SwiftUI's commands).
@MainActor
enum ProfileProcessMenu {
    private static let target = MenuTarget()

    static func make(profileName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(profileName, [
            item(String(format: L("menu.hideApp"), profileName), #selector(NSApplication.hide(_:)), "h"),
            item(L("menu.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("menu.showAll"), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(String(format: L("menu.stopProfile"), profileName), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu(L("menu.file"), [
            item(L("menu.newTab"), #selector(MenuTarget.newTab), "t", target: target),
            item(L("menu.reopenClosedTab"), #selector(MenuTarget.reopenClosedTab), "t", [.command, .shift], target: target),
            item(L("menu.openLocation"), #selector(MenuTarget.openLocation), "l", target: target),
            .separator(),
            item(L("menu.close"), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu(L("menu.edit"), [
            item(L("menu.undo"), Selector(("undo:")), "z"),
            item(L("menu.redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("menu.cut"), #selector(NSText.cut(_:)), "x"),
            item(L("menu.copy"), #selector(NSText.copy(_:)), "c"),
            item(L("menu.paste"), #selector(NSText.paste(_:)), "v"),
            item(L("menu.selectAll"), #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu(L("menu.browser"), [
            item(L("menu.reload"), #selector(MenuTarget.reload), "r", target: target),
            item(L("menu.back"), #selector(MenuTarget.goBack), "[", target: target),
            item(L("menu.forward"), #selector(MenuTarget.goForward), "]", target: target),
            .separator(),
            item(L("menu.showNextTab"), #selector(MenuTarget.selectNextTab), "\t", [.control], target: target),
            item(L("menu.showPreviousTab"), #selector(MenuTarget.selectPreviousTab), "\t", [.control, .shift], target: target),
        ]))
        main.addItem(submenu(L("menu.bookmarks"), [
            item(L("menu.bookmarkThisPage"), #selector(MenuTarget.toggleBookmark), "d", target: target),
            item(L("menu.showAllBookmarks"), #selector(MenuTarget.showBookmarks), "b", [.command, .option], target: target),
            item(L("menu.showHistory"), #selector(MenuTarget.showHistory), "y", target: target),
        ]))
        let window = submenu(L("menu.window"), [
            item(L("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("menu.zoom"), #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item(L("menu.bringAllToFront"), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    /// Forwards to the key browser window (as the launcher's SwiftUI commands do).
    @MainActor
    private final class MenuTarget: NSObject {
        private var window: BrowserWindowController? { NSApp.keyWindow?.windowController as? BrowserWindowController }

        @objc func newTab() { window?.newTab() }
        @objc func reopenClosedTab() { window?.reopenClosedTab() }
        @objc func openLocation() { window?.focusAddressBar() }
        @objc func reload() { window?.reload() }
        @objc func goBack() { window?.goBack() }
        @objc func goForward() { window?.goForward() }
        @objc func selectNextTab() { window?.selectNextTab() }
        @objc func selectPreviousTab() { window?.selectPreviousTab() }
        @objc func toggleBookmark() { window?.toggleBookmark() }
        @objc func showBookmarks() { window?.showBookmarks() }
        @objc func showHistory() { window?.showHistory() }
    }
}
