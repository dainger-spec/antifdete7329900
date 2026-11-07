// Lumen iOS — stage 1 measurement driver (branch claude/ios-app-measure, never merged).
//
// Not product code. A remote-controlled set of WKWebViews: the host harness
// (ios-measure/host/harness.py) hands it one command at a time over plain HTTP and gets the
// result back. The app decides nothing by itself, so one build serves every question of stage 1
// (proxy per data store, fingerprint scripts, Telegram) without rebuilding.
//
// Commands (JSON, from GET <control>/next): info, session, load, eval, setProxy, cookies, close,
// sleep, exit. See harness.py for their exact fields.

import Network
import UIKit
import WebKit

// MARK: - App lifecycle (UIScene: required when building with the iOS 27 SDK)

@objc(LMAppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@objc(LMSceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        let label = UILabel(frame: CGRect(x: 12, y: 60, width: 380, height: 60))
        label.numberOfLines = 0
        label.textColor = .white
        label.text = "Lumen measure driver\n" + Driver.shared.controlURL.absoluteString
        root.view.addSubview(label)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        Driver.shared.attach(to: root.view)
        Driver.shared.start()
    }
}

// MARK: - Driver

@MainActor
final class Driver: NSObject {
    static let shared = Driver()

    /// Where the harness listens. Simulator: the Mac's loopback (a simulated device shares it).
    /// A real iPhone: the Mac's address on the local network, passed by `devicectl … --environment-variables`
    /// or typed into the launch arguments (`-control http://192.168.1.10:28310`).
    let controlURL: URL = {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        var found: URL?
        if let value = env["LUMEN_CONTROL"], let url = URL(string: value) { found = url }
        if found == nil, let i = args.firstIndex(of: "-control"), i + 1 < args.count { found = URL(string: args[i + 1]) }
        // A real iPhone may be relaunched by hand: it keeps the last address it was given.
        if let found { UserDefaults.standard.set(found.absoluteString, forKey: "lumenControl"); return found }
        if let saved = UserDefaults.standard.string(forKey: "lumenControl"), let url = URL(string: saved) { return url }
        return URL(string: "http://127.0.0.1:28310")!
    }()

    private var container: UIView?
    private var sessions: [String: Session] = [:]
    /// The control channel never goes through a session's proxy: its own ephemeral URLSession.
    private lazy var control: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    func attach(to view: UIView) { container = view }

    func start() {
        log("driver up, control \(controlURL.absoluteString)")
        Task { await self.loop() }
    }

    func log(_ text: String) { print("LUMEN-DRIVER " + text) }

