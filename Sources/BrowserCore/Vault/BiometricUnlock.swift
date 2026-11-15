#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Unlocking with Touch ID: what is kept on this Mac for it, and the rule for when it may open the
/// vault (docs/ARCHITECTURE.md, "Unlocking with Touch ID").
///
/// Off unless the person turns it on (Settings › Security), with the master password typed once.
/// Then two things are kept, and neither opens anything without the other:
///
///   * a random 256-bit key in this Mac's data-protection keychain, readable by this app alone and
///     only after Touch ID with the fingerprints enrolled when it was kept — never on another Mac,
///     never in a backup (the app's `TouchIDUnlock`);
///   * this record, a file in the vault's folder: the vault's master key sealed under that key,
///     with when the master password was last typed, when this Mac had started then, and the
///     count of master-password changes — all bound into the seal, so that a record edited by
///     hand (a later date, another start) does not open.
///
/// Never the master password, and never the vault's key in the clear. The master password still
/// rules: it is asked after this Mac restarts, after `passwordEveryDays` days without typing it,
/// when it was changed, when the fingerprints changed, and whenever Touch ID does not answer.
/// Everything that asks for the master password by itself — changing it, showing saved
/// passwords — keeps asking for it.
///
/// This file is the part that needs no Mac, so that the rule is tested where the core is: the
/// record, the decision, and the opening with the key Touch ID released.
public struct BiometricUnlockRecord: Codable, Equatable, Sendable {
    /// The newest format this version reads and writes.
    public static let currentFormat = 1

    public var format: Int
    public var vaultID: UUID
    /// `VaultHeader.passwordRevision` when this was made: a master password changed since ends it.
    public var passwordRevision: Int
    /// When the master password was last typed to open the vault, or to turn this on (Unix seconds).
    public var passwordTypedAt: Int
    /// When this Mac had started at that moment (Unix seconds): another start asks for the password.
    public var bootTime: Int
    /// The Mac's enrolled fingerprints then, as the system names their set (opaque); nil: not
    /// known. A different set ends it — beside the keychain, which drops the key itself.
    public var biometryState: Data?
    /// AEAD(key in the keychain, the vault's master key), AAD = `aad`.
    public var wrappedMasterKey: Data

    /// Every field above, bound into the seal.
    var aad: String {
        "touch-id-unlock:v1:\(vaultID.uuidString):\(passwordRevision):\(passwordTypedAt):\(bootTime):"
            + (biometryState?.base64EncodedString() ?? "-")
    }
}

public enum BiometricUnlock {
    /// Touch ID opens the vault for this many days after the master password was last typed.
    public static let passwordEveryDays = 14
    /// How far two readings of when this Mac started may differ within one start, in seconds: the
    /// clock is corrected after sleep. A restart moves it by at least the time the Mac had been on.
    public static let bootTolerance = 15

    /// Why the master password is asked although unlocking with Touch ID is turned on.
    public enum PasswordReason: String, Equatable, Sendable, CaseIterable {
        /// This Mac was restarted since the password was typed.
        case restarted
        /// More than `passwordEveryDays` days since it was typed (or the clock was set back).
        case tooLong
        /// The master password was changed since.
        case passwordChanged
        /// The fingerprints enrolled on this Mac changed.
        case fingerprintsChanged
        /// The key is no longer in the keychain (the fingerprints changed, or it was removed).
        case keyGone
        /// What is kept is another vault's.
        case anotherVault
    }

    public enum Decision: Equatable, Sendable {
        /// Not turned on: nothing is kept.
        case off
        /// Touch ID may open the vault now.
        case touchID
        /// Turned on, and the master password is asked this time.
        case password(PasswordReason)
    }

