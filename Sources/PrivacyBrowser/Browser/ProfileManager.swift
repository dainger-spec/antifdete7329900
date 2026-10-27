import BrowserCore
import CryptoKit
import Foundation
import os
import WebKit

/// Launches, stops and deletes profiles; owns the running `BrowserSession`s.
///
/// Lifecycle of a persistent profile:
/// ```
/// launch: unwrap profile key → decrypt config, passwords, history, bookmarks
///         → decrypt WebKit data (webdata.pbsa → WebKit dirs)
///         → create WKWebsiteDataStore(forIdentifier:) + proxy
///         → synced cookies (cookies.bin) and queued imported cookies into the store → open window(s)
/// stop:   write cookies to disk → record them for sync → close windows/tabs → flush history → release data store → archive + encrypt WebKit dirs
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
    /// "Passwords…" in a profile's AutoFill list: open that profile's password manager.
    var onShowPasswords: ((UUID) -> Void)?

    private let repository: ProfileRepository
    private let webDataVault: WebDataStoreVault
    /// The packet tunnel that carries proxied profiles' WebRTC (when it is on).
    private let tunnel = TunnelManager.shared
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profile keys are held only while the profile runs (needed to seal on stop).
    private var keys: [UUID: SymmetricKey] = [:]
    /// The password vault a launch opened, until its session holds it (`passwordVault(for:)`).
    private var launchingVaults: [UUID: PasswordVault] = [:]
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
    /// The session warm-up robot of each profile that used one since unlock.
    private var warmUpRobots: [UUID: WarmUpRobot] = [:]

    /// A lookup through a profile's proxy is still running (self-test hook).
    var hasProxyLookupsInFlight: Bool { !lookupsInFlight.isEmpty }

    /// How long a launch waits for the lookup through the proxy when nothing is remembered for
    /// that proxy yet. A lookup still under way then finishes in the background
    /// (`proxyLookupFinishedLate`). The lookup itself gives up after 6 s.
    static var firstLookupWait: TimeInterval = 3
    /// The same with a location remembered for the proxy: a quick answer still sets this run's
    /// time zone and language (a rotating proxy is not one launch behind), a slow one does not
    /// hold the launch.
    static var rememberedLookupWait: TimeInterval = 1

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
        // Until the session exists, the password manager uses this same vault (one writer per file).
        launchingVaults[id] = passwords
        defer { launchingVaults[id] = nil }
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
        // The proxy's time zone and language should apply from the first page: the launch waits
        // a little for the lookup (briefly when a location is remembered for this proxy, which is
        // used if the lookup is slower). A lookup made only for the exit IP is not waited for.
        var lookup: ProxyGeoLookup.Result?
        if let lookupTask {
            let wait = !stored.needsProxyLocation ? 0
                : stored.rememberedProxyLocation == nil ? Self.firstLookupWait : min(Self.firstLookupWait, Self.rememberedLookupWait)
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
            let passwordSettings = ProfilePasswordSettings(repository: repository, profileID: id, profileName: summary.name,
                                                           launchConfiguration: stored)
            passwordSettings.showManager = { [weak self] in self?.onShowPasswords?(id) }
            session = try BrowserSession(profileID: id, profileName: summary.name, configuration: configuration,
                                         passwordVault: passwords, passwordSettings: passwordSettings, library: library)
        } catch {
            tunnel.unregister(profile: id)
            // Thrown before the session created its data store (see BrowserSession.init).
            if !configuration.ephemeral { _ = try? await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            throw error
        }
        // Synced cookies, and cookies imported while the profile was stopped: into its store
        // before the first page loads.
        await prepareCookies(of: id, summary: summary, syncs: stored.syncsCookies, session: session)
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
            // In flight until its answer has been acted on, not only received.
            let pending = UUID()
            lookupsInFlight.insert(pending)
            Task { [weak self] in
                let result = await lookupTask.value
                self?.proxyLookupFinishedLate(result, for: id, name: summary.name, token: token, stored: stored, runningZone: runningZone)
                self?.lookupsInFlight.remove(pending)
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
        // Not when, since the launch, the warning was turned off or the proxy removed or replaced
        // (a late answer): it is about a proxy the profile no longer asks about.
        let current = try? repository.loadConfiguration(id)
        let stillAsked = current.map { $0.warnOnProxyIPChange && $0.proxy.map(ProxyLocation.endpoint(of:)) == found.proxyEndpoint } ?? true
        if stored.warnOnProxyIPChange, stillAsked, let change = found.exitIPChange(since: stored.lastProxyLocation) {
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
        // Lock or Quit under way: nothing is written, and nothing is shown over the lock screen.
        guard latestLaunch[id] == token, !isShuttingDown else { return }
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
        // The run's language was decided without this answer (the first profile of a run that got
        // none in time leaves websites the user's own languages): say so.
        if running, stored.needsProxyLocation {
            noteLanguageMismatch(for: id, wanted: result.location?.webLanguage)
        }
    }

    /// Keeps a newly found proxy location (and exit IP) in the profile's configuration, for the
    /// next launch. Read again first: the user may have edited the profile meanwhile, and an
    /// answer about a proxy they replaced (or its credentials) is not kept. The exit IP is kept
    /// only while the warning that asks for it is on. Written only when it changed.
    private func rememberProxyLocation(_ found: ProxyLocation, for id: UUID) {
        do {
            var current = try repository.loadConfiguration(id)
            var found = found
            if !current.warnOnProxyIPChange { found.exitIP = nil }
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
        // First of all, before anything waits: the robot must not act in a session going away
        // (a tab it opened now would get no store, proxy or scripts of the profile).
        warmUpRobots[id]?.stop(.profileStopped)
        launchTokens[id] = nil
        tunnel.unregister(profile: id)
        let key = keys.removeValue(forKey: id)
        runningProfileIDs.remove(id)
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        session.onAllWindowsClosed = nil
        let ephemeral = session.configuration.ephemeral
        // Cookies set in the last moments (by a page, or imported) are written before the data is
        // sealed: CFNetwork would write them later, after the archive was made.
        if !ephemeral, let store = session.dataStore {
            await CookieStoreImport.flush(store.httpCookieStore)
            // What this run changed, for sync (the settings as they are now: sync may have been
            // turned off while it ran).
            if let key, (try? repository.loadConfiguration(id, key: key))?.syncsCookies == true {
                await recordSyncedCookies(of: id, in: store.httpCookieStore)
            }
        }
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

    /// Returns when no profile is launching or being sealed.
    func waitWhileBusy() async {
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
        warmUpRobots[id] = nil
        try repository.delete(id)
    }

    /// Called by sync when a profile was deleted on another device.
    func removeWebData(for id: UUID) async {
        await webDataVault.deleteData(profileID: id)
    }

    // MARK: Session warm-up

    /// The profile's warm-up robot (made on first use).
    func warmUpRobot(for id: UUID) -> WarmUpRobot {
        if let robot = warmUpRobots[id] { return robot }
        let robot = WarmUpRobot(profileID: id)
        robot.onProgress = { [weak self] in self?.objectWillChange.send() }
        warmUpRobots[id] = robot
        return robot
    }

    /// A warm-up robot of a profile is running (the profile list shows it).
    func isWarmingUp(_ id: UUID) -> Bool { warmUpRobots[id]?.isRunning ?? false }

    /// Starts `plan` in the running profile. False when the profile is not running, or the robot
    /// cannot start (already running, nothing to visit).
    @discardableResult
    func startWarmUp(_ id: UUID, plan: WarmUpPlan) -> Bool {
        guard !isShuttingDown, let session = sessions[id] else { return false }
        return warmUpRobot(for: id).start(plan, in: session)
    }

    // MARK: Cookie import

    enum CookieImportOutcome: Equatable {
        /// Into the running profile's store now; `refused`: those WebKit did not keep.
        case applied(stored: Int, refused: [ImportedCookie])
        /// The profile is stopped (its website data is sealed): queued, encrypted, for its next
        /// launch; `queued` counts all waiting cookies.
        case queued(Int)
    }

    enum CookieImportError: LocalizedError {
        case busy
        var errorDescription: String? { L("cookies.error.busy") }
    }

    /// Imports `cookies` into a profile: at once when it runs, else at its next launch, before
    /// its first page loads.
    func importCookies(_ cookies: [ImportedCookie], into id: UUID) async throws -> CookieImportOutcome {
        if let store = sessions[id]?.dataStore {
            let result = await CookieStoreImport.apply(cookies, to: store.httpCookieStore)
            log.notice("Imported \(result.stored) cookies into a running profile, \(result.refused.count) refused")
            return .applied(stored: result.stored, refused: result.refused)
        }
        // Starting or being encrypted: its store is about to exist or to go.
        guard !busyProfileIDs.contains(id), !isShuttingDown else { throw CookieImportError.busy }
        return .queued(try repository.queueImportedCookies(cookies, for: id))
    }

    // MARK: Synced cookies

    /// At launch, before the first page loads. With cookie sync on: what the store changed since
    /// it was last recorded (a run that ended without a stop) is recorded as changes of that
    /// time, the earliest they can be — with nothing recorded yet (sync just turned on), as old
    /// as can be: they fill in what the synced cookies lack, and any synced change wins over
    /// them. Then the document (with what sync brought from the other devices) is applied to the
    /// store, then the cookies imported while the profile was stopped go in and are recorded as
    /// changes of now. With sync off, the profile keeps no synced cookies (`clearSyncedCookies`).
    private func prepareCookies(of id: UUID, summary: ProfileSummary, syncs: Bool, session: BrowserSession) async {
        guard syncs else {
            try? repository.clearSyncedCookies(for: id)
            await applyQueuedCookies(of: id, name: summary.name, to: session)
            return
        }
        guard let store = session.dataStore?.httpCookieStore else { return }
        var synced: (loaded: CookieJarDocument, jar: CookieJarDocument, baseline: [ImportedCookie])?
        do {
            let loaded = try repository.cookieJar(for: id)
            let baseline = try repository.cookieBaseline(for: id)
            let jar = loaded.recording(store: await CookieStoreSync.persistentCookies(in: store), baseline: baseline.cookies,
                                       at: baseline.savedAt)
            let applied = await CookieStoreSync.apply(jar, to: store)
            log.notice("Synced cookies at launch: \(applied.set) set, \(applied.deleted) deleted, \(applied.refused.count) refused")
            synced = (loaded, jar, await CookieStoreSync.persistentCookies(in: store))
        } catch {
            log.error("Could not read the synced cookies of \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            onError?(String(format: L("cookies.sync.unreadable"), summary.name))
        }
        await applyQueuedCookies(of: id, name: summary.name, to: session)
        guard let synced else { return }
        let now = Date()
        let current = await CookieStoreSync.persistentCookies(in: store)
        saveSyncedCookies(of: id, name: summary.name, loaded: synced.loaded,
                          jar: synced.jar.recording(store: current, baseline: synced.baseline, at: now),
                          baseline: CookieBaseline(cookies: current, savedAt: now))
    }

    /// At stop: what the run changed, as changes of now.
    private func recordSyncedCookies(of id: UUID, in store: WKHTTPCookieStore) async {
        let name = (try? repository.summary(for: id).name) ?? ""
        do {
            let loaded = try repository.cookieJar(for: id)
            let baseline = try repository.cookieBaseline(for: id)
            let now = Date()
            let current = await CookieStoreSync.persistentCookies(in: store)
            // Nothing recorded yet (sync turned on while it ran): as at launch, as old as can be.
            let since = baseline.savedAt == .distantPast ? .distantPast : now
            saveSyncedCookies(of: id, name: name, loaded: loaded, jar: loaded.recording(store: current, baseline: baseline.cookies, at: since),
                              baseline: CookieBaseline(cookies: current, savedAt: now))
        } catch {
            log.error("Could not read the synced cookies of \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            onError?(String(format: L("cookies.sync.unreadable"), name))
        }
    }

    /// The document only when it changed: rewriting it unchanged would make sync upload it again.
    private func saveSyncedCookies(of id: UUID, name: String, loaded: CookieJarDocument, jar: CookieJarDocument, baseline: CookieBaseline) {
        do {
            if jar != loaded { try repository.saveCookieJar(jar, for: id) }
            try repository.saveCookieBaseline(baseline, for: id)
        } catch {
            log.error("Could not save the synced cookies of \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            onError?(String(format: L("cookies.sync.saveFailed"), name))
        }
    }

    private func applyQueuedCookies(of id: UUID, name: String, to session: BrowserSession) async {
        let queued: [ImportedCookie]
        do {
            queued = try repository.importedCookiesForLaunch(id)
        } catch {
            log.error("Could not read the cookies queued for \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            repository.clearImportedCookies(id)
            onError?(String(format: L("cookies.launch.unreadable"), name))
            return
        }
        guard !queued.isEmpty, let store = session.dataStore else { return }
        let result = await CookieStoreImport.apply(queued, to: store.httpCookieStore)
        repository.clearImportedCookies(id)
        log.notice("Applied \(result.stored) imported cookies at launch, \(result.refused.count) refused")
        if !result.refused.isEmpty {
            onError?(String(format: L("cookies.launch.refused"), result.refused.count, name,
                            result.refused.prefix(5).map { "\($0.name) (\($0.domain))" }.joined(separator: ", ")))
        }
    }

    // MARK: Passwords

    /// The running (or launching) profile's vault, so that each file has one writer; otherwise a
    /// fresh one.
    func passwordVault(for id: UUID) throws -> PasswordVault {
        if let session = sessions[id] { return session.passwordVault }
        if let launching = launchingVaults[id] { return launching }
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
