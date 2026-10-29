import XCTest
@testable import BrowserCore

/// A profile's own process is handed its profile's grant, not the vault's master key
/// (`ProfileGrant`): the vault it opens with it holds that one profile and refuses the rest.
final class ProfileGrantTests: XCTestCase {
    var root: URL!
    var manager: ProfileRepository!
    var granted: ProfileSummary!
    var other: ProfileSummary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-grant-\(UUID().uuidString)")
        manager = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        granted = try manager.create(name: "Granted", configuration: ProfileConfiguration(startURL: URL(string: "https://granted.test/")))
        other = try manager.create(name: "Other", configuration: ProfileConfiguration(startURL: URL(string: "https://other.test/")))
        try manager.passwordVault(for: other.id).upsert(PasswordEntry(origin: "https://other.test", username: "u", password: "secret"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The child's repository, from the record as it crosses the pipe.
    private func childRepository() throws -> ProfileRepository {
        var record = try manager.grant(for: granted.id).encoded()
        defer { ProfileGrant.erase(&record) }
        var offset = 0
        let grant = try ProfileGrant.read { count in
            let chunk = record.subdata(in: offset..<min(offset + count, record.count))
            offset += chunk.count
            return chunk
        }
        return try ProfileRepository(vault: MasterVault.open(in: root, grant: grant))
    }

    func testTheRecordCarriesTheProfileAndLeavesWhatFollowsOnTheStream() throws {
        let grant = try manager.grant(for: granted.id)
        var record = try grant.encoded()
        XCTAssertEqual(record.prefix(4), Data("PBG1".utf8))
        XCTAssertFalse(record.isEmpty)
        let commands = Data("{\"stop\":{}}\n".utf8)
        let stream = record + commands
        // Read in small pieces, as a pipe can deliver it.
        var offset = 0
        let read = try ProfileGrant.read { count in
            let chunk = stream.subdata(in: offset..<min(offset + min(count, 3), stream.count))
            offset += chunk.count
            return chunk
        }
        // Dates to the second, as the index on disk keeps them.
        XCTAssertEqual(read.summary.id, granted.id)
        XCTAssertEqual(read.summary.name, granted.name)
        XCTAssertEqual(read.summary.revision, granted.revision)
        XCTAssertEqual(read.summary.createdAt.timeIntervalSince1970, granted.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(read.key.rawBytes, try manager.profileKey(for: granted.id).rawBytes)
        XCTAssertEqual(stream.subdata(in: offset..<stream.count), commands, "the commands after the grant are left unread")
        ProfileGrant.erase(&record)
        XCTAssertTrue(record.allSatisfy { $0 == 0 })
    }

    func testATruncatedOrForeignRecordIsRefused() throws {
        let record = try manager.grant(for: granted.id).encoded()
        func read(_ data: Data) throws -> ProfileGrant {
            var offset = 0
            return try ProfileGrant.read { count in
                guard offset < data.count else { return nil }
                let chunk = data.subdata(in: offset..<min(offset + count, data.count))
                offset += chunk.count
                return chunk
            }
        }
        XCTAssertThrowsError(try read(record.prefix(40))) { error in
            guard case .corruptData? = error as? CoreError else { return XCTFail("\(error)") }
        }
        // The 32 bytes the child used to expect: the vault master key, which is not a grant.
        XCTAssertThrowsError(try read(Data(repeating: 7, count: 32))) { error in
            XCTAssertEqual(error as? CoreError, .unsupportedFormat("not a profile grant"))
        }
        var huge = record.prefix(36)
        huge.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try read(huge)) { error in
            guard case .corruptData? = error as? CoreError else { return XCTFail("\(error)") }
        }
    }

    func testAGrantedVaultOpensItsProfileAndNoOther() throws {
        let child = try childRepository()
        XCTAssertNotNil(child.vault.grant)
        XCTAssertEqual(child.list().map(\.id), [granted.id], "the other profiles' names are not there to read")
        XCTAssertEqual(child.list().map(\.name), ["Granted"])
        XCTAssertEqual(try child.loadConfiguration(granted.id).startURL, URL(string: "https://granted.test/"))
        XCTAssertEqual(try child.profileKey(for: granted.id).rawBytes, try manager.profileKey(for: granted.id).rawBytes)

        XCTAssertThrowsError(try child.profileKey(for: other.id)) { error in
            XCTAssertEqual(error as? CoreError, .profileNotFound(other.id))
        }
        XCTAssertThrowsError(try child.loadConfiguration(other.id))
        XCTAssertThrowsError(try child.passwordVault(for: other.id))
        XCTAssertThrowsError(try child.cookieJar(for: other.id))
        XCTAssertThrowsError(try child.summary(for: other.id))
    }

    func testAGrantedVaultHasNoneOfTheVaultsOwnKeys() throws {
        let child = try childRepository()
        func refused(_ what: String, _ body: () throws -> Void) {
            XCTAssertThrowsError(try body(), what) { error in
                guard case .notGranted? = error as? CoreError else { return XCTFail("\(what): \(error)") }
            }
        }
        refused("index key") { _ = try child.vault.indexKey }
        refused("profile key wrapping") { _ = try child.vault.profileKeyWrappingKey }
        refused("proxy list") { _ = try ProxyList.load(from: child.vault) }
        refused("device settings") { _ = try DeviceSettings.load(from: child.vault) }
        refused("sync") { _ = try SyncEngine(repository: child, transport: LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))) }
        refused("a grant of its own") { _ = try child.grant(for: granted.id) }
        refused("creating a profile") { _ = try child.create(name: "New", configuration: ProfileConfiguration()) }
        refused("renaming") { try child.rename(granted.id, to: "Renamed") }
        refused("deleting") { try child.delete(granted.id) }
        refused("a new master password") { try child.vault.changePassword(current: "pw", new: "pw2", iterations: 1_000) }
        // Nothing of the refused writes reached the disk.
        let reopened = try ProfileRepository(vault: MasterVault.unlock(in: root, password: "pw"))
        XCTAssertEqual(reopened.list().map(\.name), ["Granted", "Other"])
    }

