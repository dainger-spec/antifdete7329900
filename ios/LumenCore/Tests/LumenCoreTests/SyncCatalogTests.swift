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
        ]) { asked.append($0); return entryID }
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(asked, [proxy])

        let shop = try XCTUnwrap(catalog.sessions.first { $0.syncedProfileID == shopID })
        XCTAssertEqual(shop.name, "Магазин")
        XCTAssertEqual(shop.notes, "Кабинет")
        XCTAssertEqual(shop.tags, SessionCatalog.normalizedTags(["shop", "DE"]))
        XCTAssertEqual(shop.proxyID, entryID, "the Mac's proxy comes with the profile")
        XCTAssertTrue(shop.boundToProxy, "and binds it: it never opens directly")
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
        ]) { _ in entryID }
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(catalog.sessions.count, 4)
        XCTAssertEqual(catalog.sessions.first { $0.syncedProfileID == shopID }?.name, "Магазин 2")
        let reloaded = SessionCatalog(store: LumenStore(root: root))
        XCTAssertEqual(reloaded.sessions.first { $0.syncedProfileID == shopID }?.name, "Магазин 2", "kept across a relaunch")
    }
}
