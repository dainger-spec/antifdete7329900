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

    private(set) var repository: ProfileRepository?
    private(set) var manager: ProfileManager?
    private var managerObservation: AnyCancellable?

    /// `~/Library/Application Support/PrivacyBrowser` (override with PRIVACYBROWSER_VAULT_DIR).
    let root: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["PRIVACYBROWSER_VAULT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PrivacyBrowser", isDirectory: true)
        }
        phase = MasterVault.exists(in: root) ? .locked : .setup
    }

    var hasRunningProfiles: Bool { manager?.hasRunningProfiles ?? false }

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
        let root = root
        await perform {
            let vault = try await Task.detached(priority: .userInitiated) {
                try MasterVault.unlock(in: root, password: password)
            }.value
            try self.didUnlock(vault)
        }
    }

    private func didUnlock(_ vault: UnlockedVault) throws {
        let repository = try ProfileRepository(vault: vault)
        repository.removeOrphanedDirectories()
        let manager = ProfileManager(repository: repository)
        manager.onError = { [weak self] message in self?.errorMessage = message }
        managerObservation = manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.repository = repository
        self.manager = manager
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

    /// Syncs with a folder used as a dumb blob store (see LocalDirectorySyncTransport).
    /// Only allowed while no profile is running, because incoming changes replace files on disk.
    func sync(withFolder folder: URL) async {
        guard let repository, let manager else { return }
        guard !manager.hasRunningProfiles else {
            errorMessage = "Stop all profiles before syncing."
            return
        }
        await perform {
            let engine = SyncEngine(repository: repository, transport: LocalDirectorySyncTransport(directory: folder))
            let report = try await engine.sync()
            for id in report.deletedProfileIDs {
                await manager.removeWebData(for: id)
            }
            self.refresh()
        }
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
