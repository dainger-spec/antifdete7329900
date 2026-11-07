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
    private(set) var proxy: ProxyEntry?
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
        let saved = store.loadTabs(of: session.id)
        tabs = saved.tabs.map { makeTab($0, configuration: nil) }
        if tabs.isEmpty { tabs = [makeTab(TabRecord(), configuration: nil)] }
        selectedID = saved.selected.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.last?.id
        for tab in tabs { tab.restore() }
    }

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.last }

    /// What a new web view of this session is built with.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        // Safari's application name after WebKit's own string: the User-Agent Safari on this iPhone sends.
        configuration.applicationNameForUserAgent = UserAgentPreset.safariApplicationName(systemVersion: UIDevice.current.systemVersion)
        return configuration
    }

    private func makeTab(_ record: TabRecord, configuration: WKWebViewConfiguration?) -> BrowserTab {
        BrowserTab(record: record, configuration: configuration ?? makeConfiguration(), runtime: self)
    }

    func update(session: Session, proxy: ProxyEntry?) {
        self.session = session
        self.proxy = proxy
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
