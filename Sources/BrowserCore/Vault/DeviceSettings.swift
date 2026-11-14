import Foundation

/// Settings that belong to this device and vault, not to a profile, and are never synced:
/// where to sync to, the outcome of the last sync, and the local automation API's. Stored as `settings.bin`,
/// AES-GCM with `HKDF(VMK, "device-settings")` — the sync token and folder location are
/// therefore only readable after unlock.
public struct DeviceSettings: Codable, Equatable, Sendable {
    /// Stored as Swift codes an enum: `{"folder": {"bookmark", "path"}}`, `{"server": {"baseURL",
    /// "token"}}`, `{"account": {}}` — a case added does not change how the others read.
    public enum SyncTarget: Codable, Equatable, Sendable {
        /// A folder chosen by the user. `bookmark` is a security-scoped bookmark (needed to
        /// regain access inside the App Sandbox after relaunch); `path` is for display only.
        case folder(bookmark: Data, path: String)
        /// A server implementing docs/SYNC_SERVER_API.md: the person's own, its address and token typed in.
        case server(baseURL: URL, token: String)
        /// The Lumen account's server (`PBAccountServerURL`), reached with this Mac's device token
        /// (`AccountRecord.deviceToken`, the account server's CONTRACT §16.1; `AccountSync`). Only the
        /// choice is kept here: the address is the build's, and the token stays the license's — it goes
        /// with a sign-out, and the sync waits for the next sign-in.
        case account
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
        /// Of the deferred: refused by the server for the plan's sync space (507), and for their size
        /// (413). Nil when none, and in a status from before they were kept.
        public var overQuota: Int?
        public var tooLarge: Int?
        /// The Lumen server holds sync on this device until then (`403 sync_on_hold`, CONTRACT §16.1):
        /// it is not asked again before.
        public var heldUntil: Date?

        public init(date: Date = Date(), report: SyncReport) {
            self.date = date
            pushed = report.pushed.count
            pulled = report.pulled.count
            merged = report.merged.count
            conflicts = report.resolvedConflicts.count
            deferred = report.deferred.count
            error = nil
            passwordHeader = report.passwordHeader == .same ? nil : report.passwordHeader
            overQuota = report.deferredOverQuota.isEmpty ? nil : report.deferredOverQuota.count
            tooLarge = report.deferredTooLarge.isEmpty ? nil : report.deferredTooLarge.count
        }

        public init(date: Date = Date(), error: String, heldUntil: Date? = nil) {
            self.date = date
            pushed = 0; pulled = 0; merged = 0; conflicts = 0; deferred = 0
            self.error = error
            self.heldUntil = heldUntil
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

    private enum CodingKeys: String, CodingKey {
        case format, syncTarget, lastSync, automation, reopenAtUnlock
    }

    /// The newest format of `settings.bin` this version reads and writes.
    static let supportedFormat = 2

    /// The format these settings are written in: 1 — no marker, as every version before wrote them —
    /// but 2 while the target is the Lumen account, a case a version from before it cannot read: that
    /// version then refuses the file as a newer version's and leaves it as it is, rather than take it
    /// for a damaged one (docs/UPDATES.md §4).
    var format: Int { syncTarget == .account ? 2 : 1 }

    public init(from decoder: Decoder) throws {
        // A newer one is refused before this, by the file (`EncryptedDocumentFile.supportedFormat`).
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syncTarget = try c.decodeIfPresent(SyncTarget.self, forKey: .syncTarget)
        lastSync = try c.decodeIfPresent(SyncStatus.self, forKey: .lastSync)
        automation = try c.decodeIfPresent(AutomationSettings.self, forKey: .automation)
        reopenAtUnlock = try c.decodeIfPresent([UUID].self, forKey: .reopenAtUnlock)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if format > 1 { try c.encode(format, forKey: .format) }
        try c.encodeIfPresent(syncTarget, forKey: .syncTarget)
        try c.encodeIfPresent(lastSync, forKey: .lastSync)
        try c.encodeIfPresent(automation, forKey: .automation)
        try c.encodeIfPresent(reopenAtUnlock, forKey: .reopenAtUnlock)
    }
}

extension DeviceSettings {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<DeviceSettings> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("settings.bin"), key: try vault.settingsKey,
                              aad: "device-settings:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
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
