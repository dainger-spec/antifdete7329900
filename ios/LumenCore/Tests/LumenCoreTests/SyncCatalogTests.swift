@testable import LumenCore
import XCTest

/// The Mac's profiles become sessions on the iPhone (the sync's step 3).
final class SyncCatalogTests: XCTestCase {
    func testTheMacsProfilesBecomeSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-synccat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = SessionCatalog(store: LumenStore(root: root))
        let own = catalog.create(name: "Своя")
        let shopID = UUID(), mailID = UUID(), tlsID = UUID()
        let proxy = SyncedProfile.Proxy(kind: .socks5, host: "de.gw.example", port: 1080, username: "anna", password: "s3cret")
        let entryID = UUID()
        var asked: [SyncedProfile.Proxy] = []
        let made = catalog.applySynced([
            SyncedProfile(id: shopID, name: "Магазин", notes: "Кабинет", tags: ["shop", "DE"], proxy: proxy, proxyUnusable: false),
            SyncedProfile(id: mailID, name: "Почта", notes: "", tags: [], proxy: nil, proxyUnusable: false),
            SyncedProfile(id: tlsID, name: "TLS", notes: "", tags: [], proxy: nil, proxyUnusable: true),
        ]) { proxy, _ in asked.append(proxy); return entryID }
        XCTAssertEqual(made.count, 3)

        let shop = try XCTUnwrap(catalog.sessions.first { $0.syncedProfileID == shopID })
        XCTAssertEqual(shop.name, "Магазин")
        XCTAssertEqual(shop.notes, "Кабинет")
        XCTAssertEqual(shop.tags, SessionCatalog.normalizedTags(["shop", "DE"]))
        XCTAssertEqual(shop.proxyID, entryID, "the Mac's proxy comes with the profile")
        XCTAssertTrue(shop.boundToProxy, "and binds it: it never opens directly")
        XCTAssertEqual(asked, [proxy], "the entry is asked for the one proxy")
        let mail = try XCTUnwrap(catalog.sessions.first { $0.syncedProfileID == mailID })
        XCTAssertNil(mail.proxyID)
        XCTAssertFalse(mail.boundToProxy)
        let tls = try XCTUnwrap(catalog.sessions.first { $0.syncedProfileID == tlsID })
        XCTAssertNil(tls.proxyID)
        XCTAssertTrue(tls.boundToProxy, "a proxy the iPhone cannot use: bound, so locked until one is chosen")
        XCTAssertEqual(catalog.sessions.first { $0.id == own.id }?.syncedProfileID, nil, "the iPhone's own session is untouched")

        // Read again: the same sessions, the Mac's rename taken; nothing made twice; saved.
        let again = catalog.applySynced([
            SyncedProfile(id: shopID, name: "Магазин 2", notes: "Кабинет", tags: ["shop"], proxy: proxy, proxyUnusable: false),
        ]) { _, _ in entryID }
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(catalog.sessions.count, 4)
        XCTAssertEqual(catalog.sessions.first { $0.syncedProfileID == shopID }?.name, "Магазин 2")
        let reloaded = SessionCatalog(store: LumenStore(root: root))
        XCTAssertEqual(reloaded.sessions.first { $0.syncedProfileID == shopID }?.name, "Магазин 2", "kept across a relaunch")
    }

    func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-synccat-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Audit 3, #16: two of the Mac's profiles on one gateway, with the same login and different
    /// passwords (the country or the sticky session in the password), get an entry each — neither
    /// password written over the other's — and the entry of one profile follows its new password.
    func testProfilesWhosePasswordsDifferNeverShareAProxyEntry() throws {
        let catalog = SessionCatalog(store: LumenStore(root: folder()))
        var entries: [ProxyEntry] = []
        var passwords: [UUID: String] = [:]
        func take(_ proxy: SyncedProfile.Proxy, _ session: Session) -> UUID {
            let elsewhere = Set(catalog.sessions.filter { $0.id != session.id }.compactMap(\.proxyID))
            switch SyncedProxyEntry.choose(for: proxy, boundTo: session.proxyID, entries: entries, usedElsewhere: elsewhere,
                                           password: { passwords[$0] }) {
            case let .use(id): return id
            case let .newPassword(id): passwords[id] = proxy.password; return id
            case .add:
                let entry = ProxyEntry(kind: proxy.kind, host: proxy.host, port: proxy.port, username: proxy.username)
                entries.append(entry)
                passwords[entry.id] = proxy.password
                return entry.id
            }
        }
        func gateway(_ password: String) -> SyncedProfile.Proxy {
            .init(kind: .http, host: "gw.example", port: 8000, username: "anna", password: password)
        }
        let usID = UUID(), deID = UUID(), againID = UUID()
        catalog.applySynced([
            SyncedProfile(id: usID, name: "US", notes: "", tags: [], proxy: gateway("pass_country-us"), proxyUnusable: false),
            SyncedProfile(id: deID, name: "DE", notes: "", tags: [], proxy: gateway("pass_country-de"), proxyUnusable: false),
            SyncedProfile(id: againID, name: "US 2", notes: "", tags: [], proxy: gateway("pass_country-us"), proxyUnusable: false),
        ], proxyID: take)
        func entry(_ profileID: UUID) throws -> UUID { try XCTUnwrap(catalog.sessions.first { $0.syncedProfileID == profileID }?.proxyID) }
        let usEntry = try entry(usID), deEntry = try entry(deID)
        XCTAssertNotEqual(usEntry, deEntry, "another password: another entry")
        XCTAssertEqual(passwords[usEntry], "pass_country-us", "never written over by the other profile's")
        XCTAssertEqual(passwords[deEntry], "pass_country-de")
        XCTAssertEqual(try entry(againID), usEntry, "the same login and password share one")
        XCTAssertEqual(entries.count, 2)

        // The Mac changes DE's password: its own entry follows. US's shared entry is never changed for
        // one of its two profiles: that one gets an entry of its own.
        catalog.applySynced([
            SyncedProfile(id: usID, name: "US", notes: "", tags: [], proxy: gateway("pass_country-us"), proxyUnusable: false),
            SyncedProfile(id: deID, name: "DE", notes: "", tags: [], proxy: gateway("pass_country-de_session-2"), proxyUnusable: false),
            SyncedProfile(id: againID, name: "US 2", notes: "", tags: [], proxy: gateway("pass_country-us_session-9"), proxyUnusable: false),
        ], proxyID: take)
        XCTAssertEqual(try entry(deID), deEntry)
        XCTAssertEqual(passwords[deEntry], "pass_country-de_session-2")
        XCTAssertEqual(try entry(usID), usEntry)
        XCTAssertEqual(passwords[usEntry], "pass_country-us", "the shared entry keeps its password")
        let againEntry = try entry(againID)
        XCTAssertNotEqual(againEntry, usEntry)
        XCTAssertEqual(passwords[againEntry], "pass_country-us_session-9")
    }
}
