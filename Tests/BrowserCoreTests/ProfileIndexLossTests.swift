import XCTest
@testable import BrowserCore

/// A vault's profile index (`index.bin`) holds its profiles' keys, so an index that is missing or
/// cannot be read is not "no profiles". The owner's report: with `index.bin` gone, the
/// next unlock deleted every profile folder (`removeOrphanedDirectories` swept every folder the
/// empty index did not list). Each test opens the repository the way unlocking does
/// (`ProfileRepository.openedAtUnlock`, which AppModel's unlock runs).
///
/// The profiles here have no key copy in their folders (`key.bin`), as in a vault from before the
/// copies, or with the copies lost too: what happens to folders whose key is in no file but the
/// index. `ProfileKeyCopyTests` has the index put together again from the copies.
final class ProfileIndexLossTests: XCTestCase {
    var root: URL!
    let password = "pw"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-index-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var indexURL: URL { root.appendingPathComponent("index.bin") }

    private func unlock() throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: root, password: password))
    }

    private func vaultWithTwoProfiles() throws -> (ProfileRepository, ProfileSummary, ProfileSummary) {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: password, iterations: 1_000))
        let a = try repository.create(name: "A", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris"))
        let b = try repository.create(name: "B", configuration: ProfileConfiguration())
        try removeKeyCopies()
        return (repository, a, b)
    }

    /// Every profile folder's `key.bin` gone: a vault from before the copies.
    private func removeKeyCopies() throws {
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [] {
            try? FileManager.default.removeItem(at: profiles.appendingPathComponent(name).appendingPathComponent("key.bin"))
        }
    }

    /// The profile's folder with its encrypted settings in it.
    private func kept(_ repository: ProfileRepository, _ ids: UUID...) -> Bool {
        ids.allSatisfy { FileManager.default.fileExists(atPath: repository.directory(for: $0).appendingPathComponent("config.bin").path) }
    }

    func testNoIndexAndTheProfileFoldersThereTheyAreStillThereAfterUnlocking() throws {
        let (_, a, b) = try vaultWithTwoProfiles()
        try FileManager.default.removeItem(at: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .missing(profileFolders: 2))
        XCTAssertEqual(unlocked.list(), [], "an index that is not there lists nothing")
        XCTAssertTrue(kept(unlocked, a.id, b.id), "unlocking without the index deleted the profiles' folders")
        XCTAssertEqual(Set(unlocked.unlistedProfileFolders()), [a.id, b.id], "the kept folders are said")
        // And every unlock after it.
        XCTAssertTrue(kept(try unlock(), a.id, b.id))
    }

    func testTheIndexPutBackBringsTheProfilesBackWhole() throws {
        let (_, a, b) = try vaultWithTwoProfiles()
        let copy = try Data(contentsOf: indexURL)
        try FileManager.default.removeItem(at: indexURL)
        _ = try unlock()

        try copy.write(to: indexURL)
        let restored = try unlock()
        XCTAssertEqual(restored.indexState, .read)
        XCTAssertEqual(restored.list().map(\.id), [a.id, b.id])
        XCTAssertEqual(try restored.loadConfiguration(a.id).timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(restored.unlistedProfileFolders(), [])
    }

    func testAnUnreadableIndexDeletesNothingAndIsNeverWrittenOver() throws {
        let (_, a, b) = try vaultWithTwoProfiles()
        var bytes = try Data(contentsOf: indexURL)
        bytes[bytes.count - 1] ^= 0x01 // one bit of the tag: the AEAD refuses the file
        try bytes.write(to: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .unreadable(profileFolders: 2))
        XCTAssertTrue(kept(unlocked, a.id, b.id))
        XCTAssertThrowsError(try unlocked.create(name: "C", configuration: ProfileConfiguration()))
        XCTAssertEqual(try Data(contentsOf: indexURL), bytes, "the unreadable index was written over")
        XCTAssertEqual(Set(unlocked.profileFolderIDs()), [a.id, b.id], "a profile refused left a folder behind")
    }

    func testANewerVersionsIndexStillRefusesToOpen() throws {
        _ = try vaultWithTwoProfiles()
        let vault = try MasterVault.unlock(in: root, password: password)
        let newer = Data(#"{"format":2,"entries":[],"deletedProfileIDs":[]}"#.utf8)
        try SecureFile.write(AEAD.seal(newer, key: vault.indexKey, aad: "profile-index:v1:\(vault.vaultID.uuidString)"), to: indexURL)
        XCTAssertThrowsError(try unlock()) { error in
            guard case .newerFormat = error as? CoreError else { return XCTFail("\(error)") }
        }
    }

    func testOnlyAProfileTheIndexSaysWasDeletedHasItsFolderSwept() throws {
        let (repository, a, b) = try vaultWithTwoProfiles()
        // A deletion that stopped between the index and the folder: the index says deleted, the folder is there.
        let leftover = try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: b.id).path)
        let saved = repository.directory(for: b.id).deletingLastPathComponent().appendingPathComponent("saved-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repository.directory(for: b.id), to: saved)
        try repository.delete(b.id)
        try FileManager.default.moveItem(at: saved, to: repository.directory(for: b.id))
        XCTAssertFalse(leftover.isEmpty)
        // A folder no index ever listed nor deleted: unknown, so kept.
        let stranger = UUID()
        try FileManager.default.createDirectory(at: repository.directory(for: stranger), withIntermediateDirectories: true)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .read)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unlocked.directory(for: b.id).path), "a deleted profile's folder was kept")
        XCTAssertTrue(kept(unlocked, a.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.directory(for: stranger).path), "a folder no index knows was swept")
        XCTAssertEqual(unlocked.unlistedProfileFolders(), [stranger])
    }

    func testAnOlderIndexPutBackKeepsTheFoldersOfNewerProfiles() throws {
        let (repository, a, b) = try vaultWithTwoProfiles()
        let older = try Data(contentsOf: indexURL)
        let c = try repository.create(name: "C", configuration: ProfileConfiguration())
        try removeKeyCopies()
        try older.write(to: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .read)
        XCTAssertEqual(unlocked.list().map(\.id), [a.id, b.id])
        XCTAssertTrue(kept(unlocked, a.id, b.id, c.id), "the profile the older index does not know was deleted")
        XCTAssertEqual(unlocked.unlistedProfileFolders(), [c.id])
    }

    func testAnIndexWrittenWhileTheOldOneWasMissingKeepsTheOldFolders() throws {
        let (_, a, b) = try vaultWithTwoProfiles()
        try FileManager.default.removeItem(at: indexURL)
        let missing = try unlock()
        let d = try missing.create(name: "D", configuration: ProfileConfiguration())

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .read)
        XCTAssertEqual(unlocked.list().map(\.id), [d.id])
        XCTAssertTrue(kept(unlocked, a.id, b.id, d.id), "the folders of the profiles the lost index listed were deleted")
        XCTAssertEqual(Set(unlocked.unlistedProfileFolders()), [a.id, b.id])
    }

    func testAnIndexPutBackWhileTheVaultIsUnlockedIsNeverWrittenOver() throws {
        let (_, a, b) = try vaultWithTwoProfiles()
        let copy = try Data(contentsOf: indexURL)
        try FileManager.default.removeItem(at: indexURL)
        let missing = try unlock()
        // A profile made while the index was missing: the new index is written, and written again.
        let d = try missing.create(name: "D", configuration: ProfileConfiguration())
        try missing.rename(d.id, to: "D2")
        // The backup put back while the vault is still unlocked, as the Profiles window says to.
        try copy.write(to: indexURL)
        XCTAssertThrowsError(try missing.create(name: "E", configuration: ProfileConfiguration()))
        XCTAssertThrowsError(try missing.rename(d.id, to: "D3"))
        XCTAssertEqual(try Data(contentsOf: indexURL), copy, "the index put back was written over")

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .read)
        XCTAssertTrue(kept(unlocked, a.id, b.id, d.id))
        XCTAssertEqual(Set(unlocked.profileFolderIDs()), [a.id, b.id, d.id], "a profile refused left a folder behind")
        // D, made after the copies came in, has its key in its folder: the index put back lists it again.
        XCTAssertEqual(unlocked.list().map(\.id), [a.id, b.id, d.id])
        XCTAssertEqual(unlocked.takenInFromKeyCopies, [d.id])
        XCTAssertEqual(unlocked.list().last?.name, "D2")
    }

    func testSyncPutsAMissingIndexBack() async throws {
        let base = root.appendingPathComponent("sync", isDirectory: true)
        let transport = LocalDirectorySyncTransport(directory: base)
        let (repository, a, b) = try vaultWithTwoProfiles()
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        try FileManager.default.removeItem(at: indexURL)

        let unlocked = try unlock()
        XCTAssertEqual(unlocked.indexState, .missing(profileFolders: 2))
        let report = try await SyncEngine(repository: unlocked, transport: transport).sync()
        XCTAssertEqual(report.deletedProfileIDs, [])
        XCTAssertEqual(Set(unlocked.list().map(\.id)), [a.id, b.id])
        XCTAssertTrue(kept(unlocked, a.id, b.id))
        XCTAssertEqual(try unlocked.loadConfiguration(a.id).timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(try unlock().indexState, .read)
        // The server's index is whole: a new device starts from it with both profiles. (Before, this
        // device's empty index was pushed over it when the server had not changed since the last sync.)
        let other = root.appendingPathComponent("other-device", isDirectory: true)
        let device = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: other, password: password))
        _ = try await SyncEngine(repository: device, transport: transport).sync()
        XCTAssertEqual(Set(device.list().map(\.id)), [a.id, b.id])
    }

    func testAProfileMadeWhileTheIndexWasMissingIsMergedIntoTheServersNotPushedOverIt() async throws {
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("sync", isDirectory: true))
        let (repository, a, b) = try vaultWithTwoProfiles()
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        try FileManager.default.removeItem(at: indexURL)
        let missing = try unlock()
        let d = try missing.create(name: "D", configuration: ProfileConfiguration())

        _ = try await SyncEngine(repository: missing, transport: transport).sync()
        XCTAssertEqual(missing.indexState, .read)
        XCTAssertEqual(Set(missing.list().map(\.id)), [a.id, b.id, d.id])
        XCTAssertEqual(Set(try unlock().list().map(\.id)), [a.id, b.id, d.id])
        let other = root.appendingPathComponent("other-device", isDirectory: true)
        let device = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: other, password: password))
        _ = try await SyncEngine(repository: device, transport: transport).sync()
        XCTAssertEqual(Set(device.list().map(\.id)), [a.id, b.id, d.id])
    }

    func testAMissingIndexIsNeverPushedOverTheServersWhenTheServerDidNotChange() async throws {
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("sync", isDirectory: true))
        let (repository, a, b) = try vaultWithTwoProfiles()
        _ = try await SyncEngine(repository: repository, transport: transport).sync()
        try FileManager.default.removeItem(at: indexURL)
        // This device's index is gone, the server's is unchanged since the last sync: before, the
        // empty index was "a local change" and replaced the server's.
        let other = root.appendingPathComponent("other-device", isDirectory: true)
        let vault = try await SyncEngine.bootstrap(transport: transport, root: other, password: password)
        let missing = try unlock()
        _ = try await SyncEngine(repository: missing, transport: transport).sync()
        let device = try ProfileRepository(vault: vault)
        _ = try await SyncEngine(repository: device, transport: transport).sync()
        XCTAssertEqual(Set(device.list().map(\.id)), [a.id, b.id])
    }
}
