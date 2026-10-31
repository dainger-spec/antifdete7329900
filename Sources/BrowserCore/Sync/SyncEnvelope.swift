#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Wire format of one synced object. This is all the server ever stores.
///
/// ```json
/// {
///   "format":     "pbsync-1",
///   "vaultID":    "<uuid>",
///   "objectID":   "<hex HMAC-SHA256(objectIDKey, logicalName)>",
///   "revision":   7,
///   "ciphertext": "<base64 AES-256-GCM(envelopeKey, SyncPayload JSON)>"
/// }
/// ```
/// AAD of the ciphertext = `"pbsync-1|<vaultID>|<objectID>|<revision>"`, so the server
/// cannot move a blob to another object ID or replay it under a different revision.
///
/// What the server learns: vault ID, number of objects, their sizes, revision counters,
/// and upload timing. It does not learn profile names, settings, URLs, or which object
/// is which (logical names are MAC'd).
///
/// LIMITATION: rollback to an *older* complete set of blobs (with their original
/// revisions) is not detected across devices; that requires a signed, monotonic
/// manifest or a trusted server-side counter.
public struct SyncEnvelope: Codable, Equatable, Sendable {
    public static let currentFormat = "pbsync-1"
    public var format: String
    public var vaultID: UUID
    public var objectID: String
    public var revision: Int
    public var ciphertext: Data
}

/// Decrypted content of an envelope.
public struct SyncPayload: Codable, Equatable, Sendable {
    /// e.g. "index", "profile/<uuid>/config", "profile/<uuid>/passwords".
    public var logicalName: String
    public var deleted: Bool
    public var data: Data
}

/// `@unchecked`: `SymmetricKey` is immutable but not marked Sendable in swift-crypto.
public struct SyncCodec: @unchecked Sendable {
    let vaultID: UUID
    let envelopeKey: SymmetricKey
    let objectIDKey: SymmetricKey

    public init(vault: UnlockedVault) throws {
        self.vaultID = vault.vaultID
        self.envelopeKey = try vault.syncEnvelopeKey
        self.objectIDKey = try vault.syncObjectIDKey
    }

    public func objectID(for logicalName: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(logicalName.utf8), using: objectIDKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public func encode(_ payload: SyncPayload, revision: Int) throws -> Data {
        let objectID = objectID(for: payload.logicalName)
        let ciphertext = try AEAD.seal(JSONCoding.encoder.encode(payload), key: envelopeKey,
                                       aad: Self.aad(vaultID: vaultID, objectID: objectID, revision: revision))
        let envelope = SyncEnvelope(format: SyncEnvelope.currentFormat, vaultID: vaultID,
                                    objectID: objectID, revision: revision, ciphertext: ciphertext)
        return try JSONCoding.encoder.encode(envelope)
    }

    /// Decodes and authenticates a blob. Verifies that the decrypted logical name maps to
    /// the envelope's object ID (prevents a valid blob being served under another name).
    public func decode(_ blob: Data) throws -> (payload: SyncPayload, revision: Int, objectID: String) {
        let envelope = try JSONCoding.decoder.decode(SyncEnvelope.self, from: blob)
        guard envelope.format == SyncEnvelope.currentFormat else { throw CoreError.unsupportedFormat(envelope.format) }
        guard envelope.vaultID == vaultID else { throw CoreError.corruptData("envelope belongs to another vault") }
        let plaintext = try AEAD.open(envelope.ciphertext, key: envelopeKey,
                                      aad: Self.aad(vaultID: vaultID, objectID: envelope.objectID, revision: envelope.revision))
        let payload = try JSONCoding.decoder.decode(SyncPayload.self, from: plaintext)
        guard objectID(for: payload.logicalName) == envelope.objectID else {
            throw CoreError.corruptData("object ID does not match payload name")
        }
        return (payload, envelope.revision, envelope.objectID)
    }

    static func aad(vaultID: UUID, objectID: String, revision: Int) -> String {
        "\(SyncEnvelope.currentFormat)|\(vaultID.uuidString)|\(objectID)|\(revision)"
    }
}
