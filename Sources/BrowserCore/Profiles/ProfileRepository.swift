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

/// `profiles/<id>/key.bin`: a copy of what the index holds of the profile — its key, wrapped as the
/// index wraps it, its name and when it was made — sealed under the vault's index key (AAD
/// `"profile-key-copy:v1:<vaultID>:<id>"`). The index was the only place the profile's key was:
/// losing that one file lost every profile. With the copies, a vault unlocked without its index
/// puts it together again from the profiles' folders (`takeInProfilesFromKeyCopies`).
struct ProfileKeyCopy: Codable, Equatable {
    var format = 1
    var id: UUID
    var name: String
    var createdAt: Date
    /// As in the index: AEAD(profileKeyWrappingKey, profileKey), AAD `"profile-key:v1:<uuid>"`.
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
/// profiles/<uuid>/safarihome.pbsa  encrypted archive of Safari's own state in a profile hosting its
///                                  chrome (app layer, `SafariHomeVault`)
/// profiles/<uuid>/cookies-import.bin AEAD(cookieImportKey, [ImportedCookie] JSON): imported while
///                                  the profile was stopped, applied at its next launch (not synced)
/// profiles/<uuid>/cookies.bin      AEAD(cookiesKey, CookieJarDocument JSON): the persistent cookies,
///                                  synced and merged per cookie
/// profiles/<uuid>/cookies-baseline.bin AEAD(cookieBaselineKey, CookieBaseline JSON): what the cookie
///                                  store held at the last record or apply (this device only)
/// profiles/<uuid>/warmup.bin       AEAD(warmUpKey, WarmUpPlan JSON): the last session warm-up plan
///                                  (this device only)
/// profiles/<uuid>/warmup-schedule.bin AEAD(warmUpScheduleKey, WarmUpSchedule JSON): "warm up every
///                                  N hours" and when it last ran (this device only, not exported)
/// profiles/<uuid>/warmup-last.bin AEAD(warmUpRecordKey, WarmUpRecord JSON): how the last warm-up
///                                  went (this device only, not exported)
/// profiles/<uuid>/journal.bin      AEAD(journalKey, ProfileJournal JSON): what happened to the
///                                  profile (this device only, not exported)
/// profiles/<uuid>/restore-points/<p>/ copies of the profile's browsing state as it was, still
///                                  encrypted, and point.bin (`RestorePoint`; this device only)
/// profiles/<uuid>/key.bin          AEAD(indexKey, ProfileKeyCopy JSON): the profile's wrapped key, name
///                                  and creation date, as the index has them (`takeInProfilesFromKeyCopies`)
/// ```
/// Profile names are only readable after unlock. Profile configurations are only
/// decrypted when launched or edited.
///
/// On a vault opened for one profile (`ProfileGrant`, in that profile's own process) the
/// repository holds that profile only: its index is the grant's one entry, the index on disk is
/// neither read nor written (it is the manager's, and this process has no key for it), and
/// anything about another profile or the whole vault is refused.
public final class ProfileRepository: @unchecked Sendable {
    public let vault: UnlockedVault
    private let lock = NSLock()
    /// Kept deleted profiles being brought back now (`beginBringingBack`).
    private var bringingBack: Set<UUID> = []
    private var index: ProfileIndex

    /// How the vault's profile index was found when this repository was opened. An index that
    /// could not be read is not "no profiles": the profiles' keys are in it, and their folders are
    /// kept whatever happens, for the index to be put back (a backup, a sync).
    public enum IndexState: Equatable, Sendable {
        /// Read from `index.bin` — or there is none and no profile folder either (a new vault).
        case read
        /// No `index.bin`, while `profiles/` holds this many profile folders.
        case missing(profileFolders: Int)
        /// An `index.bin` this version could not read — not a newer version's, which still refuses
        /// to open (`CoreError.newerFormat`). It is never written over while this repository is open.
        case unreadable(profileFolders: Int)
    }

    /// See `IndexState`. Only `.read` lets a sweep delete anything (`removeOrphanedDirectories`).
    public var indexState: IndexState { lock.withLock { state } }
    /// `indexState`, under `lock`.
    private var state: IndexState = .read
    /// With the index missing when the vault was unlocked: the SHA-256 of the `index.bin` this
    /// repository wrote since (one put together from the profiles' key copies, or a profile
    /// created). A file there with other bytes was put back by someone — a backup restored, as the
    /// app tells a person to — and is never written over: the next unlock reads it.
    private var writtenWhileMissing: Data?
    /// The profiles the index was put together from, at unlock, out of their key copies: the index
    /// was missing, or an older one was put back (`takeInProfilesFromKeyCopies`). The Profiles
    /// window says so.
    public private(set) var takenInFromKeyCopies: [UUID] = []

    /// In a repository on a granted vault: the profile's settings were saved. The manager's index
    /// counts that as a new revision of the profile (sync's merge of the index goes by it), and
    /// only the manager writes the index — so it is told, through this, instead.
    public var onRevisionBump: ((UUID) -> Void)?

