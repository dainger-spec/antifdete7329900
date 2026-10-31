import AppKit
import BrowserCore
import Foundation
import WebKit

/// `--payments-check --url <page> --variant <name> [--proxy host:port]`: one side of
/// `scripts/payments_check.py`, which measures what Apple Pay's, Payment Request's and Web Push's
/// calls answer in this Mac's Safari and in a profile. A measurement for the parity rule
/// (docs/ISOLATION_AND_LIMITATIONS.md §2, *Parity with Safari*): the `on-` variants turn WebKit's
/// own switches for them on in one web view of this process, made here, and nothing of it is a
/// setting of the app or reaches a profile anywhere else.
///
/// A new profile, in a vault of its own that is removed at the end, opens the script's page
/// (HTTPS, on this Mac; or HTTP on 127.0.0.1, for `scripts/fragment_check.py`, whose page jumps to
/// a fragment and says whether it was still the same document), and the process ends once the
/// script has the page's report:
///   * `shipped`: the profile as it ships, in this app's window;
///   * `shipped-safari-window`: the profile as it ships, in Safari's window (a process of its own;
///     refused when the window would not be Safari's);
///   * `on-page`: `ApplePayEnabled` and `PushAPIEnabled` on, the profile's scripts as they ship —
///     its privacy script in the page's world, AutoFill in a world of its own;
///   * `on-isolated`: the same switches, the privacy script in a world of its own and nothing in
///     the page's;
///   * `on-none`: the same switches, no script and no rule list.
@MainActor
enum PaymentsCheck {
    enum Variant: String, CaseIterable {
        case shipped
        case shippedSafariWindow = "shipped-safari-window"
        case onPage = "on-page"
        case onIsolated = "on-isolated"
        case onNone = "on-none"
        /// Measurement only (the owner's questions of 31 October): WebKit's own switches for
        /// WebTransport, Web Authentication, Digital Credentials and the MediaSession coordinator
        /// on, the profile's proxy kept; the window's UI delegate says whether WebKit asks the app to
        /// run a web authentication panel, and cancels it through WebKit's own panel; the app clicks
        /// the page every second, a user gesture for its button.
        case parity
    }

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        // HTTPS, or a page of this Mac (scripts/fragment_check.py serves its page over HTTP).
        guard let page = value("--url").flatMap(URL.init(string:)),
              page.scheme == "https" || (page.scheme == "http" && ["127.0.0.1", "localhost"].contains(page.host ?? "")),
              let variant = value("--variant").flatMap(Variant.init(rawValue:)) else {
            print("PAYMENTS-CHECK wants --url https://… (or http://127.0.0.1:…) and --variant \(Variant.allCases.map(\.rawValue).joined(separator: "|"))")
            exit(64)
        }
        let proxy: ProxySettings?
        if let text = value("--proxy") {
            guard let field = try? ProxyHostField.parse(text), let port = field.port else {
                print("PAYMENTS-CHECK --proxy wants host:port")
                exit(64)
            }
            proxy = ProxySettings(kind: .httpConnect, host: field.host, port: port)
        } else {
            proxy = nil
        }
        // Safari's window needs the profile in a process of its own; every other variant is here.
        setenv("PB_PROFILE_PROCESS", variant == .shippedSafariWindow ? "1" : "0", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 400) {
            print("PAYMENTS-CHECK TIMEOUT after 400 s")
            exit(1)
        }
        Task { @MainActor in exit(await run(page: page, variant: variant, proxy: proxy)) }
        app.run()
    }

    private static func run(page: URL, variant: Variant, proxy: ProxySettings?) async -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-payments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "payments-check", iterations: 10_000))
            profile = try repository.create(name: "Payments check", configuration: ProfileConfiguration(proxy: proxy))
        } catch {
            print("PAYMENTS-CHECK could not make a profile: \(error)")
            return 1
        }
        let manager = ProfileManager(repository: repository)
        var hostsChrome: Bool?
        manager.onProfileRunning = { _, hosts in hostsChrome = hosts }
        var window: NSWindow?
        defer { window?.close() }
        do {
            switch variant {
            case .shipped:
                try await manager.launch(profile.id, openingWindow: false)
                manager.openWindow(profile.id, url: page)
            case .shippedSafariWindow:
                try await manager.launch(profile.id)
                let deadline = Date().addingTimeInterval(90)
                while hostsChrome == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard hostsChrome == true else {
                    print("PAYMENTS-CHECK the profile's window is not Safari's (\(hostsChrome == nil ? "no answer in 90 s" : "this app's own window"))")
                    try? await manager.stop(profile.id)
                    return 1
                }
                manager.openWindow(profile.id, url: page)
            case .parity:
                try await manager.launch(profile.id, openingWindow: false)
                guard let session = manager.session(for: profile.id) else {
                    print("PAYMENTS-CHECK the profile has no session in this process")
                    return 1
                }
                let configuration = session.makeWebViewConfiguration()
                let keys = ["WebTransportEnabled", "WebAuthenticationEnabled", "DigitalCredentialsEnabled", "MediaSessionCoordinatorEnabled"]
                for key in keys { WebKitFeatures.set(configuration.preferences, key, true) }
                let states = keys.map { key in
                    "\(key) " + (WebKitFeatures.isEnabled(configuration.preferences, key).map { $0 ? "on" : "off" } ?? "unknown")
                }
                print("PAYMENTS-CHECK parity: \(states.joined(separator: ", "))")
                // Round 3: the page's marks, the trace between them, and the calls a ceremony could pass through.
                WebAuthnIntercept.install()
                configuration.userContentController.add(WebAuthnProbe.shared, name: "pbmark")
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
                view.uiDelegate = ParityPanelDelegate.shared
                let made = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                made.isReleasedWhenClosed = false
                made.contentView = view
                made.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                view.load(URLRequest(url: page))
                window = made
                // A user gesture for the page's button, which covers the page.
                Task { @MainActor in
                    for _ in 0..<170 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        Self.click(view)
                    }
                }
            case .onPage, .onIsolated, .onNone:
                try await manager.launch(profile.id, openingWindow: false)
                guard let session = manager.session(for: profile.id) else {
                    print("PAYMENTS-CHECK the profile has no session in this process")
                    return 1
                }
                let configuration = session.makeWebViewConfiguration()
                switch variant {
                case .onIsolated:
                    let controller = WKUserContentController()
                    controller.addUserScript(WKUserScript(source: PrivacyScripts.source(for: session.configuration),
                                                          injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                                          in: .world(name: "PrivacyBrowser.PaymentsCheck")))
                    configuration.userContentController = controller
                case .onNone:
                    configuration.userContentController = WKUserContentController()
                default:
                    break
                }
                for setter in ["_setApplePayEnabled:", "_setPushAPIEnabled:"] {
                    guard WebKitPreferences.setBool(configuration.preferences, setter, true) else {
                        print("PAYMENTS-CHECK this WebKit has no \(setter)")
                        try? await manager.stop(profile.id)
                        return 1
                    }
                }
                // Read back, as WebKit holds them for the web view about to be made.
                let applePay = WebKitPreferences.bool(configuration.preferences, "_applePayEnabled").map { $0 ? "on" : "off" } ?? "unknown"
                let push = WebKitPreferences.bool(configuration.preferences, "_pushAPIEnabled").map { $0 ? "on" : "off" } ?? "unknown"
                print("PAYMENTS-CHECK \(variant.rawValue): ApplePayEnabled \(applePay), PushAPIEnabled \(push)")
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
                let made = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
                made.isReleasedWhenClosed = false
                made.contentView = view
                made.orderFront(nil)
                view.load(URLRequest(url: page))
                window = made
            }
        } catch {
            print("PAYMENTS-CHECK the profile did not start: \(error)")
            return 1
        }
        let reported = await waitForReport(of: page, timeout: 240)
        print("PAYMENTS-CHECK \(variant.rawValue): the page \(reported ? "reported" : "did not report within 240 s")")
        if variant == .parity { WebAuthnProbe.shared.printTrace() }
        window?.close()
        window = nil
        try? await manager.stop(profile.id)
        return reported ? 0 : 1
    }

    /// A click in the middle of `view`, as the window would get it from the mouse.
    private static func click(_ view: WKWebView) {
        guard let window = view.window else { return }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
    }

    /// Asks the script whether the page's report has come (`/reported`, the page's own query).
    /// A page of this Mac over HTTP is asked on a socket of its own: App Transport Security lets
    /// this app's own requests use HTTP only to the self-test's names.
    private static func waitForReport(of page: URL, timeout: TimeInterval) async -> Bool {
        guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return false }
        components.path = "/reported"
        guard let url = components.url else { return false }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if url.scheme == "http", let port = url.port {
                let target = (url.path) + (url.query.map { "?" + $0 } ?? "")
                let request = Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
                let answer = await Task.detached { SelfTest.rawHTTP(port: port, request) }.value
                if let answer, String(decoding: answer, as: UTF8.self).hasSuffix("\r\n\r\nyes") { return true }
            } else if let answer = try? await session.data(from: url), String(decoding: answer.0, as: UTF8.self) == "yes" {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}

