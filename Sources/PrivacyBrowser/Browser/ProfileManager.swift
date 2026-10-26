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
    /// The packet tunnel that carries proxied profiles' WebRTC (when it is on).
    private let tunnel = TunnelManager.shared
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profile keys are held only while the profile runs (needed to seal on stop).
    private var keys: [UUID: SymmetricKey] = [:]
    /// Set by `shutDown()` (Lock / Quit): no launch starts, and a launch suspended in an await
    /// seals what it decrypted instead of opening a window that would outlive this manager.
    private(set) var isShuttingDown = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileManager")
    /// The run each running profile belongs to: a lookup that finishes after its profile stopped
    /// (and maybe launched again) does not act on another run.
    private var launchTokens: [UUID: UUID] = [:]
    /// Each profile's latest launch: only its lookup is acted on, so an earlier run's late answer
    /// never replaces what a later one found.
    private var latestLaunch: [UUID: UUID] = [:]
    /// Launches whose lookup through the proxy has not finished yet.
    private var lookupsInFlight: Set<UUID> = []

    /// A lookup through a profile's proxy is still running (self-test hook).
    var hasProxyLookupsInFlight: Bool { !lookupsInFlight.isEmpty }

    /// How long a launch waits for the lookup through the proxy when nothing is remembered for
    /// that proxy yet. With a remembered location it does not wait at all. A lookup still under
    /// way then finishes in the background (`proxyLookupFinishedLate`). The lookup itself gives up
    /// after 6 s.
    static var firstLookupWait: TimeInterval = 3

    /// Why a launch was refused before anything was decrypted (shown to the user).
    enum LaunchError: LocalizedError, Equatable {
        case invalidProxy(host: String)
        /// The proxy answered 407 and the profile has no user name and password for it.
        case proxyNeedsCredentials(host: String)
        var errorDescription: String? {
            switch self {
            case .invalidProxy(let host): return String(format: L("launch.error.proxyInvalid"), host)
            case .proxyNeedsCredentials(let host): return String(format: L("launch.error.proxyNeedsCredentials"), host)
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

        // Where the proxy exits (time zone, country, exit IP), asked through the proxy while the
        // web data decrypts. See ProfileConfiguration.needsProxyLookup.
        let token = UUID()
        latestLaunch[id] = token
        var lookupTask: Task<ProxyGeoLookup.Result, Never>?
        if stored.needsProxyLookup {
            lookupsInFlight.insert(token)
            lookupTask = Task {
                let result = await self.lookUpProxyLocation(stored)
                self.lookupsInFlight.remove(token)
                return result
            }
        }
        if stored.proxy != nil { await ContentRules.prepare() }
        if !stored.ephemeral {
            // Must happen before WKWebsiteDataStore(forIdentifier:) is created.
            try await webDataVault.prepareForLaunch(profileID: id, key: key)
        }
        // A location remembered for this proxy is used at once, and a lookup made only for the
        // exit IP is not waited for. Otherwise the launch waits a little: the time zone a page sees
        // should be the proxy's from its first load.
        var lookup: ProxyGeoLookup.Result?
        if let lookupTask {
            let wait = stored.needsProxyLocation && stored.rememberedProxyLocation == nil ? Self.firstLookupWait : 0
            lookup = await Self.value(of: lookupTask, within: wait)
        }
        let location = stored.proxyLocation(lookedUp: lookup?.location)

        // Lock or Quit began while the data was decrypted: a window opened now would have no
        // manager and its data would stay unencrypted. No data store exists yet, so seal the
        // decrypted directories directly (activeStore: false) and stop here.
        if isShuttingDown {
            if !stored.ephemeral { try await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            return
        }
        // A proxy that wants credentials the profile does not have: WebKit would leave every page
        // loading forever (it never shows the proxy's challenge). Refuse the launch instead.
        if lookup?.proxyRequiresCredentials == true, let proxy = stored.proxy {
            if !stored.ephemeral { _ = try? await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            throw LaunchError.proxyNeedsCredentials(host: proxy.host)
        }
        if let lookup { proxyLookupFinished(lookup, for: id, name: summary.name, stored: stored) }
        var configuration = stored.applying(location)
        configuration.webRTCRelay = await webRTCRelay(for: id, configuration)
        // Before the first web view of the run: WebKit reads its language list only once.
        WebContentLanguage.decide(location?.webLanguage)
        noteLanguageMismatch(for: id, wanted: location?.webLanguage)
        let session: BrowserSession
        do {
            session = try BrowserSession(profileID: id, profileName: summary.name, configuration: configuration,
                                         passwordVault: passwords, library: library)
        } catch {
            tunnel.unregister(profile: id)
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
        launchTokens[id] = token
        runningProfileIDs.insert(id)
        session.openWindow(url: configuration.startURL)
        try? repository.markLaunched(id)
        if lookup == nil, let lookupTask {
            let runningZone = configuration.timeZoneIdentifier
            Task { [weak self] in
                let result = await lookupTask.value
                self?.proxyLookupFinishedLate(result, for: id, name: summary.name, token: token, stored: stored, runningZone: runningZone)
            }
        }
    }

    /// The task's value if it finishes within `seconds`, else nil; the task keeps running.
    private static func value<T: Sendable>(of task: Task<T, Never>, within seconds: TimeInterval) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let race = FirstAnswer()
            Task { @MainActor in
                let value = await task.value
                if race.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                if race.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    @MainActor private final class FirstAnswer {
        private var claimed = false
        func claim() -> Bool {
            defer { claimed = true }
            return !claimed
        }
    }

    private func lookUpProxyLocation(_ configuration: ProfileConfiguration) async -> ProxyGeoLookup.Result {
        guard configuration.needsProxyLookup, let proxy = configuration.proxy else { return ProxyGeoLookup.Result() }
        let result = await ProxyGeoLookup.lookUp(proxy: proxy,
                                                 userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version))
        if result.location == nil {
            log.notice("Could not look up where the profile's proxy exits; using \(configuration.lastProxyLocation == nil ? "the system time zone" : "the last known location", privacy: .public)")
        }
        return result
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

    /// What a finished lookup tells: the exit IP compared with the previous launch's (when the
    /// profile asks for that), and the location to remember for the next launch.
    private func proxyLookupFinished(_ result: ProxyGeoLookup.Result, for id: UUID, name: String, stored: ProfileConfiguration) {
        guard let found = result.location else { return }
        if stored.warnOnProxyIPChange, let change = found.exitIPChange(since: stored.lastProxyLocation) {
            log.notice("The proxy of \(id.uuidString, privacy: .public) exits from another IP than at the previous launch")
            onError?(String(format: L("launch.proxyIPChanged"), name, change.old, change.new))
        }
        rememberProxyLocation(found, for: id)
    }

    /// A lookup that finished after the profile opened: a proxy that turned out to want
    /// credentials stops it (as a launch would have been refused), and a time zone other than the
    /// one the profile runs in is noted (it applies at the next launch: pages already loaded keep
    /// theirs).
    private func proxyLookupFinishedLate(_ result: ProxyGeoLookup.Result, for id: UUID, name: String, token: UUID,
                                         stored: ProfileConfiguration, runningZone: String?) {
        guard latestLaunch[id] == token else { return }
        let running = sessions[id] != nil && launchTokens[id] == token
        if result.proxyRequiresCredentials, running, let proxy = stored.proxy {
            onError?(String(format: L("launch.proxyNeedsCredentialsStopped"), proxy.host))
            Task { await stopReportingErrors(id) }
            return
        }
        proxyLookupFinished(result, for: id, name: name, stored: stored)
        if running, stored.needsProxyLocation, stored.timeZoneIdentifier == nil,
           let zone = result.location?.timeZoneIdentifier, zone != runningZone {
            onError?(String(format: L("launch.proxyZoneChanged"), name, zone))
        }
    }

    /// Keeps a newly found proxy location (and exit IP) in the profile's configuration, for the
    /// next launch. Read again first: the user may have edited the profile meanwhile, and an
    /// answer about a proxy they replaced is not kept. Written only when it changed.
    private func rememberProxyLocation(_ found: ProxyLocation, for id: UUID) {
        do {
            var current = try repository.loadConfiguration(id)
            guard current.proxy.map(ProxyLocation.endpoint(of:)) == found.proxyEndpoint,
                  !found.isSameLocation(as: current.lastProxyLocation) else { return }
            current.lastProxyLocation = found
            try repository.saveConfiguration(current, for: id)
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

    /// The packet tunnel's relay for a profile that wants WebRTC behind a SOCKS5 proxy, or nil:
    /// the profile then runs with WebRTC off, and the user is told why once per run.
    private func webRTCRelay(for id: UUID, _ configuration: ProfileConfiguration) async -> WebRTCRelay? {
        guard let proxy = configuration.proxy, configuration.webRTCPolicy != .disabled else { return nil }
        if let relay = await tunnel.register(profile: id, proxy: proxy) { return relay }
        if !webRTCOffNoted.contains(id) {
            webRTCOffNoted.insert(id)
            onError?(proxy.kind == .socks5 ? L("launch.webrtcOff.noTunnel") : L("launch.webrtcOff.httpProxy"))
        }
        return nil
    }

    /// Profiles already told, once per run, that their WebRTC is off.
    private var webRTCOffNoted: Set<UUID> = []

    // MARK: Stop

    func stop(_ id: UUID) async throws {
        guard let session = sessions.removeValue(forKey: id) else { return }
        launchTokens[id] = nil
        tunnel.unregister(profile: id)
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
