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

    /// A script's wait as the clock takes it: Infinity, NaN or a number past what the system's sleep
    /// holds stopped the profile's process (audit 3).
    func testAScriptsWaitIsOneTheClockCanTake() {
        XCTAssertEqual(ScenarioWait.nanoseconds(milliseconds: 1500), 1_500_000_000)
        XCTAssertEqual(ScenarioWait.nanoseconds(milliseconds: 0), 0)
        XCTAssertEqual(ScenarioWait.nanoseconds(milliseconds: -5), 0)
        XCTAssertEqual(ScenarioWait.nanoseconds(milliseconds: -.infinity), 0)
        XCTAssertEqual(ScenarioWait.nanoseconds(milliseconds: .nan), 0)
        XCTAssertEqual(ScenarioWait.nanoseconds(milliseconds: 3_600_000), 3_600_000_000_000, "an hour, as asked")
        // Until Stop: for ever, and anything longer than a year (1e14 ms is past the sleep's range).
        for forEver in [Double.infinity, 1e14, 1e300, Double.greatestFiniteMagnitude, ScenarioWait.longest * 1000 + 1] {
            XCTAssertNil(ScenarioWait.nanoseconds(milliseconds: forEver), "\(forEver)")
        }
        XCTAssertNotNil(ScenarioWait.nanoseconds(milliseconds: ScenarioWait.longest * 1000))

        XCTAssertEqual(ScenarioWait.keyDelay(milliseconds: nil), 0.06...0.18)
        XCTAssertEqual(ScenarioWait.keyDelay(milliseconds: .nan), 0.06...0.18)
        XCTAssertEqual(ScenarioWait.keyDelay(milliseconds: 500), 0.3...0.7, "give or take 40 %")
        XCTAssertEqual(ScenarioWait.keyDelay(milliseconds: -100), 0...0.01)
        for huge in [Double.infinity, 1e300] {
            let range = ScenarioWait.keyDelay(milliseconds: huge)
            XCTAssertTrue(range.lowerBound.isFinite && range.upperBound.isFinite, "\(huge)")
            XCTAssertEqual(range.upperBound, ScenarioWait.longest * 1.4)
            // What the driver then does with it: a random pause in the range, in nanoseconds.
            XCTAssertLessThan(range.upperBound * 1_000_000_000, Double(UInt64.max))
        }
    }

    /// What `page.waitForURL` waits for: an address written out, with `*` and `**`, or a regular
    /// expression.
    func testAnAddressToWaitFor() throws {
        func glob(_ text: String) throws -> ScenarioURLPattern { try XCTUnwrap(ScenarioURLPattern(text)) }
        // Written out: that address, with or without the slash at its end, and no other.
        XCTAssertTrue(try glob("https://shop.example/account").matches("https://shop.example/account"))
        XCTAssertTrue(try glob("https://shop.example").matches("https://shop.example/"))
        XCTAssertTrue(try glob("https://shop.example/account/").matches("https://shop.example/account"))
        XCTAssertFalse(try glob("https://shop.example/account").matches("https://shop.example/account/orders"))
        XCTAssertFalse(try glob("https://shop.example/account").matches("https://shop.example/account?next=1"))
        XCTAssertFalse(try glob("https://shop.example/a.c").matches("https://shop.example/abc"), "a dot is a dot")
        XCTAssertTrue(try glob("https://shop.example/find?q=a+b").matches("https://shop.example/find?q=a+b"), "? and + are themselves")
        // ** is any run; * a run within one part of the path.
        XCTAssertTrue(try glob("**/account").matches("https://shop.example/en/account"))
        XCTAssertTrue(try glob("**/account**").matches("https://shop.example/account?tab=orders#top"))
        XCTAssertFalse(try glob("**/account").matches("https://shop.example/account/orders"))
        XCTAssertTrue(try glob("https://shop.example/orders/*").matches("https://shop.example/orders/1042"))
        XCTAssertFalse(try glob("https://shop.example/orders/*").matches("https://shop.example/orders/1042/items"))
        XCTAssertTrue(try glob("https://*.example/**").matches("https://shop.example/any/where"))
        XCTAssertEqual(try glob("**/account").shown, "**/account")
        // A regular expression of the script's own is looked for in the address.
        let orders = try XCTUnwrap(ScenarioURLPattern(["regex": #"/orders/\d+$"#, "flags": ""] as [String: Any]))
        XCTAssertTrue(orders.matches("https://shop.example/orders/1042"))
        XCTAssertFalse(orders.matches("https://shop.example/orders/new"))
        XCTAssertEqual(orders.shown, #"//orders/\d+$/"#)
        let anyCase = try XCTUnwrap(ScenarioURLPattern(["regex": "ACCOUNT", "flags": "gi"] as [String: Any]))
        XCTAssertTrue(anyCase.matches("https://shop.example/account"))
        XCTAssertFalse(try XCTUnwrap(ScenarioURLPattern(["regex": "ACCOUNT"] as [String: Any])).matches("https://shop.example/account"))
        // What cannot be read matches nothing, and says so before it is waited for.
        let broken = try XCTUnwrap(ScenarioURLPattern(["regex": "(unclosed"] as [String: Any]))
        XCTAssertFalse(broken.isReadable)
        XCTAssertFalse(broken.matches("(unclosed"))
        XCTAssertTrue(orders.isReadable)
        // Nothing to wait for is no pattern.
        XCTAssertNil(ScenarioURLPattern(""))
        XCTAssertNil(ScenarioURLPattern(nil))
        XCTAssertNil(ScenarioURLPattern(42))
        XCTAssertNil(ScenarioURLPattern(["flags": "i"] as [String: Any]))
    }
}
