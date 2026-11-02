import BrowserCore
import SwiftUI
import WebKit

/// The robot check a sign-in needs after `403 robot_check` (the server's `docs/CONTRACT.md` §5.5):
/// the site's page `/robot-check?action=login` — Cloudflare Turnstile and nothing else — in a web
/// view of the app's own process with a store of its own that keeps nothing (no cookies of any
/// browser, none of a profile, nothing on disk). The page hands its token over through
/// `window.webkit.messageHandlers.lumenRobotCheck.postMessage(token)`; the sheet closes and the
/// sign-in is sent again with it. The token is good for one request and is held nowhere else.
///
/// Only the site's own page is listened to: its main frame, at the site's origin. The main frame
/// never leaves that origin; nothing opens a window; what is not the site's is not loaded in it.
struct RobotCheckSheet: View {
    /// The site's page, with the action (`RobotCheck.pageURL`).
    let url: URL
    let onToken: (String) -> Void
    let onCancel: () -> Void
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("license.robot.title"))
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
            Text(L("license.robot.subtitle"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RobotCheckWebView(url: url, onToken: onToken, onFailure: { failed = true })
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if failed {
                Label(L("license.robot.failed"), systemImage: "exclamationmark.circle")
                    .font(.lumenBody)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("license.account.cancel"), action: onCancel)
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.raised)
        .environment(\.colorScheme, .dark)
    }
}

/// What the robot check takes from the site, decided apart from the web view (and checked so).
enum RobotCheck {
    /// The message handler's name, as the contract gives it (§5.5).
    static let handlerName = "lumenRobotCheck"

    /// `<site>/robot-check?action=login`.
    static func pageURL(site: URL, action: String = "login") -> URL? {
        var components = URLComponents(url: site, resolvingAgainstBaseURL: false)
        let base = components?.path ?? ""
        components?.path = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/robot-check"
        components?.queryItems = [URLQueryItem(name: "action", value: action)]
        components?.fragment = nil
        return components?.url
    }

    /// The same scheme, host and port as the site: the only page whose message is taken, the only
    /// place the main frame may go.
    static func sameOrigin(_ url: URL, as site: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        return scheme == site.scheme?.lowercased() && host == site.host?.lowercased() && port(url) == port(site)
    }

    static func sameOrigin(_ origin: WKSecurityOrigin, as site: URL) -> Bool {
        let port = origin.port == 0 ? defaultPort(origin.protocol) : origin.port
        return origin.protocol.lowercased() == site.scheme?.lowercased() && origin.host.lowercased() == site.host?.lowercased()
            && port == Self.port(site)
    }

    /// A Turnstile token as a page may hand it over: text, not too long, nothing but the characters
    /// such tokens are made of. Anything else is not taken.
    static func isToken(_ value: Any) -> Bool {
        guard let text = value as? String, (1...4_096).contains(text.utf8.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.:")
        return text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The check's web view: a store of its own that keeps nothing (no cookies, no cache, no
    /// storage that outlives it), the coordinator listening and deciding where it may go. The sheet's
    /// and the self-test's are made here alike.
    static func makeWebView(loading url: URL, coordinator: RobotCheckCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: handlerName)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.load(URLRequest(url: url))
        return view
    }

    private static func port(_ url: URL) -> Int { url.port ?? defaultPort(url.scheme ?? "") }

    private static func defaultPort(_ scheme: String) -> Int {
        switch scheme.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return 0
        }
    }
}

private struct RobotCheckWebView: NSViewRepresentable {
    let url: URL
    let onToken: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> RobotCheckCoordinator {
        RobotCheckCoordinator(site: url, onToken: onToken, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        RobotCheck.makeWebView(loading: url, coordinator: context.coordinator)
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: RobotCheckCoordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: RobotCheck.handlerName)
    }
}

@MainActor
final class RobotCheckCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private let site: URL
    private let onToken: (String) -> Void
    private let onFailure: () -> Void
    /// One token per page: a second message is not a second sign-in.
    private var delivered = false

    init(site: URL, onToken: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        self.site = site
        self.onToken = onToken
        self.onFailure = onFailure
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !delivered, message.frameInfo.isMainFrame, RobotCheck.sameOrigin(message.frameInfo.securityOrigin, as: site),
              RobotCheck.isToken(message.body), let token = message.body as? String else { return }
        delivered = true
        onToken(token)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            // The main frame stays on the site's page.
            decisionHandler(RobotCheck.sameOrigin(url, as: site) ? .allow : .cancel)
        } else {
            // The check's own frame (Cloudflare's) over HTTPS, the site's own, or an empty one.
            let scheme = url.scheme?.lowercased()
            let allowed = scheme == "https" || RobotCheck.sameOrigin(url, as: site)
                || url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
            decisionHandler(allowed ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure()
    }

    /// No window opens from the check.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
