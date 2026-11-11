import BrowserCore
@testable import LumenCore
import XCTest

/// The vault on the iPhone (sync step 2; ios/SYNC_PLAN.md, decision 1): the master password entered
/// once, a key kept instead of it, opening the same vault as the Mac's.
final class DeviceVaultTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAKeptKeyOpensTheSameVaultAndNothingElse() throws {
        // A Mac's vault (PBKDF2 with few rounds: a test's vault, fast).
        let mac = try MasterVault.create(in: try folder(), password: "correct horse battery", iterations: 1_000)
        let profile = UUID()
        let macToken = try SyncProfileToken.token(for: profile, vault: mac)

        // The iPhone gets the header (from the sync server) and the password once.
        let phone = try folder()
        let key = try MasterVault.deviceUnlockKey(password: "correct horse battery", header: mac.header)
        XCTAssertEqual(key.count, 32)
        let opened = try MasterVault.unlock(header: mac.header, root: phone, deviceUnlockKey: key)
        XCTAssertEqual(opened.vaultID, mac.vaultID)
        // The same master key: the same profile's token as the Mac's.
        XCTAssertEqual(try SyncProfileToken.token(for: profile, vault: opened), macToken, "the kept key opens the Mac's vault")

        // A wrong password makes no key; a key that is not this vault's opens nothing.
        XCTAssertThrowsError(try MasterVault.deviceUnlockKey(password: "wrong", header: mac.header)) { error in
            XCTAssertEqual(error as? CoreError, .wrongPassword)
        }
        var other = key
        other[0] ^= 1
        XCTAssertThrowsError(try MasterVault.unlock(header: mac.header, root: phone, deviceUnlockKey: other))
        XCTAssertThrowsError(try MasterVault.unlock(header: mac.header, root: phone, deviceUnlockKey: Data(key.prefix(16))))

        // The password changed on the Mac: the old key does not open the new header; the new
        // password makes a new key that does — the same vault still.
        try mac.changePassword(current: "correct horse battery", new: "staple", iterations: 1_000)
        XCTAssertThrowsError(try MasterVault.unlock(header: mac.header, root: phone, deviceUnlockKey: key),
                             "a key kept from before a change of the password opens nothing")
        let renewed = try MasterVault.deviceUnlockKey(password: "staple", header: mac.header)
        let reopened = try MasterVault.unlock(header: mac.header, root: phone, deviceUnlockKey: renewed)
        XCTAssertEqual(try SyncProfileToken.token(for: profile, vault: reopened), macToken)
    }


    /// The setup screen's core: the account's vaults from the server's answer, and the master
    /// password turned into the key for exactly the vault asked for.
    func testTheSetupKeepsOnlyThisVaultsKey() throws {
        let folder = try folder()
        let mac = try MasterVault.create(in: folder, password: "vault-pass-1", iterations: 1_000)
        let header = try Data(contentsOf: MasterVault.headerURL(in: folder))

        let answer = Data("""
        {"vaults": [{"vaultID": "6f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f1", "changedAt": "2026-11-10T09:30:00Z"},
                    {"vaultID": "\(mac.vaultID.uuidString.lowercased())", "changedAt": "2026-11-11T09:30:00Z"}]}
        """.utf8)
        let vaults = try XCTUnwrap(SyncSetup.vaults(answer))
        XCTAssertEqual(vaults.map(\.vaultID), [mac.vaultID, UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1")!],
                       "the last changed first, the lower-case ids read")
        XCTAssertEqual(SyncSetup.vaults(Data(#"{"vaults": []}"#.utf8)), [])
        XCTAssertNil(SyncSetup.vaults(Data("<html>".utf8)))

        guard case let .key(key) = SyncSetup.unlockKey(password: "vault-pass-1", header: header, vaultID: mac.vaultID) else {
            return XCTFail("the right password makes the key")
        }
        XCTAssertTrue(SyncSetup.opens(key: key, header: header))
        XCTAssertEqual(SyncSetup.unlockKey(password: "wrong", header: header, vaultID: mac.vaultID), .wrongPassword)
        XCTAssertEqual(SyncSetup.unlockKey(password: "vault-pass-1", header: header, vaultID: UUID()), .notThisVault,
                       "another vault's header is not taken")
        XCTAssertEqual(SyncSetup.unlockKey(password: "vault-pass-1", header: Data("{}".utf8), vaultID: mac.vaultID), .notThisVault)
        var newer = try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
        newer["format"] = 99
        XCTAssertEqual(SyncSetup.unlockKey(password: "vault-pass-1", header: try JSONSerialization.data(withJSONObject: newer),
                                           vaultID: mac.vaultID), .newerApp)

        // The password changed on the Mac: the kept key no longer opens the new header.
        try mac.changePassword(current: "vault-pass-1", new: "vault-pass-2", iterations: 1_000)
        let changed = try Data(contentsOf: MasterVault.headerURL(in: folder))
        XCTAssertFalse(SyncSetup.opens(key: key, header: changed))
    }
}
