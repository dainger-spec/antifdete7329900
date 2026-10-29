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
    /// The vault's format, and with it the generation of everything in the vault: a later version
    /// raises it before it writes anything an older one could not read, and every older version
    /// then refuses the whole vault — those from before this rule too, which open only format 1
    /// (docs/UPDATES.md §4, R3).
    public static let currentFormat = 1

    public var format: Int
    public var vaultID: UUID
    public var kdf: KDFParameters
    /// AEAD(KEK, VMK), AAD = `"vault-master-key:v1:<vaultID>"`.
    public var wrappedMasterKey: Data
    public var createdAt: Date

    static func aad(for vaultID: UUID) -> String { "vault-master-key:v1:\(vaultID.uuidString)" }

    /// A header's JSON (`vault.json`, or its copy on the sync server), refused before it is decoded
    /// when a newer version wrote it: nothing in the vault is opened then.
    public static func decodeChecked(_ json: Data) throws -> VaultHeader {
        try DocumentFormat.check(json, supported: currentFormat, what: "vault.json")
        let header = try JSONCoding.decoder.decode(VaultHeader.self, from: json)
        guard header.format == currentFormat else { throw CoreError.unsupportedFormat("vault format \(header.format)") }
        return header
    }
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
        return try VaultHeader.decodeChecked(SecureFile.read(headerURL(in: root)))
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

    /// Opens the vault for one profile, without a password: the vault a profile's own process
    /// works in (`ProfileGrant`, which the app hands to that process over a pipe). It reads and
    /// writes that profile's files and refuses everything else the vault holds.
    public static func open(in root: URL, grant: ProfileGrant) throws -> UnlockedVault {
        UnlockedVault(root: root, header: try readHeader(in: root), grant: grant)
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

    /// Replaces the header of an existing vault (master-password change) — never one that a newer
    /// version wrote since this one read it (docs/UPDATES.md §4).
    static func writeHeader(_ header: VaultHeader, in root: URL) throws {
        try SecureFile.ensureDirectory(root)
        _ = try VaultHeader.decodeChecked(SecureFile.read(headerURL(in: root)))
        try SecureFile.write(JSONCoding.encoder.encode(header), to: headerURL(in: root))
    }
}

/// An unlocked vault: holds the vault master key in memory until released — or, in a profile's
/// own process, only that profile's key (`grant`).
public final class UnlockedVault: @unchecked Sendable {
    public let root: URL
    public private(set) var header: VaultHeader
    /// Nil in a vault opened for one profile.
    private let masterKey: SymmetricKey?
    /// The one profile this vault was opened for (`MasterVault.open(in:grant:)`); nil when it was
    /// opened with the master password and holds the whole vault.
    public let grant: ProfileGrant?

    init(root: URL, header: VaultHeader, masterKey: SymmetricKey) {
        self.root = root
        self.header = header
        self.masterKey = masterKey
        self.grant = nil
    }

    init(root: URL, header: VaultHeader, grant: ProfileGrant) {
        self.root = root
        self.header = header
        self.masterKey = nil
        self.grant = grant
    }

    public var vaultID: UUID { header.vaultID }

    var indexKey: SymmetricKey { get throws { try vaultKey("profile-index") } }
    var profileKeyWrappingKey: SymmetricKey { get throws { try vaultKey("profile-key-wrap") } }
    var syncEnvelopeKey: SymmetricKey { get throws { try vaultKey("sync-envelope") } }
    var syncObjectIDKey: SymmetricKey { get throws { try vaultKey("sync-object-id") } }
    var settingsKey: SymmetricKey { get throws { try vaultKey("device-settings") } }
    /// The proxy list (`proxies.bin`, `ProxyList`): this Mac's, never synced, like the settings.
    var proxyListKey: SymmetricKey { get throws { try vaultKey("proxy-list") } }

    private func vaultKey(_ purpose: String) throws -> SymmetricKey {
        guard let masterKey else { throw CoreError.notGranted(purpose) }
        return masterKey.derive(info: purpose, salt: vaultSalt)
    }

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
        guard let masterKey else { throw CoreError.notGranted("master password") }
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
