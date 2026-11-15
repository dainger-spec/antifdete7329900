@testable import BrowserCore
@testable import LumenCore
import XCTest

/// The sync's step 4: the Mac's cookies come to the iPhone's sessions by the Mac's own rules.
final class SyncCookieTests: XCTestCase {
    /// The sessions' cookie stores, in memory.
    final class Stores: SyncCookieStores, @unchecked Sendable {
        let lock = NSLock()
        var stores: [UUID: [SyncedCookie]] = [:]
        /// Which store each session has, as the app's WebKit stores tell it; none: the stores do not tell.
        var ids: [UUID: UUID] = [:]

        func persistentCookies(profileID: UUID) async -> [SyncedCookie]? { lock.withLock { stores[profileID] } }

        func storeID(profileID: UUID) async -> UUID? { lock.withLock { ids[profileID] } }

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

    /// The Mac's profile with its sign-in on the server, and the iPhone's key and folder for its vault.
    func signedInOnTheMac() async throws -> (repository: ProfileRepository, shop: UUID, mac: LumenSyncTransport,
                                              phone: LumenSyncTransport, key: Data, root: URL) {
        let server = SyncTransportTests.Server()
        server.generation = nil
        let vault = try MasterVault.create(in: try folder(), password: "vault-pass-1", iterations: 1_000)
        let repository = try ProfileRepository(vault: vault)
        let shop = try repository.create(name: "Магазин", configuration: ProfileConfiguration())
        let expires = Date().addingTimeInterval(30 * 86400)
        let signedInOnMac = Date().addingTimeInterval(-3600)
        let signIn = ["sid", "csrf"].map { name in
            CookieJarDocument.Entry(cookie: ImportedCookie(name: name, value: "mac-\(name)", domain: "shop.example", hostOnly: true,
                                                           path: "/", expires: expires, secure: true), updatedAt: signedInOnMac)
        }
        try repository.saveCookieJar(CookieJarDocument(cookies: signIn), for: shop.id)
        let mac = LumenSyncTransport(vaultID: vault.vaultID) { m, p, b, h in server.answer(m, p, b, h) }
        _ = try await SyncEngine(repository: repository, transport: mac).sync()
        let header = try VaultHeader.decodeChecked(XCTUnwrap(server.objects["vault-header"]?.data))
        let key = try MasterVault.deviceUnlockKey(password: "vault-pass-1", header: header)
        let phone = LumenSyncTransport(vaultID: vault.vaultID) { m, p, b, h in server.answer(m, p, b, h) }
        return (repository, shop.id, mac, phone, key, try folder().appendingPathComponent("vault"))
    }

    /// Audit 3, #2: a session deleted on the iPhone and made again has a new, empty store. Measured
    /// against the old store's baseline, every cookie of the profile would be recorded as deleted —
    /// and, synced, deleted on the Mac. A baseline counts only for the store it was taken from.
    func testASessionMadeAgainDeletesNoCookieOfTheMacs() async throws {
        let (repository, shop, mac, phone, key, root) = try await signedInOnTheMac()
        let stores = Stores()
        stores.stores[shop] = []
        stores.ids[shop] = UUID()
        let first = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: nil, cookies: stores)
        XCTAssertEqual(stores.value("sid", shop), "mac-sid", "the Mac's sign-in came to the session")

        // Deleted and made again before the next run: another store, empty.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        stores.stores[shop] = []
        stores.ids[shop] = UUID()
        let second = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: first.generation, cookies: stores)
        XCTAssertEqual(stores.value("sid", shop), "mac-sid", "the new store gets the Mac's sign-in, as a first time")
        XCTAssertEqual(stores.value("csrf", shop), "mac-csrf")
        let copy = try ProfileRepository(vault: MasterVault.open(in: root, deviceUnlockKey: key))
        XCTAssertEqual(try copy.cookieJar(for: shop).deleted, [], "the old store's cookies are not recorded as deleted")

        // The runs after it send no deletion: the Mac keeps its sign-in.
        _ = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: second.generation, cookies: stores)
        _ = try await SyncEngine(repository: repository, transport: mac).sync()
        let jar = try repository.cookieJar(for: shop)
        XCTAssertEqual(Set(jar.cookies.map(\.cookie.name)), ["sid", "csrf"], "the Mac's sign-in stays")
        XCTAssertEqual(jar.deleted, [])
    }

    /// Audit 4: a profile the run made a session of gets the Mac's cookies in the same run, not at the
    /// next one — the app makes the run's sessions after `pull`, then runs the cookie step with them.
    func testASessionTheRunMadeGetsTheMacsCookiesAtOnce() async throws {
        let (_, shop, _, phone, key, root) = try await signedInOnTheMac()
        let outcome = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: nil)
        XCTAssertEqual(outcome.profiles.map(\.id), [shop], "the profile comes, to be made a session")
        XCTAssertEqual(outcome.cookiesSet, 0, "the run itself touches no store")

        // The app makes the session (a new, empty store), then the cookie step.
        let stores = Stores()
        stores.stores[shop] = []
        stores.ids[shop] = UUID()
        let applied = try await SyncRead.applyCookies(root: root, key: key, stores: stores)
        XCTAssertEqual(applied.set, 2)
        XCTAssertEqual(applied.deleted, 0)
        XCTAssertEqual(stores.value("sid", shop), "mac-sid", "the Mac's sign-in is in the session before it first opens")
        XCTAssertEqual(stores.value("csrf", shop), "mac-csrf")
        XCTAssertEqual(BaselineStores.load(root: root)[shop], stores.ids[shop], "its baseline names its store")
    }

    /// A profile with no session here keeps no baseline: a session made for it later starts from none.
    func testAProfileWithNoSessionHereKeepsNoBaseline() async throws {
        let (repository, shop, mac, phone, key, root) = try await signedInOnTheMac()
        let stores = Stores()
        stores.stores[shop] = []
        stores.ids[shop] = UUID()
        let first = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: nil, cookies: stores)
        XCTAssertEqual(BaselineStores.load(root: root)[shop], stores.ids[shop], "the baseline names its store")

        // The session deleted: the next run drops the baseline it had.
        stores.stores[shop] = nil
        stores.ids[shop] = nil
        let second = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: first.generation, cookies: stores)
        let copy = try ProfileRepository(vault: MasterVault.open(in: root, deviceUnlockKey: key))
        XCTAssertEqual(try copy.cookieBaseline(for: shop), CookieBaseline(), "no baseline without a session")
        XCTAssertNil(BaselineStores.load(root: root)[shop])

        // Made again: its new store gets the Mac's cookies, and nothing is deleted anywhere.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        stores.stores[shop] = []
        stores.ids[shop] = UUID()
        let third = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: second.generation, cookies: stores)
        XCTAssertEqual(stores.value("sid", shop), "mac-sid")
        XCTAssertEqual(third.cookiesDeleted, 0)
        _ = try await SyncRead.pull(root: root, key: key, transport: phone, keptGeneration: third.generation, cookies: stores)
        _ = try await SyncEngine(repository: repository, transport: mac).sync()
        XCTAssertEqual(try repository.cookieJar(for: shop).deleted, [], "no deletion reached the Mac")
    }
}
