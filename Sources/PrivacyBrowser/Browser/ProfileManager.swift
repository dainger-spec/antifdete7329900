import BrowserCore
import CryptoKit
import Foundation
import os

/// Launches, stops and deletes profiles; owns the running `BrowserSession`s.
///
/// Lifecycle of a persistent profile:
/// ```
/// launch: unwrap profile key → decrypt config, passwords, history, bookmarks
///         → decrypt WebKit data (webdata.pbsa → WebKit dirs)
///         → create WKWebsiteDataStore(forIdentifier:) + proxy → open window(s)
/// stop:   close windows/tabs → flush history → release data store → archive + encrypt WebKit dirs
///         → WKWebsiteDataStore.remove(forIdentifier:) → drop profile key
/// ```
/// Any number of profiles can run at once; each has its own data store and proxy.
@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var runningProfileIDs: Set<UUID> = []
    /// Profiles currently being launched or sealed (UI shows a spinner, actions disabled).
    @Published private(set) var busyProfileIDs: Set<UUID> = []

    var onError: ((String) -> Void)?

    private let repository: ProfileRepository
    private let webDataVault: WebDataStoreVault
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profile keys are held only while the profile runs (needed to seal on stop).
    private var keys: [UUID: SymmetricKey] = [:]
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileManager")

    init(repository: ProfileRepository) {
        self.repository = repository
        self.webDataVault = WebDataStoreVault(repository: repository)
    }

    var hasRunningProfiles: Bool { !sessions.isEmpty }

    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    // MARK: Launch

    func launch(_ id: UUID) async throws {
        if let session = sessions[id] {
            session.bringToFront()
            return
        }
        guard !busyProfileIDs.contains(id) else { return }
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        let summary = try repository.summary(for: id)
        let key = try repository.profileKey(for: id)
        let configuration = try repository.loadConfiguration(id, key: key)
        let passwords = try repository.passwordVault(for: id)
        // Ephemeral profiles keep history in memory only; bookmarks are explicit user data and persist.
        let history = try repository.historyStore(for: id, key: key, policy: configuration.historyPolicy,
                                                  persistent: !configuration.ephemeral)
        let library = ProfileLibrary(history: history, bookmarks: try repository.bookmarkStore(for: id, key: key),
                                     recordsHistory: configuration.historyEnabled)
        library.onError = { [weak self] message in self?.onError?(message) }

        if !configuration.ephemeral {
            // Must happen before WKWebsiteDataStore(forIdentifier:) is created.
            try await webDataVault.prepareForLaunch(profileID: id, key: key)
        }

        let session = BrowserSession(profileID: id, profileName: summary.name, configuration: configuration,
                                     passwordVault: passwords, library: library)
        session.onAllWindowsClosed = { [weak self] in
            Task { @MainActor in await self?.stopReportingErrors(id) }
        }
        sessions[id] = session
        keys[id] = key
        runningProfileIDs.insert(id)
        session.openWindow(url: configuration.startURL)
        try? repository.markLaunched(id)
    }

    /// Opens another window in an already running profile.
    func openNewWindow(_ id: UUID) {
        sessions[id]?.openWindow(url: nil)
    }

    func showLibrary(_ id: UUID, section: LibraryView.Section) {
        sessions[id]?.showLibrary(section)
    }

    // MARK: Stop

    func stop(_ id: UUID) async throws {
        guard let session = sessions.removeValue(forKey: id) else { return }
        let key = keys.removeValue(forKey: id)
        runningProfileIDs.remove(id)
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        session.onAllWindowsClosed = nil
        let ephemeral = session.configuration.ephemeral
        session.shutDown()
        // `session` is now the last reference; it is released when this scope ends, but its
        // data store reference was already dropped in shutDown().
        if !ephemeral, let key {
            try await webDataVault.seal(profileID: id, key: key)
        }
    }

    func stopAll() async {
        let ids = Array(sessions.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await self.stopReportingErrors(id) }
            }
        }
    }

    private func stopReportingErrors(_ id: UUID) async {
        do {
            try await stop(id)
        } catch {
            log.error("Stopping \(id.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            onError?(error.localizedDescription)
        }
    }

    // MARK: Delete

    func delete(_ id: UUID) async throws {
        if sessions[id] != nil {
            // WebKit must release the store first: remove(forIdentifier:) fails while it is in use.
            try? await stop(id)
        }
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }
        await webDataVault.deleteData(profileID: id)
        try repository.delete(id)
    }

    /// Called by sync when a profile was deleted on another device.
    func removeWebData(for id: UUID) async {
        await webDataVault.deleteData(profileID: id)
    }

    // MARK: Passwords

    /// The running session's vault if the profile is running (single writer), otherwise a fresh one.
    func passwordVault(for id: UUID) throws -> PasswordVault {
        if let session = sessions[id] { return session.passwordVault }
        return try repository.passwordVault(for: id)
    }

    // MARK: Crash recovery

    /// Seals WebKit data left unencrypted by a crash or forced quit. Run after unlock.
    func recoverUnsealedProfiles() async {
        for summary in repository.list() where sessions[summary.id] == nil {
            guard !WebDataStoreVault.discoverDirectories(for: summary.id).isEmpty else { continue }
            log.notice("Re-sealing unencrypted WebKit data of \(summary.id.uuidString, privacy: .public)")
            busyProfileIDs.insert(summary.id)
            do {
                try await webDataVault.seal(profileID: summary.id, key: repository.profileKey(for: summary.id))
            } catch {
                onError?("Could not re-encrypt data of profile “\(summary.name)”: \(error.localizedDescription)")
            }
            busyProfileIDs.remove(summary.id)
        }
    }
}
