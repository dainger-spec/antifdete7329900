#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// The tokens of synced profiles a renewal carries (`profileTokens`; the account server's
/// docs/CONTRACT.md §6.2, "Метки синхронизируемых профилей", and §8.4): the rule itself against
/// values computed outside this package, the same token on two devices of one vault, and which
/// profiles of a device are told.
final class SyncProfileTokenTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-tokens-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Computed with Python's hmac and hashlib, not with this code: VMK = bytes 00…1f, the vault's
    /// salt = the 16 bytes of the vault's id 6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1,
    /// K = HKDF-SHA256(VMK, salt, "sync-profile-count", 32),
    /// token = hex(HMAC-SHA256(K, "profile/" + UUID)[0..<16]).
    func testTheTokenIsTheContractsRule() throws {
        let vmk = SymmetricKey(data: Data(0..<32))
        let vaultID = try XCTUnwrap(UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F1"))
        let salt = withUnsafeBytes(of: vaultID.uuid) { Data($0) }
        let key = vmk.derive(info: "sync-profile-count", salt: salt)
        XCTAssertEqual(key.rawBytes.map { String(format: "%02x", $0) }.joined(),
                       "1620daa771076c8a1ca3abae1927b4f0fa1bd2485c736467df5be2ace12cdbd3")
        let profile = try XCTUnwrap(UUID(uuidString: "6B0E3C1F-9A2D-4E7B-8C15-0D4F6A7B8C9D"))
        // The UUID as the logical names of the profile's objects write it: upper-case, with hyphens.
        XCTAssertEqual(SyncProfileToken.token(for: profile, key: key), "750d110fc23ef5dbfb2a9b045c3711ed")
        // Written in lower case it would be another token — what another device must not do.
        XCTAssertNotEqual(SyncProfileToken.token(for: profile, key: key), "83704598564a09440dd9cfcc2ca6dd5a")
        let digits = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        XCTAssertEqual(SyncProfileToken.token(for: digits, key: key), "762689ee39937d3d5157669683d983b1")
        // 32 characters of lower-case hexadecimal, as the server takes them.
        let token = SyncProfileToken.token(for: UUID(), key: key)
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testTwoDevicesOfAVaultGiveOneTokenAndOnlySyncedProfilesAreTold() async throws {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let a = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let shared = try a.create(name: "Shared", configuration: ProfileConfiguration()).id
        // Before the first sync nothing is in the sync vault: no token.
        XCTAssertEqual(SyncEngine.syncedProfileIDs(in: a), [])
        XCTAssertEqual(SyncProfileToken.tokens(in: a), [])
        _ = try await SyncEngine(repository: a, transport: transport).sync()
        let b = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: base.appendingPathComponent("B"), password: "pw"))
        _ = try await SyncEngine(repository: b, transport: transport).sync()

        XCTAssertEqual(SyncEngine.syncedProfileIDs(in: a), [shared])
        XCTAssertEqual(SyncEngine.syncedProfileIDs(in: b), [shared])
        let tokenA = try SyncProfileToken.token(for: shared, vault: a.vault)
        XCTAssertEqual(tokenA, try SyncProfileToken.token(for: shared, vault: b.vault), "one profile, one token on every device of the vault")
        XCTAssertEqual(SyncProfileToken.tokens(in: a), [tokenA])
        XCTAssertEqual(SyncProfileToken.tokens(in: b), [tokenA])

        // A profile made since the last sync is on this device only: counted, not told.
        let local = try a.create(name: "Not synced yet", configuration: ProfileConfiguration()).id
        XCTAssertEqual(SyncEngine.syncedProfileIDs(in: a), [shared])
        _ = try await SyncEngine(repository: a, transport: transport).sync()
        XCTAssertEqual(Set(SyncEngine.syncedProfileIDs(in: a)), [shared, local])
        XCTAssertEqual(SyncProfileToken.tokens(in: a).count, 2)
        XCTAssertNotEqual(try SyncProfileToken.token(for: local, vault: a.vault), tokenA)

        // Another vault's token of the same identifier is another one: tokens of two vaults do not match.
        let other = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("C"), password: "pw", iterations: 1_000))
        XCTAssertNotEqual(try SyncProfileToken.token(for: shared, vault: other.vault), tokenA)
    }
}
