#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum SyncConflictResolution: Sendable {
    case keepLocal
    /// Take the remote version. The local file is preserved next to the original as `<name>.conflict`.
    case keepRemote
}

public struct SyncReport: Equatable, Sendable {
    public var pushed: [String] = []
    public var pulled: [String] = []
    /// Objects whose compare-and-swap lost a race; retried on the next sync.
    public var deferred: [String] = []
    /// Objects changed on both sides where one version won and the other was kept as
    /// `<file>.conflict` (or dropped, by `resolveConflict: .keepLocal`): config, passwords.
    public var resolvedConflicts: [String] = []
    /// Objects changed on both sides and merged record by record (bookmarks, history, cookies).
    public var merged: [String] = []
    /// Profiles deleted on another device and removed locally. The app layer must also
    /// remove their WebKit data stores.
    public var deletedProfileIDs: [UUID] = []
    /// Objects of deleted profiles written over on the sync location with a small envelope that
    /// says so (`SyncPayload.deleted`, no data), so that they take no room there. Not uploads of
    /// anything of this device's: not counted with `pushed`.
    public var retired: [String] = []
    /// The sync location's vault header against this device's (`SyncEngine.publishVaultHeader`).
    public var passwordHeader: PasswordHeader = .same
    /// Profile files whose copy on this device does not open (damaged, cut short, another key's):
    /// never pushed, never written over (docs/DESTRUCTIVE_PATHS.md).
    public var unreadable: [UnreadableCopy] = []
    /// Profiles whose settings changed here only, but older than the server's (R2): put back from a
    /// backup. The server's stayed the profile's settings; this Mac's are kept as a version of them
    /// (`KeptSettings.Origin.restored`), never pushed over the newer ones.
    public var restoredSettings: [UUID] = []
    /// Profiles that hold more kept versions of their settings than `KeptSettings.reviewAbove`
    /// after this sync: the person is asked to go through them; none is removed for them.
    public var settingsVersionsToReview: [UUID] = []

    public struct UnreadableCopy: Equatable, Sendable {
        public var profileID: UUID
        /// The file's name in the profile's folder (`config.bin`).
        public var file: String
        /// The server's copy was taken in its place, and this device's kept beside it under this
        /// name (`config.bin.unreadable`). Nil: the server has no copy that opens; nothing was
        /// written on either side, and the file is as it was.
        public var keptAs: String?

        public init(profileID: UUID, file: String, keptAs: String?) {
            self.profileID = profileID
            self.file = file
            self.keptAs = keptAs
        }
    }

    /// Whose master password a new device sets up with: the header the sync location keeps.
    public enum PasswordHeader: String, Codable, Equatable, Sendable {
        /// This device's.
        case same
        /// This device's, put there by this sync: newer than the one there (a change of the master
        /// password made here, or the vault's generation raised here).
        case published
        /// Another device's, newer: the master password was changed there later. This device keeps
        /// its own `vault.json`, which still opens with its own password.
        case newerElsewhere
        /// Another device's of the same count of changes: changed there and here apart, or before
        /// changes were counted. The first one there stays; this device keeps its own.
        case differentElsewhere
    }
}

