import Foundation

/// Which cookie a record is about: a cookie store keeps one per name, domain (a leading dot for a
/// domain cookie, none for a host-only one) and path.
public struct CookieKey: Codable, Hashable, Comparable, Sendable {
    public var name: String
    public var domain: String
    public var path: String

    public init(name: String, domain: String, path: String) {
        self.name = name
        self.domain = domain
        self.path = path
    }

    public init(_ cookie: ImportedCookie) {
        self.init(name: cookie.name, domain: cookie.storedDomain, path: cookie.path)
    }

    public static func < (a: CookieKey, b: CookieKey) -> Bool {
        (a.domain, a.path, a.name) < (b.domain, b.path, b.name)
    }
}

extension ImportedCookie {
    /// The same cookie state: equal, an expiry within a second aside (stores keep milliseconds,
    /// the synced document whole seconds).
    public func isSameState(as other: ImportedCookie) -> Bool {
        var a = self, b = other
        let close: Bool
        switch (a.expires, b.expires) {
        case (nil, nil): close = true
        case let (x?, y?): close = abs(x.timeIntervalSince(y)) < 1
        default: close = false
        }
        a.expires = nil
        b.expires = nil
        return close && a == b
    }
}

/// A profile's persistent cookies as they sync between devices (`cookies.bin`).
///
/// Each cookie carries the time this browser saw it change; each deletion leaves a tombstone with
/// its time. Two devices' documents merge cookie by cookie: the newer change wins, a deletion
/// included (a cookie changed after its deletion elsewhere comes back). Session cookies are not in
/// it: they end with the run that set them, on every device.
///
/// A device turns its cookie store into changes by comparing it with what the store held the
/// last time it was recorded or applied (`CookieBaseline`, kept on that device only); it applies
/// the document to its store at launch, before the first page loads.
public struct CookieJarDocument: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var cookie: ImportedCookie
        public var updatedAt: Date
    }

    public struct Tombstone: Codable, Equatable, Sendable {
        public var key: CookieKey
        public var deletedAt: Date
    }

    public var format = 1
    public var cookies: [Entry] = []
    public var deleted: [Tombstone] = []

    public init(cookies: [Entry] = [], deleted: [Tombstone] = []) {
        self.cookies = cookies
        self.deleted = deleted
    }

    /// Tombstones are kept this long: longer than any device stays unsynced in practice, and a
    /// browser keeps no cookie longer than 400 days anyway.
    public static let tombstoneLifetime: TimeInterval = 400 * 86_400

    /// The live cookies (not expired at `now`).
    public func liveCookies(at now: Date) -> [ImportedCookie] {
        cookies.map(\.cookie).filter { ($0.expires ?? .distantFuture) > now }
    }

    /// Merges two devices' documents: per cookie, the newer change wins (on the same second, a
    /// deletion, then the larger value, expiry, flags, so that the order does not matter).
    public static func merge(_ a: CookieJarDocument, _ b: CookieJarDocument, now: Date = Date()) -> CookieJarDocument {
        enum Event {
            case set(Entry)
            case delete(Date)
            var time: Date {
                switch self {
                case let .set(entry): return entry.updatedAt
                case let .delete(date): return date
                }
            }
        }
        func wins(_ x: Event, over y: Event) -> Bool {
            if x.time != y.time { return x.time > y.time }
            switch (x, y) {
            case (.delete, .set): return true
            case (.set, .delete): return false
            case let (.set(p), .set(q)):
                func order(_ c: ImportedCookie) -> (String, Date, Bool, Bool, String) {
                    (c.value, c.expires ?? .distantPast, c.secure, c.httpOnly, c.sameSite?.rawValue ?? "")
                }
                let (x, y) = (order(p.cookie), order(q.cookie))
                if x.0 != y.0 { return x.0 > y.0 }
                if x.1 != y.1 { return x.1 > y.1 }
                return (x.2 ? 1 : 0, x.3 ? 1 : 0, x.4) > (y.2 ? 1 : 0, y.3 ? 1 : 0, y.4)
            case (.delete, .delete): return false
            }
        }
        var latest: [CookieKey: Event] = [:]
        let events = (a.cookies + b.cookies).map { (CookieKey($0.cookie), Event.set($0)) }
            + (a.deleted + b.deleted).map { ($0.key, Event.delete($0.deletedAt)) }
        for (key, event) in events {
            if let current = latest[key], !wins(event, over: current) { continue }
            latest[key] = event
        }
        var result = CookieJarDocument()
        for (key, event) in latest {
            switch event {
            case let .set(entry): result.cookies.append(entry)
            case let .delete(date): result.deleted.append(Tombstone(key: key, deletedAt: date))
            }
        }
        return result.pruned(at: now)
    }

    /// What `store` (the store's persistent cookies now) changed since `baseline` (what it held
    /// when last recorded or applied), written into the document as changes made at `time`.
    public func recording(store: [ImportedCookie], baseline: [ImportedCookie], at time: Date) -> CookieJarDocument {
        let now = Date()
        let current = Dictionary(store.filter { $0.expires != nil }.map { (CookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
        let before = Dictionary(baseline.map { (CookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
        var entries = Dictionary(cookies.map { (CookieKey($0.cookie), $0) }, uniquingKeysWith: { _, last in last })
        var tombstones = Dictionary(deleted.map { ($0.key, $0.deletedAt) }, uniquingKeysWith: max)
        for (key, cookie) in current {
            guard before[key].map({ !$0.isSameState(as: cookie) }) ?? true else { continue }
            // Already the document's state (applied from it): not a change of this device's.
            if let entry = entries[key], entry.cookie.isSameState(as: cookie) { continue }
            // The document knows a newer change (from another device, not applied yet).
            if let entry = entries[key], entry.updatedAt > time { continue }
            if let deletedAt = tombstones[key], deletedAt > time { continue }
            entries[key] = Entry(cookie: cookie, updatedAt: time)
            tombstones[key] = nil
        }
        for (key, gone) in before where current[key] == nil {
            // Expired: every device's store drops it by itself, no deletion to sync.
            if let expires = gone.expires, expires <= now { continue }
            // Deleted from the store: deleted, unless the document has a newer version than this change.
            if let entry = entries[key], entry.updatedAt > time { continue }
            entries[key] = nil
            tombstones[key] = max(tombstones[key] ?? time, time)
        }
        return CookieJarDocument(cookies: entries.values.sorted { CookieKey($0.cookie) < CookieKey($1.cookie) },
                                 deleted: tombstones.map { Tombstone(key: $0.key, deletedAt: $0.value) }.sorted { $0.key < $1.key })
            .pruned(at: now)
    }

    /// What to do to `store` (its persistent cookies) to make it hold the document: cookies to
    /// set (new or different) and cookies to delete (tombstoned). Store cookies the document does
    /// not know are left alone.
    public func changes(over store: [ImportedCookie], at now: Date = Date()) -> (set: [ImportedCookie], delete: [ImportedCookie]) {
        let current = Dictionary(store.map { (CookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
        let live = liveCookies(at: now)
        let set = live.filter { cookie in current[CookieKey(cookie)].map { !$0.isSameState(as: cookie) } ?? true }
        let liveKeys = Set(live.map(CookieKey.init))
        let delete = deleted.compactMap { tombstone -> ImportedCookie? in
            liveKeys.contains(tombstone.key) ? nil : current[tombstone.key]
        }
        return (set, delete)
    }

    /// Without expired cookies and old tombstones; sorted, so equal documents encode equally.
    func pruned(at now: Date) -> CookieJarDocument {
        CookieJarDocument(
            cookies: cookies.filter { ($0.cookie.expires ?? .distantFuture) > now }.sorted { CookieKey($0.cookie) < CookieKey($1.cookie) },
            deleted: deleted.filter { now.timeIntervalSince($0.deletedAt) < Self.tombstoneLifetime }.sorted { $0.key < $1.key })
    }
}

/// What a profile's cookie store held when this device last recorded it into, or applied, the
/// synced document: the reference changes are measured against. Kept on this device only
/// (`cookies-baseline.bin`), never synced.
public struct CookieBaseline: Codable, Equatable, Sendable {
    public var cookies: [ImportedCookie]
    public var savedAt: Date

    public init(cookies: [ImportedCookie] = [], savedAt: Date = .distantPast) {
        self.cookies = cookies
        self.savedAt = savedAt
    }
}
