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
    /// The sync location's vault header against this device's (`SyncEngine.publishVaultHeader`).
    public var passwordHeader: PasswordHeader = .same

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
/// Profile files are already encrypted with per-profile keys; the envelope adds a second
/// layer that hides object names and binds blobs to their name and revision.
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

        let profilesBefore = Set(repository.list().map(\.id))
        try await syncIndex(remote: remote, state: &state, report: &report)

        let index = repository.currentIndex()
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
                try await syncFile(name: "profile/\(id.uuidString)/\(file.rawValue)", url: repository.url(of: file, for: id),
                                   merge: merge, newer: newer, check: check, remote: remote, state: &state, report: &report)
            }
        }

        let profilesAfter = Set(index.entries.map(\.summary.id))
        report.deletedProfileIDs = profilesBefore.subtracting(profilesAfter).sorted { $0.uuidString < $1.uuidString }
        repository.removeOrphanedDirectories()
        return report
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
    private func syncFile(name: String, url: URL, merge: ((Data, Data) throws -> Data)?,
                          newer: ((Data, Data) throws -> ProfileRepository.NewerVersion?)?,
                          check: (Data) throws -> Void,
                          remote: [String: Int], state: inout [String: ItemState], report: inout SyncReport) async throws {
        let objectID = codec.objectID(for: name)
        let localData = FileManager.default.fileExists(atPath: url.path) ? try SecureFile.read(url) : nil
        let known = state[name]
        let remoteRevision = remote[objectID]
        let localChanged = localData.map { Self.hash($0) != known?.sha256 } ?? false
        let remoteChanged = remoteRevision != nil && remoteRevision != known?.revision

        switch (localChanged, remoteChanged) {
        case (false, false):
            return
        case (true, false) where merge == nil || remoteRevision == nil:
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
                    let conflictURL = url.appendingPathExtension("conflict")
                    if verdict.remoteWins {
                        if verdict.keepsConflictCopy { try SecureFile.write(localData, to: conflictURL) }
                        try SecureFile.write(decoded.payload.data, to: url)
                        state[name] = ItemState(revision: decoded.revision, sha256: Self.hash(decoded.payload.data))
                        report.pulled.append(name)
                    } else {
                        if verdict.keepsConflictCopy { try SecureFile.write(decoded.payload.data, to: conflictURL) }
                        try await push(name: name, data: localData, revision: decoded.revision + 1,
                                       expected: decoded.revision, state: &state, report: &report)
                    }
                    return
                }
            }
            // Whichever side is kept, the remote copy is looked at first: a newer version's copy
            // is not written over, nor pulled.
            if let blob = try await transport.fetch(objectID: objectID) {
                let decoded = try codec.decode(blob)
                if !decoded.payload.deleted { try check(decoded.payload.data) }
            }
            report.resolvedConflicts.append(name)
            switch resolveConflict(name) {
            case .keepLocal:
                try await push(name: name, data: localData!, revision: remoteRevision! + 1,
                               expected: remoteRevision, state: &state, report: &report)
            case .keepRemote:
                try SecureFile.write(localData!, to: url.appendingPathExtension("conflict"))
                try await pull(name: name, objectID: objectID, url: url, check: check, state: &state, report: &report)
            }
        }
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
