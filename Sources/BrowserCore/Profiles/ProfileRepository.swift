#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What is visible after unlocking the vault but before launching a profile.
public struct ProfileSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    /// Monotonic revision, bumped on every config/password change (used by sync).
    public var revision: Int
}

/// On-disk index entry: summary + the profile key wrapped under the vault's key-wrap key.
struct ProfileIndexEntry: Codable, Equatable {
    var summary: ProfileSummary
    /// AEAD(profileKeyWrappingKey, profileKey), AAD = `"profile-key:v1:<uuid>"`.
    var wrappedKey: Data
}

struct ProfileIndex: Codable, Equatable {
    var format: Int = 1
    var entries: [ProfileIndexEntry] = []
    /// IDs of deleted profiles, kept so that deletions propagate through sync
    /// instead of being resurrected by a union merge.
    var deletedProfileIDs: [UUID] = []

    /// Sync merge: union of both sides by profile ID (higher summary revision wins),
    /// minus every profile either side has deleted.
    static func merge(_ a: ProfileIndex, _ b: ProfileIndex) -> ProfileIndex {
        let deleted = Set(a.deletedProfileIDs).union(b.deletedProfileIDs)
        var byID: [UUID: ProfileIndexEntry] = [:]
        for entry in a.entries + b.entries where !deleted.contains(entry.summary.id) {
            if let existing = byID[entry.summary.id], existing.summary.revision >= entry.summary.revision {
                continue
            }
            byID[entry.summary.id] = entry
        }
        return ProfileIndex(format: 1,
                            entries: byID.values.sorted { $0.summary.createdAt < $1.summary.createdAt },
                            deletedProfileIDs: deleted.sorted { $0.uuidString < $1.uuidString })
    }
}

/// Encrypted profile storage.
///
/// Layout under the vault root:
/// ```
/// vault.json                       plaintext header (KDF params, wrapped VMK)
/// index.bin                        AEAD(indexKey, ProfileIndex JSON)
/// profiles/<uuid>/config.bin       AEAD(profileKey, ProfileConfiguration JSON)
/// profiles/<uuid>/passwords.bin    AEAD(passwordKey, [PasswordEntry] JSON)
/// profiles/<uuid>/history.bin      AEAD(historyKey, HistoryDocument JSON)
/// profiles/<uuid>/bookmarks.bin    AEAD(bookmarksKey, BookmarkDocument JSON)
/// profiles/<uuid>/webdata.pbsa     encrypted archive of the WebKit data store (app layer)
/// profiles/<uuid>/cookies-import.bin AEAD(cookieImportKey, [ImportedCookie] JSON): imported while
///                                  the profile was stopped, applied at its next launch (not synced)
/// profiles/<uuid>/cookies.bin      AEAD(cookiesKey, CookieJarDocument JSON): the persistent cookies,
///                                  synced and merged per cookie
/// profiles/<uuid>/cookies-baseline.bin AEAD(cookieBaselineKey, CookieBaseline JSON): what the cookie
///                                  store held at the last record or apply (this device only)
/// ```
/// Profile names are only readable after unlock. Profile configurations are only
/// decrypted when launched or edited.
public final class ProfileRepository: @unchecked Sendable {
    public let vault: UnlockedVault
    private let lock = NSLock()
    private var index: ProfileIndex

    public init(vault: UnlockedVault) throws {
        self.vault = vault
        self.index = ProfileIndex()
        self.index = try loadIndex()
    }

    // MARK: Paths

    public var root: URL { vault.root }
    var indexURL: URL { root.appendingPathComponent("index.bin") }
    public var profilesDirectory: URL { root.appendingPathComponent("profiles", isDirectory: true) }

