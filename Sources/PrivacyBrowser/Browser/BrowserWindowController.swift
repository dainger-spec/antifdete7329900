import AppKit
import BrowserCore
import os
import WebKit

/// A browser window bound to one profile session.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let webView: WKWebView
    private weak var session: BrowserSession?
    private let profileName: String
    private let passwordVault: PasswordVault
    private let addressField = NSTextField()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var observations: [NSKeyValueObservation] = []
    private var tornDown = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserWindow")

    /// Search used for address-bar input that is not a URL. Queries go through the profile's proxy.
    static let searchURLTemplate = "https://duckduckgo.com/?q="

    init(session: BrowserSession, configuration: WKWebViewConfiguration) {
        self.session = session
        self.profileName = session.profileName
        self.passwordVault = session.passwordVault
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        // NATIVE: sets the User-Agent header and navigator.userAgent for this view.
        // LIMITATION: navigator.platform/vendor, feature detection and the TLS/HTTP2
        // fingerprint still identify WebKit on macOS; a non-WebKit UA string is inconsistent.
        webView.customUserAgent = session.configuration.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "[\(session.profileName)]"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        buildInterface(in: window)
        observeWebView()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Interface

    private func buildInterface(in window: NSWindow) {
        backButton = toolbarButton("chevron.left", "Back", #selector(goBack))
        forwardButton = toolbarButton("chevron.right", "Forward", #selector(goForward))
        let reloadButton = toolbarButton("arrow.clockwise", "Reload", #selector(reload))
        let fillButton = toolbarButton("key.fill", "Fill saved password", #selector(fillPassword(_:)))
        let saveButton = toolbarButton("key.viewfinder", "Save password from this page", #selector(savePassword))

        addressField.placeholderString = "Search or enter address"
        addressField.delegate = self
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressEntered)

        let badge = NSTextField(labelWithString: profileName)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, fillButton, saveButton, badge])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let container = NSView()
        for view in [bar, webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        updateNavigationButtons()
    }

    private func toolbarButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "New Window"
                    self.window?.title = "[\(self.profileName)] \(title)"
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    // Don't overwrite what the user is typing.
                    guard let self, self.addressField.currentEditor() == nil else { return }
                    self.addressField.stringValue = webView.url?.absoluteString ?? ""
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationButtons() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateNavigationButtons() }
            },
        ]
    }

    private func updateNavigationButtons() {
        backButton?.isEnabled = webView.canGoBack
        forwardButton?.isEnabled = webView.canGoForward
    }

    // MARK: Navigation

    func load(_ url: URL) {
        addressField.stringValue = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func reload() { webView.reload() }

    @objc private func addressEntered() {
        guard let url = Self.url(fromAddressBarInput: addressField.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(webView)
    }

    static func url(fromAddressBarInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" "), text.contains(".") || text.hasPrefix("localhost"), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        return URL(string: searchURLTemplate + query)
    }

    // MARK: Passwords
    //
    // LIMITATION: WKWebView exposes no autofill hooks. Filling/saving is explicit and runs in
    // the isolated `.defaultClient` content world, so page scripts cannot intercept the
    // function or the DOM prototypes it uses. Main frame only.

    private static let fillScript = """
    if (location.origin !== expectedOrigin) return false;
    const visible = (e) => !e.disabled && !e.readOnly && e.getClientRects().length > 0;
    const passwords = Array.from(document.querySelectorAll('input[type=password]')).filter(visible);
    const pw = passwords[0];
    if (!pw) return false;
    const scope = pw.form || document;
    const users = Array.from(scope.querySelectorAll('input[type=email], input[type=text], input[type=tel], input:not([type])'))
      .filter(visible)
      .filter((e) => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
    const setValue = (el, value) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const user = users[users.length - 1];
    if (user && username) setValue(user, username);
    setValue(pw, password);
    return true;
    """

    private static let captureScript = """
    const pw = Array.from(document.querySelectorAll('input[type=password]')).find((e) => e.value);
    if (!pw) return null;
    const scope = pw.form || document;
    const users = Array.from(scope.querySelectorAll('input[type=email], input[type=text], input[type=tel], input:not([type])'))
      .filter((e) => e.value && (e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING));
    return { username: users.length ? users[users.length - 1].value : '', password: pw.value, origin: location.origin };
    """

    @objc private func fillPassword(_ sender: NSButton) {
        guard let url = webView.url, let origin = PasswordEntry.normalizedOrigin(for: url) else { return }
        let entries = passwordVault.entries(for: url)
        switch entries.count {
        case 0:
            showMessage("No saved password for \(origin).")
        case 1:
            fill(entries[0], origin: origin)
        default:
            let menu = NSMenu()
            for entry in entries {
                let item = NSMenuItem(title: entry.username.isEmpty ? "(no username)" : entry.username,
                                      action: #selector(fillFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    @objc private func fillFromMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let url = webView.url,
              let origin = PasswordEntry.normalizedOrigin(for: url),
              let entry = passwordVault.entries(for: url).first(where: { $0.id == id }) else { return }
        fill(entry, origin: origin)
    }

    private func fill(_ entry: PasswordEntry, origin: String) {
        webView.callAsyncJavaScript(Self.fillScript,
                                    arguments: ["username": entry.username, "password": entry.password, "expectedOrigin": origin],
                                    in: nil, in: .defaultClient) { [weak self] result in
            if case .success(let value) = result, (value as? Bool) == true { return }
            self?.showMessage("No suitable password field found on this page.")
        }
    }

    @objc private func savePassword() {
        guard let url = webView.url, let origin = PasswordEntry.normalizedOrigin(for: url) else { return }
        webView.callAsyncJavaScript(Self.captureScript, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let fields = value as? [String: Any],
                  let password = fields["password"] as? String, !password.isEmpty,
                  fields["origin"] as? String == origin else {
                self.showMessage("Type the username and password into the page first, then press Save.")
                return
            }
            let username = fields["username"] as? String ?? ""
            let alert = NSAlert()
            alert.messageText = "Save password for \(origin)?"
            alert.informativeText = username.isEmpty ? "No username detected." : "Username: \(username)"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            guard let window = self.window else { return }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    try self.passwordVault.upsert(PasswordEntry(origin: origin, username: username, password: password))
                } catch {
                    self.showMessage("Could not save: \(error)")
                }
            }
        }
    }

    private func showMessage(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.beginSheetModal(for: window)
    }

    // MARK: Lifecycle

    func windowWillClose(_ notification: Notification) {
        tearDown()
        session?.windowDidClose(self)
    }

    /// Breaks every reference cycle and stops all activity so the web view (and with it the
    /// profile's data store) can be deallocated promptly.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window?.delegate = nil
    }
}

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
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

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        // With a proxy configured and failover disabled, an unreachable proxy surfaces here.
        let message = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <html><body style="font: 14px -apple-system; padding: 40px; color: #444">
        <h2>Page could not be loaded</h2><p>\(escaped)</p></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
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
        if challenge.previousFailureCount == 0, let entry = passwordVault.entries(for: url).first {
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
        guard let window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = "Log in to \(host)"
        alert.informativeText = realm.map { "Realm: \($0)" } ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Username"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(user)
        accessory.addSubview(pass)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn
                       ? URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession)
                       : nil)
        }
    }
}

// MARK: - WKUIDelegate

extension BrowserWindowController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        session?.openPopup(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// Camera / microphone: ask every time (WebKit forwards the request only after the page called getUserMedia).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let window else { decisionHandler(.deny); return }
        let what: String
        switch type {
        case .camera: what = "camera"
        case .microphone: what = "microphone"
        case .cameraAndMicrophone: what = "camera and microphone"
        @unknown default: what = "media devices"
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(origin.host) to use your \(what)?"
        alert.informativeText = "Profile: \(profileName). Media streams are not routed through the profile proxy."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.beginSheetModal(for: window) { decisionHandler($0 == .alertFirstButtonReturn ? .grant : .deny) }
    }
}

// MARK: - WKDownloadDelegate

extension BrowserWindowController: WKDownloadDelegate {
    /// LIMITATION: downloaded files are written to ~/Downloads unencrypted; they are outside the
    /// profile's encrypted storage.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = suggestedFilename.replacingOccurrences(of: "/", with: "_")
        var destination = downloads.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
        var counter = 1
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        completionHandler(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        showMessage("Download failed: \(error.localizedDescription)")
    }
}
