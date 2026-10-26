import AppKit
import BrowserCore
import Combine
import Foundation

/// Sheets of the Profiles window.
enum ProfileSheet: Identifiable, Equatable {
    case newProfile
    case edit(UUID)
    case rename(UUID)
    case passwords(UUID)
    case exportProfile(UUID)
    case importProfile(URL)
    case changePassword

    var id: String {
        switch self {
        case .newProfile: return "new"
        case .edit(let id): return "edit-\(id)"
        case .rename(let id): return "rename-\(id)"
        case .passwords(let id): return "passwords-\(id)"
        case .exportProfile(let id): return "export-\(id)"
        case .importProfile(let url): return "import-\(url.path)"
        case .changePassword: return "changePassword"
        }
    }
}

/// App-level state: vault lock state, profile list, proxy status, and the profile manager.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case setup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var profiles: [ProfileSummary] = []
    /// Each profile's settings, for the sidebar and the profile page (decrypted on refresh with
    /// keys the unlocked vault already holds; dropped on lock).
    @Published private(set) var configurations: [UUID: ProfileConfiguration] = [:]
    @Published private(set) var isWorking = false
    @Published var alert: AppAlert?
    /// A short confirmation ("12 cookies imported") shown under the profile page's header.
    @Published var notice: String?
    @Published var selectedProfileID: UUID?
    /// The sheet the Profiles window shows (editor, rename, export password…), settable from
    /// menus as well as from the window.
    @Published var sheet: ProfileSheet?
    @Published var pendingDelete: UUID?
    @Published private(set) var deviceSettings = DeviceSettings()

    let proxyStatus = ProxyStatusCenter()
    private(set) var repository: ProfileRepository?
    private(set) var manager: ProfileManager?
    private var observations: [AnyCancellable] = []

    /// The main Profiles window (SwiftUI `Window` scene), captured via `WindowReader`. Brought
    /// back to the front when a profile's windows all close, and on dock reopen.
    weak var profilesWindow: NSWindow?

    /// See `AppEnvironment.vaultDirectory` (inside the container when sandboxed).
    let root: URL

    init() {
        root = AppEnvironment.vaultDirectory
        phase = MasterVault.exists(in: root) ? .locked : .setup
        proxyStatus.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    var hasRunningProfiles: Bool { manager?.hasRunningProfiles ?? false }

    /// Brings the Profiles window to the front (e.g. after closing a profile, or on dock reopen).
    func activateProfilesWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = profilesWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func show(_ error: Error, titleKey: String? = nil) {
        Log.error("ui", "\(titleKey ?? "error"): \(Log.describe(error))")
        if let alert = ErrorPresenter.alert(for: error, titleKey: titleKey) { self.alert = alert }
    }

    // MARK: Vault

    func createVault(password: String) async {
        let root = root
        await perform(titleKey: "error.title.createVault") {
            // PBKDF2 with 600k iterations takes ~0.5 s; keep it off the main thread.
            let vault = try await Task.detached(priority: .userInitiated) {
                try MasterVault.create(in: root, password: password)
            }.value
            Log.info("vault", "created")
            try self.didUnlock(vault)
        }
    }

    func unlock(password: String) async {
        let root = root
        await perform(titleKey: "error.title.unlock") {
            let vault = try await Task.detached(priority: .userInitiated) {
                try MasterVault.unlock(in: root, password: password)
            }.value
            Log.info("vault", "unlocked")
            try self.didUnlock(vault)
        }
    }

    private func didUnlock(_ vault: UnlockedVault) throws {
        let repository = try ProfileRepository(vault: vault)
        repository.removeOrphanedDirectories()
        let manager = ProfileManager(repository: repository, proxyCenter: proxyStatus)
        manager.onError = { [weak self] error in self?.show(error) }
        manager.onReturnToProfiles = { [weak self] in
            self?.activateProfilesWindow()
            self?.refresh()
        }
        manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.repository = repository
        self.manager = manager
        deviceSettings = (try? DeviceSettings.load(from: vault)) ?? DeviceSettings()
        phase = .unlocked
        refresh()
        if selectedProfileID == nil { selectedProfileID = profiles.first?.id }
        Task { await manager.recoverUnsealedProfiles() }
    }

    /// Stops (and seals) every running profile, then forgets all keys.
    func lock() async {
        await manager?.stopAll()
        observations.removeAll()
        proxyStatus.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        manager = nil
        repository = nil
        profiles = []
        configurations = [:]
        notice = nil
        deviceSettings = DeviceSettings()
        phase = MasterVault.exists(in: root) ? .locked : .setup
        Log.info("vault", "locked")
    }

    func changePassword(current: String, new: String) async -> Bool {
        guard let vault = repository?.vault else { return false }
        var changed = false
        await perform(titleKey: "error.title.changePassword") {
            try await Task.detached(priority: .userInitiated) {
                try vault.changePassword(current: current, new: new)
            }.value
            changed = true
            Log.info("vault", "master password changed")
        }
        return changed
    }

    // MARK: Profiles

    /// Re-reads the list and each profile's settings.
    func refresh() {
        guard let repository else {
            profiles = []
            configurations = [:]
            return
        }
        profiles = repository.list()
        var loaded: [UUID: ProfileConfiguration] = [:]
        for profile in profiles {
            if let configuration = try? repository.loadConfiguration(profile.id) { loaded[profile.id] = configuration }
        }
        configurations = loaded
        if let selected = selectedProfileID, !profiles.contains(where: { $0.id == selected }) {
            selectedProfileID = profiles.first?.id
        }
    }

    func summary(_ id: UUID) -> ProfileSummary? { profiles.first { $0.id == id } }

    func proxyState(_ id: UUID) -> ProxyStatus {
        proxyStatus.status(for: id, hasProxy: configurations[id]?.proxy != nil)
    }

    @discardableResult
    func createProfile(name: String, configuration: ProfileConfiguration) throws -> ProfileSummary? {
        guard let repository else { return nil }
        let summary = try repository.create(name: name, configuration: configuration)
        Log.info("profiles", "created \(Log.id(summary.id))")
        refresh()
        selectedProfileID = summary.id
        return summary
    }

    func configuration(for id: UUID) throws -> ProfileConfiguration {
        guard let repository else { throw CoreError.vaultNotFound }
        return try repository.loadConfiguration(id)
    }

    /// Changes take effect the next time the profile is launched.
    func updateProfile(_ id: UUID, name: String, configuration: ProfileConfiguration) throws {
        guard let repository else { return }
        let previous = try? repository.loadConfiguration(id)
        try repository.saveConfiguration(configuration, for: id)
        if try repository.summary(for: id).name != name {
            try repository.rename(id, to: name)
        }
        if previous?.proxy != configuration.proxy { proxyStatus.forget(id) }
        Log.info("profiles", "updated \(Log.id(id))")
        refresh()
    }

    func rename(_ id: UUID, to name: String) {
        do {
            try repository?.rename(id, to: name)
            refresh()
        } catch {
            show(error, titleKey: "error.title.rename")
        }
    }

    /// Same settings (and bookmarks), new empty data: cookies, history and passwords stay with
    /// the original.
    func duplicate(_ id: UUID) {
        guard let repository, let source = summary(id) else { return }
        do {
            let copy = try repository.duplicate(id, name: String(format: L("profiles.copyName"), source.name))
            Log.info("profiles", "duplicated \(Log.id(id)) as \(Log.id(copy.id))")
            refresh()
            selectedProfileID = copy.id
        } catch {
            show(error, titleKey: "error.title.duplicate")
        }
    }

    func deleteProfile(_ id: UUID) async {
        await perform(titleKey: "error.title.delete") { try await self.manager?.delete(id) }
        refresh()
    }

    func launch(_ id: UUID) async {
        await perform(titleKey: "error.title.launch") { try await self.manager?.launch(id) }
        refresh()
    }

    func stop(_ id: UUID) async {
        await perform(titleKey: "error.title.stop") { try await self.manager?.stop(id) }
    }

    func isRunning(_ id: UUID) -> Bool { manager?.runningProfileIDs.contains(id) ?? false }
    func isBusy(_ id: UUID) -> Bool { manager?.busyProfileIDs.contains(id) ?? false }

    func passwordVault(for id: UUID) throws -> PasswordVault {
        guard let manager else { throw CoreError.vaultNotFound }
        return try manager.passwordVault(for: id)
    }

    // MARK: Proxy

    /// Checks the saved proxy of a profile and updates its status.
    func checkProxy(_ id: UUID) async {
        guard let proxy = configurations[id]?.proxy else { return }
        await proxyStatus.check(id, settings: proxy)
    }

    // MARK: Cookies

    /// Imports a cookies.txt / JSON file into the profile, starting it if needed (cookies can
    /// only enter through the running profile's WebKit store).
    func importCookies(_ id: UUID, from url: URL) async {
        await perform(titleKey: "error.title.importCookies") {
            let data = try Self.readUserFile(url)
            if self.manager?.session(for: id) == nil { try await self.manager?.launch(id) }
            guard let store = self.manager?.session(for: id)?.dataStore?.httpCookieStore else { return }
            let result = try await CookieService.importCookies(data, into: store)
            self.notice = result.skipped > 0
                ? String(format: L("cookies.imported.skipped"), result.imported, result.skipped)
                : String(format: L("cookies.imported"), result.imported)
        }
        refresh()
    }

    func exportCookies(_ id: UUID, to url: URL, format: CookieFormat) async {
        await perform(titleKey: "error.title.exportCookies") {
            if self.manager?.session(for: id) == nil { try await self.manager?.launch(id) }
            guard let store = self.manager?.session(for: id)?.dataStore?.httpCookieStore else { return }
            let (data, count) = try await CookieService.exportCookies(from: store, format: format)
            try Self.writeUserFile(data, to: url)
            self.notice = String(format: L("cookies.exported"), count)
        }
        refresh()
    }

    // MARK: Profile export / import

    /// Writes a password-protected file with everything of the profile (settings, cookies and
    /// site data, history, bookmarks, passwords). The profile is stopped first: its website
    /// data is only complete and encrypted then.
    func exportProfile(_ id: UUID, to url: URL, password: String) async {
        guard let repository else { return }
        await perform(titleKey: "error.title.exportProfile") {
            if self.manager?.isRunning(id) == true { try await self.manager?.stop(id) }
            let info = try await Task.detached(priority: .userInitiated) {
                try Self.accessingUserFile(url) {
                    try ProfileBackup.export(profile: id, from: repository, to: url, password: password)
                }
            }.value
            Log.info("profiles", "exported \(Log.id(id)): \(info.fileCount) files")
            self.notice = L("backup.exported")
        }
    }

    /// Restores a profile file. A profile that already exists here (same id) comes back as a copy.
    func importProfile(from url: URL, password: String) async {
        guard let repository else { return }
        await perform(titleKey: "error.title.importProfile") {
            let summary = try await Task.detached(priority: .userInitiated) {
                try Self.accessingUserFile(url) {
                    try ProfileBackup.restore(from: url, password: password, into: repository, mode: .automatic)
                }
            }.value
            Log.info("profiles", "imported \(Log.id(summary.id))")
            self.refresh()
            self.selectedProfileID = summary.id
            self.notice = String(format: L("backup.imported"), summary.name)
        }
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
            show(error, titleKey: "error.title.sync")
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
            show(error, titleKey: "error.title.sync")
        }
    }

    func clearSyncTarget() {
        do {
            try updateDeviceSettings { $0.syncTarget = nil }
        } catch {
            show(error, titleKey: "error.title.sync")
        }
    }

    /// Only allowed while no profile is running, because incoming changes replace files on disk.
    func syncNow() async {
        guard let repository, let manager, let target = deviceSettings.syncTarget else { return }
        guard !manager.hasRunningProfiles else {
            alert = ErrorPresenter.alert(titleKey: "error.title.sync", messageKey: "sync.stopProfilesFirst")
            return
        }
        isWorking = true
        defer { isWorking = false }
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
            Log.info("sync", "done: pushed \(status.pushed), pulled \(status.pulled), merged \(status.merged)")
        } catch {
            let shown = ErrorPresenter.alert(for: error, titleKey: "error.title.sync")
            status = DeviceSettings.SyncStatus(error: shown?.message ?? Log.describe(error))
            show(error, titleKey: "error.title.sync")
        }
        try? updateDeviceSettings { $0.lastSync = status }
        refresh()
    }

    private func updateDeviceSettings(_ change: (inout DeviceSettings) -> Void) throws {
        guard let vault = repository?.vault else { return }
        var updated = deviceSettings
        change(&updated)
        try updated.save(to: vault)
        deviceSettings = updated
    }

    // MARK: Helpers

    private func perform(titleKey: String, _ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            show(error, titleKey: titleKey)
        }
    }

    /// Files the user picked in an open/save panel. Inside the App Sandbox the panel grants access
    /// to exactly that file; security-scoped access is harmless when it isn't needed.
    nonisolated static func accessingUserFile<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    nonisolated static func readUserFile(_ url: URL, maxBytes: Int = 10 * 1024 * 1024) throws -> Data {
        try accessingUserFile(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBytes else { throw CoreError.invalidConfiguration("file is larger than 10 MB") }
            return try Data(contentsOf: url)
        }
    }

    nonisolated static func writeUserFile(_ data: Data, to url: URL) throws {
        try accessingUserFile(url) { try data.write(to: url, options: .atomic) }
    }
}
