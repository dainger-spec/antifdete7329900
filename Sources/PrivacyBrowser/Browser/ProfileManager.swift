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
    /// Called after a profile's own windows all close (not on explicit stop/lock), so the app
    /// can bring the Profiles window back to the front.
    var onReturnToProfiles: (() -> Void)?

    private let repository: ProfileRepository
    private let webDataVault: WebDataStoreVault
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profile keys are held only while the profile runs (needed to seal on stop).
    private var keys: [UUID: SymmetricKey] = [:]
    /// Set by `shutDown()` (Lock / Quit): no launch starts, and a launch suspended in an await
    /// seals what it decrypted instead of opening a window that would outlive this manager.
    private(set) var isShuttingDown = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileManager")

    /// Why a launch was refused before anything was decrypted (shown to the user).
    enum LaunchError: LocalizedError {
        case invalidProxy(host: String)
        var errorDescription: String? {
            switch self {
            case .invalidProxy(let host): return String(format: L("launch.error.proxyInvalid"), host)
            }
        }
    }

    init(repository: ProfileRepository) {
        self.repository = repository
        self.webDataVault = WebDataStoreVault(repository: repository)
    }

    var hasRunningProfiles: Bool { !sessions.isEmpty }

    /// A profile is running, launching or being sealed: Lock / Quit must wait for it.
    var hasActivity: Bool { !sessions.isEmpty || !busyProfileIDs.isEmpty }

    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    // MARK: Launch

    func launch(_ id: UUID) async throws {
        guard !isShuttingDown else { return }
        if let session = sessions[id] {
            session.bringToFront()
            return
        }
        guard !busyProfileIDs.contains(id) else { return }
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        let summary = try repository.summary(for: id)
        let key = try repository.profileKey(for: id)
        let stored = try repository.loadConfiguration(id, key: key)
        // Refuse a proxy that cannot be applied before decrypting anything: the profile must not
        // start on a direct connection, and there is then nothing to seal again.
        if let proxy = stored.proxy {
            do { try proxy.validate() } catch { throw LaunchError.invalidProxy(host: proxy.host) }
        }
        let passwords = try repository.passwordVault(for: id)
        // Ephemeral profiles keep history in memory only; bookmarks are explicit user data and persist.
        let history = try repository.historyStore(for: id, key: key, policy: stored.historyPolicy,
                                                  persistent: !stored.ephemeral)
        let library = ProfileLibrary(history: history, bookmarks: try repository.bookmarkStore(for: id, key: key),
                                     recordsHistory: stored.historyEnabled)
        library.onError = { [weak self] message in self?.onError?(message) }

        // Where the proxy exits (time zone, country), asked through the proxy while the web data
        // decrypts. See ProfileConfiguration.matchProxyLocation.
        async let lookedUp = lookUpProxyLocation(stored)
        if stored.proxy != nil { await ContentRules.prepare() }
        if !stored.ephemeral {
            // Must happen before WKWebsiteDataStore(forIdentifier:) is created.
            try await webDataVault.prepareForLaunch(profileID: id, key: key)
        }
        let location = stored.proxyLocation(lookedUp: await lookedUp)

        // Lock or Quit began while the data was decrypted: a window opened now would have no
        // manager and its data would stay unencrypted. No data store exists yet, so seal the
        // decrypted directories directly (activeStore: false) and stop here.
        if isShuttingDown {
            if !stored.ephemeral { try await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            return
        }
        rememberProxyLocation(location, for: id, in: stored)
        let configuration = stored.applying(location)
        // Before the first web view of the run: WebKit reads its language list only once.
        WebContentLanguage.decide(location?.webLanguage)
        noteLanguageMismatch(for: id, wanted: location?.webLanguage)
        let session: BrowserSession
        do {
            session = try BrowserSession(profileID: id, profileName: summary.name, configuration: configuration,
                                         passwordVault: passwords, library: library)
        } catch {
            // Thrown before the session created its data store (see BrowserSession.init).
            if !configuration.ephemeral { _ = try? await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            throw error
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
        session.openWindow(url: configuration.startURL)
        try? repository.markLaunched(id)
    }

    private func lookUpProxyLocation(_ configuration: ProfileConfiguration) async -> ProxyLocation? {
        guard configuration.needsProxyLocation, let proxy = configuration.proxy else { return nil }
        let location = await ProxyGeoLookup.lookUp(proxy: proxy,
                                                   userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version))
        if location == nil {
            log.notice("Could not look up where the profile's proxy exits; using \(configuration.lastProxyLocation == nil ? "the system time zone" : "the last known location", privacy: .public)")
        }
        return location
    }

    /// Profiles already told, once per run, that websites see another language than their
    /// proxy's country suggests (WebKit's language list is fixed by the first profile launched).
    private var languageMismatchNoted: Set<UUID> = []

    private func noteLanguageMismatch(for id: UUID, wanted: String?) {
        guard let wanted, let decided = WebContentLanguage.decided?.first, decided != wanted,
              !languageMismatchNoted.contains(id) else { return }
        languageMismatchNoted.insert(id)
        onError?(String(format: L("launch.languageFixed"), decided, wanted))
    }

    /// Keeps a newly found proxy location in the profile's configuration, as the fallback for a
    /// later failed lookup. Written only when it changed.
    private func rememberProxyLocation(_ location: ProxyLocation?, for id: UUID, in stored: ProfileConfiguration) {
        guard let location, !location.isSameLocation(as: stored.lastProxyLocation) else { return }
        var updated = stored
        updated.lastProxyLocation = location
        do {
            try repository.saveConfiguration(updated, for: id)
        } catch {
            log.error("Could not store the proxy location of \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
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

    /// Quit: the process exits after this shutdown, so a seal whose data store WebKit still holds
    /// after every attempt is forced rather than failed (see
    /// `WebDataStoreVault.forceSealWhenStoreStaysInUse`). Also reaches seals already retrying.
    func prepareForQuit() {
        webDataVault.forceSealWhenStoreStaysInUse = true
    }

    /// The running session of a profile (self-test hook).
    func session(for id: UUID) -> BrowserSession? { sessions[id] }

    /// Lock / Quit: refuse new launches, let launches and seals already under way finish (a
    /// suspended launch seals again instead of opening a window), then stop and seal every
    /// running profile. Returns when nothing is running, launching or sealing.
    func shutDown() async {
        isShuttingDown = true
        await waitWhileBusy()
        await stopAll()
        await waitWhileBusy()
    }

    private func waitWhileBusy() async {
        while !busyProfileIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
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
            guard !isShuttingDown else { break }
            guard !WebDataStoreVault.discoverDirectories(for: summary.id).isEmpty else { continue }
            log.notice("Re-sealing unencrypted WebKit data of \(summary.id.uuidString, privacy: .public)")
            busyProfileIDs.insert(summary.id)
            do {
                // activeStore: false — the profile is not running in this process, so no live
                // store uses these directories: archive and delete them without WebKit API.
                try await webDataVault.seal(profileID: summary.id, key: repository.profileKey(for: summary.id),
                                            activeStore: false)
            } catch {
                onError?("Could not re-encrypt data of profile “\(summary.name)”: \(error.localizedDescription)")
            }
            busyProfileIDs.remove(summary.id)
        }
    }
}
