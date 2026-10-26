#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Plaintext vault header (`vault.json`). Contains nothing secret: the KDF salt and
/// parameters, and the vault master key wrapped (AES-GCM) under the password-derived key.
///
/// Anyone holding this file can run an offline password-guessing attack, bounded
/// only by the KDF cost. That is inherent to any password-only scheme; choose a
/// strong master password.
public struct VaultHeader: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var vaultID: UUID
    public var kdf: KDFParameters
    /// AEAD(KEK, VMK), AAD = `"vault-master-key:v1:<vaultID>"`.
    public var wrappedMasterKey: Data
    public var createdAt: Date

    static func aad(for vaultID: UUID) -> String { "vault-master-key:v1:\(vaultID.uuidString)" }
}

/// Key hierarchy
/// ```
/// master password ──PBKDF2──▶ KEK ──unwraps──▶ VMK (random 256-bit, vault master key)
///                                               ├─HKDF "profile-index"   ▶ index key
///                                               ├─HKDF "profile-key-wrap"▶ wraps per-profile keys
///                                               ├─HKDF "sync-envelope"   ▶ sync encryption key
///                                               ├─HKDF "sync-object-id"  ▶ sync object-name MAC key
///                                               └─HKDF "device-settings" ▶ settings.bin (not synced)
/// per-profile key (random 256-bit, stored wrapped in the index)
///                                               ├─ encrypts profile configuration
///                                               ├─HKDF "passwords"       ▶ password vault key
///                                               └─HKDF "webdata-archive" ▶ per-archive WebKit data keys
/// ```
/// Changing the master password only re-wraps the VMK; no data is re-encrypted.
public enum MasterVault {
    public static func headerURL(in root: URL) -> URL { root.appendingPathComponent("vault.json") }

    public static func exists(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: headerURL(in: root).path)
    }

    public static func create(in root: URL, password: String,
                              iterations: Int = KDFParameters.recommendedIterations) throws -> UnlockedVault {
        guard !exists(in: root) else { throw CoreError.vaultAlreadyExists }
        guard !password.isEmpty else { throw CoreError.invalidConfiguration("empty master password") }
        let vaultID = UUID()
        let kdf = KDFParameters.generate(iterations: iterations)
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        let vmk = SymmetricKey(size: .bits256)
        let wrapped = try AEAD.seal(vmk.rawBytes, key: kek, aad: VaultHeader.aad(for: vaultID))
        let header = VaultHeader(format: VaultHeader.currentFormat, vaultID: vaultID, kdf: kdf,
                                 wrappedMasterKey: wrapped, createdAt: Date())
        try writeHeader(header, in: root)
        return UnlockedVault(root: root, header: header, masterKey: vmk)
    }

    public static func readHeader(in root: URL) throws -> VaultHeader {
        guard exists(in: root) else { throw CoreError.vaultNotFound }
        let header = try JSONCoding.decoder.decode(VaultHeader.self, from: SecureFile.read(headerURL(in: root)))
        guard header.format == VaultHeader.currentFormat else {
            throw CoreError.unsupportedFormat("vault format \(header.format)")
        }
        return header
    }

    public static func unlock(in root: URL, password: String) throws -> UnlockedVault {
        let header = try readHeader(in: root)
        return try unlock(header: header, root: root, password: password)
    }

    /// Also used by sync bootstrap: a second device fetches the header blob and unlocks with it.
    public static func unlock(header: VaultHeader, root: URL, password: String) throws -> UnlockedVault {
        let kek = try KeyDerivation.deriveKey(password: password, parameters: header.kdf)
        let raw: Data
        do {
            raw = try AEAD.open(header.wrappedMasterKey, key: kek, aad: VaultHeader.aad(for: header.vaultID))
        } catch CoreError.authenticationFailed {
            throw CoreError.wrongPassword
        }
        guard raw.count == 32 else { throw CoreError.corruptData("master key length") }
        return UnlockedVault(root: root, header: header, masterKey: SymmetricKey(data: raw))
    }

    /// Moves the whole vault folder aside — nothing is deleted — so that a new vault can be created
    /// in `root`: the way out when the master password is unknown. The backup is a sibling folder
    /// named `<root>-backup-<yyyy-MM-dd-HHmmss>` (with a counter if that exists); renaming it back
    /// to `root` restores the old vault. Returns the backup folder.
    public static func moveAside(_ root: URL, date: Date = Date()) throws -> URL {
        guard exists(in: root) else { throw CoreError.vaultNotFound }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let parent = root.standardizedFileURL.deletingLastPathComponent()
        let base = "\(root.standardizedFileURL.lastPathComponent)-backup-\(formatter.string(from: date))"
        var backup = parent.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = parent.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.moveItem(at: root, to: backup)
        return backup
    }

    static func writeHeader(_ header: VaultHeader, in root: URL) throws {
        try SecureFile.ensureDirectory(root)
        try SecureFile.write(JSONCoding.encoder.encode(header), to: headerURL(in: root))
    }
}

/// An unlocked vault: holds the vault master key in memory until released.
public final class UnlockedVault: @unchecked Sendable {
    public let root: URL
    public private(set) var header: VaultHeader
    private let masterKey: SymmetricKey

    init(root: URL, header: VaultHeader, masterKey: SymmetricKey) {
        self.root = root
        self.header = header
        self.masterKey = masterKey
    }

    public var vaultID: UUID { header.vaultID }

    var indexKey: SymmetricKey { masterKey.derive(info: "profile-index", salt: vaultSalt) }
    var profileKeyWrappingKey: SymmetricKey { masterKey.derive(info: "profile-key-wrap", salt: vaultSalt) }
    var syncEnvelopeKey: SymmetricKey { masterKey.derive(info: "sync-envelope", salt: vaultSalt) }
    var syncObjectIDKey: SymmetricKey { masterKey.derive(info: "sync-object-id", salt: vaultSalt) }
    var settingsKey: SymmetricKey { masterKey.derive(info: "device-settings", salt: vaultSalt) }

    private var vaultSalt: Data { withUnsafeBytes(of: header.vaultID.uuid) { Data($0) } }

    /// Re-wraps the VMK under a key derived from `newPassword`. Data keys are unchanged.
    public func changePassword(current: String, new newPassword: String,
                               iterations: Int = KDFParameters.recommendedIterations) throws {
        // Re-verify the current password: an unlocked session alone must not be
        // enough to change it (e.g. an unattended unlocked machine).
        _ = try MasterVault.unlock(header: header, root: root, password: current)
        guard !newPassword.isEmpty else { throw CoreError.invalidConfiguration("empty master password") }
        let kdf = KDFParameters.generate(iterations: iterations)
        let kek = try KeyDerivation.deriveKey(password: newPassword, parameters: kdf)
        var updated = header
        updated.kdf = kdf
        updated.wrappedMasterKey = try AEAD.seal(masterKey.rawBytes, key: kek, aad: VaultHeader.aad(for: header.vaultID))
        try MasterVault.writeHeader(updated, in: root)
        header = updated
    }
}

enum JSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
}
