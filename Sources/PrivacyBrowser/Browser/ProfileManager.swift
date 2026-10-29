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
    /// A warm-up run of a profile moved on: another page visited, or it finished. The per-profile
    /// process reports it to the manager over the channel (`ProfileChannel`).
    var onWarmUpProgress: ((UUID) -> Void)?
    /// A profile's own process reported that it is up, and whether its window is Safari's chrome
    /// (the self-test checks that the chrome's own web views load through the profile's proxy).
    var onProfileRunning: ((UUID, Bool) -> Void)?
    /// A profile's own process answered `checkNetwork` (`ProfileNetworkGuard.report`).
    var onNetworkReport: ((UUID, ProfileNetworkReport) -> Void)?
    /// This manager is the one inside a profile's own process (`ProfileSessionHost`), where the
    /// process *is* the profile: ending a warm-up there means quitting, which the host does, so
    /// this manager does not stop the profile itself.
    var runsInProfileProcess = false
    /// A profile's stored configuration changed outside the editor (a proxy lookup remembered a
    /// new exit location): the Profiles list shows it.
    var onConfigurationChanged: ((UUID) -> Void)?
    /// A profile that was started has a proxy that does not work, and the probe says how
    /// (`diagnoseProxy`): it would load no page — fail-closed — and this is what says why.
    var onProxyProblem: ((UUID, ProxySettings, ProxyDiagnosis) -> Void)?

    private let repository: ProfileRepository
    private let webDataVault: WebDataStoreVault
    /// The directory Safari's frameworks use as their home in a profile's own process, encrypted
    /// between runs like everything else (`SafariHomeVault`).
    private let safariHomeVault: SafariHomeVault
    /// The packet tunnel that carries proxied profiles' WebRTC (when it is on).
    private let tunnel = TunnelManager.shared
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profiles running in their own process (`ProfileProcess`, off unless asked for). A profile is
    /// in this or in `sessions`, never both.
    private var children: [UUID: ProfileProcess] = [:]
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
    /// A cookie import sent to a profile's own process, waiting for its answer.
    private var pendingCookieExports: [UUID: CheckedContinuation<[ImportedCookie], Error>] = [:]
    private var pendingCookieImports: [UUID: CheckedContinuation<CookieImportOutcome, Error>] = [:]
    /// Where the warm-up of each profile running in its own process has got to, as that process
    /// last reported it. The one the manager keeps for a profile it runs itself comes from the
    /// robot instead (`warmUpStatus(of:)`).
    private var reportedWarmUp: [UUID: WarmUpStatus] = [:]

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
        self.safariHomeVault = SafariHomeVault(repository: repository)
    }

    var hasRunningProfiles: Bool { !sessions.isEmpty || !children.isEmpty }

    /// A profile is running, launching or being sealed: Lock / Quit must wait for it.
    var hasActivity: Bool { !sessions.isEmpty || !children.isEmpty || !busyProfileIDs.isEmpty }

    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil || children[id] != nil }

    // MARK: Launch

    func launch(_ id: UUID, openingWindow: Bool = true) async throws {
        guard !isShuttingDown else { return }
        if let session = sessions[id] {
            // A profile that is only being warmed up has no window yet: a launch now gives it one.
            if !session.hasVisibleWindow, openingWindow,
               !SafariChromeHost.open(session: session, url: session.configuration.startURL) {
                session.openWindow(url: session.configuration.startURL)
            }
            session.bringToFront()
            return
        }
        if let child = children[id] {
            child.send(.activate)
            child.bringToFront()
            return
        }
        guard !busyProfileIDs.contains(id) else { return }
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        let summary = try repository.summary(for: id)
        let key = try repository.profileKey(for: id)
        let stored = try repository.loadConfiguration(id, key: key)
        // A proxy that does not work leaves the profile with no page loaded: said in words, by the
        // same probe the Proxies sheet's check runs, while the profile starts.
        if let proxy = stored.proxy, !runsInProfileProcess { diagnoseProxy(of: id, proxy, startURL: stored.startURL) }
        // A profile's own process runs its profile itself: it never starts another process.
        if ProfileProcess.isEnabled, !runsInProfileProcess {
            var stored = stored
            // Its languages and time zone are fixed when the process starts. With no location
            // remembered for the proxy yet — a first launch, or a new proxy — they are looked up
            // here first, as briefly as a launch in this process waits, rather than the process
            // starting with this Mac's own languages and learning the proxy's only for next time.
            if stored.needsProxyLocation, stored.rememberedProxyLocation == nil, (try? stored.proxy?.validate()) != nil {
                let lookup = Task { await self.lookUpProxyLocation(stored) }
                if let result = await Self.value(of: lookup, within: Self.firstLookupWait), result.location != nil {
                    proxyLookupFinished(result, for: id, name: summary.name, stored: stored)
                    stored = (try? repository.loadConfiguration(id, key: key)) ?? stored
                }
            }
            try startInOwnProcess(id, summary: summary, stored: stored, forWarmUpOnly: !openingWindow)
            return
        }
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
        // Attribution reports a page set up before Private Click Measurement was off for proxied
        // profiles would still be sent by WebKit, later, outside the page's session: removed.
        if configuration.proxy != nil, let store = session.dataStore {
            await store.removeData(ofTypes: ["_WKWebsiteDataTypePrivateClickMeasurements", "_WKWebsiteDataTypeAdClickAttributions"],
                                   modifiedSince: .distantPast)
        }
        session.onAllWindowsClosed = { [weak self] in
            // Return to the Profiles window right away; sealing then runs in the background and
            // flips the row to "Encrypting…" via busyProfileIDs.
            self?.onReturnToProfiles?()
            Task { @MainActor in await self?.stopReportingErrors(id) }
        }
        sessions[id] = session
        // Before any web view of this process exists: in a profile's own process every web view is
        // built with this session's data store, which is what carries its proxy (ProfileNetworkGuard).
        ProfileNetworkGuard.register(session: session)
        keys[id] = key
        launchTokens[id] = token
        runningProfileIDs.insert(id)
        // This launch's lookup (also one made only for the exit IP), else what was found before.
        session.exitLocation = lookup?.location ?? stored.rememberedProxyLocation
        // In a per-profile child process, Safari's own chrome is the window and the profile's web
        // view is its content (SafariChromeHost); everywhere else, and on a macOS where that is
        // not available, our own window as before. A launch for a warm-up opens none: the robot
        // browses in a window of its own that the user never sees.
        if openingWindow, !SafariChromeHost.open(session: session, url: configuration.startURL) {
            session.openWindow(url: configuration.startURL)
        }
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

    /// Hands the profile to a process of its own, and does nothing else: the child runs the launch
    /// itself, from the same vault, and seals on its way out (`ProfileProcess`,
    /// `ProfileSessionHost`).
    ///
    /// What the language and time zone are decided from here, before the child starts: the
    /// location remembered for this profile's proxy. They are read once per process by the system,
    /// so they have to be known before it exists; the child looks the proxy up again and a changed
    /// answer applies at its next launch. For a profile that does not follow its proxy, the user's
    /// own languages, as Safari uses them.
    private func startInOwnProcess(_ id: UUID, summary: ProfileSummary, stored: ProfileConfiguration,
                                   forWarmUpOnly: Bool = false) throws {
        guard let executable = Bundle.main.executableURL else { throw CoreError.corruptData("no executable path") }
        let location = stored.needsProxyLocation ? stored.rememberedProxyLocation : nil
        let languages = location.map { [$0.webLanguage] } ?? WebContentLanguage.systemLanguages
        // Safari's own state has to be on disk before its frameworks read it, which happens while
        // the child builds its window — before the launch inside the child unseals the WebKit data.
        let key = try repository.profileKey(for: id)
        try safariHomeVault.prepareForLaunch(profileID: id, key: key)
        let child = try ProfileProcess.start(
            profileID: id,
            executable: executable,
            vaultRoot: repository.root,
            grant: repository.grant(for: id),
            home: safariHomeVault.homeDirectory(for: id),
            languages: languages,
            locale: languages.first.map { $0.replacingOccurrences(of: "-", with: "_") },
            timeZone: stored.timeZoneIdentifier ?? location?.timeZoneIdentifier,
            forWarmUpOnly: forWarmUpOnly)
        child.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .error(let message):
                self.onError?(message)
            case .running(let hostsSafariChrome):
                self.onProfileRunning?(id, hostsSafariChrome)
                self.objectWillChange.send()
            case .warmUp(let status):
                self.reportedWarmUp[id] = status
                self.onWarmUpProgress?(id)
                self.objectWillChange.send()
            case .cookiesImported(let outcome):
                let pending = self.pendingCookieImports.removeValue(forKey: id)
                if let outcome { pending?.resume(returning: outcome) } else { pending?.resume(throwing: CookieImportError.busy) }
            case .cookiesExported(let cookies):
                let pending = self.pendingCookieExports.removeValue(forKey: id)
                if let cookies { pending?.resume(returning: cookies) } else { pending?.resume(throwing: CookieImportError.busy) }
            case .networkReport(let report):
                self.onNetworkReport?(id, report)
            case .configurationSaved:
                try? self.repository.bumpRevision(id)
                self.onConfigurationChanged?(id)
            }
        }
        child.onExit = { [weak self] status in
            guard let self, self.children[id] === child else { return }
            self.pendingCookieImports.removeValue(forKey: id)?.resume(throwing: CookieImportError.busy)
            self.pendingCookieExports.removeValue(forKey: id)?.resume(throwing: CookieImportError.busy)
            self.children[id] = nil
            self.runningProfileIDs.remove(id)
            // A warm-up cannot outlive the process it ran in; what it collected is still shown.
            if self.reportedWarmUp[id]?.isRunning == true { self.reportedWarmUp[id]?.phase = .stopped }
            // Nothing holds those files now. Sealed whatever way the process ended: one that crashed
            // left its WebKit data in plaintext in this home too, and it goes into the same archive
            // (the next launch takes it from there, as any crash residue).
            var sealed = true
            do {
                try self.safariHomeVault.seal(profileID: id, key: key)
            } catch {
                sealed = false
                self.log.error("Could not seal Safari's home for \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                self.onError?(String(format: L("profile.homeNotSealed"), summary.name, error.localizedDescription))
            }
            // A stop asked for from here takes this handler away first, so this is a process that
            // ended on its own: said, not only logged.
            if status != 0 {
                self.log.error("Profile \(id.uuidString, privacy: .public) exited with status \(status, privacy: .public)")
                self.onError?(String(format: L(sealed ? "profile.crashed" : "profile.crashedUnsealed"), summary.name))
            }
            self.onReturnToProfiles?()
        }
        children[id] = child
        runningProfileIDs.insert(id)
        try? repository.markLaunched(id)
    }

    /// Probes the proxy of a profile that is starting (`ProxyProbe`), and says what is wrong with it
    /// when it does not work (`onProxyProblem`) — unless the profile was stopped meanwhile. The
    /// tunnel it asks for goes to the profile's own start page, which the profile is about to ask
    /// the same proxy for (no start page: the first geolocation service), and only one: no latency
    /// is measured here. The probe talks to the proxy alone.
    private func diagnoseProxy(of id: UUID, _ proxy: ProxySettings, startURL: URL?) {
        guard onProxyProblem != nil, (try? proxy.validate()) != nil else { return }
        var configured = ProxyChecker.probe(latencySamples: 1)
        if let url = startURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty {
            configured.targetHost = host
            configured.targetPort = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        }
        let probe = configured
        Task { @MainActor [weak self] in
            let diagnosis = await probe.run(proxy)
            guard let self, !diagnosis.isWorking, self.isRunning(id) || self.busyProfileIDs.contains(id) else { return }
            self.log.notice("The proxy of \(id.uuidString, privacy: .public) does not work: \(diagnosis.verdict.rawValue, privacy: .public)")
            self.onProxyProblem?(id, proxy, diagnosis)
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
        if running, let found = result.location { sessions[id]?.exitLocation = found }
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
            onConfigurationChanged?(id)
        } catch {
            log.error("Could not store the proxy location of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// Asks a profile running in its own process where its traffic goes; the answer comes back
    /// through `onNetworkReport`. False when the profile does not run in a process of its own.
    @discardableResult
    func checkNetwork(_ id: UUID, probe: URL? = nil) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.checkNetwork(probe: probe))
        return true
    }

    /// The process a profile runs in, when it runs in one of its own.
    func processIdentifier(of id: UUID) -> Int32? { children[id]?.processIdentifier }

    /// Opens another window in an already running profile.
    func openNewWindow(_ id: UUID) {
        if let child = children[id] {
            child.send(.openWindow)
            child.bringToFront()
            return
        }
        sessions[id]?.openWindow(url: nil)
    }

    /// Another window of a running profile, on `url`.
    func openWindow(_ id: UUID, url: URL) {
        if let child = children[id] {
            child.send(.openURL(url))
            child.bringToFront()
            return
        }
        sessions[id]?.openWindow(url: url)
    }

    func showLibrary(_ id: UUID, section: LibraryView.Section) {
        if let child = children[id] {
            child.send(.showLibrary(section: section.rawValue))
            child.bringToFront()
            return
        }
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
        if let child = children.removeValue(forKey: id) {
            runningProfileIDs.remove(id)
            busyProfileIDs.insert(id)
            defer { busyProfileIDs.remove(id) }
            // Its own quit path seals the WebKit data; this returns when that finished, and then
            // Safari's home is sealed here, where nothing is writing in it any more.
            child.onExit = nil
            child.terminate()
            await child.waitUntilExit(timeout: 30)
            if let key = try? repository.profileKey(for: id) {
                try safariHomeVault.seal(profileID: id, key: key)
            }
            return
        }
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
        let ids = Array(sessions.keys) + Array(children.keys)
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
            log.error("Stopping \(id.uuidString, privacy: .public) failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            onError?(error.localizedDescription)
        }
    }

    // MARK: Delete

    func delete(_ id: UUID) async throws {
        if sessions[id] != nil || children[id] != nil {
            // WebKit must release the store first: remove(forIdentifier:) fails while it is in use.
            try? await stop(id)
        }
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }
        await webDataVault.deleteData(profileID: id)
        safariHomeVault.delete(profileID: id)
        warmUpRobots[id] = nil
        reportedWarmUp[id] = nil
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
        robot.onProgress = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.onWarmUpProgress?(id)
            // Started for the warm-up alone, so it has no window of its own: the run is over, so
            // the profile stops, and stopping is what seals what it collected. (In a profile's own
            // process that quit is the process's; see ProfileSessionHost.)
            if !self.runsInProfileProcess, let robot = self.warmUpRobots[id], !robot.isRunning, robot.state != .idle,
               let session = self.sessions[id], !session.hasVisibleWindow {
                Task { @MainActor [weak self] in try? await self?.stop(id) }
            }
        }
        warmUpRobots[id] = robot
        return robot
    }

    /// Where the profile's warm-up has got to, wherever it runs: from its own process, what that
    /// process last reported; in the manager's process, the robot's own state. Nil when this
    /// profile has not been warmed up since unlock.
    func warmUpStatus(of id: UUID) -> WarmUpStatus? {
        if children[id] != nil { return reportedWarmUp[id] }
        guard let robot = warmUpRobots[id], robot.state != .idle else { return reportedWarmUp[id] }
        return robot.status
    }

    /// The pages of a warm-up running in this process, one by one, for the warm-up screen's list.
    /// Empty for a profile in its own process: what that run reports is `warmUpStatus`.
    func warmUpVisits(of id: UUID) -> [WarmUpVisit] {
        children[id] == nil ? (warmUpRobots[id]?.visits ?? []) : []
    }

    /// Stops the profile's warm-up, wherever it runs. The profile itself keeps running.
    func stopWarmUp(_ id: UUID) {
        if let child = children[id] {
            child.send(.stopWarmUp)
            if reportedWarmUp[id]?.isRunning == true { reportedWarmUp[id]?.phase = .stopped }
            objectWillChange.send()
            return
        }
        warmUpRobots[id]?.stop()
    }

    /// Starts `plan` in the running profile. False when the profile is not running, or the robot
    /// cannot start (already running, nothing to visit).
    @discardableResult
    func startWarmUp(_ id: UUID, plan: WarmUpPlan) -> Bool {
        guard !isShuttingDown else { return false }
        if let child = children[id] {
            // The same refusal the in-process robot gives, before anything is sent: a plan with no
            // page is not a run, and the screen should say so rather than show a warm-up that
            // never starts.
            let pages = plan.pages().pages.count
            guard pages > 0 else { return false }
            reportedWarmUp[id] = WarmUpStatus(phase: .running, visited: 0, total: pages,
                                              secondsRemaining: Double(pages) * plan.secondsPerPage)
            child.send(.startWarmUp(plan))
            objectWillChange.send()
            return true
        }
        guard let session = sessions[id] else { return false }
        return warmUpRobot(for: id).start(plan, in: session)
    }

    // MARK: Cookie import

    enum CookieImportOutcome: Equatable, Codable {
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
        // A profile in its own process imports into its own store, and says how it went.
        if let child = children[id] {
            guard pendingCookieImports[id] == nil else { throw CookieImportError.busy }
            return try await withCheckedThrowingContinuation { continuation in
                pendingCookieImports[id] = continuation
                child.send(.importCookies(cookies))
                // A process that does not answer (it is sealing on its way out) is not waited on.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    self?.pendingCookieImports.removeValue(forKey: id)?.resume(throwing: CookieImportError.busy)
                }
            }
        }
        if let store = sessions[id]?.dataStore {
            let result = await CookieStoreImport.apply(cookies, to: store.httpCookieStore)
            log.notice("Imported \(result.stored) cookies into a running profile, \(result.refused.count) refused")
            return .applied(stored: result.stored, refused: result.refused)
        }
        // Starting or being encrypted: its store is about to exist or to go.
        guard !busyProfileIDs.contains(id), !isShuttingDown else { throw CookieImportError.busy }
        return .queued(try repository.queueImportedCookies(cookies, for: id))
    }

    /// Every cookie of a profile, session cookies included, for an export (`CookieExport`). A
    /// running profile is asked as it runs, in its own process or here. A stopped one is started
    /// without a window, asked, and stopped — which seals its data again — as a warm-up does.
    func exportCookies(of id: UUID) async throws -> [ImportedCookie] {
        let wasRunning = isRunning(id)
        if !wasRunning {
            guard !busyProfileIDs.contains(id), !isShuttingDown else { throw CookieImportError.busy }
            try await launch(id, openingWindow: false)
        }
        do {
            let cookies = try await cookiesOf(id)
            if !wasRunning { try? await stop(id) }
            return cookies
        } catch {
            if !wasRunning { try? await stop(id) }
            throw error
        }
    }

    private func cookiesOf(_ id: UUID) async throws -> [ImportedCookie] {
        if let child = children[id] {
            guard pendingCookieExports[id] == nil else { throw CookieImportError.busy }
            return try await withCheckedThrowingContinuation { continuation in
                pendingCookieExports[id] = continuation
                // Sent at once: a process that is still starting acts on it once the profile is up.
                child.send(.exportCookies)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    self?.pendingCookieExports.removeValue(forKey: id)?.resume(throwing: CookieImportError.busy)
                }
            }
        }
        guard let store = sessions[id]?.dataStore?.httpCookieStore else { throw CookieImportError.busy }
        return await CookieStoreSync.exportableCookies(in: store)
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
            log.error("Could not read the synced cookies of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
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
            log.error("Could not read the synced cookies of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            onError?(String(format: L("cookies.sync.unreadable"), name))
        }
    }

    /// The document only when it changed: rewriting it unchanged would make sync upload it again.
    private func saveSyncedCookies(of id: UUID, name: String, loaded: CookieJarDocument, jar: CookieJarDocument, baseline: CookieBaseline) {
        do {
            if jar != loaded { try repository.saveCookieJar(jar, for: id) }
            try repository.saveCookieBaseline(baseline, for: id)
        } catch {
            log.error("Could not save the synced cookies of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            onError?(String(format: L("cookies.sync.saveFailed"), name))
        }
    }

    private func applyQueuedCookies(of id: UUID, name: String, to session: BrowserSession) async {
        let queued: [ImportedCookie]
        do {
            queued = try repository.importedCookiesForLaunch(id)
        } catch {
            log.error("Could not read the cookies queued for \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
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

    /// A stopped profile's data, all of it sealed: WebKit data a crash left in plaintext is
    /// archived again, and so is Safari's home of a profile whose own process did not get to
    /// seal it. Nothing happens to a running profile, whose data is in use.
    func sealLeftovers(of id: UUID) async throws {
        guard !isRunning(id), !busyProfileIDs.contains(id) else { return }
        let key = try repository.profileKey(for: id)
        if !WebDataStoreVault.discoverDirectories(for: id).isEmpty {
            try await webDataVault.seal(profileID: id, key: key, activeStore: false)
        }
        try safariHomeVault.seal(profileID: id, key: key)
    }

    /// A home still held by a profile's process that a crashed manager left behind is sealed once
    /// that process has gone (it quits by itself when its channel closes): looked at every two
    /// seconds for up to ten minutes, unless the profile is started again meanwhile.
    private func sealHomeWhenFree(_ summary: ProfileSummary) {
        log.notice("Safari's home of \(summary.id.uuidString, privacy: .public) is still in use; sealed once its process is gone")
        Task { @MainActor [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.isShuttingDown,
                      self.sessions[summary.id] == nil, self.children[summary.id] == nil else { return }
                guard !self.safariHomeVault.isInUse(profileID: summary.id) else { continue }
                do {
                    try self.safariHomeVault.seal(profileID: summary.id, key: self.repository.profileKey(for: summary.id))
                } catch {
                    self.onError?(String(format: L("recovery.homeNotSealed"), summary.name, error.localizedDescription))
                }
                return
            }
        }
    }

    /// Seals WebKit data left unencrypted by a crash or forced quit, and Safari's home of a
    /// profile whose process ended without the manager sealing it (the manager itself crashed, or
    /// was killed, while the profile ran). Run after unlock.
    func recoverUnsealedProfiles() async {
        for summary in repository.list() where sessions[summary.id] == nil && children[summary.id] == nil {
            guard !isShuttingDown else { break }
            guard FileManager.default.fileExists(atPath: safariHomeVault.homeDirectory(for: summary.id).path) else { continue }
            if safariHomeVault.isInUse(profileID: summary.id) {
                sealHomeWhenFree(summary)
                continue
            }
            log.notice("Re-sealing Safari's unencrypted home of \(summary.id.uuidString, privacy: .public)")
            do {
                try safariHomeVault.seal(profileID: summary.id, key: repository.profileKey(for: summary.id))
            } catch {
                onError?(String(format: L("recovery.homeNotSealed"), summary.name, error.localizedDescription))
            }
        }
        for summary in repository.list() where sessions[summary.id] == nil && children[summary.id] == nil {
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
                onError?(String(format: L("recovery.webDataNotSealed"), summary.name, error.localizedDescription))
            }
            busyProfileIDs.remove(summary.id)
        }
    }
}