    public init(vault: UnlockedVault) throws {
        self.vault = vault
        self.index = ProfileIndex()
        if let grant = vault.grant {
            index.entries = [ProfileIndexEntry(summary: grant.summary, wrappedKey: Data())]
        } else {
            (self.index, self.state) = try loadIndex()
        }
    }

    /// The repository as unlocking opens it: the index read (or found missing or unreadable), and
    /// the folders of profiles the index says were deleted swept away — nothing else, and nothing at
    /// all from an index that was not read. What AppModel's unlock runs, and what the tests run.
    public static func openedAtUnlock(vault: UnlockedVault) throws -> ProfileRepository {
        // This version writes what a version from before cannot read (saved passwords, format 2):
        // the vault's generation first (docs/UPDATES.md §4, R3).
        try vault.raiseGenerationIfNeeded()
        let repository = try ProfileRepository(vault: vault)
        repository.removeOrphanedDirectories()
        repository.takeInProfilesFromKeyCopies()
        repository.writeMissingKeyCopies()
        return repository
    }

    /// What the profile's own process is given to run it: its summary and its key, not the
    /// vault's master key (`ProfileGrant`). Only a repository on the whole vault grants.
    public func grant(for id: UUID) throws -> ProfileGrant {
        guard vault.grant == nil else { throw CoreError.notGranted("granting a profile") }
        return ProfileGrant(summary: try summary(for: id), key: try profileKey(for: id))
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
    /// Safari's own state of the profile, for a profile whose window is Safari's chrome (the
    /// app's `SafariHomeVault` seals and restores it).
    public func safariHomeArchiveURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("safarihome.pbsa") }

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
        try create(name: name, configuration: configuration, createdAt: Date())
    }

    /// `create`, made at `createdAt`: a deleted profile brought back keeps when it was made, and with
    /// it its place in the list, which is in that order (`ProfileTransfer.bringBack`).
    func create(name: String, configuration: ProfileConfiguration, createdAt: Date) throws -> ProfileSummary {
        try configuration.validate()
        let cleanName = try Self.validatedName(name)
        let id = UUID()
        let profileKey = SymmetricKey(size: .bits256)
        let wrapped = try AEAD.seal(profileKey.rawBytes, key: vault.profileKeyWrappingKey, aad: Self.keyAAD(id))
        let summary = ProfileSummary(id: id, name: cleanName, createdAt: createdAt, lastLaunchedAt: nil, revision: 1)

        // Nothing of a new profile is written beside an index that is not written over.
        if case .unreadable = indexState {
            throw CoreError.corruptData("the profile index (index.bin) could not be read, and is not written over")
        }
        try SecureFile.ensureDirectory(directory(for: id))
        do {
            // Its key in its own folder too, before the index: a folder left by a create that
            // stopped before the index is a profile the next unlock takes in.
            try writeKeyCopy(ProfileKeyCopy(id: id, name: cleanName, createdAt: summary.createdAt, wrappedKey: wrapped))
            try writeConfiguration(configuration, id: id, key: profileKey)
            try lock.withLock {
                var updated = index
                updated.entries.append(ProfileIndexEntry(summary: summary, wrappedKey: wrapped))
                try saveIndex(updated)
                index = updated
            }
        } catch {
            // Its key was only ever in the index: a folder the index never got is of no use, and
            // the sweep no longer takes folders the index does not list.
            try? FileManager.default.removeItem(at: directory(for: id))
            throw error
        }
        return summary
    }

    public func rename(_ id: UUID, to name: String) throws {
        let cleanName = try Self.validatedName(name)
        try mutateSummary(id) { $0.name = cleanName; $0.revision += 1 }
        // The copy's name follows (a stale one would only be the name a lost index comes back with).
        try? writeKeyCopy(for: id)
    }

    public func markLaunched(_ id: UUID) throws {
        // In the profile's own process: the manager marked the launch when it started the process.
        if vault.grant != nil { _ = try summary(for: id); return }
        try mutateSummary(id) { $0.lastLaunchedAt = Date() }
    }

    public func bumpRevision(_ id: UUID) throws {
        if vault.grant != nil {
            _ = try summary(for: id)
            onRevisionBump?(id)
            return
        }
        try mutateSummary(id) { $0.revision += 1 }
    }

