import AppKit
import BrowserCore
import Foundation

/// `Lumen --webdriver-serve` (CI): the WebDriver's listener over a temporary vault, for a real
/// client to drive (scripts/webdriver_check.py, with Selenium).
///
/// A new profile, held to the self-test proxy (`PB_SELFTEST_HTTP_PROXY_PORT`, which serves the
/// page), is made in a temporary vault; the automation API listens on a port of its choice with
/// WebDriver on it, as in the app; and the profile's address is printed —
/// `WEBDRIVER ADDRESS http://127.0.0.1:<port>/wd/<token>/<profile>` — for the client. The profile
/// is not started: the client's new session starts it, in a process of its own with Safari's
/// window. It serves until it is ended (the script's kill), ten minutes at most.
@MainActor
enum WebDriverCheck {
    private static let tag = "WEBDRIVER"
    private static var kept: [Any] = []

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window: where a session's commands act.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            print("\(tag) INFO served for 10 minutes: ending")
            exit(0)
        }
        Task { @MainActor in
            if let problem = await serve() {
                print("\(tag) FAIL \(problem)")
                exit(1)
            }
        }
        application.run()
    }

    /// Nil when it is serving; else why it is not.
    private static func serve() async -> String? {
        guard !AppEnvironment.isSandboxed else { return "the sandboxed build has no automation API" }
        guard let port = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            return "PB_SELFTEST_HTTP_PROXY_PORT is not set: scripts/selftest_proxy.py serves the page"
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-webdriver-\(UUID().uuidString)", isDirectory: true)
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "webdriver", iterations: 10_000))
            profile = try repository.create(name: "WebDriver", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port), matchProxyLocation: false))
        } catch {
            return "could not make a profile: \(error)"
        }
        print("\(tag) INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")
        let manager = ProfileManager(repository: repository)
        manager.onError = { message in print("\(tag) INFO the manager was told: \(message)") }
        manager.onProfileRunning = { _, hosts in print("\(tag) INFO the profile runs, in \(hosts ? "Safari's window" : "the app's own window")") }
        let settings = AutomationSettings(isEnabled: true, port: 0)
        let handler = AutomationHandler(manager: manager, repository: repository)
        handler.allowsAutomation = { true }
        let server = AutomationServer(settings: settings, handler: handler)
        let webDriver = WebDriverService(manager: manager, repository: repository)
        webDriver.allowsAutomation = { true }
        webDriver.launch = { id in
            do {
                try await manager.launch(id, openingWindow: false)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        webDriver.stop = { id in _ = try? await manager.stop(id) }
        server.webDriver = webDriver
        var said = false
        server.onStateChange = { state in
            switch state {
            case let .listening(port):
                guard !said else { return }
                said = true
                print("\(tag) ADDRESS \(WebDriverRoute.address(port: port, masterToken: settings.token, profile: profile.id))")
            case let .failed(reason):
                print("\(tag) FAIL the listener did not start: \(reason)")
                exit(1)
            case .stopped:
                break
            }
        }
        kept = [repository, manager, server, webDriver, root]
        server.start()
        return nil
    }
}
