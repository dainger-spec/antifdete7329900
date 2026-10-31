import XCTest
@testable import BrowserCore

/// A `settings.bin` that cannot be read is moved aside, never written over (the audit's finding:
/// the defaults shown in its place were saved over it at the first change — the sync target, the
/// server's token and the automation token gone). AppModel moves it at the first change.
final class DeviceSettingsUnreadableTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-settings-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnUnreadableSettingsFileIsKeptAsideAndNeverWrittenOver() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        try DeviceSettings(automation: AutomationSettings()).save(to: vault)
        let file = root.appendingPathComponent("settings.bin")
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: file)
        XCTAssertThrowsError(try DeviceSettings.load(from: vault))

        let aside = try XCTUnwrap(DeviceSettings.moveUnreadableAside(in: vault))
        XCTAssertEqual(aside.lastPathComponent, "settings.bin.unreadable")
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        try DeviceSettings().save(to: vault)
        XCTAssertEqual(try DeviceSettings.load(from: vault), DeviceSettings())
        XCTAssertEqual(try Data(contentsOf: aside), damaged, "the file kept aside was written over")

        // Once more: the first one kept is not replaced.
        try damaged.write(to: file)
        let second = try XCTUnwrap(DeviceSettings.moveUnreadableAside(in: vault))
        XCTAssertEqual(second.lastPathComponent, "settings.bin.unreadable-2")
        XCTAssertEqual(try Data(contentsOf: aside), damaged)
        XCTAssertNil(try DeviceSettings.moveUnreadableAside(in: vault), "no file, nothing moved")
    }
}
