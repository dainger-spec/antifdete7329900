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
        DispatchQueue.main.asyncAfter(deadline: .now() + 280) {
            print("PAYMENTS-CHECK TIMEOUT after 280 s")
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
        let reported = await waitForReport(of: page, timeout: 120)
        print("PAYMENTS-CHECK \(variant.rawValue): the page \(reported ? "reported" : "did not report within 120 s")")
        window?.close()
        window = nil
        try? await manager.stop(profile.id)
        return reported ? 0 : 1
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
