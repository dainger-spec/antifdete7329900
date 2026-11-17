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
    /// Which store that session has (its WebKit data store's identifier): a session deleted and made
    /// again has another one, empty. Nil: no such session here, or stores that cannot tell.
    func storeID(profileID: UUID) async -> UUID?
}

extension SyncCookieStores {
    public func storeID(profileID: UUID) async -> UUID? { nil }
}

/// The Mac's cookie rules on the iPhone (its SYNC_FORMAT.md, "Cookies"): at each run, for each
/// profile of the vault with a session here — what the store changed since the last run recorded
/// into the profile's document (as of the baseline's time, so that a newer change from the Mac wins),
/// the document applied to the store, and the baseline made the store again. The document is the
/// iPhone's copy in the vault; it goes to the server when the iPhone writes (step 5).
///
/// A baseline is measured only against the store it was taken from (`BaselineStores`). A store that
/// is another one — the session deleted here and made again, its store new and empty — never
/// had the baseline's cookies: measured against it, every one of them would be recorded as
/// deleted, and the deletions would take them off the Mac and every device (audit 3, #2; the Mac's
/// own rule for a store that came up with nothing, `CookieJarDocument.atLaunch`). Such a store is
/// taken as one that never had a run synced. And a profile with no session here keeps no baseline.
enum SyncCookieRun {
    static func run(repository: ProfileRepository, stores: SyncCookieStores, root: URL) async -> (set: Int, deleted: Int) {
        var set = 0, deleted = 0
        let kept = BaselineStores.load(root: root)
        var taken = kept.filter { id, _ in repository.list().contains { $0.id == id } }
        for summary in repository.list() {
            guard let configuration = try? repository.loadConfiguration(summary.id), configuration.syncCookies,
                  !configuration.ephemeral else { continue }
            guard let current = await stores.persistentCookies(profileID: summary.id) else {
                // No session here (deleted, or not made yet): the baseline of the store it had is no
                // one's now. A session made for the profile later starts from none.
                taken[summary.id] = nil
                if let baseline = try? repository.cookieBaseline(for: summary.id), baseline != CookieBaseline() {
                    try? repository.saveCookieBaseline(CookieBaseline(), for: summary.id)
                }
                continue
            }
            guard let loaded = try? repository.cookieJar(for: summary.id),
                  var baseline = try? repository.cookieBaseline(for: summary.id) else { continue }
            // Taken from another store (or from one not known): not this one's. Stores that cannot tell
            // which they are keep their baselines.
            let storeID = await stores.storeID(profileID: summary.id)
            if let storeID, taken[summary.id] != storeID { baseline = CookieBaseline() }
            let store = current.map(\.imported)
            // A store that never had a run synced (no baseline, or another store's): its cookies are
            // recorded as of the earliest time — any synced change wins over them — and none is
            // recorded as deleted, as the Mac does at a first launch.
            let jar = Faults.isActive(.syncCookiesOverwriteLocal) ? loaded : loaded.atLaunch(store: store, baseline: baseline, storeRestored: true)
            if jar != loaded { try? repository.saveCookieJar(jar, for: summary.id) }
            let changes = jar.changes(over: store)
            if !changes.set.isEmpty || !changes.delete.isEmpty {
                await stores.apply(set: changes.set.map(SyncedCookie.init), delete: changes.delete.map(SyncedCookie.init), profileID: summary.id)
            }
            set += changes.set.count
            deleted += changes.delete.count
            let after = await stores.persistentCookies(profileID: summary.id) ?? current
            if (try? repository.saveCookieBaseline(CookieBaseline(cookies: after.map(\.imported), savedAt: Date()), for: summary.id)) != nil {
                taken[summary.id] = storeID
            }
        }
        // After the baselines it names: a run stopped between the two leaves a baseline taken for
        // another store's — measured against none, never a store against another's baseline.
        if taken != kept { BaselineStores.save(taken, root: root) }
        return (set, deleted)
    }
}

/// Which store each profile's cookie baseline was taken from: `cookie-baseline-stores.json` in the
/// iPhone's copy of the vault, beside the Mac's files — the iPhone's own, never synced, gone with
/// the copy. A profile not named has a baseline of no store known (a build from before), or none.
enum BaselineStores {
    private struct File: Codable {
        var version = 1
        /// Profile id → store id.
        var stores: [String: String]
    }

    static func url(root: URL) -> URL { root.appendingPathComponent("cookie-baseline-stores.json") }

    static func load(root: URL) -> [UUID: UUID] {
        guard let data = try? Data(contentsOf: url(root: root)), let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        var stores: [UUID: UUID] = [:]
        for (profile, store) in file.stores {
            guard let profileID = UUID(uuidString: profile), let storeID = UUID(uuidString: store) else { continue }
            stores[profileID] = storeID
        }
        return stores
    }

    static func save(_ stores: [UUID: UUID], root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let file = File(stores: Dictionary(uniqueKeysWithValues: stores.map { ($0.key.uuidString, $0.value.uuidString) }))
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url(root: root), options: [.atomic])
    }
}