/// Client side of the optional encrypted sync.
///
/// Synced objects:
/// * `vault-header`            plaintext `VaultHeader` (salt, KDF params, wrapped VMK) — lets a
///                             new device unlock with the master password.
/// * `index`                   the profile index; merged automatically (see `ProfileIndex.merge`).
/// * `profile/<id>/config`     the profile's encrypted `config.bin`, as-is.
/// * `profile/<id>/passwords`  the profile's encrypted `passwords.bin`, as-is.
/// * `profile/<id>/bookmarks`  `bookmarks.bin`; concurrent edits are merged per bookmark.
/// * `profile/<id>/history`    `history.bin`; concurrent edits are merged per URL.
/// * `profile/<id>/cookies`    `cookies.bin`, the persistent cookies; merged per cookie, the newer
///                             change winning (`CookieJarDocument`).
///
/// A config changed on two devices: the newer settings win (`settingsModifiedAt`), and the other
/// device's file is kept as `config.bin.conflict`; when only what the browser keeps for itself
/// differs (the proxy location), the remote file, no copy; without a time on either side, or
/// equal ones, `resolveConflict`.
///
/// A profile file this device cannot open is never pushed and never written over: the server's
/// copy, when one opens, is taken in its place and this device's kept beside it as
/// `<file>.unreadable` (`SyncReport.unreadable`). Settings lost here are taken back from the
/// server: the profile does not start without them.
///
/// Profile files are already encrypted with per-profile keys; the envelope adds a second
/// layer that hides object names and binds blobs to their name and revision.
///
/// A deleted profile's objects are written over with a small envelope that says so (`deleted`,
/// no data), by whichever device syncs first knowing of the deletion, and before anything else is
/// written: they held the profile's files, which no device takes any more, and took the sync
/// location's room (`retireObjects`). The folders of the profile on the devices are not touched.
///
/// NOT synced: WebKit data store archives (localStorage/IndexedDB/cache; cookies sync through
/// `cookies.bin` instead). They are large and only consistent while the profile is stopped.
///
/// Run sync only while no profile is running: an incoming config replaces the file on disk,
/// not a live session.
public final class SyncEngine: @unchecked Sendable {
    public static let vaultHeaderObjectID = "vault-header"

    private struct ItemState: Codable, Equatable {
        var revision: Int
        var sha256: String
    }

    private let repository: ProfileRepository
    private let transport: SyncTransport
    private let codec: SyncCodec
    private let resolveConflict: @Sendable (String) -> SyncConflictResolution

    public init(repository: ProfileRepository, transport: SyncTransport,
                resolveConflict: @escaping @Sendable (String) -> SyncConflictResolution = { _ in .keepRemote }) throws {
        self.repository = repository
        self.transport = transport
        self.codec = try SyncCodec(vault: repository.vault)
        self.resolveConflict = resolveConflict
    }

    /// New-device setup: download the vault header, verify the master password against it,
    /// and write it locally. Follow with `ProfileRepository(vault:)` + `SyncEngine.sync()`.
    public static func bootstrap(transport: SyncTransport, root: URL, password: String) async throws -> UnlockedVault {
        guard !MasterVault.exists(in: root) else { throw CoreError.vaultAlreadyExists }
        guard let blob = try await transport.fetch(objectID: vaultHeaderObjectID) else { throw CoreError.vaultNotFound }
        let header = try VaultHeader.decodeChecked(blob)
        let vault = try MasterVault.unlock(header: header, root: root, password: password)
        try MasterVault.createHeader(header, in: root)
        return vault
    }

    /// Puts this device's vault header on the sync location when it is the newer one there — after
    /// a change of the master password here (`VaultHeader.passwordRevision`), or the vault's
    /// generation raised here (R3), or when there is none — so that a new device sets up with this
    /// device's password, and not with the one before. Never one over a newer: a header changed
    /// later on another device (a higher count), or apart from this one (the same count, another
    /// key), stays, and the result says so. A newer version's header stops here (docs/UPDATES.md
    /// §4). `listed`: the sync location's objects, when the caller has them.
    @discardableResult
    public func publishVaultHeader(listed: [RemoteObjectInfo]? = nil) async throws -> SyncReport.PasswordHeader {
        let objects: [RemoteObjectInfo]
        if let listed { objects = listed } else { objects = try await transport.listObjects() }
        let local = repository.vault.header
        guard let remote = objects.first(where: { $0.objectID == Self.vaultHeaderObjectID }),
              let blob = try await transport.fetch(objectID: Self.vaultHeaderObjectID) else {
            try await transport.store(objectID: Self.vaultHeaderObjectID, revision: 1,
                                      data: JSONCoding.encoder.encode(local), expectedRevision: nil)
            return .published
        }
        let existing = try VaultHeader.decodeChecked(blob)
        guard existing.vaultID == local.vaultID else { throw CoreError.corruptData("sync location holds a different vault") }
        switch Self.compare(local: local, remote: existing) {
        case .same: return .same
        case .remoteNewer: return .newerElsewhere
        case .apart: return .differentElsewhere
        case .localNewer:
            // Compare-and-swap: a header another device put there meanwhile is not written over.
            try await transport.store(objectID: Self.vaultHeaderObjectID, revision: remote.revision + 1,
                                      data: JSONCoding.encoder.encode(local), expectedRevision: remote.revision)
            return .published
        }
    }

