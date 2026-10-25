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
    public var resolvedConflicts: [String] = []
    /// Profiles deleted on another device and removed locally. The app layer must also
    /// remove their WebKit data stores.
    public var deletedProfileIDs: [UUID] = []
}

/// Client side of the optional encrypted sync.
///
/// Synced objects:
/// * `vault-header`            plaintext `VaultHeader` (salt, KDF params, wrapped VMK) — lets a
///                             new device unlock with the master password.
/// * `index`                   the profile index; merged automatically (see `ProfileIndex.merge`).
/// * `profile/<id>/config`     the profile's encrypted `config.bin`, as-is.
/// * `profile/<id>/passwords`  the profile's encrypted `passwords.bin`, as-is.
///
/// Profile files are already encrypted with per-profile keys; the envelope adds a second
/// layer that hides object names and binds blobs to their name and revision.
///
/// NOT synced: WebKit data store archives (cookies/localStorage/IndexedDB/cache). They are
/// large and only consistent while the profile is stopped. Syncing them would reuse
/// `EncryptedDirectoryArchive` output as an additional object type.
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
                resolveConflict: @escaping @Sendable (String) -> SyncConflictResolution = { _ in .keepRemote }) {
        self.repository = repository
        self.transport = transport
        self.codec = SyncCodec(vault: repository.vault)
        self.resolveConflict = resolveConflict
    }

    /// New-device setup: download the vault header, verify the master password against it,
    /// and write it locally. Follow with `ProfileRepository(vault:)` + `SyncEngine.sync()`.
    public static func bootstrap(transport: SyncTransport, root: URL, password: String) async throws -> UnlockedVault {
        guard !MasterVault.exists(in: root) else { throw CoreError.vaultAlreadyExists }
        guard let blob = try await transport.fetch(objectID: vaultHeaderObjectID) else { throw CoreError.vaultNotFound }
        let header = try JSONCoding.decoder.decode(VaultHeader.self, from: blob)
        let vault = try MasterVault.unlock(header: header, root: root, password: password)
        try MasterVault.writeHeader(header, in: root)
        return vault
    }

    /// Uploads the current vault header (e.g. after a master-password change).
    public func publishVaultHeader() async throws {
        let remote = try await transport.listObjects().first { $0.objectID == Self.vaultHeaderObjectID }
        if let remote, let blob = try await transport.fetch(objectID: Self.vaultHeaderObjectID) {
            let existing = try JSONCoding.decoder.decode(VaultHeader.self, from: blob)
            guard existing.vaultID == repository.vault.vaultID else {
                throw CoreError.corruptData("sync location holds a different vault")
            }
            if existing == repository.vault.header { return }
            try await transport.store(objectID: Self.vaultHeaderObjectID, revision: remote.revision + 1,
                                      data: JSONCoding.encoder.encode(repository.vault.header),
                                      expectedRevision: remote.revision)
        } else {
            try await transport.store(objectID: Self.vaultHeaderObjectID, revision: 1,
                                      data: JSONCoding.encoder.encode(repository.vault.header), expectedRevision: nil)
        }
    }

    public func sync() async throws -> SyncReport {
        var report = SyncReport()
        var state = try loadState()
        defer { try? saveState(state) }

        let remoteObjects = try await transport.listObjects()
        if !remoteObjects.contains(where: { $0.objectID == Self.vaultHeaderObjectID }) {
            try await publishVaultHeader()
        } else if let blob = try await transport.fetch(objectID: Self.vaultHeaderObjectID),
                  try JSONCoding.decoder.decode(VaultHeader.self, from: blob).vaultID != repository.vault.vaultID {
            throw CoreError.corruptData("sync location holds a different vault")
        }
        let remote = Dictionary(remoteObjects.map { ($0.objectID, $0.revision) }, uniquingKeysWith: max)

        let profilesBefore = Set(repository.list().map(\.id))
        try await syncIndex(remote: remote, state: &state, report: &report)

        let index = repository.currentIndex()
        for entry in index.entries {
            let id = entry.summary.id
            try await syncFile(name: "profile/\(id.uuidString)/config", url: repository.configURL(for: id),
                               remote: remote, state: &state, report: &report)
            try await syncFile(name: "profile/\(id.uuidString)/passwords", url: repository.passwordsURL(for: id),
                               remote: remote, state: &state, report: &report)
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

        if let remoteRevision = remote[objectID], remoteRevision != known?.revision {
            guard let blob = try await transport.fetch(objectID: objectID) else { return }
            let decoded = try codec.decode(blob)
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
        } else if Self.hash(localBytes) != known?.sha256 {
            let remoteRevision = remote[objectID]
            try await push(name: name, data: localBytes, revision: (remoteRevision ?? 0) + 1,
                           expected: remoteRevision, state: &state, report: &report)
        }
    }

    // MARK: Opaque encrypted files

    private func syncFile(name: String, url: URL, remote: [String: Int],
                          state: inout [String: ItemState], report: inout SyncReport) async throws {
        let objectID = codec.objectID(for: name)
        let localData = FileManager.default.fileExists(atPath: url.path) ? try SecureFile.read(url) : nil
        let known = state[name]
        let remoteRevision = remote[objectID]
        let localChanged = localData.map { Self.hash($0) != known?.sha256 } ?? false
        let remoteChanged = remoteRevision != nil && remoteRevision != known?.revision

        switch (localChanged, remoteChanged) {
        case (false, false):
            return
        case (true, false):
            try await push(name: name, data: localData!, revision: (remoteRevision ?? 0) + 1,
                           expected: remoteRevision, state: &state, report: &report)
        case (false, true):
            try await pull(name: name, objectID: objectID, url: url, state: &state, report: &report)
        case (true, true):
            report.resolvedConflicts.append(name)
            switch resolveConflict(name) {
            case .keepLocal:
                try await push(name: name, data: localData!, revision: remoteRevision! + 1,
                               expected: remoteRevision, state: &state, report: &report)
            case .keepRemote:
                try SecureFile.write(localData!, to: url.appendingPathExtension("conflict"))
                try await pull(name: name, objectID: objectID, url: url, state: &state, report: &report)
            }
        }
    }

    private func pull(name: String, objectID: String, url: URL,
                      state: inout [String: ItemState], report: inout SyncReport) async throws {
        guard let blob = try await transport.fetch(objectID: objectID) else { return }
        let decoded = try codec.decode(blob)
        guard decoded.payload.logicalName == name else { throw CoreError.corruptData("unexpected object \(decoded.payload.logicalName)") }
        if !decoded.payload.deleted {
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

    private var stateURL: URL { repository.root.appendingPathComponent("sync-state.bin") }
    private var stateAAD: String { "sync-state:v1:\(repository.vault.vaultID.uuidString)" }

    private func loadState() throws -> [String: ItemState] {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [:] }
        let plaintext = try AEAD.open(SecureFile.read(stateURL), key: repository.vault.syncEnvelopeKey, aad: stateAAD)
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
