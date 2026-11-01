import XCTest
@testable import BrowserCore

/// R3 (docs/DESTRUCTIVE_PATHS.md), the owner's decision of 1 November: a deleted profile's folder
/// is not removed silently. A deletion made on this Mac marks the folder before it touches the
/// index, and only such a folder is swept (a deletion that stopped part-way). Any other folder of a
/// deleted profile — the deletion came from another device, or the folder was put back from a
/// backup — is kept, and the person decides: bring the profile back (as a new profile: the deletion
/// of the old id is permanent and synced), or remove it for good.
final class KeptDeletedProfileTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-kept-deleted-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func vault(_ name: String) throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: root.appendingPathComponent(name), password: "pw", iterations: 1_000))
    }

    private func unlock(_ name: String) throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: root.appendingPathComponent(name), password: "pw"))
    }

    private let proxied = ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "proxy.example", port: 1080),
                                               timeZoneIdentifier: "Asia/Tokyo")

    /// The test that confirmed R3 in the audit (appendix B): a deleted profile's folder put back
    /// from a backup was deleted again at the next unlock.
    func testAFolderPutBackFromABackupIsKeptAndShown() throws {
        let repository = try vault("v")
        let id = try repository.create(name: "P", configuration: proxied).id
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: repository.directory(for: id), to: copy)
        try repository.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: id).path), "deleted here: gone")
        try FileManager.default.copyItem(at: copy, to: repository.directory(for: id)) // put back

        let unlocked = try unlock("v")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: id).path),
                      "R3: the folder put back was deleted again at the next unlock")
        XCTAssertEqual(unlocked.keptDeletedProfiles(), [.init(id: id, name: "P", createdAt: try XCTUnwrap(unlocked.readKeyCopy(id)?.createdAt))])
        XCTAssertEqual(unlocked.list(), [], "kept, not listed: the deletion stands until the person decides")
    }

    /// A deletion that does not happen leaves no mark: of a profile not listed — no folder is made
    /// for the mark — nor of one deleted on another device whose folder is kept here.
    func testADeletionThatDoesNotHappenLeavesNoMark() async throws {
        let repository = try vault("v")
        let stranger = UUID()
        XCTAssertThrowsError(try repository.delete(stranger))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: stranger).path))
        XCTAssertEqual(repository.unlistedProfileFolders(), [])

        let (id, _) = try keptProfile(in: "w")
        let unlocked = try unlock("w")
        XCTAssertThrowsError(try unlocked.delete(id), "not listed: not deleted again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlocked.deletionMarkURL(for: id).path))
        XCTAssertEqual(unlocked.keptDeletedProfiles().map(\.id), [id], "still kept, not swept as this Mac's")
        _ = unlocked.removeOrphanedDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: id).path))
    }

    /// A deletion of this Mac's own that stopped between the index and the folder is finished.
    func testThisMacsInterruptedDeletionIsFinished() throws {
        let repository = try vault("v")
        let id = try repository.create(name: "P", configuration: proxied).id
        try repository.recordDeletion(id) // stopped before the folder
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.directory(for: id).path))
        let unlocked = try unlock("v")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlocked.directory(for: id).path))
        XCTAssertEqual(unlocked.keptDeletedProfiles(), [])
    }

    /// A deletion that stopped before the index leaves the profile listed, and its mark is taken
    /// away: a later deletion on another device must not look like this Mac's.
    func testAMarkOnAListedProfileIsTakenAway() throws {
        let repository = try vault("v")
        let id = try repository.create(name: "P", configuration: proxied).id
        try Data().write(to: repository.deletionMarkURL(for: id))
        let unlocked = try unlock("v")
        XCTAssertEqual(unlocked.list().map(\.id), [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlocked.deletionMarkURL(for: id).path))
    }

    /// Deleted on another device: the sync takes it out of the list here, and keeps its folder.
    func testADeletionFromAnotherDeviceKeepsTheFolderHere() async throws {
        let server = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let a = try vault("A")
        let id = try a.create(name: "Shared", configuration: proxied).id
        _ = try await SyncEngine(repository: a, transport: server).sync()
        let b = try ProfileRepository.openedAtUnlock(vault: await SyncEngine.bootstrap(transport: server, root: root.appendingPathComponent("B"), password: "pw"))
        _ = try await SyncEngine(repository: b, transport: server).sync()
        try a.delete(id)
        _ = try await SyncEngine(repository: a, transport: server).sync()
        let report = try await SyncEngine(repository: b, transport: server).sync()
        XCTAssertEqual(report.deletedProfileIDs, [id])
        XCTAssertEqual(b.list(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.directory(for: id).path))
        XCTAssertEqual(b.keptDeletedProfiles().map(\.name), ["Shared"])
        // Still kept at the next unlock.
        let unlocked = try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: root.appendingPathComponent("B"), password: "pw"))
        XCTAssertEqual(unlocked.keptDeletedProfiles().map(\.id), [id])
    }

    /// A kept deleted profile, its folder put back from a backup after it was deleted here.
    private func keptProfile(in name: String) throws -> (UUID, URL) {
        let repository = try vault(name)
        let id = try repository.create(name: "P", configuration: proxied).id
        let key = try repository.profileKey(for: id)
        try repository.passwordVault(for: id).upsert(PasswordEntry(origin: "https://site.test", username: "bob", password: "s3cret"))
        try repository.bookmarkStore(for: id, key: key).add(title: "B", url: URL(string: "https://b.test/")!)
        let history = try repository.historyStore(for: id, key: key)
        history.recordVisit(url: URL(string: "https://h.test/")!, title: "H")
        try history.save()
        try repository.saveOpenTabs(OpenTabs(windows: [.init(tabs: [URL(string: "https://tab.test/")!])]), for: id)
        let copy = root.appendingPathComponent("copy-\(name)")
        try FileManager.default.copyItem(at: repository.directory(for: id), to: copy)
        try repository.delete(id)
        try FileManager.default.copyItem(at: copy, to: repository.directory(for: id))
        return (id, copy)
    }

    /// Brought back: a new profile with its settings, passwords, bookmarks and history; the
    /// deletion of the old id still recorded. The old folder is not removed — the open tabs, which
    /// an export does not carry, are still in it — but marked brought back, and it is not brought
    /// back twice.
    func testBringingAProfileBack() throws {
        let (id, _) = try keptProfile(in: "v")
        let unlocked = try unlock("v")
        let before = try FileManager.default.contentsOfDirectory(atPath: unlocked.directory(for: id).path).sorted()

        let back = try ProfileTransfer.bringBack(id, in: unlocked)
        XCTAssertNotEqual(back.id, id)
        XCTAssertEqual(back.name, "P")
        XCTAssertEqual(unlocked.list().map(\.id), [back.id])
        let newKey = try unlocked.profileKey(for: back.id)
        XCTAssertEqual(try unlocked.loadConfiguration(back.id).proxy?.host, "proxy.example")
        XCTAssertEqual(try unlocked.passwordVault(for: back.id).allEntries().map(\.password), ["s3cret"])
        XCTAssertEqual(try unlocked.bookmarkStore(for: back.id, key: newKey).all().map(\.title), ["B"])
        XCTAssertEqual(try unlocked.historyStore(for: back.id, key: newKey).count, 1)
        XCTAssertTrue(unlocked.currentIndex().deletedProfileIDs.contains(id))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unlocked.directory(for: id).path).sorted(),
                       (before + ["brought-back"]).sorted(), "the old folder is kept whole: nothing in it is removed")
        XCTAssertEqual(try String(contentsOf: unlocked.broughtBackMarkURL(for: id), encoding: .utf8), back.id.uuidString)
        XCTAssertEqual(unlocked.keptDeletedProfiles(), [.init(id: id, name: "P", createdAt: try XCTUnwrap(unlocked.readKeyCopy(id)?.createdAt),
                                                             broughtBack: true)])
        XCTAssertThrowsError(try ProfileTransfer.bringBack(id, in: unlocked), "brought back once only")
        XCTAssertEqual(unlocked.list().count, 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("lumen-bring-back-") }
        XCTAssertEqual(left, [], "the export it went through is removed")

        // Still so at the next unlock; and the person removes the old folder.
        let again = try unlock("v")
        XCTAssertEqual(again.keptDeletedProfiles().map(\.broughtBack), [true])
        try again.removeKeptDeletedProfile(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.directory(for: id).path))
        XCTAssertEqual(again.list().map(\.id), [back.id])
    }

    /// While a folder is being brought back, a second bring-back of it at once is refused.
    func testOneBringBackOfAFolderAtATime() throws {
        let (id, _) = try keptProfile(in: "v")
        let unlocked = try unlock("v")
        XCTAssertTrue(unlocked.beginBringingBack(id))
        XCTAssertThrowsError(try ProfileTransfer.bringBack(id, in: unlocked))
        XCTAssertEqual(unlocked.list(), [])
        unlocked.endBringingBack(id)
        XCTAssertNoThrow(try ProfileTransfer.bringBack(id, in: unlocked))
    }

    /// Removed for good, by the person: gone. A profile that is not a kept deleted one is refused.
    func testRemovingAKeptProfileForGood() throws {
        let (id, _) = try keptProfile(in: "v")
        let listed = try unlock("v").create(name: "Q", configuration: proxied).id
        let unlocked = try unlock("v")
        XCTAssertThrowsError(try unlocked.removeKeptDeletedProfile(listed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: listed).path))
        try unlocked.removeKeptDeletedProfile(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlocked.directory(for: id).path))
        XCTAssertEqual(unlocked.keptDeletedProfiles(), [])
    }

    /// A kept folder whose key copy does not open cannot be read at all: it is shown, unnamed, and
    /// never removed — not even when asked — nor brought back.
    func testAFolderThatCannotBeReadIsNeverRemoved() throws {
        let (id, _) = try keptProfile(in: "v")
        let unlocked = try unlock("v")
        let keyCopy = unlocked.directory(for: id).appendingPathComponent("key.bin")
        var damaged = try Data(contentsOf: keyCopy)
        damaged[damaged.count - 1] ^= 0xFF
        try damaged.write(to: keyCopy)

        XCTAssertEqual(unlocked.keptDeletedProfiles(), [.init(id: id, name: nil, createdAt: nil)])
        XCTAssertFalse(try XCTUnwrap(unlocked.keptDeletedProfiles().first).isReadable)
        XCTAssertThrowsError(try unlocked.removeKeptDeletedProfile(id))
        XCTAssertThrowsError(try ProfileTransfer.bringBack(id, in: unlocked))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: id).path))
        XCTAssertEqual(try Data(contentsOf: keyCopy), damaged)
        XCTAssertEqual(unlocked.list(), [])
    }
}
