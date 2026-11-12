import BrowserCore
import Foundation

/// A persistent cookie, as the sync carries it (the Mac's `ImportedCookie`, in the app's terms).
public struct SyncedCookie: Equatable, Sendable {
    public enum SameSite: String, Sendable { case none, lax, strict }

    public var name: String
    public var value: String
    /// Without the leading dot; `hostOnly` says whether it is the host's alone.
    public var domain: String
    public var hostOnly: Bool
    public var path: String
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: SameSite?

    public init(name: String, value: String, domain: String, hostOnly: Bool, path: String = "/", expires: Date?,
                secure: Bool = false, httpOnly: Bool = false, sameSite: SameSite? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = hostOnly
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }

    init(_ cookie: ImportedCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, hostOnly: cookie.hostOnly, path: cookie.path,
                  expires: cookie.expires, secure: cookie.secure, httpOnly: cookie.httpOnly,
                  sameSite: cookie.sameSite.flatMap { SameSite(rawValue: $0.rawValue) })
    }

    var imported: ImportedCookie {
        ImportedCookie(name: name, value: value, domain: domain, hostOnly: hostOnly, path: path, expires: expires, secure: secure,
                       httpOnly: httpOnly, sameSite: sameSite.flatMap { ImportedCookie.SameSite(rawValue: $0.rawValue) })
    }
}

/// The cookie stores of the iPhone's sessions made from the Mac's profiles, as the sync's run sees
/// them: the app gives them (WebKit's), the run reads and changes them. A session that is open now
/// is closed by the app before the run (the Mac's rule: cookies are applied while a profile is not
/// running).
public protocol SyncCookieStores: Sendable {
    /// The persistent cookies of the session made from `profileID`; nil: no such session here.
    func persistentCookies(profileID: UUID) async -> [SyncedCookie]?
    /// Sets and deletes cookies in that session's store.
    func apply(set: [SyncedCookie], delete: [SyncedCookie], profileID: UUID) async
}

/// The Mac's cookie rules on the iPhone (its SYNC_FORMAT.md, "Cookies"): at each run, for each
/// profile of the vault with a session here — what the store changed since the last run recorded
/// into the profile's document (as of the baseline's time, so that a newer change from the Mac wins),
/// the document applied to the store, and the baseline made the store again. The document is the
/// iPhone's copy in the vault; it goes to the server when the iPhone writes (step 5).
enum SyncCookieRun {
    static func run(repository: ProfileRepository, stores: SyncCookieStores) async -> (set: Int, deleted: Int) {
        var set = 0, deleted = 0
        for summary in repository.list() {
            guard let configuration = try? repository.loadConfiguration(summary.id), configuration.syncCookies,
                  !configuration.ephemeral,
                  let current = await stores.persistentCookies(profileID: summary.id) else { continue }
            guard let loaded = try? repository.cookieJar(for: summary.id),
                  let baseline = try? repository.cookieBaseline(for: summary.id) else { continue }
            let store = current.map(\.imported)
            // A store that never had a run synced (no baseline): its cookies are recorded as of the
            // earliest time — any synced change wins over them — as the Mac does at a first launch.
            let jar = Faults.isActive(.syncCookiesOverwriteLocal) ? loaded : loaded.atLaunch(store: store, baseline: baseline, storeRestored: true)
            if jar != loaded { try? repository.saveCookieJar(jar, for: summary.id) }
            let changes = jar.changes(over: store)
            if !changes.set.isEmpty || !changes.delete.isEmpty {
                await stores.apply(set: changes.set.map(SyncedCookie.init), delete: changes.delete.map(SyncedCookie.init), profileID: summary.id)
            }
            set += changes.set.count
            deleted += changes.delete.count
            let after = await stores.persistentCookies(profileID: summary.id) ?? current
            try? repository.saveCookieBaseline(CookieBaseline(cookies: after.map(\.imported), savedAt: Date()), for: summary.id)
        }
        return (set, deleted)
    }
}
