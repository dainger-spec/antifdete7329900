import XCTest
@testable import BrowserCore

/// R4 and R2 (docs/DESTRUCTIVE_PATHS.md): every version of a profile's settings that a sync does
/// not keep as the settings is kept beside them, in a file of its own, with where it is from and
/// when, and none goes but by the person's hand. A version older than the server's that was put
/// back here from a backup is such a version (R2): the server's stay the settings.
final class KeptSettingsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-kept-settings-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func vault(_ name: String) throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: root.appendingPathComponent(name), password: "pw", iterations: 1_000))
    }

    private func sync(_ repository: ProfileRepository, _ server: SyncTransport) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: server).sync()
    }

    private func edit(_ repository: ProfileRepository, _ id: UUID, zone: String, at time: Date) throws {
        var configuration = try repository.loadConfiguration(id)
        configuration.timeZoneIdentifier = zone
        try repository.saveConfiguration(configuration.savingEdit(over: try repository.loadConfiguration(id), at: time), for: id)
    }

    private func twoDevices() async throws -> (LocalDirectorySyncTransport, ProfileRepository, ProfileRepository, UUID) {
        let server = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let a = try vault("A")
        let id = try a.create(name: "P", configuration: ProfileConfiguration()).id
        _ = try await sync(a, server)
        let b = try ProfileRepository.openedAtUnlock(vault: await SyncEngine.bootstrap(transport: server, root: root.appendingPathComponent("B"), password: "pw"))
        _ = try await sync(b, server)
        return (server, a, b, id)
    }

    // MARK: R4

    /// The test that confirmed R4 in the audit (appendix B): a second conflict wrote over the first
    /// conflict's copy. Now each is kept, with where it is from.
    func testEveryConflictKeepsItsOwnVersion() async throws {
        let (server, a, b, id) = try await twoDevices()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try edit(b, id, zone: "Europe/Berlin", at: t0)
        try edit(a, id, zone: "Asia/Tokyo", at: t0.addingTimeInterval(10))
        _ = try await sync(a, server)
        _ = try await sync(b, server) // conflict 1: A's newer settings win on B; B's Berlin is kept
        try edit(b, id, zone: "Europe/Paris", at: t0.addingTimeInterval(20))
        try edit(a, id, zone: "America/Chicago", at: t0.addingTimeInterval(30))
        _ = try await sync(a, server)
        _ = try await sync(b, server) // conflict 2: B's Paris is kept beside Berlin

        let kept = b.keptSettings(for: id)
        XCTAssertEqual(kept.map(\.file), ["config.bin.conflict", "config.bin.conflict-2"])
        XCTAssertEqual(kept.compactMap(\.configuration?.timeZoneIdentifier), ["Europe/Berlin", "Europe/Paris"])
        XCTAssertEqual(kept.map(\.origin), [.thisMac, .thisMac])
        XCTAssertEqual(kept.map(\.editedAt), [t0, t0.addingTimeInterval(20)])
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "America/Chicago")
    }

    /// The device that wins keeps the other's version, said as the other device's.
    func testTheWinningDeviceKeepsTheOthersVersion() async throws {
        let (server, a, b, id) = try await twoDevices()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try edit(a, id, zone: "Asia/Tokyo", at: t0)
        _ = try await sync(a, server)
        try edit(b, id, zone: "Europe/Oslo", at: t0.addingTimeInterval(10)) // B's is newer
        _ = try await sync(b, server)
        XCTAssertEqual(b.keptSettings(for: id).map(\.origin), [.otherDevice])
        XCTAssertEqual(b.keptSettings(for: id).first?.configuration?.timeZoneIdentifier, "Asia/Tokyo")
    }

    /// Past five versions the sync says the profile wants them gone through; none is removed.
    func testManyVersionsAreToBeReviewedAndNoneIsRemoved() async throws {
        let (server, a, b, id) = try await twoDevices()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var last = SyncReport()
        for round in 0..<6 {
            try edit(b, id, zone: round % 2 == 0 ? "Europe/Berlin" : "Europe/Paris", at: time)
            time.addTimeInterval(10)
            try edit(a, id, zone: round % 2 == 0 ? "Asia/Tokyo" : "Asia/Seoul", at: time)
            time.addTimeInterval(10)
            _ = try await sync(a, server)
            last = try await sync(b, server)
        }
        XCTAssertEqual(b.keptSettings(for: id).count, 6)
        XCTAssertEqual(last.settingsVersionsToReview, [id])
    }

    // MARK: The person's hand

    /// "Use this version": the kept one becomes the settings, as a new edit (so sync takes it
    /// everywhere), and the settings it replaces are kept in its place — nothing is dropped.
    func testUsingAKeptVersionKeepsTheReplacedSettings() async throws {
        let (server, a, b, id) = try await twoDevices()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try edit(b, id, zone: "Europe/Berlin", at: t0)
        try edit(a, id, zone: "Asia/Tokyo", at: t0.addingTimeInterval(10))
        _ = try await sync(a, server)
        _ = try await sync(b, server)
        try b.useKeptSettings("config.bin.conflict", for: id, at: t0.addingTimeInterval(100))
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "Europe/Berlin")
        let kept = b.keptSettings(for: id)
        XCTAssertEqual(kept.map(\.origin), [.replaced])
        XCTAssertEqual(kept.first?.configuration?.timeZoneIdentifier, "Asia/Tokyo")
        _ = try await sync(b, server)
        _ = try await sync(a, server)
        XCTAssertEqual(try a.loadConfiguration(id).timeZoneIdentifier, "Europe/Berlin", "the choice is the newest edit, everywhere")
    }

    /// A version the person removes goes; one that does not open never does.
    func testRemovingAVersionTakesTheReadableOneOnly() async throws {
        let (server, a, b, id) = try await twoDevices()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try edit(b, id, zone: "Europe/Berlin", at: t0)
        try edit(a, id, zone: "Asia/Tokyo", at: t0.addingTimeInterval(10))
        _ = try await sync(a, server)
        _ = try await sync(b, server)
        try b.removeKeptSettings("config.bin.conflict", for: id)
        XCTAssertEqual(b.keptSettings(for: id), [])

        try SecureFile.write(Data(repeating: 9, count: 64), to: b.directory(for: id).appendingPathComponent("config.bin.conflict-2"))
        XCTAssertEqual(b.keptSettings(for: id).map(\.file), ["config.bin.conflict-2"])
        XCTAssertNil(b.keptSettings(for: id).first?.configuration)
        XCTAssertThrowsError(try b.removeKeptSettings("config.bin.conflict-2", for: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.directory(for: id).appendingPathComponent("config.bin.conflict-2").path))
    }

    // MARK: R2

    /// The test that confirmed R2 in the audit (appendix B): an old config.bin put back from a
    /// backup was pushed over the newer settings, everywhere, with no copy. Now the newer settings
    /// stay, and the old ones are kept as a version, said as put back.
    func testOlderSettingsPutBackDoNotReplaceTheNewerOnes() async throws {
        let (server, a, b, id) = try await twoDevices()
        let backup = try Data(contentsOf: a.configURL(for: id))
        try edit(a, id, zone: "Europe/Oslo", at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try await sync(a, server)
        try backup.write(to: a.configURL(for: id)) // a partial restore: the settings from before
        let report = try await sync(a, server)
        XCTAssertEqual(report.restoredSettings, [id])
        XCTAssertFalse(report.pushed.contains("profile/\(id.uuidString)/config"), "\(report.pushed)")
        XCTAssertEqual(try a.loadConfiguration(id).timeZoneIdentifier, "Europe/Oslo")
        XCTAssertEqual(a.keptSettings(for: id).map(\.origin), [.restored])
        XCTAssertEqual(try Data(contentsOf: a.directory(for: id).appendingPathComponent("config.bin.conflict")), backup)
        _ = try await sync(b, server)
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "Europe/Oslo")
    }

    /// What the browser keeps for itself changing here (the proxy location found at a launch) is no
    /// restore: the settings are the same, and they are pushed as before.
    func testOnlyTheProxyLocationChangedHereIsPushedAsBefore() async throws {
        let (server, a, _, id) = try await twoDevices()
        try edit(a, id, zone: "Europe/Oslo", at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try await sync(a, server)
        var configuration = try a.loadConfiguration(id)
        configuration.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Oslo", countryCode: "NO", proxyEndpoint: "p.example:1080")
        try a.saveConfiguration(configuration, for: id)
        let report = try await sync(a, server)
        XCTAssertEqual(report.restoredSettings, [])
        XCTAssertTrue(report.pushed.contains("profile/\(id.uuidString)/config"), "\(report.pushed)")
        XCTAssertEqual(a.keptSettings(for: id), [])
    }

    /// A newer edit made here is pushed as before.
    func testANewerEditHereIsPushed() async throws {
        let (server, a, b, id) = try await twoDevices()
        try edit(a, id, zone: "Europe/Oslo", at: Date(timeIntervalSince1970: 1_800_000_000))
        _ = try await sync(a, server)
        try edit(a, id, zone: "Asia/Tokyo", at: Date(timeIntervalSince1970: 1_800_000_100))
        let report = try await sync(a, server)
        XCTAssertEqual(report.restoredSettings, [])
        _ = try await sync(b, server)
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo")
    }
}
