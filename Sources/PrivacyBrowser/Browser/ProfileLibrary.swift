import BrowserCore
import Foundation
import os

/// History and bookmarks of one running profile, observable by SwiftUI and AppKit.
///
/// Wraps the encrypted `HistoryStore` / `BookmarkStore` from BrowserCore. Both are decrypted
/// when the profile launches and live only as long as the `BrowserSession`.
///
/// History writes are debounced (a page load must not re-encrypt the whole history file)
/// and flushed synchronously when the profile stops. If the app crashes, at most the last
/// `saveDelay` seconds of history are lost.
@MainActor
final class ProfileLibrary: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []
    /// Incremented on every history change; views re-query `historyEntries(matching:)`.
    @Published private(set) var historyRevision = 0

    let recordsHistory: Bool
    var onError: ((Error) -> Void)?

    private let history: HistoryStore
    private let bookmarkStore: BookmarkStore
    private var saveTask: Task<Void, Never>?
    private let saveDelay: UInt64 = 3
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileLibrary")

    init(history: HistoryStore, bookmarks: BookmarkStore, recordsHistory: Bool) {
        self.history = history
        self.bookmarkStore = bookmarks
        self.recordsHistory = recordsHistory
        self.bookmarks = bookmarks.all()
    }

    /// False for ephemeral profiles (history kept in memory only).
    var historyIsPersistent: Bool { history.isPersistent }

    // MARK: History

    func recordVisit(url: URL, title: String?) {
        guard recordsHistory, history.recordVisit(url: url, title: title) else { return }
        historyChanged()
    }

    func updateTitle(url: URL, title: String?) {
        guard recordsHistory else { return }
        history.updateTitle(url: url, title: title)
        historyChanged()
    }

    func historyEntries(matching query: String, limit: Int = 1_000) -> [HistoryEntry] {
        history.entries(matching: query, limit: limit)
    }

    func removeHistoryEntry(url: String) {
        history.remove(url: url)
        historyChanged()
    }

    /// `since == nil` clears everything.
    func clearHistory(since: Date?) {
        history.clear(since: since)
        historyChanged()
    }

    /// Writes pending history immediately (profile stop, lock, quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try history.save()
        } catch {
            report(error)
        }
    }

    private func historyChanged() {
        historyRevision &+= 1
        guard history.isPersistent, saveTask == nil else { return }
        let history = history
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            // Encryption of a large history happens off the main thread; the store is lock-protected.
            let result = await Task.detached(priority: .utility) { Result { try history.save() } }.value
            guard let self else { return }
            self.saveTask = nil
            if case .failure(let error) = result {
                self.report(error)
            }
        }
    }

    // MARK: Bookmarks

    func bookmark(for url: URL?) -> Bookmark? {
        url.flatMap { bookmarkStore.bookmark(for: $0) }
    }

    var bookmarkFolders: [String] { bookmarkStore.folders() }

    @discardableResult
    func addBookmark(title: String, url: URL, folder: String? = nil) -> Bookmark? {
        mutateBookmarks { try bookmarkStore.add(title: title, url: url, folder: folder) }
    }

    func updateBookmark(_ bookmark: Bookmark) {
        mutateBookmarks { try bookmarkStore.update(bookmark) }
    }

    func removeBookmark(id: UUID) {
        mutateBookmarks { try bookmarkStore.remove(id: id) }
    }

    func moveBookmark(id: UUID, toIndex index: Int) {
        mutateBookmarks { try bookmarkStore.move(id: id, toIndex: index) }
    }

    @discardableResult
    private func mutateBookmarks<R>(_ change: () throws -> R) -> R? {
        defer { bookmarks = bookmarkStore.all() }
        do {
            return try change()
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        log.error("\(String(describing: error), privacy: .public)")
        Log.error("library", "saving bookmarks or history failed: \(Log.describe(error))")
        onError?(error)
    }
}
