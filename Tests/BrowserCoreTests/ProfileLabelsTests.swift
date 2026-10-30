import XCTest
@testable import BrowserCore

/// A profile's tags, notes and glyph: the person's own words, held to limits, kept with the
/// profile's settings, and written as before when there are none.
final class ProfileLabelsTests: XCTestCase {
    func testTagsAreTrimmedCutAndKeptOnceWhateverTheCase() {
        XCTAssertEqual(ProfileTags.normalized(["  work ", "Work", "", "   ", "shop\n  US", "WORK"]), ["work", "shop US"])
        let long = String(repeating: "x", count: ProfileTags.maximumLength + 10)
        XCTAssertEqual(ProfileTags.normalized([long]).first?.count, ProfileTags.maximumLength)
        let many = (0..<(ProfileTags.maximumCount + 5)).map { "t\($0)" }
        XCTAssertEqual(ProfileTags.normalized(many), Array(many.prefix(ProfileTags.maximumCount)))
        XCTAssertEqual(ProfileTags.parse("ads, US ,\nads,  , warm"), ["ads", "US", "warm"])
        XCTAssertTrue(ProfileTags.contains(["Ads"], "ADS"))
        XCTAssertFalse(ProfileTags.contains(["Ads"], "Ad"))
    }

    func testTheGlyphKeepsOnlyWhatTheAppCanShow() {
        XCTAssertNil(ProfileAvatarStyle().normalized, "nothing chosen: the default look")
        XCTAssertNil(ProfileAvatarStyle(color: ProfileAvatarStyle.colorCount, letters: "  ").normalized)
        XCTAssertEqual(ProfileAvatarStyle(color: -1, letters: "N W X").normalized, ProfileAvatarStyle(letters: "NW"))
        XCTAssertEqual(ProfileAvatarStyle(color: 3).normalized, ProfileAvatarStyle(color: 3))
    }

    func testKeptWithTheSettingsAndWrittenAsBeforeWithoutThem() throws {
        let plain = String(decoding: try JSONCoding.encoder.encode(ProfileConfiguration()), as: UTF8.self)
        for key in ["tags", "notes", "avatar"] {
            XCTAssertFalse(plain.contains("\"\(key)\""), "\(key) is not written when there is none: \(plain)")
        }
        let labelled = ProfileConfiguration(tags: ["ads", "US"], notes: "Bought 2026-10, renew monthly",
                                            avatar: ProfileAvatarStyle(color: 2, letters: "N"))
        let read = try ProfileRepository.decodeConfiguration(try JSONCoding.encoder.encode(labelled))
        XCTAssertEqual(read.tags, ["ads", "US"])
        XCTAssertEqual(read.notes, "Bought 2026-10, renew monthly")
        XCTAssertEqual(read.avatar, ProfileAvatarStyle(color: 2, letters: "N"))
        XCTAssertFalse(labelled.hasSameSettings(as: ProfileConfiguration()), "a tag is a setting: an edit, and synced")
    }

    func testWhatDoesNotReadIsDroppedAndTheRestKept() throws {
        let odd = #"{"historyEnabled":false,"tags":"not a list","notes":42,"avatar":{"color":"red"}}"#
        let read = try ProfileRepository.decodeConfiguration(Data(odd.utf8))
        XCTAssertEqual(read.tags, [])
        XCTAssertEqual(read.notes, "")
        XCTAssertNil(read.avatar)
        XCTAssertFalse(read.historyEnabled, "the rest of the settings are kept")

        let longNotes = String(repeating: "n", count: ProfileConfiguration.maximumNotesLength + 7)
        let stored = #"{"notes":"\#(longNotes)","tags":["a","A","b"]}"#
        let held = try ProfileRepository.decodeConfiguration(Data(stored.utf8))
        XCTAssertEqual(held.notes.count, ProfileConfiguration.maximumNotesLength)
        XCTAssertEqual(held.tags, ["a", "b"])
    }
}
