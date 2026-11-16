import XCTest
@testable import BrowserCore

/// Tags changed for several profiles at once (the Profiles list's selection): added after each
/// profile's own, removed whatever their case, held to a profile's limit — and saved as an edit,
/// never over settings that do not read.
final class ProfileTaggingTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-tagging-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The change itself

    func testTagsAreAddedAfterAProfilesOwnAndRemovedWhateverTheirCase() {
        let added = ProfileTags.changing(["ads", "US"], adding: ["warm-up", "ADS", " Q4  campaign "], removing: [])
        XCTAssertEqual(added.tags, ["ads", "US", "warm-up", "Q4 campaign"], "a tag the profile has, in any case, is not added twice")
        XCTAssertEqual(added.notAdded, [])

        let removed = ProfileTags.changing(["ads", "US", "warm-up"], adding: [], removing: ["us", "none such"])
        XCTAssertEqual(removed.tags, ["ads", "warm-up"])

        let both = ProfileTags.changing(["old", "keep"], adding: ["new"], removing: ["OLD"])
        XCTAssertEqual(both.tags, ["keep", "new"])

        // In both lists: what the profile had goes, and the tag is added as it is written now.
        let renamedCase = ProfileTags.changing(["us", "x"], adding: ["US"], removing: ["us"])
        XCTAssertEqual(renamedCase.tags, ["x", "US"])

        let nothing = ProfileTags.changing(["a", "b"], adding: ["A"], removing: ["c"])
        XCTAssertEqual(nothing.tags, ["a", "b"], "nothing to do leaves the tags as they were, in their order")
    }

    func testAProfileHoldsNoMoreThanItsLimitAndWhatDidNotFitIsSaid() {
        let full = (0..<ProfileTags.maximumCount).map { "t\($0)" }
        let over = ProfileTags.changing(full, adding: ["extra", "t3"], removing: [])
        XCTAssertEqual(over.tags, full)
        XCTAssertEqual(over.notAdded, ["extra"], "the tag it already has is not counted as left out")

        // Removing one makes room for one.
        let swapped = ProfileTags.changing(full, adding: ["first", "second"], removing: ["T0"])
        XCTAssertEqual(swapped.tags, Array(full.dropFirst()) + ["first"])
        XCTAssertEqual(swapped.notAdded, ["second"])
        XCTAssertEqual(swapped.tags.count, ProfileTags.maximumCount)
    }

    // MARK: Several profiles

    func testTheTagsOfSeveralProfilesAreChangedAsAnEditOfEach() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let proxy = ProxySettings(kind: .socks5, host: "gw.example", port: 9000, username: "u", password: "p")
        let a = try repository.create(name: "A", configuration: ProfileConfiguration(proxy: proxy, tags: ["ads", "US"], notes: "kept"))
        let b = try repository.create(name: "B", configuration: ProfileConfiguration(tags: ["client"]))
        let c = try repository.create(name: "C", configuration: ProfileConfiguration(tags: ["Client", "team"]))
        let time = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = repository.changeTags(of: [a.id, b.id, c.id], adding: ["client", "Q4"], removing: ["us"], at: time)
        XCTAssertEqual(outcome.changed, [a.id, b.id, c.id])
        XCTAssertEqual(outcome.failed, [:])
        XCTAssertEqual(outcome.full, [])
        XCTAssertEqual(try repository.loadConfiguration(a.id).tags, ["ads", "client", "Q4"])
        XCTAssertEqual(try repository.loadConfiguration(b.id).tags, ["client", "Q4"])
        XCTAssertEqual(try repository.loadConfiguration(c.id).tags, ["Client", "team", "Q4"], "its own spelling of a tag it has is kept")

        // An edit of the tags alone: the rest of the settings as they were, a new revision, and the
        // time sync compares settings by.
        let saved = try repository.loadConfiguration(a.id)
        XCTAssertEqual(saved.proxy, proxy)
        XCTAssertEqual(saved.notes, "kept")
        XCTAssertEqual(saved.settingsModifiedAt, time)
        XCTAssertEqual(try repository.summary(for: a.id).revision, 2)

        // The same change again: every profile already stands as asked, and none is written.
        let again = repository.changeTags(of: [a.id, b.id, c.id], adding: ["client", "Q4"], removing: ["us"],
                                          at: time.addingTimeInterval(60))
        XCTAssertEqual(again.changed, [])
        XCTAssertEqual(again.unchanged, [a.id, b.id, c.id])
        XCTAssertEqual(try repository.summary(for: a.id).revision, 2, "nothing to change is no new revision")
        XCTAssertEqual(try repository.loadConfiguration(a.id).settingsModifiedAt, time)
    }

    func testAProfileWhoseSettingsDoNotReadIsLeftAsItIsAndTheOthersAreStillChanged() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let good = try repository.create(name: "Good", configuration: ProfileConfiguration())
        let broken = try repository.create(name: "Broken", configuration: ProfileConfiguration(tags: ["mine"]))
        let alsoGood = try repository.create(name: "Also good", configuration: ProfileConfiguration())
        // One bit of the AEAD tag flipped: the file no longer opens.
        let url = repository.configURL(for: broken.id)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: url)

        let outcome = repository.changeTags(of: [good.id, broken.id, alsoGood.id], adding: ["batch"], removing: [])
        XCTAssertEqual(outcome.changed, [good.id, alsoGood.id])
        XCTAssertEqual(Array(outcome.failed.keys), [broken.id])
        XCTAssertEqual(try Data(contentsOf: url), bytes, "settings that do not read are never written over (R1)")
        XCTAssertEqual(try repository.loadConfiguration(alsoGood.id).tags, ["batch"])
    }

    func testAFullProfileIsSaidAndGetsWhatThereIsRoomFor() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let almost = (1..<ProfileTags.maximumCount).map { "t\($0)" }
        let profile = try repository.create(name: "Many", configuration: ProfileConfiguration(tags: almost))
        let outcome = repository.changeTags(of: [profile.id], adding: ["one", "two"], removing: [])
        XCTAssertEqual(outcome.changed, [profile.id])
        XCTAssertEqual(outcome.full, [profile.id])
        XCTAssertEqual(try repository.loadConfiguration(profile.id).tags, almost + ["one"])
    }
}
