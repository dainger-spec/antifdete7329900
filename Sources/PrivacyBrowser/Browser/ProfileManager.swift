import BrowserCore
import CryptoKit
import Foundation
import AppKit
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

    var onError: ((Error) -> Void)?
    /// Called after a profile's own windows all close (not on explicit stop/lock), so the app
    /// can bring the Profiles window back to the front.
    var onReturnToProfiles: (() -> Void)?

    private let repository: ProfileRepository
    private let webDataVault: WebDataStoreVault
    private let proxyCenter: ProxyStatusCenter
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profile keys are held only while the profile runs (needed to seal on stop).
    private var keys: [UUID: SymmetricKey] = [:]
    /// Which profile (if any) holds the app-wide single-exit tunnel. Only one at a time.
    private var tunnelCoordinator = TunnelCoordinator()
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileManager")

    /// Why a launch was refused before any window opened (shown to the user).
    enum LaunchBlock: LocalizedError {
        case tunnelUnavailable
        case tunnelBusy
        var errorDescription: String? {
            switch self {
            case .tunnelUnavailable: return L("tunnel.error.failClosed")
            case .tunnelBusy: return L("tunnel.error.another")
            }
        }
    }

    init(repository: ProfileRepository, proxyCenter: ProxyStatusCenter) {
        self.repository = repository
        self.proxyCenter = proxyCenter
        self.webDataVault = WebDataStoreVault(repository: repository)
    }

    var hasRunningProfiles: Bool { !sessions.isEmpty }

    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    /// The running session of a profile (cookie import/export, menus).
    func session(for id: UUID) -> BrowserSession? { sessions[id] }

    /// The profile whose browser window is in front, if any.
    var keyWindowProfileID: UUID? {
        guard let controller = NSApp.keyWindow?.windowController as? BrowserWindowController else { return nil }
        return sessions.first { $0.value.frontmostWindow === controller }?.key
    }

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

        // Single-exit tunnel (opt-in). Bring it up BEFORE any web view exists, and fail closed:
        // if it is requested but can't run, the profile gets no network at all.
        var tunnelController: ProfileTunnelController?
        if configuration.unifiedTunnel {
            guard let egress = configuration.network.egress(tunnelAvailable: ProfileTunnelController.isAvailable),
                  case .tunnel = egress,
                  let tunnelConfig = TunnelConfiguration(egress: egress, profileID: id) else {
                throw LaunchBlock.tunnelUnavailable
            }
            if tunnelCoordinator.canStart(id) != nil { throw LaunchBlock.tunnelBusy }
            let controller = ProfileTunnelController()
            do {
                try await controller.start(tunnelConfig, proxyPassword: configuration.proxy?.password)
            } catch {
                throw error // fail-closed: no fallback to proxy-only or direct
            }
            tunnelCoordinator.started(id)
            tunnelController = controller
            Log.info("tunnel", "up for \(Log.id(id)): \(tunnelConfig.summary)")
        }

        // Open tabs are device-local and saved only for persistent profiles that restore tabs.
        let sessionStore = try repository.sessionStore(for: id, key: key, persistent: !configuration.ephemeral)
        let savedState = configuration.restoreTabs ? (try? sessionStore.load()) ?? nil : nil

        let session = BrowserSession(profileID: id, profileName: summary.name, configuration: configuration,
                                     passwordVault: passwords, library: library, sessionStore: sessionStore)
        session.proxyCenter = proxyCenter
        session.tunnelController = tunnelController
        if configuration.proxy != nil {
            session.onLoadFinished = { [weak proxyCenter] in proxyCenter?.reportLoadSucceeded(id) }
            session.onLoadFailed = { [weak proxyCenter] message in proxyCenter?.reportLoadFailed(id, message: message) }
        }
        session.onAllWindowsClosed = { [weak self] in
            // Return to the Profiles window right away; sealing then runs in the background and
            // flips the row to "Encrypting…" via busyProfileIDs.
            self?.onReturnToProfiles?()
            Task { @MainActor in await self?.stopReportingErrors(id) }
        }
        sessions[id] = session
        keys[id] = key
        runningProfileIDs.insert(id)
        if let savedState, session.restore(savedState) {
            Log.info("profiles", "launched \(Log.id(id)), restored \(savedState.windows.count) window(s)")
        } else {
            session.openWindow(url: configuration.startURL)
            Log.info("profiles", "launched \(Log.id(id))")
        }
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
        if let tunnel = session.tunnelController {
            await tunnel.stop()
            tunnelCoordinator.stopped(id)
            Log.info("tunnel", "down for \(Log.id(id))")
        }
        session.shutDown()
        // `session` is now the last reference; it is released when this scope ends, but its
        // data store reference was already dropped in shutDown().
        if !ephemeral, let key {
            let started = Date()
            try await webDataVault.seal(profileID: id, key: key)
            Log.info("profiles", "stopped and encrypted \(Log.id(id)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } else {
            Log.info("profiles", "stopped \(Log.id(id))")
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
            Log.error("profiles", "stopping \(Log.id(id)) failed: \(Log.describe(error))")
            onError?(error)
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
        proxyCenter.forget(id)
        Log.info("profiles", "deleted \(Log.id(id))")
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
                // activeStore: false — the profile is not running in this process, so the data
                // store was never created here; a WebKit-coordinated removal would abort.
                try await webDataVault.seal(profileID: summary.id, key: repository.profileKey(for: summary.id),
                                            activeStore: false)
            } catch {
                Log.error("profiles", "re-encrypting \(Log.id(summary.id)) after a crash failed: \(Log.describe(error))")
                onError?(error)
            }
            busyProfileIDs.remove(summary.id)
        }
    }
}
