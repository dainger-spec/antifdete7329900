import AppKit
import BrowserCore
import os
import WebKit

/// What a tab needs from its window.
@MainActor
protocol BrowserTabHost: AnyObject {
    var hostWindow: NSWindow? { get }
    /// Title, URL, loading or back/forward state changed.
    func tabDidChange(_ tab: BrowserTab)
    /// `window.open` / `target=_blank`: WebKit requires a web view built from `configuration`.
    func tab(_ tab: BrowserTab, createTabWith configuration: WKWebViewConfiguration) -> WKWebView?
    /// ⌘-click / middle-click: open `request` in a new background tab.
    func tab(_ tab: BrowserTab, openInBackground request: URLRequest)
    func tabDidRequestClose(_ tab: BrowserTab)
    /// A dialog (alert/confirm/auth/permission) is about to be shown for this tab.
    func tabNeedsAttention(_ tab: BrowserTab)
}

/// Per-profile services every tab of a session shares.
@MainActor
struct BrowserTabContext {
    let profileID: UUID
    let profileName: String
    /// A full custom User-Agent (iPhone/iPad/custom modes); nil keeps WebKit's, completed by the
    /// configuration's `applicationNameForUserAgent` (Safari for Mac).
    let userAgent: String?
    let proxyConfigured: Bool
    let passwordVault: PasswordVault
    let library: ProfileLibrary
    let downloads: DownloadsController
    let onLoadFinished: () -> Void
    let onLoadFailed: (UserFacingMessage) -> Void
}

/// One tab: a `WKWebView` and its navigation, UI and download delegates.
///
/// All tabs of all windows of a profile share the profile's `WKWebsiteDataStore` (through the
/// configuration created by `BrowserSession`), so they share cookies and storage — exactly
/// like tabs of one browser profile. Tabs of different profiles never share anything.
@MainActor
final class BrowserTab: NSObject {
    let id = UUID()
    let webView: WKWebView
    weak var host: BrowserTabHost?

    private let context: BrowserTabContext
    private var observations: [NSKeyValueObservation] = []
    private var lastRecordedURL: URL?
    private var tornDown = false
    /// A restored tab that has not been shown yet: loads when first selected.
    private var pending: SessionState.Tab?
    /// The address of the page that failed to load (the error page itself is about:blank).
    private(set) var failedURL: URL?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserTab")

    init(configuration: WKWebViewConfiguration, context: BrowserTabContext, pending: SessionState.Tab? = nil) {
        self.context = context
        self.pending = pending
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // NATIVE: sets the User-Agent header and navigator.userAgent for this view.
        // FINGERPRINTING LIMITATION: navigator.platform/vendor, the supported feature set and the
        // TLS/HTTP2 fingerprint still identify WebKit on macOS; a non-WebKit UA is inconsistent.
        webView.customUserAgent = context.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observe()
    }

    // MARK: State

