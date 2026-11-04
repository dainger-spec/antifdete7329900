import XCTest
@testable import BrowserCore

/// Each profile's folder holds a copy of its key (`key.bin`, sealed under the vault's index key), so
/// that losing `index.bin` no longer loses the profiles: unlocking without it puts the index
/// together again from the copies, and an older index put back gets the profiles made since listed
/// again (the owner's question 1). An index that cannot be read is still never written over.
final class ProfileKeyCopyTests: XCTestCase {
    var root: URL!
    let password = "pw"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-keycopy-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var indexURL: URL { root.appendingPathComponent("index.bin") }

    private func unlock(_ folder: URL? = nil) throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: folder ?? root, password: password))
    }

    private func vault() throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: root, password: password, iterations: 1_000))
    }

    func testALostIndexIsPutTogetherFromTheProfilesKeyCopies() throws {
        let repository = try vault()
        let a = try repository.create(name: "Paris", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris"))
        let b = try repository.create(name: "Second", configuration: ProfileConfiguration())
        try repository.passwordVault(for: b.id).upsert(PasswordEntry(origin: "https://site.example", username: "u", password: "kept"))
        try FileManager.default.removeItem(at: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .read)
        XCTAssertEqual(unlocked.list().map(\.name), ["Paris", "Second"])
        XCTAssertEqual(Set(unlocked.takenInFromKeyCopies), [a.id, b.id])
        XCTAssertEqual(try unlocked.loadConfiguration(a.id).timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(try unlocked.passwordVault(for: b.id).allEntries().map(\.password), ["kept"])
        XCTAssertEqual(unlocked.unlistedProfileFolders(), [])
        // Written: the next unlock reads it, and takes in nothing more.
        let again = try unlock()
        XCTAssertEqual(again.list().map(\.id), [a.id, b.id])
        XCTAssertEqual(again.takenInFromKeyCopies, [])
    }

    func testAnOlderIndexPutBackListsTheProfilesMadeSinceAgain() throws {
        let repository = try vault()
        let a = try repository.create(name: "A", configuration: ProfileConfiguration())
        let older = try Data(contentsOf: indexURL)
        let c = try repository.create(name: "Made since", configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"))
        try older.write(to: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.list().map(\.id), [a.id, c.id])
        XCTAssertEqual(unlocked.takenInFromKeyCopies, [c.id])
        XCTAssertEqual(try unlocked.loadConfiguration(c.id).timeZoneIdentifier, "Asia/Tokyo")
    }

    /// Only this vault's copies: a folder without one, or with another vault's, stays out of the
    /// list — and is kept, as before.
    func testAFolderWithoutACopyThisVaultOpensStaysOutOfTheListAndIsKept() throws {
        let other = root.appendingPathComponent("other")
        let foreign = try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: other, password: password, iterations: 1_000))
        let stranger = try foreign.create(name: "Other vault's", configuration: ProfileConfiguration())
        let repository = try vault()
        let a = try repository.create(name: "A", configuration: ProfileConfiguration())
        try FileManager.default.copyItem(at: foreign.directory(for: stranger.id), to: repository.directory(for: stranger.id))
        let bare = UUID()
        try FileManager.default.createDirectory(at: repository.directory(for: bare), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.list().map(\.id), [a.id])
        XCTAssertEqual(Set(unlocked.unlistedProfileFolders()), [stranger.id, bare])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: stranger.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: bare).path))
    }

    func testADeletedProfilesFolderPutBackWithItsCopyIsNotBroughtBack() throws {
        let repository = try vault()
        let gone = try repository.create(name: "Deleted", configuration: ProfileConfiguration())
        let saved = root.appendingPathComponent("saved")
        try FileManager.default.copyItem(at: repository.directory(for: gone.id), to: saved)
        try repository.delete(gone.id)
        try FileManager.default.moveItem(at: saved, to: repository.directory(for: gone.id))

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.list(), [])
        XCTAssertEqual(unlocked.takenInFromKeyCopies, [])
    }

    func testAnUnreadableIndexIsNotPutTogetherOverAndNotWrittenOver() throws {
        let repository = try vault()
        let a = try repository.create(name: "A", configuration: ProfileConfiguration())
        var bytes = try Data(contentsOf: indexURL)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .unreadable(profileFolders: 1))
        XCTAssertEqual(unlocked.takenInFromKeyCopies, [])
        XCTAssertEqual(try Data(contentsOf: indexURL), bytes, "the unreadable index was written over")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: a.id).path))
    }

    /// Put together while it was missing, then the original put back while the vault is unlocked
    /// (as the Profiles window says to): the one put back is never written over.
    func testAnIndexPutBackAfterItWasPutTogetherIsNeverWrittenOver() throws {
        let repository = try vault()
        let a = try repository.create(name: "A", configuration: ProfileConfiguration())
        try repository.markLaunched(a.id)
        let original = try Data(contentsOf: indexURL)
        try FileManager.default.removeItem(at: indexURL)
        let rebuilt = try unlock()
        XCTAssertEqual(rebuilt.list().map(\.id), [a.id])
        try original.write(to: indexURL)
        XCTAssertThrowsError(try rebuilt.create(name: "B", configuration: ProfileConfiguration()))
        XCTAssertEqual(try Data(contentsOf: indexURL), original)
        XCTAssertNotNil(try unlock().list().first?.lastLaunchedAt, "the index put back was not the one read")
    }

    /// A vault from before the copies gets them at its next unlock; a rename renames the copy.
    func testCopiesAreWrittenForOlderVaultsAndFollowARename() throws {
        let repository = try vault()
        let a = try repository.create(name: "Before", configuration: ProfileConfiguration())
        try FileManager.default.removeItem(at: repository.keyCopyURL(for: a.id))
        let unlocked = try unlock()
        XCTAssertNotNil(unlocked.readKeyCopy(a.id), "no copy written for a profile from before the copies")
        try unlocked.rename(a.id, to: "After")
        try FileManager.default.removeItem(at: indexURL)
        XCTAssertEqual(try unlock().list().map(\.name), ["After"])
    }

    /// A profile another device made arrives through sync with its copy written here too.
    func testAProfileSyncBroughtGetsItsCopyHere() async throws {
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let deviceA = root.appendingPathComponent("A")
        let a = try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: deviceA, password: password, iterations: 1_000))
        let made = try a.create(name: "From A", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Oslo"))
        _ = try await SyncEngine(repository: a, transport: transport).sync()
        let deviceB = root.appendingPathComponent("B")
        let b = try ProfileRepository.openedAtUnlock(vault: await SyncEngine.bootstrap(transport: transport, root: deviceB, password: password))
        _ = try await SyncEngine(repository: b, transport: transport).sync()
        XCTAssertNotNil(b.readKeyCopy(made.id))
        try FileManager.default.removeItem(at: deviceB.appendingPathComponent("index.bin"))
        let unlocked = try unlock(deviceB)
        XCTAssertEqual(unlocked.list().map(\.name), ["From A"])
        XCTAssertEqual(try unlocked.loadConfiguration(made.id).timeZoneIdentifier, "Europe/Oslo")
    }
}
