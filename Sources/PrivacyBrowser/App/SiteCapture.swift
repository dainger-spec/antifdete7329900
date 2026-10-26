import AppKit
import BrowserCore
import TunnelCore
import TunnelTransport
import WebKit

/// `PrivacyBrowser --capture-sites <spec.json> <out-dir>`: loads pages in real profile windows and
/// records what a script on each page returns. `scripts/live_compare.py` writes the spec, runs the
/// same pages and scripts in this Mac's Safari (safaridriver) and compares the two, so the
/// fingerprinting sites a user would try (deviceinfo.me, CreepJS, a TLS/HTTP2 echo, …) are measured
/// in both browsers on the same machine, with the same outer window size.
///
/// Unlike the self-test, pages load in an on-screen `BrowserWindowController` window: the
/// window chrome (outerHeight − innerHeight) and the screen position are what a user's window has.
/// A temporary vault and ephemeral profiles are used; nothing is left behind.
///
/// Spec (JSON): {"window": {"width": W, "height": H},
///               "profiles": [{"name": "default"}, {"name": "shimmed", "timeZone": "host", "webRTC": "relayOnly"},
///                            {"name": "proxied", "proxy": {"kind": "socks5", "host": "127.0.0.1", "port": 1080}},
///                            {"name": "relayed", "proxy": {…socks5…}, "webRTC": "unrestricted", "relay": "harness"}],
///               "pages": [{"name": "…", "url": "…", "script": "<async function body>", "settleMs": 0,
///                          "timeoutMs": 60000, "extraTabs": 0}]}
/// A page script is the body of an async function; its result is serialised with JSON.stringify.
/// Output: <out-dir>/<profile>.json = {"<page>": result or {"error": "…"}}.
@MainActor
final class SiteCapture {
    struct Spec: Decodable {
        struct Window: Decodable { var width: Double; var height: Double }
        struct Profile: Decodable {
            var name: String
            /// An IANA zone, or "host" for this Mac's own zone (the shim then runs with native values).
            var timeZone: String?
            var webRTC: String?
            var geolocation: [Double]?
            /// `ProxySettings.Kind` raw value, host and port.
            var proxy: Proxy?
            /// "harness": WebRTC through the packet tunnel's TURN server and SOCKS5 relay, run on a
            /// UDP socket of this Mac instead of in the extension (`TURNUDPHost`) — what CI can run.
            var relay: String?
        }
        struct Proxy: Decodable { var kind: String; var host: String; var port: Int }
        struct Page: Decodable {
            var name: String
            var url: String
            var script: String
            var settleMs: Int?
            var timeoutMs: Int?
            /// Background tabs opened before the script runs (Safari shows its tab bar from two tabs on).
            var extraTabs: Int?
        }
        var window: Window
        var profiles: [Profile]
        var pages: [Page]
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--capture-sites"), arguments.count > index + 2 else {
            print("usage: PrivacyBrowser --capture-sites <spec.json> <out-dir>")
            exit(64)
        }
        let specPath = arguments[index + 1], outPath = arguments[index + 2]
        let app = NSApplication.shared
        // Windows on screen (as a user's), no Dock icon or menu bar of our own.
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) {
            print("CAPTURE TIMEOUT after 900 s")
            exit(3)
        }
        Task { @MainActor in
            do {
                let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
                try await SiteCapture().run(spec, out: URL(fileURLWithPath: outPath))
                print("CAPTURE DONE")
                exit(0)
            } catch {
                print("CAPTURE FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
        app.run()
    }

    private func run(_ spec: Spec, out: URL) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "capture", iterations: 10_000))
        print("INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version), zone \(TimeZone.current.identifier)")
        for profileSpec in spec.profiles {
            let results = try await capture(profileSpec, spec: spec, repository: repository)
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent("\(profileSpec.name).json"))
        }
    }

    private func configuration(for profile: Spec.Profile) -> ProfileConfiguration {
        var configuration = ProfileConfiguration(ephemeral: true)
        if let zone = profile.timeZone {
            configuration.timeZoneIdentifier = zone == "host" ? TimeZone.current.identifier : zone
        }
        if let policy = profile.webRTC.flatMap(WebRTCPolicy.init(rawValue:)) { configuration.webRTCPolicy = policy }
        if let point = profile.geolocation, point.count == 3 {
            configuration.geolocation = .fixed(latitude: point[0], longitude: point[1], accuracyMeters: point[2])
        }
        if let proxy = profile.proxy, let kind = ProxySettings.Kind(rawValue: proxy.kind) {
            configuration.proxy = ProxySettings(kind: kind, host: proxy.host, port: proxy.port)
        }
        return configuration
    }

    private func capture(_ profileSpec: Spec.Profile, spec: Spec, repository: ProfileRepository) async throws -> [String: Any] {
        let summary = try repository.create(name: "Capture \(profileSpec.name)", configuration: configuration(for: profileSpec))
        defer { try? repository.delete(summary.id) }
        let key = try repository.profileKey(for: summary.id)
        var configuration = try repository.loadConfiguration(summary.id, key: key)
        let library = ProfileLibrary(
            history: try repository.historyStore(for: summary.id, key: key, policy: configuration.historyPolicy, persistent: false),
            bookmarks: try repository.bookmarkStore(for: summary.id, key: key),
            recordsHistory: false)
        // As a launch does (ProfileManager.launch): the rules a proxied profile's web views get.
        if configuration.proxy != nil { await ContentRules.prepare() }
        var relayHost: TURNUDPHost?
        if profileSpec.relay == "harness" {
            relayHost = try startRelayHarness(for: configuration)
            configuration.webRTCRelay = relayHost.map { WebRTCRelay(urls: [$0.turnURL], username: $0.route.username, credential: $0.route.password) }
        }
        defer { relayHost?.stop() }
        let session = try BrowserSession(profileID: summary.id, profileName: summary.name, configuration: configuration,
                                         passwordVault: try repository.passwordVault(for: summary.id), library: library)
        defer { session.shutDown() }
        let controller = session.openWindow(url: nil)
        // 60 pt from the screen's top-left corner, where live_compare.py puts Safari's window too
        // (WebDriver window rects are top-left based, AppKit frames bottom-left).
        let screen = controller.window?.screen?.frame ?? NSScreen.main?.frame ?? .zero
        controller.window?.setFrame(NSRect(x: screen.minX + 60, y: screen.maxY - 60 - spec.window.height,
                                           width: spec.window.width, height: spec.window.height), display: true)

        var results: [String: Any] = [:]
        for page in spec.pages {
            print("INFO [\(profileSpec.name)] \(page.name): \(page.url)")
            do {
                results[page.name] = try await run(page, in: controller)
            } catch {
                print("INFO [\(profileSpec.name)] \(page.name) failed: \(error.localizedDescription)")
                results[page.name] = ["error": error.localizedDescription]
            }
            // Back to a single tab for the next page.
            while controller.tabCount > 1 { controller.closeTab(at: controller.tabCount - 1) }
        }
        return results
    }

    private let relayQueue = DispatchQueue(label: "PrivacyBrowser.capture.relay")

    /// The packet tunnel's relay outside the tunnel: the TURN server on this Mac's primary IPv4
    /// address, relaying through the profile's SOCKS5 proxy exactly as the extension does.
    private func startRelayHarness(for configuration: ProfileConfiguration) throws -> TURNUDPHost {
        guard let proxy = configuration.proxy, proxy.kind == .socks5, let port = UInt16(exactly: proxy.port) else {
            throw Failure("the relay harness needs a SOCKS5 proxy")
        }
        guard let address = TURNUDPHost.primaryIPv4() else { throw Failure("no IPv4 interface for the relay harness") }
        let route = TunnelRoute(id: UUID().uuidString, relayIPv4: address, relayIPv6: TunnelAddressing.relayIPv6(slot: 0),
                                username: "capture", password: UUID().uuidString,
                                proxy: SOCKSProxy(host: proxy.host, port: port, username: proxy.username, password: proxy.password))
        let host = try TURNUDPHost(route: route, bindTo: address, queue: relayQueue,
                                   relays: SOCKS5RelayFactory(queue: relayQueue, log: { print("INFO relay: \($0)") }),
                                   log: { print("INFO turn: \($0)") })
        print("INFO relay harness at \(host.turnURL)")
        return host
    }

    private func run(_ page: Spec.Page, in controller: BrowserWindowController) async throws -> Any {
        guard let url = URL(string: page.url), let tab = controller.selectedTab else { throw Failure("no tab or bad URL") }
        let timeout = TimeInterval(page.timeoutMs ?? 60_000) / 1000
        tab.load(url)
        try await Task.sleep(nanoseconds: 300_000_000)
        let deadline = Date().addingTimeInterval(timeout)
        while tab.webView.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if tab.webView.isLoading { throw Failure("page did not finish loading in \(Int(timeout)) s") }
        for _ in 0..<(page.extraTabs ?? 0) {
            controller.addTab(url: nil, select: false, afterSelected: false)
        }
        if let settle = page.settleMs, settle > 0 { try await Task.sleep(nanoseconds: UInt64(settle) * 1_000_000) }
        let body = "const __value = await (async () => {\n" + page.script + "\n})();\nreturn JSON.stringify(__value === undefined ? null : __value);"
        let value = try await evaluate(body, in: tab.webView, timeout: timeout)
        guard let text = value as? String, let data = text.data(using: .utf8) else { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func evaluate(_ body: String, in webView: WKWebView, timeout: TimeInterval) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            var answered = false
            let answer: (Result<Any?, Error>) -> Void = { result in
                guard !answered else { return }
                answered = true
                continuation.resume(with: result)
            }
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                answer(result.map { $0 as Any? })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                answer(.failure(Failure("script did not finish in \(Int(timeout)) s")))
            }
        }
    }
}
