import Foundation

/// A copy of a profile's persistent cookies, taken while it runs (docs/COOKIE_RECOVERY.md).
///
/// WebKit's cookie store can lose cookies: a crash or a forced quit before CFNetwork wrote them,
/// a damaged cookie file, website data that went missing. For a profile whose accounts were
/// warmed up and logged in, that is the accounts gone. A snapshot is what the store held, so that
/// a launch which finds the store has lost them can put them back before its first page loads.
///
/// Only persistent cookies that had not expired when it was taken: a session cookie ends with the
/// run that set it, and is never brought back. One cookie per name, domain and path, sorted, so
/// that two snapshots of the same store are equal.
public struct CookieSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// What made the snapshot.
    public enum Trigger: String, Codable, Sendable {
        /// A look while the profile runs found its cookies changed (`CookieRecovery.shouldSnapshot`).
        case periodic
        /// The profile stopped cleanly: quit, its last window closed, stopped from the Profiles window.
        case close
        /// Lumen itself changed the store: a cookie import, a restore, a WebDriver command, the
        /// launch (synced cookies applied, imported cookies put in).
        case change
    }

    public var id: UUID
    public var takenAt: Date
    public var trigger: Trigger
    public var cookies: [ImportedCookie]

    /// `cookies` as the store holds them: session cookies and cookies expired at `takenAt` are
    /// left out, and one per name, domain and path is kept (the last).
    public init(id: UUID = UUID(), takenAt: Date, trigger: Trigger, cookies: [ImportedCookie]) {
        self.id = id
        self.takenAt = takenAt
        self.trigger = trigger
        self.cookies = CookieRecovery.persistent(cookies, liveAt: takenAt)
    }

    private enum CodingKeys: String, CodingKey { case id, takenAt, trigger, cookies }

    /// Tolerant of a trigger a later version adds: read as a periodic one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        trigger = (try? c.decode(Trigger.self, forKey: .trigger)) ?? .periodic
        cookies = try c.decode([ImportedCookie].self, forKey: .cookies)
    }

    /// Its cookies that have not expired at `now`: the only ones a restore may put back.
    public func liveCookies(at now: Date) -> [ImportedCookie] {
        cookies.filter { ($0.expires ?? .distantPast) > now }
    }
}

/// A profile's last snapshots (`cookie-snapshots.bin`, sealed under a key derived from the profile's
/// key; this Mac only: not synced, not in a profile export), oldest first.
public struct CookieSnapshots: Codable, Equatable, Sendable {
    /// How many are kept: the newest, and two before it to go back to by hand.
    public static let kept = 3

    public private(set) var snapshots: [CookieSnapshot]

    public init(snapshots: [CookieSnapshot] = []) {
        self.snapshots = Array(snapshots.suffix(Self.kept))
    }

    /// The last one taken: what the store held as far as Lumen knows.
    public var latest: CookieSnapshot? { snapshots.last }

    public var newestFirst: [CookieSnapshot] { snapshots.reversed() }

    /// Adds `snapshot` as the newest, the oldest going beyond `kept`. In the order they were taken,
    /// not by their clocks: a clock set back does not make a new snapshot an old one.
    public mutating func add(_ snapshot: CookieSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > Self.kept { snapshots.removeFirst(snapshots.count - Self.kept) }
    }
}

/// When a profile's cookies are copied, and when and what a launch puts back
/// (docs/COOKIE_RECOVERY.md). Pure decisions: the app reads the store and the disk, asks here, and
/// does what it is told.
public enum CookieRecovery {
    /// A running profile's cookies are looked at this often (a read of its store, nothing written
    /// when they are as the newest snapshot has them).
    public static let checkInterval: TimeInterval = 30
    /// A changed store is copied at most this often, but for a mass removal (`isMassRemoval`), a
    /// clean stop and Lumen's own changes, which are copied at once.
    public static let snapshotInterval: TimeInterval = 180
    /// "Far fewer": the store keeps less than this share of the snapshot's cookies.
    public static let lossShare = 0.5

