import Foundation

/// Settings that belong to this device and vault, not to a profile, and are never synced:
/// where to sync to, the outcome of the last sync, and when to lock automatically. Stored as `settings.bin`,
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

        public init(date: Date = Date(), report: SyncReport) {
            self.date = date
            pushed = report.pushed.count
            pulled = report.pulled.count
            merged = report.merged.count
            conflicts = report.resolvedConflicts.count
            deferred = report.deferred.count
            error = nil
        }

        public init(date: Date = Date(), error: String) {
            self.date = date
            pushed = 0; pulled = 0; merged = 0; conflicts = 0; deferred = 0
            self.error = error
        }
    }

    public var syncTarget: SyncTarget?
    public var lastSync: SyncStatus?
    /// Optional so that `settings.bin` written before auto-lock existed still decodes.
    public var autoLock: AutoLockSettings?

    public init(syncTarget: SyncTarget? = nil, lastSync: SyncStatus? = nil, autoLock: AutoLockSettings? = nil) {
        self.syncTarget = syncTarget
        self.lastSync = lastSync
        self.autoLock = autoLock
    }

    public var effectiveAutoLock: AutoLockSettings { autoLock ?? AutoLockSettings() }
}

/// When the app locks itself (stops and seals every profile, forgets all keys).
public struct AutoLockSettings: Codable, Equatable, Sendable {
    /// Lock after this many minutes without keyboard/mouse input anywhere on the Mac. `nil` = never.
    public var idleMinutes: Int?
    /// Lock when the Mac goes to sleep (the app holds sleep back briefly so sealing can finish).
    public var lockOnSleep: Bool
    /// Lock when the screen is locked or the screen saver starts.
    public var lockOnScreenLock: Bool

    public static let idleChoices = [1, 5, 10, 15, 30, 60, 120]

    public init(idleMinutes: Int? = 15, lockOnSleep: Bool = true, lockOnScreenLock: Bool = false) {
        self.idleMinutes = idleMinutes
        self.lockOnSleep = lockOnSleep
        self.lockOnScreenLock = lockOnScreenLock
    }

    /// True when `idleSeconds` of system-wide inactivity reach the idle limit.
    public func shouldLock(afterIdleSeconds idleSeconds: Double) -> Bool {
        guard let idleMinutes, idleMinutes > 0 else { return false }
        return idleSeconds >= Double(idleMinutes) * 60
    }
}

extension DeviceSettings {
    private static func file(for vault: UnlockedVault) -> EncryptedDocumentFile<DeviceSettings> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("settings.bin"), key: vault.settingsKey,
                              aad: "device-settings:v1:\(vault.vaultID.uuidString)")
    }

    public static func load(from vault: UnlockedVault) throws -> DeviceSettings {
        try file(for: vault).load() ?? DeviceSettings()
    }

    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