    /// How many times the master password was changed by the header the sync location holds (nil:
    /// none there). A change made knowing it (`UnlockedVault.changePassword(atLeast:)`) is the
    /// newest there, and goes there.
    public func passwordRevisionThere() async throws -> Int? {
        guard let blob = try await transport.fetch(objectID: Self.vaultHeaderObjectID) else { return nil }
        let header = try VaultHeader.decodeChecked(blob)
        guard header.vaultID == repository.vault.vaultID else { throw CoreError.corruptData("sync location holds a different vault") }
        return header.passwordRevision ?? 0
    }

    enum HeaderOrder: Equatable { case same, localNewer, remoteNewer, apart }

    /// Which of two headers of one vault is the newer. More changes of the master password is newer.
    /// With as many: the same key (the same password, as it was wrapped then) is the same header,
    /// but for the vault's generation, where the higher is newer (R3); another key is a change made
    /// apart — or, at 0, one made before changes were counted — and neither is taken for newer.
    static func compare(local: VaultHeader, remote: VaultHeader) -> HeaderOrder {
        let mine = local.passwordRevision ?? 0, theirs = remote.passwordRevision ?? 0
        if mine != theirs { return mine > theirs ? .localNewer : .remoteNewer }
        guard local.wrappedMasterKey == remote.wrappedMasterKey, local.kdf == remote.kdf else { return .apart }
        if local.format != remote.format { return local.format > remote.format ? .localNewer : .remoteNewer }
        return .same
    }

