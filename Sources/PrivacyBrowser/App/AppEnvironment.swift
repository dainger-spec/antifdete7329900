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

    /// `<vault>/SafariChromeHome`: the home `--safari-chrome` (a developer's way to try Safari's
    /// chrome with no profile) gave itself up to 1 November — Safari's chrome and WebKit's caches,
    /// local storage and databases of whatever was browsed in it, in plaintext, in no profile and
    /// never sealed (the owner's Mac: 868 files of 29 October). Nothing uses it any more (that mode
    /// now runs in a temporary home of its own, removed when it ends), so it is removed, once,
    /// whatever is in it, and said in the log.
    static func removeStandaloneSafariHome(in vault: URL) {
        let home = vault.appendingPathComponent("SafariChromeHome", isDirectory: true)
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        let files = FileManager.default.enumerator(atPath: home.path)?.allObjects.count ?? 0
        do {
            try FileManager.default.removeItem(at: home)
            Logger(subsystem: "PrivacyBrowser", category: "AppEnvironment")
                .notice("Removed the plaintext home --safari-chrome left in the vault folder: \(Int(files), privacy: .public) items")
        } catch {
            Logger(subsystem: "PrivacyBrowser", category: "AppEnvironment")
                .error("Could not remove the plaintext home --safari-chrome left in the vault folder: \(error.logKind, privacy: .public)")
        }
    }

    /// What an unseal that never finished left (R8, docs/DESTRUCTIVE_PATHS.md): part of a
    /// profile's plaintext in a hidden staging directory, `.<name>.unseal-<UUID>`, next to WebKit's
    /// data or, in the profile's folder, next to Safari's home — a crash or a kill while one of
    /// its archives was extracted. Nothing reads it and no seal takes it in: the archive holds the
    /// profile's data. Removed at the app's launch and at unlock (every profile's), and before a
    /// profile's launch (its own); how many, said in the log. Returns how many were removed.
    @discardableResult
    static func removeUnsealLeftovers(vault: URL, of profileID: UUID? = nil) -> Int {
        let webKit = WebDataStoreVault.layout.removeUnsealLeftovers(of: profileID)
        // Safari's home is extracted in the profile's own folder, next to where it goes.
        let profiles = vault.appendingPathComponent("profiles", isDirectory: true)
        let folders = profileID.map { [$0.uuidString] } ?? ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [])
        let homes = EncryptedDirectoryArchive.removeStagingLeftovers(
            below: folders.map { profiles.appendingPathComponent($0, isDirectory: true) }, depth: 0)
        let removed = webKit.removed + homes.removed, failed = webKit.failed + homes.failed
        let log = Logger(subsystem: "PrivacyBrowser", category: "AppEnvironment")
        if removed > 0 {
            if let profileID {
                log.notice("Removed \(Int(removed), privacy: .public) partial plaintext directories an unseal of \(profileID.uuidString, privacy: .public) did not finish left")
            } else {
                log.notice("Removed \(Int(removed), privacy: .public) partial plaintext directories unseals that did not finish left")
            }
        }
        if failed > 0 {
            log.error("Could not remove \(Int(failed), privacy: .public) partial plaintext directories unseals that did not finish left")
        }
        return removed
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
            log.error("Could not move the sandboxed build's vault out of its container: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }
}
