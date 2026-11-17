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
    /// How far the page has loaded (0…1): the address capsule's line.
    @Published private(set) var progress: Double = 0
    /// Why the last page did not load, when it did not (the browser shows it for a proxy that does not answer).
    @Published private(set) var failure: URLError.Code?
    /// The page's own ground is light: the bars over it turn light too, the status bar dark.
    @Published private(set) var lightPage = true
    /// What the page looked like when it last finished loading: the tab's card shows it.
    @Published private(set) var thumbnail: UIImage?
    private var saved: TabRecord
    private var observations: [NSKeyValueObservation] = []
    /// The dialog this tab's page is waiting on (`showDialog`), and the answer it gets if the tab
    /// closes under it: WebKit raises an exception for a completion handler dropped unanswered.
    private var pendingDialog: (alert: UIAlertController, dismissed: () -> Void)?
    /// A load this tab started itself — the address bar, its menu, a restore, a link held back and
    /// loaded again (`loadOwn`) — is under way in its main frame: WebKit offers neither it nor its
    /// redirects to another app, so `decidePolicyFor` lets them through (`LinkHandoff`). Over when a
    /// page commits, when that load fails, or when a link is tapped.
    private var ownLoad = false
    /// That load's navigation (nil: a restore), and its address, let through once whatever WebKit
    /// calls its navigation — a link loaded again is never held back a second time.
    private var ownNavigation: WKNavigation?
    private var ownLoadURL: URL?
    private var tornDown = false

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
            webView.observe(\.estimatedProgress) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            webView.observe(\.underPageBackgroundColor) { [weak self] view, _ in Task { @MainActor in self?.readGround(of: view) } },
        ]
    }

    /// The tab as it was left: its back/forward list (WebKit's interaction state), else its address.
    func restore() {
        if let state = saved.interactionState {
            ownLoad = true
            ownNavigation = nil
            ownLoadURL = nil
            webView.interactionState = state
        } else if let url {
            loadOwn(URLRequest(url: url))
        }
    }

    func load(_ url: URL) {
        self.url = url
        loadOwn(URLRequest(url: url))
    }

    /// A load of the tab's own (see `ownLoad`).
    private func loadOwn(_ request: URLRequest) {
        guard !tornDown else { return }
        ownLoad = true
        ownLoadURL = request.url
        ownNavigation = webView.load(request)
    }

    private func endOwnLoad() {
        ownLoad = false
        ownNavigation = nil
        ownLoadURL = nil
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

    /// Loads the page again after it failed (the browser's "Повторить").
    func retry() {
        failure = nil
        if webView.url != nil { webView.reload() } else if let url { webView.load(URLRequest(url: url)) }
    }

    private func readGround(of view: WKWebView) {
        var white: CGFloat = 1, alpha: CGFloat = 1
        if view.underPageBackgroundColor.getWhite(&white, alpha: &alpha) { lightPage = alpha < 0.1 || white > 0.5 }
    }

    func tearDown() {
        tornDown = true
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    // A page that failed: the tab's own load ends (the trunk's link handoff), and the failure is noted
    // for the proxy that does not answer (the design's p3-dead).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === ownNavigation { endOwnLoad() }
        noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === ownNavigation { endOwnLoad() }
        noteFailure(error)
    }

    /// A page that could not be reached; one the person stopped, or left for another, is no failure.
    private func noteFailure(_ error: Error) {
        let code = URLError.Code(rawValue: (error as NSError).code)
        guard (error as NSError).domain == NSURLErrorDomain, code != .cancelled else { return }
        failure = code
        refresh(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        endOwnLoad()   // the tab's own load, or a navigation that took its place
    }

    /// A session's link must not leave its proxy and its data for another app. Schemes a web view
    /// cannot load (tg:, mailto:, …) are refused. A web address that WebKit would first offer to the
    /// app claiming it — a page's navigation to another host (`LinkHandoff`) — is held back and
    /// loaded by the tab itself, which WebKit never offers to an app; for a host an app commonly
    /// claims, after the person is told and chooses (`warnBeforeLeaving`). Answered with the
    /// decision handler, so the navigation is cancelled before the tab's own load starts.
    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let request = navigationAction.request
        guard let url = request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.allow) }
        guard ["http", "https", "about", "blob", "data", "file"].contains(scheme) else { return decisionHandler(.cancel) }
        let target: LinkHandoff.Target
        if let frame = navigationAction.targetFrame {
            target = frame.isMainFrame ? .mainFrame : .frame
        } else {
            target = .newWindow
        }
        let kind = LinkHandoff.Kind(navigationAction.navigationType)
        if target == .mainFrame {
            if let own = ownLoadURL, own == url {
                ownLoadURL = nil
                return decisionHandler(.allow)
            }
            if kind == .link { endOwnLoad() }   // a tap takes the place of whatever the tab was loading
        }
        switch LinkHandoff.decide(url: url, currentHost: webView.url?.host, target: target, kind: kind,
                                  method: request.httpMethod, ownLoad: ownLoad) {
        case .allow:
            decisionHandler(.allow)
        case .openHere:
            decisionHandler(.cancel)
            openHere(request, target: target)
        case let .warn(app):
            decisionHandler(.cancel)
            warnBeforeLeaving(request, app: app, target: target)
        }
    }

    /// A held-back navigation, loaded by the tab itself: in this tab, or a new window's in a new tab
    /// of the session.
    private func openHere(_ request: URLRequest, target: LinkHandoff.Target) {
        guard !tornDown else { return }
        if target == .newWindow {
            if let url = request.url { runtime?.newTab(opening: url) }
        } else {
            loadOwn(request)
        }
    }

    /// A link to a host whose app may take it (`LinkHandoff.apps`): the person is told that the app
    /// would open it outside the session — from the iPhone's own address, with the account signed in
    /// there — and chooses. "Open Here" is the default, and what happens when the warning cannot be
    /// shown (a tab not on screen).
    private func warnBeforeLeaving(_ request: URLRequest, app: String, target: LinkHandoff.Target) {
        guard let url = request.url else { return }
        let choice = DialogAnswer<Bool> { [weak self] inApp in
            if inApp { self?.openInApp(url, request: request, target: target) } else { self?.openHere(request, target: target) }
        }
        let alert = UIAlertController(
            title: L("Ссылку может открыть приложение %@", app),
            message: L("В приложении она откроется вне этой сессии и её прокси: с собственного адреса этого iPhone и под аккаунтом, с которым вы вошли в %@.", app),
            preferredStyle: .alert)
        let here = UIAlertAction(title: L("Открыть здесь"), style: .default) { _ in choice.give(false) }
        alert.addAction(here)
        alert.addAction(UIAlertAction(title: L("Открыть в приложении"), style: .default) { _ in choice.give(true) })
        alert.preferredAction = here
        showDialog(alert) { choice.give(false) }
    }

    /// "Open in the App": handed to the app that claims the address and to nothing else — not to
    /// Safari when none does (`.universalLinksOnly`); then it opens here after all.
    private func openInApp(_ url: URL, request: URLRequest, target: LinkHandoff.Target) {
        Task { [weak self] in
            let opened = await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
            if !opened { self?.openHere(request, target: target) }
        }
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
        // The dialog before this one, if UIKit took it off the screen without a touch on any of its
        // buttons (the sheet it stood on was closed): dropped unanswered, its completion handler
        // would end the app (WebKit raises for one never called). Its page gets the answer a closed
        // dialog gives — a moment later, so that a button touched as it went (its handler comes once
        // the dialog is gone) still answers first (`DialogAnswer` takes the first).
        if let earlier = pendingDialog {
            pendingDialog = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { earlier.dismissed() }
        }
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

extension LinkHandoff.Kind {
    init(_ type: WKNavigationType) {
        switch type {
        case .linkActivated: self = .link
        case .formSubmitted, .formResubmitted: self = .form
        case .backForward: self = .backForward
        case .reload: self = .reload
        case .other: self = .other
        @unknown default: self = .other
        }
    }
}
