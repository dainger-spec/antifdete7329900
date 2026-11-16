import Foundation
import LumenCore
import UIKit
import UniformTypeIdentifiers
import WebKit

/// One tab: a WKWebView of its session's configuration, and what the bar above it shows.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: WKWebView
    weak var runtime: SessionRuntime?
    @Published private(set) var title: String
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// What the page looked like when it last finished loading: the tab's card shows it.
    @Published private(set) var thumbnail: UIImage?
    private var saved: TabRecord
    private var observations: [NSKeyValueObservation] = []
    /// The dialog this tab's page is waiting on (`showDialog`), and the answer it gets if the tab
    /// closes under it: WebKit raises an exception for a completion handler dropped unanswered.
    private var pendingDialog: (alert: UIAlertController, dismissed: () -> Void)?

    init(record: TabRecord, configuration: WKWebViewConfiguration, runtime: SessionRuntime) {
        id = record.id
        saved = record
        title = record.title
        url = record.url.flatMap(URL.init(string:))
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.runtime = runtime
        super.init()
        // The app is dark whatever the iPhone's appearance is (Theme); a site is told the iPhone's
        // own appearance, as Safari tells it — not the app's.
        webView.overrideUserInterfaceStyle = UIScreen.main.traitCollection.userInterfaceStyle
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // A long press on a link or an image shows the app's own menu, never WebKit's (`menu(for:)`).
        // Link previews stay allowed, unlike the Mac's: on iOS they are what gives a web view a
        // context menu at all — turned off, WebKit asks this delegate for no menu, and a long press
        // on a link opens it as a tap does.
        webView.allowsLinkPreview = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        observations = [
            webView.observe(\.title) { [weak self] view, _ in Task { @MainActor in self?.refresh(from: view) } },
            webView.observe(\.url) { [weak self] view, _ in Task { @MainActor in self?.refresh(from: view) } },
            webView.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.refresh(from: view) } },
            webView.observe(\.canGoForward) { [weak self] view, _ in Task { @MainActor in self?.refresh(from: view) } },
            webView.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.refresh(from: view) } },
        ]
    }

    /// The tab as it was left: its back/forward list (WebKit's interaction state), else its address.
    func restore() {
        if let state = saved.interactionState {
            webView.interactionState = state
        } else if let url {
            webView.load(URLRequest(url: url))
        }
    }

    func load(_ url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }

    /// What is written for the tab: the interaction state when WebKit gives it as data.
    var record: TabRecord {
        var state = saved.interactionState
        if let current = webView.interactionState as? Data { state = current }
        return TabRecord(id: id, url: (webView.url ?? url)?.absoluteString, title: webView.title ?? title, interactionState: state)
    }

    private func refresh(from view: WKWebView) {
        if let pageTitle = view.title, !pageTitle.isEmpty { title = pageTitle }
        if let current = view.url { url = current }
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        isLoading = view.isLoading
    }

    func tearDown() {
        if let pending = pendingDialog {
            pendingDialog = nil
            if pending.alert.presentingViewController != nil { pending.alert.dismiss(animated: false) }
            pending.dismissed()
        }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh(from: webView)
        if let url = webView.url { runtime?.recordVisit(url: url, title: webView.title ?? "") }
        saved = record
        runtime?.saveTabs()
        takeThumbnail()
    }

    /// A small picture of the page's top, for the tab's card. Kept in memory only.
    private func takeThumbnail() {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 200
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in if let image { self?.thumbnail = image } }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Schemes a web view cannot load (tg:, mailto:, …) are not handed to other apps here: a
        // session's link must not leave its proxy and its data for another app.
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .allow }
        guard ["http", "https", "about", "blob", "data", "file"].contains(scheme) else { return .cancel }
        return .allow
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        runtime?.adoptTab(configuration: configuration)
    }

    /// A page's getUserMedia: refused, camera and microphone alike, as WebKit refused it itself while
    /// Info.plist had no purpose for them. Those purposes (project.yml) are for the photo or video a
    /// person takes in a site's file field — WebKit's own upload menu, which iOS ends the app for
    /// without them — not for pages.
    @objc(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: The page's dialogs and a site's sign-in

    /// `alert()`: the page's message, under the name of its host, with OK.
    @objc(webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let answer = DialogAnswer<Bool> { _ in completionHandler() }
        let alert = UIAlertController(title: Self.dialogTitle(frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("ОК"), style: .default) { _ in answer.give(true) })
        showDialog(alert) { answer.give(true) }
    }

    /// `confirm()`: OK is true; Cancel, or a dialog that could not be shown, is false.
    @objc(webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let answer = DialogAnswer<Bool>(completionHandler)
        let alert = UIAlertController(title: Self.dialogTitle(frame), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel) { _ in answer.give(false) })
        let ok = UIAlertAction(title: L("ОК"), style: .default) { _ in answer.give(true) }
        alert.addAction(ok)
        alert.preferredAction = ok
        showDialog(alert) { answer.give(false) }
    }

    /// `prompt()`: the text typed (the page's default to start with); Cancel is null.
    @objc(webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let answer = DialogAnswer<String?>(completionHandler)
        let alert = UIAlertController(title: Self.dialogTitle(frame), message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel) { _ in answer.give(nil) })
        let ok = UIAlertAction(title: L("ОК"), style: .default) { [weak alert] _ in
            answer.give(alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(ok)
        alert.preferredAction = ok
        showDialog(alert) { answer.give(nil) }
    }

    /// A site's own sign-in (HTTP Basic or Digest, the server's 401): asked for in a sheet — only over
    /// https, where the password goes to the site encrypted; over plain http the site's 401 page is
    /// shown, as before. What is typed is kept for this session only while the app runs
    /// (`.forSession`: WebKit keeps it in the session's own data store, in memory), never written
    /// anywhere — the Mac's rule for HTTP sign-in (a saved login is sent only over https).
    /// Everything else — server trust, client certificates, the relay's own proxy sign-in — is
    /// answered as WebKit answers it by itself.
    @objc(webView:didReceiveAuthenticationChallenge:completionHandler:)
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let siteSignIn = space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest
        guard siteSignIn, !space.isProxy() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard space.protocol?.lowercased() == "https" else {
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        let answer = DialogAnswer<URLCredential?> { credential in
            if let credential { completionHandler(.useCredential, credential) } else { completionHandler(.rejectProtectionSpace, nil) }
        }
        var lines: [String] = []
        if challenge.previousFailureCount > 0 { lines.append(L("Имя пользователя или пароль не подошли.")) }
        if let realm = space.realm, !realm.isEmpty { lines.append(L("Сайт пишет: «%@»", String(realm.prefix(200)))) }
        lines.append(L("Не сохраняется: после перезапуска приложения сайт спросит снова."))
        let alert = UIAlertController(title: L("Вход на %@", space.host), message: lines.joined(separator: "\n\n"), preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L("Имя пользователя")
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        alert.addTextField { field in
            field.placeholder = L("Пароль")
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel) { _ in answer.give(nil) })
        let signIn = UIAlertAction(title: L("Войти"), style: .default) { [weak alert] _ in
            let user = alert?.textFields?.first?.text ?? "", password = alert?.textFields?.last?.text ?? ""
            answer.give(URLCredential(user: user, password: password, persistence: .forSession))
        }
        alert.addAction(signIn)
        alert.preferredAction = signIn
        showDialog(alert) { answer.give(nil) }
    }

    /// A dialog's title: the host of the page that shows it, as Safari names it.
    private static func dialogTitle(_ frame: WKFrameInfo) -> String {
        let host = frame.securityOrigin.host
        return host.isEmpty ? L("Эта страница") : host
    }

    /// Shows a dialog of this tab over whatever is on top of its window. `dismissed` is the page's
    /// answer when it cannot be shown — the tab is not on screen, another of its dialogs is still
    /// open, UIKit refuses — or when the tab closes under it (`tearDown`; an answer already given
    /// stands, `DialogAnswer`).
    private func showDialog(_ alert: UIAlertController, dismissed: @escaping () -> Void) {
        if let open = pendingDialog?.alert, open.presentingViewController != nil, !open.isBeingDismissed {
            dismissed()
            return
        }
        guard var top = webView.window?.rootViewController else {
            dismissed()
            return
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        pendingDialog = (alert, dismissed)
        top.present(alert, animated: true)
        if alert.presentingViewController == nil {
            pendingDialog = nil
            dismissed()
        }
    }

    // MARK: The long-press menu

    /// A long press on a link, or on an image: the app's own menu (`menu(for:)`), always — never
    /// WebKit's, which it shows when this answers nil. WebKit's preview opens the link in Safari's
    /// view, and its Share… and Add to Reading List hand the address to the system, which fetches
    /// it — the page and its icon for the share sheet, the page for Safari's list — from the
    /// iPhone's own address: outside the session's data store, so outside its proxy (the Mac
    /// measured the same frameworks, HandOffs.swift there).
    @objc(webView:contextMenuConfigurationForElement:completionHandler:)
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        completionHandler(menu(for: elementInfo.linkURL))
    }

    /// The lifted link itself touched: it opens in this tab, as a tap on it does.
    @objc(webView:contextMenuForElement:willCommitWithAnimator:)
    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL, Self.opensHere(url) else { return }
        animator.addCompletion { [weak self] in
            Task { @MainActor in self?.load(url) }
        }
    }

    /// The menu of a link: Open, Open in New Tab (a tab of this session) and Copy Link — the first two
    /// for a web address only — and no preview: everything stays in this session's data store. An
    /// element without a link (an image) gets a menu with nothing in it.
    func menu(for url: URL?) -> UIContextMenuConfiguration {
        var actions: [UIMenuElement] = []
        if let url {
            if Self.opensHere(url) {
                actions.append(UIAction(title: L("Открыть"), image: UIImage(systemName: "arrow.up.forward.square")) { [weak self] _ in
                    self?.load(url)
                })
                actions.append(UIAction(title: L("Открыть в новой вкладке"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    self?.runtime?.newTab(opening: url)
                })
            }
            actions.append(UIAction(title: L("Скопировать ссылку"), image: UIImage(systemName: "doc.on.doc")) { _ in
                Self.copyLink(url)
            })
        }
        let shown = UIMenu(title: url.map { String($0.absoluteString.prefix(300)) } ?? "", children: actions)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in shown }
    }

    /// An address a tab of the session loads (the others are refused by `decidePolicyFor` anyway).
    static func opensHere(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The address on this iPhone's pasteboard only — not on the person's other devices (Universal
    /// Clipboard), as the Mac keeps what a profile copies on that Mac.
    static func copyLink(_ url: URL) {
        UIPasteboard.general.setItems([[UTType.url.identifier: url, UTType.plainText.identifier: url.absoluteString]],
                                      options: [.localOnly: true])
    }
}

/// A WebKit completion handler given exactly once, whichever comes first: the person's answer, or
/// the one the page gets when its dialog cannot be shown or is closed with its tab.
private final class DialogAnswer<Value> {
    private var handler: ((Value) -> Void)?

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func give(_ value: Value) {
        guard let handler else { return }
        self.handler = nil
        handler(value)
    }
}