    public func sync() async throws -> SyncReport {
        var report = SyncReport()
        var state = try loadState()
        defer { try? saveState(state) }

        let remoteObjects = try await transport.listObjects()
        // The vault's header there: this device's when it is the newer — a change of the master
        // password made here, so that new devices set up with the new password and not the old,
        // or the vault's generation raised here, so that a version from before refuses the sync
        // location as it refuses the vault (R3). Never an older one over a newer. A newer version's
        // vault there stops the sync here.
        report.passwordHeader = try await publishVaultHeader(listed: remoteObjects)
        let remote = Dictionary(remoteObjects.map { ($0.objectID, $0.revision) }, uniquingKeysWith: max)

        // The objects of the profiles deleted here go first, before anything else is written: a
        // sync location that is full takes these (each is smaller than what it replaces) and then
        // has room for the rest — the index among it, which would otherwise be refused and stop
        // the sync before the room was given back.
        let deletedHere = repository.currentIndex().deletedProfileIDs
        try await retireObjects(ofDeleted: deletedHere, remote: remote, state: &state, report: &report)

        let profilesBefore = Set(repository.list().map(\.id))
        try await syncIndex(remote: remote, state: &state, report: &report)
        try await syncLabels(remote: remote, state: &state, report: &report)

        let index = repository.currentIndex()
        // And those of the profiles the index just taken in says were deleted elsewhere: the device
        // that deleted them has usually done it, and then nothing is written here.
        let known = Set(deletedHere)
        try await retireObjects(ofDeleted: index.deletedProfileIDs.filter { !known.contains($0) },
                                remote: remote, state: &state, report: &report)
        for entry in index.entries {
            let id = entry.summary.id
            for file in ProfileSyncFile.allCases {
                let merge: ((Data, Data) throws -> Data)? = file.isMergeable
                    ? { [repository] local, remote in try repository.mergeSyncedFile(file, profileID: id, local: local, remote: remote) }
                    : nil
                let newer: ((Data, Data) throws -> ProfileRepository.NewerVersion?)? = file.prefersNewer
                    ? { [repository] local, remote in try repository.newerVersion(file, profileID: id, local: local, remote: remote) }
                    : nil
                let check: (Data) throws -> Void = { [repository] data in
                    try repository.checkSyncedFileFormat(file, profileID: id, data: data)
                }
                let opens: (Data) -> Bool = { [repository] data in
                    repository.opensSyncedFile(file, profileID: id, data: data)
                }
                // The version a conflict does not keep as the file: one file of its own beside it,
                // never one written over (R4).
                let keep: (Data, KeptSettings.Origin) throws -> Void = { [repository] data, origin in
                    if file == .config {
                        try repository.keepSettingsVersion(data, origin: origin, for: id)
                    } else {
                        try SecureFile.writeBeside(data, of: repository.url(of: file, for: id), suffix: "conflict")
                    }
                }
                try await syncFile(name: "profile/\(id.uuidString)/\(file.rawValue)", url: repository.url(of: file, for: id),
                                   profileID: id, neededToStart: file.isNeededToStart,
                                   merge: merge, newer: newer, check: check, opens: opens, keep: keep,
                                   remote: remote, state: &state, report: &report)
            }
            if repository.keptSettings(for: id).count > KeptSettings.reviewAbove { report.settingsVersionsToReview.append(id) }
        }

        let profilesAfter = Set(index.entries.map(\.summary.id))
        report.deletedProfileIDs = profilesBefore.subtracting(profilesAfter).sorted { $0.uuidString < $1.uuidString }
        repository.removeOrphanedDirectories()
        return report
    }

    // MARK: Deleted profiles

    /// What `ItemState` holds for an object written over as deleted: the hash of no data.
    private static let retiredHash = SyncEngine.hash(Data())

    /// The objects of deleted profiles that the sync location still holds are written over with a
    /// small envelope that says so (`deleted: true`, no data) — a deletion is permanent
    /// (`ProfileIndex.deletedProfileIDs`), no device takes these objects any more, and until now
    /// they stayed there at their full size for good. Compare-and-swap, as every write: one that
    /// another device wrote meanwhile is left for the next sync (`deferred`). An object this device
    /// knows at the revision listed is written over without being fetched; any other is fetched
    /// first, and one that already says it is deleted is only noted — so that two devices do not
    /// write it over in turn. One that does not open here (damaged, or a newer version's) is left
    /// as it is: what cannot be read is not written over, and no device needs it for the sync to go
    /// on. A profile the index lists is never touched, whatever else it says. Nothing is written or
    /// removed on this device.
    private func retireObjects(ofDeleted ids: [UUID], remote: [String: Int],
                               state: inout [String: ItemState], report: inout SyncReport) async throws {
        guard !ids.isEmpty else { return }
        let listed = Set(repository.currentIndex().entries.map(\.summary.id))
        for id in ids where !listed.contains(id) {
            for file in ProfileSyncFile.allCases {
                let name = "profile/\(id.uuidString)/\(file.rawValue)"
                let objectID = codec.objectID(for: name)
                guard let remoteRevision = remote[objectID] else { continue }
                var current = remoteRevision
                if let known = state[name], known.revision == remoteRevision {
                    if known.sha256 == Self.retiredHash { continue }
                } else {
                    guard let blob = try await transport.fetch(objectID: objectID),
                          let decoded = try? codec.decode(blob), decoded.payload.logicalName == name else { continue }
                    if decoded.payload.deleted, decoded.payload.data.isEmpty {
                        state[name] = ItemState(revision: decoded.revision, sha256: Self.retiredHash)
                        continue
                    }
                    current = decoded.revision
                }
                let blob = try codec.encode(SyncPayload(logicalName: name, deleted: true, data: Data()), revision: current + 1)
                do {
                    try await transport.store(objectID: objectID, revision: current + 1, data: blob, expectedRevision: current)
                    state[name] = ItemState(revision: current + 1, sha256: Self.retiredHash)
                    report.retired.append(name)
                } catch CoreError.syncConflict {
                    report.deferred.append(name)
                }
            }
        }
    }

