import Foundation

/// Everything the app keeps, as JSON files under one folder (Application Support/Lumen in the app):
///
///     sessions.json                 the catalogue (sessions and their settings)
///     proxies.json                  the proxy list (passwords are in the Keychain)
///     sessions/<id>/tabs.json       a session's open tabs
///     sessions/<id>/history.json    a session's history
///
/// Every write is atomic (a whole new file renamed over the old one), so a killed app leaves the
/// last complete state. WebKit's own data (cookies, storage, cache) is in each session's
/// WKWebsiteDataStore, which WebKit keeps itself. A session's history is written off the caller's
/// thread (`saveHistory`).
public final class LumenStore: @unchecked Sendable {
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(root: URL) {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    struct Catalogue: Codable {
        var version = 1
        var sessions: [Session]
    }

    struct ProxyFile: Codable {
        var version = 1
        var proxies: [ProxyEntry]
    }

    struct HistoryFile: Codable {
        var version = 1
        var entries: [HistoryEntry]
    }

    // MARK: Sessions

    public func loadSessions() -> [Session] {
        (read(Catalogue.self, at: root.appendingPathComponent("sessions.json"))?.sessions) ?? []
    }

    public func saveSessions(_ sessions: [Session]) {
        if Faults.isActive(.sessionsNotSaved) { return }
        write(Catalogue(sessions: sessions), to: root.appendingPathComponent("sessions.json"))
    }

    // MARK: Proxies

    public func loadProxies() -> [ProxyEntry] {
        (read(ProxyFile.self, at: root.appendingPathComponent("proxies.json"))?.proxies) ?? []
    }

    public func saveProxies(_ proxies: [ProxyEntry]) {
        write(ProxyFile(proxies: proxies), to: root.appendingPathComponent("proxies.json"))
    }

    // MARK: Per session

    public func sessionFolder(_ id: UUID) -> URL {
        root.appendingPathComponent("sessions").appendingPathComponent(id.uuidString)
    }

    public func loadTabs(of id: UUID) -> SessionTabs {
        read(SessionTabs.self, at: sessionFolder(id).appendingPathComponent("tabs.json")) ?? SessionTabs()
    }

    public func saveTabs(_ tabs: SessionTabs, of id: UUID) {
        if Faults.isActive(.tabsNotRestored) { return }
        write(tabs, to: sessionFolder(id).appendingPathComponent("tabs.json"))
    }

    /// The session's history as last saved — after any write of it still on its way.
    public func loadHistory(of id: UUID) -> [HistoryEntry] {
        let url = historyURL(id)
        return HistoryWriter.shared.afterWrites { (read(HistoryFile.self, at: url)?.entries) ?? [] }
    }

    /// Written off the caller's thread — it is saved after every page that finishes loading, as a
    /// whole file, and the browser calls it on the main thread — in the order saved; a version not
    /// yet written gives way to a newer one of the same session.
    public func saveHistory(_ entries: [HistoryEntry], of id: UUID) {
        HistoryWriter.shared.save(entries, to: historyURL(id)) { [self] entries, url in
            write(HistoryFile(entries: entries), to: url, with: historyEncoder)
        }
    }

    private func historyURL(_ id: UUID) -> URL { sessionFolder(id).appendingPathComponent("history.json") }

    /// The session's own files (tabs, history) — after any history write on its way, which would
    /// otherwise put the folder back. Its WebKit store is removed by the app.
    public func removeSessionFiles(_ id: UUID) {
        let folder = sessionFolder(id)
        HistoryWriter.shared.afterWrites(dropping: historyURL(id)) { try? FileManager.default.removeItem(at: folder) }
    }

    /// Everything, for a test that starts from nothing.
    public func removeAll() {
        HistoryWriter.shared.afterWrites {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL, with encoder: JSONEncoder? = nil) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try (encoder ?? self.encoder).encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Lumen: could not write \(url.lastPathComponent): \(error)")
        }
    }

    /// The history's own encoder, used on the writer's queue only (the other one, on the caller's).
    private let historyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// How much of a session's history is kept: what the Mac keeps of a profile's by default (its
/// `HistoryStore.Policy()`) — the last 90 days, and at most 10 000 visits.
public enum HistoryRetention {
    public static let days = 90
    public static let maximumEntries = 10_000

    /// `entries` (oldest first, as recorded) without the visits older than `days` before `now`, and
    /// of the rest the newest `maximumEntries`.
    public static func kept(_ entries: [HistoryEntry], now: Date = Date()) -> [HistoryEntry] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var kept = entries.filter { $0.visitedAt >= since }
        if kept.count > maximumEntries { kept.removeFirst(kept.count - maximumEntries) }
        return kept
    }
}

/// The sessions' history files, written one at a time on a queue of their own, for every store of
/// the process (a store opened again on the same folder reads what an earlier one wrote): of a
/// file's versions saved while one was waiting, only the newest is written.
final class HistoryWriter: @unchecked Sendable {
    static let shared = HistoryWriter()

    private let queue = DispatchQueue(label: "io.lumenbrowser.ios.history", qos: .utility)
    private let lock = NSLock()
    /// The newest version of each file not written yet.
    private var waiting: [URL: [HistoryEntry]] = [:]

    func save(_ entries: [HistoryEntry], to url: URL, write: @escaping @Sendable ([HistoryEntry], URL) -> Void) {
        let queued = lock.withLock { waiting.updateValue(entries, forKey: url) != nil }
        guard !queued else { return }   // the write already on its way takes this version
        queue.async { [self] in
            guard let newest = lock.withLock({ waiting.removeValue(forKey: url) }) else { return }
            write(newest, url)
        }
    }

    /// Runs `body` once every write saved before it is done — `dropping` the version of that file
    /// not yet written, if any (the file is going).
    @discardableResult
    func afterWrites<T>(dropping url: URL? = nil, _ body: () -> T) -> T {
        queue.sync { () -> T in
            if let url { _ = lock.withLock { waiting.removeValue(forKey: url) } }
            return body()
        }
    }
}
