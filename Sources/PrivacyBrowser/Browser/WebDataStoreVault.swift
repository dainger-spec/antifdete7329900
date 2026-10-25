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
///     FileVault and file permissions);
///   * on stop, the directories are archived + encrypted and then removed via
///     `WKWebsiteDataStore.remove(forIdentifier:)`.
///
/// The directory layout is not documented by Apple. Rather than hard-coding it, this
/// type locates WebKit's directories by name: WebKit names them after the store's UUID,
/// so any directory with that name below our bundle's WebKit/Caches folders belongs to
/// the profile. If WebKit ever stores per-identifier data elsewhere, it would not be
/// sealed — verify on new macOS releases with
/// `find ~/Library -iname '<profile-uuid>' 2>/dev/null`.
///
/// A crash while a profile is running leaves plaintext on disk until the next unlock,
/// when `recoverUnsealedProfiles` re-seals it.
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

    // MARK: Launch

    /// Decrypts the profile's archived WebKit data into WebKit's directories.
    /// Must be called before the profile's `WKWebsiteDataStore` is created.
    func prepareForLaunch(profileID: UUID, key: SymmetricKey) async throws {
        let residue = Self.discoverDirectories(for: profileID)
        if !residue.isEmpty {
            // Leftover plaintext from a crash. It is newer than the archive (it was produced
            // by unsealing that archive and then browsing), so keep it; the next stop seals it.
            log.notice("Using unsealed WebKit data left by a previous run for profile \(profileID.uuidString, privacy: .public)")
            return
        }
        let archive = repository.webDataArchiveURL(for: profileID)
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        let library = Self.libraryDirectory
        _ = try await Task.detached(priority: .userInitiated) {
            try EncryptedDirectoryArchive.unseal(from: archive, key: key) { label in
                try Self.destination(forLabel: label, profileID: profileID, library: library)
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
    func seal(profileID: UUID, key: SymmetricKey) async throws {
        let archive = repository.webDataArchiveURL(for: profileID)
        let library = Self.libraryDirectory
        let delays: [UInt64] = [1, 2, 3, 5, 8]
        var lastError: Error?
        for (attempt, seconds) in delays.enumerated() {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            let directories = Self.discoverDirectories(for: profileID)
            if directories.isEmpty { return } // nothing was ever written, or already sealed
            do {
                let roots = Dictionary(uniqueKeysWithValues: directories.map { (Self.label(for: $0, library: library), $0) })
                let stats = try await Task.detached(priority: .userInitiated) {
                    try EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key)
                }.value
                try await WKWebsiteDataStore.remove(forIdentifier: profileID)
                // remove(forIdentifier:) deletes the store; sweep anything it left behind.
                for directory in Self.discoverDirectories(for: profileID) {
                    try FileManager.default.removeItem(at: directory)
                }
                log.info("Sealed profile \(profileID.uuidString, privacy: .public): \(stats.files) files, \(stats.bytes) bytes")
                return
            } catch {
                lastError = error
                log.notice("Seal attempt \(attempt + 1) for \(profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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

    // MARK: Directory discovery

    nonisolated static var libraryDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    }

    nonisolated private static var bundleName: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    /// Subtrees in which WebKit places this app's per-identifier data stores.
    /// Observed layouts (macOS 14/15), relative to ~/Library (or the sandbox container's Library):
    ///   WebKit/<bundleID>/WebsiteDataStore/<UUID>             (non-sandboxed, general storage)
    ///   WebKit/WebsiteDataStore/<UUID>                        (sandboxed, general storage)
    ///   Caches/<bundleID>/WebKit/WebsiteDataStore/<UUID>      (network cache)
    nonisolated private static var searchRoots: [URL] {
        let library = libraryDirectory
        return [
            library.appendingPathComponent("WebKit/\(bundleName)", isDirectory: true),
            library.appendingPathComponent("WebKit/WebsiteDataStore", isDirectory: true),
            library.appendingPathComponent("Caches/\(bundleName)", isDirectory: true),
        ]
    }

    nonisolated static func discoverDirectories(for profileID: UUID) -> [URL] {
        let target = profileID.uuidString.lowercased()
        var found: [URL] = []
        var seen = Set<String>()
        for root in searchRoots {
            search(root, target: target, depth: 0, maxDepth: 3, found: &found, seen: &seen)
        }
        return found
    }

    nonisolated private static func search(_ directory: URL, target: String, depth: Int, maxDepth: Int,
                               found: inout [URL], seen: inout Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let child = directory.appendingPathComponent(name, isDirectory: true)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue } // lstat: no symlinks
            if name.lowercased() == target {
                if seen.insert(child.path).inserted { found.append(child) }
            } else if depth < maxDepth {
                search(child, target: target, depth: depth + 1, maxDepth: maxDepth, found: &found, seen: &seen)
            }
        }
    }

    /// Archive root label = path relative to ~/Library with "/" → "|" (labels are single path components).
    nonisolated static func label(for directory: URL, library: URL) -> String {
        let relative = directory.path.dropFirst(library.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.replacingOccurrences(of: "/", with: "|")
    }

    /// Inverse of `label(for:)`, restricted to the known subtrees and to a directory named after the profile.
    nonisolated static func destination(forLabel label: String, profileID: UUID, library: URL) throws -> URL {
        let components = label.split(separator: "|").map(String.init)
        guard components.count >= 2,
              ["WebKit", "Caches"].contains(components[0]),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.last?.lowercased() == profileID.uuidString.lowercased() else {
            throw CoreError.unsafeArchivePath(label)
        }
        return components.reduce(library) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
