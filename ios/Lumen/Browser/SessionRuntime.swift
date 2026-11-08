import Foundation
import LumenCore
import UIKit
import WebKit

/// The open sessions' web views, kept while the app runs so that going back to the list and into a
/// session again finds its tabs as they were.
@MainActor
final class SessionRuntimes {
    static let shared = SessionRuntimes()
    private var runtimes: [UUID: SessionRuntime] = [:]

    func runtime(for session: Session, model: AppModel) -> SessionRuntime {
        if let runtime = runtimes[session.id] {
            runtime.update(session: session, proxy: model.proxy(session.proxyID))
            return runtime
        }
        let runtime = SessionRuntime(session: session, proxy: model.proxy(session.proxyID), store: model.store)
        runtimes[session.id] = runtime
        return runtime
    }

    func existing(_ id: UUID) -> SessionRuntime? { runtimes[id] }

    func close(_ id: UUID) {
        runtimes.removeValue(forKey: id)?.close()
    }
}

/// One session while it is open: its WebKit data store (cookies, storage, cache), its tabs and its
/// history. Tabs are written after every page that finishes loading and every tab change, so an
/// app that is killed (the system does that) loses nothing a person saw.
@MainActor
final class SessionRuntime: ObservableObject {
    let sessionID: UUID
    private(set) var session: Session
    /// Published: what the browser says (a refused HTTP proxy on iOS 17) follows a change at once.
    @Published private(set) var proxy: ProxyEntry?
    let dataStore: WKWebsiteDataStore
    private let store: LumenStore
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var history: [HistoryEntry]

    init(session: Session, proxy: ProxyEntry?, store: LumenStore) {
        sessionID = session.id
        self.session = session
        self.proxy = proxy
        self.store = store
        // The session's own store; the planted fault puts every session on WebKit's default one.
        dataStore = Faults.isActive(.sharedStore) ? .default() : WKWebsiteDataStore(forIdentifier: session.storeID)
        history = store.loadHistory(of: session.id)
        applyProxy()
        applyPageSettings()
        let saved = store.loadTabs(of: session.id)
        tabs = saved.tabs.map { makeTab($0, configuration: nil) }
        if tabs.isEmpty { tabs = [makeTab(TabRecord(), configuration: nil)] }
        selectedID = saved.selected.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.last?.id
        for tab in tabs { tab.restore() }
    }

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.last }

    /// Set when this session must load nothing at all (an HTTP proxy on iOS 17): every navigation is
    /// cancelled and the browser says why.
    var refusal: String? { PlatformLimits.refusal(for: proxy) }

    /// What a new web view of this session is built with.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        // Safari's application name after WebKit's own string: the User-Agent Safari on this iPhone sends.
        configuration.applicationNameForUserAgent = UserAgentPreset.safariApplicationName(systemVersion: UIDevice.current.systemVersion)
        if proxy != nil, let rules = ContentRules.proxied { configuration.userContentController.add(rules) }
        configuration.userContentController.addUserScript(PageSettings.script(for: session, proxy: proxy))
        return configuration
    }

    private func makeTab(_ record: TabRecord, configuration: WKWebViewConfiguration?) -> BrowserTab {
        let tab = BrowserTab(record: record, configuration: configuration ?? makeConfiguration(), runtime: self)
        tab.webView.customUserAgent = PageSettings.userAgent(for: session)
        return tab
    }

    func update(session: Session, proxy: ProxyEntry?) {
        self.session = session
        self.proxy = proxy
        applyProxy()
        applyPageSettings()
    }

    /// What the pages were last given (User-Agent and shim configuration); a change reaches every
    /// open tab, from its next page on.
    private var appliedPage: String?

    private func applyPageSettings() {
        let config = PageSettings.config(for: session, proxy: proxy)
        let key = "\(PageSettings.userAgent(for: session) ?? "")|\(String(describing: config))"
        guard key != appliedPage else { return }
        let first = appliedPage == nil
        appliedPage = key
        guard !first else { return }   // the tabs were built with these already
        let script = PageSettings.script(for: session, proxy: proxy)
        for tab in tabs {
            let controller = tab.webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(script)
            tab.webView.customUserAgent = PageSettings.userAgent(for: session)
        }
    }

    // MARK: Proxy

    /// What the data store was last given: the proxy's address, kind, user and password.
    private var appliedProxy: String?

    /// The session's proxy, on its data store; a change applies at once to every tab — the next
    /// request goes through the new proxy (measured on iOS 18.6–27.2: no new web view needed).
    private func applyProxy() {
        guard !Faults.isActive(.proxyNotApplied) else { return }
        let password = proxy.flatMap { ProxyPasswords.get($0.id) }
        let key = proxy.map { "\($0.kind.rawValue)://\($0.username):\(password ?? "")@\($0.host):\($0.port)" } ?? "direct"
        guard key != appliedProxy else { return }
        if appliedProxy != nil, Faults.isActive(.proxyChangeNotLive) { return }
        dataStore.proxyConfigurations = proxy.map { ProxyFactory.make($0, password: password) } ?? []
        appliedProxy = key
        if let rules = ContentRules.proxied {
            for tab in tabs {
                let controller = tab.webView.configuration.userContentController
                controller.remove(rules)
                if proxy != nil { controller.add(rules) }
            }
        }
    }

    // MARK: Tabs

    func newTab() {
        guard !Faults.isActive(.newTabNotOpened) else { return }
        let tab = makeTab(TabRecord(), configuration: nil)
        tabs.append(tab)
        selectedID = tab.id
        saveTabs()
    }

    /// A page's window.open / target=_blank: a tab of this session, on the configuration WebKit gives.
    func adoptTab(configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = makeTab(TabRecord(), configuration: configuration)
        tabs.append(tab)
        selectedID = tab.id
        saveTabs()
        return tab.webView
    }

    func select(_ id: UUID) {
        selectedID = id
        saveTabs()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].tearDown()
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [makeTab(TabRecord(), configuration: nil)] }
        if selectedID == id || !tabs.contains(where: { $0.id == selectedID }) {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        saveTabs()
    }

    /// What the address bar does: an address opens, anything else is searched with the session's engine.
    func open(_ text: String) {
        guard let url = AddressInput.resolve(text, engine: session.settings.searchEngine) else { return }
        selected?.load(url)
    }

    func saveTabs() {
        store.saveTabs(SessionTabs(tabs: tabs.map(\.record), selected: selectedID), of: sessionID)
    }

    // MARK: History

    func recordVisit(url: URL, title: String) {
        guard !Faults.isActive(.historyNotRecorded), let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        if let last = history.last, last.url == url.absoluteString {
            // A reload or a title that came late: the same visit.
            history[history.count - 1].title = title.isEmpty ? last.title : title
        } else {
            history.append(HistoryEntry(url: url.absoluteString, title: title))
        }
        store.saveHistory(history, of: sessionID)
    }

    func clearHistory() {
        history = []
        store.saveHistory(history, of: sessionID)
    }

    func close() {
        for tab in tabs { tab.tearDown() }
        tabs = []
    }
}
