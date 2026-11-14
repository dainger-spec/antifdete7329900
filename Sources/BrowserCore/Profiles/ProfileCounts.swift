#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What the Profiles window's inspector counts of a profile: its saved logins, its bookmarks, its
/// history entries, its synced cookies. Nil: not known — the file does not open, or (cookies) the
/// caller did not ask.
public struct ProfileCounts: Equatable, Sendable {
    /// Logins as the password manager lists them; the versions kept after a conflict are not counted.
    public var logins: Int?
    public var bookmarks: Int?
    /// Pages in its history, as the profile's history setting keeps them.
    public var historyEntries: Int?
    /// The cookies sync keeps of the profile (`cookies.bin`).
    public var syncedCookies: Int?
    /// How the profile's last warm-up went; nil when it was never warmed on this Mac, or its
    /// record does not open.
    public var lastWarmUp: WarmUpRecord?
    /// Its restore points (`RestorePoint`; nil: none), and the newest events of its journal.
    public var restorePoints: Int?
    public var recentEvents: [ProfileJournal.Event] = []

    public init(logins: Int? = nil, bookmarks: Int? = nil, historyEntries: Int? = nil, syncedCookies: Int? = nil,
                lastWarmUp: WarmUpRecord? = nil, restorePoints: Int? = nil, recentEvents: [ProfileJournal.Event] = []) {
        self.logins = logins
        self.bookmarks = bookmarks
        self.historyEntries = historyEntries
        self.syncedCookies = syncedCookies
        self.lastWarmUp = lastWarmUp
        self.restorePoints = restorePoints
        self.recentEvents = recentEvents
    }
}

extension ProfileRepository {
    /// Counts what the profile keeps, reading its files as they are: nothing is written, moved
    /// aside or taken in, whatever is found — a file that does not open is not counted and stays as
    /// it is, a copy an earlier sync set beside the passwords stays beside them (opening a
    /// `PasswordVault` would take it in). The inspector looks at profiles it does not use, often
    /// while they run, and only looks. A file that is not there counts 0.
    ///
    /// `historyPolicy`: the profile's own (`ProfileConfiguration.historyPolicy`), so that the count
    /// is the history the profile shows. `cookies`: count the synced cookies — only for a profile
    /// whose cookies are synced; others keep none there.
    public func counts(for id: UUID, historyPolicy: HistoryStore.Policy = .init(), cookies: Bool) -> ProfileCounts {
        guard let key = try? profileKey(for: id) else { return ProfileCounts() }
        var counts = ProfileCounts()
        counts.logins = Self.counted(passwordsURL(for: id)) { url in
            try PasswordDocument.decode(AEAD.open(SecureFile.read(url), key: PasswordVault.fileKey(profileID: id, profileKey: key),
                                                  aad: PasswordVault.aad(profileID: id)))
                .entries.filter { !$0.isConflictVersion }.count
        }
        counts.bookmarks = Self.counted(bookmarksURL(for: id)) { url in
            try BookmarkStore.file(url: url, profileID: id, profileKey: key).load()?.bookmarks.count ?? 0
        }
        counts.historyEntries = Self.counted(historyURL(for: id)) { url in
            var document = try HistoryStore.file(url: url, profileID: id, profileKey: key).load() ?? HistoryDocument()
            // In memory only: what opening the history would leave of it.
            _ = HistoryStore.prune(&document, policy: historyPolicy, now: Date())
            return document.entries.count
        }
        if cookies {
            counts.syncedCookies = Self.counted(cookieJarURL(for: id)) { url in
                try Self.cookieJarFile(url: url, profileID: id, profileKey: key).load()?.cookies.count ?? 0
            }
        }
        counts.lastWarmUp = try? warmUpRecord(for: id)
        let points = restorePoints(for: id).count
        counts.restorePoints = points > 0 ? points : nil
        counts.recentEvents = (try? journal(for: id))?.latest(4) ?? []
        return counts
    }

    /// 0 when there is no file at `url`; nil when it does not open; else what `count` read.
    private static func counted(_ url: URL, _ count: (URL) throws -> Int) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try? count(url)
    }
}
