import CryptoKit
import Foundation

/// The labels of synced profiles a renewal and an activation carry (`profileTokens`, the server's
/// CONTRACT.md §6.2): a profile synced to several devices of a license takes one place in its count.
///
///     K     = HKDF-SHA256(IKM = VMK, salt = the vault's salt, info = "sync-profile-count", L = 32)
///     token = lowercase hex of the first 16 bytes of HMAC-SHA256(K, "profile/" + UUID)
///
/// The UUID is written as `UUID.uuidString` — upper case, with hyphens — as the Mac writes it
/// (trunk b34ffc89): in lower case the label is another one, and the server would count twice.
/// The server knows neither the key nor the salt, so a label tells it nothing.
public enum ProfileTokens {
    /// The key of a vault's labels.
    public static func key(vaultKey: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: vaultKey), salt: salt,
                               info: Data("sync-profile-count".utf8), outputByteCount: 32)
    }

    /// A profile's label: 32 lowercase hex characters.
    public static func token(profile: UUID, key: SymmetricKey) -> String {
        // The planted fault: the UUID in lower case — a label no Mac would make.
        let name = Faults.isActive(.profileTokenLowercase) ? profile.uuidString.lowercased() : profile.uuidString
        let code = HMAC<SHA256>.authenticationCode(for: Data(("profile/" + name).utf8), using: key)
        return code.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The labels of the profiles that are both in the vault and on this device, in a steady order.
    public static func tokens(profiles: [UUID], vaultKey: Data, salt: Data) -> [String] {
        let labelKey = key(vaultKey: vaultKey, salt: salt)
        return Array(Set(profiles.map { token(profile: $0, key: labelKey) })).sorted()
    }
}
