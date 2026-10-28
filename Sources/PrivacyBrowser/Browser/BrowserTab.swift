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
    let profileName: String
    let userAgent: String?
    let passwordVault: PasswordVault
    /// AutoFill on or off, and the sites passwords are never saved for, as they are now.
    let passwordSettings: ProfilePasswordSettings
    let library: ProfileLibrary
    /// The profile proxy's user name and password, answered to the proxy's own auth challenges.
    let proxyCredential: URLCredential?
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
    /// Sheets whose result a WebKit completion handler is waiting for (see `presentSheet`).
    private var pendingSheets: [UUID: PendingSheet] = [:]
    /// Why the profile's proxy challenge was just cancelled: shown by the error page of the
    /// navigation that fails as a result (otherwise that failure reads "cancelled" and the tab
    /// would stay blank).
    private var proxyAuthFailure: String?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserTab")

    private struct PendingSheet {
        let parent: NSWindow
        let sheet: NSWindow
        /// Answers the waiting WebKit completion handler with "cancel" (no-op once answered).
        let cancel: () -> Void
    }

    /// A dialog of this tab is waiting for the user (self-test hook).
    var hasPendingSheet: Bool { !pendingSheets.isEmpty }

    /// How many loads of this tab failed before their page came (an error page was shown
    /// instead), and why the last one did: the warm-up robot tells a failed visit by them.
    private(set) var failedNavigations = 0
    private(set) var lastNavigationError: String?
    /// Main-frame navigations whose page committed (held weakly): who started a load knows by it
    /// when its page came. The URL and `isLoading` do not always tell: a load requested while the
    /// tab's previous one is still being decided can leave the tab, for a moment, with no address
    /// and nothing loading before it starts (WebKit drops the pending request when it decides on
    /// the earlier load).
    private let committedNavigations = NSHashTable<WKNavigation>.weakObjects()
    /// Main-frame navigations that ended before their page came: failed, or cancelled when
    /// another load took their place (held weakly).
    private let abandonedNavigations = NSHashTable<WKNavigation>.weakObjects()
    /// Set while the warm-up robot drives this tab: what would be downloaded is refused instead
    /// (a response WebKit cannot show fails as a load), so a run never saves a file.
    var refusesDownloads = false
    /// Sites that asked for the position in the page this tab shows (`GeolocationPermission`).
    private var geolocationAsked: Set<String> = []

    /// Password AutoFill in this tab: suggestions, filling, the save question.
    private(set) lazy var passwords = TabPasswordAutoFill(tab: self, vault: context.passwordVault,
                                                          settings: context.passwordSettings)

    init(configuration: WKWebViewConfiguration, context: BrowserTabContext) {
        self.context = context
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
        if let title = webView.title, !title.isEmpty { return title }
        if let host = webView.url?.host { return host }
        return L("tab.newTab")
    }

    var url: URL? { webView.url }
    var isLoading: Bool { webView.isLoading }
    /// Opened as an empty new tab (not a popup, not with an address): its window shows the start
    /// page over it until it starts loading something.
    var startsEmpty = false
    var showsStartPage: Bool { startsEmpty && webView.url == nil && !webView.isLoading }
    /// Shown in its window (every tab's web view is in its window; only the selected one is not hidden).
    var isSelected: Bool { webView.window != nil && !webView.isHidden }

    /// Loads `url`; returns the navigation it started (see `hasCommitted`).
    @discardableResult
    func load(_ url: URL) -> WKNavigation? {
        startsEmpty = false
        return webView.load(URLRequest(url: url))
    }

    /// The page of `navigation` has committed (replaced the one before).
    func hasCommitted(_ navigation: WKNavigation) -> Bool {
        committedNavigations.contains(navigation)
    }

    /// `navigation` ended without its page: it failed, or another load took its place.
    func hasAbandoned(_ navigation: WKNavigation) -> Bool {
        abandonedNavigations.contains(navigation)
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
        passwords.closeSuggestions()
        dismissPendingSheets()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        host = nil
    }

    // MARK: Dialog helpers

    func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        presentSheet(alert.window, begin: { alert.beginSheetModal(for: $0, completionHandler: $1) }, respond: completion)
    }

    /// Shows a sheet whose result a WebKit completion handler is waiting for, and guarantees
    /// `respond` runs exactly once: with the sheet's return code, or with `.cancel` when the tab
    /// is torn down first (Stop, Lock, Quit, delete, closing the tab). WebKit raises
    /// NSInternalInconsistencyException when such a handler is released without being called,
    /// and closing a window does not end its sheets or call their completions.
    private func presentSheet(_ sheet: NSWindow,
                              begin: (NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void,
                              respond: @escaping (NSApplication.ModalResponse) -> Void) {
        host?.tabNeedsAttention(self)
        guard !tornDown, let window = host?.hostWindow else {
            respond(.cancel)
            return
        }
        let token = UUID()
        var answered = false
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] code in
            guard !answered else { return }
            answered = true
            self?.pendingSheets[token] = nil
            respond(code)
        }
        pendingSheets[token] = PendingSheet(parent: window, sheet: sheet, cancel: { answer(.cancel) })
        begin(window, answer)
    }

    /// Answers every waiting WebKit completion handler with "cancel" and closes its sheet.
    private func dismissPendingSheets() {
        let pending = Array(pendingSheets.values)
        pendingSheets.removeAll()
        for item in pending {
            item.cancel() // first: ending the sheet below calls the same, then no-op, answer
            if item.sheet.sheetParent === item.parent {
                item.parent.endSheet(item.sheet, returnCode: .cancel)
            }
        }
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
            decisionHandler(refusesDownloads ? .cancel : .download)
        } else if navigationAction.navigationType == .linkActivated,
                  flags.contains(.command) || navigationAction.buttonNumber == 2,
                  ["http", "https"].contains(scheme) {
            host?.tab(self, openInBackground: navigationAction.request)
            decisionHandler(.cancel)
        } else if ["http", "https", "about", "blob", "data"].contains(scheme) {
            // A form submission: the AutoFill script reads a password typed into it first (a form
            // submitted by `form.submit()` sends no `submit` event). sourceFrame can be nil although
            // Swift declares it non-optional; read through KVC.
            if navigationAction.navigationType == .formSubmitted,
               let source = (navigationAction as NSObject).value(forKey: "sourceFrame") as? WKFrameInfo {
                passwords.formSubmitted(from: source) { decisionHandler(.allow) }
                return
            }
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
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : refusesDownloads ? .cancel : .download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let navigation { committedNavigations.add(navigation) }
        geolocationAsked.removeAll() // another page: WebKit asks again when it does
        passwords.closeSuggestions()
        if let url = webView.url { recordVisit(url) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let navigation { abandonedNavigations.add(navigation) }
        let nsError = error as NSError
        if let reason = proxyAuthFailure {
            // The load was cancelled by this tab itself, at the proxy's challenge (fail-closed).
            proxyAuthFailure = nil
            showErrorPage(reason)
            return
        }
        guard nsError.code != NSURLErrorCancelled else { return }
        // With a proxy configured and failover disabled, an unreachable proxy surfaces here.
        showErrorPage("\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }

    private func showErrorPage(_ message: String) {
        failedNavigations += 1
        lastNavigationError = message
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let heading = L("errorpage.title")
        let html = """
        <html><head><meta charset="utf-8"><title>\(heading)</title></head>
        <body style="font: 15px -apple-system; padding: 48px; color: #333; background: #fff">
        <h2 style="font-weight: 600">\(heading)</h2><p style="color:#666">\(escaped)</p></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        // The profile's proxy asks for its credentials (HTTP 407 / SOCKS auth). With
        // proxyConfigurations set, WebKit hands these to the app instead of answering them itself,
        // so the system default would never send the profile's user name and password. Without
        // credentials, or after they were rejected once, cancel: the load fails (fail-closed)
        // instead of retrying forever. TLS trust of an HTTPS proxy stays with the system.
        if space.isProxy(), space.authenticationMethod != NSURLAuthenticationMethodServerTrust,
           space.authenticationMethod != NSURLAuthenticationMethodClientCertificate {
            if challenge.previousFailureCount == 0, let credential = context.proxyCredential {
                completionHandler(.useCredential, credential)
            } else {
                let missing = challenge.previousFailureCount == 0
                log.error("Proxy authentication \(missing ? "requested, no credentials set" : "rejected", privacy: .public)")
                proxyAuthFailure = L(missing ? "errorpage.proxy.noCredentials" : "errorpage.proxy.rejected")
                completionHandler(.cancelAuthenticationChallenge, nil)
                // WebKit does not always report the cancelled load to didFailProvisionalNavigation;
                // the tab must not stay blank, so the error page is shown from here then.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.tornDown, let reason = self.proxyAuthFailure else { return }
                    self.proxyAuthFailure = nil
                    self.showErrorPage(reason)
                }
            }
            return
        }
        let httpAuth = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod)
        guard httpAuth, let scheme = space.protocol,
              let url = URL(string: "\(scheme)://\(space.host):\(space.port)") else {
            // Server trust, client certificates: system default.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if challenge.previousFailureCount == 0, let entry = context.passwordVault.entries(for: url).first {
            completionHandler(.useCredential, URLCredential(user: entry.username, password: entry.password, persistence: .forSession))
            return
        }
        promptForHTTPCredentials(host: space.host, realm: space.realm) { [weak self] credential, remember in
            guard let credential else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // "Remember this password", as Safari's sign-in sheet: kept in the profile's vault.
            if remember, let self, let origin = PasswordEntry.normalizedOrigin(for: url), let password = credential.password {
                do {
                    try self.context.passwordVault.upsert(PasswordEntry(origin: origin, username: credential.user ?? "", password: password))
                } catch {
                    self.log.error("Could not save the HTTP sign-in: \(String(describing: error), privacy: .public)")
                }
            }
            completionHandler(.useCredential, credential)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process terminated; reloading")
        webView.reload()
    }

    private func promptForHTTPCredentials(host: String, realm: String?, completion: @escaping (URLCredential?, Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(format: L("auth.login"), host)
        alert.informativeText = realm.map { String(format: L("auth.realm"), $0) } ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = L("passwords.placeholder.username")
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = L("passwords.placeholder.password")
        let remember = NSButton(checkboxWithTitle: L("auth.remember"), target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        user.frame.origin.y = 56
        pass.frame.origin.y = 26
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        accessory.addSubview(user)
        accessory.addSubview(pass)
        accessory.addSubview(remember)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("auth.logIn"))
        alert.addButton(withTitle: L("common.cancel"))
        presentAlert(alert) { response in
            completion(response == .alertFirstButtonReturn
                       ? URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession)
                       : nil, remember.state == .on)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    /// The window's frame, which WebKit turns into window.outerWidth/outerHeight and
    /// screenX/screenY. WebKit asks the UI delegate for it (`WKUIDelegatePrivate`, the method Safari
    /// answers); a delegate without it gets outerWidth = outerHeight = 0 and a screen position
    /// computed from an empty rectangle — what embedded and headless browsers report. AppKit screen
    /// coordinates; WebKit flips them. A tab behind the shown one is in the window too (hidden,
    /// `BrowserWindowController.attach`), so it answers with its window as the shown tab does.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, windowFrameCompletion completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(webView.window?.frame ?? .zero)
    }

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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        presentSheet(panel, begin: { panel.beginSheetModal(for: $0, completionHandler: $1) },
                     respond: { completionHandler($0 == .OK ? panel.urls : nil) })
    }

    /// Geolocation (`WKUIDelegatePrivate`, asked when a frame calls getCurrentPosition or
    /// watchPosition): no, as a user who said no would answer, so the page gets WebKit's own
    /// PERMISSION_DENIED. Profiles with a fixed position never get here: the shim answers them.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func answerGeolocationRequest(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                                  decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        geolocationAsked.insert(GeolocationPermission.site(origin))
        if let top = GeolocationPermission.site(of: webView.url) { geolocationAsked.insert(top) }
        decisionHandler(.deny)
        // A PermissionStatus the page holds reads the state again ('denied') and fires 'change'.
        if webView.responds(to: GeolocationPermission.permissionChanged) {
            _ = webView.perform(GeolocationPermission.permissionChanged, with: "geolocation", with: origin)
        }
    }

    /// The state navigator.permissions.query reports (`WKUIDelegatePrivate`): for geolocation,
    /// 'prompt' until a page of the site asked for the position, then 'denied'; for every other
    /// permission 'prompt', which WebKit reports for them when a delegate does not answer.
    @objc(_webView:queryPermission:forOrigin:completionHandler:)
    func answerPermissionQuery(_ webView: WKWebView, name: String, origin: WKSecurityOrigin,
                               completionHandler: @escaping (WKPermissionDecision) -> Void) {
        let asked = name == "geolocation" && geolocationAsked.contains(GeolocationPermission.site(origin))
        completionHandler(asked ? .deny : .prompt)
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

// MARK: - WKDownloadDelegate

extension BrowserTab: WKDownloadDelegate {
    /// LIMITATION: downloaded files are written to ~/Downloads unencrypted; they are outside the
    /// profile's encrypted storage. In the App Sandbox this needs
    /// `com.apple.security.files.downloads.read-write`.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        completionHandler(Self.uniqueDownloadURL(suggestedFilename: suggestedFilename))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        showMessage(String(format: L("download.failed"), error.localizedDescription))
    }

    static func uniqueDownloadURL(suggestedFilename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = suggestedFilename.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var destination = downloads.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return destination
    }
}
