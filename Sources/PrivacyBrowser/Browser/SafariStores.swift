import BrowserCore
import Foundation
import os
import SQLite3

/// Safari's own stores in a profile's home, made sure of in the profile's process before Safari's
/// frameworks load (`SafariStoreLayout`: the folders, writable; a store that is not one set aside,
/// so that Safari's code makes it anew), and what the address bar check asks of them.
///
/// WHY. Safari's address bar reads Safari's stores as a person types and presses Return — its
/// history, the embeddings it searches history with, top sites, per-site settings, icons. Another
/// browser hosting Safari's chrome gives each profile the complete tree of them; a profile's home
/// here started with none, and where Safari's code found a folder missing or a store it could not
/// open, it got nil, and threw where it did not expect one. A customer on macOS 27.2.1 could not
/// search from the address bar: the field showed the committed search, the page stayed empty, and
/// the window said the feature was not available in a profile.
enum SafariStores {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariStores")

    /// What this process's start made sure of (the address bar check reports it).
    nonisolated(unsafe) private(set) static var preparation: SafariStoreLayout.Preparation?

    /// The profile's home, as this process was given it.
    static var home: URL? {
        guard let path = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Makes sure of Safari's stores in the profile's home. Before Safari's frameworks load, in a
    /// profile's own process (and a check's, in its home of its own); never in the account's real
    /// home. Idempotent: a launch of a profile made before this gets what it lacks.
    static func prepare() {
        guard preparation == nil, let home else { return }
        if let realHome = SafariPaths.realHome, URL(fileURLWithPath: realHome).standardizedFileURL.path == home.standardizedFileURL.path {
            log.error("This process's home is the account's own: Safari's stores are not touched")
            return
        }
        let report = SafariStoreLayout.prepare(home: home, opens: opens)
        preparation = report
        if report.isEmpty {
            log.notice("Safari's stores in the profile's home: every folder there, nothing to set aside")
            return
        }
        log.notice("Safari's stores in the profile's home: \(report.made.count, privacy: .public) folder(s) made, \(report.madeWritable.count, privacy: .public) made writable, \(report.setAside.count, privacy: .public) set aside")
        for path in report.setAside {
            log.error("Safari's store \(path, privacy: .public) was not one Safari could open: set aside for Safari to make anew")
        }
        for line in report.failed {
            log.error("Safari's stores in the profile's home: \(line, privacy: .public)")
        }
    }

    /// Whether SQLite opens the database at `url` and reads its schema: false when it is not a
    /// database or its schema is damaged, nil when that cannot be told (busy, locked, refused).
    static func opens(_ url: URL) -> Bool? {
        switch openDatabase(url, readOnly: false) {
        case .opens: return true
        case .broken: return false
        case .unknown: return nil
        }
    }

    enum Opening {
        case opens(tables: Int)
        case broken(String)
        case unknown(String)

        var text: String {
            switch self {
            case .opens(let tables): return "opens (\(tables) tables)"
            case .broken(let why): return "DOES NOT OPEN (\(why))"
            case .unknown(let why): return "not told (\(why))"
            }
        }
    }

    /// Opens the database at `url` with SQLite and counts its tables (`sqlite_master`, which reads
    /// the whole schema).
    static func openDatabase(_ url: URL, readOnly: Bool) -> Opening {
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &database, flags, nil)
        defer { sqlite3_close_v2(database) }
        guard code == SQLITE_OK else { return verdict(code, database) }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK else {
            return verdict(sqlite3_errcode(database), database)
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else { return verdict(step, database) }
        return .opens(tables: Int(sqlite3_column_int(statement, 0)))
    }

    private static func verdict(_ code: Int32, _ database: OpaquePointer?) -> Opening {
        let primary = code & 0xff
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite \(code)"
        if primary == SQLITE_NOTADB || primary == SQLITE_CORRUPT { return .broken("\(code) \(message)") }
        return .unknown("\(code) \(message)")
    }

    // MARK: The report

    struct Report: Codable {
        var home = ""
        var stores: [SafariStoreLayout.Assessment] = []
        var preparation: SafariStoreLayout.Preparation?
        /// Every file under the home's Library, relative, with its size (at most 400).
        var files: [String] = []
        /// What Safari's path getters answered in this process (`SafariPaths.answers`).
        var getters: [String] = []
    }

    /// The stores as they stand now, opened read-only; the files in the home's Library; where
    /// Safari's getters pointed.
    static func report() -> Report {
        var report = Report()
        guard let home else { return report }
        report.home = home.path
        report.preparation = preparation
        report.stores = SafariStoreLayout.assess(home: home) { url in openDatabase(url, readOnly: true).text }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        if let walk = FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values?.isDirectory != true else { continue }
                let relative = String(url.path.dropFirst(home.path.count + 1))
                report.files.append("\(relative) \(values?.fileSize ?? 0)")
                if report.files.count >= 400 { break }
            }
        }
        report.getters = SafariPaths.answers.map { "\($0.key) → \($0.value)" }.sorted()
        return report
    }
}