/// Measurement only: whether WebKit asks the app to run a web authentication panel — the one place
/// an app could take the ceremony before the system shows its sheet — and what the page gets when
/// the app cancels it through WebKit's own panel.
final class ParityPanelDelegate: NSObject, WKUIDelegate {
    static let shared = ParityPanelDelegate()

    @objc(_webView:runWebAuthenticationPanel:initiatedByFrame:completionHandler:)
    func runWebAuthenticationPanel(_ webView: WKWebView, panel: NSObject, frame: WKFrameInfo,
                                   completionHandler: @escaping (Int) -> Void) {
        let type = panel.responds(to: NSSelectorFromString("type")) ? "\(panel.value(forKey: "type") ?? "?")" : "?"
        print("PAYMENTS-CHECK parity: WebKit asked the app to run a web authentication panel (type \(type)), "
              + "at \(String(format: "%.3f", Date().timeIntervalSince1970))")
        completionHandler(1) // _WKWebAuthenticationPanelResultPresented
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let cancel = NSSelectorFromString("cancel")
            if panel.responds(to: cancel) {
                _ = panel.perform(cancel)
                print("PAYMENTS-CHECK parity: the app cancelled the panel through WebKit's own cancel, "
                      + "at \(String(format: "%.3f", Date().timeIntervalSince1970))")
            } else {
                print("PAYMENTS-CHECK parity: the panel has no cancel")
            }
        }
    }
}