    @MainActor
    private func loop() async {
        var hello = true
        while true {
            do {
                var request = URLRequest(url: controlURL.appendingPathComponent(hello ? "hello" : "next"))
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: hello ? Self.info() : [:])
                hello = false
                let (data, response) = try await control.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                guard let command = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // Each command runs on its own: a load that waits does not hold the next command
                // (two sessions load at the same moment when the harness asks for it).
                Task { await self.handle(command) }
            } catch {
                log("control error: \(error)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func handle(_ command: [String: Any]) async {
        let id = command["id"] as? String ?? "?"
        let started = Date()
        var result: [String: Any]
        do {
            result = try await run(command)
        } catch {
            result = ["error": String(describing: error)]
        }
        result["id"] = id
        result["ms"] = Int(Date().timeIntervalSince(started) * 1000)
        for attempt in 0..<5 {
            do {
                var post = URLRequest(url: controlURL.appendingPathComponent("result"))
                post.httpMethod = "POST"
                post.httpBody = try JSONSerialization.data(withJSONObject: Self.jsonSafe(result))
                _ = try await control.data(for: post)
                break
            } catch {
                log("result \(id) not delivered (attempt \(attempt)): \(error)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        if command["op"] as? String == "exit" { exit(0) }
    }

    // MARK: Commands

    @MainActor
    private func run(_ c: [String: Any]) async throws -> [String: Any] {
        switch c["op"] as? String ?? "" {
        case "info":
            return Self.info()
        case "session":
            return try makeSession(c)
        case "load":
            let session = try find(c)
            return await session.load(c["url"] as? String ?? "about:blank", timeout: c["timeout"] as? Double ?? 20)
        case "html":
            let session = try find(c)
            return await session.loadHTML(c["html"] as? String ?? "", base: c["base"] as? String, timeout: c["timeout"] as? Double ?? 20)
        case "eval":
            let session = try find(c)
            return await session.evaluate(c["js"] as? String ?? "null", world: c["world"] as? String ?? "page",
                                          frameURL: c["frame"] as? String)
        case "setProxy":
            let session = try find(c)
            return session.setProxies(c["proxies"] as? [[String: Any]] ?? [])
        case "cookies":
            let session = try find(c)
            return await session.cookies()
        case "close":
            if let id = c["session"] as? String, let session = sessions.removeValue(forKey: id) { session.close() }
            return ["closed": true]
        case "dropView":
            // Releases the web view but keeps the store object: the next "session" with the same
            // store id builds a fresh web view on it (isolation of a store across web views).
            let session = try find(c)
            session.close()
            return ["dropped": true]
        case "defaults":
            // The app's own preferences, e.g. AppleLanguages: does a web view made afterwards speak
            // another language without the app being relaunched?
            let key = c["key"] as? String ?? ""
            if let value = c["value"] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            UserDefaults.standard.synchronize()
            return ["key": key, "now": UserDefaults.standard.object(forKey: key).map { String(describing: $0) } ?? NSNull(),
                    "preferredLanguages": Locale.preferredLanguages, "timeZone": TimeZone.current.identifier]
        case "sleep":
            try await Task.sleep(nanoseconds: UInt64((c["seconds"] as? Double ?? 1) * 1e9))
            return ["slept": true]
        case "exit":
            return ["bye": true]
        default:
            throw DriverError.message("unknown op \(c["op"] ?? "nil")")
        }
    }

    private var stores: [String: WKWebsiteDataStore] = [:]

    @MainActor
    private func makeSession(_ c: [String: Any]) throws -> [String: Any] {
        guard let id = c["session"] as? String, let container else { throw DriverError.message("no session id") }
        sessions.removeValue(forKey: id)?.close()
        var notes: [String: Any] = [:]
        let storeSpec = c["store"] as? String ?? "ephemeral"
        let store: WKWebsiteDataStore
        if let existing = stores[storeSpec] {
            store = existing
            notes["store"] = "reused"
        } else if storeSpec.hasPrefix("persistent:") {
            if #available(iOS 17.0, *) {
                let uuid = UUID(uuidString: String(storeSpec.dropFirst("persistent:".count))) ?? UUID()
                store = WKWebsiteDataStore(forIdentifier: uuid)
                notes["store"] = "forIdentifier"
            } else {
                throw DriverError.message("WKWebsiteDataStore(forIdentifier:) needs iOS 17")
            }
        } else if storeSpec == "default" {
            store = .default()
            notes["store"] = "default"
        } else {
            store = .nonPersistent()
            notes["store"] = "nonPersistent"
        }
        stores[storeSpec] = store

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.allowsInlineMediaPlayback = true
        if let bound = c["limitsNavigationsToAppBoundDomains"] as? Bool {
            configuration.limitsNavigationsToAppBoundDomains = bound
        }
        let controller = WKUserContentController()
        for script in c["userScripts"] as? [[String: Any]] ?? [] {
            let source = script["source"] as? String ?? ""
            let atEnd = (script["injectionTime"] as? String) == "end"
            let mainOnly = script["mainFrameOnly"] as? Bool ?? false
            let world: WKContentWorld = (script["world"] as? String) == "isolated" ? .defaultClient : .page
            controller.addUserScript(WKUserScript(source: source, injectionTime: atEnd ? .atDocumentEnd : .atDocumentStart,
                                                  forMainFrameOnly: mainOnly, in: world))
        }
        configuration.userContentController = controller

        let session = Session(id: id, store: store, configuration: configuration, driver: self)
        session.answerProxyAuth = c["answerProxyAuth"] as? Bool ?? true
        session.trustTestCertificates = c["trustTestCertificates"] as? Bool ?? true
        if let proxies = c["proxies"] as? [[String: Any]] {
            notes["proxy"] = session.setProxies(proxies)
        }
        let view = session.makeView(in: container, customUserAgent: c["userAgent"] as? String,
                                    inspectable: c["inspectable"] as? Bool ?? true)
        _ = view
        sessions[id] = session
        notes["session"] = id
        return notes
    }

    @MainActor
    private func find(_ c: [String: Any]) throws -> Session {
        guard let id = c["session"] as? String, let session = sessions[id] else {
            throw DriverError.message("no such session \(c["session"] ?? "nil")")
        }
        return session
    }

    static func info() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let env = ProcessInfo.processInfo.environment
        var info: [String: Any] = [
            "os": UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            "osBuild": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": UIDevice.current.model,
            "machine": machine,
            "simulator": env["SIMULATOR_DEVICE_NAME"] ?? NSNull(),
            "simulatorRuntime": env["SIMULATOR_RUNTIME_VERSION"] ?? NSNull(),
            "preferredLanguages": Locale.preferredLanguages,
            "timeZone": TimeZone.current.identifier,
            "processorCount": ProcessInfo.processInfo.activeProcessorCount,
            "bundle": Bundle.main.bundleIdentifier ?? "?",
            "appBoundDomains": Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") ?? NSNull(),
            // The runtime's own answer, independent of what this binary was compiled against.
            "storeRespondsToSetProxyConfigurations": WKWebsiteDataStore.instancesRespond(to: NSSelectorFromString("setProxyConfigurations:")),
            "storeRespondsToDataStoreForIdentifier": WKWebsiteDataStore.responds(to: NSSelectorFromString("dataStoreForIdentifier:")),
        ]
        if #available(iOS 17.0, *) {
            let probe = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: 9))
            info["proxyConfigurationDefaultAllowFailover"] = probe.allowFailover
        }
        return info
    }

