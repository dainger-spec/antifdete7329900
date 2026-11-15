import XCTest
@testable import BrowserCore

/// What the Profiles window shows of each profile's settings is read once per stored version of
/// them (`ProfileSettingsCache`): kept while `config.bin` is the same file, read again after any
/// write of it — an edit here, a save in the profile's own process, a file put in its place as sync
/// does — never kept for settings that do not read, and not kept across another repository. And
/// following an edited proxy reads only the profiles it is given (`follow(_:previous:among:)`).
final class ProfileSettingsCacheTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-settings-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSettingsAreReadAgainOnlyOnceTheyChanged() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let a = try repository.create(name: "A", configuration: ProfileConfiguration(notes: "first"))
        let b = try repository.create(name: "B", configuration: ProfileConfiguration(notes: "b"))
        let cache = ProfileSettingsCache<String>()
        var reads = 0
        func notes(_ id: UUID, in repository: ProfileRepository) throws -> String {
            try cache.value(of: id, in: repository) { reads += 1; return $0.notes }
        }

        XCTAssertEqual(try notes(a.id, in: repository), "first")
        XCTAssertEqual(try notes(b.id, in: repository), "b")
        XCTAssertEqual(reads, 2)
        // Unchanged: nothing is read again, however often it is asked.
        for _ in 0..<5 {
            XCTAssertEqual(try notes(a.id, in: repository), "first")
            XCTAssertEqual(try notes(b.id, in: repository), "b")
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(repository.settingsStamp(a.id), repository.settingsStamp(a.id))

        // An edit here: read again, the new value kept.
        let firstSealed = try SecureFile.read(repository.configURL(for: a.id))
        var edited = try repository.loadConfiguration(a.id)
        edited.notes = "second"
        try repository.saveConfiguration(edited, for: a.id)
        XCTAssertEqual(try notes(a.id, in: repository), "second")
        XCTAssertEqual(try notes(a.id, in: repository), "second")
        XCTAssertEqual(reads, 3)

        // A file put in its place, as sync puts the one it brought — here the earlier version, bytes
        // and size as they were: another file all the same, so read again.
        try SecureFile.write(firstSealed, to: repository.configURL(for: a.id))
        XCTAssertEqual(try notes(a.id, in: repository), "first")
        XCTAssertEqual(reads, 4)

        // A save in the profile's own process (a vault opened for that profile alone).
        let own = try ProfileRepository(vault: MasterVault.open(in: root, grant: repository.grant(for: a.id)))
        var fromOwnProcess = try own.loadConfiguration(a.id)
        fromOwnProcess.notes = "saved in its process"
        try own.saveConfiguration(fromOwnProcess, for: a.id)
        XCTAssertEqual(try notes(a.id, in: repository), "saved in its process")
        XCTAssertEqual(reads, 5)
        // B was never written: still not read again.
        XCTAssertEqual(try notes(b.id, in: repository), "b")
        XCTAssertEqual(reads, 5)

        // Settings that do not read throw, as before, and are not kept; once they read again, they are.
        let bSealed = try SecureFile.read(repository.configURL(for: b.id))
        try SecureFile.write(Data("not the settings".utf8), to: repository.configURL(for: b.id))
        XCTAssertThrowsError(try notes(b.id, in: repository))
        XCTAssertThrowsError(try notes(b.id, in: repository))
        XCTAssertEqual(cache.count, 1)
        try SecureFile.write(bSealed, to: repository.configURL(for: b.id))
        XCTAssertEqual(try notes(b.id, in: repository), "b")
        XCTAssertEqual(reads, 6)
        XCTAssertEqual(cache.count, 2)

        // Settings missing altogether: no stamp, nothing kept.
        try FileManager.default.removeItem(at: repository.configURL(for: b.id))
        XCTAssertNil(repository.settingsStamp(b.id))
        XCTAssertThrowsError(try notes(b.id, in: repository))
        XCTAssertEqual(cache.count, 1)

        // A profile no longer listed goes; another repository (the vault locked and opened again)
        // starts with nothing; and nothing is kept once emptied (Lock).
        cache.keep(only: [b.id])
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(try notes(a.id, in: repository), "saved in its process")
        XCTAssertEqual(reads, 7)
        let reopened = try ProfileRepository(vault: MasterVault.unlock(in: root, password: "pw"))
        XCTAssertEqual(try notes(a.id, in: reopened), "saved in its process")
        XCTAssertEqual(reads, 8)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testFollowingAnEditedProxyReadsOnlyTheProfilesItIsGiven() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let used = ProxySettings(kind: .socks5, host: "gw.example", port: 9000, username: "u", password: "old")
        let a = try repository.create(name: "A", configuration: ProfileConfiguration(proxy: used))
        let b = try repository.create(name: "B", configuration: ProfileConfiguration(proxy: used))
        let c = try repository.create(name: "C", configuration: ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "other.example", port: 1)))
        var list = ProxyList()
        list.takeIn(profileProxies: repository.profileProxies())
        let entry = try XCTUnwrap(list.entry(for: used))
        var changed = entry.proxy
        changed.password = "new"
        let previous = try list.update(entry.id, label: "", proxy: changed)
        // C's settings do not read: among the profiles given, it would fail; left out, it is not read.
        try SecureFile.write(Data("not the settings".utf8), to: repository.configURL(for: c.id))

        let outcome = repository.follow(try XCTUnwrap(list.entry(entry.id)), previous: previous, among: [a.id])
        XCTAssertEqual(outcome.changed, [a.id])
        XCTAssertEqual(outcome.failed, [:])
        XCTAssertEqual(try repository.loadConfiguration(a.id).proxy?.password, "new")
        XCTAssertEqual(try repository.loadConfiguration(b.id).proxy?.password, "old", "a profile not given is not touched")
        // A profile given that does not use the proxy is read and left alone; one that does not read says so.
        let again = repository.follow(try XCTUnwrap(list.entry(entry.id)), previous: previous, among: [b.id, c.id, UUID()])
        XCTAssertEqual(again.changed, [b.id])
        XCTAssertEqual(Set(again.failed.keys), [c.id], "an id no longer listed is passed over")
        // Without `among`, every listed profile, as before.
        XCTAssertEqual(Set(repository.follow(try XCTUnwrap(list.entry(entry.id)), previous: changed).unchanged), [a.id, b.id])
    }
}
