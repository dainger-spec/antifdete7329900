#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A device that keeps a key instead of asking for the master password at every start — Lumen for
/// iPhone (its ios/SYNC_PLAN.md, decision 1: the password entered once, the key kept in the
/// Keychain, this device only, behind Face ID or the passcode; the password itself kept nowhere).
///
/// The key kept is the password's key (KEK): what the master password derives under the header's
/// KDF, and what unwraps the vault's master key. It opens the vault only with the header it was made
/// for: after a change of the master password (a new KDF salt, a new wrapping) it no longer does,
/// and the device asks for the new password — as a Mac on the old `vault.json` keeps the old one
/// (SYNC_FORMAT.md, Limitations). Added for the iPhone; nothing on the Mac uses it.
extension MasterVault {
    /// The key a device keeps for `header`, checked to open it: `CoreError.wrongPassword` when the
    /// password is not the vault's.
    public static func deviceUnlockKey(password: String, header: VaultHeader) throws -> Data {
        let kek = try KeyDerivation.deriveKey(password: password, parameters: header.kdf)
        var raw = try unwrapMasterKey(header: header, kek: kek)
        wipe(&raw)
        return kek.rawBytes
    }

    /// The vault opened with a kept key (`deviceUnlockKey`) instead of the password.
    public static func unlock(header: VaultHeader, root: URL, deviceUnlockKey: Data) throws -> UnlockedVault {
        guard deviceUnlockKey.count == 32 else { throw CoreError.wrongPassword }
        var raw = try unwrapMasterKey(header: header, kek: SymmetricKey(data: deviceUnlockKey))
        defer { wipe(&raw) }
        return UnlockedVault(root: root, header: header, masterKey: SymmetricKey(data: raw))
    }

    private static func unwrapMasterKey(header: VaultHeader, kek: SymmetricKey) throws -> Data {
        let raw: Data
        do {
            raw = try AEAD.open(header.wrappedMasterKey, key: kek, aad: VaultHeader.aad(for: header.vaultID))
        } catch CoreError.authenticationFailed {
            throw CoreError.wrongPassword
        }
        guard raw.count == 32 else { throw CoreError.corruptData("master key length") }
        return raw
    }
}
