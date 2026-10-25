#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A device-bound P-256 key-agreement key. On the Mac the app implements this with the Secure
/// Enclave (`SecureEnclave.P256.KeyAgreement.PrivateKey` with a `.biometryCurrentSet` access
/// control), so every use of the private key needs Touch ID. Tests use a software key.
public protocol QuickUnlockKeyProvider {
    /// Creates a new key. `keyData` is its opaque representation (for the Secure Enclave: a blob
    /// that only this Mac's Secure Enclave can use); it is stored in `quick-unlock.json`.
    func createKey() throws -> (keyData: Data, publicKey: P256.KeyAgreement.PublicKey)
    /// ECDH between the stored key and `peer`. This is the step that asks for Touch ID.
    func sharedSecret(keyData: Data, peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

/// `quick-unlock.json`: the VMK wrapped under a key that only the device-bound key can re-derive.
/// Device-local; never synced and never part of a backup.
public struct QuickUnlockRecord: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var vaultID: UUID
    /// Opaque device key (Secure Enclave blob). Useless on any other Mac.
    public var deviceKey: Data
    public var devicePublicKey: Data
    /// Public half of the throw-away key used when enabling; its private half was discarded.
    public var ephemeralPublicKey: Data
    /// AEAD(KEK, VMK), AAD = `"quick-unlock:v1:<vaultID>"`.
    public var wrappedMasterKey: Data
    public var createdAt: Date
}

/// Unlocking without the master password (Touch ID).
///
/// ```
/// enable:  E = new software P-256 key;  S = ECDH(E.private, D.public);  discard E.private
/// unlock:  S = ECDH(D.private, E.public)     ← Secure Enclave, needs Touch ID
/// KEK = HKDF-SHA256(S, salt: vaultID, info: "quick-unlock:v1" | E.public | D.public)
/// quick-unlock.json = { D (opaque), D.public, E.public, AES-GCM(KEK, VMK) }
/// ```
/// The VMK can be recovered only by this Mac's Secure Enclave after a successful biometric
/// match; adding or removing a fingerprint invalidates the key (`.biometryCurrentSet`), and
/// the app then falls back to the master password. The master password still works and is
/// needed to turn quick unlock on.
public enum QuickUnlock {
    public static func recordURL(in root: URL) -> URL { root.appendingPathComponent("quick-unlock.json") }

    public static func isEnabled(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(in: root).path)
    }

    /// Turns quick unlock on. Re-verifies the master password first, so an unlocked but
    /// unattended session is not enough.
    public static func enable(vault: UnlockedVault, password: String, provider: QuickUnlockKeyProvider) throws {
        _ = try MasterVault.unlock(header: vault.header, root: vault.root, password: password)
        let device = try provider.createKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: device.publicKey)
        let devicePublic = device.publicKey.x963Representation
        let ephemeralPublic = ephemeral.publicKey.x963Representation
        let kek = keyEncryptionKey(secret, vaultID: vault.vaultID, ephemeral: ephemeralPublic, device: devicePublic)
        let record = QuickUnlockRecord(format: QuickUnlockRecord.currentFormat, vaultID: vault.vaultID,
                                       deviceKey: device.keyData, devicePublicKey: devicePublic,
                                       ephemeralPublicKey: ephemeralPublic,
                                       wrappedMasterKey: try vault.wrapMasterKey(with: kek, aad: aad(vault.vaultID)),
                                       createdAt: Date())
        try SecureFile.write(JSONCoding.encoder.encode(record), to: recordURL(in: vault.root))
    }

    public static func disable(in root: URL) {
        try? FileManager.default.removeItem(at: recordURL(in: root))
    }

    /// Unlocks the vault at `root` with the device key. Throws `CoreError.vaultNotFound` when quick
    /// unlock is off, `CoreError.authenticationFailed` when the record no longer matches the
    /// vault or the device key; errors of the provider (e.g. Touch ID cancelled) pass through.
    public static func unlock(in root: URL, provider: QuickUnlockKeyProvider) throws -> UnlockedVault {
        let header = try MasterVault.readHeader(in: root)
        guard isEnabled(in: root) else { throw CoreError.vaultNotFound }
        let record = try JSONCoding.decoder.decode(QuickUnlockRecord.self, from: SecureFile.read(recordURL(in: root)))
        guard record.format == QuickUnlockRecord.currentFormat else {
            throw CoreError.unsupportedFormat("quick unlock format \(record.format)")
        }
        guard record.vaultID == header.vaultID else { throw CoreError.authenticationFailed }
        let ephemeral: P256.KeyAgreement.PublicKey
        do {
            ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: record.ephemeralPublicKey)
        } catch {
            throw CoreError.corruptData("quick unlock public key")
        }
        let secret = try provider.sharedSecret(keyData: record.deviceKey, peer: ephemeral)
        let kek = keyEncryptionKey(secret, vaultID: header.vaultID, ephemeral: record.ephemeralPublicKey,
                                   device: record.devicePublicKey)
        let raw = try AEAD.open(record.wrappedMasterKey, key: kek, aad: aad(header.vaultID))
        guard raw.count == 32 else { throw CoreError.corruptData("master key length") }
        return UnlockedVault(root: root, header: header, masterKey: SymmetricKey(data: raw))
    }

    static func aad(_ vaultID: UUID) -> String { "quick-unlock:v1:\(vaultID.uuidString)" }

    private static func keyEncryptionKey(_ secret: SharedSecret, vaultID: UUID, ephemeral: Data, device: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: vaultID.rawBytes,
                                       sharedInfo: Data("quick-unlock:v1".utf8) + ephemeral + device,
                                       outputByteCount: 32)
    }
}

/// Software implementation (tests, and Macs without a Secure Enclave are simply not offered
/// quick unlock by the app). The "device key" is the raw private key: no hardware protection.
public struct SoftwareQuickUnlockKeyProvider: QuickUnlockKeyProvider {
    public init() {}

    public func createKey() throws -> (keyData: Data, publicKey: P256.KeyAgreement.PublicKey) {
        let key = P256.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey)
    }

    public func sharedSecret(keyData: Data, peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: keyData).sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw CoreError.authenticationFailed
        }
    }
}