    /// Removes the profile from the index and deletes its encrypted files.
    /// The caller (app layer) is responsible for removing WebKit's own data store
    /// via `WKWebsiteDataStore.remove(forIdentifier:)` first.
    public func delete(_ id: UUID) throws {
        try recordDeletion(id)
        // Index is updated first: a crash here leaves orphaned *encrypted* files,
        // which are harmless and cleaned up by `removeOrphanedDirectories()`.
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// `delete` up to the folder — what a deletion that stopped there leaves.
    func recordDeletion(_ id: UUID) throws {
        // Marked first as this Mac's own deletion: should it stop between the index and the folder,
        // the sweep finishes it. A deleted profile's folder without the mark — the deletion came
        // from another device, or the folder was put back from a backup — is not removed by
        // anything but the person (R3, `keptDeletedProfiles`). A mark that cannot be written leaves
        // the folder to be asked about, never removed unasked. Only in a folder that is there: no
        // folder is made for it.
        let marked = FileManager.default.fileExists(atPath: directory(for: id).path)
            && (try? SecureFile.write(Data(), to: deletionMarkURL(for: id))) != nil
        do {
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
        } catch {
            // Not deleted after all (not a listed profile, or the index not written): the mark goes,
            // or a deletion of it made elsewhere would later look like this Mac's.
            if marked { try? FileManager.default.removeItem(at: deletionMarkURL(for: id)) }
            throw error
        }
    }

    /// Deletes the folders of profiles the index records as deleted (`deletedProfileIDs`) that are
    /// still on disk: a deletion interrupted between the index and the folder, or one that came
    /// through sync. Returns their IDs.
    ///
    /// Never more than that. Before this was fixed, it deleted every profile folder the index did not
    /// list — and an index that was missing read as empty, so losing that one file deleted every
    /// profile at the next unlock. A folder the index does not list is not one it says was deleted:
    /// the index may be missing or unreadable (nothing at all is deleted then), restored from an
    /// older copy, or written new while it was missing. Such a folder is kept, and said
    /// (`unlistedProfileFolders`).
    ///
    /// And of those, only a deletion made on this Mac, which marked the folder before it touched
    /// the index (`delete`). A deleted profile's folder without the mark — the deletion came from
    /// another device through sync, or the folder was put back from a backup — is kept, and the
    /// person decides: bring the profile back, or remove it for good (R3, `keptDeletedProfiles`).
    @discardableResult
    public func removeOrphanedDirectories() -> [UUID] {
        // A granted vault's index is one profile: every other profile's directory would look orphaned.
        guard vault.grant == nil, indexState == .read else { return [] }
        let (listed, deleted) = lock.withLock { (Set(index.entries.map(\.summary.id)), Set(index.deletedProfileIDs)) }
        var removed: [UUID] = []
        for id in profileFolderIDs() {
            let marked = FileManager.default.fileExists(atPath: deletionMarkURL(for: id).path)
            if listed.contains(id) {
                // A deletion that stopped before the index: the profile is still there, and so is
                // its mark, which must not make a later deletion elsewhere look like this Mac's.
                if marked { try? FileManager.default.removeItem(at: deletionMarkURL(for: id)) }
            } else if deleted.contains(id), marked {
                if (try? FileManager.default.removeItem(at: directory(for: id))) != nil { removed.append(id) }
            }
        }
        return removed
    }

    /// The folder of a deleted profile that is kept (R3): the index records the profile as
    /// deleted, but not by this Mac (no mark), and its folder is here.
    public struct KeptDeletedProfile: Equatable, Sendable {
        public let id: UUID
        /// Its name and when it was made, from its key copy; nil when the copy does not open —
        /// then nothing in the folder can be read.
        public let name: String?
        public let createdAt: Date?
        /// Brought back already, as a new profile (`ProfileTransfer.bringBack`). The folder stays
        /// for what was not carried over, until the person removes it.
        public let broughtBack: Bool

        public init(id: UUID, name: String?, createdAt: Date?, broughtBack: Bool = false) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.broughtBack = broughtBack
        }

        /// Its key copy opens. A folder that cannot be read is never removed by the app, even when
        /// asked (docs/DESTRUCTIVE_PATHS.md): it can only be shown in the Finder.
        public var isReadable: Bool { name != nil }
    }

    /// The deleted profiles whose folders are kept, for the person to bring back or remove.
    public func keptDeletedProfiles() -> [KeptDeletedProfile] {
        guard vault.grant == nil, indexState == .read else { return [] }
        let (listed, deleted) = lock.withLock { (Set(index.entries.map(\.summary.id)), Set(index.deletedProfileIDs)) }
        return profileFolderIDs()
            .filter { deleted.contains($0) && !listed.contains($0) && !FileManager.default.fileExists(atPath: deletionMarkURL(for: $0).path) }
            .map { id in
                let copy = readKeyCopy(id)
                var isDirectory: ObjCBool = false
                let marked = FileManager.default.fileExists(atPath: broughtBackMarkURL(for: id).path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
                return KeptDeletedProfile(id: id, name: copy?.name, createdAt: copy?.createdAt, broughtBack: marked)
            }
    }

    /// The person removes a kept deleted profile's folder for good, having been asked. One whose
    /// key copy does not open is refused: what cannot be read is never deleted.
    public func removeKeptDeletedProfile(_ id: UUID) throws {
        guard let kept = keptDeletedProfiles().first(where: { $0.id == id }) else { throw CoreError.profileNotFound(id) }
        guard kept.isReadable else {
            throw CoreError.corruptData("profiles/\(id.uuidString) cannot be read; it is kept as it is")
        }
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// Written in a profile's folder by `delete` before the index: the deletion is this Mac's own.
    func deletionMarkURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("deleted-here") }

    /// Written in a kept deleted profile's folder once it was brought back: a file, holding the new
    /// profile's id (a directory by its name is not the mark).
    func broughtBackMarkURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("brought-back") }