    /// Whether Touch ID may open the vault now. `record`: what is kept beside the vault (nil:
    /// nothing); `bootTime`: when this Mac started; `biometryState`: the enrolled fingerprints'
    /// set now (nil: not readable now); `keyKept`: the key is in the keychain.
    public static func decide(record: BiometricUnlockRecord?, header: VaultHeader, now: Date, bootTime: Int,
                              biometryState: Data?, keyKept: Bool) -> Decision {
        guard let record else { return .off }
        guard record.vaultID == header.vaultID else { return .password(.anotherVault) }
        guard record.passwordRevision == (header.passwordRevision ?? 0) else { return .password(.passwordChanged) }
        guard keyKept else { return .password(.keyGone) }
        if let then = record.biometryState, let current = biometryState, then != current { return .password(.fingerprintsChanged) }
        guard abs(bootTime - record.bootTime) <= bootTolerance else { return .password(.restarted) }
        let elapsed = Int(now.timeIntervalSince1970) - record.passwordTypedAt
        guard elapsed >= -bootTolerance, elapsed <= passwordEveryDays * 86_400 else { return .password(.tooLong) }
        return .touchID
    }

    /// A reason that ends it: what is kept is removed, and it is turned on again in Settings, with
    /// the master password. After a restart or too long a time it stays on, and the next unlock
    /// with the password starts the days anew.
    public static func ends(_ reason: PasswordReason) -> Bool {
        switch reason {
        case .restarted, .tooLong: return false
        case .passwordChanged, .fingerprintsChanged, .keyGone, .anotherVault: return true
        }
    }

    // MARK: What is kept beside the vault

    public static func recordURL(in root: URL) -> URL { root.appendingPathComponent("unlock-touchid.json") }

    /// The record beside the vault; nil when there is none — or one this version cannot read
    /// (damaged, or a newer version's): it then counts as turned off, and turning it on writes
    /// this version's. Nothing is lost with it: it holds nothing that the master password does
    /// not give back.
    public static func load(in root: URL) -> BiometricUnlockRecord? {
        guard let json = try? SecureFile.read(recordURL(in: root)),
              let record = try? JSONCoding.decoder.decode(BiometricUnlockRecord.self, from: json),
              (1...BiometricUnlockRecord.currentFormat).contains(record.format) else { return nil }
        return record
    }

    public static func save(_ record: BiometricUnlockRecord, in root: URL) throws {
        try SecureFile.write(JSONCoding.encoder.encode(record), to: recordURL(in: root))
    }

    /// Removes the record; true when none is left (there was none, or it went).
    @discardableResult
    public static func remove(in root: URL) -> Bool {
        let url = recordURL(in: root)
        try? FileManager.default.removeItem(at: url)
        return !FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Turning it on, and opening

    /// Makes what is kept: a new random key (for the keychain, behind Touch ID) and the record
    /// that holds the vault's master key under it. `vault` must have been opened with the master
    /// password — a profile's own process, opened with a grant, is refused. The caller keeps the
    /// key first and saves the record only once it is kept.
    public static func enroll(_ vault: UnlockedVault, now: Date, bootTime: Int, biometryState: Data?) throws
        -> (record: BiometricUnlockRecord, key: Data) {
        let key = SymmetricKey(size: .bits256)
        var record = BiometricUnlockRecord(format: BiometricUnlockRecord.currentFormat, vaultID: vault.vaultID,
                                           passwordRevision: vault.header.passwordRevision ?? 0,
                                           passwordTypedAt: Int(now.timeIntervalSince1970), bootTime: bootTime,
                                           biometryState: biometryState, wrappedMasterKey: Data())
        record.wrappedMasterKey = try vault.sealedMasterKey(under: key, aad: record.aad)
        return (record, key.rawBytes)
    }

    /// Opens the vault in `root` with the key Touch ID released. The record must be this vault's,
    /// made with its current master password, and exactly as it was sealed: one whose dates were
    /// edited does not open (`CoreError.authenticationFailed`), nor does one under another key.
    public static func unlock(root: URL, record: BiometricUnlockRecord, key: Data) throws -> UnlockedVault {
        let header = try MasterVault.readHeader(in: root)
        guard record.vaultID == header.vaultID else { throw CoreError.corruptData("the Touch ID record is another vault's") }
        guard record.passwordRevision == (header.passwordRevision ?? 0) else { throw CoreError.wrongPassword }
        guard key.count == 32 else { throw CoreError.corruptData("Touch ID key length") }
        var raw = try AEAD.open(record.wrappedMasterKey, key: SymmetricKey(data: key), aad: record.aad)
        defer { wipe(&raw) }
        return try MasterVault.unlock(header: header, root: root, masterKey: raw)
    }
}