    var displayTitle: String {
        if let pending { return pending.title.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: pending.url)?.host ?? pending.url }
        if failedURL != nil, let host = failedURL?.host { return host }
        if let title = webView.title, !title.isEmpty { return title }
        if let host = webView.url?.host { return host }
        return L("tab.newTab")
    }

    /// What the address bar shows and what history, bookmarks and the saved session use.
    var url: URL? {
        if let pending { return URL(string: pending.url) }
        return failedURL ?? webView.url
    }

    var isLoading: Bool { webView.isLoading }
    var estimatedProgress: Double { webView.estimatedProgress }
    var isSecure: Bool { failedURL == nil && webView.url?.scheme?.lowercased() == "https" && webView.hasOnlySecureContent }

    /// The tab as the saved session stores it.
    var sessionTab: SessionState.Tab? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return SessionState.Tab(url: url.absoluteString, title: pending?.title ?? webView.title)
    }

    func load(_ url: URL) {
        pending = nil
        failedURL = nil
        webView.load(URLRequest(url: url))
    }

    /// Restored tabs load the first time they are shown.
    func loadPendingIfNeeded() {
        guard let pending else { return }
        self.pending = nil
        if let url = URL(string: pending.url) { load(url) }
    }

    private func observe() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let url = webView.url { self.context.library.updateTitle(url: url, title: webView.title) }
                    self.notifyChanged()
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Full loads are recorded in didCommit. This catches same-document navigations
                    // (history.pushState, fragments): their URL is already the back/forward list's
                    // current item, whereas a provisional (not yet committed) URL is not.
                    if let url = webView.url, webView.backForwardList.currentItem?.url == url {
                        self.recordVisit(url)
                    }
                    self.notifyChanged()
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChanged() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChanged() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChanged() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChanged() }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notifyChanged() }
            },
        ]
    }

    private func notifyChanged() {
        host?.tabDidChange(self)
    }

    private func recordVisit(_ url: URL) {
        guard url != lastRecordedURL else { return }
        lastRecordedURL = url
        context.library.recordVisit(url: url, title: webView.title)
    }

    /// Stops all activity and breaks reference cycles so the web view — and with it the
    /// profile's data store — can be deallocated.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        host = nil
    }

    // MARK: Dialog helpers

    private func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        host?.tabNeedsAttention(self)
        guard let window = host?.hostWindow else {
            completion(.cancel)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        presentAlert(alert) { _ in }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let flags = navigationAction.modifierFlags
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else if navigationAction.navigationType == .linkActivated,
                  flags.contains(.command) || navigationAction.buttonNumber == 2,
                  ["http", "https"].contains(scheme) {
            host?.tab(self, openInBackground: navigationAction.request)
            decisionHandler(.cancel)
        } else if ["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            // mailto:, tel:, custom app schemes: handing them to other apps would leave the
            // profile (and its proxy). Blocked; the user can copy the link instead.
            log.info("Blocked navigation to scheme \(scheme, privacy: .public)")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, url.scheme?.lowercased() != "about" {
            failedURL = nil
            recordVisit(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let scheme = webView.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            context.onLoadFinished()
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        context.downloads.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        context.downloads.adopt(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorPage(for: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Fails after commit (connection dropped mid-page): keep what is shown, report only.
        if let message = UserFacingError.message(for: error, proxyConfigured: context.proxyConfigured) {
            context.onLoadFailed(message)
        }
    }

    /// A page that says what went wrong in plain words, with a Try Again link. With a proxy and
    /// failover disabled, an unreachable proxy surfaces here and is reported as a proxy problem.
    private func showErrorPage(for error: Error) {
        guard let message = UserFacingError.message(for: error, proxyConfigured: context.proxyConfigured) else { return }
        let failing = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        Log.notice("load", "\(Log.id(context.profileID)): \(message.technical)")
        context.onLoadFailed(message)
        failedURL = failing.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let html = ErrorPage.html(title: L(message.titleKey), message: L(message.messageKey),
                                  retryURL: failedURL, retryLabel: L("errorpage.retry"),
                                  details: message.technical, hint: message.kind == .proxy ? L("errorpage.proxyHint") : nil)
        webView.loadHTMLString(html, baseURL: nil)
        notifyChanged()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let httpAuth = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod)
        guard httpAuth, !space.isProxy(), let scheme = space.protocol,
              let url = URL(string: "\(scheme)://\(space.host):\(space.port)") else {
            // Server trust, client certificates, proxy auth (handled by ProxyConfiguration): system default.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if challenge.previousFailureCount == 0, let entry = context.passwordVault.entries(for: url).first {
            completionHandler(.useCredential, URLCredential(user: entry.username, password: entry.password, persistence: .forSession))
            return
        }
        promptForHTTPCredentials(host: space.host, realm: space.realm) { credential in
            if let credential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process terminated; reloading")
        webView.reload()
    }

    private func promptForHTTPCredentials(host: String, realm: String?, completion: @escaping (URLCredential?) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(format: L("auth.login"), host)
        alert.informativeText = realm.map { String(format: L("auth.realm"), $0) } ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = L("passwords.placeholder.username")
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = L("passwords.placeholder.password")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(user)
        accessory.addSubview(pass)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("auth.logIn"))
        alert.addButton(withTitle: L("common.cancel"))
        presentAlert(alert) { response in
            completion(response == .alertFirstButtonReturn
                       ? URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession)
                       : nil)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.tab(self, createTabWith: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.tabDidRequestClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        presentAlert(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        presentAlert(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        presentAlert(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// File inputs. In the App Sandbox the open panel grants read access to the chosen files
    /// (entitlement `com.apple.security.files.user-selected.read-write`).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        host?.tabNeedsAttention(self)
        guard let window = host?.hostWindow else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// Camera / microphone: ask every time (WebKit forwards the request only after the page called getUserMedia).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String
        switch type {
        case .camera: what = L("media.camera")
        case .microphone: what = L("media.microphone")
        case .cameraAndMicrophone: what = L("media.cameraAndMic")
        @unknown default: what = L("media.devices")
        }
        let alert = NSAlert()
        alert.messageText = String(format: L("media.allow"), origin.host, what)
        alert.informativeText = String(format: L("media.note"), context.profileName)
        alert.addButton(withTitle: L("media.allowButton"))
        alert.addButton(withTitle: L("media.denyButton"))
        presentAlert(alert) { decisionHandler($0 == .alertFirstButtonReturn ? .grant : .deny) }
    }
}