    // MARK: Index

    private func syncIndex(remote: [String: Int], state: inout [String: ItemState], report: inout SyncReport) async throws {
        let name = "index"
        let objectID = codec.objectID(for: name)
        let local = repository.currentIndex()
        let localBytes = try JSONCoding.encoder.encode(local)
        let known = state[name]
        // An index this device could not read (missing, unreadable) is not an empty one: the
        // server's copy is fetched and taken in whatever its revision, and nothing of this device's
        // is pushed — it once was, the empty index over the server's, whose profiles' keys were
        // then on no copy anywhere.
        let localWasRead = repository.indexState == .read

        if let remoteRevision = remote[objectID], remoteRevision != known?.revision || !localWasRead {
            guard let blob = try await transport.fetch(objectID: objectID) else { return }
            let decoded = try codec.decode(blob)
            // A newer version's index stops the sync: nothing is merged, nothing written either side.
            try DocumentFormat.check(decoded.payload.data, supported: ProfileRepository.indexFormat, what: "index.bin")
            let remoteIndex = try JSONCoding.decoder.decode(ProfileIndex.self, from: decoded.payload.data)
            let merged = ProfileIndex.merge(local, remoteIndex)
            let mergedBytes = try JSONCoding.encoder.encode(merged)
            if mergedBytes != localBytes {
                try repository.replaceIndex(merged)
                report.pulled.append(name)
            }
            if mergedBytes != decoded.payload.data {
                try await push(name: name, data: mergedBytes, revision: remoteRevision + 1,
                               expected: remoteRevision, state: &state, report: &report)
            } else {
                state[name] = ItemState(revision: remoteRevision, sha256: Self.hash(mergedBytes))
            }
        } else if localWasRead, Self.hash(localBytes) != known?.sha256 {
            let remoteRevision = remote[objectID]
            try await push(name: name, data: localBytes, revision: (remoteRevision ?? 0) + 1,
                           expected: remoteRevision, state: &state, report: &report)
        }
    }

    // MARK: Tag colours

    /// The tags' colours (`labels.bin`, `TagColors`): whenever either side changed, the two are
    /// merged tag by tag, written here when the merge differs from this device's copy and pushed
    /// when it differs from the server's. A copy here that does not open counts as none: the
    /// server's is taken in and this one kept beside it as `labels.bin.unreadable` — never pushed,
    /// never written over. A newer version's copy, here or there, stops the sync with nothing
    /// written on either side. With nothing there and no colour here, nothing is pushed.
    private func syncLabels(remote: [String: Int], state: inout [String: ItemState], report: inout SyncReport) async throws {
        let name = "labels"
        let objectID = codec.objectID(for: name)
        let file = try TagColors.file(for: repository.vault)
        var localOpens = true
        let local: TagColors
        do {
            local = try file.load() ?? TagColors()
        } catch let error as CoreError {
            if case .newerFormat = error { throw error }
            local = TagColors()
            localOpens = false
        } catch {
            local = TagColors()
            localOpens = false
        }
        let localBytes = try JSONCoding.encoder.encode(local)
        let known = state[name]
        let remoteRevision = remote[objectID]
        let localChanged = localOpens && Self.hash(localBytes) != known?.sha256
        let remoteChanged = remoteRevision != nil && remoteRevision != known?.revision

        if let remoteRevision, remoteChanged || localChanged || !localOpens {
            guard let blob = try await transport.fetch(objectID: objectID) else { return }
            let decoded = try codec.decode(blob)
            guard decoded.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(decoded.payload.logicalName)") }
            try DocumentFormat.check(decoded.payload.data, supported: TagColors.supportedFormat, what: "labels.bin")
            let theirs = try JSONCoding.decoder.decode(TagColors.self, from: decoded.payload.data)
            let merged = TagColors.merge(local, theirs)
            let mergedBytes = try JSONCoding.encoder.encode(merged)
            if mergedBytes != localBytes || !localOpens {
                try file.save(merged)
                report.pulled.append(name)
            }
            if mergedBytes != decoded.payload.data {
                try await push(name: name, data: mergedBytes, revision: remoteRevision + 1,
                               expected: remoteRevision, state: &state, report: &report)
            } else {
                state[name] = ItemState(revision: remoteRevision, sha256: Self.hash(mergedBytes))
            }
        } else if remoteRevision == nil, localChanged, !local.choices.isEmpty {
            try await push(name: name, data: localBytes, revision: 1, expected: nil, state: &state, report: &report)
        }
    }

