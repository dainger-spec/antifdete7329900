import AppKit
import BrowserCore
import Combine
import Foundation
import os

/// App-level state: vault lock state, profile list, and the profile manager.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case setup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var profiles: [ProfileSummary] = []
    /// What the Profiles list shows about each profile beyond its summary (see `ProfileDetails`).
    @Published private(set) var details: [UUID: ProfileDetails] = [:]
    @Published private(set) var isWorking = false
    /// A sync is running: launches wait for it (it replaces the profiles' files on disk).
    private var isSyncing = false
    @Published var errorMessage: String?
    /// Why the master password just typed is not accepted (§10.1): it is the account's password or
    /// the license's key. Shown under its field, on the setup screen and in "Change master password";
    /// cleared as the password changes.
    @Published var masterPasswordRefusal: String?
    /// After an unlock (§10.1, later): the master password is the account's password or the license's
    /// key, typed in this session. Said, not refused — the data is already locked with it — with the
    /// action to change it beside the text.
    @Published var masterPasswordWarning: String?
    /// A profile whose password manager should open (from "Passwords…" in a browser window).
    @Published var passwordsRequest: ProfileSummary?
    /// Profiles that were started with a proxy that does not work, and what the probe found
    /// (`ProfileManager.onProxyProblem`): the Profiles window says it in words, with Check.
    @Published var proxyProblems: [ProxyProblem] = []
    /// The tags' colours (`labels.bin`): the vault's, for every view that shows tags.
    @Published private(set) var tagColors = TagColors()
    /// `labels.bin` is a newer version's: shown as none, and no choice is written over it.
    private var tagColorsRefused = false
    /// The scenarios of the automation editor (`scenarios.bin`): this Mac's.
    @Published private(set) var scenarios = ScenarioLibrary()
    /// `scenarios.bin` is a newer version's: shown as none, and nothing is written over it.
    private var scenariosRefused = false
    /// The last unlock attempt failed with a wrong password (the unlock screen then shows which
    /// vault it tried).
    @Published private(set) var unlockFailed = false
    /// Where `startOver()` moved the previous vault (shown on the setup screen).
    @Published private(set) var movedAsideVaultPath: String?
    /// The vault's profile index not read as it should be, or profile folders on disk that it does
    /// not list: said in the Profiles window with the vault's folder and what to do (nil: all is well).
    @Published private(set) var indexNotice: IndexNotice?
    /// Deleted profiles whose folders are kept (R3): deleted on another device, or their folder put
    /// back from a backup. The Profiles window asks what to do with each: bring it back, or remove it.
    @Published private(set) var keptDeletedProfiles: [ProfileRepository.KeptDeletedProfile] = []

    struct IndexNotice: Equatable {
        enum Kind: Equatable {
            /// No `index.bin`, and profile folders there.
            case missing
            /// An `index.bin` that could not be read: kept, never written over.
            case unreadable
            /// The index was read, and profile folders are there that it neither lists nor
            /// records as deleted (an older index put back, or one made anew while it was missing).
            case unlisted
            /// Profiles put back into the index from the key copies in their own folders, at this
            /// unlock: the index was missing, or an older one was put back (`folders`: how many).
            case takenIn
        }
        let kind: Kind
        /// The profile folders kept: all of them (missing, unreadable), or those not listed.
        let folders: Int
        let vaultPath: String
    }
    @Published private(set) var deviceSettings = DeviceSettings()
    /// `settings.bin` could not be read at unlock (and is not a newer version's): the defaults are
    /// shown, and at the first change the file is moved aside (`settings.bin.unreadable`), never
    /// written over — it holds the sync target, the server's token and the automation token.
    private var deviceSettingsUnreadable = false
    /// The app's own settings (Settings…, ⌘,).
    let settings = AppSettings()
    /// The Proxies section is asked for from outside the Profiles window (Settings → Proxies).
    @Published var proxiesRequest = false
    /// The command palette (⌘K) is open in the Profiles window.
    @Published var showingPalette = false
    /// The Help window's topic (`HelpView`): what opens the window may choose it — the scenario
    /// editor's Commands, the automation settings.
    @Published var helpTopic: HelpTopic = .start
    /// A section of Settings to show when it next appears (the command palette).
    @Published var settingsSection: SettingsSection?
    /// The network guard's notice at the foot of the profiles was closed: not again until the app
    /// starts again (kept nowhere but here).
    @Published var guardNoticeHidden = false
    /// Safari on this Mac runs a newer engine than profiles, and OK was not yet pressed for this
    /// pair of versions (`EngineWarning`).
    @Published private(set) var engineWarning: EngineWarning.Facts?

    /// The version an update installed at the last quit: the profiles' window says it once.
    @Published private(set) var updatedTo: String?

    func updatedNoticeSeen() {
        updatedTo = nil
    }

    func engineWarningSeen() {
        if let engineWarning { EngineWarning.markSeen(engineWarning) }
        engineWarning = nil
    }
    /// This quit has recorded the profiles to reopen (a quit locks in more than one round).
    private var recordedProfilesToReopen = false

    private(set) var repository: ProfileRepository?
    /// The open vault's profiles, for `AccountSwitchScenario`'s measurements (a check only).
    var repositoryForChecks: ProfileRepository? { repository }
    private(set) var manager: ProfileManager?
    /// The warm-up queue and schedule of this unlock (`WarmUpCoordinator`).
    private(set) var warmUps: WarmUpCoordinator?
    /// The proxy list of the unlocked vault (`ProxyListModel`); nil while locked.
    private(set) var proxyList: ProxyListModel?
    private var managerObservation: AnyCancellable?
    private var lockTask: Task<Void, Never>?
    /// The app's updater; nil in a build without an update feed (`AppUpdater.Configuration.main`),
    /// and until the app's window first appears (`startUpdates`).
    @Published private(set) var updater: AppUpdater?
    private var updatesStarted = false
    /// "Install Now" is stopping the profiles and checking the quit (`installUpdateNow`).
    @Published private(set) var isInstallingUpdate = false
    /// Profile processes this app had killed before the quit under way began (`ProfileProcess.forcedExits`).
    private var forcedExitsBeforeQuit: Int?

    /// The main Profiles window (SwiftUI `Window` scene), captured via `WindowReader`. Brought
    /// back to the front when a profile's windows all close, and on dock reopen.
    weak var profilesWindow: NSWindow?

    /// See `AppEnvironment.vaultDirectory` (inside the container when sandboxed).
    let root: URL
    /// This Mac's license (`LicenseModel`, the server's docs/CONTRACT.md §8): read from
    /// `account.json` before the vault is unlocked, and decided here every minute.
    let license: LicenseModel
    /// The first launch's sign-in and this Mac's connection are done — or this build has no account
    /// server: the master password's screen comes next (§10.1, the owner's order).
    @Published var accountStepDone: Bool
    /// The master password's screen is the first this run shows (no sign-in before it): the
    /// interface's language is offered on it (`FirstLaunchLanguagePicker`).
    let setupIsFirstScreen: Bool
    private var licenseObservation: AnyCancellable?

    init() {
        _engineWarning = Published(initialValue: EngineWarning.unseen(EngineWarning.current))
        // Before the vault is looked for: a vault a sandboxed build of this app left in its
        // container is this build's to use (an unsandboxed build hosts Safari's chrome).
        AppEnvironment.adoptSandboxedDataIfNeeded()
        root = AppEnvironment.vaultDirectory
        AppEnvironment.removeStandaloneSafariHome(in: root)
        // Partial plaintext an unseal that did not finish left (R8): no profile runs yet.
        AppEnvironment.removeUnsealLeftovers(vault: root)
        let firstPhase: Phase = MasterVault.exists(in: root) ? .locked : .setup
        phase = firstPhase
        license = LicenseModel(root: root)
        let accountDone = !license.isConfigured || license.record.isSignedIn
        accountStepDone = accountDone
        // The master password's screen is this run's first: no sign-in comes before it.
        setupIsFirstScreen = firstPhase == .setup && accountDone
        // No profile's page is handed to Quick Look, Services or another app (`HandOffs`).
        HandOffs.closeForWebViews()
        // Profiles in processes of their own get changed browsing settings at once.
        settings.onBrowsingChange = { [weak self] preferences in self?.manager?.sendPreferences(preferences) }
        // The license counts this Mac's profiles (sent with each refresh, §6.2; the limit, §8.4) and
        // asks for an update when the server sent what this version cannot judge (§9.4).
        license.profilesHere = { [weak self] in self?.profiles ?? [] }
        // The windows that show the license redraw with it.
        licenseObservation = license.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        license.onAppOutdated = { [weak self] in Task { await self?.updater?.checkNow() } }
        // The subscription's reminders for an account with a key alone (ExpiryNotifications): offered
        // right after a key connected this Mac, or at the first warning — then, not over the lock.
        license.onActivatedWithKey = { [weak self] in
            guard let self else { return }
            ExpiryNotifications.update(at: .activatedWithKey, license: self.license)
        }
        license.onStateChanged = { [weak self] in
            guard let self, self.phase == .unlocked else { return }
            // A plan without automation any more: every run stops after its current step.
            if !self.license.allowsAutomation, let manager = self.manager {
                for (id, run) in manager.scenarioRuns where run.isRunning { manager.stopScenario(id, reason: .rightsEnded) }
            }
            ExpiryNotifications.update(at: .stateChanged, license: self.license)
        }
        license.start()
    }

    /// The unlocked vault, for the license's key (`AccountKeyVault`); nil while locked.
    var unlockedVaultForAccount: UnlockedVault? { repository?.vault }

    /// Settings → Proxies → the list: the Profiles window shows its Proxies section.
    func showProxyList() {
        guard proxyList != nil else { return }
        activateProfilesWindow()
        proxiesRequest = true
    }

    var hasRunningProfiles: Bool { manager?.hasRunningProfiles ?? false }

    /// Brings the Profiles window to the front (e.g. after closing a profile, or on dock reopen).
    func activateProfilesWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = profilesWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Vault

    func createVault(password: String) async {
        guard !isWorking else { return }
        // §10.1, the owner's decision: the account's password, typed in this session, is not
        // accepted as the master password — compared directly, never used to open anything; nor is
        // the license's key, which goes to the server at every activation.
        if let refusal = refusalOfMasterPassword(password) {
            masterPasswordRefusal = refusal
            return
        }
        masterPasswordRefusal = nil
        let root = root
        await perform {
            // Argon2id (64 MiB, 3 passes) takes a fraction of a second; keep it off the main thread.
            let vault = try await Task.detached(priority: .userInitiated) {
                try MasterVault.create(in: root, password: password)
            }.value
            try self.didUnlock(vault)
            self.license.forgetComparisons()
        }
    }

    /// §10.1: a new master password that is the account's password (typed in this session) or the
    /// license's key (typed in this session, or kept in the vault) — the refusal's text; nil when it
    /// is neither. Compared in memory only; nothing is derived from either, nothing is tried with them.
    func refusalOfMasterPassword(_ password: String) -> String? {
        if license.isAccountPassword(password) { return L("contract.master_password.same_as_account") }
        if license.isLicenseKey(password) { return L("contract.master_password.same_as_key") }
        return nil
    }

    func unlock(password: String) async {
        // One Return press can arrive twice (field submit + default button): never try "" or a
        // second attempt while one is running — that attempt would report a wrong password.
        guard !password.isEmpty, !isWorking else { return }
        let root = root
        unlockFailed = false
        await perform {
            let vault: UnlockedVault
            do {
                vault = try await Task.detached(priority: .userInitiated) {
                    let vault = try MasterVault.unlock(in: root, password: password)
                    // A vault from before Argon2id gets it now, with the password that just opened
                    // it. A failure leaves the old header in place (the write is atomic).
                    let log = Logger(subsystem: "PrivacyBrowser", category: "Vault")
                    do {
                        if try vault.upgradeKDFIfNeeded(password: password) {
                            log.notice("Vault key derivation upgraded from PBKDF2 to Argon2id")
                        }
                    } catch {
                        log.error("Vault key derivation upgrade failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                    }
                    return vault
                }.value
            } catch CoreError.wrongPassword {
                self.unlockFailed = true
                throw CoreError.wrongPassword
            }
            try self.didUnlock(vault)
            // §10.1 later: the account's password and the master password typed in one session are
            // the same — the data is already locked with it, so it is said, not refused; the same for
            // the license's key (typed in this session, or kept in the vault just opened).
            if self.license.isAccountPassword(password) {
                self.masterPasswordWarning = L("contract.master_password.same_as_account_existing")
            } else if self.license.isLicenseKey(password) {
                self.masterPasswordWarning = L("contract.master_password.same_as_key")
            }
            self.license.forgetComparisons()
        }
    }

    /// For the unlock screen after a wrong password: when the vault this build opens was created
    /// (from its plaintext header). A sandboxed `.app`, an unsandboxed build (`swift run`,
    /// `SANDBOX=0`) and a build with another bundle id each open their own vault folder, so a
    /// password set in one of them is "wrong" in another.
    var vaultCreatedDescription: String {
        guard let header = try? MasterVault.readHeader(in: root) else { return "?" }
        return header.createdAt.shown(date: .abbreviated, time: .shortened)
    }

    /// The lock screen's footer: the day the vault was made ("12 March 2026"); nil when its
    /// header cannot be read.
    var vaultCreatedDay: String? {
        (try? MasterVault.readHeader(in: root)).map { $0.createdAt.shown(date: .long, time: .omitted) }
    }

    /// The vault folder, with the real home directory shown as `~` (inside the App Sandbox
    /// `homeDirectoryForCurrentUser` is the container, so the passwd entry is used instead).
    var vaultPathDescription: String {
        Self.displayPath(root)
    }

    /// True when the vault was not created in the app: the app uses Argon2id (or, before it,
    /// `KDFParameters.recommendedIterations` of PBKDF2); the self-test and the CI migration check use
    /// PBKDF2 with far fewer (`--selftest-write-vault` creates one with the password "migration-check").
    var vaultLooksLikeTestVault: Bool {
        guard let header = try? MasterVault.readHeader(in: root) else { return false }
        return !header.kdf.isMemoryHard && header.kdf.iterations < KDFParameters.recommendedIterations
    }

    /// The way out when the master password is unknown: the current vault folder is moved aside
    /// (not deleted — renaming it back restores it) and the setup screen creates a new vault.
    func startOver() {
        guard phase == .locked, !isWorking else { return }
        do {
            let backup = try MasterVault.moveAside(root)
            movedAsideVaultPath = Self.displayPath(backup)
            unlockFailed = false
            phase = .setup
        } catch {
            showError(errorText(error))
        }
    }

    /// `indexNotice` from the repository as it is now: a sync can have put a missing index back.
    private func updateIndexNotice() {
        guard let repository else {
            indexNotice = nil
            return
        }
        let unlisted = repository.unlistedProfileFolders().count
        let notice: IndexNotice?
        switch repository.indexState {
        case .unreadable(let folders):
            notice = IndexNotice(kind: .unreadable, folders: folders, vaultPath: vaultPathDescription)
        case .missing:
            notice = unlisted > 0 ? IndexNotice(kind: .missing, folders: unlisted, vaultPath: vaultPathDescription) : nil
        case .read:
            let takenIn = repository.takenInFromKeyCopies.count
            notice = unlisted > 0 ? IndexNotice(kind: .unlisted, folders: unlisted, vaultPath: vaultPathDescription)
                : takenIn > 0 ? IndexNotice(kind: .takenIn, folders: takenIn, vaultPath: vaultPathDescription) : nil
        }
        if notice != indexNotice { indexNotice = notice }
    }

    /// A new profile is refused while the index cannot be read (the repository refuses it as well):
    /// said in words, pointing at the notice that says how to restore it.
    private func refuseWhileTheIndexIsUnreadable(_ repository: ProfileRepository) throws {
        if case .unreadable = repository.indexState { throw DraftProblem(L("index.unreadable.cannotCreate")) }
    }

    /// The vault's folder in the Finder (the Profiles window's notice about the index).
    func revealVaultFolder() {
        SystemOpen.revealInFinder([root])
    }

    /// A kept deleted profile's folder (R3), in the Finder: the one that cannot be read is not
    /// removed by the app, so this is where the person sees it.
    func revealProfileFolder(_ id: UUID) {
        guard let repository else { return }
        SystemOpen.revealInFinder([repository.directory(for: id)])
    }

    private static func displayPath(_ url: URL) -> String {
        let path = url.path
        if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }), path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// This app's Settings window, from outside SwiftUI's views (a profile's ⌘, arrives over its
    /// channel): the app menu's Settings… item — SwiftUI's own, ⌘, — is chosen as a click would.
    /// The private `showSettingsWindow:` action this used did nothing on macOS 26 (the owner's Mac,
    /// 31 October: the Profiles window came forward, Settings did not open).
    static func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
    }

    private func didUnlock(_ vault: UnlockedVault) throws {
        // The index read, or found missing or unreadable — then nothing is swept, and the Profiles
        // window says so (`indexNotice`); with it read, only the folders of profiles it records as
        // deleted go (ProfileRepository.openedAtUnlock, which the tests run as well).
        let repository = try ProfileRepository.openedAtUnlock(vault: vault)
        // Partial plaintext an unseal that did not finish left (R8) — while the vault was locked,
        // no profile ran; none is started again before this.
        AppEnvironment.removeUnsealLeftovers(vault: vault.root)
        switch repository.indexState {
        case .read:
            break
        case .missing(let folders):
            Logger(subsystem: "PrivacyBrowser", category: "Vault")
                .error("The profile index is missing: \(Int(folders), privacy: .public) profile folders kept, none deleted")
        case .unreadable(let folders):
            Logger(subsystem: "PrivacyBrowser", category: "Vault")
                .error("The profile index could not be read: \(Int(folders), privacy: .public) profile folders kept, none deleted, the index not written over")
        }
        let manager = ProfileManager(repository: repository)
        // The license decides whether a profile opens (§8): here, before its process starts.
        manager.launchGate = { [weak self] id in self?.license.refusalToOpen(id) }
        // Scenario automation is the plan's (docs/AUTOMATION.md): asked before each command.
        manager.scenariosAllowed = { [weak self] in self?.license.allowsAutomation ?? false }
        license.vaultOpened(vault)
        ExpiryNotifications.update(at: .stateChanged, license: license)
        manager.onError = { [weak self] message in self?.showError(message) }
        manager.onReturnToProfiles = { [weak self] in
            self?.activateProfilesWindow()
            self?.refresh()
        }
        manager.onConfigurationChanged = { [weak self] _ in self?.refresh() }
        // ⌘, in a profile's window: this app's Settings, in front.
        manager.onShowSettings = { Self.openSettingsWindow() }
        manager.onShowPasswords = { [weak self] id in
            guard let self, let summary = self.profiles.first(where: { $0.id == id }) else { return }
            self.activateProfilesWindow()
            self.passwordsRequest = summary
        }
        managerObservation = manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.repository = repository
        self.manager = manager
        // Queued and scheduled warm-ups start the way the warm-up screen does (startWarmUp).
        let warmUps = WarmUpCoordinator(manager: manager, repository: repository) { [weak self] plan, id in
            await self?.startWarmUp(plan, for: id) ?? false
        }
        warmUps.forwardChanges(to: self)
        self.warmUps = warmUps
        warmUps.begin()
        let proxyList = ProxyListModel(vault: vault) { [weak self] message in self?.showError(message) }
        // The proxies typed into profiles before there was a list are in it from now on (once).
        proxyList.takeIn(profileProxies: repository.profileProxies())
        proxyList.onEntryChanged = { [weak self] entry, previous in self?.followProxyEntry(entry, previous: previous) }
        self.proxyList = proxyList
        manager.onProxyProblem = { [weak self] id, proxy, diagnosis in
            self?.reportProxyProblem(of: id, proxy: proxy, diagnosis: diagnosis)
        }
        manager.refusesFailingProxy = { [weak self] in self?.settings.proxyFailure == .doNotLaunch }
        loadTagColors(from: vault)
        loadScenarios(from: vault)
        manager.onProxyLaunchRefused = { [weak self] id, proxy, diagnosis in
            self?.reportProxyProblem(of: id, proxy: proxy, diagnosis: diagnosis, notStarted: true)
        }
        do {
            deviceSettings = try DeviceSettings.load(from: vault)
            deviceSettingsUnreadable = false
        } catch {
            deviceSettings = DeviceSettings()
            // A newer version's settings are neither shown nor saved over (the save refuses):
            // said once, rather than showing defaults as if they were this device's settings.
            // Settings that could not be read are said too, and kept (`deviceSettingsUnreadable`).
            if case CoreError.newerFormat = error {
                showError(errorText(error))
            } else {
                deviceSettingsUnreadable = true
                Logger(subsystem: "PrivacyBrowser", category: "Vault").error("settings.bin could not be read: \(error.logKind, privacy: .public); kept, the defaults shown")
                showError(L("settings.device.unreadable"))
            }
        }
        restartAutomation()
        phase = .unlocked
        refresh()
        // What earlier versions left in the account's com.apple.Safari.plist is taken out, once.
        SafariAccountPreferences.removeOnce { repository.list().compactMap { try? repository.loadConfiguration($0.id) } }
        // A quit that was not finished (an update refused at Install Now) recorded what ran then;
        // the next quit records afresh.
        recordedProfilesToReopen = false
        Task {
            await manager.recoverUnsealedProfiles()
            await self.reopenProfilesFromLastQuit()
        }
    }

    /// Settings → Startup: the profiles that had a window when the app last quit start again —
    /// those that still exist. The list is used once.
    private func reopenProfilesFromLastQuit() async {
        guard let recorded = deviceSettings.reopenAtUnlock, !recorded.isEmpty else { return }
        try? updateDeviceSettings { $0.reopenAtUnlock = nil }
        guard settings.startup == .reopenProfiles else { return }
        for id in StartupReopen.toLaunch(recorded: recorded, existing: profiles.map(\.id)) {
            await launch(id)
        }
    }

    /// At the start of a quit: the profiles with a window now are kept for the next unlock when the
    /// settings ask to reopen them; otherwise nothing is kept.
    private func recordProfilesToReopen() {
        guard !recordedProfilesToReopen, let manager, repository != nil else { return }
        recordedProfilesToReopen = true
        let open = settings.startup == .reopenProfiles ? StartupReopen.toRecord(manager.activity()) : []
        guard open != (deviceSettings.reopenAtUnlock ?? []) else { return }
        try? updateDeviceSettings { $0.reopenAtUnlock = open.isEmpty ? nil : open }
    }

    /// Lock (and Quit): waits for launches and seals under way, then stops and seals every
    /// running profile. A second call — Lock clicked twice, or ⌘Q during Lock — waits for the
    /// same lock instead of starting another or returning before the data is sealed.
    ///
    /// `forQuit`: the process exits afterwards, so a profile whose data store WebKit still holds
    /// after every seal attempt is force-sealed instead of left decrypted (also when the quit
    /// joins a Lock already under way). See `WebDataStoreVault.forceSealWhenStoreStaysInUse`.
    func lock(forQuit: Bool = false) async {
        if forQuit {
            recordProfilesToReopen()
            manager?.prepareForQuit()
            forcedExitsBeforeQuit = forcedExitsBeforeQuit ?? ProfileProcess.forcedExits
        }
        if let lockTask {
            await lockTask.value
            return
        }
        let task = Task { @MainActor in
            await self.performLock()
            // Cleared by the lock itself, before anyone awaiting it resumes: a waiter that finds
            // `hasActivity` still true would wait (or quit) again.
            self.lockTask = nil
        }
        lockTask = task
        await task.value
    }

    /// Lock or Quit must wait: a lock is under way, or a profile is running, launching or sealing.
    var hasActivity: Bool { lockTask != nil || (manager?.hasActivity ?? false) }

    private func performLock() async {
        license.vaultLocked()
        // First: no script may start a profile while they are being stopped and sealed.
        automationServer?.stop()
        automationServer = nil
        automationState = .stopped
        // Before the profiles stop: nothing waiting in the warm-up queue may launch one again.
        warmUps?.shutDown()
        warmUps = nil
        await manager?.shutDown()
        proxyList?.stopChecking()
        proxyList = nil
        proxyProblems = []
        tagColors = TagColors()
        tagColorsRefused = false
        scenarios = ScenarioLibrary()
        scenariosRefused = false
        managerObservation = nil
        manager = nil
        repository = nil
        profiles = []
        details = [:]
        deviceSettings = DeviceSettings()
        deviceSettingsUnreadable = false
        phase = MasterVault.exists(in: root) ? .locked : .setup
    }

    /// Changes the master password: the vault's key is wrapped anew under it, and nothing else
    /// changes — a copy of `vault.json` from before still opens the vault with the old password,
    /// the data saved after the change included (docs/ARCHITECTURE.md, Changing the master
    /// password). With sync set up, the new header goes to the sync location right away, so that a
    /// new device joins with the new password and not the old; out of reach, it goes at the next
    /// sync, and the person is told so.
    func changePassword(current: String, new: String) async {
        guard let repository else { return }
        // §10.1: the new master password is held to the rule a first one is.
        if let refusal = refusalOfMasterPassword(new) {
            masterPasswordRefusal = refusal
            return
        }
        masterPasswordRefusal = nil
        let vault = repository.vault
        let target = deviceSettings.syncTarget
        var changed = false
        await perform {
            // The count of changes the sync location's header has, when it can be read: this change
            // is then the newest there (another Mac may have changed the password since this one synced).
            let there = await self.passwordRevisionThere(target, repository: repository)
            try await Task.detached(priority: .userInitiated) {
                try vault.changePassword(current: current, new: new, atLeast: there)
            }.value
            changed = true
        }
        if changed, let target { await publishPasswordChange(target, repository: repository) }
    }

    private func passwordRevisionThere(_ target: DeviceSettings.SyncTarget?, repository: ProfileRepository) async -> Int? {
        guard let target, !isSyncing else { return nil }
        var folder: URL?
        defer { folder?.stopAccessingSecurityScopedResource() }
        do {
            let (transport, scoped) = try syncTransport(for: target, vaultID: repository.vault.vaultID)
            folder = scoped
            return try await SyncEngine(repository: repository, transport: transport).passwordRevisionThere()
        } catch {
            return nil
        }
    }

    /// The header of a change of the master password made here, to the sync location (header only:
    /// no profile's files, so not held back by running profiles).
    private func publishPasswordChange(_ target: DeviceSettings.SyncTarget, repository: ProfileRepository) async {
        var folder: URL?
        defer { folder?.stopAccessingSecurityScopedResource() }
        do {
            let (transport, scoped) = try syncTransport(for: target, vaultID: repository.vault.vaultID)
            folder = scoped
            if try await SyncEngine(repository: repository, transport: transport).publishVaultHeader() != .published {
                showError(L("changepw.sync.notThere"))
            }
        } catch {
            showError(String(format: L("changepw.sync.later"), errorText(error)))
        }
    }

    // MARK: Profiles

    func refresh() {
        profiles = repository?.list() ?? []
        // The license tells the server the real number with its renewals (the owner, 3 November).
        if repository != nil { license.profilesKnown(count: profiles.count) }
        updateIndexNotice()
        let kept = repository?.keptDeletedProfiles() ?? []
        if kept != keptDeletedProfiles { keptDeletedProfiles = kept }
        var details: [UUID: ProfileDetails] = [:]
        if let repository {
            for profile in profiles {
                if let configuration = try? repository.loadConfiguration(profile.id) {
                    details[profile.id] = ProfileDetails(configuration)
                }
            }
        }
        self.details = details
    }

    /// The new profile's id.
    @discardableResult
    func createProfile(name: String, configuration: ProfileConfiguration) throws -> UUID? {
        guard let repository else { return nil }
        try refuseWhileTheIndexIsUnreadable(repository)
        if let refusal = license.refusalToCreate() { throw refusal }
        let summary = try repository.create(name: name, configuration: configuration)
        refresh()
        return summary.id
    }

    func configuration(for id: UUID) throws -> ProfileConfiguration {
        guard let repository else { throw CoreError.vaultNotFound }
        return try repository.loadConfiguration(id)
    }

    /// Brings a kept deleted profile back as a new profile (`ProfileTransfer.bringBack`), off the
    /// main thread: everything it carries is re-encrypted. The old folder stays, marked brought back.
    func bringBackDeletedProfile(_ id: UUID) async {
        guard let repository else { return }
        if let refusal = license.refusalToCreate() {
            errorMessage = refusal.text
            return
        }
        await perform {
            _ = try await Task.detached(priority: .userInitiated) { try ProfileTransfer.bringBack(id, in: repository) }.value
        }
        refresh()
    }

    /// Removes a kept deleted profile's folder for good, once the person said so (refused for one
    /// that cannot be read).
    func removeDeletedProfileForGood(_ id: UUID) {
        guard let repository else { return }
        do {
            try repository.removeKeptDeletedProfile(id)
        } catch {
            showError(errorText(error))
        }
        refresh()
    }

    /// The files in a profile's folder set aside as unreadable: its deletion's confirmation names them.
    func unreadableFiles(for id: UUID) -> [String] {
        repository?.unreadableFiles(for: id) ?? []
    }

    /// What the inspector counts of each profile it has shown (`ProfileRepository.counts`): read
    /// when a profile is inspected, off the main thread, and only read — nothing is written, moved
    /// aside or taken in.
    @Published private(set) var inspectorCounts: [UUID: ProfileCounts] = [:]

    func loadInspectorCounts(for id: UUID) {
        guard let repository, let details = details[id] else { return }
        let historyPolicy = details.historyPolicy
        let cookies = details.syncsCookies
        Task.detached(priority: .utility) {
            let counts = repository.counts(for: id, historyPolicy: historyPolicy, cookies: cookies)
            await MainActor.run { self.inspectorCounts[id] = counts }
        }
    }

    /// The versions of the profile's settings kept beside them (R4, R2).
    func keptSettings(for id: UUID) -> [KeptSettings] {
        repository?.keptSettings(for: id) ?? []
    }

    /// The person chose a kept version for the profile's settings (`ProfileRepository.useKeptSettings`).
    func useKeptSettings(_ file: String, for id: UUID) throws {
        guard let repository else { return }
        try repository.useKeptSettings(file, for: id)
        refresh()
    }

    /// The person removed a kept version, having looked at it; one that does not open is refused.
    func removeKeptSettings(_ file: String, for id: UUID) throws {
        guard let repository else { return }
        try repository.removeKeptSettings(file, for: id)
    }

    /// Changes take effect the next time the profile is launched.
    func updateProfile(_ id: UUID, name: String, configuration: ProfileConfiguration) throws {
        guard let repository else { return }
        // The settings this edit is of. Settings that cannot be read stop the save (R1): the form
        // was opened without them, and saved, the profile would start without its proxy.
        let stored = try repository.loadConfiguration(id)
        let saved = configuration.savingEdit(over: stored)
        try repository.saveConfiguration(saved, for: id)
        // Cookie sync off: the synced cookies go, here and (at the next sync) on the other devices.
        if !saved.syncsCookies { try repository.clearSyncedCookies(for: id) }
        if try repository.summary(for: id).name != name {
            try repository.rename(id, to: name)
        }
        refresh()
    }

    // MARK: Profile export and import (ProfileTransfer)

    /// Writes the profile to `url`, encrypted with `password`. A running profile is stopped first,
    /// and anything a crash left unsealed is sealed: the export must hold the profile whole.
    func exportProfile(_ id: UUID, to url: URL, password: String) async throws -> ProfileTransfer.Manifest {
        guard let manager, let repository else { throw CoreError.vaultNotFound }
        if manager.isRunning(id) { try await manager.stop(id) }
        try await manager.sealLeftovers(of: id)
        return try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ProfileTransfer.export(id, from: repository, to: url, password: password)
        }.value
    }

    /// What a profile export holds, opened with its password (nothing is imported).
    func readProfileExport(_ url: URL, password: String) async throws -> ProfileTransfer.Manifest {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ProfileTransfer.manifest(of: url, password: password)
        }.value
    }

    /// Imports a profile export as a new profile named `name`.
    func importProfile(from url: URL, password: String, name: String?) async throws -> ProfileSummary {
        guard let repository else { throw CoreError.vaultNotFound }
        try refuseWhileTheIndexIsUnreadable(repository)
        if let refusal = license.refusalToCreate() { throw refusal }
        let summary = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ProfileTransfer.importProfile(from: url, password: password, into: repository, name: name)
        }.value
        refresh()
        return summary
    }

    /// The Profiles window's Delete, once the person confirmed it (one profile, or each of several):
    /// the only caller of the one path that deletes a profile's data.
    func deleteProfile(_ id: UUID) async {
        await perform { try await self.manager?.deleteBecauseThePersonAsked(id) }
        refresh()
    }

    func launch(_ id: UUID, openingWindow: Bool = true) async {
        // A launch reads the files sync replaces (settings, synced cookies): after the sync.
        while isSyncing { try? await Task.sleep(nanoseconds: 100_000_000) }
        await perform { try await self.manager?.launch(id, openingWindow: openingWindow) }
        refresh()
    }

    func stop(_ id: UUID) async {
        await perform { try await self.manager?.stop(id) }
    }

    func isRunning(_ id: UUID) -> Bool { manager?.runningProfileIDs.contains(id) ?? false }
    /// A sync is replacing the profiles' files (the sidebar says so).
    var isSyncInProgress: Bool { isSyncing }
    func isBusy(_ id: UUID) -> Bool { manager?.busyProfileIDs.contains(id) ?? false }

    func passwordVault(for id: UUID) throws -> PasswordVault {
        guard let manager else { throw CoreError.vaultNotFound }
        return try manager.passwordVault(for: id)
    }

    // MARK: Cookie import

    /// Reads a cookie export chosen in the file panel (a security-scoped URL), off the main thread.
    func readCookieFile(_ url: URL) async -> CookieImportReport {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return CookieImporter.read(contentsOf: url)
        }.value
    }

    /// Imports cookies into a profile: now if it runs, else at its next launch.
    func importCookies(_ cookies: [ImportedCookie], into id: UUID) async throws -> ProfileManager.CookieImportOutcome {
        guard let manager else { throw CoreError.vaultNotFound }
        return try await manager.importCookies(cookies, into: id)
    }

    /// Every cookie of a profile, for an export (`ProfileManager.exportCookies`).
    func exportCookies(of id: UUID) async throws -> [ImportedCookie] {
        guard let manager else { throw CoreError.vaultNotFound }
        return try await manager.exportCookies(of: id)
    }

    // MARK: Session warm-up

    /// The profile's last warm-up plan, or a new one — and whether a saved plan could not be read
    /// (R1b): the warm-up screen says so, and the file is moved aside at the next save, never
    /// written over. A newer version's plan is not said here: saving over it is refused, and said.
    func warmUpPlan(for id: UUID) -> (plan: WarmUpPlan, unreadable: Bool) {
        guard let repository else { return (WarmUpPlan(), false) }
        do {
            return (try repository.warmUpPlan(for: id) ?? WarmUpPlan(), false)
        } catch {
            if case CoreError.newerFormat = error { return (WarmUpPlan(), false) }
            return (WarmUpPlan(), true)
        }
    }

    /// Remembers `plan` for the profile and starts it, launching the profile first when it is
    /// stopped. False when it did not start (the launch failed, and said why).
    func startWarmUp(_ plan: WarmUpPlan, for id: UUID) async -> Bool {
        guard let repository, let manager else { return false }
        do {
            try repository.saveWarmUpPlan(plan, for: id)
        } catch {
            showError(error.localizedDescription)
        }
        // Starting or being encrypted (a launch or a stop under way): let that finish first.
        while manager.busyProfileIDs.contains(id) { try? await Task.sleep(nanoseconds: 100_000_000) }
        // A profile that is not running is started for the warm-up alone: no window of its own
        // appears, the robot browses in one the user never sees, and when the run ends the profile
        // stops and seals again. This is what "warm up without a window in my face" means.
        if !manager.isRunning(id) { await launch(id, openingWindow: false) }
        // The manager of this unlock: a Lock while the profile started ends it.
        guard let current = self.manager, current === manager, current.isRunning(id) else { return false }
        guard current.startWarmUp(id, plan: plan) else {
            let name = profiles.first { $0.id == id }?.name ?? ""
            showError(String(format: L("warmup.error.notStarted"), name))
            return false
        }
        return true
    }

    /// Stops the profile's warm-up; the profile keeps running.
    func stopWarmUp(_ id: UUID) {
        manager?.stopWarmUp(id)
    }

    /// Whether `password` is the master password (asked before saved passwords are shown).
    func verifyMasterPassword(_ password: String) async -> Bool {
        guard let vault = repository?.vault else { return false }
        return await Task.detached(priority: .userInitiated) { vault.verifyPassword(password) }.value
    }

    /// The sites a profile never saves passwords for ("Never for This Website").
    func neverSavedSites(for id: UUID) -> [String] {
        (try? repository?.loadConfiguration(id).passwordNeverSaveSites) ?? []
    }

    /// Removes a site from that list: the browser offers to save passwords there again.
    func removeNeverSavedSite(_ site: String, for id: UUID) throws {
        guard let repository else { return }
        var configuration = try repository.loadConfiguration(id)
        guard configuration.passwordNeverSaveSites.contains(site) else { return }
        configuration.passwordNeverSaveSites.removeAll { $0 == site }
        configuration.settingsModifiedAt = Date()
        try repository.saveConfiguration(configuration, for: id)
    }

    // MARK: Sync (optional)

    /// Where this device syncs to; device-local, stored encrypted in `settings.bin`.
    var syncTarget: DeviceSettings.SyncTarget? { deviceSettings.syncTarget }
    var lastSyncStatus: DeviceSettings.SyncStatus? { deviceSettings.lastSync }

    /// LOCAL-ONLY transport: a folder (NAS, external disk). Stored as a security-scoped
    /// bookmark so the App Sandbox grants access again after relaunch.
    func setSyncFolder(_ folder: URL) {
        do {
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try updateDeviceSettings { $0.syncTarget = .folder(bookmark: bookmark, path: folder.path) }
        } catch {
            showError(String(format: L("sync.error.rememberFolder"), errorText(error)))
        }
    }

    /// SERVER-READY transport: a server implementing docs/SYNC_SERVER_API.md (none is included).
    func setSyncServer(baseURL: String, token: String) {
        do {
            guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) else {
                throw CoreError.invalidConfiguration("not a URL")
            }
            try HTTPSyncTransport.validate(url)
            try updateDeviceSettings { $0.syncTarget = .server(baseURL: url, token: token) }
        } catch {
            showError(errorText(error))
        }
    }

    func clearSyncTarget() {
        do {
            try updateDeviceSettings { $0.syncTarget = nil }
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Only allowed while no profile is running, because incoming changes replace files on disk.
    func syncNow() async {
        guard let repository, let manager, let target = deviceSettings.syncTarget, !isSyncing else { return }
        guard !manager.hasRunningProfiles else {
            showError(L("sync.error.profilesRunning"))
            return
        }
        isWorking = true
        defer { isWorking = false }
        isSyncing = true
        defer { isSyncing = false }
        // A profile still starting or being encrypted reads and writes its synced cookies: after it.
        await manager.waitWhileBusy()
        guard !manager.hasRunningProfiles else {
            showError(L("sync.error.profilesRunning"))
            return
        }
        var scopedFolder: URL?
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }
        let status: DeviceSettings.SyncStatus
        do {
            let (transport, folder) = try syncTransport(for: target, vaultID: repository.vault.vaultID)
            scopedFolder = folder
            let report = try await SyncEngine(repository: repository, transport: transport).sync()
            if report.pulled.contains("labels") { loadTagColors(from: repository.vault) }
            // A profile deleted on another device: nothing of it is deleted here. Its folder stays
            // for the person to bring back or remove (R3); WebKit's store of it outside the vault —
            // there only if sealing it failed at the unlock — stays as well. Profile data goes only
            // by the person's own Delete (`ProfileManager.deleteBecauseThePersonAsked`).
            for copy in report.unreadable {
                showError(Self.unreadableCopyText(copy, name: (try? repository.summary(for: copy.profileID))?.name))
            }
            // Settings put back from a backup, older than the server's (R2), and versions to go
            // through (R4): said, by the profile's name.
            func name(_ id: UUID) -> String { (try? repository.summary(for: id))?.name ?? id.uuidString }
            for id in report.restoredSettings { showError(String(format: L("sync.versions.restored"), name(id))) }
            for id in report.settingsVersionsToReview {
                showError(String(format: L("sync.versions.review"), name(id), repository.keptSettings(for: id).count))
            }
            status = DeviceSettings.SyncStatus(report: report)
        } catch {
            let message = errorText(error)
            status = DeviceSettings.SyncStatus(error: message)
            showError(String(format: L("sync.error.failed"), message))
        }
        try? updateDeviceSettings { $0.lastSync = status }
        refresh()
    }

    // MARK: Scenarios

    /// `scenarios.bin` as it is. One that does not open is kept and said once; the next save moves
    /// it aside as `scenarios.bin.unreadable`, never over it. A newer version's is said, and nothing
    /// is written over it.
    private func loadScenarios(from vault: UnlockedVault) {
        do {
            scenarios = try ScenarioLibrary.load(from: vault)
            scenariosRefused = false
        } catch {
            scenarios = ScenarioLibrary()
            if case CoreError.newerFormat = error {
                scenariosRefused = true
                showError(errorText(error))
            } else {
                Logger(subsystem: "PrivacyBrowser", category: "Vault")
                    .error("scenarios.bin could not be read: \(error.logKind, privacy: .public); kept, moved aside at the next save")
                showError(L("scenarios.unreadable"))
            }
        }
    }

    /// Saves `scenario` (added, or its edit), or removes it with `remove`. False when it was not written.
    @discardableResult
    func saveScenario(_ scenario: Scenario, remove: Bool = false) -> Bool {
        guard let repository else { return false }
        guard !scenariosRefused else {
            showError(L("scenarios.newer"))
            return false
        }
        var next = scenarios
        if remove { next.remove(scenario.id) } else { next.put(scenario) }
        do {
            try next.save(to: repository.vault)
            scenarios = next
            return true
        } catch {
            showError(errorText(error))
            return false
        }
    }

    /// Whether this plan has scenario automation.
    var allowsAutomation: Bool { license.allowsAutomation }

    /// The last run of a scenario on profile `id`, if any.
    func scenarioRun(of id: UUID) -> ProfileManager.ScenarioRunState? { manager?.scenarioRuns[id] }

    /// Runs `scenario` on profile `id`, starting the profile first when it is not running. False
    /// when the plan has no automation, the profile did not start, or a run of it is going.
    func runScenario(_ scenario: Scenario, on id: UUID) async -> Bool {
        guard license.allowsAutomation, manager != nil else { return false }
        if !isRunning(id) { await launch(id) }
        guard let manager, isRunning(id) else { return false }
        return manager.runScenario(id, name: scenario.name, source: scenario.source)
    }

    func stopScenario(on id: UUID) {
        manager?.stopScenario(id)
    }

    // MARK: Tags' colours

    /// `labels.bin` as it is. One that does not open is kept as it is and said once; the next
    /// choice of a colour moves it aside as `labels.bin.unreadable` (`TagColors.save`), never over
    /// it. A newer version's is said, and no choice is written over it.
    private func loadTagColors(from vault: UnlockedVault) {
        do {
            tagColors = try TagColors.load(from: vault)
            tagColorsRefused = false
        } catch {
            tagColors = TagColors()
            if case CoreError.newerFormat = error {
                tagColorsRefused = true
                showError(errorText(error))
            } else {
                Logger(subsystem: "PrivacyBrowser", category: "Vault")
                    .error("labels.bin could not be read: \(error.logKind, privacy: .public); kept, moved aside at the next choice")
                showError(L("tags.colors.unreadable"))
            }
        }
    }

    /// Gives `tag` a colour of the palette, or takes its colour away (nil), for the whole vault.
    func setTagColor(_ color: Int?, for tag: String) {
        guard let repository else { return }
        guard !tagColorsRefused else {
            showError(L("tags.colors.newer"))
            return
        }
        let wanted = color.flatMap { (0..<ProfileAvatarStyle.colorCount).contains($0) ? $0 : nil }
        guard tagColors.color(of: tag) != wanted else { return }
        var next = tagColors
        next.set(wanted, for: tag)
        do {
            try next.save(to: repository.vault)
            tagColors = next
        } catch {
            showError(errorText(error))
        }
    }

    /// A profile file that did not open on this Mac, as a sync left it (`SyncReport.unreadable`):
    /// the server's copy taken and this one kept beside it, or nothing there to take.
    static func unreadableCopyText(_ copy: SyncReport.UnreadableCopy, name: String?) -> String {
        let profile = name ?? copy.profileID.uuidString
        let path = "profiles/\(copy.profileID.uuidString)/\(copy.file)"
        let settings = copy.file == "config.bin"
        if let kept = copy.keptAs {
            return settings ? String(format: L("sync.unreadable.settings.taken"), profile, kept)
                : String(format: L("sync.unreadable.file.taken"), profile, copy.file, kept)
        }
        return settings ? String(format: L("sync.unreadable.settings.none"), profile, path)
            : String(format: L("sync.unreadable.file.none"), profile, copy.file, path)
    }

    /// The sync location's transport, and the folder whose security scope it opened (to be closed
    /// once done).
    private func syncTransport(for target: DeviceSettings.SyncTarget, vaultID: UUID) throws -> (SyncTransport, URL?) {
        switch target {
        case let .folder(bookmark, _):
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            let scoped = folder.startAccessingSecurityScopedResource() ? folder : nil
            if stale { setSyncFolder(folder) }
            return (LocalDirectorySyncTransport(directory: folder), scoped)
        case let .server(baseURL, token):
            return (try HTTPSyncTransport(configuration: .init(baseURL: baseURL, vaultID: vaultID, bearerToken: token)), nil)
        }
    }

    // MARK: Automation API (optional)

    /// Whether the local automation API listens, and where (`AutomationServer`).
    @Published private(set) var automationState: AutomationServer.State = .stopped
    private var automationServer: AutomationServer?

    /// The API's settings: off, with a token of its own, until set (`ensureAutomationSettings`).
    var automationSettings: AutomationSettings? { deviceSettings.automation }

    /// Makes and saves the API's settings (off, a new token) the first time they are shown, so
    /// that the token shown is the one kept.
    func ensureAutomationSettings() {
        guard deviceSettings.automation == nil else { return }
        try? updateDeviceSettings { $0.automation = AutomationSettings() }
    }

    func setAutomation(enabled: Bool, port: Int) {
        var settings = deviceSettings.automation ?? AutomationSettings()
        settings.isEnabled = enabled
        settings.port = port
        saveAutomation(settings)
    }

    /// A new token: scripts holding the old one are refused from now on.
    func renewAutomationToken() {
        var settings = deviceSettings.automation ?? AutomationSettings()
        settings.token = AutomationSettings.newToken()
        saveAutomation(settings)
    }

    private func saveAutomation(_ settings: AutomationSettings) {
        do {
            try updateDeviceSettings { $0.automation = settings }
        } catch {
            showError(String(format: L("automation.error.save"), error.localizedDescription))
            return
        }
        restartAutomation()
    }

    /// Listens with the saved settings when the API is on (and the vault unlocked), else not.
    private func restartAutomation() {
        automationServer?.stop()
        automationServer = nil
        guard let settings = deviceSettings.automation, settings.isEnabled, let manager, let repository else {
            automationState = .stopped
            return
        }
        let handler = AutomationHandler(manager: manager, repository: repository)
        handler.waitForSync = { [weak self] in
            while self?.isSyncing == true { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        handler.onChange = { [weak self] in self?.refresh() }
        handler.allowsAutomation = { [weak self] in self?.license.allowsAutomation ?? false }
        handler.savedScenario = { [weak self] name in
            let matching = self?.scenarios.scenarios.filter { $0.name == name } ?? []
            return matching.count == 1 ? matching[0] : nil
        }
        let server = AutomationServer(settings: settings, handler: handler)
        server.onStateChange = { [weak self] state in self?.automationState = state }
        automationServer = server
        server.start()
    }

    private func updateDeviceSettings(_ change: (inout DeviceSettings) -> Void) throws {
        guard let vault = repository?.vault else { return }
        var updated = deviceSettings
        change(&updated)
        if deviceSettingsUnreadable {
            // Kept beside, not written over (`deviceSettingsUnreadable`).
            try DeviceSettings.moveUnreadableAside(in: vault)
            deviceSettingsUnreadable = false
        }
        try updated.save(to: vault)
        deviceSettings = updated
    }

    // MARK: Updates (docs/UPDATES.md)

    /// Once, when the app's window first appears — never in the self-test, the snapshots or a
    /// profile's own process: the updater of a build with a feed, its automatic checks when they
    /// are on, and what became of the last update when it was not installed.
    func startUpdates() {
        guard !updatesStarted else { return }
        updatesStarted = true
        guard let configuration = AppUpdater.Configuration.main() else { return }
        let updater = AppUpdater(configuration: configuration)
        self.updater = updater
        updater.start()
        switch updater.notice {
        case .outcome(let outcome)?:
            switch outcome.result {
            case .installed: updatedTo = outcome.version // and the Updates section says when
            case .rolledBack: showError(String(format: L("updates.notice.rolledBack"), outcome.version, outcome.detail))
            case .refused: showError(String(format: L("updates.notice.refused"), outcome.version, outcome.detail))
            case .gaveUp: showError(String(format: L("updates.notice.gaveUp"), outcome.version, outcome.detail))
            }
        case .deferred(let reason)?:
            showError(String(format: L("updates.notice.deferred"), reason))
        case nil:
            break
        }
    }

    /// The check at the end of the quit under way, with what that quit had to kill.
    private func updateGate(forcedExitsBefore: Int?) -> UpdateGate.Verdict {
        UpdateGate.check(vaultRoot: root, hasActivity: hasActivity,
                         forcedExits: ProfileProcess.forcedExits - (forcedExitsBefore ?? ProfileProcess.forcedExits))
    }

    /// At the end of a quit that sealed every profile (`QuitCoordinator`): the gate, then the
    /// installer. Whatever stops it is said at the next launch; the app quits either way.
    func installUpdateAtQuit() async {
        guard let updater, updater.isReady else { return }
        switch await updater.installAtQuit(gate: updateGate(forcedExitsBefore: forcedExitsBeforeQuit)) {
        case .started, .nothingReady: break
        case .refused(let reasons): updater.rememberNotInstalled(reasons.joined(separator: "; "))
        case .blocked: break // the Updates sheet says where the app has to be
        case .failed(let reason): updater.rememberNotInstalled(reason)
        }
    }

    /// "Install Now": the quit path, asked for here — every profile stopped and sealed (the vault
    /// locked) — then the gate. If it does not pass, the app does not quit: it stays locked, says
    /// why, and keeps the update for the next quit.
    func installUpdateNow() async {
        guard let updater, updater.isReady, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        defer { isInstallingUpdate = false }
        let before = ProfileProcess.forcedExits
        await lock(forQuit: true)
        switch await updater.installAtQuit(gate: updateGate(forcedExitsBefore: before)) {
        case .started:
            NSApp.terminate(nil)
        case .refused(let reasons):
            showError(String(format: L("updates.now.refused"), reasons.joined(separator: "\n")))
        case .blocked:
            showError(L("updates.now.blocked"))
        case .failed(let reason):
            showError(String(format: L("updates.now.failed"), reason))
        case .nothingReady:
            break
        }
    }

    /// What a quit would stop now, one line per profile, for Install Now's confirmation.
    func updateStopsList() -> [String] {
        guard let manager else { return [] }
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return manager.activity().map { entry in
            let name = names[entry.id] ?? entry.id.uuidString
            switch entry.activity {
            case .window(ownProcess: true): return String(format: L("updates.stops.ownProcess"), name)
            case .window(ownProcess: false): return String(format: L("updates.stops.window"), name)
            case .warmUpOnly: return String(format: L("updates.stops.warmUp"), name)
            case .busy: return String(format: L("updates.stops.busy"), name)
            }
        }.sorted()
    }

    // MARK: Helpers

    /// Shows `message` in the error alert. What arrives while it is up is shown with it (a launch
    /// can report several things at once: an exit-IP change, a new time zone, a language note),
    /// not instead of it; a message already shown is not repeated, and the latest few are kept.
    func showError(_ message: String) {
        var shown = errorMessage?.components(separatedBy: "\n\n") ?? []
        guard !shown.contains(message) else { return }
        shown.append(message)
        errorMessage = shown.suffix(5).joined(separator: "\n\n")
    }

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            showError(errorText(error))
        }
    }
}

