#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    /// One level of grouping. `nil` = top level ("Favorites").
    public var folder: String?
    /// Sort key within the folder. Fractional so items can be inserted between others.
    public var position: Double
    public var createdAt: Date
    public var updatedAt: Date
}

struct BookmarkDocument: Codable, Equatable {
    var format = 1
    var bookmarks: [Bookmark] = []
    /// Bookmark ID (uuidString) → deletion time. Keeps deletions from being resurrected by sync.
    var deleted: [String: Date] = [:]
}

/// Per-profile bookmarks, encrypted at rest with `HKDF(profileKey, "bookmarks")`,
/// AAD `"bookmarks:v1:<profileID>"`. Every mutation is persisted immediately (bookmark
/// changes are rare and user-initiated).
public final class BookmarkStore: @unchecked Sendable {
    private let file: EncryptedDocumentFile<BookmarkDocument>
    private let lock = NSLock()
    private var document: BookmarkDocument

    static let maxTitleLength = 512
    static let maxFolderLength = 128

    static func file(url: URL?, profileID: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<BookmarkDocument> {
        ProfileFileBinding.bookmarks.document(url: url, profileID: profileID, profileKey: profileKey)
    }

    init(file: EncryptedDocumentFile<BookmarkDocument>) throws {
        self.file = file
        self.document = try file.load() ?? BookmarkDocument()
    }

    // MARK: Queries

    /// Top-level bookmarks first, then folders alphabetically; each group ordered by `position`.
    public func all() -> [Bookmark] {
        lock.withLock { Self.sorted(document.bookmarks) }
    }

    public func folders() -> [String] {
        lock.withLock { Array(Set(document.bookmarks.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    /// The bookmark for exactly this page, if any (fragment-insensitive).
    public func bookmark(for url: URL) -> Bookmark? {
        guard let key = Self.normalizedURL(url) else { return nil }
        return lock.withLock { document.bookmarks.first { $0.url == key } }
    }

    // MARK: Mutations

    @discardableResult
    public func add(title: String, url: URL, folder: String? = nil, now: Date = Date()) throws -> Bookmark {
        guard let key = Self.normalizedURL(url) else {
            throw CoreError.invalidConfiguration("only http(s) pages can be bookmarked")
        }
        let cleanFolder = try Self.cleanFolder(folder)
        return try mutate { document in
            let lastPosition = document.bookmarks.filter { $0.folder == cleanFolder }.map(\.position).max() ?? 0
            let bookmark = Bookmark(id: UUID(), title: Self.cleanTitle(title, fallback: key), url: key,
                                    folder: cleanFolder, position: lastPosition + 1, createdAt: now, updatedAt: now)
            document.bookmarks.append(bookmark)
            return bookmark
        }
    }

    /// Replaces title, URL and folder of an existing bookmark.
    public func update(_ bookmark: Bookmark, now: Date = Date()) throws {
        guard let url = URL(string: bookmark.url), let key = Self.normalizedURL(url) else {
            throw CoreError.invalidConfiguration("bookmark URL must be http(s)")
        }
        let cleanFolder = try Self.cleanFolder(bookmark.folder)
        try mutate { document in
            guard let index = document.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
                throw CoreError.invalidConfiguration("bookmark no longer exists")
            }
            var updated = document.bookmarks[index]
            if updated.folder != cleanFolder {
                updated.position = (document.bookmarks.filter { $0.folder == cleanFolder }.map(\.position).max() ?? 0) + 1
            }
            updated.title = Self.cleanTitle(bookmark.title, fallback: key)
            updated.url = key
            updated.folder = cleanFolder
            updated.updatedAt = now
            document.bookmarks[index] = updated
        }
    }

    public func remove(id: UUID, now: Date = Date()) throws {
        try mutate { document in
            document.bookmarks.removeAll { $0.id == id }
            document.deleted[id.uuidString] = now
        }
    }

    /// Moves `id` to `index` among the bookmarks of its folder.
    public func move(id: UUID, toIndex index: Int, now: Date = Date()) throws {
        try mutate { document in
            guard let moving = document.bookmarks.first(where: { $0.id == id }) else { return }
            var siblings = Self.sorted(document.bookmarks.filter { $0.folder == moving.folder && $0.id != id })
            siblings.insert(moving, at: max(0, min(index, siblings.count)))
            for (offset, sibling) in siblings.enumerated() {
                guard let position = document.bookmarks.firstIndex(where: { $0.id == sibling.id }) else { continue }
                if document.bookmarks[position].position != Double(offset + 1) {
                    document.bookmarks[position].position = Double(offset + 1)
                    document.bookmarks[position].updatedAt = now
                }
            }
        }
    }

    // MARK: Merge (sync)

    /// Union by ID; the most recently updated version wins; a deletion wins over any version
    /// that is not newer than it.
    static func merge(_ a: BookmarkDocument, _ b: BookmarkDocument) -> BookmarkDocument {
        var result = BookmarkDocument()
        result.deleted = a.deleted.merging(b.deleted, uniquingKeysWith: max)
        var byID: [UUID: Bookmark] = [:]
        for bookmark in a.bookmarks + b.bookmarks {
            if let existing = byID[bookmark.id], existing.updatedAt >= bookmark.updatedAt { continue }
            byID[bookmark.id] = bookmark
        }
        result.bookmarks = sorted(byID.values.filter { bookmark in
            result.deleted[bookmark.id.uuidString].map { bookmark.updatedAt > $0 } ?? true
        })
        return result
    }

    // MARK: Private

    private func mutate<R>(_ change: (inout BookmarkDocument) throws -> R) throws -> R {
        try lock.withLock {
            var updated = document
            let result = try change(&updated)
            try file.save(updated)
            document = updated
            return result
        }
    }

    static func sorted(_ bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            switch (lhs.folder, rhs.folder) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (l?, r?) where l != r: return l.localizedStandardCompare(r) == .orderedAscending
            default: return (lhs.position, lhs.createdAt) < (rhs.position, rhs.createdAt)
            }
        }
    }

    static func normalizedURL(_ url: URL) -> String? { HistoryStore.normalizedURL(url) }

    static func cleanTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        return trimmed.count > maxTitleLength ? String(trimmed.prefix(maxTitleLength)) : trimmed
    }

    static func cleanFolder(_ folder: String?) throws -> String? {
        guard let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxFolderLength else { throw CoreError.invalidConfiguration("folder name too long") }
        return trimmed
    }
}