    // MARK: Opaque encrypted files

    /// `merge` (bookmarks, history, cookies) combines both versions record by record — whenever
    /// this device's copy changed and the server holds one, whether or not the server's changed
    /// too; `newer` (config) tells which version is newer, the other is kept as `<file>.conflict`;
    /// the rest (passwords, or a config without times) goes through `resolveConflict`.
    ///
    /// `check` refuses a copy a newer version of the app wrote (docs/UPDATES.md §4). It runs on every
    /// remote copy before it is used — pulled, merged, compared, or written over — and on this
    /// device's copy before the two are merged or compared, so such a copy stops the sync with
    /// nothing written on either side.
    ///
    /// `opens` tells whether a copy opens with the profile's key. This device's copy, whenever it is
    /// to be pushed, merged, compared or written over (it or the server's changed), is looked at
    /// first, and one that does not open goes to `takeServerCopy`: never pushed — it once was, over
    /// the server's good copy, the one a person could take back with Sync Now — and never written
    /// over. A copy unchanged on both sides is not opened: nothing is done with it. `neededToStart`
    /// (the settings): this device's copy lost, the server's is taken back.
    private func syncFile(name: String, url: URL, profileID: UUID, neededToStart: Bool,
                          merge: ((Data, Data) throws -> Data)?,
                          newer: ((Data, Data) throws -> ProfileRepository.NewerVersion?)?,
                          check: (Data) throws -> Void, opens: (Data) -> Bool,
                          keep: (Data, KeptSettings.Origin) throws -> Void,
                          remote: [String: Int], state: inout [String: ItemState], report: inout SyncReport) async throws {
        let objectID = codec.objectID(for: name)
        let localData = FileManager.default.fileExists(atPath: url.path) ? try SecureFile.read(url) : nil
        let known = state[name]
        let remoteRevision = remote[objectID]
        let localChanged = localData.map { Self.hash($0) != known?.sha256 } ?? false
        let remoteChanged = remoteRevision != nil && remoteRevision != known?.revision

        // The settings lost here (a backup put back without them, a stop between moving an
        // unreadable copy aside and writing the server's): the profile does not start without
        // them, so the server's copy is taken whether or not it changed since this device had it.
        if localData == nil, neededToStart, remoteRevision != nil {
            try await pull(name: name, objectID: objectID, url: url, check: check, state: &state, report: &report)
            return
        }
        if localChanged || remoteChanged, let localData, !opens(localData) {
            try await takeServerCopy(name: name, objectID: objectID, url: url, profileID: profileID, remoteRevision: remoteRevision,
                                     check: check, opens: opens, state: &state, report: &report)
            return
        }

        switch (localChanged, remoteChanged) {
        case (false, false):
            return
        case (true, false) where merge == nil || remoteRevision == nil:
            // The settings changed here only, but older than the server's (R2): not an edit, a
            // version put back from a backup. The server's stay the profile's settings, and this
            // Mac's are kept as a version of them — never pushed over the newer ones. The clocks
            // decide only which is the profile's settings; neither is dropped. The same settings
            // with only what the browser keeps for itself changed (the proxy location found at a
            // launch) are no version: pushed as before.
            if let newer, let localData, remoteRevision != nil, let blob = try await transport.fetch(objectID: objectID) {
                let decoded = try codec.decode(blob)
                guard decoded.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(decoded.payload.logicalName)") }
                if !decoded.payload.deleted {
                    try check(localData)
                    try check(decoded.payload.data)
                    if let verdict = try newer(localData, decoded.payload.data), verdict.remoteWins, verdict.keepsConflictCopy {
                        try keep(localData, .restored)
                        try SecureFile.write(decoded.payload.data, to: url)
                        state[name] = ItemState(revision: decoded.revision, sha256: Self.hash(decoded.payload.data))
                        report.pulled.append(name)
                        report.restoredSettings.append(profileID)
                        return
                    }
                }
            }
            try await push(name: name, data: localData!, revision: (remoteRevision ?? 0) + 1,
                           expected: remoteRevision, state: &state, report: &report)
        case (false, true):
            try await pull(name: name, objectID: objectID, url: url, check: check, state: &state, report: &report)
        case (true, _):
            // Both copies changed — or only this device's copy of a mergeable file did, while the
            // server holds one: merged with it as well, never pushed over it. A copy made anew from
            // nothing (the file lost, one bookmark added since) holds only what was added since;
            // pushed as it was, it took everything else off every other device. The merge goes
            // record by record, with each deletion's tombstone, so what was deleted here still is.
            if let localData { try check(localData) }
            if let merge, let localData {
                guard let blob = try await transport.fetch(objectID: objectID) else { return }
                let decoded = try codec.decode(blob)
                guard decoded.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(decoded.payload.logicalName)") }
                if !decoded.payload.deleted { try check(decoded.payload.data) }
                let merged = try merge(localData, decoded.payload.data)
                try SecureFile.write(merged, to: url)
                report.merged.append(name)
                try await push(name: name, data: merged, revision: decoded.revision + 1,
                               expected: decoded.revision, state: &state, report: &report)
                return
            }
            if let newer, let localData {
                guard let blob = try await transport.fetch(objectID: objectID) else { return }
                let decoded = try codec.decode(blob)
                guard decoded.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(decoded.payload.logicalName)") }
                if !decoded.payload.deleted { try check(decoded.payload.data) }
                if let verdict = try newer(localData, decoded.payload.data) {
                    if verdict.keepsConflictCopy { report.resolvedConflicts.append(name) }
                    if verdict.remoteWins {
                        if verdict.keepsConflictCopy { try keep(localData, .thisMac) }
                        try SecureFile.write(decoded.payload.data, to: url)
                        state[name] = ItemState(revision: decoded.revision, sha256: Self.hash(decoded.payload.data))
                        report.pulled.append(name)
                    } else {
                        if verdict.keepsConflictCopy { try keep(decoded.payload.data, .otherDevice) }
                        try await push(name: name, data: localData, revision: decoded.revision + 1,
                                       expected: decoded.revision, state: &state, report: &report)
                    }
                    return
                }
            }
            // Whichever side is kept, the remote copy is looked at first: a newer version's copy
            // is not written over, nor pulled. The side not kept is kept beside, as a version.
            var remoteData: Data?
            if let blob = try await transport.fetch(objectID: objectID) {
                let decoded = try codec.decode(blob)
                if !decoded.payload.deleted {
                    try check(decoded.payload.data)
                    remoteData = decoded.payload.data
                }
            }
            report.resolvedConflicts.append(name)
            switch resolveConflict(name) {
            case .keepLocal:
                if let remoteData { try keep(remoteData, .otherDevice) }
                try await push(name: name, data: localData!, revision: remoteRevision! + 1,
                               expected: remoteRevision, state: &state, report: &report)
            case .keepRemote:
                try keep(localData!, .thisMac)
                try await pull(name: name, objectID: objectID, url: url, check: check, state: &state, report: &report)
            }
        }
    }

