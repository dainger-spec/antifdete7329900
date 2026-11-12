import Foundation
import LumenCore
import WebKit

/// The sessions' WebKit cookie stores, as the sync's run sees them (SyncCookieStores; step 4 of
/// ios/SYNC_PLAN.md): only persistent cookies, the partitioned ones (CHIPS) left out — the Mac's own
/// rules (its CookieStoreSync). The sessions made from the vault's profiles are closed first by the
/// app: a store is changed while no page of it runs.
final class CookieBridge: SyncCookieStores, @unchecked Sendable {
    /// The vault's profile → the data store of the session made from it.
    private let stores: [UUID: UUID]

    init(sessions: [Session]) {
        var stores: [UUID: UUID] = [:]
        for session in sessions {
            if let profile = session.syncedProfileID { stores[profile] = session.storeID }
        }
        self.stores = stores
    }

    func persistentCookies(profileID: UUID) async -> [SyncedCookie]? {
        guard let storeID = stores[profileID] else { return nil }
        let all = await Self.allCookies(storeID)
        return all.compactMap(Self.cookie(from:))
    }

    func apply(set: [SyncedCookie], delete: [SyncedCookie], profileID: UUID) async {
        guard let storeID = stores[profileID] else { return }
        let all = await Self.allCookies(storeID)
        let gone = Set((delete + set).map(Self.key))
        for cookie in all where !cookie.isSessionOnly {
            guard let synced = Self.cookie(from: cookie), gone.contains(Self.key(synced)) else { continue }
            await Self.store(storeID) { store, done in store.delete(cookie, completionHandler: done) }
        }
        for synced in set {
            guard let cookie = Self.httpCookie(synced) else { continue }
            await Self.store(storeID) { store, done in store.setCookie(cookie, completionHandler: done) }
        }
    }

    // MARK: WebKit

    @MainActor
    private static func cookieStore(_ storeID: UUID) -> WKHTTPCookieStore {
        WKWebsiteDataStore(forIdentifier: storeID).httpCookieStore
    }

    private static func allCookies(_ storeID: UUID) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                cookieStore(storeID).getAllCookies { continuation.resume(returning: $0) }
            }
        }
    }

    private static func store(_ storeID: UUID, _ change: @escaping @MainActor (WKHTTPCookieStore, @escaping () -> Void) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in change(cookieStore(storeID)) { continuation.resume() } }
        }
    }

    private static func key(_ cookie: SyncedCookie) -> String {
        [cookie.name, cookie.hostOnly ? cookie.domain : "." + cookie.domain, cookie.path].joined(separator: "\u{0}")
    }

    /// A persistent, unpartitioned cookie as the sync carries it; nil for the others.
    static func cookie(from cookie: HTTPCookie) -> SyncedCookie? {
        guard !cookie.isSessionOnly, let expires = cookie.expiresDate else { return nil }
        if let partition = cookie.properties?[HTTPCookiePropertyKey("StoragePartition")] as? String, !partition.isEmpty { return nil }
        let stored = cookie.domain.lowercased()
        let hostOnly = !stored.hasPrefix(".")
        var sameSite: SyncedCookie.SameSite?
        if cookie.sameSitePolicy == .sameSiteLax { sameSite = .lax }
        if cookie.sameSitePolicy == .sameSiteStrict { sameSite = .strict }
        return SyncedCookie(name: cookie.name, value: cookie.value, domain: hostOnly ? stored : String(stored.dropFirst()),
                            hostOnly: hostOnly, path: cookie.path, expires: expires, secure: cookie.isSecure,
                            httpOnly: cookie.isHTTPOnly, sameSite: sameSite)
    }

    static func httpCookie(_ cookie: SyncedCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name, .value: cookie.value, .path: cookie.path.isEmpty ? "/" : cookie.path,
            .domain: cookie.hostOnly ? cookie.domain : "." + cookie.domain,
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.secure { properties[.secure] = "TRUE" }
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch cookie.sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}