    /// What a launch found on disk of the profile's website data, before its store existed.
    public enum StoreState: String, Equatable, Sendable {
        /// No website data at all — no archive, nothing an earlier run left — while snapshots are
        /// kept: the store is missing.
        case missing
        /// A cookie file that is WebKit's and does not hold together (`BinaryCookiesFile`).
        case damaged
        /// Website data that came up as the earlier run left it, as far as can be told from disk.
        case present
    }

    /// How the profile's last run ended: whether its store was copied as it stopped.
    public enum RunEnd: String, Equatable, Sendable {
        /// Stopped cleanly: the newest snapshot is the store as it was sealed, and nothing changes a
        /// sealed store.
        case clean
        /// Crashed, killed, forced to quit (its running mark was left): the newest snapshot may be
        /// a few minutes older than the store's last state.
        case unclean
    }

    /// Why a launch put cookies back.
    public enum Cause: String, Codable, Equatable, Sendable {
        case websiteDataMissing
        case cookieFileDamaged
        /// The last run ended uncleanly, and the store kept fewer than half of the snapshot's cookies.
        case uncleanEnd
        /// The last run ended cleanly, and the store lacks cookies its last snapshot had: a store
        /// cannot lose cookies while it is sealed but by damage (or a write CFNetwork never made).
        case cleanEnd
    }

    /// Why a launch put nothing back.
    public enum Keep: String, Equatable, Sendable {
        case noSnapshot
        /// The newest snapshot holds no cookie that is still valid.
        case nothingToRestore
        /// The store has every cookie of the snapshot (perhaps with other values: kept as they are).
        case nothingMissing
        /// After an unclean end the store lacks a few of the snapshot's cookies: a site's sign-out,
        /// the person's own deletions since the snapshot — theirs, not a loss.
        case fewMissingAfterUncleanEnd
    }

    public enum Decision: Equatable, Sendable {
        case keep(Keep)
        /// Put `cookies` back: the snapshot's cookies that are still valid and that the store does
        /// not have at all (one it has, with any value, stays as it is).
        case restore(cookies: [ImportedCookie], snapshot: CookieSnapshot, cause: Cause)
    }

    /// At a launch, before the first page loads and before synced cookies are applied: whether the
    /// store lost the profile's cookies, and which to put back.
    ///
    /// `store`: its persistent cookies as it came up. `state`: what was found on disk before it
    /// existed. `end`: how the last run ended. `latest`: the newest snapshot.
    ///
    ///   * missing website data or a damaged cookie file: every cookie the store lacks comes back;
    ///   * after a clean end: the same — the newest snapshot is the store as it was sealed, so a
    ///     cookie it lacks now was lost, not deleted;
    ///   * after an unclean end: only when the store kept fewer than half of the snapshot's cookies.
    ///     Fewer gone are what the person or the sites did since the snapshot (a sign-out), and stay
    ///     gone; a mass removal while the profile ran was copied at once (`shouldSnapshot`), so a
    ///     clear is not undone either.
    ///
    /// Never a cookie that has expired, never a session cookie, never one the store has.
    public static func decide(store: [ImportedCookie], state: StoreState, end: RunEnd, latest: CookieSnapshot?,
                              now: Date) -> Decision {
        guard let latest else { return .keep(.noSnapshot) }
        let live = latest.liveCookies(at: now)
        guard !live.isEmpty else { return .keep(.nothingToRestore) }
        let present = Set(store.map(CookieKey.init))
        let missing = live.filter { !present.contains(CookieKey($0)) }
        guard !missing.isEmpty else { return .keep(.nothingMissing) }
        switch state {
        case .missing: return .restore(cookies: missing, snapshot: latest, cause: .websiteDataMissing)
        case .damaged: return .restore(cookies: missing, snapshot: latest, cause: .cookieFileDamaged)
        case .present: break
        }
        switch end {
        case .clean:
            return .restore(cookies: missing, snapshot: latest, cause: .cleanEnd)
        case .unclean:
            let kept = live.count - missing.count
            guard isFarFewer(kept: kept, of: live.count) else { return .keep(.fewMissingAfterUncleanEnd) }
            return .restore(cookies: missing, snapshot: latest, cause: .uncleanEnd)
        }
    }

