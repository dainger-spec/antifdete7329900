import Foundation

/// Settings that belong to this device and vault, not to a profile, and are never synced:
/// where to sync to, the outcome of the last sync, and the local automation API's. Stored as `settings.bin`,
/// AES-GCM with `HKDF(VMK, "device-settings")` — the sync token and folder location are
/// therefore only readable after unlock.
public struct DeviceSettings: Codable, Equatable, Sendable {
    public enum SyncTarget: Codable, Equatable, Sendable {
        /// A folder chosen by the user. `bookmark` is a security-scoped bookmark (needed to
        /// regain access inside the App Sandbox after relaunch); `path` is for display only.
        case folder(bookmark: Data, path: String)
        /// A server implementing docs/SYNC_SERVER_API.md.
        case server(baseURL: URL, token: String)
    }

    public struct SyncStatus: Codable, Equatable, Sendable {
        public var date: Date
        public var pushed: Int
        public var pulled: Int
        public var merged: Int
        public var conflicts: Int
        public var deferred: Int
        public var error: String?
        /// Whose master password the sync location holds (`SyncReport.passwordHeader`); nil when
        /// it is this Mac's, or in a status from before it was kept.
        public var passwordHeader: SyncReport.PasswordHeader?

        public init(date: Date = Date(), report: SyncReport) {
            self.date = date
            pushed = report.pushed.count
            pulled = report.pulled.count
            merged = report.merged.count
            conflicts = report.resolvedConflicts.count
            deferred = report.deferred.count
            error = nil
            passwordHeader = report.passwordHeader == .same ? nil : report.passwordHeader
        }

        public init(date: Date = Date(), error: String) {
            self.date = date
            pushed = 0; pulled = 0; merged = 0; conflicts = 0; deferred = 0
            self.error = error
        }
    }

    public var syncTarget: SyncTarget?
    public var lastSync: SyncStatus?
    /// The local automation API (`AutomationHTTP`): nil until it is first set up.
    public var automation: AutomationSettings?
    /// The profiles that had a window when the app last quit, for the next unlock to start again
    /// (the app's Settings → Startup); used once, and kept only while that setting asks for it.
    public var reopenAtUnlock: [UUID]?

    public init(syncTarget: SyncTarget? = nil, lastSync: SyncStatus? = nil, automation: AutomationSettings? = nil,
                reopenAtUnlock: [UUID]? = nil) {
        self.syncTarget = syncTarget
        self.lastSync = lastSync
        self.automation = automation
        self.reopenAtUnlock = reopenAtUnlock
    }
}

extension DeviceSettings {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<DeviceSettings> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("settings.bin"), key: try vault.settingsKey,
                              aad: "device-settings:v1:\(vault.vaultID.uuidString)")
    }

    public static func load(from vault: UnlockedVault) throws -> DeviceSettings {
        try file(for: vault).load() ?? DeviceSettings()
    }

    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }

    /// Moves a `settings.bin` that could not be read aside — `settings.bin.unreadable`, then
    /// `.unreadable-2`, … — so that saving new settings never writes over it: it holds the sync
    /// target, the server's token and the automation token. Returns where it went (nil: no file).
    @discardableResult
    public static func moveUnreadableAside(in vault: UnlockedVault) throws -> URL? {
        let file = vault.root.appendingPathComponent("settings.bin")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try SecureFile.moveAside(file, suffix: "unreadable")
    }
}
