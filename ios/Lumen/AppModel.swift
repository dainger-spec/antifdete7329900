import Foundation
import LumenCore
import SwiftUI
import WebKit

/// Launch options a test passes (DEBUG builds only; a release build ignores them).
enum LaunchOptions {
    /// Start from nothing: the catalogue, the proxy list, every session's files and WebKit store.
    static var resetState: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-LumenResetState")
        #else
        return false
        #endif
    }
}

/// The app's state: the session catalogue and the proxy list, saved as they change.
@MainActor
final class AppModel: ObservableObject {
    let store: LumenStore
    let catalog: SessionCatalog
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var proxies: [ProxyEntry] = []
    @Published var path: [UUID] = []
    /// Set once a reset launch has removed every WebKit store (the UI waits for it).
    @Published private(set) var ready = false
    /// Proxies being checked right now (their rows show it).
    @Published private(set) var checking: Set<UUID> = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = LumenStore(root: support.appendingPathComponent("Lumen", isDirectory: true))
        if LaunchOptions.resetState {
            store.removeAll()
            ProxyPasswords.removeAll()
        }
        catalog = SessionCatalog(store: store)
        refresh()
        // WebKit's data-store calls finish on WebKit's main run loop, which exists only once WebKit is
        // initialized: before that, fetching the store identifiers crashes (CI run 3: SIGSEGV in
        // WebsiteDataStore::fetchAllDataStoreIdentifiers → RunLoop::dispatch). The macOS app does
        // the same (WebDataStoreVault.ensureWebKitInitialized).
        _ = WKWebViewConfiguration().processPool
        Task {
            if LaunchOptions.resetState {
                for id in await WKWebsiteDataStore.allDataStoreIdentifiers {
                    try? await WKWebsiteDataStore.remove(forIdentifier: id)
                }
            }
            // A session with a proxy gets its content rules from its first page on.
            await ContentRules.prepare()
            ready = true
        }
    }

    func refresh() {
        sessions = catalog.sessions
        if proxies.isEmpty { proxies = store.loadProxies() }
    }

    // MARK: Sessions

    @discardableResult
    func createSession(name: String, notes: String, tags: String) -> Session {
        let session = catalog.create(name: name, notes: notes, tags: [tags])
        refresh()
        return session
    }

    func updateSession(_ id: UUID, name: String, notes: String, tags: String) {
        catalog.rename(id, to: name)
        catalog.setNotes(id, notes)
        catalog.setTags(id, [tags])
        refresh()
    }

    func setSettings(_ id: UUID, _ settings: SessionSettings) {
        catalog.setSettings(id, settings)
        refresh()
    }

    func setProxy(_ id: UUID, proxyID: UUID?) {
        catalog.setProxy(id, proxyID: proxyID)
        refresh()
        refreshRuntimes()
    }

    // MARK: Proxies

    /// Adds or changes an entry (the password goes to the Keychain), then checks it.
    func saveProxy(_ entry: ProxyEntry, password: String?) {
        var entry = entry
        entry.hasPassword = !(password ?? "").isEmpty
        entry.check = nil
        ProxyPasswords.set(password, for: entry.id)
        if let index = proxies.firstIndex(where: { $0.id == entry.id }) { proxies[index] = entry } else { proxies.append(entry) }
        store.saveProxies(proxies)
        refreshRuntimes()
        check(entry.id)
    }

    func check(_ id: UUID) {
        guard let entry = proxies.first(where: { $0.id == id }), !checking.contains(id) else { return }
        checking.insert(id)
        Task {
            let result = await ProxyChecker.check(entry, password: ProxyPasswords.get(id))
            checking.remove(id)
            guard let index = proxies.firstIndex(where: { $0.id == id }) else { return }
            proxies[index].check = result
            store.saveProxies(proxies)
            refreshRuntimes()
        }
    }

    func deleteProxy(_ id: UUID) {
        proxies.removeAll { $0.id == id }
        store.saveProxies(proxies)
        ProxyPasswords.remove(id)
        catalog.forgetProxy(id)
        refresh()
        refreshRuntimes()
    }

    func password(for id: UUID) -> String? { ProxyPasswords.get(id) }

    /// Open sessions take a new or changed proxy at once (no relaunch).
    private func refreshRuntimes() {
        for session in sessions {
            SessionRuntimes.shared.existing(session.id)?.update(session: session, proxy: proxy(session.proxyID))
        }
    }

    func markOpened(_ id: UUID) {
        catalog.markOpened(id)
        refresh()
    }

    func deleteSession(_ id: UUID) {
        guard let session = catalog.session(id) else { return }
        path.removeAll { $0 == id }
        SessionRuntimes.shared.close(id)
        catalog.delete(id)
        refresh()
        let storeID = session.storeID
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: storeID) }
    }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }

    func proxy(_ id: UUID?) -> ProxyEntry? {
        guard let id else { return nil }
        return proxies.first { $0.id == id }
    }

    func filteredSessions(_ query: String) -> [Session] {
        catalog.filter(query) { [proxies] id in proxies.first { $0.id == id }?.displayName }
    }
}
