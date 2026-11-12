@testable import BrowserCore
@testable import LumenCore
import XCTest

/// The sync's step 4: the Mac's cookies come to the iPhone's sessions by the Mac's own rules.
final class SyncCookieTests: XCTestCase {
    /// The sessions' cookie stores, in memory.
    final class Stores: SyncCookieStores, @unchecked Sendable {
        let lock = NSLock()
        var stores: [UUID: [SyncedCookie]] = [:]

        func persistentCookies(profileID: UUID) async -> [SyncedCookie]? { lock.withLock { stores[profileID] } }

        func apply(set: [SyncedCookie], delete: [SyncedCookie], profileID: UUID) async {
            lock.withLock {
                var cookies = stores[profileID] ?? []
                let gone = Set((set + delete).map { "\($0.name)|\($0.domain)|\($0.path)" })
                cookies.removeAll { gone.contains("\($0.name)|\($0.domain)|\($0.path)") }
                stores[profileID] = cookies + set
            }
        }

        func value(_ name: String, _ profileID: UUID) -> String? { lock.withLock { stores[profileID]?.first { $0.name == name }?.value } }
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-cookies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheMacsCookiesComeAndANewerOneHereStays() async throws {
        let server = SyncTransportTests.Server()
        server.generation = nil
        let mac = try MasterVault.create(in: try folder(), password: "vault-pass-1", iterations: 1_000)
        let repository = try ProfileRepository(vault: mac)
        let shop = try repository.create(name: "Магазин", configuration: ProfileConfiguration())
        let expires = Date().addingTimeInterval(30 * 86400)
        func cookie(_ name: String, _ value: String) -> ImportedCookie {
            ImportedCookie(name: name, value: value, domain: "shop.example", hostOnly: true, path: "/", expires: expires, secure: true)
        }
        let signedInOnMac = Date().addingTimeInterval(-3600)
        try repository.saveCookieJar(CookieJarDocument(cookies: [
            .init(cookie: cookie("sid", "mac-session"), updatedAt: signedInOnMac),
            .init(cookie: cookie("lang", "de"), updatedAt: signedInOnMac),
        ]), for: shop.id)
        let macTransport = LumenSyncTransport(vaultID: mac.vaultID) { m, p, b, h in server.answer(m, p, b, h) }
        _ = try await SyncEngine(repository: repository, transport: macTransport).sync()

        let header = try VaultHeader.decodeChecked(XCTUnwrap(server.objects["vault-header"]?.data))
        let key = try MasterVault.deviceUnlockKey(password: "vault-pass-1", header: header)
        let root = try folder().appendingPathComponent("vault")
        let phone = LumenSyncTransport(vaultID: mac.vaultID) { m, p, b, h in server.answer(m, p, b, h) }

        // The first run makes the session; the iPhone's store for it is empty, and an own cookie of the iPhone's.
        let stores = Stores()
        stores.stores[shop.id] = [SyncedCookie(name: "own", value: "iphone", domain: "other.example", hostOnly: true, expires: expires)]
        let first = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: nil, cookies: stores)
        XCTAssertEqual(stores.value("sid", shop.id), "mac-session", "the Mac's sign-in came to the iPhone's session")
        XCTAssertEqual(stores.value("lang", shop.id), "de")
        XCTAssertEqual(stores.value("own", shop.id), "iphone", "a cookie the document does not know is left alone")
        XCTAssertEqual(first.cookiesSet, 2)

        // On the iPhone the person signs in again: a newer session cookie here. The next run keeps it.
        try await Task.sleep(nanoseconds: 1_100_000_000)   // whole seconds: the next change is a later one
        await stores.apply(set: [SyncedCookie(name: "sid", value: "iphone-session", domain: "shop.example", hostOnly: true,
                                              expires: expires, secure: true)], delete: [], profileID: shop.id)
        let second = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: first.generation, cookies: stores)
        XCTAssertEqual(stores.value("sid", shop.id), "iphone-session", "a newer change made here stays")
        XCTAssertEqual(second.cookiesSet, 0)

        // A profile with no session here is passed over.
        let none = await stores.persistentCookies(profileID: UUID())
        XCTAssertNil(none)
    }
}
