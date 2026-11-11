import BrowserCore
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

}