    /// This device's copy of a profile file does not open. The server's copy, when there is one
    /// that opens, is taken in its place, and this device's kept beside it as `<file>.unreadable`
    /// (`-2`, `-3`, … when one is there already): nothing unreadable is ever deleted or written
    /// over. Without one, nothing is written on either side. Either way the report says so. A
    /// newer version's copy on the server stops the sync, as everywhere (`check`).
    private func takeServerCopy(name: String, objectID: String, url: URL, profileID: UUID, remoteRevision: Int?,
                                check: (Data) throws -> Void, opens: (Data) -> Bool,
                                state: inout [String: ItemState], report: inout SyncReport) async throws {
        var decoded: (payload: SyncPayload, revision: Int, objectID: String)?
        if remoteRevision != nil, let blob = try await transport.fetch(objectID: objectID) {
            let found = try codec.decode(blob)
            guard found.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(found.payload.logicalName)") }
            decoded = found
        }
        guard let decoded, !decoded.payload.deleted, opens(decoded.payload.data) else {
            report.unreadable.append(.init(profileID: profileID, file: url.lastPathComponent, keptAs: nil))
            return
        }
        try check(decoded.payload.data)
        let aside = try SecureFile.moveAside(url, suffix: "unreadable")
        try SecureFile.write(decoded.payload.data, to: url)
        state[name] = ItemState(revision: decoded.revision, sha256: Self.hash(decoded.payload.data))
        report.pulled.append(name)
        report.unreadable.append(.init(profileID: profileID, file: url.lastPathComponent, keptAs: aside.lastPathComponent))
    }

