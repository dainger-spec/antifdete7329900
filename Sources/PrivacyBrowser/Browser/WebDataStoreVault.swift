import BrowserCore
import CryptoKit
import Foundation
import os
import WebKit

/// Keeps a profile's WebKit data (cookies, localStorage, IndexedDB, cache, service
/// workers, HSTS, …) encrypted on disk while the profile is not running.
///
/// PLATFORM LIMITATION — why this is an archive/restore cycle and not transparent encryption:
/// WebKit writes a persistent `WKWebsiteDataStore(forIdentifier:)` to directories it
/// chooses itself; there is no public API to relocate it (e.g. into an encrypted disk
/// image) or to supply an encryption key. (`_WKWebsiteDataStoreConfiguration` can set
/// directories but is private API.) So:
///   * on launch, `webdata.pbsa` is decrypted into WebKit's directories;
///   * while the profile runs, that data is plaintext on disk (protected only by
///     FileVault, file permissions and — when sandboxed — the app container);
///   * on stop, the directories are archived + encrypted and then removed via
///     `WKWebsiteDataStore.remove(forIdentifier:)`.
///
/// Directory locations come from `WebKitDataLayout` (discovery by UUID name, plus translation
/// between the sandboxed and non-sandboxed layouts). `--self-test` verifies them on the
/// running macOS version.
///
/// A crash while a profile is running leaves plaintext on disk until the next unlock,
/// when `ProfileManager.recoverUnsealedProfiles` re-seals it.
@MainActor
final class WebDataStoreVault {
    private let repository: ProfileRepository
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WebDataStoreVault")

    init(repository: ProfileRepository) {
        self.repository = repository
    }

    enum VaultError: LocalizedError {
        case storeStillInUse(UUID)

        var errorDescription: String? {
            switch self {
            case .storeStillInUse(let id):
                return "WebKit did not release the data store of profile \(id). Its data remains unencrypted on disk until it is sealed on the next stop or unlock."
            }
        }
    }

    struct SealResult {
        var directories: [URL] = []
        var stats = EncryptedDirectoryArchive.Stats()
        var attempts = 0
    }

    /// Layout of the running process (sandboxed or not).
    nonisolated static var layout: WebKitDataLayout {
        WebKitDataLayout(library: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath(),
                         bundleID: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
                         sandboxed: AppEnvironment.isSandboxed)
    }

    nonisolated static func discoverDirectories(for profileID: UUID) -> [URL] {
        layout.discoverDirectories(for: profileID)
    }

    // MARK: Launch

    /// Decrypts the profile's archived WebKit data into WebKit's directories.
    /// Must be called before the profile's `WKWebsiteDataStore` is created.
    func prepareForLaunch(profileID: UUID, key: SymmetricKey) async throws {
        let layout = Self.layout
        let residue = layout.discoverDirectories(for: profileID)
        if !residue.isEmpty {
            // Leftover plaintext from a crash. It is newer than the archive (it was produced
            // by unsealing that archive and then browsing), so keep it; the next stop seals it.
            log.notice("Using unsealed WebKit data left by a previous run for profile \(profileID.uuidString, privacy: .public)")
            return
        }
        let archive = repository.webDataArchiveURL(for: profileID)
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        _ = try await Task.detached(priority: .userInitiated) {
            try EncryptedDirectoryArchive.unseal(from: archive, key: key) { label in
                try layout.destination(forLabel: label, profileID: profileID)
            }
        }.value
    }

    // MARK: Stop

    /// Seals the profile's WebKit data. Call after every `WKWebView` and the
    /// `WKWebsiteDataStore` of the profile have been released.
    ///
    /// PLATFORM LIMITATION: there is no public "close/flush data store" API. WebKit's
    /// network process tears the session down asynchronously after the last reference to
    /// the data store goes away. We therefore: wait, archive, then call
    /// `WKWebsiteDataStore.remove(forIdentifier:)`, which fails while the store is still in
    /// use. On failure the cycle is repeated with a longer wait. A write that lands between
    /// the archive and the successful removal would be lost (never leaked in plaintext).
    ///
    /// `activeStore` must be true only when this process created the profile's
    /// `WKWebsiteDataStore` (i.e. the profile ran). Pass false for crash recovery at unlock:
    /// the store was never registered in this process, so `WKWebsiteDataStore.remove(forIdentifier:)`
    /// would hand WebKit an unknown identifier and abort on its data-store IO queue. In that
    /// case we archive and delete the leftover directories directly, which is safe because no
    /// live store references them.
    @discardableResult
    func seal(profileID: UUID, key: SymmetricKey, activeStore: Bool = true) async throws -> SealResult {
        let archive = repository.webDataArchiveURL(for: profileID)
        let layout = Self.layout
        // A live store needs settle time and a WebKit-coordinated removal, with retries.
        // Recovered-from-disk data needs neither: archive once and delete the files.
        let delays: [UInt64] = activeStore ? [1, 2, 3, 5, 8] : [0]
        var result = SealResult()
        var lastError: Error?
        for seconds in delays {
            result.attempts += 1
            if seconds > 0 { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            let directories = layout.discoverDirectories(for: profileID)
            if directories.isEmpty { return result } // nothing was ever written, or already sealed
            result.directories = directories
            do {
                let roots = Dictionary(uniqueKeysWithValues: try directories.map { (try layout.label(for: $0), $0) })
                result.stats = try await Task.detached(priority: .userInitiated) {
                    try EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key)
                }.value
                if activeStore {
                    try await WKWebsiteDataStore.remove(forIdentifier: profileID)
                }
                // Sweep the directories. `remove(forIdentifier:)` usually clears them for a live
                // store; recovered data is simply deleted here.
                for directory in layout.discoverDirectories(for: profileID) {
                    try FileManager.default.removeItem(at: directory)
                }
                log.info("Sealed profile \(profileID.uuidString, privacy: .public): \(result.stats.files) files, \(result.stats.bytes) bytes (activeStore=\(activeStore))")
                return result
            } catch {
                lastError = error
                log.notice("Seal attempt \(result.attempts) for \(profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        log.error("Giving up sealing \(profileID.uuidString, privacy: .public): \(String(describing: lastError), privacy: .public)")
        throw VaultError.storeStillInUse(profileID)
    }

    // MARK: Delete

    func deleteData(profileID: UUID) async {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: profileID)
        } catch {
            log.notice("remove(forIdentifier:) for \(profileID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        for directory in Self.discoverDirectories(for: profileID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
