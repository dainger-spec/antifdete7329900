#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// How each small per-profile encrypted file is bound to its profile: the key (the profile key
/// itself, or an HKDF subkey salted with the profile ID) and the AAD (purpose + profile ID).
///
/// This is the single definition used by the stores (configuration, `PasswordVault`,
/// `HistoryStore`, `BookmarkStore`) and by the code that moves files to another profile ID and
/// key — profile duplication and restoring a backup as a copy. Because every ciphertext names
/// its owner, a copied file does not decrypt for its new profile until it is re-encrypted
/// with `reseal`.
///
/// `webdata.pbsa` is not listed: it is a chunk stream with its own per-archive key, and its
/// plaintext root labels name the profile (see `EncryptedDirectoryArchive.reseal`).
enum ProfileFileBinding: String, CaseIterable {
    /// `config.bin`: the profile key directly, AAD `"profile-config:v1:<uuid>"`.
    case config
    /// `passwords.bin`: HKDF(profileKey, "passwords"), AAD `"passwords:v1:<uuid>"`.
    case passwords
    /// `history.bin`: HKDF(profileKey, "history"), AAD `"history:v1:<uuid>"`.
    case history
    /// `bookmarks.bin`: HKDF(profileKey, "bookmarks"), AAD `"bookmarks:v1:<uuid>"`.
    case bookmarks
    /// `session.bin` (tabs to reopen): HKDF(profileKey, "session"), AAD `"session:v1:<uuid>"`.
    /// The session store must use this binding (`document(url:profileID:profileKey:)`) so that a
    /// restored copy can carry its session over; a file that does not open under it is dropped
    /// by `ProfileBackup` rather than failing the restore (it only lists tabs to reopen).
    case session

    var fileName: String { rawValue + ".bin" }

    func key(profileID: UUID, profileKey: SymmetricKey) -> SymmetricKey {
        switch self {
        case .config: return profileKey
        case .passwords, .history, .bookmarks, .session: return profileKey.derive(info: rawValue, salt: profileID.rawBytes)
        }
    }

    func aad(_ profileID: UUID) -> String {
        switch self {
        case .config: return "profile-config:v1:\(profileID.uuidString)"
        case .passwords, .history, .bookmarks, .session: return "\(rawValue):v1:\(profileID.uuidString)"
        }
    }

    func seal(_ plaintext: Data, profileID: UUID, profileKey: SymmetricKey) throws -> Data {
        try AEAD.seal(plaintext, key: key(profileID: profileID, profileKey: profileKey), aad: aad(profileID))
    }

    func open(_ sealed: Data, profileID: UUID, profileKey: SymmetricKey) throws -> Data {
        try AEAD.open(sealed, key: key(profileID: profileID, profileKey: profileKey), aad: aad(profileID))
    }

    /// Decrypts a file of profile `from` and encrypts the same plaintext for profile `to`.
    func reseal(_ sealed: Data, from: (id: UUID, key: SymmetricKey), to: (id: UUID, key: SymmetricKey)) throws -> Data {
        try seal(open(sealed, profileID: from.id, profileKey: from.key), profileID: to.id, profileKey: to.key)
    }

    /// A JSON document stored under this binding (`url == nil` → memory-only).
    func document<Document: Codable>(url: URL?, profileID: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<Document> {
        EncryptedDocumentFile(url: url, key: key(profileID: profileID, profileKey: profileKey), aad: aad(profileID))
    }
}