    private func pull(name: String, objectID: String, url: URL, check: (Data) throws -> Void,
                      state: inout [String: ItemState], report: inout SyncReport) async throws {
        guard let blob = try await transport.fetch(objectID: objectID) else { return }
        let decoded = try codec.decode(blob)
        guard decoded.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(decoded.payload.logicalName)") }
        if !decoded.payload.deleted {
            try check(decoded.payload.data)
            try SecureFile.write(decoded.payload.data, to: url)
        }
        state[name] = ItemState(revision: decoded.revision, sha256: Self.hash(decoded.payload.data))
        report.pulled.append(name)
    }

    private func push(name: String, data: Data, revision: Int, expected: Int?,
                      state: inout [String: ItemState], report: inout SyncReport) async throws {
        let blob = try codec.encode(SyncPayload(logicalName: name, deleted: false, data: data), revision: revision)
        do {
            try await transport.store(objectID: codec.objectID(for: name), revision: revision, data: blob, expectedRevision: expected)
            state[name] = ItemState(revision: revision, sha256: Self.hash(data))
            report.pushed.append(name)
        } catch CoreError.syncConflict {
            report.deferred.append(name)
        }
    }

    // MARK: State

    var stateURL: URL { repository.root.appendingPathComponent("sync-state.bin") }
    var stateAAD: String { "sync-state:v1:\(repository.vault.vaultID.uuidString)" }

    private func loadState() throws -> [String: ItemState] {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [:] }
        let plaintext = try AEAD.open(SecureFile.read(stateURL), key: repository.vault.syncEnvelopeKey, aad: stateAAD)
        // A map of items is format 1; a newer version's state stops the sync before anything is
        // fetched (starting over from nothing would push this device's files over newer ones).
        try DocumentFormat.check(plaintext, supported: 1, what: "sync-state.bin")
        return try JSONCoding.decoder.decode([String: ItemState].self, from: plaintext)
    }

    private func saveState(_ state: [String: ItemState]) throws {
        let plaintext = try JSONCoding.encoder.encode(state)
        try SecureFile.write(AEAD.seal(plaintext, key: repository.vault.syncEnvelopeKey, aad: stateAAD), to: stateURL)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
