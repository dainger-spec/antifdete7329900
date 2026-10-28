import XCTest
@testable import BrowserCore

/// A profile's own process opens that profile's files with its key alone (docs/PROCESS_PER_PROFILE.md).
final class SingleProfileFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-single-profile-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOpensOneProfileWithItsKeyAlone() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let one = try repository.create(name: "One", configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"))
        let two = try repository.create(name: "Two", configuration: ProfileConfiguration())
        let files = SingleProfileFiles(root: root, profileID: one.id, key: try repository.profileKey(for: one.id))

        XCTAssertEqual(try files.loadConfiguration().timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(files.webDataArchiveURL, repository.webDataArchiveURL(for: one.id))
        XCTAssertEqual(files.locations.directory(for: one.id), repository.directory(for: one.id))

        // What the profile's process writes is what the launcher reads.
        _ = try files.bookmarkStore().add(title: "Example", url: URL(string: "https://example.com/")!)
        XCTAssertEqual(try repository.bookmarkStore(for: one.id, key: repository.profileKey(for: one.id)).all().map(\.title), ["Example"])

        // Another profile's key opens nothing of this one.
        let wrong = SingleProfileFiles(root: root, profileID: one.id, key: try repository.profileKey(for: two.id))
        XCTAssertThrowsError(try wrong.loadConfiguration())
        XCTAssertThrowsError(try wrong.bookmarkStore())
    }

    func testDeviceSettingsWithoutTheSettingDecode() throws {
        // Written before the setting existed: decodes, with the setting off.
        let old = try JSONCoding.encoder.encode(DeviceSettings())
        let object = try JSONSerialization.jsonObject(with: old) as? [String: Any] ?? [:]
        XCTAssertNil(object["processPerProfile"])
        XCTAssertNil(try JSONCoding.decoder.decode(DeviceSettings.self, from: old).processPerProfile)
        let on = try JSONCoding.decoder.decode(DeviceSettings.self, from: JSONCoding.encoder.encode(DeviceSettings(processPerProfile: true)))
        XCTAssertEqual(on.processPerProfile, true)
    }
}
