#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The token of a synced profile, told to the account server with a renewal (`profileTokens`, the
/// server's docs/CONTRACT.md §6.2 and §8.4; question 14 of its docs/SYNC_SERVER.md, decided 10
/// November 2026): a profile that sync has on several devices of a license takes one place of
/// `limits.profiles`, and the server knows which profiles are one by this token alone.
///
/// ```
/// K     = HKDF-SHA256(IKM = VMK, salt = the vault's salt, info = "sync-profile-count", L = 32)
/// token = lowercase hex of the first 16 bytes of HMAC-SHA256(K, "profile/" + the profile's UUID)
/// ```
///
/// The key is the vault's, as the one of the object names is (`sync-object-id`): the server knows
/// neither, so a token says nothing of the profile, and tokens of two vaults cannot be matched. The
/// UUID is written as in the logical names of the profile's objects (`profile/<uuid>/config`,
/// `SyncEngine`): `UUID.uuidString` — upper-case hexadecimal with hyphens. Another device of the
/// vault must write it the same way, or its token of the same profile is another one.
public enum SyncProfileToken {
    /// The token of `profileID` in `vault`. Throws without the master key (a profile's own process).
    public static func token(for profileID: UUID, vault: UnlockedVault) throws -> String {
        token(for: profileID, key: try vault.syncProfileCountKey)
    }

    static func token(for profileID: UUID, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("profile/\(profileID.uuidString)".utf8), using: key)
        return Array(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The tokens of the profiles of this device that are in the sync vault (`SyncEngine.
    /// syncedProfileIDs`), sorted. Empty before the first sync.
    public static func tokens(in repository: ProfileRepository) -> [String] {
        SyncEngine.syncedProfileIDs(in: repository).compactMap { try? token(for: $0, vault: repository.vault) }.sorted()
    }
}