    /// The files in a profile's folder set aside because they could not be read — `<file>.unreadable`,
    /// then `-2`, `-3`… (`SecureFile.moveAside`) — by name. A deletion of the profile by the person
    /// deletes them too, and its confirmation says so (the owner, 1 November: the person decides,
    /// knowing). Of a listed profile or of a kept deleted one alike.
    public func unreadableFiles(for id: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory(for: id).path)) ?? [])
            .filter(Self.isSetAsideAsUnreadable).sorted()
    }

    static func isSetAsideAsUnreadable(_ name: String) -> Bool {
        guard let range = name.range(of: ".unreadable", options: .backwards), range.lowerBound > name.startIndex else { return false }
        let rest = name[range.upperBound...]
        return rest.isEmpty || (rest.hasPrefix("-") && Int(rest.dropFirst()).map { $0 >= 2 } == true)
    }

    /// One bring-back of a folder at a time in this process (`ProfileTransfer.bringBack`): a second
    /// one at once would make the profile twice.
    func beginBringingBack(_ id: UUID) -> Bool { lock.withLock { bringingBack.insert(id).inserted } }
    func endBringingBack(_ id: UUID) { lock.withLock { _ = bringingBack.remove(id) } }

    /// The profile folders on disk (folders of `profiles/` named by a UUID).
    public func profileFolderIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesDirectory.path)) ?? []
        return names.compactMap { name -> UUID? in
            guard let id = UUID(uuidString: name) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: profilesDirectory.appendingPathComponent(name).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return id
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// Profile folders on disk that the index neither lists nor records as deleted: kept, never
    /// swept, and to be told (the index missing, unreadable, or older than they are).
    public func unlistedProfileFolders() -> [UUID] {
        guard vault.grant == nil else { return [] }
        let (listed, deleted) = lock.withLock { (Set(index.entries.map(\.summary.id)), Set(index.deletedProfileIDs)) }
        return profileFolderIDs().filter { !listed.contains($0) && !deleted.contains($0) }
    }

    // MARK: Keys and configuration

    /// Unwraps the profile key. Call only when launching/editing the profile and drop the
    /// returned key when done.
    public func profileKey(for id: UUID) throws -> SymmetricKey {
        if let grant = vault.grant {
            guard grant.profileID == id else { throw CoreError.profileNotFound(id) }
            return grant.key
        }
        let wrapped = try lock.withLock { try entry(for: id).wrappedKey }
        let raw = try AEAD.open(wrapped, key: vault.profileKeyWrappingKey, aad: Self.keyAAD(id))
        guard raw.count == 32 else { throw CoreError.corruptData("profile key length") }
        return SymmetricKey(data: raw)
    }

    public func loadConfiguration(_ id: UUID) throws -> ProfileConfiguration {
        try loadConfiguration(id, key: profileKey(for: id))
    }

    /// The profile's settings. Settings that cannot be read — damaged, cut short, missing, another
    /// key's — throw `CoreError.unreadableSettings`, never defaults: a profile started or saved
    /// with defaults goes without its proxy (docs/DESTRUCTIVE_PATHS.md, R1). A newer version's
    /// throw `newerFormat`, as before.
    public func loadConfiguration(_ id: UUID, key: SymmetricKey) throws -> ProfileConfiguration {
        do {
            let sealed = try SecureFile.read(configURL(for: id))
            return try Self.decodeConfiguration(AEAD.open(sealed, key: key, aad: Self.configAAD(id)))
        } catch let error as CoreError {
            if case .newerFormat = error { throw error }
            throw unreadableSettings(id, error)
        } catch {
            throw unreadableSettings(id, error)
        }
    }

    private func unreadableSettings(_ id: UUID, _ error: Error) -> CoreError {
        .unreadableSettings(profileID: id, profile: (try? summary(for: id))?.name ?? id.uuidString, reason: String(describing: error))
    }

    /// The newest format of `config.bin` this version reads and writes (docs/UPDATES.md §4).
    static let configurationFormat = 1

    /// A configuration's JSON, refused when a newer version wrote it: its decoder is tolerant, so
    /// without this a newer version's fields would be dropped here and the rest written back.
    static func decodeConfiguration(_ json: Data) throws -> ProfileConfiguration {
        try DocumentFormat.check(json, supported: configurationFormat, what: "config.bin")
        return try JSONCoding.decoder.decode(ProfileConfiguration.self, from: json)
    }

    /// Saves an edit of the profile's settings. Never over settings that cannot be read (R1): the
    /// edit was made without them — the editor's form, opened on defaults — and the profile would
    /// start without its proxy. They are read first, and their error stops the save.
    public func saveConfiguration(_ configuration: ProfileConfiguration, for id: UUID) throws {
        try configuration.validate()
        let key = try profileKey(for: id)
        _ = try loadConfiguration(id, key: key)
        try writeConfiguration(configuration, id: id, key: key)
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

    func importedCookiesFile(for id: UUID) throws -> EncryptedDocumentFile<[ImportedCookie]> {
        EncryptedDocumentFile(url: importedCookiesURL(for: id),
                              key: try profileKey(for: id).derive(info: "cookie-import", salt: id.rawBytes),
                              aad: "cookie-import:v1:\(id.uuidString)")
    }

    /// Keeps cookies imported into a stopped profile until its next launch puts them into its
    /// cookie store (its website data is sealed while it is stopped). Added to those queued before;
    /// a later cookie replaces an earlier one with the same name, domain and path. Returns how
    /// many are queued now.
    /// A queue that cannot be read is moved aside first (`moveUnreadableImportedCookiesAside`),
    /// never written over; a newer version's refuses the import.
    @discardableResult
    public func queueImportedCookies(_ cookies: [ImportedCookie], for id: UUID) throws -> Int {
        _ = try summary(for: id)
        let file = try importedCookiesFile(for: id)
        var queued: [ImportedCookie]
        do {
            queued = try file.load() ?? []
        } catch {
            if case CoreError.newerFormat = error { throw error }
            try moveUnreadableImportedCookiesAside(id)
            queued = []
        }
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

    /// Drops the queue once the launch has put the cookies into the profile's store — never a
    /// queue a newer version wrote (docs/UPDATES.md §4), nor one that could not be read (moved
    /// aside instead, `moveUnreadableImportedCookiesAside`).
    public func clearImportedCookies(_ id: UUID) {
        try? importedCookiesFile(for: id).remove()
    }

    /// A queue that cannot be read — damaged, another key's; not a newer version's, which stays as
    /// it is — moved aside as `cookies-import.bin.unreadable` (then `-2`, …): nothing unreadable is
    /// ever deleted (docs/DESTRUCTIVE_PATHS.md). Returns where it went; nil when there is no queue,
    /// or it reads.
    @discardableResult
    public func moveUnreadableImportedCookiesAside(_ id: UUID) throws -> URL? {
        let url = importedCookiesURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            _ = try importedCookiesFile(for: id).load()
            return nil
        } catch CoreError.newerFormat {
            return nil
        } catch {
            return try SecureFile.moveAside(url, suffix: "unreadable")
        }
    }

    // MARK: Synced cookies

    func cookieJarURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookies.bin") }
    func cookieBaselineURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookies-baseline.bin") }

    static func cookieJarFile(url: URL?, profileID id: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<CookieJarDocument> {
        EncryptedDocumentFile(url: url, key: profileKey.derive(info: "cookies", salt: id.rawBytes), aad: "cookies:v1:\(id.uuidString)")
    }

    func cookieBaselineFile(for id: UUID) throws -> EncryptedDocumentFile<CookieBaseline> {
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
        try cookieBaselineFile(for: id).remove()
        guard FileManager.default.fileExists(atPath: cookieJarURL(for: id).path),
              (try? cookieJar(for: id)) != CookieJarDocument() else { return }
        try saveCookieJar(CookieJarDocument(), for: id)
    }

    // MARK: Warm-up plan (this Mac only)

    func warmUpPlanURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("warmup.bin") }

    func warmUpPlanFile(for id: UUID) throws -> EncryptedDocumentFile<WarmUpPlan> {
        warmUpPlanFile(for: id, key: try profileKey(for: id))
    }

    func warmUpPlanFile(for id: UUID, key: SymmetricKey) -> EncryptedDocumentFile<WarmUpPlan> {
        EncryptedDocumentFile(url: warmUpPlanURL(for: id), key: key.derive(info: "warm-up", salt: id.rawBytes),
                              aad: "warm-up:v1:\(id.uuidString)")
    }

    /// The profile's last warm-up plan (`WarmUpPlan`), or nil when none was saved.
    public func warmUpPlan(for id: UUID) throws -> WarmUpPlan? {
        try warmUpPlanFile(for: id).load()
    }

    /// A saved plan that cannot be read is moved aside as `warmup.bin.unreadable`, never written
    /// over (R1b, docs/DESTRUCTIVE_PATHS.md).
    public func saveWarmUpPlan(_ plan: WarmUpPlan, for id: UUID) throws {
        try warmUpPlanFile(for: id).save(plan)
    }

    // MARK: Warm-up schedule (this Mac only)

    func warmUpScheduleURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("warmup-schedule.bin") }

    func warmUpScheduleFile(for id: UUID) throws -> EncryptedDocumentFile<WarmUpSchedule> {
        EncryptedDocumentFile(url: warmUpScheduleURL(for: id),
                              key: try profileKey(for: id).derive(info: "warm-up-schedule", salt: id.rawBytes),
                              aad: "warm-up-schedule:v1:\(id.uuidString)")
    }

    /// The profile's warm-up schedule (`WarmUpSchedule`), or nil when none was ever set.
    public func warmUpSchedule(for id: UUID) throws -> WarmUpSchedule? {
        try warmUpScheduleFile(for: id).load()
    }

    /// A saved schedule that cannot be read is moved aside as `warmup-schedule.bin.unreadable`,
    /// never written over (R1b).
    public func saveWarmUpSchedule(_ schedule: WarmUpSchedule, for id: UUID) throws {
        try warmUpScheduleFile(for: id).save(schedule)
    }

    // MARK: Last warm-up (this Mac only)

    func warmUpRecordURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("warmup-last.bin") }

    func warmUpRecordFile(for id: UUID) throws -> EncryptedDocumentFile<WarmUpRecord> {
        EncryptedDocumentFile(url: warmUpRecordURL(for: id),
                              key: try profileKey(for: id).derive(info: "warm-up-last", salt: id.rawBytes),
                              aad: "warm-up-last:v1:\(id.uuidString)")
    }

    /// How the profile's last warm-up went (`WarmUpRecord`), or nil when it was never warmed.
    public func warmUpRecord(for id: UUID) throws -> WarmUpRecord? {
        try warmUpRecordFile(for: id).load()
    }

    /// A record that cannot be read is moved aside as `warmup-last.bin.unreadable`, never written
    /// over (R1b).
    public func saveWarmUpRecord(_ record: WarmUpRecord, for id: UUID) throws {
        try warmUpRecordFile(for: id).save(record)
    }

    // MARK: Open tabs (this Mac only)

    func openTabsURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("tabs.bin") }

    func openTabsFile(for id: UUID) throws -> EncryptedDocumentFile<OpenTabs> {
        EncryptedDocumentFile(url: openTabsURL(for: id), key: try profileKey(for: id).derive(info: "open-tabs", salt: id.rawBytes),
                              aad: "open-tabs:v1:\(id.uuidString)")
    }

    /// The tabs the profile left open when it last stopped (`OpenTabs`), or nil when none were kept.
    public func openTabs(for id: UUID) throws -> OpenTabs? {
        try openTabsFile(for: id).load()
    }

    public func saveOpenTabs(_ tabs: OpenTabs, for id: UUID) throws {
        try openTabsFile(for: id).save(tabs)
    }

    /// Forgets them: the setting was turned off, or the profile keeps no history.
    public func removeOpenTabs(for id: UUID) throws {
        try openTabsFile(for: id).remove()
    }

    // MARK: Sync support (raw encrypted files; see SyncEngine)

    func currentIndex() -> ProfileIndex {
        lock.withLock { index }
    }

    func replaceIndex(_ incoming: ProfileIndex) throws {
        guard incoming.format <= Self.indexFormat else {
            throw CoreError.newerFormat(what: "index.bin", found: incoming.format, supported: Self.indexFormat)
        }
        try lock.withLock {
            try saveIndex(incoming)
            index = incoming
            // A missing index the sync just put back from the server is this vault's index again.
            // (An unreadable one is never written over: saveIndex refused above.)
            state = .read
            writtenWhileMissing = nil
        }
        // Profiles the sync brought, renamed, or wrapped anew: their copies follow.
        writeMissingKeyCopies()
    }

    // MARK: Key copies

    func keyCopyURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("key.bin") }
    private func keyCopyAAD(_ id: UUID) -> String { "profile-key-copy:v1:\(vault.vaultID.uuidString):\(id.uuidString)" }

    private func writeKeyCopy(_ copy: ProfileKeyCopy) throws {
        try SecureFile.ensureDirectory(directory(for: copy.id))
        let url = keyCopyURL(for: copy.id)
        // A copy there that this vault cannot read (damaged, another vault's) is moved aside as
        // `key.bin.unreadable`, never written over (docs/DESTRUCTIVE_PATHS.md); the index is what
        // the new one is written from.
        if FileManager.default.fileExists(atPath: url.path), readKeyCopy(copy.id) == nil {
            try SecureFile.moveAside(url, suffix: "unreadable")
        }
        try SecureFile.write(AEAD.seal(JSONCoding.encoder.encode(copy), key: vault.indexKey, aad: keyCopyAAD(copy.id)), to: url)
    }

    private func writeKeyCopy(for id: UUID) throws {
        let entry = try lock.withLock { try self.entry(for: id) }
        try writeKeyCopy(ProfileKeyCopy(id: id, name: entry.summary.name, createdAt: entry.summary.createdAt, wrappedKey: entry.wrappedKey))
    }

    /// The copy in `id`'s folder, when this vault's key opens it and the key it holds unwraps.
    func readKeyCopy(_ id: UUID) -> ProfileKeyCopy? {
        guard let sealed = try? SecureFile.read(keyCopyURL(for: id)),
              let plaintext = try? AEAD.open(sealed, key: vault.indexKey, aad: keyCopyAAD(id)),
              (try? DocumentFormat.check(plaintext, supported: 1, what: "key.bin")) != nil,
              let copy = try? JSONCoding.decoder.decode(ProfileKeyCopy.self, from: plaintext), copy.id == id,
              let raw = try? AEAD.open(copy.wrappedKey, key: vault.profileKeyWrappingKey, aad: Self.keyAAD(id)), raw.count == 32
        else { return nil }
        return copy
    }

    /// Every profile of the index gets its copy, or a new one when its name or key changed (an
    /// index from before the copies, a profile sync brought). Not on a granted vault.
    func writeMissingKeyCopies() {
        guard vault.grant == nil else { return }
        for entry in lock.withLock({ index.entries }) {
            let copy = ProfileKeyCopy(id: entry.summary.id, name: entry.summary.name, createdAt: entry.summary.createdAt,
                                      wrappedKey: entry.wrappedKey)
            // Dates are kept to the second (ISO 8601): compared so, or every copy were written again.
            let onDisk = readKeyCopy(entry.summary.id)
            let same = onDisk.map { ($0.name, $0.wrappedKey, Int($0.createdAt.timeIntervalSince1970))
                == (copy.name, copy.wrappedKey, Int(copy.createdAt.timeIntervalSince1970)) } ?? false
            if !same { try? writeKeyCopy(copy) }
        }
    }

    /// Profiles whose folder holds a key copy this vault opens, and whom the index does not list:
    /// the index was missing (it is put together from the copies, and written), or an older one
    /// was put back (the profiles made since are listed again). Never with an index that could not
    /// be read (kept as it is, as before), never a profile the index records as deleted; a folder
    /// without a copy this vault opens stays out of the list, kept, as before. The summary comes
    /// back with its name and when it was made; when it was last used does not. Returns the
    /// profiles taken in.
    @discardableResult
    func takeInProfilesFromKeyCopies() -> [UUID] {
        guard vault.grant == nil else { return [] }
        if case .unreadable = indexState { return [] }
        // Oldest first, as the index lists profiles. A copy keeps when its profile was made to the
        // second only, so profiles made in one second go in by name, then id: the same order at every
        // unlock, whatever order the folders are listed in (they swapped in CI run 543).
        let found = unlistedProfileFolders().compactMap(readKeyCopy)
            .sorted { ($0.createdAt, $0.name, $0.id.uuidString) < ($1.createdAt, $1.name, $1.id.uuidString) }
        guard !found.isEmpty else { return [] }
        return lock.withLock {
            var updated = index
            for copy in found {
                updated.entries.append(ProfileIndexEntry(summary: ProfileSummary(id: copy.id, name: copy.name, createdAt: copy.createdAt,
                                                                                lastLaunchedAt: nil, revision: 0),
                                                         wrappedKey: copy.wrappedKey))
            }
            do {
                try saveIndex(updated)
            } catch {
                return []
            }
            index = updated
            if case .missing = state {
                // Read from now on (the sweep, sync), but a file put back meanwhile is still not
                // written over (saveIndex: `writtenWhileMissing`, set as it wrote).
                state = .read
            }
            takenInFromKeyCopies = found.map(\.id)
            return takenInFromKeyCopies
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

    /// Refuses a synced copy of `file` that a newer version of the app wrote (docs/UPDATES.md §4):
    /// the sync then stops, and neither this device's copy nor the remote one is written.
    func checkSyncedFileFormat(_ file: ProfileSyncFile, profileID id: UUID, data: Data) throws {
        let key = try profileKey(for: id)
        let what = url(of: file, for: id).lastPathComponent
        switch file {
        case .config:
            try DocumentFormat.check(AEAD.open(data, key: key, aad: Self.configAAD(id)), supported: Self.configurationFormat, what: what)
        case .passwords:
            try DocumentFormat.check(PasswordVault.open(data, profileID: id, profileKey: key), supported: PasswordVault.supportedFormat, what: what)
        case .bookmarks:
            let codec = BookmarkStore.file(url: nil, profileID: id, profileKey: key)
            try DocumentFormat.check(codec.open(data), supported: codec.supportedFormat, what: what)
        case .history:
            let codec = HistoryStore.file(url: nil, profileID: id, profileKey: key)
            try DocumentFormat.check(codec.open(data), supported: codec.supportedFormat, what: what)
        case .cookies:
            let codec = Self.cookieJarFile(url: nil, profileID: id, profileKey: key)
            try DocumentFormat.check(codec.open(data), supported: codec.supportedFormat, what: what)
        }
    }

    /// Whether a copy of a profile file opens with the profile's key: decrypted and, for the
    /// settings, decoded as a launch reads them. A newer version's copy opens (`checkSyncedFileFormat`
    /// refuses it, and the sync stops). One that does not — damaged, cut short, another key's — is
    /// never pushed and never written over (`SyncEngine.syncFile`).
    func opensSyncedFile(_ file: ProfileSyncFile, profileID id: UUID, data: Data) -> Bool {
        do {
            if file == .config {
                _ = try Self.decodeConfiguration(AEAD.open(data, key: profileKey(for: id), aad: Self.configAAD(id)))
            } else {
                try checkSyncedFileFormat(file, profileID: id, data: data)
            }
            return true
        } catch CoreError.newerFormat {
            return true
        } catch {
            return false
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
            // The profile's own retention; with its settings unreadable, none: a merge never cuts
            // the history to a default the person did not choose (90 days, when they kept it for
            // a year or for ever). The number of entries is no one's choice and stays the limit.
            let policy = (try? loadConfiguration(id, key: key))?.historyPolicy ?? HistoryStore.Policy(retentionDays: nil)
            return try codec.encode(HistoryStore.merge(codec.decode(local), codec.decode(remote), policy: policy))
        case .cookies:
            let codec = Self.cookieJarFile(url: nil, profileID: id, profileKey: key)
            // Cookie sync is off (the settings just synced say so): nothing to keep.
            if let configuration = try? loadConfiguration(id, key: key), !configuration.syncsCookies {
                return try codec.encode(CookieJarDocument())
            }
            return try codec.encode(CookieJarDocument.merge(codec.decode(local), codec.decode(remote)))
        case .passwords:
            return try PasswordVault.merge(local, remote, profileID: id, profileKey: key)
        case .config:
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
            try Self.decodeConfiguration(AEAD.open(data, key: key, aad: Self.configAAD(id)))
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
        // Never over a newer version's file — whatever the caller read, or failed to read, first.
        try DocumentFormat.guardOverwrite(of: configURL(for: id), supported: Self.configurationFormat, what: "config.bin") {
            try AEAD.open($0, key: key, aad: Self.configAAD(id))
        }
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

    /// The index on disk, and how it was found. No file is an empty index only when there is no
    /// profile folder either; with folders it is `.missing`. A file that cannot be read is
    /// `.unreadable`, but for a newer version's, which still throws (`newerFormat`).
    private func loadIndex() throws -> (ProfileIndex, IndexState) {
        let folders = profileFolderIDs().count
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return (ProfileIndex(), folders == 0 ? .read : .missing(profileFolders: folders))
        }
        do {
            let plaintext = try AEAD.open(SecureFile.read(indexURL), key: vault.indexKey, aad: indexAAD)
            try DocumentFormat.check(plaintext, supported: Self.indexFormat, what: "index.bin")
            return (try JSONCoding.decoder.decode(ProfileIndex.self, from: plaintext), .read)
        } catch let error as CoreError {
            if case .newerFormat = error { throw error }
            return (ProfileIndex(), .unreadable(profileFolders: folders))
        } catch {
            return (ProfileIndex(), .unreadable(profileFolders: folders))
        }
    }

    /// The newest format of `index.bin` this version reads and writes (docs/UPDATES.md §4).
    static let indexFormat = 1

    /// Caller must hold `lock`. Never over an index a newer version wrote since this one read it,
    /// nor over one that could not be read, nor over one put back while it was missing.
    private func saveIndex(_ index: ProfileIndex) throws {
        switch state {
        case .read:
            // Put together from the key copies while it was missing: a file put back since is not written over.
            if let written = writtenWhileMissing, let onDisk = try? SecureFile.read(indexURL), Data(SHA256.hash(data: onDisk)) != written {
                throw CoreError.corruptData("an index.bin was put back after the vault was unlocked without one; it is read at the next unlock, not written over")
            }
        case .unreadable:
            // Kept as it is: it may be readable again (a transient read error, a backup restored
            // over it), and the profiles' keys are in it.
            throw CoreError.corruptData("the profile index (index.bin) could not be read, and is not written over")
        case .missing:
            if let onDisk = try? SecureFile.read(indexURL), Data(SHA256.hash(data: onDisk)) != writtenWhileMissing {
                throw CoreError.corruptData("an index.bin was put back after the vault was unlocked without one; it is read at the next unlock, not written over")
            }
        }
        try DocumentFormat.guardOverwrite(of: indexURL, supported: Self.indexFormat, what: "index.bin") {
            try AEAD.open($0, key: vault.indexKey, aad: indexAAD)
        }
        let plaintext = try JSONCoding.encoder.encode(index)
        let sealed = try AEAD.seal(plaintext, key: vault.indexKey, aad: indexAAD)
        try SecureFile.write(sealed, to: indexURL)
        if case .missing = state { writtenWhileMissing = Data(SHA256.hash(data: sealed)) }
    }

    var indexAAD: String { "profile-index:v1:\(vault.vaultID.uuidString)" }
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

    /// Merged record by record (passwords login by login, since `passwords.bin` format 2).
    var isMergeable: Bool { self != .config }
    /// Changed on two devices: the newer version wins, the other is kept as `<file>.conflict`.
    var prefersNewer: Bool { self == .config }
    /// The profile does not start without it: a copy lost here is taken back from the server even
    /// when the server's has not changed since this device last had it.
    var isNeededToStart: Bool { self == .config }
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