    /// JSONSerialization refuses NaN, infinities and arbitrary objects; turn them into strings.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues { jsonSafe($0) }
        case let a as [Any]: return a.map { jsonSafe($0) }
        case let n as Double where !n.isFinite: return String(n)
        case is String, is Int, is Double, is Bool, is NSNull: return value
        case let n as NSNumber: return n
        default: return String(describing: value)
        }
    }
}

enum DriverError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(text): return text }
    }
}

// MARK: - Session: one data store, its proxies, one web view

@MainActor
final class Session: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let store: WKWebsiteDataStore
    let configuration: WKWebViewConfiguration
    weak var driver: Driver?
    var webView: WKWebView?
    var answerProxyAuth = true
    var trustTestCertificates = true
    private var pending: CheckedContinuation<[String: Any], Never>?
    private var challenges: [[String: Any]] = []
    private var proxyCredential: URLCredential?

    init(id: String, store: WKWebsiteDataStore, configuration: WKWebViewConfiguration, driver: Driver) {
        self.id = id
        self.store = store
        self.configuration = configuration
        self.driver = driver
    }

    @MainActor
    func makeView(in container: UIView, customUserAgent: String?, inspectable: Bool) -> WKWebView {
        // A real phone screen's size, in the window (hidden web views are throttled less when in a window).
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: container.bounds.width, height: container.bounds.height),
                             configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        if let customUserAgent { view.customUserAgent = customUserAgent }
        if #available(iOS 16.4, *) { view.isInspectable = inspectable }
        container.addSubview(view)
        webView = view
        return view
    }

    @MainActor
    func setProxies(_ specs: [[String: Any]]) -> [String: Any] {
        guard #available(iOS 17.0, *) else {
            return ["applied": false, "reason": "WKWebsiteDataStore.proxyConfigurations needs iOS 17"]
        }
        var configurations: [ProxyConfiguration] = []
        var described: [String] = []
        proxyCredential = nil
        for spec in specs {
            let host = spec["host"] as? String ?? "127.0.0.1"
            let port = NWEndpoint.Port(rawValue: UInt16(spec["port"] as? Int ?? 1)) ?? 1
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            var configuration: ProxyConfiguration
            if (spec["type"] as? String) == "socks5" {
                configuration = ProxyConfiguration(socksv5Proxy: endpoint)
            } else {
                configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
            }
            if let user = spec["user"] as? String, let pass = spec["pass"] as? String {
                if spec["applyCredential"] as? Bool ?? true {
                    configuration.applyCredential(username: user, password: pass)
                }
                proxyCredential = URLCredential(user: user, password: pass, persistence: .forSession)
            }
            if let failover = spec["allowFailover"] as? Bool { configuration.allowFailover = failover }
            if let excluded = spec["excludedDomains"] as? [String] { configuration.excludedDomains = excluded }
            if let match = spec["matchDomains"] as? [String] { configuration.matchDomains = match }
            configurations.append(configuration)
            described.append("\(spec["type"] ?? "http")://\(host):\(port) failover=\(configuration.allowFailover)")
        }
        store.proxyConfigurations = configurations
        return ["applied": true, "count": store.proxyConfigurations.count, "proxies": described]
    }

    @MainActor
    func load(_ address: String, timeout: Double) async -> [String: Any] {
        guard let webView, let url = URL(string: address) else { return ["ok": false, "error": "no view or bad url"] }
        challenges = []
        return await waitForNavigation(timeout: timeout) { webView.load(URLRequest(url: url)) }
    }

    @MainActor
    func loadHTML(_ html: String, base: String?, timeout: Double) async -> [String: Any] {
        guard let webView else { return ["ok": false, "error": "no view"] }
        challenges = []
        return await waitForNavigation(timeout: timeout) { webView.loadHTMLString(html, baseURL: base.flatMap(URL.init(string:))) }
    }

    @MainActor
    private func waitForNavigation(timeout: Double, start: () -> Void) async -> [String: Any] {
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            self.finish(["ok": false, "error": "timeout after \(timeout)s"])
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            pending = continuation
            start()
        }
        timer.cancel()
        var out = result
        out["challenges"] = challenges
        out["url"] = webView?.url?.absoluteString ?? NSNull()
        return out
    }

    @MainActor
    private func finish(_ result: [String: Any]) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(returning: result)
    }

    @MainActor
    func evaluate(_ body: String, world: String, frameURL: String?) async -> [String: Any] {
        guard let webView else { return ["ok": false, "error": "no view"] }
        // The body is an async function body; its value comes back as JSON text.
        let wrapped = "return JSON.stringify(await (async () => {\n" + body + "\n})());"
        let contentWorld: WKContentWorld = world == "isolated" ? .defaultClient : .page
        do {
            let value = try await webView.callAsyncJavaScript(wrapped, arguments: [:], in: nil, contentWorld: contentWorld)
            if let text = value as? String, let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return ["ok": true, "value": parsed]
            }
            return ["ok": true, "value": value.map { String(describing: $0) } ?? NSNull()]
        } catch {
            let ns = error as NSError
            return ["ok": false, "error": ns.localizedDescription, "detail": String(describing: ns.userInfo)]
        }
    }

    @MainActor
    func cookies() async -> [String: Any] {
        let cookies = await store.httpCookieStore.allCookies()
        return ["cookies": cookies.map { ["name": $0.name, "value": $0.value, "domain": $0.domain] }]
    }

    @MainActor
    func close() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(["ok": true])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        finish(["ok": false, "error": ns.localizedDescription, "code": ns.code, "domain": ns.domain])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        finish(["ok": false, "error": ns.localizedDescription, "code": ns.code, "domain": ns.domain])
    }

    // The async form of webView(_:didReceive:completionHandler:): its Swift signature is the same in
    // every SDK, so it is never left out as a near miss (the completion-handler form was, in run 1).
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        var record: [String: Any] = ["host": space.host, "port": space.port, "method": space.authenticationMethod,
                                     "isProxy": space.isProxy(), "previousFailures": challenge.previousFailureCount]
        defer {
            challenges.append(record)
            driver?.log("challenge \(record)")
        }
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Only the harness's own self-signed names; everything else the system's default way.
            if trustTestCertificates, space.host.hasSuffix(".lumentest"), let trust = space.serverTrust {
                record["answer"] = "trusted test certificate"
                return (.useCredential, URLCredential(trust: trust))
            }
            record["answer"] = "default"
            return (.performDefaultHandling, nil)
        }
        if space.isProxy() {
            if answerProxyAuth, challenge.previousFailureCount == 0, let credential = proxyCredential {
                record["answer"] = "credential"
                return (.useCredential, credential)
            }
            record["answer"] = "cancel"
            return (.cancelAuthenticationChallenge, nil)
        }
        record["answer"] = "default"
        return (.performDefaultHandling, nil)
    }

    // MARK: WKUIDelegate: a page's window.open stays in the same session (no new view needed here)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}
