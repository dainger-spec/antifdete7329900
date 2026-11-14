import Foundation
import LumenCore
import UIKit
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
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
}
