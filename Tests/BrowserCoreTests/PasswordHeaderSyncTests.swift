import XCTest
@testable import BrowserCore

/// The vault's header on the sync location after a change of the master password (the owner's
/// report: a new device joined with the old password and not with the new one, because the header
/// there was put there once, when the vault was first synced, and never again).
///
/// A change of the master password wraps the vault's key anew and counts the change
/// (`VaultHeader.passwordRevision`); sync puts this device's header there when it is the newer,
/// and never an older one over a newer.
final class PasswordHeaderSyncTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-header-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var server: LocalDirectorySyncTransport { LocalDirectorySyncTransport(directory: root.appendingPathComponent("server")) }

    private func device(_ name: String, password: String = "old") throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: root.appendingPathComponent(name), password: password, iterations: 1_000))
    }

    private func joining(_ name: String, password: String) async throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: await SyncEngine.bootstrap(transport: server, root: root.appendingPathComponent(name),
                                                                              password: password))
    }

    private func joins(_ name: String, password: String) async -> Bool {
        (try? await SyncEngine.bootstrap(transport: server, root: root.appendingPathComponent(name), password: password)) != nil
    }

    private func sync(_ repository: ProfileRepository) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: server).sync()
    }

    private func remoteHeader() async throws -> VaultHeader {
        let blob = try await server.fetch(objectID: SyncEngine.vaultHeaderObjectID)
        return try VaultHeader.decodeChecked(XCTUnwrap(blob))
    }

    /// The owner's report, closed: after a change and a sync, a new device joins with the new
    /// password and not with the old one.
    func testANewDeviceJoinsWithTheNewPasswordAfterAChangeAndNotWithTheOld() async throws {
        let a = try device("A")
        let id = try a.create(name: "P", configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo")).id
        _ = try await sync(a)
        try a.vault.changePassword(current: "old", new: "new", iterations: 1_000)
        XCTAssertEqual(a.vault.header.passwordRevision, 1)
        let report = try await sync(a)
        XCTAssertEqual(report.passwordHeader, .published)
        let joinedWithOld = await joins("C-old", password: "old")
        XCTAssertFalse(joinedWithOld, "a new device joined with the old password")
        let c = try await joining("C", password: "new")
        _ = try await sync(c)
        XCTAssertEqual(try c.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo")
        // Synced again, nothing left to put there.
        let again = try await sync(a)
        XCTAssertEqual(again.passwordHeader, .same)
    }

    /// The app puts the header there right after the change, without a whole sync.
    func testTheHeaderGoesThereOnItsOwnRightAfterTheChange() async throws {
        let a = try device("A")
        _ = try await sync(a)
        try a.vault.changePassword(current: "old", new: "new", iterations: 1_000)
        let result = try await SyncEngine(repository: a, transport: server).publishVaultHeader()
        XCTAssertEqual(result, .published)
        let joined = await joins("C", password: "new")
        XCTAssertTrue(joined)
    }

    /// A device set up before the change keeps its own header: it syncs on (the vault's key has not
    /// changed), never puts its older header back, and says the sync location holds a newer one.
    func testADeviceStillOnTheOldPasswordNeverPutsItBack() async throws {
        let a = try device("A")
        let id = try a.create(name: "P", configuration: ProfileConfiguration()).id
        _ = try await sync(a)
        let b = try await joining("B", password: "old")
        _ = try await sync(b)
        try a.vault.changePassword(current: "old", new: "new", iterations: 1_000)
        _ = try await sync(a)
        let published = try await remoteHeader()

        try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://site.example", username: "me", password: "after the change"))
        _ = try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.passwordHeader, .newerElsewhere)
        let after = try await remoteHeader()
        XCTAssertEqual(after, published, "a device on the old password put its header back")
        XCTAssertEqual(try b.passwordVault(for: id).allEntries().map(\.password), ["after the change"], "B stopped syncing")
        // B's own vault.json is B's: it opens with the old password (docs: what a change does not do).
        XCTAssertNoThrow(try MasterVault.unlock(in: root.appendingPathComponent("B"), password: "old"))
        let joinedWithOld = await joins("C", password: "old")
        XCTAssertFalse(joinedWithOld)
    }

    /// The password changed on two devices before either synced: the first header there stays, the
    /// other device says so, and a new device joins with the first one's password.
    func testTwoChangesMadeApartLeaveTheFirstThere() async throws {
        let a = try device("A")
        _ = try await sync(a)
        let b = try await joining("B", password: "old")
        _ = try await sync(b)
        try a.vault.changePassword(current: "old", new: "set on A", iterations: 1_000)
        try b.vault.changePassword(current: "old", new: "set on B", iterations: 1_000)
        let first = try await sync(a)
        XCTAssertEqual(first.passwordHeader, .published)
        let second = try await sync(b)
        XCTAssertEqual(second.passwordHeader, .differentElsewhere)
        let joinedWithA = await joins("C", password: "set on A")
        XCTAssertTrue(joinedWithA)
        let joinedWithB = await joins("D", password: "set on B")
        XCTAssertFalse(joinedWithB)
    }

    /// A device behind the sync location changes its own password knowing the count there
    /// (`atLeast`): its change is then the newest, and goes there.
    func testAChangeMadeKnowingTheSyncLocationsCountGoesThere() async throws {
        let a = try device("A")
        _ = try await sync(a)
        let b = try await joining("B", password: "old")
        _ = try await sync(b)
        try a.vault.changePassword(current: "old", new: "set on A", iterations: 1_000)
        _ = try await sync(a)
        let there = try await remoteHeader()
        try b.vault.changePassword(current: "old", new: "set on B", iterations: 1_000, atLeast: there.passwordRevision)
        let report = try await sync(b)
        XCTAssertEqual(report.passwordHeader, .published)
        let joinedWithB = await joins("C", password: "set on B")
        XCTAssertTrue(joinedWithB)
        // A, now behind, does not put its own back.
        let fromA = try await sync(a)
        XCTAssertEqual(fromA.passwordHeader, .newerElsewhere)
    }

    /// What a change of the master password does not do, written down so that the documentation
    /// and the code cannot part ways: a copy of `vault.json` from before the change opens the vault
    /// with the old password — the data written after the change included. (A change of every key
    /// is a project of its own: docs/ARCHITECTURE.md, Changing the master password.)
    func testAnOldCopyOfVaultJSONStillOpensEverythingWithTheOldPassword() throws {
        let folder = root.appendingPathComponent("A")
        let a = try device("A")
        let oldCopy = try Data(contentsOf: MasterVault.headerURL(in: folder))
        try a.vault.changePassword(current: "old", new: "new", iterations: 1_000)
        let later = try a.create(name: "After the change", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Oslo")).id
        try oldCopy.write(to: MasterVault.headerURL(in: folder))
        let opened = try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: folder, password: "old"))
        XCTAssertEqual(try opened.loadConfiguration(later).timeZoneIdentifier, "Europe/Oslo")
    }
}