/// What the Profiles list shows about a profile beyond its summary, read from its encrypted
/// configuration when the list refreshes (one small decryption per profile).
struct ProfileDetails: Equatable {
    /// "host:port" of its proxy; nil when it connects directly.
    var proxyEndpoint: String?
    /// Which proxy of the list it uses (`ProxyList.identity(of:)`): the Proxies section counts them.
    var proxyIdentity: String?
    /// Where the proxy was last seen exiting (ISO 3166-1 alpha-2), when a lookup found it.
    var exitCountryCode: String?
    var ephemeral: Bool
    var deviceGeneration: DeviceGeneration
    /// The Safari version its settings pin (`ProfileConfiguration.safariVersion`); nil: this Mac's.
    var safariVersion: String?
    /// The person's own tags and notes, and how the glyph looks.
    var tags: [String]
    var notes: String
    var avatar: ProfileAvatarStyle?
    // What the inspector says of how it reaches the web and how sites see it.
    /// "SOCKS5", "HTTP", "HTTPS": the proxy's kind, as the proxy list names it.
    var proxyKind: String?
    /// A SOCKS5 proxy: the kind that can carry UDP, so WebRTC through the app's relay.
    var proxyCarriesUDP: Bool
    /// The address sites saw it come from at its last launch through its proxy, when known.
    var exitIP: String?
    var timeZone: String
    /// The WebRTC choice stored; what it amounts to with a proxy depends on the gate at launch
    /// (`ProfileConfiguration.webRTCRouting`), which the inspector says as the editor does.
    var webRTCChoice: WebRTCPolicy
    /// It would carry WebRTC through its SOCKS5 proxy if the network guard worked
    /// (`WebRTCProtectionNotice`): the profiles window says when the guard does not.
    var wantsNetworkGuard: Bool
    var languages: String
    var window: String
    var syncsCookies: Bool
    var historyPolicy: HistoryStore.Policy

