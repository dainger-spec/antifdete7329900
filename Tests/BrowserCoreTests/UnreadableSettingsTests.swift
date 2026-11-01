import XCTest
@testable import BrowserCore

/// R1 (docs/DESTRUCTIVE_PATHS.md): a profile's settings that cannot be read are never written over,
/// by anything. Saved over with the editor's form — opened on defaults after the failed read — the
/// profile went without its proxy, from the Mac's own address. And sync pushed such a file over the
/// server's good copy, the one a person could take back with Sync Now. Now the settings are read
/// before every save and their error stops it; sync never pushes a copy that does not open, takes
/// the server's in its place, and keeps this device's beside it as `<file>.unreadable`.
final class UnreadableSettingsTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-unreadable-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private let proxied = ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "proxy.example", port: 1080),
                                               timeZoneIdentifier: "Asia/Tokyo")

    private func device(_ name: String) throws -> ProfileRepository {
        try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent(name), password: "pw", iterations: 1_000))
    }

    private func twoDevices() async throws -> (LocalDirectorySyncTransport, ProfileRepository, ProfileRepository, UUID) {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let a = try device("A")
        let id = try a.create(name: "Shared", configuration: proxied).id
        _ = try await sync(a, transport)
        let b = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: base.appendingPathComponent("B"), password: "pw"))
        _ = try await sync(b, transport)
        return (transport, a, b, id)
    }

    private func sync(_ repository: ProfileRepository, _ transport: SyncTransport) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: transport).sync()
    }

    /// The server's copy of a profile file, as it is there.
    private func serverCopy(_ transport: LocalDirectorySyncTransport, _ repository: ProfileRepository, _ id: UUID,
                            _ file: String) async throws -> Data? {
        let codec = try SyncCodec(vault: repository.vault)
        guard let blob = try await transport.fetch(objectID: codec.objectID(for: "profile/\(id.uuidString)/\(file)")) else { return nil }
        return try codec.decode(blob).payload.data
    }

    /// Flips one bit of the file, `fromEnd` bytes before its end (the AEAD tag: it no longer opens).
    private func damage(_ url: URL, fromEnd: Int = 1) throws -> Data {
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - fromEnd] ^= 0x01
        try bytes.write(to: url)
        return bytes
    }

    private func isUnreadableSettings(_ error: Error, of profile: String) -> Bool {
        if case .unreadableSettings(_, profile, _)? = error as? CoreError { return true }
        return false
    }

    // MARK: Saving

    /// The test that confirmed R1 in the audit (appendix B): the editor's Save after a failed read.
    func testUnreadableSettingsAreNotWrittenOverByASave() throws {
        let repository = try device("A")
        let id = try repository.create(name: "P", configuration: proxied).id
        let url = repository.configURL(for: id)
        let damaged = try damage(url)
        XCTAssertThrowsError(try repository.loadConfiguration(id)) { XCTAssertTrue(self.isUnreadableSettings($0, of: "P"), "\($0)") }
        XCTAssertThrowsError(try repository.saveConfiguration(ProfileConfiguration().savingEdit(over: nil), for: id)) {
            XCTAssertTrue(self.isUnreadableSettings($0, of: "P"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: url), damaged, "the unreadable config.bin was written over")
        XCTAssertEqual(try repository.summary(for: id).revision, 1, "a refused save is no new revision")
    }

    /// Settings that are not there are not made anew from defaults either: the profile would start
    /// without its proxy all the same.
    func testMissingSettingsAreNotMadeAnewByASave() throws {
        let repository = try device("A")
        let id = try repository.create(name: "P", configuration: proxied).id
        let url = repository.configURL(for: id)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try repository.saveConfiguration(ProfileConfiguration(), for: id)) {
            XCTAssertTrue(self.isUnreadableSettings($0, of: "P"), "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Every other writer of the settings reads them first: a proxy given from the list to a
    /// profile whose settings cannot be read is refused, and nothing is written.
    func testAProxyIsNotGivenToAProfileWhoseSettingsCannotBeRead() throws {
        let repository = try device("A")
        let id = try repository.create(name: "P", configuration: proxied).id
        let url = repository.configURL(for: id)
        let damaged = try damage(url)
        var list = ProxyList()
        let added = list.add(ProxyListImport.read("http://other.example:3128").proxies).added
        let entry = try XCTUnwrap(list.entries.first { $0.id == added.first })
        XCTAssertNotNil(entry.usableProxy)
        let outcome = repository.assign([ProxyAssignment(profileID: id, entry: entry)])
        XCTAssertNotNil(outcome.failed[id])
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    // MARK: Sync

    /// Damaged here, the settings are not pushed over the server's: the server's are taken in their
    /// place, and the damaged file kept beside them. The other device keeps its settings.
    func testSyncTakesTheServersSettingsAndKeepsTheUnreadableOnesAside() async throws {
        let (transport, a, b, id) = try await twoDevices()
        let good = try await serverCopy(transport, a, id, "config")
        let url = a.configURL(for: id)
        let damaged = try damage(url)

        let report = try await sync(a, transport)
        XCTAssertEqual(report.unreadable, [.init(profileID: id, file: "config.bin", keptAs: "config.bin.unreadable")])
        XCTAssertFalse(report.pushed.contains("profile/\(id.uuidString)/config"), "\(report.pushed)")
        let serverNow = try await serverCopy(transport, a, id, "config")
        XCTAssertEqual(serverNow, good, "the server's copy was written over")
        XCTAssertEqual(try Data(contentsOf: url), good)
        XCTAssertEqual(try a.loadConfiguration(id).proxy?.host, "proxy.example", "the profile has its proxy again")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unreadable")), damaged, "the unreadable file is kept")

        _ = try await sync(b, transport)
        XCTAssertEqual(try b.loadConfiguration(id).proxy?.host, "proxy.example")
        // The next sync has nothing to say: the file is the server's.
        let again = try await sync(a, transport)
        XCTAssertEqual(again.unreadable, [])
    }

    /// An unreadable copy kept aside before is never written over by the next one.
    func testASecondUnreadableCopyGoesBesideTheFirst() async throws {
        let (transport, a, _, id) = try await twoDevices()
        let url = a.configURL(for: id)
        let first = try damage(url)
        _ = try await sync(a, transport)
        let second = try damage(url, fromEnd: 2)
        XCTAssertNotEqual(first, second)
        let report = try await sync(a, transport)
        XCTAssertEqual(report.unreadable.map(\.keptAs), ["config.bin.unreadable-2"])
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unreadable")), first)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unreadable-2")), second)
        XCTAssertNoThrow(try a.loadConfiguration(id))
    }

    /// With no copy on the server (never synced), nothing is pushed and nothing written: the file is
    /// as it was, the report says so, and the profile stays unstartable until a backup's copy is back.
    func testUnreadableSettingsWithNoServerCopyAreLeftAsTheyAre() async throws {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let a = try device("A")
        let id = try a.create(name: "P", configuration: proxied).id
        let url = a.configURL(for: id)
        let damaged = try damage(url)

        let report = try await sync(a, transport)
        XCTAssertEqual(report.unreadable, [.init(profileID: id, file: "config.bin", keptAs: nil)])
        let onServer = try await serverCopy(transport, a, id, "config")
        XCTAssertNil(onServer, "an unreadable file was pushed")
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
        // The profile's other files sync as usual.
        XCTAssertTrue(report.pushed.contains("profile/\(id.uuidString)/bookmarks") || report.pushed.contains("index"), "\(report.pushed)")
    }

    /// The server's copy does not open either (pushed damaged by a version before this one): it is
    /// not taken, and this device's stays as it was.
    func testAnUnreadableServerCopyIsNotTaken() async throws {
        let (transport, a, b, id) = try await twoDevices()
        let name = "profile/\(id.uuidString)/config"
        let codec = try SyncCodec(vault: a.vault)
        let objectID = codec.objectID(for: name)
        let objects = try await transport.listObjects()
        let revision = try XCTUnwrap(objects.first { $0.objectID == objectID }).revision
        let garbage = Data(repeating: 7, count: 200)
        try await transport.store(objectID: objectID, revision: revision + 1,
                                  data: codec.encode(SyncPayload(logicalName: name, deleted: false, data: garbage), revision: revision + 1),
                                  expectedRevision: revision)
        let url = b.configURL(for: id)
        let damaged = try damage(url)

        let report = try await sync(b, transport)
        XCTAssertEqual(report.unreadable, [.init(profileID: id, file: "config.bin", keptAs: nil)])
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        let onServer = try await serverCopy(transport, a, id, "config")
        XCTAssertEqual(onServer, garbage)
    }

    /// Settings lost here (a backup put back without them) come back from the server even though
    /// it has not changed since this device last had them: the profile does not start without them.
    func testLostSettingsAreTakenBackFromTheServer() async throws {
        let (transport, a, _, id) = try await twoDevices()
        let url = a.configURL(for: id)
        let good = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)

        let report = try await sync(a, transport)
        XCTAssertTrue(report.pulled.contains("profile/\(id.uuidString)/config"), "\(report.pulled)")
        XCTAssertEqual(try Data(contentsOf: url), good)
        XCTAssertEqual(try a.loadConfiguration(id).proxy?.host, "proxy.example")
    }

    /// The same rule for the profile's other files: a damaged bookmarks file is not pushed — the sync
    /// used to stop on it — the server's is taken, the damaged one kept, and no bookmark is lost.
    func testAnUnreadableBookmarksFileIsNotPushedAndIsKeptAside() async throws {
        let (transport, a, b, id) = try await twoDevices()
        let store = try a.bookmarkStore(for: id, key: a.profileKey(for: id))
        for n in 1...3 { try store.add(title: "B\(n)", url: URL(string: "https://b\(n).test/")!) }
        _ = try await sync(a, transport)
        _ = try await sync(b, transport)
        let url = a.bookmarksURL(for: id)
        let damaged = try damage(url)

        let report = try await sync(a, transport)
        XCTAssertEqual(report.unreadable, [.init(profileID: id, file: "bookmarks.bin", keptAs: "bookmarks.bin.unreadable")])
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unreadable")), damaged)
        for (device, repository) in [("A", a), ("B", b)] {
            let titles = try repository.bookmarkStore(for: id, key: repository.profileKey(for: id)).all().map(\.title)
            XCTAssertEqual(Set(titles), ["B1", "B2", "B3"], "device \(device)")
        }
    }
}
