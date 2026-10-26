import AppKit
import BrowserCore
import Combine
import Foundation

/// App-level state: vault lock state, profile list, and the profile manager.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case setup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var profiles: [ProfileSummary] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    /// The last unlock attempt failed with a wrong password (the unlock screen then shows which
    /// vault it tried).
    @Published private(set) var unlockFailed = false
    @Published private(set) var deviceSettings = DeviceSettings()

    private(set) var repository: ProfileRepository?
    private(set) var manager: ProfileManager?
    private var managerObservation: AnyCancellable?

    /// The main Profiles window (SwiftUI `Window` scene), captured via `WindowReader`. Brought
    /// back to the front when a profile's windows all close, and on dock reopen.
    weak var profilesWindow: NSWindow?

    /// See `AppEnvironment.vaultDirectory` (inside the container when sandboxed).
    let root: URL

    init() {
        root = AppEnvironment.vaultDirectory
        phase = MasterVault.exists(in: root) ? .locked : .setup
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
        let root = root
        await perform {
            // PBKDF2 with 600k iterations takes ~0.5 s; keep it off the main thread.
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
                    try MasterVault.unlock(in: root, password: password)
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
        let path = root.path
        if let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }), path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func didUnlock(_ vault: UnlockedVault) throws {
        let repository = try ProfileRepository(vault: vault)
        repository.removeOrphanedDirectories()
        let manager = ProfileManager(repository: repository)
        manager.onError = { [weak self] message in self?.errorMessage = message }
        manager.onReturnToProfiles = { [weak self] in
            self?.activateProfilesWindow()
            self?.refresh()
        }
        managerObservation = manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.repository = repository
        self.manager = manager
        deviceSettings = (try? DeviceSettings.load(from: vault)) ?? DeviceSettings()
        phase = .unlocked
        refresh()
        Task { await manager.recoverUnsealedProfiles() }
    }

    /// Stops (and seals) every running profile, then forgets all keys.
    func lock() async {
        await manager?.stopAll()
        managerObservation = nil
        manager = nil
        repository = nil
        profiles = []
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
    }

    func createProfile(name: String, configuration: ProfileConfiguration) throws {
        guard let repository else { return }
        try repository.create(name: name, configuration: configuration)
        refresh()
    }

    func configuration(for id: UUID) throws -> ProfileConfiguration {
        guard let repository else { throw CoreError.vaultNotFound }
        return try repository.loadConfiguration(id)
    }

    /// Changes take effect the next time the profile is launched.
    func updateProfile(_ id: UUID, name: String, configuration: ProfileConfiguration) throws {
        guard let repository else { return }
        try repository.saveConfiguration(configuration, for: id)
        if try repository.summary(for: id).name != name {
            try repository.rename(id, to: name)
        }
        refresh()
    }

    func deleteProfile(_ id: UUID) async {
        await perform { try await self.manager?.delete(id) }
        refresh()
    }

    func launch(_ id: UUID) async {
        await perform { try await self.manager?.launch(id) }
        refresh()
    }

    func stop(_ id: UUID) async {
        await perform { try await self.manager?.stop(id) }
    }

    func isRunning(_ id: UUID) -> Bool { manager?.runningProfileIDs.contains(id) ?? false }
    func isBusy(_ id: UUID) -> Bool { manager?.busyProfileIDs.contains(id) ?? false }

    func passwordVault(for id: UUID) throws -> PasswordVault {
        guard let manager else { throw CoreError.vaultNotFound }
        return try manager.passwordVault(for: id)
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
            errorMessage = "Could not remember the sync folder: \(error.localizedDescription)"
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
            errorMessage = (error as? CoreError)?.description ?? error.localizedDescription
        }
    }

    func clearSyncTarget() {
        do {
            try updateDeviceSettings { $0.syncTarget = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Only allowed while no profile is running, because incoming changes replace files on disk.
    func syncNow() async {
        guard let repository, let manager, let target = deviceSettings.syncTarget else { return }
        guard !manager.hasRunningProfiles else {
            errorMessage = "Stop all profiles before syncing."
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
        } catch {
            let message = (error as? CoreError)?.description ?? error.localizedDescription
            status = DeviceSettings.SyncStatus(error: message)
            errorMessage = "Sync failed: \(message)"
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

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            errorMessage = (error as? CoreError)?.description ?? error.localizedDescription
        }
    }
}
