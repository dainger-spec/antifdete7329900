import XCTest
@testable import BrowserCore

/// The scenarios of the app's editor (docs/AUTOMATION.md): `scenarios.bin` at the vault's root,
/// sealed under the vault's own key, never written over a copy that does not open or a newer one.
final class ScenarioLibraryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-scenarios-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeptUnderTheVaultsOwnKeyAndReadBack() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertEqual(try ScenarioLibrary.load(from: vault), ScenarioLibrary(), "none before the first")
        var library = ScenarioLibrary()
        library.put(Scenario(name: "Sign in to the shop", source: "await page.goto('https://shop.example/');", createdAt: t0), at: t0)
        try library.save(to: vault)
        XCTAssertEqual(try ScenarioLibrary.load(from: vault), library)
        let raw = try Data(contentsOf: root.appendingPathComponent("scenarios.bin"))
        XCTAssertNil(raw.range(of: Data("shop.example".utf8)), "the scenario's text is in the clear")
        XCTAssertNil(raw.range(of: Data("Sign in".utf8)), "the scenario's name is in the clear")
    }

    func testPutReplacesByIDAndMovesItsTimeRemoveTakesItAway() {
        var library = ScenarioLibrary()
        let first = Scenario(name: "b", source: "1", createdAt: t0)
        library.put(first, at: t0)
        library.put(Scenario(name: "A", source: "2", createdAt: t0), at: t0)
        var edited = first
        edited.source = "3"
        library.put(edited, at: t0.addingTimeInterval(60))
        XCTAssertEqual(library.scenarios.count, 2)
        XCTAssertEqual(library.scenario(first.id)?.source, "3")
        XCTAssertEqual(library.scenario(first.id)?.updatedAt, t0.addingTimeInterval(60))
        XCTAssertEqual(library.sorted.map(\.name), ["A", "b"], "by name, case aside")
        library.remove(first.id)
        XCTAssertEqual(library.scenarios.map(\.name), ["A"])
    }

    func testAFreeNameCountsOnWhateverTheCase() {
        var library = ScenarioLibrary()
        XCTAssertEqual(library.freeName("Scenario"), "Scenario")
        library.put(Scenario(name: "scenario", source: ""))
        library.put(Scenario(name: "Scenario 2", source: ""))
        XCTAssertEqual(library.freeName("Scenario"), "Scenario 3")
    }

    func testACopyThatDoesNotOpenIsMovedAsideNeverWrittenOver() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        var library = ScenarioLibrary()
        library.put(Scenario(name: "one", source: "x", createdAt: t0), at: t0)
        try library.save(to: vault)
        let file = root.appendingPathComponent("scenarios.bin")
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: file)
        XCTAssertThrowsError(try ScenarioLibrary.load(from: vault))

        var next = ScenarioLibrary()
        next.put(Scenario(name: "two", source: "y", createdAt: t0), at: t0)
        try next.save(to: vault)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("scenarios.bin.unreadable")), damaged,
                       "the copy that did not open was not kept as it was")
        XCTAssertEqual(try ScenarioLibrary.load(from: vault), next)
    }

    func testANewerVersionsCopyIsRefusedAndNotWrittenOver() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        let file = root.appendingPathComponent("scenarios.bin")
        let newer = try AEAD.seal(Data(#"{"scenarios":[],"format":2}"#.utf8), key: vault.scenariosKey,
                                  aad: "scenarios:v1:\(vault.vaultID.uuidString)")
        try SecureFile.write(newer, to: file)
        XCTAssertThrowsError(try ScenarioLibrary.load(from: vault)) { error in
            guard case CoreError.newerFormat = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ScenarioLibrary().save(to: vault))
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }
}