    /// Fewer than `lossShare` of `total` kept.
    static func isFarFewer(kept: Int, of total: Int) -> Bool {
        total > 0 && Double(kept) < Double(total) * lossShare
    }

    /// Whether a running profile's store is to be copied now. Never when it holds what the newest
    /// snapshot holds (a cookie's expiry within a second aside), nor a first snapshot of nothing.
    /// Otherwise: at a clean stop and after Lumen's own change, at once; while it runs, when the
    /// newest snapshot is `snapshotInterval` old (or from a clock ahead of this one), or at once when
    /// most of its cookies are gone (`isMassRemoval`).
    public static func shouldSnapshot(store: [ImportedCookie], latest: CookieSnapshot?, trigger: CookieSnapshot.Trigger,
                                      now: Date) -> Bool {
        let current = persistent(store, liveAt: now)
        guard let latest else { return !current.isEmpty }
        if sameCookies(current, latest.liveCookies(at: now)) { return false }
        switch trigger {
        case .close, .change:
            return true
        case .periodic:
            let age = now.timeIntervalSince(latest.takenAt)
            return age >= snapshotInterval || age < 0 || isMassRemoval(store: current, latest: latest, now: now)
        }
    }

    /// The running store kept fewer than half of the newest snapshot's cookies: a clear, a sign-out
    /// of the one site that set most of them — what the person or a site did, which a crash right
    /// after must not undo. A store loses cookies on disk, never in a running process.
    public static func isMassRemoval(store: [ImportedCookie], latest: CookieSnapshot, now: Date) -> Bool {
        let live = latest.liveCookies(at: now)
        let present = Set(store.map(CookieKey.init))
        return isFarFewer(kept: live.filter { present.contains(CookieKey($0)) }.count, of: live.count)
    }

