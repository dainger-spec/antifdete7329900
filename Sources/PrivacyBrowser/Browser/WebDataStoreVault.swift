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

    /// Set when the app quits (`ProfileManager.prepareForQuit`): a live store WebKit still holds
    /// after the last attempt is force-sealed (see `forceSeal`) instead of left decrypted. Only
    /// right before the process exits — a running app may still use the store.
    var forceSealWhenStoreStaysInUse = false

    /// Seconds to wait before each attempt to seal a live store (self-test hook).
    var retryDelays: [UInt64] = [1, 2, 3, 5, 8]

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
        /// Sealed by `forceSeal`: WebKit kept the store in use until the end.
        var forced = false
    }

    /// Written by `forceSeal`: the archive is the profile's data, and WebKit directories found
    /// later were written after that seal (see `discardResidueAfterForcedSeal`).
    func forcedSealMarkerURL(for profileID: UUID) -> URL {
        repository.directory(for: profileID).appendingPathComponent("webdata.forced")
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

    /// Identifiers whose `WKWebsiteDataStore(forIdentifier:)` this process created and has not
    /// removed yet. Only these are passed to `WKWebsiteDataStore.remove(forIdentifier:)`; any
    /// other profile's data is deleted by sweeping its directories. This gate is what fixes the
    /// delete crash: before it, deleting a profile right after unlock handed WebKit an identifier
    /// in a process where no WebKit object existed yet (see `ensureWebKitInitialized`).
    private static var registeredStoreIDs: Set<UUID> = []

    private static var webKitInitialized = false

    /// How many times this process called `remove(forIdentifier:)` (self-test hook).
    private(set) static var removeCallCount = 0

    /// Whether `deleteData` would hand this profile's identifier to WebKit (self-test hook).
    static func isRegistered(_ profileID: UUID) -> Bool {
        registeredStoreIDs.contains(profileID)
    }

    /// Initializes WebKit (`InitializeWebKit2`, which installs `RunLoop::main()`).
    ///
    /// `WKWebsiteDataStore.nonPersistent()` and `remove(forIdentifier:)` do not initialize WebKit
    /// themselves, yet both use `RunLoop::main()`: the non-persistent store's constructor builds a
    /// timer on it (`AuthenticatorManager`), and `remove` completes through it from its IO queue.
    /// As the first WebKit use in the process (e.g. right after unlock) either one is an
    /// EXC_BAD_ACCESS. `WKWebsiteDataStore(forIdentifier:)`, `.default()` and `WKWebView` do
    /// initialize WebKit.
    ///
    /// Creates neither a data store nor a web view: it creates a configuration's process pool,
    /// which initializes WebKit on every macOS version (macOS 14's `WKWebViewConfiguration.init`
    /// already does it; newer WebKit does it when the pool is created).
    static func ensureWebKitInitialized() {
        guard !webKitInitialized else { return }
        (ProcessPoolInitializer() as WebKitInitializing).initializeWebKit()
        webKitInitialized = true
    }

    /// The only caller of `WKWebsiteDataStore.remove(forIdentifier:)`. Main-actor isolated (the
    /// class is `@MainActor`), so no queue hopping is needed.
    private static func removeStore(for profileID: UUID) async throws {
        // Defensive: a registered identifier implies `makeStore` already initialized WebKit.
        ensureWebKitInitialized()
        removeCallCount += 1
        try await WKWebsiteDataStore.remove(forIdentifier: profileID)
        // Removed: a later delete of this profile only sweeps directories. The next launch
        // registers it again through `makeStore`.
        registeredStoreIDs.remove(profileID)
    }

    /// Creates a profile's persistent data store. Always use this instead of calling
    /// `WKWebsiteDataStore(forIdentifier:)` directly, so `deleteData` knows it may remove it.
    static func makeStore(for profileID: UUID) -> WKWebsiteDataStore {
        registeredStoreIDs.insert(profileID)
        excludeRootsFromCopies()
        return WKWebsiteDataStore(forIdentifier: profileID)
    }

    private static var rootsExcluded = false

    /// WebKit's directories of this app hold a running profile's data in plaintext: excluded from
    /// Time Machine and its local snapshots, which would keep that plaintext after the seal. The
    /// exclusion is an attribute of the folder, which the app never removes (only the profiles'
    /// directories inside it), so once per process is enough.
    private static func excludeRootsFromCopies() {
        guard !rootsExcluded else { return }
        rootsExcluded = true
        for root in layout.searchRoots {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = root
            try? url.setResourceValues(values)
        }
    }

    // MARK: Launch

    /// Decrypts the profile's archived WebKit data into WebKit's directories.
    /// Must be called before the profile's `WKWebsiteDataStore` is created.
    func prepareForLaunch(profileID: UUID, key: SymmetricKey) async throws {
        let layout = Self.layout
        try discardResidueAfterForcedSeal(profileID: profileID)
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
    /// no live store references the leftover directories, so there is nothing for WebKit to
    /// coordinate — we archive and delete them directly, without any WebKit API (WebKit is
    /// usually not even initialized yet at that point; see `ensureWebKitInitialized`).
    @discardableResult
    func seal(profileID: UUID, key: SymmetricKey, activeStore: Bool = true) async throws -> SealResult {
        let archive = repository.webDataArchiveURL(for: profileID)
        let layout = Self.layout
        var result = SealResult()
        // Recovery after a forced seal: the directories are what WebKit wrote after that seal,
        // and the archive already holds the profile's data.
        if !activeStore, try discardResidueAfterForcedSeal(profileID: profileID) {
            result.attempts = 1
            return result
        }
        // A live store needs settle time and a WebKit-coordinated removal, with retries.
        // Recovered-from-disk data needs neither: archive once and delete the files.
        let delays: [UInt64] = activeStore ? retryDelays : [0]
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
                    try await Self.removeStore(for: profileID)
                }
                // Sweep the directories. `remove(forIdentifier:)` usually clears them for a live
                // store; recovered data is simply deleted here.
                for directory in layout.discoverDirectories(for: profileID) {
                    try FileManager.default.removeItem(at: directory)
                }
                // The archive is current again; nothing found later is post-forced-seal residue.
                try? FileManager.default.removeItem(at: forcedSealMarkerURL(for: profileID))
                log.info("Sealed profile \(profileID.uuidString, privacy: .public): \(result.stats.files) files, \(result.stats.bytes) bytes (activeStore=\(activeStore))")
                return result
            } catch {
                lastError = error
                log.notice("Seal attempt \(result.attempts) for \(profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        if activeStore && forceSealWhenStoreStaysInUse {
            log.error("WebKit kept the data store of \(profileID.uuidString, privacy: .public) in use through \(result.attempts) attempts (\(String(describing: lastError), privacy: .public)); forcing the seal before quitting")
            return try await forceSeal(profileID: profileID, key: key, result: result)
        }
        log.error("Giving up sealing \(profileID.uuidString, privacy: .public): \(String(describing: lastError), privacy: .public)")
        throw VaultError.storeStillInUse(profileID)
    }

    /// Quitting, and WebKit still holds the store after every attempt (it lets go only when the
    /// process exits): archive what is on disk now and delete the plaintext without WebKit.
    /// Nothing in this process uses the store again. Whatever WebKit writes between this and the
    /// exit is residue: the marker, written before the deletion, makes the next launch or unlock
    /// discard it instead of preferring it over this archive as it would crash leftovers.
    private func forceSeal(profileID: UUID, key: SymmetricKey, result: SealResult) async throws -> SealResult {
        let archive = repository.webDataArchiveURL(for: profileID)
        let marker = forcedSealMarkerURL(for: profileID)
        let layout = Self.layout
        var result = result
        // Two tries: a file WebKit replaces while it is being read fails one archive pass.
        for _ in 0..<2 {
            result.attempts += 1
            let directories = layout.discoverDirectories(for: profileID)
            if directories.isEmpty { return result } // WebKit removed them after all
            result.directories = directories
            do {
                let roots = Dictionary(uniqueKeysWithValues: try directories.map { (try layout.label(for: $0), $0) })
                result.stats = try await Task.detached(priority: .userInitiated) {
                    try EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key)
                }.value
                // Without the marker, residue would later be taken for newer data: never delete first.
                try Data().write(to: marker, options: .atomic)
                for directory in directories {
                    do {
                        try FileManager.default.removeItem(at: directory)
                    } catch {
                        // Left for the next launch or unlock to discard (the marker is in place).
                        log.error("Forced seal of \(profileID.uuidString, privacy: .public) could not delete \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
                result.forced = true
                log.error("Force-sealed profile \(profileID.uuidString, privacy: .public): \(result.stats.files) files, \(result.stats.bytes) bytes")
                return result
            } catch {
                log.error("Forced seal attempt for \(profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        throw VaultError.storeStillInUse(profileID)
    }

    /// After a forced seal, the profile's WebKit directories hold only what WebKit wrote between
    /// that seal and the process exit, and the archive holds the profile's data: deletes the
    /// directories, then the marker. Returns false when there is no marker. Throws (keeping the
    /// marker) when residue cannot be deleted, so it is never mistaken for the profile's data.
    @discardableResult
    func discardResidueAfterForcedSeal(profileID: UUID) throws -> Bool {
        let marker = forcedSealMarkerURL(for: profileID)
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        for directory in Self.discoverDirectories(for: profileID) {
            log.notice("Discarding WebKit data written after the forced seal of \(profileID.uuidString, privacy: .public): \(directory.path, privacy: .public)")
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.removeItem(at: marker)
        return true
    }

    // MARK: Delete

    /// Removes the profile's WebKit data. For a profile whose store this process did not create
    /// (just created, never launched since unlock, or deleted via sync) WebKit has no store to
    /// remove — and right after unlock no WebKit object exists, so `remove(forIdentifier:)` would
    /// crash; deleting the leftover directories is enough.
    func deleteData(profileID: UUID) async {
        if Self.registeredStoreIDs.contains(profileID) {
            do {
                try await Self.removeStore(for: profileID)
            } catch {
                log.notice("remove(forIdentifier:) for \(profileID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for directory in Self.discoverDirectories(for: profileID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// `WKWebViewConfiguration.processPool` is deprecated (separate pools no longer have an effect),
/// not removed, and creating the pool is the store-free way to initialize WebKit. Calling the
/// deprecated getter from a deprecated witness through a protocol keeps the build warning-free.
@MainActor
private protocol WebKitInitializing {
    func initializeWebKit()
}

@MainActor
private struct ProcessPoolInitializer: WebKitInitializing {
    @available(macOS, deprecated: 12.0)
    func initializeWebKit() {
        _ = WKWebViewConfiguration().processPool
    }
}
