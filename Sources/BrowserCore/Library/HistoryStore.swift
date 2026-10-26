#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One history item per URL (visits to the same URL are coalesced).
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { url }
    public var url: String
    public var title: String
    public var firstVisitedAt: Date
    public var lastVisitedAt: Date
    public var visitCount: Int
}

/// On-disk document. Removals are recorded as tombstones so that a deletion on one device
/// is not undone by a sync merge with another device's copy.
struct HistoryDocument: Codable, Equatable {
    var format = 1
    var entries: [HistoryEntry] = []
    /// URL → time of removal. An entry whose `lastVisitedAt` is not newer is dropped on merge.
    var removedURLs: [String: Date] = [:]
    /// "Clear all history" watermark: entries last visited at or before this are dropped on merge.
    var clearedThrough: Date?
}

/// Per-profile browsing history, encrypted at rest with
/// `HKDF(profileKey, "history")`, AAD `"history:v1:<profileID>"`.
///
/// Mutations only change memory and mark the store dirty; the app layer calls `save()`
/// (debounced, and on profile stop) so that a page load does not re-encrypt the whole file.
///
/// Privacy rules applied when recording: only http(s) URLs, user/password components and
/// fragments are stripped, titles are truncated. Ephemeral profiles get a memory-only store.
public final class HistoryStore: @unchecked Sendable {
    public struct Policy: Equatable, Sendable {
        public var maxEntries: Int
        /// `nil` = keep forever.
        public var retentionDays: Int?

        public init(maxEntries: Int = 10_000, retentionDays: Int? = 90) {
            self.maxEntries = maxEntries
            self.retentionDays = retentionDays
        }
    }

    private let file: EncryptedDocumentFile<HistoryDocument>
    private let lock = NSLock()
    private let saveLock = NSLock()
    private var document: HistoryDocument
    private var dirty = false
    public let policy: Policy

    static func file(url: URL?, profileID: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<HistoryDocument> {
        ProfileFileBinding.history.document(url: url, profileID: profileID, profileKey: profileKey)
    }

    init(file: EncryptedDocumentFile<HistoryDocument>, policy: Policy) throws {
        self.file = file
        self.policy = policy
        self.document = try file.load() ?? HistoryDocument()
        if Self.prune(&document, policy: policy, now: Date()) { dirty = true }
    }

    public var isPersistent: Bool { file.url != nil }
    public var hasUnsavedChanges: Bool { lock.withLock { dirty } }

    // MARK: Recording

    /// Records a visit. Returns false if the URL is not recordable (non-http(s)).
    @discardableResult
    public func recordVisit(url: URL, title: String?, at date: Date = Date()) -> Bool {
        guard let key = Self.normalizedURL(url) else { return false }
        let cleanTitle = Self.cleanTitle(title)
        lock.withLock {
            if let index = document.entries.firstIndex(where: { $0.url == key }) {
                document.entries[index].lastVisitedAt = max(document.entries[index].lastVisitedAt, date)
                document.entries[index].visitCount += 1
                if !cleanTitle.isEmpty { document.entries[index].title = cleanTitle }
            } else {
                document.entries.append(HistoryEntry(url: key, title: cleanTitle, firstVisitedAt: date,
                                                     lastVisitedAt: date, visitCount: 1))
            }
            if document.entries.count > policy.maxEntries + policy.maxEntries / 10 {
                Self.prune(&document, policy: policy, now: date)
            }
            dirty = true
        }
        return true
    }

    /// Titles usually arrive after the navigation commits.
    public func updateTitle(url: URL, title: String?) {
        guard let key = Self.normalizedURL(url) else { return }
        let cleanTitle = Self.cleanTitle(title)
        guard !cleanTitle.isEmpty else { return }
        lock.withLock {
            guard let index = document.entries.firstIndex(where: { $0.url == key }),
                  document.entries[index].title != cleanTitle else { return }
            document.entries[index].title = cleanTitle
            dirty = true
        }
    }

    // MARK: Queries

    /// Most recent first. `query` matches title or URL, case- and diacritic-insensitive.
    public func entries(matching query: String? = nil, limit: Int = 500) -> [HistoryEntry] {
        let needle = query?.trimmingCharacters(in: .whitespaces) ?? ""
        let all = lock.withLock { document.entries }
        let filtered = needle.isEmpty ? all : all.filter {
            $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.url.range(of: needle, options: [.caseInsensitive]) != nil
        }
        return Array(filtered.sorted { $0.lastVisitedAt > $1.lastVisitedAt }.prefix(limit))
    }

    public var count: Int { lock.withLock { document.entries.count } }

    // MARK: Removal

    public func remove(url: String, at date: Date = Date()) {
        lock.withLock {
            document.entries.removeAll { $0.url == url }
            document.removedURLs[url] = date
            dirty = true
        }
    }

    /// Removes entries last visited at or after `since`; `nil` removes everything.
    public func clear(since: Date? = nil, now: Date = Date()) {
        lock.withLock {
            if let since {
                for entry in document.entries where entry.lastVisitedAt >= since {
                    document.removedURLs[entry.url] = now
                }
                document.entries.removeAll { $0.lastVisitedAt >= since }
            } else {
                document.entries.removeAll()
                document.removedURLs.removeAll()
                document.clearedThrough = now
            }
            dirty = true
        }
    }

    // MARK: Persistence

    /// Writes the encrypted file if there are unsaved changes. No-op for memory-only stores.
    ///
    /// Saves are serialised and each takes its snapshot inside `saveLock`, so a background save
    /// racing with a final `flush` can never write an older snapshot last.
    public func save() throws {
        try saveLock.withLock {
            let snapshot: HistoryDocument? = lock.withLock { dirty ? document : nil }
            guard let snapshot else { return }
            try file.save(snapshot)
            lock.withLock { if document == snapshot { dirty = false } }
        }
    }

    // MARK: Normalisation

    /// `https://user:pw@Example.com/a#frag` → `https://example.com/a`. nil for non-http(s).
    public static func normalizedURL(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.string
    }

    static func cleanTitle(_ title: String?) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 512 ? String(trimmed.prefix(512)) : trimmed
    }

