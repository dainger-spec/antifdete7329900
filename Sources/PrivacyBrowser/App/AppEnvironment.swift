import AppKit
import BrowserCore
import Foundation
import os

/// Facts about the running process that change storage locations.
enum AppEnvironment {
    /// True when running inside the App Sandbox. The kernel sets `APP_SANDBOX_CONTAINER_ID`
    /// for sandboxed processes; all `FileManager` user-domain URLs then point into
    /// `~/Library/Containers/<bundle-id>/Data/`.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Default vault location: `<Application Support>/PrivacyBrowser`, i.e.
    /// `~/Library/Application Support/PrivacyBrowser` (not sandboxed) or
    /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/PrivacyBrowser`.
    /// `PRIVACYBROWSER_VAULT_DIR` overrides it (inside the sandbox only paths in the container
    /// are writable).
    static var vaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PRIVACYBROWSER_VAULT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivacyBrowser", isDirectory: true)
    }

    /// An unsandboxed build that has no vault yet takes over the one a sandboxed build of the same
    /// bundle identifier left in its container (`UnsandboxedMigration`), once, before the vault is
    /// looked for. Not while another instance of the app runs (it may be that sandboxed build, using
    /// those files), and not with a vault folder named explicitly.
    static func adoptSandboxedDataIfNeeded() {
        let log = Logger(subsystem: "PrivacyBrowser", category: "AppEnvironment")
        guard !isSandboxed, ProcessInfo.processInfo.environment["PRIVACYBROWSER_VAULT_DIR"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let container = library.appendingPathComponent("Containers/\(bundleID)/Data/Library", isDirectory: true)
        let moves = UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID)
        guard !moves.isEmpty else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else {
            log.notice("A sandboxed build's vault is in its container, but another instance is running: not moved now")
            return
        }
        do {
            try UnsandboxedMigration.perform(moves)
            log.notice("Moved a sandboxed build's vault out of its container (\(moves.count, privacy: .public) items)")
        } catch {
            log.error("Could not move the sandboxed build's vault out of its container: \(String(describing: error), privacy: .public)")
        }
    }
}
