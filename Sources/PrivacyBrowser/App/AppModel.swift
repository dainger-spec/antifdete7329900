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
    /// A profile whose password manager should open (from "Passwords…" in a browser window).
    @Published var passwordsRequest: ProfileSummary?
    /// Profiles that were started with a proxy that does not work, and what the probe found
    /// (`ProfileManager.onProxyProblem`): the Profiles window says it in words, with Check.
    @Published var proxyProblems: [ProxyProblem] = []
    /// The last unlock attempt failed with a wrong password (the unlock screen then shows which
    /// vault it tried).
    @Published private(set) var unlockFailed = false
    /// Where `startOver()` moved the previous vault (shown on the setup screen).
    @Published private(set) var movedAsideVaultPath: String?
    @Published private(set) var deviceSettings = DeviceSettings()
    /// The app's own settings (Settings…, ⌘,).
    let settings = AppSettings()
    /// The Proxies sheet is asked for from outside the Profiles window (Settings → Proxies).
    @Published var proxiesRequest = false
    /// The command palette (⌘K) is open in the Profiles window.
    @Published var showingPalette = false
    /// A section of Settings to show when it next appears (the command palette).
    @Published var settingsSection: SettingsSection?
    /// This quit has recorded the profiles to reopen (a quit locks in more than one round).
    private var recordedProfilesToReopen = false

    private(set) var repository: ProfileRepository?
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

    init() {
        // Before the vault is looked for: a vault a sandboxed build of this app left in its
        // container is this build's to use (an unsandboxed build hosts Safari's chrome).
        AppEnvironment.adoptSandboxedDataIfNeeded()
        root = AppEnvironment.vaultDirectory
        phase = MasterVault.exists(in: root) ? .locked : .setup
        // No profile's page is handed to Quick Look, Services or another app (`HandOffs`).
        HandOffs.closeForWebViews()
        // Profiles in processes of their own get changed browsing settings at once.
        settings.onBrowsingChange = { [weak self] preferences in self?.manager?.sendPreferences(preferences) }
    }

    /// Settings → Proxies → the list: the Profiles window opens its Proxies sheet.
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
        let root = root
        await perform {
            // Argon2id (64 MiB, 3 passes) takes a fraction of a second; keep it off the main thread.
            let vault = try await Task.detached(priority: .userInitiated) {
                try MasterVault.create(in: root, password: password)
            }.value
            try self.didUnlock(vault)
        }
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
        }
    }

    /// For the unlock screen after a wrong password: when the vault this build opens was created
    /// (from its plaintext header). A sandboxed `.app`, an unsandboxed build (`swift run`,
    /// `SANDBOX=0`) and a build with another bundle id each open their own vault folder, so a
    /// password set in one of them is "wrong" in another.
    var vaultCreatedDescription: String {
        guard let header = try? MasterVault.readHeader(in: root) else { return "?" }
        return header.createdAt.formatted(date: .abbreviated, time: .shortened)
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
            showError((error as? CoreError)?.description ?? error.localizedDescription)
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let path = url.path
        if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }), path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func didUnlock(_ vault: UnlockedVault) throws {
        let repository = try ProfileRepository(vault: vault)
        repository.removeOrphanedDirectories()
        let manager = ProfileManager(repository: repository)
        manager.onError = { [weak self] message in self?.showError(message) }
        manager.onReturnToProfiles = { [weak self] in
            self?.activateProfilesWindow()
            self?.refresh()
        }
        manager.onConfigurationChanged = { [weak self] _ in self?.refresh() }
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
        manager.onProxyLaunchRefused = { [weak self] id, proxy, diagnosis in
            self?.reportProxyProblem(of: id, proxy: proxy, diagnosis: diagnosis, notStarted: true)
        }
        do {
            deviceSettings = try DeviceSettings.load(from: vault)
        } catch {
            deviceSettings = DeviceSettings()
            // A newer version's settings are neither shown nor saved over (the save refuses):
            // said once, rather than showing defaults as if they were this device's settings.
            if case CoreError.newerFormat = error { showError(errorText(error)) }
        }
        restartAutomation()
        phase = .unlocked
        refresh()
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
        managerObservation = nil
        manager = nil
        repository = nil
        profiles = []
        details = [:]
        deviceSettings = DeviceSettings()
        phase = MasterVault.exists(in: root) ? .locked : .setup
    }

    func changePassword(current: String, new: String) async {
        guard let vault = repository?.vault else { return }
        await perform {
            try await Task.detached(priority: .userInitiated) {
                try vault.changePassword(current: current, new: new)
            }.value
        }
    }

    // MARK: Profiles

    func refresh() {
        profiles = repository?.list() ?? []
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
        let summary = try repository.create(name: name, configuration: configuration)
        refresh()
        return summary.id
    }

    func configuration(for id: UUID) throws -> ProfileConfiguration {
        guard let repository else { throw CoreError.vaultNotFound }
        return try repository.loadConfiguration(id)
    }

    /// Changes take effect the next time the profile is launched.
    func updateProfile(_ id: UUID, name: String, configuration: ProfileConfiguration) throws {
        guard let repository else { return }
        let stored = try? repository.loadConfiguration(id)
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
        let summary = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ProfileTransfer.importProfile(from: url, password: password, into: repository, name: name)
        }.value
        refresh()
        return summary
    }

    func deleteProfile(_ id: UUID) async {
        await perform { try await self.manager?.delete(id) }
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

    /// The profile's last warm-up plan, or a new one.
    func warmUpPlan(for id: UUID) -> WarmUpPlan {
        (try? repository?.warmUpPlan(for: id)) ?? WarmUpPlan()
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
            showError("Could not remember the sync folder: \(error.localizedDescription)")
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
            showError((error as? CoreError)?.description ?? error.localizedDescription)
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
            showError("Stop all profiles before syncing.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        isSyncing = true
        defer { isSyncing = false }
        // A profile still starting or being encrypted reads and writes its synced cookies: after it.
        await manager.waitWhileBusy()
        guard !manager.hasRunningProfiles else {
            showError("Stop all profiles before syncing.")
            return
        }
        var scopedFolder: URL?
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }
        let status: DeviceSettings.SyncStatus
        do {
            let transport: SyncTransport
            switch target {
            case let .folder(bookmark, _):
                var stale = false
                let folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
                if folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
                if stale { setSyncFolder(folder) }
                transport = LocalDirectorySyncTransport(directory: folder)
            case let .server(baseURL, token):
                transport = try HTTPSyncTransport(configuration: .init(baseURL: baseURL, vaultID: repository.vault.vaultID,
                                                                       bearerToken: token))
            }
            let report = try await SyncEngine(repository: repository, transport: transport).sync()
            for id in report.deletedProfileIDs {
                await manager.removeWebData(for: id)
            }
            status = DeviceSettings.SyncStatus(report: report)
        } catch {
            let message = errorText(error)
            status = DeviceSettings.SyncStatus(error: message)
            showError("Sync failed: \(message)")
        }
        try? updateDeviceSettings { $0.lastSync = status }
        refresh()
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
        let server = AutomationServer(settings: settings, handler: handler)
        server.onStateChange = { [weak self] state in self?.automationState = state }
        automationServer = server
        server.start()
    }

    private func updateDeviceSettings(_ change: (inout DeviceSettings) -> Void) throws {
        guard let vault = repository?.vault else { return }
        var updated = deviceSettings
        change(&updated)
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
            case .installed: break // the Updates sheet says which update this launch is
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
    /// Which proxy of the list it uses (`ProxyList.identity(of:)`): the Proxies sheet counts them.
    var proxyIdentity: String?
    /// Where the proxy was last seen exiting (ISO 3166-1 alpha-2), when a lookup found it.
    var exitCountryCode: String?
    var ephemeral: Bool
    var deviceGeneration: DeviceGeneration
    /// The person's own tags and notes, and how the glyph looks.
    var tags: [String]
    var notes: String
    var avatar: ProfileAvatarStyle?

    init(_ configuration: ProfileConfiguration) {
        proxyEndpoint = configuration.proxy.map { "\($0.host):\($0.port)" }
        proxyIdentity = configuration.proxy.map(ProxyList.identity(of:))
        exitCountryCode = configuration.rememberedProxyLocation?.countryCode
        ephemeral = configuration.ephemeral
        deviceGeneration = configuration.deviceGeneration
        tags = configuration.tags
        notes = configuration.notes
        avatar = configuration.avatar
    }
}
