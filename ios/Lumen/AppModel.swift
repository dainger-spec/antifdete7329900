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

/// Where the app's rights come from (`Access`): the Lumen account — the server's signed document of
/// rights, or the free level while nobody is signed in (Account.swift). So it is in a release build,
/// always, and in a DEBUG build unless a test fixes them by name (LUMEN_TEST_ACCESS) — the server
/// knows iPhones since v2026.11.10.3, and the mode "everything open by default" is gone with that
/// (the lead, 10 November 2026):
///   full    — everything, for a test that checks something else than rights;
///   free    — the free level; none — a paid period that ended;
///   account, or nothing — nothing fixed: the account decides.
enum AccessSource {
    /// The rights fixed for this launch; nil: the account decides.
    static func fixed() -> Access? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["LUMEN_TEST_ACCESS"] {
        case "full": return .full
        case "free": return .free
        case "none": return .expired
        default: return nil
        }
        #else
        return nil
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
    /// What this iPhone may do now (the one place rights come from).
    @Published private(set) var access: Access
    /// The rights a test fixed (DEBUG builds); nil: the account decides them.
    let fixedAccess: Access?
    /// Where this iPhone stands with the account server.
    @Published private(set) var license = LicenseState(mode: .notSignedIn, access: .free)
    /// This iPhone's place in a license, once signed in.
    @Published private(set) var account: AccountRecord?
    /// What the server last said that the person must read (the iPhone unlinked, …).
    @Published var accountNotice: String?
    /// This iPhone's clock against the server's at the last answer (§8.3): `clock.skew` beyond ten minutes.
    @Published var clockSkew: TimeInterval = 0
    /// The `period.ending` stage the person closed, for which period's end ("<end>|<stage>").
    @Published var dismissedEnding: String? = UserDefaults.standard.string(forKey: "notice.periodEnding")
    /// The document `license` was decided by, when it passed the check.
    var entitlement: Entitlement?
    var refreshFailures = 0
    var nextRefreshAttempt = Date.distantPast
    var refreshing = false
    var accountTimer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = LumenStore(root: support.appendingPathComponent("Lumen", isDirectory: true))
        fixedAccess = AccessSource.fixed()
        access = fixedAccess ?? .free
        if LaunchOptions.resetState {
            store.removeAll()
            ProxyPasswords.removeAll()
            AccountStore.save(nil)   // the iPhone's own identifier stays, as it does through a reinstall
        }
        catalog = SessionCatalog(store: store)
        refresh()
        startAccount()
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

    /// Whether the plan lets one more profile be made (Access: the free plan keeps two).
    var mayCreateSession: Bool { access.mayCreateProfile(having: sessions.count) }

    /// A new session, if the plan allows one more; nil otherwise.
    @discardableResult
    func createSession(name: String, notes: String, tags: String) -> Session? {
        guard mayCreateSession else { return nil }
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

    /// A proxy given to a session binds it to proxies; `unbind` — the person's own choice, confirmed —
    /// lets a session that had one go without it.
    func setProxy(_ id: UUID, proxyID: UUID?, unbind: Bool = false) {
        // A plan without proxies gives none (the free plan): the settings offer none either.
        if proxyID != nil, !access.proxies { return }
        catalog.setProxy(id, proxyID: proxyID, unbind: unbind)
        refresh()
        refreshRuntimes()
    }

    /// The proxy `session` may go through now: its own, if the rights allow proxies at all. Without them
    /// a session would have none — which, for one that lived behind a proxy, the lock below forbids.
    func usableProxy(_ session: Session) -> ProxyEntry? {
        access.proxies ? proxy(session.proxyID) : nil
    }

    /// Whether `session` may open now: one that lived behind a proxy never opens without one it may
    /// use, and one beyond the plan's count of profiles stays shut (the ones made first are open).
    func lock(_ session: Session) -> SessionLock {
        let within = License.withinLimit(sessions, allowed: access.maxProfiles).contains(session.id)
        return SessionLock.of(session, proxyExists: proxy(session.proxyID) != nil, access: access, overLimit: !within)
    }

    /// Whether a lock on `session` is the proxy's — it lived behind one and may not use one now — and
    /// not the plan's (no right to open sites, or a profile beyond the plan's count).
    func lockedForProxy(_ session: Session) -> Bool {
        access.browse && License.withinLimit(sessions, allowed: access.maxProfiles).contains(session.id)
    }

    /// The account's decision, applied: the rights, who is signed in — and the open sessions told.
    func apply(_ state: LicenseState, account: AccountRecord?, entitlement: Entitlement?) {
        self.entitlement = entitlement
        if license != state { license = state }
        if self.account != account { self.account = account }
        if access != state.access {
            access = state.access
            refreshRuntimes()
        }
    }

    // MARK: The sync

    /// The Mac's profiles as the sync read them, made sessions here (ios/SYNC_PLAN.md, step 3). A
    /// profile's proxy becomes an entry of the list — the one already there for the same address and
    /// login, its password brought up to date in the Keychain — and the session is bound to it.
    @discardableResult
    func applySynced(_ profiles: [SyncedProfile]) -> Int {
        var added: [UUID] = []
        let made = catalog.applySynced(profiles) { proxy in
            if let found = proxies.first(where: { $0.kind == proxy.kind && $0.host == proxy.host && $0.port == proxy.port
                                                  && $0.username == proxy.username }) {
                if ProxyPasswords.get(found.id) != proxy.password { ProxyPasswords.set(proxy.password, for: found.id) }
                return found.id
            }
            var entry = ProxyEntry(kind: proxy.kind, host: proxy.host, port: proxy.port, username: proxy.username)
            entry.hasPassword = !proxy.password.isEmpty
            ProxyPasswords.set(proxy.password, for: entry.id)
            proxies.append(entry)
            added.append(entry.id)
            return entry.id
        }
        if !added.isEmpty { store.saveProxies(proxies) }
        refresh()
        refreshRuntimes()
        added.forEach(check)
        return made.count
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
            if Faults.isActive(.recheckDropsProxy), proxies[index].check?.alive == true, !result.alive {
                // The planted fault: a proxy found dead is taken off its sessions, which then go direct — the
                // binding cleared too, or the lock (SessionLock) would keep them shut and the fault would
                // plant nothing (CI run 32); the lock has its own red, lockedOpensDirect.
                for session in sessions where session.proxyID == id { catalog.setProxy(session.id, proxyID: nil, unbind: true) }
                refresh()
            }
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
    func refreshRuntimes() {
        for session in sessions {
            SessionRuntimes.shared.existing(session.id)?.update(session: session, proxy: usableProxy(session),
                                                                locked: lock(session).isLocked)
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
