import Foundation

/// Where the app keeps the account's session token (`lms_…`) between runs: inside the vault, in a file
/// of its own (`account-session.bin`), AES-GCM under `HKDF(VMK, "account-session")` — as the license's
/// key is kept (`AccountKeyVault`). This Mac's alone: never synced.
///
/// Before the security audit of 12 November 2026 (APP-11) the session lay in `account.json` in the
/// clear, which every process of the Mac's user could read — the release runs without the App Sandbox
/// — and so did a profile's own process: whoever copied the file had the account (its Macs and their
/// unlinking, a team's seats, new devices activated). Now `account.json` keeps the session's dates only
/// (for `account.no_session`), the token is here, and it is read back when the vault opens. A profile's
/// own process, opened with a grant, cannot derive the key.
///
/// The device's token stays in `account.json`: the rights are decided with it before the vault is
/// unlocked (the server's `docs/CONTRACT.md` §4.2).
public enum AccountSessionVault {
    struct Stored: Codable {
        var format = 1
        var token: String
        var expiresAt: Date?
        var savedAt: Date
    }

    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<Stored> {
        EncryptedDocumentFile(url: url(in: vault.root), key: try vault.accountSessionKey, aad: "account-session:v1:\(vault.vaultID.uuidString)")
    }

    static func url(in root: URL) -> URL { root.appendingPathComponent("account-session.bin") }

    /// The session token kept in `vault` and until when it holds, or nil when none is. Throws when the
    /// file does not open (it is then left where it is: `save` moves it aside, never over it).
    public static func load(from vault: UnlockedVault) throws -> (token: ServerToken, expiresAt: Date?)? {
        guard let stored = try file(for: vault).load() else { return nil }
        guard !stored.token.isEmpty else { throw CoreError.corruptData("account-session.bin") }
        return (ServerToken(stored.token), stored.expiresAt)
    }

    public static func save(_ token: ServerToken, expiresAt: Date?, to vault: UnlockedVault, at date: Date = Date()) throws {
        try file(for: vault).save(Stored(token: token.unredacted(), expiresAt: expiresAt, savedAt: date))
    }

    /// When the session ends here: signed out, refused by the server, or replaced.
    public static func remove(from vault: UnlockedVault) throws {
        try file(for: vault).remove()
    }
}
