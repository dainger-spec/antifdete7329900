import XCTest
@testable import BrowserCore

/// A synced file this device lost, and then made anew with one change, is not "everything else was
/// deleted". Before, sync pushed such a copy as it was whenever the server's had not changed, and
/// every other device then pulled it over its own: their bookmarks (or history) went, all but the
/// one added since. Now a mergeable file that changed here is merged with the server's copy.
final class SyncLostFileTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-lostfile-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func twoDevices() async throws -> (LocalDirectorySyncTransport, ProfileRepository, ProfileRepository, UUID) {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let a = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let id = try a.create(name: "Shared", configuration: ProfileConfiguration()).id
        _ = try await SyncEngine(repository: a, transport: transport).sync()
        let b = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: base.appendingPathComponent("B"), password: "pw"))
        _ = try await SyncEngine(repository: b, transport: transport).sync()
        return (transport, a, b, id)
    }

    private func sync(_ repository: ProfileRepository, _ transport: SyncTransport) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: transport).sync()
    }

    private func bookmarks(_ repository: ProfileRepository, _ id: UUID) throws -> BookmarkStore {
        try repository.bookmarkStore(for: id, key: repository.profileKey(for: id))
    }

    func testBookmarksLostOnOneDeviceAreKeptOnTheOthers() async throws {
        let (transport, a, b, id) = try await twoDevices()
        for n in 1...3 { try bookmarks(a, id).add(title: "B\(n)", url: URL(string: "https://b\(n).test/")!) }
        _ = try await sync(a, transport)
        _ = try await sync(b, transport)
        XCTAssertEqual(try bookmarks(b, id).all().count, 3)

        try FileManager.default.removeItem(at: a.bookmarksURL(for: id))
        try bookmarks(a, id).add(title: "New", url: URL(string: "https://new.test/")!)
        let report = try await sync(a, transport)
        XCTAssertEqual(report.merged, ["profile/\(id.uuidString)/bookmarks"])
        _ = try await sync(b, transport)

        for (device, repository) in [("A", a), ("B", b)] {
            XCTAssertEqual(Set(try bookmarks(repository, id).all().map(\.title)), ["B1", "B2", "B3", "New"], "device \(device)")
        }
    }

    func testABookmarkDeletedOnOneDeviceIsStillDeletedOnTheOthers() async throws {
        let (transport, a, b, id) = try await twoDevices()
        let kept = try bookmarks(a, id).add(title: "Kept", url: URL(string: "https://kept.test/")!)
        let gone = try bookmarks(a, id).add(title: "Gone", url: URL(string: "https://gone.test/")!)
        _ = try await sync(a, transport)
        _ = try await sync(b, transport)

        try bookmarks(a, id).remove(id: gone.id)
        _ = try await sync(a, transport)
        _ = try await sync(b, transport)
        for (device, repository) in [("A", a), ("B", b)] {
            XCTAssertEqual(try bookmarks(repository, id).all().map(\.id), [kept.id], "device \(device)")
        }
    }

    func testHistoryLostOnOneDeviceIsKeptOnTheOthers() async throws {
        let (transport, a, b, id) = try await twoDevices()
        let key = try a.profileKey(for: id)
        let history = try a.historyStore(for: id, key: key)
        for n in 1...3 { history.recordVisit(url: URL(string: "https://h\(n).test/")!, title: "H\(n)") }
        try history.save()
        _ = try await sync(a, transport)
        _ = try await sync(b, transport)

        try FileManager.default.removeItem(at: a.historyURL(for: id))
        let anew = try a.historyStore(for: id, key: key)
        anew.recordVisit(url: URL(string: "https://new.test/")!, title: "New")
        try anew.save()
        _ = try await sync(a, transport)
        _ = try await sync(b, transport)

        for (device, repository) in [("A", a), ("B", b)] {
            let urls = Set(try repository.historyStore(for: id, key: repository.profileKey(for: id)).entries().map(\.url))
            XCTAssertEqual(urls, ["https://h1.test/", "https://h2.test/", "https://h3.test/", "https://new.test/"], "device \(device)")
        }
    }
}
