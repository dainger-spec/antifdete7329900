import Foundation
import LumenCore
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
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // An HTTP proxy on iOS 17: nothing loads, a restored tab (a back/forward navigation) included.
        if runtime?.refusal != nil, !Faults.isActive(.ios17LoadsAnyway),
           !(Faults.isActive(.refusalSkipsBackForward) && navigationAction.navigationType == .backForward) {
            return .cancel
        }
        // Schemes a web view cannot load (tg:, mailto:, …) are not handed to other apps here: a
        // session's link must not leave its proxy and its data for another app.
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .allow }
        return ["http", "https", "about", "blob", "data", "file"].contains(scheme) ? .allow : .cancel
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        runtime?.adoptTab(configuration: configuration)
    }
}
