import BrowserCore
import CryptoKit
import Foundation
import os
import TunnelCore
import TunnelTransport
import WebKit

/// Launches, stops and deletes profiles; owns the running `BrowserSession`s.
///
/// Lifecycle of a persistent profile:
/// ```
/// launch: unwrap profile key → decrypt config, passwords, history, bookmarks
///         → decrypt WebKit data (webdata.pbsa → WebKit dirs)
///         → create WKWebsiteDataStore(forIdentifier:) + proxy
///         → cookies the store lost put back from their snapshot (cookie-snapshots.bin)
///         → synced cookies (cookies.bin) and queued imported cookies into the store → open window(s)
/// run:    the store's cookies copied when they change (CookieSnapshotKeeper)
/// stop:   write cookies to disk → record them for sync → last snapshot → close windows/tabs → flush history → release data store → archive + encrypt WebKit dirs
///         → WKWebsiteDataStore.remove(forIdentifier:) → drop profile key
/// ```
/// Any number of profiles can run at once; each has its own data store and proxy.
@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var runningProfileIDs: Set<UUID> = [] {
        // The system camera is fed while a profile set to it runs (`SystemCameraFeed`).
        didSet { if !runsInProfileProcess { SystemCameraFeed.shared.keep(only: runningProfileIDs) } }
    }
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
    /// A scenario's run of a profile, wherever it runs: its log and how it ended.
    struct ScenarioRunState: Equatable {
        var runID: UUID
        var name: String
        var startedAt: Date
        var lines: [ScenarioRunner.Line]
        var outcome: ScenarioRunner.Outcome?
        var isRunning: Bool { outcome == nil }
    }

    /// The last run of a scenario of each profile (the scenario screen shows it).
    @Published private(set) var scenarioRuns: [UUID: ScenarioRunState] = [:]
    private var scenarioRunners: [UUID: ScenarioRunner] = [:]
    /// Whether the plan has automation, asked before each command of a run in this process. In a
    /// profile's own process it stays true: the manager sends a stop when the plan loses it.
    var scenariosAllowed: () -> Bool = { true }
    /// Whether the plan has camera substitution (docs/CAMERA.md), asked when a profile launches. The
    /// parent reads it from the license and carries the answer to the child (`PB_CAMERA_ALLOWED`);
    /// the child's manager reads it back from there. False neutralises a profile's camera at launch.
    var cameraAllowed: () -> Bool = { true }
    /// Told of each line and the end of a run in this process (a profile's process passes them on).
    var onScenarioLine: ((UUID, UUID, ScenarioRunner.Line) -> Void)?
    var onScenarioEnded: ((UUID, UUID, ScenarioRunner.Outcome) -> Void)?
    /// A scenario is being recorded in a profile: something the person did there, or a page that loaded.
    var onRecorded: ((UUID, ScenarioRecorder.Event) -> Void)?
    /// A profile's own process reported that it is up, and whether its window is Safari's chrome
    /// (the self-test checks that the chrome's own web views load through the profile's proxy).
    var onProfileRunning: ((UUID, Bool) -> Void)?
    /// A profile's process said which language its interface took (`ProfileEvent.interfaceLanguage`):
    /// the language given, its bundles', Safari's chrome's. The self-test's.
    var onInterfaceLanguage: ((UUID, String, String, String?) -> Void)?
    /// A profile's own process answered `checkNetwork` (`ProfileNetworkGuard.report`).
    var onNetworkReport: ((UUID, ProfileNetworkReport) -> Void)?
    /// A profile's own process answered `checkKeychain` (`KeychainCheck`).
    var onKeychainReport: ((UUID, KeychainReport) -> Void)?
    /// This manager is the one inside a profile's own process (`ProfileSessionHost`), where the
    /// process *is* the profile: ending a warm-up there means quitting, which the host does, so
    /// this manager does not stop the profile itself.
    var runsInProfileProcess = false
    /// A profile's stored configuration changed outside the editor (a proxy lookup remembered a
    /// new exit location): the Profiles list shows it.
    var onConfigurationChanged: ((UUID) -> Void)?
    /// A profile's window asked for Settings (⌘, in Safari's chrome): the app's own open.
    var onShowSettings: (() -> Void)?
    /// A profile's WebKit data was sealed here, and how (a profile's process tells its manager).
    var onSealed: ((UUID, ProfileSealReport) -> Void)?
    /// A step of the menu walk a profile's process was asked for (`walkMenu`; `--menu-walk`).
    var onMenuWalk: ((UUID, String) -> Void)?
    /// A line of the sweep a profile's process was asked for (`sweep`; `--sweep`).
    var onSweep: ((UUID, String) -> Void)?
    /// What a profile's History window showed when the self-test asked (`lookAtHistory`).
    var onHistoryLook: ((UUID, HistoryWindowLook) -> Void)?
    /// What a profile's window showed after the self-test acted on it (`lookAtWindow`).
    var onWindowLook: ((UUID, WindowLook) -> Void)?
    /// A profile's process ended on its own (a quit of its own, or a crash: `status` is not 0),
    /// after its home was sealed. Not called for a stop asked for from here (`--menu-walk`).
    var onChildExited: ((UUID, Int32) -> Void)?
    /// A profile's process ended after a stop asked for from here, and how: 0 when it quit by itself,
    /// else the signal that ended it (a crash on its way out, or the kill after 30 s). The self-test's.
    var onChildStopped: ((UUID, Int32) -> Void)?
    /// A profile's process told how it sealed its data, just before it exited (the self-test).
    var onChildSealed: ((UUID, ProfileSealReport) -> Void)?
    /// A launch put back cookies the profile's store had lost (docs/COOKIE_RECOVERY.md), here or in
    /// the profile's own process: told once per launch, for the profile's journal.
    var onCookiesRecovered: ((UUID, CookieSnapshotKeeper.Report) -> Void)?
    /// Profiles whose proxy's exit no geolocation service could tell at their last launch (they
    /// are blocked often): said once when it happens, and shown in the profile's row and editor
    /// until its next launch.
    @Published private(set) var proxyLocationUnknown: Set<UUID> = []
    /// In a profile's own process: its proxy's exit was not found (the manager says so).
    var onProxyLocationUnknown: ((UUID) -> Void)?
    /// A lookup through the profile's proxy answered (in a profile's own process): the manager in
    /// the app, which keeps `proxyLocationUnknown` for the list and the editor, is told, so an
    /// earlier "unknown" of this launch does not stay beside a place that is known now.
    var onProxyLocationFound: ((UUID) -> Void)?
    /// Pages of Safari's chrome closed by a quit, before the seal (`prepareForQuit`).
    private var pagesClosedForQuit = 0
    /// Settings → Proxies: a profile whose proxy does not work is not started at all — its proxy is
    /// asked first (`refusesFailingProxy`), and `onProxyLaunchRefused` says how it failed.
    var refusesFailingProxy: () -> Bool = { false }
    var onProxyLaunchRefused: ((UUID, ProxySettings, ProxyDiagnosis) -> Void)?

    /// A profile that was started has a proxy that does not work, and the probe says how
    /// (`diagnoseProxy`): it would load no page — fail-closed — and this is what says why.
    var onProxyProblem: ((UUID, ProxySettings, ProxyDiagnosis) -> Void)?
    /// Whether a profile may start (the license, `LicenseModel.refusalToOpen`): asked before a
    /// profile that is not running starts; an open one keeps working whatever it says (the owner:
    /// work in the middle of something is not cut off). Nil: every profile starts (the self-test's
    /// own managers, a build without licensing).
    var launchGate: ((UUID) -> Error?)?

    private let repository: ProfileRepository
    private let webDataVault: WebDataStoreVault
    /// The cookie snapshots of the profiles run in this process, and what their launches put back.
    let cookieSnapshots: CookieSnapshotKeeper
    /// The directory Safari's frameworks use as their home in a profile's own process, encrypted
    /// between runs like everything else (`SafariHomeVault`).
    private let safariHomeVault: SafariHomeVault
    /// Why a running profile that wants WebRTC runs without it (`WebRTCGate`), for its row and
    /// inspector; said once when it is decided. Gone when the profile stops.
    @Published private(set) var webRTCRefusals: [UUID: WebRTCRefusal] = [:]
    /// The running profiles whose WebRTC must not connect and stays in their pages, connecting
    /// nowhere, the network guard holding their process (`decideWebRTC`; the self-test reads it).
    private(set) var webRTCSilenced: Set<UUID> = []
    private var sessions: [UUID: BrowserSession] = [:]
    /// Profiles running in their own process (`ProfileProcess`, off unless asked for). A profile is
    /// in this or in `sessions`, never both.
    private var children: [UUID: ProfileProcess] = [:]
    /// The profiles whose own process has said its window is up (`.running`), and who waits for that.
    private var windowsUp: Set<UUID> = []
    private var windowWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    /// Profile keys are held only while the profile runs (needed to seal on stop).
    private var keys: [UUID: SymmetricKey] = [:]
    /// The password vault a launch opened, until its session holds it (`passwordVault(for:)`).
    private var launchingVaults: [UUID: PasswordVault] = [:]
    /// Set by `shutDown()` (Lock / Quit): no launch starts, and a launch suspended in an await
    /// seals what it decrypted instead of opening a window that would outlive this manager.
    private(set) var isShuttingDown = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileManager")
    private static let webRTCLog = Logger(subsystem: "PrivacyBrowser", category: "ProfileManager")
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
    /// Cookie imports and exports sent to profiles' own processes, waiting for their answers — by
    /// the request's id, which the process sends back with its answer — each with the timer that
    /// stops waiting for it. They were kept by the profile's id, and a timer was never cancelled:
    /// an earlier request's timer ended a later one as "busy", and its answer could then end a
    /// retry with the earlier request's counts.
    private var pendingCookieImports: [UUID: (profile: UUID, continuation: CheckedContinuation<CookieImportOutcome, Error>,
                                              timeout: Task<Void, Never>)] = [:]
    private var pendingCookieExports: [UUID: (profile: UUID, continuation: CheckedContinuation<[ImportedCookie], Error>,
                                              timeout: Task<Void, Never>)] = [:]
    /// WebDriver calls sent to profiles' own processes, waiting for their answers (by the call's id).
    private var pendingWebDriver: [UUID: (profile: UUID, continuation: CheckedContinuation<WebDriverAnswer, Never>)] = [:]
    /// The WebDriver's page of each profile run in this process that has a session (`webDriver`).
    private var webDriverExecutors: [UUID: WebDriverExecutor] = [:]
    /// A network report asked of a profile's own process and awaited (`networkReport(of:)`).
    private var recordingStops: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pendingNetworkReports: [UUID: [CheckedContinuation<ProfileNetworkReport?, Never>]] = [:]
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
        /// A process of the profile that an earlier run of the app left behind is still sealing
        /// its data (`launch`).
        case stillSealing(name: String)
        /// The profile's OpenVPN connection did not come up (docs/OPENVPN.md): why, in words.
        case openVPN(name: String, reason: String)
        /// The profile's proxy is a share link, and this build has no relay for it (`XrayRelays`).
        case relayNotInBuild(name: String)
        /// The profile's proxy is a share link, and its relay did not start.
        case relayDidNotStart(name: String)
        var errorDescription: String? {
            switch self {
            case .invalidProxy(let host): return String(format: L("launch.error.proxyInvalid"), host)
            case .proxyNeedsCredentials(let host): return String(format: L("launch.error.proxyNeedsCredentials"), host)
            case .stillSealing(let name): return String(format: L("launch.error.stillSealing"), name)
            case .openVPN(let name, let reason): return String(format: L("launch.error.openVPN"), name, reason)
            case .relayNotInBuild(let name): return String(format: L("launch.error.relayNotInBuild"), name)
            case .relayDidNotStart(let name): return String(format: L("launch.error.relayDidNotStart"), name)
            }
        }
    }

    init(repository: ProfileRepository) {
        self.repository = repository
        self.webDataVault = WebDataStoreVault(repository: repository)
        self.cookieSnapshots = CookieSnapshotKeeper(repository: repository)
        self.safariHomeVault = SafariHomeVault(repository: repository)
        // The guard stopped answering for processes it held: their relays stop at once, and their
        // profiles stop — nothing of theirs runs on without it.
        NetworkGuard.shared.onHoldsLost = { [weak self] pids in
            self?.guardLost(pids)
        }
    }

    private func guardLost(_ pids: [pid_t]) {
        for (id, child) in children where pids.contains(child.processIdentifier) {
            WebRTCRelays.shared.stop(profile: id)
            let name = (try? repository.summary(for: id).name) ?? ""
            log.error("The network guard is gone for \(id.uuidString, privacy: .public): the profile stops")
            onError?(String(format: L("launch.guardLost"), name))
            Task { try? await self.stop(id) }
        }
    }

    var hasRunningProfiles: Bool { !sessions.isEmpty || !children.isEmpty }

    /// A profile is running, launching or being sealed: Lock / Quit must wait for it.
    var hasActivity: Bool { !sessions.isEmpty || !children.isEmpty || !busyProfileIDs.isEmpty }

    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil || children[id] != nil }

    // MARK: Restore points

    /// Why a restore point was not made or restored here, beyond `RestorePointProblem`.
    enum RestorePointRefusal: Error, Equatable {
        /// The profile runs, starts or is being sealed: its files on disk are not the whole of it.
        case inUse
        /// Data of a run that did not get to seal is on disk beside the archives (a crash): the
        /// profile is to be started and stopped once first, which seals it.
        case unsealed
    }

    /// The profile can have a point made or restored now: stopped, nothing under way, and its
    /// website data and Safari's home sealed (the archives on disk are the whole of it).
    private func checkRestorable(_ id: UUID) throws {
        guard !isRunning(id), !busyProfileIDs.contains(id) else { throw RestorePointRefusal.inUse }
        guard !webDataVault.holdsUnsealedData(profileID: id), !safariHomeVault.holdsUnsealedHome(profileID: id) else {
            throw RestorePointRefusal.unsealed
        }
    }

    /// Makes a restore point of a stopped profile (`ProfileRepository.createRestorePoint`); the
    /// profile is busy meanwhile, so it does not start while its files are copied.
    func createRestorePoint(_ id: UUID, name: String) async throws -> RestorePoint {
        try checkRestorable(id)
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }
        let repository = repository
        return try await Task.detached(priority: .userInitiated) {
            try repository.createRestorePoint(for: id, name: name)
        }.value
    }

    /// Puts a stopped profile back as point `pointID` holds it (`ProfileRepository.restore`), the
    /// state it replaces kept as a point first. Returns that point.
    @discardableResult
    func restore(_ id: UUID, to pointID: UUID) async throws -> RestorePoint {
        try checkRestorable(id)
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }
        let repository = repository
        let kept = try await Task.detached(priority: .userInitiated) {
            try repository.restore(pointID, for: id)
        }.value
        log.notice("Profile \(id.uuidString, privacy: .public) restored to a restore point")
        return kept
    }

    /// Whether `id`'s window is up: at once for a profile run in this process, whose launch returns
    /// with its window; for one in a process of its own, once that process says so — false when it
    /// ends first, or after `seconds` (the selection's Launch, `LaunchQueue`).
    func waitForWindow(_ id: UUID, seconds: Double) async -> Bool {
        guard children[id] != nil else { return sessions[id] != nil }
        if windowsUp.contains(id) { return true }
        return await withCheckedContinuation { continuation in
            windowWaiters[id, default: []].append(continuation)
            // Held until then, so that a wait always ends.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.resumeWindowWaiters(of: id, up: false)
            }
        }
    }

    private func resumeWindowWaiters(of id: UUID, up: Bool) {
        for waiter in windowWaiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: up) }
    }

    // MARK: Launch

    /// `forExport`: started without a window only to take its data out (the cookies' export) — the
    /// license's export-only mode allows that (CONTRACT §8.1, the owner's decision), so the gate is
    /// not asked; nothing is navigated.
    func launch(_ id: UUID, openingWindow: Bool = true, forExport: Bool = false) async throws {
        guard !isShuttingDown else { return }
        if sessions[id] == nil, children[id] == nil { proxyLocationUnknown.remove(id) }
        if let session = sessions[id] {
            // A profile that is only being warmed up has no window yet: a launch now gives it one.
            if !session.hasVisibleWindow, openingWindow {
                let tabs = restorableTabs(of: id, session.configuration)
                if !SafariChromeHost.open(session: session, url: session.configuration.startURL, restoring: tabs) {
                    session.openFirstWindows(restoring: tabs, startURL: session.configuration.startURL)
                }
                presentCookieRecovery(id)
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
        if !forExport, let refusal = launchGate?(id) { throw refusal }
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        // A process of this profile that an app before this one left running (it crashed or was
        // killed) quits by itself when its channel closes, and seals the profile's data as it goes:
        // a second process on the same home and website data would write under it. Waited for, as
        // long as a stop waits for a process to seal, then refused.
        if ProfileProcess.isEnabled, !runsInProfileProcess, safariHomeVault.isInUse(profileID: id) {
            log.notice("\(id.uuidString, privacy: .public) is still held by a process an earlier run left: waiting for it to seal and quit")
            guard await waitUntilHomeIsFree(of: id, seconds: 30) else {
                if isShuttingDown { return }
                throw LaunchError.stillSealing(name: (try? repository.summary(for: id).name) ?? "")
            }
        }
        // Partial plaintext an unseal of this profile that did not finish left (R8): first, whatever
        // the launch then does, and before its archives are extracted again.
        AppEnvironment.removeUnsealLeftovers(vault: repository.root, of: id)
        let summary = try repository.summary(for: id)
        let key = try repository.profileKey(for: id)
        let stored = try repository.loadConfiguration(id, key: key)
        // A proxy that a relay of the app's carries — a share link's, an OpenVPN connection — is
        // reached through that relay alone (`LocalRelays`, docs/TUNNEL.md, "Relays"): it is started
        // here, before anything asks the proxy — the probe, the lookup, the process — and the
        // profile's proxy stays what is stored; whatever connects through it is given the relay
        // (`ProxyRoutes`). A launch that ends without a process of the profile running stops it
        // again. A profile's own process starts none: its manager's route is handed to it with its
        // grant (`ProfileSessionHost`).
        var relayStarted = false
        if let proxy = stored.proxy, proxy.localRelay != nil, !runsInProfileProcess {
            try await startRelay(for: id, proxy: proxy, name: summary.name)
            relayStarted = true
        }
        defer {
            if relayStarted, children[id] == nil, sessions[id] == nil { LocalRelays.stop(owner: id) }
        }
        // Settings → Proxies → "Do not start it": the proxy is asked before anything is decrypted,
        // and a profile whose proxy does not work stays stopped; the Profiles window says why.
        var probedBeforeLaunch = false
        if let proxy = stored.proxy, !runsInProfileProcess, refusesFailingProxy(), (try? proxy.validate()) != nil {
            let (probe, reportsNoUpstream) = launchProbe(startURL: stored.startURL)
            let diagnosis = await probe.run(proxy)
            if !diagnosis.isWorking, diagnosis.verdict != .noUpstream || reportsNoUpstream {
                log.notice("Not starting \(id.uuidString, privacy: .public): its proxy does not work (\(diagnosis.verdict.rawValue, privacy: .public))")
                onProxyLaunchRefused?(id, proxy, diagnosis)
                return
            }
            probedBeforeLaunch = true
        }
        // A proxy that does not work leaves the profile with no page loaded: said in words, by the
        // same probe the Proxies section's check runs, while the profile starts.
        if let proxy = stored.proxy, !runsInProfileProcess, !probedBeforeLaunch {
            diagnoseProxy(of: id, proxy, startURL: stored.startURL)
        }
        // A profile's own process runs its profile itself: it never starts another process. Every
        // profile runs in one of its own, WebRTC through its proxy included: the relay is this
        // process's, and the network guard holds the profile's process to its proxy
        // (`decideWebRTC`, docs/TUNNEL.md).
        if ProfileProcess.isEnabled, !runsInProfileProcess {
            var stored = stored
            // Its languages and time zone are fixed when the process starts: WebKit reads the
            // language list from the process's command line before anything in it can change it.
            // So where the proxy exits is looked up here first, at every launch — not only when
            // nothing is remembered: a proxy that exited in Finland last time and exits in the
            // United States now must not start a process that speaks Finnish to every site until it
            // is quit (the lead, 7 November; the self-test's "languages per profile"). It waits as
            // long as a first launch does, since what it starts with stays; a lookup slower than
            // that leaves the remembered location, and the profile's process looks again and says
            // when the country changed.
            var foundNow = false
            if stored.needsProxyLocation, stored.proxy == nil || (try? stored.proxy?.validate()) != nil {
                let lookup = Task { await self.lookUpProxyLocation(stored) }
                if let result = await Self.value(of: lookup, within: Self.firstLookupWait), result.location != nil {
                    proxyLookupFinished(result, for: id, name: summary.name, stored: stored)
                    stored = (try? repository.loadConfiguration(id, key: key)) ?? stored
                    foundNow = true
                }
            }
            try startInOwnProcess(id, summary: summary, stored: stored, forWarmUpOnly: !openingWindow, proxyLocationFound: foundNow)
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
        if stored.needsProxyLookup, !locationFoundByManager {
            lookupsInFlight.insert(token)
            lookupTask = Task {
                let result = await self.lookUpProxyLocation(stored)
                self.lookupsInFlight.remove(token)
                return result
            }
        }
        if ContentRules.needed(by: stored) { await ContentRules.prepare() }
        // A warm-up that spares traffic needs its tab's list as it starts (`openOffscreenWindow`).
        if !stored.ephemeral { await ContentRules.prepareWarmUp() }
        var restored = WebDataStoreVault.Restored.nothing
        var storeState = (state: CookieRecovery.StoreState.present, note: "")
        if !stored.ephemeral {
            // Must happen before WKWebsiteDataStore(forIdentifier:) is created.
            restored = try await webDataVault.prepareForLaunch(profileID: id, key: key)
            // What cookie recovery needs of the disk: before the store exists, and CFNetwork reads
            // (and rewrites) its cookie file.
            if stored.keepsCookieSnapshots { storeState = CookieSnapshotKeeper.storeState(for: id, restored: restored) }
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
        let webRTC = await webRTCLaunch(for: id, configuration)
        configuration.webRTCRelay = webRTC.relay
        configuration.webRTCSilent = webRTC.silent
        // Lock or Quit began while the manager's word on WebRTC was awaited (`shutDown` ends that
        // wait): as above, nothing is opened, and what was decrypted is sealed again.
        if isShuttingDown {
            if !stored.ephemeral { try await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            return
        }
        // Camera substitution is the plan's (docs/CAMERA.md). Below pro/team the profile's camera is
        // turned off here — before the session's shim or the system camera's config is built from it —
        // so a stored camera never reaches a page on a plan that does not open it.
        if configuration.cameraSubstitution.mode != .off, !cameraAllowed() {
            configuration.cameraSubstitution = .off
        }
        // Before the first web view of the run: WebKit reads its language list only once. The
        // profile's own language when one is set, else its proxy country's.
        let language = stored.webLanguage(for: location)
        if runsInProfileProcess {
            // A profile's own process: WebKit took the list on its command line, which the app
            // chose (`startInOwnProcess`). Recorded as it is, so that a late answer is compared
            // with what pages really see — not with a list this process could no longer give them.
            WebContentLanguage.adoptCommandLine()
        } else {
            WebContentLanguage.decide(language)
        }
        noteLanguageMismatch(for: id, wanted: language)
        // The system camera's render config and its "active" flag live in the app group. A profile's
        // own process is kept out of it, so there the parent already wrote the config and passed the
        // flag (`startInOwnProcess`); the app's own process (sandboxed, in-window) reads and writes it
        // here (docs/CAMERA.md).
        let systemCameraActive: Bool
        if runsInProfileProcess {
            // One profile in this process: its geolocation is the engine's own answer, before any
            // web view exists (`NativeGeolocation`; the page script answers where WebKit cannot).
            NativeGeolocation.engage(configuration.geolocation)
            systemCameraActive = ProfileProcess.systemCameraActiveForThisProcess
        } else {
            let usesSystemCamera = configuration.cameraSubstitution.usesSystemCamera
            if usesSystemCamera {
                SystemCamera.shared.writeRenderConfig(for: configuration.cameraSubstitution)
            }
            systemCameraActive = SystemCamera.shared.activeForLaunch(usesSystemCamera: usesSystemCamera)
        }
        let session: BrowserSession
        do {
            let passwordSettings = ProfilePasswordSettings(repository: repository, profileID: id, profileName: summary.name,
                                                           launchConfiguration: stored)
            passwordSettings.showManager = { [weak self] in self?.onShowPasswords?(id) }
            session = try BrowserSession(profileID: id, profileName: summary.name, configuration: configuration,
                                         passwordVault: passwords, passwordSettings: passwordSettings, library: library,
                                         systemCameraActive: systemCameraActive)
            // The engine as saved now, read at each search: a change in the editor applies at once.
            session.searchEngine = { [repository, configuration] in
                (try? repository.loadConfiguration(id, key: key))?.searchEngine ?? configuration.searchEngine ?? .standard
            }
        } catch {
            // Thrown before the session created its data store (see BrowserSession.init).
            if !configuration.ephemeral { _ = try? await webDataVault.seal(profileID: id, key: key, activeStore: false) }
            throw error
        }
        // Cookies the store lost, synced cookies, and cookies imported while the profile was
        // stopped: into its store before the first page loads.
        await prepareCookies(of: id, summary: summary, stored: stored, storeRestored: restored != .nothing,
                             storeState: storeState, session: session)
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
        // A profile in this process keeps its relay until it stops (`stop`).
        sessions[id] = session
        // Before any web view of this process exists: in a profile's own process every web view is
        // built with this session's data store, which is what carries its proxy (ProfileNetworkGuard).
        ProfileNetworkGuard.register(session: session)
        keys[id] = key
        launchTokens[id] = token
        runningProfileIDs.insert(id)
        // The system camera's frames are drawn here, in the app's own process (`SystemCameraFeed`).
        if !runsInProfileProcess, configuration.cameraSubstitution.usesSystemCamera {
            SystemCameraFeed.shared.use(for: id)
        }
        // This launch's lookup (also one made only for the exit IP), else what was found before.
        session.exitLocation = lookup?.location ?? stored.rememberedProxyLocation
        // In a per-profile child process, Safari's own chrome is the window and the profile's web
        // view is its content (SafariChromeHost); everywhere else, and on a macOS where that is
        // not available, our own window as before. A launch for a warm-up opens none: the robot
        // browses in a window of its own that the user never sees.
        if openingWindow {
            // The tabs it left open come back in either window (Settings → Startup → Restore tabs).
            let tabs = restorableTabs(of: id, configuration)
            if !SafariChromeHost.open(session: session, url: configuration.startURL, restoring: tabs) {
                session.openFirstWindows(restoring: tabs, startURL: configuration.startURL)
            }
        }
        // Cookies put back at this launch: said in its window, or told for the journal when it has none.
        presentCookieRecovery(id)
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
                                   forWarmUpOnly: Bool = false, proxyLocationFound: Bool = false) throws {
        // LumenProfile, never the app's own executable: in a build with the network guard that one
        // carries the app's keychain, which every profile would then share (`ProfileExecutable`).
        let executable: URL
        do {
            executable = try ProfileExecutable.url()
        } catch {
            log.error("A profile's process was not started: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            throw error
        }
        let location = stored.needsProxyLocation ? stored.rememberedProxyLocation : nil
        // The profile's own language first (its editor: set by hand or at random), as a launch in
        // this process takes it (`webLanguage(for:)`). Inside the child it is too late to change:
        // WebKit has read the command line's list before the launch there decides anything (CI run
        // 579). Never the interface's language, which the child is given apart (`ProfileProcess`).
        let languages = stored.webLanguage(for: location).map { [$0] } ?? WebContentLanguage.systemLanguages
        // Safari's own state has to be on disk before its frameworks read it, which happens while
        // the child builds its window — before the launch inside the child unseals the WebKit data.
        let key = try repository.profileKey(for: id)
        try safariHomeVault.prepareForLaunch(profileID: id, key: key)
        // The system camera's render config and its "active" flag live in the app group, which a
        // profile's own process is kept out of (`ProfileExecutable`, no app-group entitlement). So the
        // parent — which can reach it — writes the config and reads whether the extension is on, and
        // passes the answer to the child (docs/CAMERA.md). Off below the plan (cameraAllowed) or when
        // the profile does not use the system camera.
        let usesSystemCamera = cameraAllowed() && stored.cameraSubstitution.usesSystemCamera
        if usesSystemCamera {
            SystemCamera.shared.writeRenderConfig(for: stored.cameraSubstitution)
        }
        // A profile that does not use the device must still hide it whenever it may be there, or a
        // page sees a stray "Lumen Camera" among its devices; one that uses it is told only whether
        // the device is listed now — else it gets no camera at once (`SystemCamera.activeForLaunch`).
        let systemCameraActive = SystemCamera.shared.activeForLaunch(usesSystemCamera: usesSystemCamera)
        let child = try ProfileProcess.start(
            profileID: id,
            executable: executable,
            vaultRoot: repository.root,
            grant: repository.grant(for: id),
            home: safariHomeVault.homeDirectory(for: id),
            languages: languages,
            locale: languages.first.map { $0.replacingOccurrences(of: "-", with: "_") },
            timeZone: stored.timeZoneIdentifier ?? location?.timeZoneIdentifier,
            forWarmUpOnly: forWarmUpOnly,
            proxyLocationFound: proxyLocationFound,
            preferences: BrowsingPreferences.current.forProfileProcess,
            menusInAppLanguage: stored.menusInAppLanguage,
            cameraAllowed: cameraAllowed(),
            systemCameraActive: systemCameraActive,
            routes: LocalRelays.routes(for: stored.proxy, owner: id))
        // The process object is held by `children` and, until its exit has been handled, by its own
        // termination handler — never by what it calls: each of these held it, and it and its
        // pipes were never freed (`ProfileProcess.didExit`).
        child.onEvent = { [weak self, weak child] event in
            guard let self, let child else { return }
            switch event {
            case .error(let message):
                self.onError?(message)
            case .running(let hostsSafariChrome):
                // A process stopped meanwhile says it too, as its launch returns into its quit.
                guard self.children[id] === child else { break }
                self.windowsUp.insert(id)
                self.resumeWindowWaiters(of: id, up: true)
                self.onProfileRunning?(id, hostsSafariChrome)
                self.objectWillChange.send()
            case .interfaceLanguage(let code, let bundles, let chrome):
                self.log.info("Profile \(id.uuidString, privacy: .public)'s process: interface \(code, privacy: .private), its bundles \(bundles, privacy: .private), Safari's chrome \(chrome ?? "not hosted", privacy: .private)")
                self.onInterfaceLanguage?(id, code, bundles, chrome)
            case .warmUp(let status):
                self.reportedWarmUp[id] = status
                self.onWarmUpProgress?(id)
                self.objectWillChange.send()
            case .recorded(let event):
                self.onRecorded?(id, event)
            case .recordingStopped(let request):
                self.recordingStops.removeValue(forKey: request)?.resume()
            case .webDriverAnswer(let answer):
                self.pendingWebDriver.removeValue(forKey: answer.id)?.continuation.resume(returning: answer)
            case .scenarioLine(let runID, let line):
                self.scenarioLine(id, runID, line)
            case .scenarioEnded(let runID, let outcome):
                self.scenarioEnded(id, runID, outcome)
            case .cookiesImported(let outcome, let request):
                if let outcome {
                    self.endCookieImport(request, of: id, with: .success(outcome))
                } else {
                    self.endCookieImport(request, of: id, with: .failure(CookieImportError.busy))
                }
            case .cookiesExported(let cookies, let request):
                if let cookies {
                    self.endCookieExport(request, of: id, with: .success(cookies))
                } else {
                    self.endCookieExport(request, of: id, with: .failure(CookieImportError.busy))
                }
            case .networkReport(let report):
                for waiting in self.pendingNetworkReports.removeValue(forKey: id) ?? [] { waiting.resume(returning: report) }
                self.onNetworkReport?(id, report)
            case .keychainReport(let report):
                self.onKeychainReport?(id, report)
            case .configurationSaved:
                try? self.repository.bumpRevision(id)
                self.onConfigurationChanged?(id)
            case .showSettings:
                self.onShowSettings?()
            case .sealing:
                // Quitting on its own (⌘Q, its last window closed): encrypting until it exits. A
                // stop asked for from here has taken the child out of `children` and keeps the
                // profile busy itself, until after the exit.
                guard self.children[id] === child else { break }
                self.runningProfileIDs.remove(id)
                self.busyProfileIDs.insert(id)
                self.objectWillChange.send()
            case .proxyLocationUnknown:
                self.noteProxyLocationUnknown(id, name: summary.name, last: stored.rememberedProxyLocation)
            case .proxyLocationFound:
                self.proxyLocationUnknown.remove(id)
            case .cookiesRecovered(let report):
                self.log.notice("Profile \(id.uuidString, privacy: .public)'s process put back \(report.restored) cookies its store had lost (\(report.cause.rawValue, privacy: .public)); notice shown: \(report.noticeShown, privacy: .public)")
                self.onCookiesRecovered?(id, report)
            case .sealed(let report):
                self.log.notice("Profile \(id.uuidString, privacy: .public) sealed its data in \(Int(report.seconds), privacy: .public) s, attempts \(report.attempts, privacy: .public), forced \(report.forced, privacy: .public), pages closed \(report.pagesClosed, privacy: .public), archived \(Int(report.archivePasses ?? -1), privacy: .public) time(s), unchanged at \(Int(report.archivePassesSkipped ?? -1), privacy: .public) more attempt(s)")
                self.onChildSealed?(id, report)
            case .menuWalk(let line):
                self.onMenuWalk?(id, line)
            case .sweep(let line):
                self.onSweep?(id, line)
            case .historyLook(let look):
                self.onHistoryLook?(id, look)
            case .windowLook(let look):
                self.onWindowLook?(id, look)
            }
        }
        child.onExit = { [weak self, weak child] status in
            guard let self, let child else { return }
            guard self.children[id] === child else {
                // The manager no longer holds this process for the profile: nothing below runs for
                // it (its home is sealed by whatever took it out, or at the next launch). Said, so
                // that such an exit is not silent.
                self.log.notice("Profile \(id.uuidString, privacy: .public)'s process \(child.processIdentifier, privacy: .public) ended with status \(status, privacy: .public) after the manager had let it go")
                return
            }
            self.endCookieRequests(of: id)
            self.children[id] = nil
            self.endWebDriver(of: id)
            self.releaseWebRTC(of: id, pid: child.processIdentifier)
            // Its relay, once nothing of the process is left to use it.
            LocalRelays.stop(owner: id)
            self.windowsUp.remove(id)
            self.resumeWindowWaiters(of: id, up: false)
            self.runningProfileIDs.remove(id)
            // Sealing on its own (`.sealing`) ends with the process.
            self.busyProfileIDs.remove(id)
            // A warm-up cannot outlive the process it ran in; what it collected is still shown.
            if self.reportedWarmUp[id]?.isRunning == true { self.reportedWarmUp[id]?.phase = .stopped }
            // Nor a scenario's run.
            if let run = self.scenarioRuns[id], run.isRunning { self.scenarioEnded(id, run.runID, .stopped(.profileStopped)) }
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
            self.onChildExited?(id, status)
        }
        children[id] = child
        windowsUp.remove(id)
        runningProfileIDs.insert(id)
        // The profile's own process cannot reach the app group: the app draws its camera's frames
        // and writes them into the device's sink (`SystemCameraFeed`).
        if usesSystemCamera { SystemCameraFeed.shared.use(for: id) }
        try? repository.markLaunched(id)
        // The app's settings for browsing, before anything else is asked of it.
        child.send(.preferences(BrowsingPreferences.current.forProfileProcess))
        // A profile with a proxy waits for this before it builds anything (`WebRTCGate.managerDecides`).
        if let proxy = stored.proxy, WebRTCGate.managerDecides(proxy: proxy) {
            let userAgent = stored.userAgent(hostSafariVersion: HostSafari.version)
            Task { await self.decideWebRTC(for: id, name: summary.name, child: child, proxy: proxy, policy: stored.webRTCLaunchPolicy,
                                           automatic: stored.webRTCAutomatic, userAgent: userAgent) }
        }
    }

    // MARK: WebRTC through the profile's proxy

    /// Decides a launch's WebRTC for a profile in its own process (`WebRTCGate`), and says the
    /// decision to the process. The relay only when the network guard holds that process to its
    /// proxy and the proxy relays UDP from the address its TCP leaves from. Anything else is WebRTC
    /// that must not connect: kept in the pages, connecting nowhere, once the guard holds the process
    /// to its proxy (`WebRTCGate.silence`), and otherwise off in the engine — said once, where there
    /// is something to say (`WebRTCGate.tells`).
    private func decideWebRTC(for id: UUID, name: String, child: ProfileProcess, proxy storedProxy: ProxySettings, policy: WebRTCPolicy,
                              automatic: Bool = false, userAgent: String) async {
        // Once asking macOS is over (the app just started, the guard was just installed).
        let guardState = await NetworkGuard.shared.settledState()
        // What the process is held to and the relay sends through: the relay of a share link or an
        // OpenVPN connection, as the SOCKS5 proxy it is to this Mac (`LocalRelays`); any other proxy
        // as it is. A relay that does not run leaves nothing to hold to: WebRTC is off.
        guard let reach = LocalRelays.reach(of: storedProxy, owner: id) else {
            child.send(.webRTC(WebRTCLaunchMessage(relay: nil, refusal: .notRegistered)))
            return
        }
        let proxy = reach
        // The proxy is asked about UDP only when nothing else rules the relay out.
        var udp = ProxyUDPSupport.unknown
        var exit: IPAddr?
        if guardState == .ready, WebRTCGate.wantsRelay(policy: policy, proxy: proxy) {
            (udp, exit) = await Self.proxyUDP(proxy, userAgent: userAgent)
        }
        var decision = WebRTCGate.decide(policy: policy, proxy: proxy, ownProcess: true, guardState: guardState, udp: udp)
        var relay: WebRTCRelay?
        if decision == .relay {
            let pid = child.processIdentifier
            // Held first: no relay exists for a process the guard does not hold.
            var held = false
            if children[id] === child { held = await NetworkGuard.shared.hold(pid: pid, proxy: proxy) }
            if held, children[id] === child, let exit {
                do {
                    // Its allocations only from this process's sockets; where the kernel's table
                    // cannot be read, only the self-test's stand-in for the guard lets them in.
                    relay = try WebRTCRelays.shared.start(profile: id, proxy: proxy, exit: exit, clientPID: pid,
                                                          admitsUnread: NetworkGuard.shared.selfTestStandIn)
                } catch {
                    log.error("The WebRTC relay of \(id.uuidString, privacy: .public) did not start: \(error.logKind, privacy: .public)")
                }
            }
            if relay == nil {
                if held { NetworkGuard.shared.release(pid: pid) }
                decision = .off(.notRegistered)
            }
        }
        // WebRTC that must not connect stays in the pages, connecting nowhere, only while the guard
        // holds the process to its proxy: a page that got past the script could then reach nothing
        // but the proxy. The hold is taken first, and a hold refused leaves WebRTC off in the engine.
        var silent = false
        if case .off = decision, children[id] === child,
           WebRTCGate.silence(proxy: proxy, ownProcess: true, guardState: NetworkGuard.shared.state) == .afterHold {
            // Its TCP port only: a process whose WebRTC connects nowhere needs nothing else of the proxy.
            silent = await NetworkGuard.shared.hold(pid: child.processIdentifier, proxy: proxy, relaysUDP: false)
            if !silent { log.notice("WebRTC of \(id.uuidString, privacy: .public) is off: the guard did not take its process") }
        }
        // Stopped meanwhile: nothing to say, and nothing this decision made is kept (a relaunch's
        // own relay, made since, is not this one's to stop).
        guard children[id] === child else {
            if let relay {
                WebRTCRelays.shared.stop(profile: id, onlyIf: relay)
                NetworkGuard.shared.release(pid: child.processIdentifier)
            } else if silent {
                NetworkGuard.shared.release(pid: child.processIdentifier)
            }
            return
        }
        switch decision {
        case .relay:
            guard let relay else { return }
            webRTCRefusals[id] = nil
            log.notice("WebRTC of \(id.uuidString, privacy: .public) goes through its proxy")
            child.send(.webRTC(WebRTCLaunchMessage(relay: .init(urls: relay.urls, username: relay.username, credential: relay.credential),
                                                   refusal: nil)))
        case .off(let reason):
            if let reason {
                webRTCRefusals[id] = reason
                if silent {
                    log.notice("WebRTC of \(id.uuidString, privacy: .public) cannot connect, present and connecting nowhere: \(reason.rawValue, privacy: .public)")
                } else {
                    log.notice("WebRTC of \(id.uuidString, privacy: .public) is off: \(reason.rawValue, privacy: .public)")
                }
                if WebRTCGate.tells(reason, automatic: automatic) { noteWebRTCOff(id, name: name, reason: reason) }
            }
            if silent { webRTCSilenced.insert(id) } else { webRTCSilenced.remove(id) }
            child.send(.webRTC(WebRTCLaunchMessage(relay: nil, refusal: reason, silent: silent)))
        case .native:
            // Not for a proxied profile; said as off, so that the process does not wait.
            child.send(.webRTC(WebRTCLaunchMessage(relay: nil, refusal: nil)))
        }
    }

    /// Whether `proxy` relays UDP, asked the way the relay will use it (`ProxyUDPCheck`), and from
    /// where: its UDP must leave from the address its TCP leaves from (`ProxyExitLookup`, asked at the
    /// same time), the one sites see the pages come from. That address comes back with `.supported`
    /// alone, for the relay to hold every allocation to it (`TunnelRoute.exit`). Internal for the
    /// self-test.
    static func proxyUDP(_ proxy: ProxySettings, userAgent: String) async -> (support: ProxyUDPSupport, exit: IPAddr?) {
        guard proxy.kind == .socks5, let port = UInt16(exactly: proxy.port) else { return (.unsupported, nil) }
        async let outcome = ProxyUDPCheck.run(proxy: SOCKSProxy(host: proxy.host, port: port,
                                                                username: proxy.username, password: proxy.password))
        async let tcpExit = ProxyExitLookup.lookUp(proxy: proxy, userAgent: userAgent)
        guard case let .supported(egress) = await outcome else { return (.unsupported, nil) }
        guard let exit = await tcpExit else {
            webRTCLog.notice("WebRTC: where the proxy's TCP leaves from could not be found out, so its UDP cannot be compared with it")
            return (.exitUnknown, nil)
        }
        guard egress.ip == exit else {
            webRTCLog.notice("WebRTC: the proxy's UDP leaves from another address than its TCP (\(egress.ip.description, privacy: .private) against \(exit.description, privacy: .private))")
            return (.elsewhere, nil)
        }
        return (.supported, exit)
    }

    // MARK: The relay of a link or an OpenVPN connection

    /// Starts the relay `id`'s proxy needs for this launch (`LocalRelays`): a share link's or an
    /// OpenVPN connection's, refused with why when it does not start. Should it go for good while the
    /// profile runs, the profile stops and the person is told (`relayLost`): its pages fail
    /// meanwhile, never going another way.
    private func startRelay(for id: UUID, proxy: ProxySettings, name: String) async throws {
        // OpenVPN is for a profile in its own process, held there by the kernel (docs/OPENVPN.md).
        if proxy.localRelay == .openVPN, !ProfileProcess.isEnabled {
            throw LaunchError.openVPN(name: name, reason: OpenVPNTunnels.Failure.needsOwnProcess.text)
        }
        do {
            try await LocalRelays.start(for: proxy, owner: id, name: name) { [weak self] message in
                self?.relayLost(id, message: message)
            }
        } catch let failure as LocalRelays.Failure {
            throw failure.launchError(name: name)
        }
    }

    /// `id`'s relay went and did not come back: the profile stops, and says why. Its pages failed
    /// meanwhile; none went another way.
    private func relayLost(_ id: UUID, message: String) {
        guard !runsInProfileProcess, isRunning(id) || busyProfileIDs.contains(id) else { return }
        log.error("The relay of \(id.uuidString, privacy: .public) is gone and did not come back: the profile stops")
        onError?(message)
        let grace = Self.relayDeathGrace
        Task {
            if grace > 0 { try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000)) }
            try? await self.stop(id)
        }
    }

    /// How long a profile whose relay died runs on before it is stopped: none. The check of links
    /// (`XrayCheck`) leaves it a few seconds, to see its pages fail meanwhile, never going around.
    static var relayDeathGrace: TimeInterval = 0

    /// The relay and the guard's hold of a profile whose process ended or was stopped.
    private func releaseWebRTC(of id: UUID, pid: pid_t) {
        WebRTCRelays.shared.stop(profile: id)
        NetworkGuard.shared.release(pid: pid)
        webRTCRefusals[id] = nil
        webRTCSilenced.remove(id)
    }

    /// Why WebRTC is off for this run, said once per run of the profile.
    private func noteWebRTCOff(_ id: UUID, name: String, reason: WebRTCRefusal) {
        guard !webRTCOffNoted.contains(id) else { return }
        webRTCOffNoted.insert(id)
        onError?(Self.webRTCOffText(reason))
    }

    /// The words for each reason, with what the person can do about it.
    static func webRTCOffText(_ reason: WebRTCRefusal) -> String {
        switch reason {
        case .guardNotInBuild: return L("launch.webrtcOff.guardNotInBuild")
        case .guardNotInstalled: return L("launch.webrtcOff.guardNotInstalled")
        case .guardAwaitingApproval: return L("launch.webrtcOff.guardAwaitingApproval")
        case .guardOff: return L("launch.webrtcOff.guardOff")
        case .guardNotAnswering: return L("launch.webrtcOff.guardNotAnswering")
        case .guardRestartNeeded: return L("guard.problem.reboot")
        case .guardUnproven: return L("launch.webrtcOff.guardUnproven")
        case .httpProxy: return L("launch.webrtcOff.httpProxy")
        case .proxyWithoutUDP: return L("launch.webrtcOff.proxyWithoutUDP")
        case .proxyUDPElsewhere: return L("launch.webrtcOff.proxyUDPElsewhere")
        case .proxyExitUnknown: return L("launch.webrtcOff.proxyExitUnknown")
        case .proxyUDPUnknown: return L("launch.webrtcOff.proxyUDPUnknown")
        case .notOwnProcess: return L("launch.webrtcOff.notOwnProcess")
        case .notRegistered: return L("launch.webrtcOff.notRegistered")
        }
    }

    // In a profile's own process: what the manager decided (`ProfileCommand.webRTC`), and the
    // launch waiting for it.
    private static var webRTCMessage: WebRTCLaunchMessage?
    private static var webRTCWaiters: [CheckedContinuation<WebRTCLaunchMessage?, Never>] = []

    /// The manager's decision arrived (`ProfileSessionHost`).
    static func receiveWebRTC(_ message: WebRTCLaunchMessage) {
        webRTCMessage = message
        let waiters = webRTCWaiters
        webRTCWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: message) }
    }

    /// This process is quitting (`shutDown`): a launch waits for the manager's word no longer.
    private static var webRTCWaitEnded = false

    /// Lock or quit in a profile's own process: a launch waiting for the manager's word on WebRTC
    /// goes on without it, to find the quit. The manager sends no word to a process it has stopped,
    /// and the wait (up to 40 s) held the quit past the 30 s the manager gives a stopping process
    /// before it kills it (audit 3, #22).
    private static func endWebRTCWait() {
        webRTCWaitEnded = true
        let waiters = webRTCWaiters
        webRTCWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: webRTCMessage) }
    }

    /// The manager's decision, waited for at most `seconds`; nil when none came (WebRTC then off).
    private static func webRTCDecision(within seconds: Double) async -> WebRTCLaunchMessage? {
        if let webRTCMessage { return webRTCMessage }
        if webRTCWaitEnded { return nil }
        return await withCheckedContinuation { continuation in
            webRTCWaiters.append(continuation)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let waiters = webRTCWaiters
                webRTCWaiters.removeAll()
                for waiter in waiters { waiter.resume(returning: webRTCMessage) }
            }
        }
    }

    /// The app's settings for browsing changed: every profile in a process of its own gets them
    /// (a profile in this process reads `BrowsingPreferences.current` itself).
    func sendPreferences(_ preferences: BrowsingPreferences) {
        for child in children.values { child.send(.preferences(preferences.forProfileProcess)) }
    }

    /// Probes the proxy of a profile that is starting (`ProxyProbe`), and says what is wrong with it
    /// when it does not work (`onProxyProblem`) — unless the profile was stopped meanwhile. The
    /// tunnel it asks for goes to the profile's own start page, which the profile is about to ask
    /// the same proxy for (no start page: the first geolocation service), and only one: no latency
    /// is measured here. The probe talks to the proxy alone. Without a start page, a proxy that
    /// works and only cannot reach that service is not reported: the pages the user opens may well
    /// load through it.
    private func diagnoseProxy(of id: UUID, _ proxy: ProxySettings, startURL: URL?) {
        guard onProxyProblem != nil, (try? proxy.validate()) != nil else { return }
        let (probe, reportsNoUpstream) = launchProbe(startURL: startURL)
        Task { @MainActor [weak self] in
            let diagnosis = await probe.run(proxy)
            guard let self, !diagnosis.isWorking, diagnosis.verdict != .noUpstream || reportsNoUpstream,
                  self.isRunning(id) || self.busyProfileIDs.contains(id) else { return }
            self.log.notice("The proxy of \(id.uuidString, privacy: .public) does not work: \(diagnosis.verdict.rawValue, privacy: .public)")
            self.onProxyProblem?(id, proxy, diagnosis)
        }
    }

    // MARK: Open tabs (Settings → Startup → restore tabs)

    /// A profile that keeps them — not an ephemeral one, nor one that keeps no history: what it
    /// left open is as much a record of where it went as its history.
    private func keepsOpenTabs(_ configuration: ProfileConfiguration) -> Bool {
        BrowsingPreferences.current.restoreTabs && !configuration.ephemeral && configuration.historyEnabled
    }

    /// The tabs a start opens again, when the settings ask and the profile keeps them.
    private func restorableTabs(of id: UUID, _ configuration: ProfileConfiguration) -> OpenTabs? {
        guard keepsOpenTabs(configuration) else { return nil }
        do {
            return try repository.openTabs(for: id)
        } catch {
            log.error("The open tabs of \(id.uuidString, privacy: .public) could not be read: \(error.logKind, privacy: .public)")
            return nil
        }
    }

    /// What a stopping profile leaves open is kept for its next start; with the setting off, or a
    /// profile that keeps none, what was kept is forgotten. A run without a window of the user's (a
    /// warm-up) leaves what was kept as it was.
    ///
    /// `emptyForgets`: in Safari's window, where the person's windows are read as they stand
    /// (`SafariTabs`), windows that held no page at the end — start pages alone — leave nothing
    /// open: the tabs of the run before, closed since, are forgotten rather than opened again.
    private func rememberOpenTabs(of id: UUID, _ tabs: OpenTabs?, configuration: ProfileConfiguration,
                                  emptyForgets: Bool = false) {
        do {
            if !keepsOpenTabs(configuration) {
                try repository.removeOpenTabs(for: id)
            } else if let tabs, !tabs.windows.isEmpty {
                try repository.saveOpenTabs(tabs, for: id)
            } else if tabs != nil, emptyForgets {
                try repository.removeOpenTabs(for: id)
            }
        } catch {
            log.error("The open tabs of \(id.uuidString, privacy: .public) could not be kept: \(error.logKind, privacy: .public)")
        }
    }

    /// The probe a launch runs: one tunnel, to the start page's site (without one, the first
    /// geolocation service — and then a proxy that cannot reach only that is not reported).
    private func launchProbe(startURL: URL?) -> (ProxyProbe, reportsNoUpstream: Bool) {
        var configured = ProxyChecker.probe(latencySamples: 1)
        if let url = startURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty {
            configured.targetHost = host
            configured.targetPort = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
            return (configured, true)
        }
        return (configured, false)
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

    /// In a profile's own process: the manager found where the proxy exits for this very launch,
    /// moments before it started the process, and stored it in the profile's settings — which is
    /// what this launch runs by. Asking the services again would be a second request for one
    /// launch, and one that fails here would say the location is unknown when it was just found.
    private var locationFoundByManager: Bool {
        runsInProfileProcess && ProcessInfo.processInfo.environment[ProfileProcess.proxyLocationFoundVariable] == "1"
    }

    private func lookUpProxyLocation(_ configuration: ProfileConfiguration) async -> ProxyGeoLookup.Result {
        guard configuration.needsProxyLookup else { return ProxyGeoLookup.Result() }
        let result = await ProxyGeoLookup.lookUp(proxy: configuration.proxy,
                                                 userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version))
        if result.location == nil {
            log.notice("Could not look up where the profile's proxy exits; using \(configuration.lastProxyLocation == nil ? "the system time zone" : "the last known location", privacy: .public)")
        }
        return result
    }

    /// Says that no geolocation service answered through the profile's proxy, and in which time
    /// zone and language the profile runs instead; marks the profile for its row and editor.
    func noteProxyLocationUnknown(_ id: UUID, name: String, last: ProxyLocation?) {
        guard !proxyLocationUnknown.contains(id) else { return }
        proxyLocationUnknown.insert(id)
        // A profile with no proxy is told apart: it has no proxy to blame (the lead, 7 November).
        let direct = (try? repository.loadConfiguration(id))?.proxy == nil
        log.notice("No geolocation service answered for \(id.uuidString, privacy: .public)\(direct ? " (direct)" : " (through its proxy)")")
        if let last {
            onError?(String(format: L(direct ? "launch.directLocationUnknown.last" : "launch.proxyLocationUnknown.last"), name,
                            last.countryCode.map(CountryNames.name(for:)) ?? last.timeZoneIdentifier))
        } else {
            onError?(String(format: L(direct ? "launch.directLocationUnknown.mac" : "launch.proxyLocationUnknown.mac"), name))
        }
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
        guard let found = result.location else {
            // No service answered through the proxy: not only a line in the log. None asked (none
            // configured: CI's PB_GEO_SERVICES_OFF) is not that, and says nothing.
            if stored.needsProxyLocation, !ProxyGeoLookup.services.isEmpty {
                if runsInProfileProcess {
                    onProxyLocationUnknown?(id)
                } else {
                    noteProxyLocationUnknown(id, name: name, last: stored.rememberedProxyLocation)
                }
            }
            return
        }
        // Not when, since the launch, the warning was turned off or the proxy removed or replaced
        // (a late answer): it is about a proxy the profile no longer asks about.
        let current = try? repository.loadConfiguration(id)
        let stillAsked = current.map { $0.warnOnProxyIPChange && $0.proxy.map(ProxyLocation.endpoint(of:)) == found.proxyEndpoint } ?? (stored.proxy != nil)
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
        if running, let found = result.location { sessions[id]?.exitLocation = found; proxyLocationUnknown.remove(id) }
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
        // A lookup that answered ends an earlier one's "unknown" for this profile — here, and in
        // the app when this is a profile's own process (the owner, 21 November: the language and
        // time zone of the exit were applied, and «не удалось определить, где выходит прокси»
        // stayed in the app until the profile stopped).
        proxyLocationUnknown.remove(id)
        if runsInProfileProcess { onProxyLocationFound?(id) }
        do {
            var current = try repository.loadConfiguration(id)
            var found = found
            // A direct connection's address is kept as its country is (it is shown); a proxy's only
            // while the warning that asks for it is on.
            if current.proxy != nil, !current.warnOnProxyIPChange { found.exitIP = nil }
            guard ProxyLocation.exitEndpoint(of: current.proxy) == found.proxyEndpoint,
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

    // MARK: WebDriver

    /// A WebDriver command done to profile `id`'s page (docs/AUTOMATION.md, "WebDriver"): in the
    /// profile's own process when it has one, else here. The first command of a session ("open")
    /// opens the page it acts in — a window of Safari's where the profile's process hosts Safari's
    /// chrome, as a scenario's run; "close" closes it.
    func webDriver(_ id: UUID, _ call: WebDriverCall) async -> WebDriverAnswer {
        func refused(_ error: WebDriverError) -> WebDriverAnswer { WebDriverAnswer(id: call.id, value: nil, error: error) }
        guard scenariosAllowed() else { return refused(.unsupported("the plan has no automation")) }
        guard !isShuttingDown else { return refused(.noSuchWindow("the profile is stopping")) }
        if let child = children[id] {
            return await withCheckedContinuation { continuation in
                pendingWebDriver[call.id] = (id, continuation)
                child.send(.webDriver(call))
                // A page load can take its whole timeout; past that the process is not answering.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 330_000_000_000)
                    self?.pendingWebDriver.removeValue(forKey: call.id)?.continuation
                        .resume(returning: refused(.timeout("the profile's process did not answer")))
                }
            }
        }
        guard let session = sessions[id] else { return refused(.noSuchWindow("the profile is not running")) }
        if call.command == "close" {
            webDriverExecutors.removeValue(forKey: id)?.close()
            return WebDriverAnswer(id: call.id, value: "null", error: nil)
        }
        do {
            let executor = try await webDriverExecutor(for: id, session)
            let value = try await executor.perform(call)
            // Cookies set or deleted through WebDriver are Lumen's own change: on disk and copied at once,
            // so that a crash right after neither loses them nor brings back the ones deleted.
            if Self.webDriverCookieCommands.contains(call.command), let store = session.dataStore?.httpCookieStore {
                await CookieStoreImport.flush(store)
                await cookieSnapshots.snapshot(id, store: store, trigger: .change)
            }
            return WebDriverAnswer(id: call.id, value: value, error: nil)
        } catch let error as WebDriverError {
            return refused(error)
        } catch {
            return refused(.unknown(String(describing: error)))
        }
    }

    /// The WebDriver commands that change the profile's cookies.
    static let webDriverCookieCommands: Set<String> = ["addCookie", "deleteCookie", "deleteCookies"]

    /// The profile's process is gone, or its session here: calls still waiting for it get their
    /// answer now — the window is closed — and the page it had is forgotten.
    private func endWebDriver(of id: UUID) {
        webDriverExecutors[id] = nil
        for (call, waiting) in pendingWebDriver where waiting.profile == id {
            pendingWebDriver[call] = nil
            waiting.continuation.resume(returning: WebDriverAnswer(id: call, value: nil, error: .noSuchWindow("the profile stopped")))
        }
    }

    /// The page a WebDriver session of profile `id` acts in: the one it has, while its window is
    /// there; else a new one of its own, where a scenario's run would get one — never a run's
    /// window, nor one a run takes after (`openScenarioPage(forWebDriver:)`). Closing it as the
    /// session ends is not the profile's last window closing: a profile the session found running
    /// stays, and one it started is stopped by the session's end (`WebDriverService.end`).
    private func webDriverExecutor(for id: UUID, _ session: BrowserSession) async throws -> WebDriverExecutor {
        if let executor = webDriverExecutors[id], executor.driver.webView.window != nil { return executor }
        webDriverExecutors.removeValue(forKey: id)?.close()
        if SafariChromeHost.isHosting,
           let page = await SafariChromeHost.openScenarioPage(session: session, forWebDriver: true) {
            let window = page.webView.window
            let executor = WebDriverExecutor(driver: PageDriver(webView: page.webView, navigate: page.navigate), windowKind: "Safari's") {
                [weak window] in
                if let window { SafariChromeHost.closeKeepingProfile(window) }
            }
            webDriverExecutors[id] = executor
            return executor
        }
        let controller = session.openWindow(url: nil)
        guard let tab = controller.selectedTab else { throw WebDriverError.sessionNotCreated("the profile gave no window to act in") }
        let executor = WebDriverExecutor(driver: PageDriver(webView: tab.webView) { [weak tab] url in _ = tab?.load(url) },
                                         windowKind: "the app's own") { [weak controller] in
            // Not one of the profile's own windows as it closes, as the warm-up's is not: its
            // closing is not the profile's last window closing (`BrowserSession.windowDidClose`).
            controller?.isForWarmUp = true
            controller?.close()
        }
        webDriverExecutors[id] = executor
        return executor
    }

    /// Begins recording a scenario from what the person does in profile `id`'s windows; what is
    /// seen comes through `onRecorded`. False when the plan has no automation or the profile is
    /// not running.
    @discardableResult
    func startRecording(_ id: UUID) -> Bool {
        guard scenariosAllowed() else { return false }
        if let child = children[id] {
            child.send(.startRecording)
            return true
        }
        guard let session = sessions[id] else { return false }
        session.startRecording { [weak self] event in self?.onRecorded?(id, event) }
        return true
    }

    func stopRecording(_ id: UUID) async {
        guard let child = children[id] else {
            await sessions[id]?.stopRecording()
            return
        }
        let request = UUID()
        await withCheckedContinuation { continuation in
            recordingStops[request] = continuation
            child.send(.stopRecording(request: request))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.recordingStops.removeValue(forKey: request)?.resume()
            }
        }
    }

    /// What a profile's own process says about where its traffic goes, awaited (the profile's
    /// check). Nil for a profile that does not run in a process of its own, and for one that
    /// does not answer in `timeout` seconds.
    func networkReport(of id: UUID, timeout: TimeInterval = 10) async -> ProfileNetworkReport? {
        guard children[id] != nil else { return nil }
        return await withCheckedContinuation { continuation in
            pendingNetworkReports[id, default: []].append(continuation)
            guard checkNetwork(id) else {
                for waiting in pendingNetworkReports.removeValue(forKey: id) ?? [] { waiting.resume(returning: nil) }
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                for waiting in self?.pendingNetworkReports.removeValue(forKey: id) ?? [] { waiting.resume(returning: nil) }
            }
        }
    }

    /// Asks a profile running in its own process to look at the data-protection keychain from
    /// inside (`ProfileCommand.checkKeychain`); the answer comes back through `onKeychainReport`.
    /// False when the profile does not run in a process of its own.
    @discardableResult
    func checkKeychain(_ id: UUID, _ probe: KeychainProbe) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.checkKeychain(probe))
        return true
    }

    /// Asks a profile running in its own process to close its windows as their close buttons do
    /// (`ProfileCommand.closeWindows`, the self-test's). False when it has no process of its own.
    @discardableResult
    func closeWindows(_ id: UUID) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.closeWindows)
        return true
    }

    /// Asks a profile running in its own process to walk Safari's menu bar from item `from` on;
    /// each step comes back through `onMenuWalk`. False when it does not run in a process of its own.
    @discardableResult
    func walkMenu(_ id: UUID, from: Int) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.walkMenu(from: from))
        return true
    }

    /// Asks a profile running in its own process to drive its window with real input from step
    /// `from`, unit `sub` on (`SafariSweep`); each line comes back through `onSweep`. The `--sweep`
    /// check's only. False when it does not run in a process of its own.
    @discardableResult
    func sweep(_ id: UUID, from: Int, sub: Int, phases: [String]) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.sweep(from: from, sub: sub, phases: phases))
        return true
    }

    /// Asks a profile running in its own process to open its History window as the person does and
    /// say what it shows; the answer comes back through `onHistoryLook`. The self-test's only.
    /// Asks a profile running in its own process to act on its window as a person would
    /// (`WindowProbe`); the answer comes back through `onWindowLook`. The self-test's only.
    @discardableResult
    func lookAtWindow(_ id: UUID, _ action: WindowProbeAction) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.lookAtWindow(action))
        return true
    }

    @discardableResult
    func lookAtHistory(_ id: UUID) -> Bool {
        guard let child = children[id] else { return false }
        child.send(.lookAtHistory)
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

    /// The relay a launch's pages are given for WebRTC through the profile's proxy, and whether WebRTC
    /// that must not connect stays in its pages, connecting nowhere (`WebRTCGate.silence`). Without a
    /// proxy there is no relay, and a WebRTC that is off stays in the pages: it would go out as this
    /// Mac, as the pages do. In a profile's own process the manager decided (`decideWebRTC`) and holds
    /// the relay or the guard's hold; this process waits for its word, and without one runs with
    /// WebRTC off in the engine. A proxied profile launched here, in the manager, never gets either:
    /// the network guard tells profiles apart by their processes (`WebRTCRefusal.notOwnProcess`).
    private func webRTCLaunch(for id: UUID, _ configuration: ProfileConfiguration) async -> (relay: WebRTCRelay?, silent: Bool) {
        let policy = configuration.webRTCLaunchPolicy
        // Without a proxy a WebRTC that is off is present, connecting nowhere, by itself (`webRTCRouting`).
        guard let proxy = configuration.proxy else { return (nil, false) }
        if runsInProfileProcess, WebRTCGate.managerDecides(proxy: proxy) {
            // The manager answers within the time its proxy check takes (`ProxyUDPCheck`).
            guard let message = await Self.webRTCDecision(within: 40) else {
                if !isShuttingDown { log.error("No word from the manager on this launch's WebRTC: it stays off") }
                return (nil, false)
            }
            let relay = message.relay.map { WebRTCRelay(urls: $0.urls, username: $0.username, credential: $0.credential) }
            return (relay, relay == nil && message.silent == true)
        }
        guard policy != .disabled else { return (nil, false) }
        guard WebRTCGate.wantsRelay(policy: policy, proxy: proxy) else {
            if WebRTCGate.tells(.httpProxy, automatic: configuration.webRTCAutomatic) { noteWebRTCOff(id, name: "", reason: .httpProxy) }
            return (nil, false)
        }
        if case let .off(reason?) = WebRTCGate.decide(policy: policy, proxy: proxy, ownProcess: false,
                                                      guardState: NetworkGuard.shared.state, udp: .unknown) {
            webRTCRefusals[id] = reason
            noteWebRTCOff(id, name: "", reason: reason)
        }
        return (nil, false)
    }

    /// Profiles already told, once per run, that their WebRTC is off.
    private var webRTCOffNoted: Set<UUID> = []

    // MARK: Stop

    func stop(_ id: UUID) async throws {
        if let run = scenarioRuns[id], run.isRunning {
            scenarioRunners[id]?.stop(.profileStopped)
            scenarioEnded(id, run.runID, .stopped(.profileStopped))
        }
        if let child = children.removeValue(forKey: id) {
            // Its exit is not heard from here on (`onExit` is taken away below): the WebDriver
            // calls and the cookie imports and exports still waiting for this process get their
            // answer now (the cookies' waited for their timer, and held the profile "busy" for a
            // launch after this stop).
            endWebDriver(of: id)
            endCookieRequests(of: id)
            runningProfileIDs.remove(id)
            releaseWebRTC(of: id, pid: child.processIdentifier)
            windowsUp.remove(id)
            resumeWindowWaiters(of: id, up: false)
            busyProfileIDs.insert(id)
            defer { busyProfileIDs.remove(id) }
            // Its own quit path seals the WebKit data; this returns when that finished, and then
            // Safari's home is sealed here, where nothing is writing in it any more.
            child.onExit = nil
            child.terminate()
            await child.waitUntilExit(timeout: 30)
            // Its relay: only now, with nothing of the process left to send to its port.
            LocalRelays.stop(owner: id)
            if let status = child.terminationStatus { onChildStopped?(id, status) }
            if let key = try? repository.profileKey(for: id) {
                try safariHomeVault.seal(profileID: id, key: key)
            }
            return
        }
        guard let session = sessions.removeValue(forKey: id) else { return }
        endWebDriver(of: id)
        // First of all, before anything waits: the robot must not act in a session going away
        // (a tab it opened now would get no store, proxy or scripts of the profile).
        warmUpRobots[id]?.stop(.profileStopped)
        launchTokens[id] = nil
        let key = keys.removeValue(forKey: id)
        runningProfileIDs.remove(id)
        busyProfileIDs.insert(id)
        defer { busyProfileIDs.remove(id) }

        session.onAllWindowsClosed = nil
        let ephemeral = session.configuration.ephemeral
        // Cookies set in the last moments (by a page, or imported) are written before the data is
        // sealed: CFNetwork would write them later, after the archive was made.
        if !ephemeral, let store = session.dataStore {
            // A stop ends the profile's browsing session, as quitting Safari does: its session
            // cookies go. WebKit's network process, which the profiles of this process share, hands
            // them back at the profile's next launch while it keeps running for another profile
            // (measured: CI run 436, macOS 27, `sessionCookieAfterStop`); with no other profile
            // running they went with it.
            await Self.deleteSessionCookies(in: store.httpCookieStore)
            await CookieStoreImport.flush(store.httpCookieStore)
            // What this run changed, for sync (the settings as they are now: sync may have been
            // turned off while it ran).
            if let key, (try? repository.loadConfiguration(id, key: key))?.syncsCookies == true {
                await recordSyncedCookies(of: id, in: store.httpCookieStore)
            }
            // A clean stop: the last snapshot of its cookies, and its running mark gone
            // (docs/COOKIE_RECOVERY.md). After the cookies are on disk, before the seal.
            await cookieSnapshots.close(id, store: store.httpCookieStore)
        }
        cookieSnapshots.stopWatching(id)
        session.shutDown()
        LocalRelays.stop(owner: id)
        rememberOpenTabs(of: id, session.lastOpenTabs, configuration: session.configuration,
                         emptyForgets: SafariChromeHost.isHosting)
        // `session` is now the last reference; it is released when this scope ends, but its
        // data store reference was already dropped in shutDown().
        if !ephemeral, let key {
            let started = Date()
            let result = try await webDataVault.seal(profileID: id, key: key)
            onSealed?(id, ProfileSealReport(forced: result.forced, attempts: result.attempts,
                                            seconds: Date().timeIntervalSince(started), pagesClosed: pagesClosedForQuit,
                                            archivePasses: result.archivePasses, archivePassesSkipped: result.archivePassesSkipped))
        }
    }

    /// Deletes the store's session cookies (those without an expiry date).
    private static func deleteSessionCookies(in store: WKHTTPCookieStore) async {
        for cookie in await store.allCookies() where cookie.isSessionOnly {
            await store.deleteCookie(cookie)
        }
    }

    /// Quit: the process exits after this shutdown, so a seal whose data store WebKit still holds
    /// after every attempt is forced rather than failed (see
    /// `WebDataStoreVault.forceSealWhenStoreStaysInUse`). Also reaches seals already retrying.
    func prepareForQuit() {
        webDataVault.forceSealWhenStoreStaysInUse = true
        // Safari's chrome: its windows go first, before anything is sealed — the window disappears
        // when the user quits instead of staying up through the seal — and so do the pages of the
        // windows it closed earlier and keeps for reopening, which would keep the store in use.
        // What is left of the retries is for WebKit to let the store go, not for Safari to.
        if SafariChromeHost.isHosting {
            SafariChromeHost.closeEveryWindow()
            pagesClosedForQuit = ProfileNetworkGuard.closeEveryPage()
            webDataVault.retryDelays = [1, 1, 2]
        }
    }

    /// The running session of a profile (self-test hook).
    func session(for id: UUID) -> BrowserSession? { sessions[id] }

    /// What a profile is doing that a quit would stop (an update's confirmation lists them).
    enum Activity: Equatable {
        /// Running with a window, here or in its own process.
        case window(ownProcess: Bool)
        /// Running only for a warm-up, without a window.
        case warmUpOnly
        /// Starting, or being encrypted.
        case busy
    }

    /// Every profile a quit would stop now, and how it runs.
    func activity() -> [(id: UUID, activity: Activity)] {
        var found: [(id: UUID, activity: Activity)] = []
        for (id, session) in sessions {
            let activity: Activity = session.hasVisibleWindow ? .window(ownProcess: false) : .warmUpOnly
            found.append((id: id, activity: activity))
        }
        for (id, child) in children {
            let activity: Activity = child.isForWarmUpOnly ? .warmUpOnly : .window(ownProcess: true)
            found.append((id: id, activity: activity))
        }
        for id in busyProfileIDs where sessions[id] == nil && children[id] == nil {
            found.append((id: id, activity: .busy))
        }
        return found
    }

    /// Lock / Quit: refuse new launches, let launches and seals already under way finish (a
    /// suspended launch seals again instead of opening a window), then stop and seal every
    /// running profile. Returns when nothing is running, launching or sealing.
    func shutDown() async {
        isShuttingDown = true
        if runsInProfileProcess { Self.endWebRTCWait() }
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

    /// The one path that deletes a profile's data — its folder in the vault (settings, history,
    /// saved logins, bookmarks, cookies, the sealed WebKit store and Safari's home) and WebKit's
    /// store of it outside the vault. Profiles are this Mac's (CONTRACT §2, §12): nothing but the
    /// person's own Delete deletes them — not signing out, not another account, not a sync, not
    /// a server's answer. Its one caller is `AppModel.deleteProfile`, which the Delete confirmation
    /// of the Profiles window calls; `scripts/check_deletion_paths.py` fails CI on any other.
    func deleteBecauseThePersonAsked(_ id: UUID) async throws {
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

    // MARK: Scenarios

    /// Runs `source` in the running profile, in a window of its own (docs/AUTOMATION.md). False when
    /// the profile is not running or a run of it is still going. `inBackground`: a scheduled run,
    /// whose window neither takes the keyboard nor activates the app (`SafariChromeHost.openScenarioPage`).
    @discardableResult
    func runScenario(_ id: UUID, name: String, source: String, parametersJSON: String = "{}", runID: UUID = UUID(),
                     inBackground: Bool = false) -> Bool {
        guard !isShuttingDown, scenarioRuns[id]?.isRunning != true else { return false }
        if let child = children[id] {
            scenarioRuns[id] = ScenarioRunState(runID: runID, name: name, startedAt: Date(), lines: [], outcome: nil)
            child.send(.runScenario(ScenarioRunRequest(runID: runID, name: name, source: source, parametersJSON: parametersJSON,
                                                       inBackground: inBackground ? true : nil)))
            objectWillChange.send()
            return true
        }
        guard let session = sessions[id] else { return false }
        // Where the run acts. In a profile's own process that hosts Safari's chrome: a window of
        // Safari's, opened for the run — the profile's real window, as a person has it (the owner,
        // 10 November: a run in a window of ours is not Safari). Everywhere else — the sandboxed
        // build, a macOS where the chrome is not hosted — a window of ours.
        if SafariChromeHost.isHosting {
            scenarioRuns[id] = ScenarioRunState(runID: runID, name: name, startedAt: Date(), lines: [], outcome: nil)
            objectWillChange.send()
            Task { @MainActor [weak self] in
                let page = await SafariChromeHost.openScenarioPage(session: session, inBackground: inBackground)
                // Stopped, or the profile gone, while the window was opening: nothing runs.
                guard let self, let run = self.scenarioRuns[id], run.runID == runID, run.isRunning else { return }
                guard let page else {
                    // Safari's window gave no page to act on: the run is not lost for it — it goes
                    // on in a window of ours, and its log says so.
                    guard let tab = session.openWindow(url: nil).selectedTab else {
                        self.scenarioEnded(id, runID, .failed("no window to run in"))
                        return
                    }
                    self.startScenario(id, runID: runID, driver: PageDriver(webView: tab.webView) { [weak tab] url in _ = tab?.load(url) },
                                       window: "the app's own (Safari's gave no page)", source: source, parametersJSON: parametersJSON)
                    return
                }
                self.startScenario(id, runID: runID, driver: PageDriver(webView: page.webView, navigate: page.navigate),
                                   window: "Safari's", source: source, parametersJSON: parametersJSON)
            }
            return true
        }
        guard let tab = session.openWindow(url: nil).selectedTab else { return false }
        scenarioRuns[id] = ScenarioRunState(runID: runID, name: name, startedAt: Date(), lines: [], outcome: nil)
        startScenario(id, runID: runID, driver: PageDriver(webView: tab.webView) { [weak tab] url in _ = tab?.load(url) },
                      window: "the app's own", source: source, parametersJSON: parametersJSON)
        return true
    }

    /// The run itself, once it has a page to act on. Its log's first line says which window that is.
    private func startScenario(_ id: UUID, runID: UUID, driver: PageDriver, window: String, source: String, parametersJSON: String) {
        let runner = ScenarioRunner(driver: driver)
        runner.allowed = { [weak self] in self?.scenariosAllowed() ?? false }
        scenarioRunners[id] = runner
        runner.onLine = { [weak self] line in self?.scenarioLine(id, runID, line) }
        runner.onEnd = { [weak self] outcome in self?.scenarioEnded(id, runID, outcome) }
        let parameters = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) as? [String: Any] ?? [:]
        scenarioLine(id, runID, ScenarioRunner.Line(at: Date(), kind: .command, text: "window: \(window)"))
        runner.start(source, parameters: parameters)
    }

    /// Stops the profile's run, wherever it runs: a command under way finishes first.
    func stopScenario(_ id: UUID, reason: ScenarioRunner.StopReason = .byUser) {
        guard scenarioRuns[id]?.isRunning == true else { return }
        if let child = children[id] {
            child.send(.stopScenario(reason))
            return
        }
        if let runner = scenarioRunners[id] {
            runner.stop(reason)
        } else if let run = scenarioRuns[id] {
            // Its window (Safari's) is still opening: nothing ran, and nothing will.
            scenarioEnded(id, run.runID, .stopped(reason))
        }
    }

    private func scenarioLine(_ id: UUID, _ runID: UUID, _ line: ScenarioRunner.Line) {
        guard scenarioRuns[id]?.runID == runID else { return }
        // The last lines of a long run are what matter; it keeps 5000.
        if (scenarioRuns[id]?.lines.count ?? 0) >= 5000 { scenarioRuns[id]?.lines.removeFirst() }
        scenarioRuns[id]?.lines.append(line)
        onScenarioLine?(id, runID, line)
        objectWillChange.send()
    }

    private func scenarioEnded(_ id: UUID, _ runID: UUID, _ outcome: ScenarioRunner.Outcome) {
        guard scenarioRuns[id]?.runID == runID, scenarioRuns[id]?.outcome == nil else { return }
        scenarioRuns[id]?.outcome = outcome
        scenarioRunners[id] = nil
        onScenarioEnded?(id, runID, outcome)
        objectWillChange.send()
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
        /// The profile stopped, or its process ended, before it answered.
        case profileStopped
        var errorDescription: String? {
            switch self {
            case .busy: return L("cookies.error.busy")
            case .profileStopped: return L("cookies.error.stopped")
            }
        }
    }

    /// The import `request` sent to profile `profile`'s process ends with `result` — its answer, or
    /// a failure — and its timer is let go. An answer for a request no longer waited for (it timed
    /// out) is dropped.
    private func endCookieImport(_ request: UUID, of profile: UUID, with result: Result<CookieImportOutcome, Error>) {
        guard pendingCookieImports[request]?.profile == profile, let pending = pendingCookieImports.removeValue(forKey: request) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    /// `endCookieImport`, for an export.
    private func endCookieExport(_ request: UUID, of profile: UUID, with result: Result<[ImportedCookie], Error>) {
        guard pendingCookieExports[request]?.profile == profile, let pending = pendingCookieExports.removeValue(forKey: request) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    /// The profile's process stopped or exited: every import and export it was asked for and has
    /// not answered fails now, saying so.
    private func endCookieRequests(of profile: UUID) {
        for (request, pending) in pendingCookieImports where pending.profile == profile {
            endCookieImport(request, of: profile, with: .failure(CookieImportError.profileStopped))
        }
        for (request, pending) in pendingCookieExports where pending.profile == profile {
            endCookieExport(request, of: profile, with: .failure(CookieImportError.profileStopped))
        }
    }

    /// Imports `cookies` into a profile: at once when it runs, else at its next launch, before
    /// its first page loads.
    func importCookies(_ cookies: [ImportedCookie], into id: UUID) async throws -> CookieImportOutcome {
        // A profile in its own process imports into its own store, and says how it went.
        if let child = children[id] {
            // One import into a profile at a time, as before.
            guard !pendingCookieImports.values.contains(where: { $0.profile == id }) else { throw CookieImportError.busy }
            let request = UUID()
            return try await withCheckedThrowingContinuation { continuation in
                // A process that does not answer (it is sealing on its way out) is not waited on.
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.endCookieImport(request, of: id, with: .failure(CookieImportError.busy))
                }
                pendingCookieImports[request] = (id, continuation, timeout)
                child.send(.importCookies(cookies, request: request))
            }
        }
        if let store = sessions[id]?.dataStore {
            let result = await CookieStoreImport.apply(cookies, to: store.httpCookieStore)
            log.notice("Imported \(result.stored) cookies into a running profile, \(result.refused.count) refused")
            // Lumen's own change: copied at once — a crash right after neither loses the imported
            // cookies nor takes those they replaced for ones to put back (docs/COOKIE_RECOVERY.md).
            await cookieSnapshots.snapshot(id, store: store.httpCookieStore, trigger: .change)
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
            try await launch(id, openingWindow: false, forExport: true)
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
            guard !pendingCookieExports.values.contains(where: { $0.profile == id }) else { throw CookieImportError.busy }
            let request = UUID()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.endCookieExport(request, of: id, with: .failure(CookieImportError.busy))
                }
                pendingCookieExports[request] = (id, continuation, timeout)
                // Sent at once: a process that is still starting acts on it once the profile is up.
                child.send(.exportCookies(request: request))
            }
        }
        guard let store = sessions[id]?.dataStore?.httpCookieStore else { throw CookieImportError.busy }
        return await CookieStoreSync.exportableCookies(in: store)
    }

    // MARK: Synced cookies

    /// At launch, before the first page loads. First cookie recovery (docs/COOKIE_RECOVERY.md): a
    /// store that lost the profile's cookies — missing website data, a damaged cookie file, far
    /// fewer than its newest snapshot after a run that did not stop cleanly — gets back from that
    /// snapshot the cookies it lacks, before anything reads it as the person's.
    ///
    /// Then, with cookie sync on: what the store changed since it was last recorded (a run that
    /// ended without a stop) is recorded as changes of that time, the earliest they can be — with
    /// nothing recorded yet (sync just turned on), as old as can be: they fill in what the synced
    /// cookies lack, and any synced change wins over them — unless the store came up with nothing
    /// (`storeRestored` false: no archive, no plaintext), which is not every cookie deleted
    /// (CookieJarDocument.atLaunch); a store that lost cookies records no deletion either, but for
    /// what the newest snapshot says was deleted since the baseline (`atLaunch(afterLoss:)`). Then the
    /// document (with what sync brought from the other devices)
    /// is applied to the store, then the cookies imported while the profile was stopped go in and
    /// are recorded as changes of now. With sync off, the profile keeps no synced cookies
    /// (`clearSyncedCookies`).
    ///
    /// Last, what the launch changed is copied, the run is marked as begun, and its store is looked
    /// at from now on (`CookieSnapshotKeeper.begin`).
    private func prepareCookies(of id: UUID, summary: ProfileSummary, stored: ProfileConfiguration, storeRestored: Bool,
                                storeState: (state: CookieRecovery.StoreState, note: String), session: BrowserSession) async {
        var finding = CookieSnapshotKeeper.LaunchFinding()
        if stored.keepsCookieSnapshots, let store = session.dataStore?.httpCookieStore {
            finding = await cookieSnapshots.recover(id, store: store, state: storeState.state, note: storeState.note)
        } else {
            // Turned off, or an ephemeral profile: no copy of its cookies is kept.
            cookieSnapshots.forget(id)
        }
        // Cookies put back are the profile's state now; none put back (WebKit kept none of them) is
        // tried again at the next launch — unless a clean stop copies the store first.
        var changedAtLaunch = (finding.report?.restored ?? 0) > 0
        if !stored.syncsCookies {
            try? repository.clearSyncedCookies(for: id)
            if await applyQueuedCookies(of: id, name: summary.name, to: session) > 0 { changedAtLaunch = true }
        } else if let store = session.dataStore?.httpCookieStore {
            var synced: (loaded: CookieJarDocument, jar: CookieJarDocument, baseline: [ImportedCookie])?
            do {
                let loaded = try repository.cookieJar(for: id)
                let baseline = try repository.cookieBaseline(for: id)
                // A store that came up with nothing (its website data lost) records no deletions, nor one
                // that lost cookies — but for what this Mac's newest snapshot, at least as new as the
                // baseline, says was deleted since (`atLaunch(afterLoss:)`); nor one whose cookie file
                // was damaged.
                let found = await CookieStoreSync.persistentCookies(in: store)
                let jar: CookieJarDocument
                if finding.lost {
                    jar = loaded.atLaunch(afterLoss: found, snapshot: finding.latest, baseline: baseline)
                } else {
                    let came: CookieJarDocument.LaunchStore = finding.damaged ? .recovered : (storeRestored ? .asLeft : .withNothing)
                    jar = loaded.atLaunch(store: found, baseline: baseline, came: came)
                }
                let applied = await CookieStoreSync.apply(jar, to: store)
                log.notice("Synced cookies at launch: \(applied.set) set, \(applied.deleted) deleted, \(applied.refused.count) refused")
                if applied.set + applied.deleted > 0 { changedAtLaunch = true }
                synced = (loaded, jar, await CookieStoreSync.persistentCookies(in: store))
            } catch {
                log.error("Could not read the synced cookies of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                onError?(String(format: L("cookies.sync.unreadable"), summary.name))
            }
            if await applyQueuedCookies(of: id, name: summary.name, to: session) > 0 { changedAtLaunch = true }
            if let synced {
                let now = Date()
                let current = await CookieStoreSync.persistentCookies(in: store)
                saveSyncedCookies(of: id, name: summary.name, loaded: synced.loaded,
                                  jar: synced.jar.recording(store: current, baseline: synced.baseline, at: now),
                                  baseline: CookieBaseline(cookies: current, savedAt: now))
            }
        }
        if stored.keepsCookieSnapshots, let store = session.dataStore?.httpCookieStore {
            await cookieSnapshots.begin(id, store: store, changedAtLaunch: changedAtLaunch) { [weak session] in
                session?.dataStore?.httpCookieStore
            }
        }
    }

    /// Cookies put back at this launch (`CookieSnapshotKeeper.recover`), shown in the profile's window
    /// once it has one (`CookieRecoveryNotice`), and told once for the profile's journal — at once, with
    /// or without a window. Called when the launch opened its window, and again when a profile that
    /// had none gets one.
    func presentCookieRecovery(_ id: UUID) {
        guard let session = sessions[id], let pending = cookieSnapshots.untoldReport(id) else { return }
        let shown = CookieRecoveryNotice.present(pending, in: session)
        guard let taken = cookieSnapshots.takeUntold(id, shown: shown), taken.firstTime else { return }
        onCookiesRecovered?(id, taken.report)
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

    /// The cookies imported while the profile was stopped, into its store; returns how many it kept.
    /// One that expired while it waited is not set: setting it would delete the profile's own cookie
    /// of that name (a restore from a snapshot, queued for days, as an import).
    @discardableResult
    private func applyQueuedCookies(of id: UUID, name: String, to session: BrowserSession) async -> Int {
        let queued: [ImportedCookie]
        do {
            queued = try repository.importedCookiesForLaunch(id)
        } catch {
            log.error("Could not read the cookies queued for \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            if case CoreError.newerFormat = error {
                // A newer version's queue stays for it as it is (docs/UPDATES.md §4).
                onError?(errorText(error))
            } else {
                // Never deleted (docs/DESTRUCTIVE_PATHS.md): moved aside, the import can be made again.
                let aside = try? repository.moveUnreadableImportedCookiesAside(id)
                onError?(String(format: L("cookies.launch.unreadable"), name, aside?.lastPathComponent ?? "cookies-import.bin"))
            }
            return 0
        }
        guard !queued.isEmpty, let store = session.dataStore else { return 0 }
        let now = Date()
        let live = queued.filter { ($0.expires ?? .distantFuture) > now }
        let result = await CookieStoreImport.apply(live, to: store.httpCookieStore)
        repository.clearImportedCookies(id)
        log.notice("Applied \(result.stored) imported cookies at launch, \(result.refused.count) refused, \(queued.count - live.count) expired while they waited")
        if !result.refused.isEmpty {
            onError?(String(format: L("cookies.launch.refused"), result.refused.count, name,
                            result.refused.prefix(5).map { "\($0.name) (\($0.domain))" }.joined(separator: ", ")))
        }
        return result.stored
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

    /// Returns true once no process holds the profile's home (`SafariHomeVault.isInUse`), false if
    /// one still does after `seconds` or a Lock or Quit began meanwhile.
    private func waitUntilHomeIsFree(of id: UUID, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while safariHomeVault.isInUse(profileID: id) {
            guard Date() < deadline, !isShuttingDown else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
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
