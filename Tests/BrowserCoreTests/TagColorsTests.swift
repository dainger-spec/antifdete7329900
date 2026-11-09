import XCTest
@testable import BrowserCore

/// The tags' colours (the owner, 1 November: coloured tags, yes — they group by meaning, a profile's
/// glyph tells apart within a group): one choice per tag for the whole vault, in `labels.bin`, not
/// in any profile's settings; synced as an object of its own, merged tag by tag.
final class TagColorsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-labels-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t1: Date { t0.addingTimeInterval(60) }
    private var t2: Date { t0.addingTimeInterval(120) }

    // MARK: Choices

    func testAColourIsTheTagsWhateverItsCase() {
        var colours = TagColors()
        colours.set(3, for: "Ads", at: t0)
        XCTAssertEqual(colours.color(of: "ads"), 3)
        XCTAssertEqual(colours.color(of: "ADS "), 3)
        colours.set(5, for: "aDs", at: t1)
        XCTAssertEqual(colours.choices.count, 1, "one choice per tag, whatever its case")
        XCTAssertEqual(colours.color(of: "Ads"), 5)
        XCTAssertNil(colours.color(of: "DE"))
    }

    func testAColourOutsideThePaletteIsNoneAndTakingAwayNothingLeavesNothing() {
        var colours = TagColors()
        colours.set(ProfileAvatarStyle.colorCount, for: "ads", at: t0)
        colours.set(-1, for: "DE", at: t0)
        colours.set(nil, for: "US", at: t0)
        XCTAssertTrue(colours.choices.isEmpty, "\(colours.choices)")
        colours.set(2, for: "ads", at: t0)
        colours.set(nil, for: "ads", at: t1)
        XCTAssertNil(colours.color(of: "ads"))
        XCTAssertEqual(colours.choices["ads"], .init(color: nil, chosenAt: t1), "a colour taken away is a choice too")
    }

    // MARK: Merge

    func testTheLaterChoiceWinsTagByTagTakingAwayIncluded() {
        var a = TagColors(), b = TagColors()
        a.set(1, for: "ads", at: t0)
        b.set(2, for: "ads", at: t1)
        a.set(4, for: "DE", at: t1)
        b.set(6, for: "DE", at: t0)
        b.set(7, for: "US", at: t0)
        a.set(3, for: "warm-up", at: t0)
        b.set(3, for: "warm-up", at: t0)
        b.set(nil, for: "warm-up", at: t2)
        let merged = TagColors.merge(a, b)
        XCTAssertEqual(merged.color(of: "ads"), 2)
        XCTAssertEqual(merged.color(of: "DE"), 4)
        XCTAssertEqual(merged.color(of: "US"), 7)
        XCTAssertNil(merged.color(of: "warm-up"), "taken away later, it stays away")
    }

    func testTheSameMomentEndsTheSameWhicheverDeviceMerges() {
        var a = TagColors(), b = TagColors(), c = TagColors()
        a.set(5, for: "ads", at: t0)
        b.set(2, for: "ads", at: t0)
        c.set(4, for: "ads", at: t0)
        c.set(nil, for: "ads", at: t0)
        XCTAssertEqual(TagColors.merge(a, b).color(of: "ads"), 2)
        XCTAssertEqual(TagColors.merge(b, a).color(of: "ads"), 2)
        XCTAssertEqual(TagColors.merge(a, c).color(of: "ads"), 5, "a colour over none, at the same moment")
        XCTAssertEqual(TagColors.merge(c, a).color(of: "ads"), 5)
    }

    func testMergeIsCommutativeAssociativeAndIdempotent() {
        var generator = SplitMix(seed: 0x5EED)
        let tags = ["ads", "DE", "us", "Warm-up", "Q4"]
        func random() -> TagColors {
            var colours = TagColors()
            for _ in 0..<6 {
                let tag = tags[Int(generator.next() % UInt64(tags.count))]
                let pick = Int(generator.next() % UInt64(ProfileAvatarStyle.colorCount + 1))
                let at = t0.addingTimeInterval(TimeInterval(generator.next() % 4) * 60)
                colours.set(pick == ProfileAvatarStyle.colorCount ? nil : pick, for: tag, at: at)
            }
            return colours
        }
        for _ in 0..<200 {
            let a = random(), b = random(), c = random()
            XCTAssertEqual(TagColors.merge(a, b), TagColors.merge(b, a))
            XCTAssertEqual(TagColors.merge(TagColors.merge(a, b), c), TagColors.merge(a, TagColors.merge(b, c)))
            XCTAssertEqual(TagColors.merge(a, a), TagColors.merge(a, TagColors()))
        }
    }

    // MARK: On disk

    func testKeptUnderTheVaultsOwnKeyAndReadBack() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertEqual(try TagColors.load(from: vault), TagColors(), "none before the first choice")
        var colours = TagColors()
        colours.set(3, for: "ads", at: t0)
        try colours.save(to: vault)
        XCTAssertEqual(try TagColors.load(from: vault), colours)
        let raw = try Data(contentsOf: root.appendingPathComponent("labels.bin"))
        XCTAssertNil(raw.range(of: Data("ads".utf8)), "the tag's name is in the clear")
    }

    func testACopyThatDoesNotOpenIsMovedAsideNeverWrittenOver() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        var colours = TagColors()
        colours.set(3, for: "ads", at: t0)
        try colours.save(to: vault)
        let file = root.appendingPathComponent("labels.bin")
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: file)
        XCTAssertThrowsError(try TagColors.load(from: vault))

        var next = TagColors()
        next.set(1, for: "DE", at: t1)
        try next.save(to: vault)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("labels.bin.unreadable")), damaged,
                       "the copy that did not open was not kept as it was")
        XCTAssertEqual(try TagColors.load(from: vault), next)
    }

    func testANewerVersionsCopyIsRefusedAndNotWrittenOver() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        let file = root.appendingPathComponent("labels.bin")
        let newer = try AEAD.seal(Data(#"{"choices":{},"format":2}"#.utf8), key: vault.labelsKey,
                                  aad: "profile-labels:v1:\(vault.vaultID.uuidString)")
        try SecureFile.write(newer, to: file)
        XCTAssertThrowsError(try TagColors.load(from: vault)) { error in
            guard case CoreError.newerFormat = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try TagColors().save(to: vault))
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    // MARK: Sync

    private var server: LocalDirectorySyncTransport { LocalDirectorySyncTransport(directory: root.appendingPathComponent("server")) }

    private func device(_ name: String) throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: MasterVault.create(in: root.appendingPathComponent(name), password: "pw", iterations: 1_000))
    }

    private func joining(_ name: String) async throws -> ProfileRepository {
        try ProfileRepository.openedAtUnlock(vault: await SyncEngine.bootstrap(transport: server, root: root.appendingPathComponent(name),
                                                                              password: "pw"))
    }

    private func sync(_ repository: ProfileRepository) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: server).sync()
    }

    private func set(_ color: Int?, _ tag: String, at date: Date, on repository: ProfileRepository) throws {
        var colours = try TagColors.load(from: repository.vault)
        colours.set(color, for: tag, at: date)
        try colours.save(to: repository.vault)
    }

    func testColoursGoToAnotherDeviceAndTheLaterChoiceWins() async throws {
        let a = try device("A")
        try set(3, "ads", at: t0, on: a)
        let first = try await sync(a)
        XCTAssertTrue(first.pushed.contains("labels"), "\(first)")
        let b = try await joining("B")
        _ = try await sync(b)
        XCTAssertEqual(try TagColors.load(from: b.vault).color(of: "ads"), 3)

        // Both change it, B later: both end with B's, whichever syncs first.
        try set(5, "ads", at: t2, on: b)
        try set(1, "ads", at: t1, on: a)
        try set(6, "DE", at: t1, on: a)
        _ = try await sync(a)
        _ = try await sync(b)
        _ = try await sync(a)
        for repository in [a, b] {
            let colours = try TagColors.load(from: repository.vault)
            XCTAssertEqual(colours.color(of: "ads"), 5)
            XCTAssertEqual(colours.color(of: "DE"), 6)
        }
        let quiet = try await sync(a)
        XCTAssertFalse(quiet.pushed.contains("labels") || quiet.pulled.contains("labels"), "nothing changed, nothing moved: \(quiet)")
    }

    func testAColourTakenAwayStaysAwayOnTheOtherDevice() async throws {
        let a = try device("A")
        try set(3, "ads", at: t0, on: a)
        _ = try await sync(a)
        let b = try await joining("B")
        _ = try await sync(b)
        try set(nil, "ads", at: t1, on: a)
        _ = try await sync(a)
        _ = try await sync(b)
        XCTAssertNil(try TagColors.load(from: b.vault).color(of: "ads"))
    }

    func testACopyHereThatDoesNotOpenIsNeverPushedAndTheServersIsTakenIn() async throws {
        let a = try device("A")
        try set(3, "ads", at: t0, on: a)
        _ = try await sync(a)
        let b = try await joining("B")
        _ = try await sync(b)
        let file = root.appendingPathComponent("B/labels.bin")
        var damaged = try Data(contentsOf: file)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: file)

        let report = try await sync(b)
        XCTAssertFalse(report.pushed.contains("labels"), "a copy that does not open was pushed: \(report)")
        XCTAssertEqual(try TagColors.load(from: b.vault).color(of: "ads"), 3, "the server's was not taken in")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("B/labels.bin.unreadable")), damaged)
        _ = try await sync(a)
        XCTAssertEqual(try TagColors.load(from: a.vault).color(of: "ads"), 3)
    }

    func testNoColourAnywhereNothingIsPushed() async throws {
        let a = try device("A")
        let report = try await sync(a)
        XCTAssertFalse(report.pushed.contains("labels"), "\(report)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/labels.bin").path))
    }
}

/// A small seeded generator, so that the merge's properties are checked on the same cases every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