    // MARK: Merge and pruning (also used by sync)

    /// Union by URL; tombstones and the clear watermark win over older visits.
    static func merge(_ a: HistoryDocument, _ b: HistoryDocument, policy: Policy, now: Date = Date()) -> HistoryDocument {
        var result = HistoryDocument()
        result.clearedThrough = [a.clearedThrough, b.clearedThrough].compactMap { $0 }.max()
        result.removedURLs = a.removedURLs.merging(b.removedURLs, uniquingKeysWith: max)
        var byURL: [String: HistoryEntry] = [:]
        for entry in a.entries + b.entries {
            guard var existing = byURL[entry.url] else {
                byURL[entry.url] = entry
                continue
            }
            // Title of the most recent visit wins; never replace a title with an empty one.
            if !entry.title.isEmpty && (entry.lastVisitedAt > existing.lastVisitedAt || existing.title.isEmpty) {
                existing.title = entry.title
            }
            existing.firstVisitedAt = min(existing.firstVisitedAt, entry.firstVisitedAt)
            existing.lastVisitedAt = max(existing.lastVisitedAt, entry.lastVisitedAt)
            // max, not sum: the same visits are present on both sides after earlier merges.
            existing.visitCount = max(existing.visitCount, entry.visitCount)
            byURL[entry.url] = existing
        }
        result.entries = byURL.values.sorted { $0.lastVisitedAt > $1.lastVisitedAt }
        prune(&result, policy: policy, now: now)
        return result
    }

    /// Applies tombstones, the clear watermark, retention and the size cap. Returns true if anything changed.
    @discardableResult
    static func prune(_ document: inout HistoryDocument, policy: Policy, now: Date) -> Bool {
        let before = document
        if let cleared = document.clearedThrough {
            document.entries.removeAll { $0.lastVisitedAt <= cleared }
        }
        document.entries.removeAll { entry in
            document.removedURLs[entry.url].map { entry.lastVisitedAt <= $0 } ?? false
        }
        if let days = policy.retentionDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            document.entries.removeAll { $0.lastVisitedAt < cutoff }
            // Tombstones older than the retention window can no longer match a surviving entry.
            document.removedURLs = document.removedURLs.filter { $0.value >= cutoff }
        }
        if document.entries.count > policy.maxEntries {
            document.entries = Array(document.entries.sorted { $0.lastVisitedAt > $1.lastVisitedAt }.prefix(policy.maxEntries))
        }
        if document.removedURLs.count > policy.maxEntries {
            let kept = document.removedURLs.sorted { $0.value > $1.value }.prefix(policy.maxEntries)
            document.removedURLs = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        return document != before
    }
}
