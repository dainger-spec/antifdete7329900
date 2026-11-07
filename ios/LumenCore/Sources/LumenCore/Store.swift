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
/// WKWebsiteDataStore, which WebKit keeps itself.
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

    public func loadHistory(of id: UUID) -> [HistoryEntry] {
        (read(HistoryFile.self, at: sessionFolder(id).appendingPathComponent("history.json"))?.entries) ?? []
    }

    public func saveHistory(_ entries: [HistoryEntry], of id: UUID) {
        write(HistoryFile(entries: entries), to: sessionFolder(id).appendingPathComponent("history.json"))
    }

    /// The session's own files (tabs, history). Its WebKit store is removed by the app.
    public func removeSessionFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: sessionFolder(id))
    }

    /// Everything, for a test that starts from nothing.
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Lumen: could not write \(url.lastPathComponent): \(error)")
        }
    }
}
