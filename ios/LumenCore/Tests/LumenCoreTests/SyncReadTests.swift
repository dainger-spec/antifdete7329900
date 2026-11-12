import BrowserCore
@testable import LumenCore
import XCTest

/// The sync's step 3: what a Mac put on the server comes to the iPhone — the Mac's own engine on
/// both ends, the iPhone's transport between them, and nothing written back.
final class SyncReadTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheMacsProfilesComeToTheIPhone() async throws {
        let server = SyncTransportTests.Server()
        server.generation = nil   // the stand-in's server makes one at the first write

        // The Mac: a vault, two profiles — one behind a SOCKS5 proxy with a login — synced up.
        let macRoot = try folder()
        let mac = try MasterVault.create(in: macRoot, password: "vault-pass-1", iterations: 1_000)
        let repository = try ProfileRepository(vault: mac)
        let shop = try repository.create(name: "Магазин", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .socks5, host: "de.gw.example", port: 1080, username: "anna", password: "s3cret"),
            tags: ["shop", "de"], notes: "Кабинет и счета"))
        let mail = try repository.create(name: "Почта", configuration: ProfileConfiguration())
        let macTransport = LumenSyncTransport(vaultID: mac.vaultID) { m, p, b, h in server.answer(m, p, b, h) }
        _ = try await SyncEngine(repository: repository, transport: macTransport).sync()
        XCTAssertNotNil(server.objects["vault-header"], "the Mac put its vault's header on the server")

        // The iPhone: the key from the master password once, then a read.
        let header = try VaultHeader.decodeChecked(XCTUnwrap(server.objects["vault-header"]?.data))
        let key = try MasterVault.deviceUnlockKey(password: "vault-pass-1", header: header)
        let phoneRoot = try folder().appendingPathComponent("vault")
        let phoneTransport = LumenSyncTransport(vaultID: mac.vaultID) { m, p, b, h in server.answer(m, p, b, h) }
        let first = try await SyncRead.pull(root: phoneRoot, key: key, transport: phoneTransport, keptGeneration: nil)

        let byName = Dictionary(uniqueKeysWithValues: first.profiles.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Магазин", "Почта"], "both of the Mac's profiles came")
        XCTAssertEqual(byName["Магазин"]?.id, shop.id)
        XCTAssertEqual(byName["Магазин"]?.notes, "Кабинет и счета")
        XCTAssertEqual(byName["Магазин"]?.tags, ["shop", "de"])
        XCTAssertEqual(byName["Магазин"]?.proxy, .init(kind: .socks5, host: "de.gw.example", port: 1080, username: "anna", password: "s3cret"),
                       "the proxy with its login and password")
        XCTAssertEqual(byName["Почта"]?.id, mail.id)
        XCTAssertNil(byName["Почта"]?.proxy)
        XCTAssertEqual(first.generation, server.generation, "the server's generation to keep")

        // Step 5: a rename on the Mac comes to the iPhone, and one made on the iPhone goes to the Mac —
        // each on its own profile, so neither is the other's conflict.
        try repository.rename(mail.id, to: "Почта 2")
        _ = try await SyncEngine(repository: repository, transport: macTransport).sync()
        let edit = SyncedEdit(profileID: shop.id, name: "Магазин (iPhone)", notes: "С iPhone", tags: ["shop", "de", "iphone"])
        let second = try await SyncRead.pull(root: phoneRoot, key: key, transport: phoneTransport, keptGeneration: first.generation,
                                             edits: [edit])
        XCTAssertTrue(second.profiles.contains { $0.name == "Почта 2" }, "a rename on the Mac reaches the iPhone")
        XCTAssertTrue(second.profiles.contains { $0.name == "Магазин (iPhone)" && $0.notes == "С iPhone" }, "the iPhone's rename reaches the Mac: first it is in the iPhone's copy")
        XCTAssertEqual(second.profileTokens.count, 2, "a token for each synced profile, for the renewal")
        XCTAssertTrue(second.profileTokens.allSatisfy { $0.count == 32 })

        _ = try await SyncEngine(repository: repository, transport: macTransport).sync()
        XCTAssertEqual(try repository.summary(for: shop.id).name, "Магазин (iPhone)", "the iPhone's rename reaches the Mac")
        let config = try repository.loadConfiguration(shop.id)
        XCTAssertEqual(config.notes, "С iPhone")
        XCTAssertEqual(config.tags, ["shop", "de", "iphone"])
        XCTAssertNotNil(config.proxy, "the proxy the Mac had stays: the iPhone sent only its edit")
        // The tokens are the Mac's own for the same vault (SyncProfileToken): one place per profile.
        XCTAssertEqual(Set(second.profileTokens), Set(try [shop.id, mail.id].map { try SyncProfileToken.token(for: $0, vault: mac) }))
    }

    func testAProxyTheIPhoneCannotUseComesBoundAndLocked() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: try folder(), password: "p", iterations: 1_000))
        let tlsID = try repository.create(name: "TLS", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "p.example", port: 443, tlsToProxy: true))).id
        let httpID = try repository.create(name: "HTTP", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "p.example", port: 3128))).id
        let tls = SyncRead.profile(try repository.summary(for: tlsID), try repository.loadConfiguration(tlsID))
        XCTAssertNil(tls.proxy)
        XCTAssertTrue(tls.proxyUnusable, "a proxy over TLS is not taken as plain HTTP")
        let http = SyncRead.profile(try repository.summary(for: httpID), try repository.loadConfiguration(httpID))
        XCTAssertEqual(http.proxy?.kind, .http)
        XCTAssertFalse(http.proxyUnusable)
    }
}
