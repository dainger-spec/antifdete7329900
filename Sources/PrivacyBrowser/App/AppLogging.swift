import BrowserCore
import Foundation
import os

/// The app's log: unified logging (Console.app) plus a plain file that Settings ▸ Show Log
/// displays and the user can attach to a bug report.
///
/// What is logged: lifecycle events (unlock, lock, launch, stop, seal), errors with their
/// technical code, proxy checks, import/export counts. What is never logged: page URLs or
/// titles, cookies, passwords, proxy credentials, profile names. Profiles appear by the first
/// 8 characters of their id.
enum Log {
    private static let system = Logger(subsystem: "PrivacyBrowser", category: "app")

    /// `~/Library/Logs/PrivacyBrowser` (inside the container when sandboxed).
    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("PrivacyBrowser", isDirectory: true)
    }

    /// Call once at startup.
    static func start() {
        guard AppLog.shared == nil else { return }
        AppLog.shared = AppLog(directory: directory)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("app", "started \(version) on macOS \(os), sandbox=\(AppEnvironment.isSandboxed)")
    }

    static func info(_ category: String, _ message: String) {
        system.info("\(category, privacy: .public): \(message, privacy: .public)")
        AppLog.shared?.log(.info, category, message)
    }

    static func notice(_ category: String, _ message: String) {
        system.notice("\(category, privacy: .public): \(message, privacy: .public)")
        AppLog.shared?.log(.notice, category, message)
    }

    static func error(_ category: String, _ message: String) {
        system.error("\(category, privacy: .public): \(message, privacy: .public)")
        AppLog.shared?.log(.error, category, message)
    }

    /// Short, non-identifying form of a profile id for the log.
    static func id(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// The technical part of an error, without user data: domain and code for NSErrors.
    static func describe(_ error: Error) -> String {
        if let core = error as? CoreError { return AppLog.redact(core.description) }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
