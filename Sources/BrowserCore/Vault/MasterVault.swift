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
/// master password ──Argon2id──▶ KEK ──unwraps──▶ VMK (random 256-bit, vault master key)
///                  (PBKDF2 in vaults from before Argon2id, until their next unlock)
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

    /// `iterations`: PBKDF2 with that many iterations instead of Argon2id, for fast vaults in tests
    /// and the self-test. The app passes none: Argon2id (`KDFParameters.recommended()`).
    public static func create(in root: URL, password: String, iterations: Int? = nil) throws -> UnlockedVault {
        guard !exists(in: root) else { throw CoreError.vaultAlreadyExists }
        guard !password.isEmpty else { throw CoreError.invalidConfiguration("empty master password") }
        let vaultID = UUID()
        let kdf = iterations.map { KDFParameters.generate(iterations: $0) } ?? .recommended()
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        let vmk = SymmetricKey(size: .bits256)
        var raw = vmk.rawBytes
        defer { wipe(&raw) }
        let wrapped = try AEAD.seal(raw, key: kek, aad: VaultHeader.aad(for: vaultID))
        let header = VaultHeader(format: VaultHeader.currentFormat, vaultID: vaultID, kdf: kdf,
                                 wrappedMasterKey: wrapped, createdAt: Date())
        // The check above is only a fast path: two creates (a double click, two app instances)
        // can both pass it. The exclusive write is the real guard — exactly one header lands,
        // and the loser gets an error instead of keeping a vault that no longer matches the disk.
        try createHeader(header, in: root)
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
        var raw: Data
        do {
            raw = try AEAD.open(header.wrappedMasterKey, key: kek, aad: VaultHeader.aad(for: header.vaultID))
        } catch CoreError.authenticationFailed {
            throw CoreError.wrongPassword
        }
        defer { wipe(&raw) }
        guard raw.count == 32 else { throw CoreError.corruptData("master key length") }
        return UnlockedVault(root: root, header: header, masterKey: SymmetricKey(data: raw))
    }

    /// Opens the vault with the master key itself, without a password.
    ///
    /// For one purpose: the app hands this key to its own per-profile child process over a pipe, so
    /// that the child opens the same vault without asking for the master password a second time
    /// (`ProfileProcess`). The key never goes into a file, a command line or the environment.
    public static func open(in root: URL, masterKeyMaterial: Data) throws -> UnlockedVault {
        let header = try readHeader(in: root)
        guard masterKeyMaterial.count == 32 else { throw CoreError.corruptData("master key length") }
        return UnlockedVault(root: root, header: header, masterKey: SymmetricKey(data: masterKeyMaterial))
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

    /// Writes a new vault's header; fails with `vaultAlreadyExists` if one is already there.
    static func createHeader(_ header: VaultHeader, in root: URL) throws {
        try SecureFile.ensureDirectory(root)
        guard try SecureFile.createNew(JSONCoding.encoder.encode(header), at: headerURL(in: root)) else {
            throw CoreError.vaultAlreadyExists
        }
    }

    /// Replaces the header of an existing vault (master-password change).
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

    /// The vault master key, to be handed to this app's own per-profile child process over a pipe
    /// and opened there with `MasterVault.open(in:masterKeyMaterial:)`. Everything else derives
    /// purpose-specific keys from it below, and nothing else should read it: it must never be
    /// written to a file, a command line or the environment.
    public var masterKeyMaterial: Data { masterKey.rawBytes }

    var indexKey: SymmetricKey { masterKey.derive(info: "profile-index", salt: vaultSalt) }
    var profileKeyWrappingKey: SymmetricKey { masterKey.derive(info: "profile-key-wrap", salt: vaultSalt) }
    var syncEnvelopeKey: SymmetricKey { masterKey.derive(info: "sync-envelope", salt: vaultSalt) }
    var syncObjectIDKey: SymmetricKey { masterKey.derive(info: "sync-object-id", salt: vaultSalt) }
    var settingsKey: SymmetricKey { masterKey.derive(info: "device-settings", salt: vaultSalt) }
    /// The proxy list (`proxies.bin`, `ProxyList`): this Mac's, never synced, like the settings.
    var proxyListKey: SymmetricKey { masterKey.derive(info: "proxy-list", salt: vaultSalt) }

    private var vaultSalt: Data { withUnsafeBytes(of: header.vaultID.uuid) { Data($0) } }

    /// Whether `password` opens this vault (one key derivation: Argon2id, a fraction of a second).
    /// Asked before saved passwords are shown, as Safari asks for Touch ID or the login password.
    public func verifyPassword(_ password: String) -> Bool {
        (try? MasterVault.unlock(header: header, root: root, password: password)) != nil
    }

    /// Re-wraps the VMK under a key derived from `newPassword` (Argon2id, or PBKDF2 with
    /// `iterations` for tests). Data keys are unchanged.
    public func changePassword(current: String, new newPassword: String, iterations: Int? = nil) throws {
        // Re-verify the current password: an unlocked session alone must not be
        // enough to change it (e.g. an unattended unlocked machine).
        _ = try MasterVault.unlock(header: header, root: root, password: current)
        guard !newPassword.isEmpty else { throw CoreError.invalidConfiguration("empty master password") }
        try rewrap(password: newPassword, kdf: iterations.map { KDFParameters.generate(iterations: $0) } ?? .recommended())
    }

    /// A vault from before Argon2id (PBKDF2): re-wraps the VMK under `kdf` (Argon2id) with the
    /// password it was just unlocked with. That password is checked against the header again —
    /// the VMK is never re-wrapped under a password that does not open the vault. Data keys are
    /// unchanged. Returns whether the header was upgraded.
    @discardableResult
    public func upgradeKDFIfNeeded(password: String, to kdf: KDFParameters = .recommended()) throws -> Bool {
        guard !header.kdf.isMemoryHard, kdf.isMemoryHard else { return false }
        _ = try MasterVault.unlock(header: header, root: root, password: password)
        try rewrap(password: password, kdf: kdf)
        return true
    }

    private func rewrap(password: String, kdf: KDFParameters) throws {
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        var raw = masterKey.rawBytes
        defer { wipe(&raw) }
        var updated = header
        updated.kdf = kdf
        updated.wrappedMasterKey = try AEAD.seal(raw, key: kek, aad: VaultHeader.aad(for: header.vaultID))
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