    /// The same cookies in the same state, whatever their order (an expiry within a second aside).
    public static func sameCookies(_ a: [ImportedCookie], _ b: [ImportedCookie]) -> Bool {
        let left = unique(a), right = Dictionary(unique(b).map { (CookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
        guard left.count == right.count else { return false }
        return left.allSatisfy { cookie in right[CookieKey(cookie)].map { $0.isSameState(as: cookie) } ?? false }
    }

    /// What a restore the person asked for puts back from `snapshot`: its cookies still valid at `now`.
    public static func manualRestore(from snapshot: CookieSnapshot, now: Date) -> [ImportedCookie] {
        snapshot.liveCookies(at: now)
    }

    /// The persistent cookies of `cookies` that have not expired at `now`, one per name, domain and
    /// path (the last), sorted by them.
    static func persistent(_ cookies: [ImportedCookie], liveAt now: Date) -> [ImportedCookie] {
        unique(cookies.filter { ($0.expires ?? .distantPast) > now })
    }

    private static func unique(_ cookies: [ImportedCookie]) -> [ImportedCookie] {
        Dictionary(cookies.map { (CookieKey($0), $0) }, uniquingKeysWith: { _, last in last })
            .values.sorted { CookieKey($0) < CookieKey($1) }
    }
}

/// WebKit's cookie file (`Cookies.binarycookies`, CFNetwork's format), checked for holding together
/// — never read for its cookies: their names and values stay where they are.
///
/// The format, as CFNetwork writes it: `cook`, the number of pages and each page's size (big-endian),
/// then the pages; a page starts `00 00 01 00`, then its number of cookies and their offsets in it
/// (little-endian), each cookie starting with its own size. A checksum and a footer follow the pages.
public enum BinaryCookiesFile {
    public enum Check: Equatable, Sendable {
        /// The pages hold together; `cookies` is how many cookie records they hold.
        case wellFormed(cookies: Int)
        /// WebKit's file that does not hold together: cut short, pages or records running past
        /// their ends. `reason` says which, without anything of a cookie.
        case damaged(String)
        /// Not this format: another WebKit's, perhaps. Says nothing either way.
        case unrecognized
    }

    /// At most this many pages and records per page: more is not a cookie file but garbage.
    static let maximumPages = 1_000_000
    static let maximumPerPage = 1_000_000

    public static func check(_ data: Data) -> Check {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return .damaged("empty") }
        guard bytes.count >= 4 else { return .damaged("cut short before its signature") }
        guard bytes[0..<4].elementsEqual(Array("cook".utf8)) else { return .unrecognized }
        guard bytes.count >= 8 else { return .damaged("cut short before its page count") }
        func be32(_ at: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(bytes[at + $1]) } }
        func le32(_ at: Int) -> Int { (0..<4).reversed().reduce(0) { ($0 << 8) | Int(bytes[at + $1]) } }
        let pages = be32(4)
        guard pages <= maximumPages else { return .damaged("page count out of range") }
        let tableEnd = 8 + 4 * pages
        guard tableEnd <= bytes.count else { return .damaged("cut short in its page table") }
        var start = tableEnd
        var cookies = 0
        for page in 0..<pages {
            let size = be32(8 + 4 * page)
            guard size >= 12, start + size <= bytes.count else { return .damaged("page \(page + 1) runs past the end") }
            // Another layout of page: not known here.
            guard bytes[start..<start + 4].elementsEqual([0x00, 0x00, 0x01, 0x00]) else { return .unrecognized }
            let count = le32(start + 4)
            guard count <= maximumPerPage, 8 + 4 * count + 4 <= size else { return .damaged("page \(page + 1): its records do not fit") }
            for index in 0..<count {
                let offset = le32(start + 8 + 4 * index)
                guard offset >= 8 + 4 * count, offset + 4 <= size else { return .damaged("page \(page + 1): a record outside it") }
                let length = le32(start + offset)
                guard length >= 4, offset + length <= size else { return .damaged("page \(page + 1): a record runs past it") }
            }
            cookies += count
            start += size
        }
        return .wellFormed(cookies: cookies)
    }
}

extension CookieJarDocument {
    /// `atLaunch` for a store found to have lost the profile's cookies — its website data missing, or
    /// cookies put back from a snapshot (`CookieRecovery`) — whose losses are not deletions. The newest
    /// snapshot, when it is at least as new as the baseline, is this Mac's own record of the run before:
    /// what it lacks of the baseline that the store does not hold either was deleted since (a sign-out,
    /// a deletion through Lumen, copied at once) and is recorded so — otherwise these synced cookies,
    /// applied to the store, would bring back a deletion the lost store had not written. `store` with
    /// what the snapshot holds and the store does not (WebKit refused it) is taken for the store the run
    /// left, its changes recorded as of the baseline's time: any change another device made since wins.
    /// Without such a snapshot, nothing it lacks is a deletion (`LaunchStore.recovered`).
    public func atLaunch(afterLoss store: [ImportedCookie], snapshot: CookieSnapshot?, baseline: CookieBaseline,
                         now: Date = Date()) -> CookieJarDocument {
        guard let snapshot, snapshot.takenAt >= baseline.savedAt else {
            return atLaunch(store: store, baseline: baseline, came: .recovered)
        }
        let present = Set(store.map(CookieKey.init))
        let left = store + snapshot.liveCookies(at: now).filter { !present.contains(CookieKey($0)) }
        return recording(store: left, baseline: baseline.cookies, at: baseline.savedAt)
    }
}
