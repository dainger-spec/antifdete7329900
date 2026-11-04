import Foundation

/// Where the app keeps the license's key of an account bought without registration: inside the
/// vault, in a file of its own (`account-key.bin`), AES-GCM under `HKDF(VMK, "account-key")` — as
/// carefully as the master password keeps everything else (the owner, 1 November): readable only
/// after the vault is unlocked, by the app's own process; never in `account.json`, the settings, a
/// log or a report. This Mac's alone: never synced.
///
/// Why keep it at all: a key opens no session. The account screen asks the server with it for the
/// license's Macs and to unlink one (the server's `POST /v1/anonymous/…`), so without it the person
/// would type the key each time. What signs this Mac in is not the key but the device's token
/// (`account.json`), which the rights need before the vault is unlocked.
public enum AccountKeyVault {
    struct Stored: Codable {
        var format = 1
        var key: String
        var savedAt: Date
    }

    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<Stored> {
        EncryptedDocumentFile(url: url(in: vault.root), key: try vault.accountKeyKey, aad: "account-key:v1:\(vault.vaultID.uuidString)")
    }

    static func url(in root: URL) -> URL { root.appendingPathComponent("account-key.bin") }

    /// The key kept in `vault`, or nil when none is. Throws when the file does not open (it is then
    /// left where it is: `save` moves it aside, never over it).
    public static func load(from vault: UnlockedVault) throws -> AccountKey? {
        guard let stored = try file(for: vault).load() else { return nil }
        guard let key = AccountKey(stored: stored.key) else { throw CoreError.corruptData("account-key.bin") }
        return key
    }

    public static func save(_ key: AccountKey, to vault: UnlockedVault, at date: Date = Date()) throws {
        try file(for: vault).save(Stored(key: key.unredacted(), savedAt: date))
    }

    /// When this Mac signs out of the account the key opened.
    public static func remove(from vault: UnlockedVault) throws {
        try file(for: vault).remove()
    }
}