    func testTheChildWritesItsProfileButNeverTheIndex() throws {
        let child = try childRepository()
        var bumped: [UUID] = []
        child.onRevisionBump = { bumped.append($0) }
        let indexBefore = try Data(contentsOf: manager.indexURL)
        // The manager changes the index while the child runs (a profile created meanwhile).
        let created = try manager.create(name: "Created meanwhile", configuration: ProfileConfiguration())
        let indexWithNewProfile = try Data(contentsOf: manager.indexURL)
        XCTAssertNotEqual(indexBefore, indexWithNewProfile)

        var configuration = try child.loadConfiguration(granted.id)
        configuration.startURL = URL(string: "https://changed-in-child.test/")
        try child.saveConfiguration(configuration, for: granted.id)
        try child.markLaunched(granted.id)
        let history = try child.historyStore(for: granted.id, key: child.profileKey(for: granted.id))
        XCTAssertTrue(history.recordVisit(url: URL(string: "https://visited.test/")!, title: "Visited"))
        try history.save()
        child.removeOrphanedDirectories()

        XCTAssertEqual(bumped, [granted.id], "the settings change is handed to the manager to record")
        XCTAssertEqual(try Data(contentsOf: manager.indexURL), indexWithNewProfile,
                       "the child never writes the index: the profile created meanwhile stays in it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.directory(for: other.id).path),
                      "the other profiles' folders are not orphans to a granted vault")
        // The manager reads what the child wrote, with the same profile key.
        XCTAssertEqual(try manager.loadConfiguration(granted.id).startURL, URL(string: "https://changed-in-child.test/"))
        let seen = try manager.historyStore(for: granted.id, key: manager.profileKey(for: granted.id))
        XCTAssertEqual(seen.entries().map(\.url), ["https://visited.test/"])
        XCTAssertEqual(try ProfileRepository(vault: MasterVault.unlock(in: root, password: "pw")).list().map(\.id),
                       [granted.id, other.id, created.id])
    }
}