    public func directory(for id: UUID) -> URL {
        profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func configURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("config.bin") }
    public func webDataArchiveURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("webdata.pbsa") }

    // MARK: Queries

    public func list() -> [ProfileSummary] {
        lock.withLock { index.entries.map(\.summary).sorted { $0.createdAt < $1.createdAt } }
    }

    public func summary(for id: UUID) throws -> ProfileSummary {
        try lock.withLock { try entry(for: id).summary }
    }

    // MARK: Mutations

    @discardableResult
    public func create(name: String, configuration: ProfileConfiguration) throws -> ProfileSummary {
        try configuration.validate()
        let cleanName = try Self.validatedName(name)
        let id = UUID()
        let profileKey = SymmetricKey(size: .bits256)
        let wrapped = try AEAD.seal(profileKey.rawBytes, key: vault.profileKeyWrappingKey, aad: Self.keyAAD(id))
        let summary = ProfileSummary(id: id, name: cleanName, createdAt: Date(), lastLaunchedAt: nil, revision: 1)

        try SecureFile.ensureDirectory(directory(for: id))
        try writeConfiguration(configuration, id: id, key: profileKey)
        try lock.withLock {
            var updated = index
            updated.entries.append(ProfileIndexEntry(summary: summary, wrappedKey: wrapped))
            try saveIndex(updated)
            index = updated
        }
        return summary
    }

    public func rename(_ id: UUID, to name: String) throws {
        let cleanName = try Self.validatedName(name)
        try mutateSummary(id) { $0.name = cleanName; $0.revision += 1 }
    }

    public func markLaunched(_ id: UUID) throws {
        try mutateSummary(id) { $0.lastLaunchedAt = Date() }
    }

    public func bumpRevision(_ id: UUID) throws {
        try mutateSummary(id) { $0.revision += 1 }
    }

    /// Removes the profile from the index and deletes its encrypted files.
    /// The caller (app layer) is responsible for removing WebKit's own data store
    /// via `WKWebsiteDataStore.remove(forIdentifier:)` first.
    public func delete(_ id: UUID) throws {
        try lock.withLock {
            var updated = index
            guard let position = updated.entries.firstIndex(where: { $0.summary.id == id }) else {
                throw CoreError.profileNotFound(id)
            }
            updated.entries.remove(at: position)
            updated.deletedProfileIDs.append(id)
            try saveIndex(updated)
            index = updated
        }
        // Index is updated first: a crash here leaves orphaned *encrypted* files,
        // which are harmless and cleaned up by `removeOrphanedDirectories()`.
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Deletes profile directories that are not referenced by the index.
    public func removeOrphanedDirectories() {
        let known = Set(list().map { $0.id.uuidString })
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: profilesDirectory.path)) ?? []
        for name in contents where !known.contains(name) && UUID(uuidString: name) != nil {
            try? FileManager.default.removeItem(at: profilesDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Keys and configuration

    /// Unwraps the profile key. Call only when launching/editing the profile and drop the
    /// returned key when done.
    public func profileKey(for id: UUID) throws -> SymmetricKey {
        let wrapped = try lock.withLock { try entry(for: id).wrappedKey }
        let raw = try AEAD.open(wrapped, key: vault.profileKeyWrappingKey, aad: Self.keyAAD(id))
        guard raw.count == 32 else { throw CoreError.corruptData("profile key length") }
        return SymmetricKey(data: raw)
    }

    public func loadConfiguration(_ id: UUID) throws -> ProfileConfiguration {
        try loadConfiguration(id, key: profileKey(for: id))
    }

    public func loadConfiguration(_ id: UUID, key: SymmetricKey) throws -> ProfileConfiguration {
        let sealed = try SecureFile.read(configURL(for: id))
        let plaintext = try AEAD.open(sealed, key: key, aad: Self.configAAD(id))
        return try JSONCoding.decoder.decode(ProfileConfiguration.self, from: plaintext)
    }

    public func saveConfiguration(_ configuration: ProfileConfiguration, for id: UUID) throws {
        try configuration.validate()
        try writeConfiguration(configuration, id: id, key: profileKey(for: id))
        try bumpRevision(id)
    }

    public func passwordVault(for id: UUID) throws -> PasswordVault {
        try PasswordVault(fileURL: passwordsURL(for: id),
                          profileID: id, profileKey: profileKey(for: id))
    }

    /// Opens the profile's encrypted history. `persistent: false` gives a memory-only store
    /// (ephemeral profiles, or history disabled) that never touches disk.
    public func historyStore(for id: UUID, key: SymmetricKey, policy: HistoryStore.Policy = .init(),
                             persistent: Bool = true) throws -> HistoryStore {
        try HistoryStore(file: HistoryStore.file(url: persistent ? historyURL(for: id) : nil, profileID: id, profileKey: key),
                         policy: policy)
    }

    public func bookmarkStore(for id: UUID, key: SymmetricKey) throws -> BookmarkStore {
        try BookmarkStore(file: BookmarkStore.file(url: bookmarksURL(for: id), profileID: id, profileKey: key))
    }

    // MARK: Imported cookies waiting for the next launch

    func importedCookiesURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookies-import.bin") }

    private func importedCookiesFile(for id: UUID) throws -> EncryptedDocumentFile<[ImportedCookie]> {
        EncryptedDocumentFile(url: importedCookiesURL(for: id),
                              key: try profileKey(for: id).derive(info: "cookie-import", salt: id.rawBytes),
                              aad: "cookie-import:v1:\(id.uuidString)")
    }

    /// Keeps cookies imported into a stopped profile until its next launch puts them into its
    /// cookie store (its website data is sealed while it is stopped). Added to those queued before;
    /// a later cookie replaces an earlier one with the same name, domain and path. Returns how
    /// many are queued now.
    @discardableResult
    public func queueImportedCookies(_ cookies: [ImportedCookie], for id: UUID) throws -> Int {
        _ = try summary(for: id)
        let file = try importedCookiesFile(for: id)
        var queued = try file.load() ?? []
        let incoming = Set(cookies.map(\.identity))
        queued.removeAll { incoming.contains($0.identity) }
        queued += cookies
        try file.save(queued)
        return queued.count
    }

    /// The cookies queued for the profile's next launch (none: empty).
    public func importedCookiesForLaunch(_ id: UUID) throws -> [ImportedCookie] {
        try importedCookiesFile(for: id).load() ?? []
    }

    /// Drops the queue once the launch has put the cookies into the profile's store.
    public func clearImportedCookies(_ id: UUID) {
        try? FileManager.default.removeItem(at: importedCookiesURL(for: id))
    }

    // MARK: Synced cookies

    func cookieJarURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookies.bin") }
    func cookieBaselineURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookies-baseline.bin") }

    static func cookieJarFile(url: URL?, profileID id: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<CookieJarDocument> {
        EncryptedDocumentFile(url: url, key: profileKey.derive(info: "cookies", salt: id.rawBytes), aad: "cookies:v1:\(id.uuidString)")
    }

    private func cookieBaselineFile(for id: UUID) throws -> EncryptedDocumentFile<CookieBaseline> {
        EncryptedDocumentFile(url: cookieBaselineURL(for: id), key: try profileKey(for: id).derive(info: "cookie-baseline", salt: id.rawBytes),
                              aad: "cookie-baseline:v1:\(id.uuidString)")
    }

    /// The profile's synced cookies (`CookieJarDocument`; empty before the first record).
    public func cookieJar(for id: UUID) throws -> CookieJarDocument {
        try Self.cookieJarFile(url: cookieJarURL(for: id), profileID: id, profileKey: profileKey(for: id)).load() ?? CookieJarDocument()
    }

    public func saveCookieJar(_ jar: CookieJarDocument, for id: UUID) throws {
        try Self.cookieJarFile(url: cookieJarURL(for: id), profileID: id, profileKey: profileKey(for: id)).save(jar)
    }

    /// What this device's store held at the last record or apply (`CookieBaseline`).
    public func cookieBaseline(for id: UUID) throws -> CookieBaseline {
        try cookieBaselineFile(for: id).load() ?? CookieBaseline()
    }

    public func saveCookieBaseline(_ baseline: CookieBaseline, for id: UUID) throws {
        try cookieBaselineFile(for: id).save(baseline)
    }

    /// Cookie sync turned off for the profile (or the profile made ephemeral): the synced
    /// document is emptied, so that sync empties it on the other devices too (their cookie stores
    /// keep what they have), and this device's baseline goes.
    public func clearSyncedCookies(for id: UUID) throws {
        try? FileManager.default.removeItem(at: cookieBaselineURL(for: id))
        guard FileManager.default.fileExists(atPath: cookieJarURL(for: id).path),
              (try? cookieJar(for: id)) != CookieJarDocument() else { return }
        try saveCookieJar(CookieJarDocument(), for: id)
    }

    // MARK: Sync support (raw encrypted files; see SyncEngine)

    func currentIndex() -> ProfileIndex {
        lock.withLock { index }
    }

    func replaceIndex(_ incoming: ProfileIndex) throws {
        guard incoming.format == 1 else { throw CoreError.unsupportedFormat("index format \(incoming.format)") }
        try lock.withLock {
            try saveIndex(incoming)
            index = incoming
        }
    }

    func passwordsURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("passwords.bin") }
    func historyURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("history.bin") }
    func bookmarksURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("bookmarks.bin") }

    func url(of file: ProfileSyncFile, for id: UUID) -> URL {
        switch file {
        case .config: return configURL(for: id)
        case .passwords: return passwordsURL(for: id)
        case .bookmarks: return bookmarksURL(for: id)
        case .history: return historyURL(for: id)
        case .cookies: return cookieJarURL(for: id)
        }
    }

    /// Sync merge of two encrypted versions of a mergeable profile file. Both are decrypted with
    /// the profile key, merged, and the result is re-encrypted.
    func mergeSyncedFile(_ file: ProfileSyncFile, profileID id: UUID, local: Data, remote: Data) throws -> Data {
        let key = try profileKey(for: id)
        switch file {
        case .bookmarks:
            let codec = BookmarkStore.file(url: nil, profileID: id, profileKey: key)
            return try codec.encode(BookmarkStore.merge(codec.decode(local), codec.decode(remote)))
        case .history:
            let codec = HistoryStore.file(url: nil, profileID: id, profileKey: key)
            let policy = (try? loadConfiguration(id, key: key))?.historyPolicy ?? .init()
            return try codec.encode(HistoryStore.merge(codec.decode(local), codec.decode(remote), policy: policy))
        case .cookies:
            let codec = Self.cookieJarFile(url: nil, profileID: id, profileKey: key)
            // Cookie sync is off (the settings just synced say so): nothing to keep.
            if let configuration = try? loadConfiguration(id, key: key), !configuration.syncsCookies {
                return try codec.encode(CookieJarDocument())
            }
            return try codec.encode(CookieJarDocument.merge(codec.decode(local), codec.decode(remote)))
        case .config, .passwords:
            throw CoreError.unsupportedFormat("\(file.rawValue) is not mergeable")
        }
    }

    /// Which of two versions of a file changed on two devices wins, for a file the newer version
    /// settles (the settings).
    struct NewerVersion: Equatable {
        var remoteWins: Bool
        /// The losing version holds settings the winner does not: kept as `<file>.conflict`.
        var keepsConflictCopy: Bool
    }

    /// For the settings changed on two devices: which version wins. The same settings on both
    /// (only what the browser keeps for itself differs, such as the proxy location found at a
    /// launch): the remote version, no copy. Different settings: the newer by
    /// `ProfileConfiguration.settingsModifiedAt` — a version with the time beats one without (not
    /// edited since it was created, or rewritten by an older build) — the other kept as a copy.
    /// Nil when that cannot be told (equal times, or neither has one).
    func newerVersion(_ file: ProfileSyncFile, profileID id: UUID, local: Data, remote: Data) throws -> NewerVersion? {
        guard file == .config else { return nil }
        let key = try profileKey(for: id)
        func decode(_ data: Data) throws -> ProfileConfiguration {
            try JSONCoding.decoder.decode(ProfileConfiguration.self, from: AEAD.open(data, key: key, aad: Self.configAAD(id)))
        }
        let localConfiguration = try decode(local), remoteConfiguration = try decode(remote)
        if localConfiguration.hasSameSettings(as: remoteConfiguration) {
            return NewerVersion(remoteWins: true, keepsConflictCopy: false)
        }
        switch (localConfiguration.settingsModifiedAt, remoteConfiguration.settingsModifiedAt) {
        case let (local?, remote?) where local != remote: return NewerVersion(remoteWins: remote > local, keepsConflictCopy: true)
        case (nil, _?): return NewerVersion(remoteWins: true, keepsConflictCopy: true)
        case (_?, nil): return NewerVersion(remoteWins: false, keepsConflictCopy: true)
        default: return nil
        }
    }

    // MARK: Private

    private func writeConfiguration(_ configuration: ProfileConfiguration, id: UUID, key: SymmetricKey) throws {
        let plaintext = try JSONCoding.encoder.encode(configuration)
        try SecureFile.write(AEAD.seal(plaintext, key: key, aad: Self.configAAD(id)), to: configURL(for: id))
    }

    private func mutateSummary(_ id: UUID, _ change: (inout ProfileSummary) -> Void) throws {
        try lock.withLock {
            var updated = index
            guard let position = updated.entries.firstIndex(where: { $0.summary.id == id }) else {
                throw CoreError.profileNotFound(id)
            }
            change(&updated.entries[position].summary)
            try saveIndex(updated)
            index = updated
        }
    }

    /// Caller must hold `lock`.
    private func entry(for id: UUID) throws -> ProfileIndexEntry {
        guard let entry = index.entries.first(where: { $0.summary.id == id }) else {
            throw CoreError.profileNotFound(id)
        }
        return entry
    }

    private func loadIndex() throws -> ProfileIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return ProfileIndex() }
        let plaintext = try AEAD.open(SecureFile.read(indexURL), key: vault.indexKey, aad: indexAAD)
        let decoded = try JSONCoding.decoder.decode(ProfileIndex.self, from: plaintext)
        guard decoded.format == 1 else { throw CoreError.unsupportedFormat("index format \(decoded.format)") }
        return decoded
    }

    /// Caller must hold `lock`.
    private func saveIndex(_ index: ProfileIndex) throws {
        let plaintext = try JSONCoding.encoder.encode(index)
        try SecureFile.write(AEAD.seal(plaintext, key: vault.indexKey, aad: indexAAD), to: indexURL)
    }

    private var indexAAD: String { "profile-index:v1:\(vault.vaultID.uuidString)" }
    static func keyAAD(_ id: UUID) -> String { "profile-key:v1:\(id.uuidString)" }
    static func configAAD(_ id: UUID) -> String { "profile-config:v1:\(id.uuidString)" }

    private static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            throw CoreError.invalidConfiguration("profile name must be 1–128 characters")
        }
        return trimmed
    }
}

/// Per-profile encrypted files that are synced.
enum ProfileSyncFile: String, CaseIterable {
    case config, passwords, bookmarks, history, cookies

    var isMergeable: Bool { self == .bookmarks || self == .history || self == .cookies }
    /// Changed on two devices: the newer version wins, the other is kept as `<file>.conflict`.
    var prefersNewer: Bool { self == .config }
}

#if !canImport(Darwin)
extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
