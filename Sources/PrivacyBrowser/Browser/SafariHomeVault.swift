import BrowserCore
import CryptoKit
import Foundation
import os

/// The directory a profile's process gives Safari's frameworks as its home
/// (`CFFIXED_USER_HOME`, see `ProfileProcess`), encrypted between runs like everything else a
/// profile owns.
///
/// WHY SEPARATELY FROM `WebDataStoreVault`. That one seals what WebKit writes, and it does it in
/// the process that was browsing, after WebKit released the data store. This directory is what
/// *Safari's own* frameworks write — its history, its tab snapshots, its per-site settings, the
/// `com.apple.Safari` preferences — and it has to exist, with its contents, before the profile's
/// process starts: `CFFIXED_USER_HOME` is read once at process start, and Safari's chrome reads
/// those files while it builds its window, long before the launch that unseals the WebKit data.
/// So this cycle belongs to the manager process: unseal, start the child, and seal again once the
/// child has exited and nothing holds the files.
@MainActor
final class SafariHomeVault {
    private let repository: ProfileRepository
    private let log = Logger(subsystem: "PrivacyBrowser", category: "SafariHomeVault")

    init(repository: ProfileRepository) {
        self.repository = repository
    }

    /// The home directory itself, handed to the child as `CFFIXED_USER_HOME`.
    func homeDirectory(for profileID: UUID) -> URL {
        repository.directory(for: profileID).appendingPathComponent("home", isDirectory: true)
    }

    private func archiveURL(for profileID: UUID) -> URL {
        repository.safariHomeArchiveURL(for: profileID)
    }

    private static let label = ProfileTransfer.safariHomeLabel

    /// Restores the directory from its archive, ready for the child process to be started.
    /// Anything already there is left alone: it is plaintext from a run that did not get to seal
    /// (a crash), it is newer than the archive, and the next seal takes it.
    func prepareForLaunch(profileID: UUID, key: SymmetricKey) throws {
        let home = homeDirectory(for: profileID)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: home.path)
        if let contents, !contents.isEmpty {
            log.notice("Using Safari's unsealed home left by a previous run of \(profileID.uuidString, privacy: .public)")
            return
        }
        let archive = archiveURL(for: profileID)
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        // The archive restores the directory itself and refuses to write over one that is there,
        // so an empty leftover (the child creates the directory before it runs, and a profile that
        // never wrote anything leaves it behind) is removed first.
        if contents != nil { try FileManager.default.removeItem(at: home) }
        try EncryptedDirectoryArchive.unseal(from: archive, key: key) { label in
            guard label == Self.label else { throw CoreError.corruptData("unexpected label \(label) in Safari's home archive") }
            return home
        }
    }

    /// Archives the directory and removes the plaintext. Call once the profile's process has
    /// exited: while it runs, Safari's frameworks are writing in there.
    func seal(profileID: UUID, key: SymmetricKey) throws {
        let home = homeDirectory(for: profileID)
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        let stats = try EncryptedDirectoryArchive.seal(roots: [Self.label: home], to: archiveURL(for: profileID), key: key)
        try FileManager.default.removeItem(at: home)
        log.notice("Sealed Safari's home for \(profileID.uuidString, privacy: .public): \(stats.files, privacy: .public) files, \(stats.bytes, privacy: .public) bytes")
    }

    /// The lock a profile's process holds on its home for as long as it runs (`holdWhileRunning`).
    nonisolated static func lockURL(forHome home: URL) -> URL {
        home.deletingLastPathComponent().appendingPathComponent("home.lock")
    }

    /// A profile's process is running on this home — possibly one left behind by a manager that
    /// crashed: its files are in use and must not be sealed from under it.
    func isInUse(profileID: UUID) -> Bool {
        let descriptor = open(Self.lockURL(forHome: homeDirectory(for: profileID)).path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Called by a profile's own process at start: holds the home's lock until the process exits
    /// (the kernel lets go of it then, however the process ended).
    nonisolated static func holdWhileRunning(home: URL) {
        let descriptor = open(lockURL(forHome: home).path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            Logger(subsystem: "PrivacyBrowser", category: "SafariHomeVault")
                .error("Another process holds this profile's home")
        }
        // Deliberately never closed: the descriptor is the lock.
    }

    /// With the profile itself.
    func delete(profileID: UUID) {
        try? FileManager.default.removeItem(at: homeDirectory(for: profileID))
        try? FileManager.default.removeItem(at: archiveURL(for: profileID))
        try? FileManager.default.removeItem(at: Self.lockURL(forHome: homeDirectory(for: profileID)))
    }
}