    init(_ configuration: ProfileConfiguration) {
        proxyEndpoint = configuration.proxy.map { "\($0.host):\($0.port)" }
        proxyIdentity = configuration.proxy.map(ProxyList.identity(of:))
        exitCountryCode = configuration.rememberedProxyLocation?.countryCode
        ephemeral = configuration.ephemeral
        deviceGeneration = configuration.deviceGeneration
        safariVersion = configuration.safariVersion
        tags = configuration.tags
        notes = configuration.notes
        avatar = configuration.avatar
        proxyKind = configuration.proxy.map { ProxyReport.kindName($0.kind, tls: $0.tlsToProxy) }
        proxyCarriesUDP = configuration.proxy?.kind == .socks5
        exitIP = configuration.rememberedProxyLocation?.exitIP
        if let zone = configuration.timeZoneIdentifier {
            timeZone = zone
        } else if configuration.needsProxyLocation {
            let direct = configuration.proxy == nil
            timeZone = configuration.rememberedProxyLocation.map {
                String(format: L(direct ? "inspector.timeZone.fromExit" : "inspector.timeZone.fromProxy"), $0.timeZoneIdentifier)
            } ?? L(direct ? "inspector.fromExit" : "inspector.fromProxy")
        } else {
            timeZone = L("inspector.asThisMac")
        }
        webRTCChoice = configuration.webRTCPolicy
        wantsNetworkGuard = WebRTCProtectionNotice.wants(proxyKind: configuration.proxy?.kind, webRTC: configuration.webRTCPolicy)
        // Nil: the connection's — its proxy's country when the profile follows it — else this Mac's.
        languages = configuration.languageOverride
            ?? (configuration.needsProxyLocation
                ? L(configuration.proxy == nil ? "inspector.languages.fromExit" : "inspector.languages.fromProxy")
                : L("inspector.asThisMac"))
        window = configuration.windowSize.map { "\($0.frame.width) × \($0.frame.height)" } ?? L("editor.window.app")
        syncsCookies = configuration.syncsCookies
        historyPolicy = configuration.historyPolicy
    }
}
