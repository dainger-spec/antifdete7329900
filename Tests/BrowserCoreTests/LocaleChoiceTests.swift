import XCTest
@testable import BrowserCore

/// A profile's time zone and language: from the connection, chosen, or a place picked at random —
/// a time zone and a language that belong together.
final class LocaleChoiceTests: XCTestCase {
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testTheSourceIsSaidByTheFieldsUnlessRandom() {
        XCTAssertEqual(ProfileConfiguration().effectiveLocaleSource, .connection)
        XCTAssertEqual(ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo").effectiveLocaleSource, .manual)
        XCTAssertEqual(ProfileConfiguration(languageOverride: "fr-FR").effectiveLocaleSource, .manual)
        XCTAssertEqual(ProfileConfiguration(timeZoneIdentifier: "Europe/Paris", languageOverride: "fr-FR",
                                            localeSource: .random).effectiveLocaleSource, .random)
    }

    func testTheLanguageSetWinsOverTheProxyCountrys() {
        let germany = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE", proxyEndpoint: "socks5://203.0.113.5:1080")
        XCTAssertEqual(ProfileConfiguration().webLanguage(for: germany), "de-DE")
        XCTAssertNil(ProfileConfiguration().webLanguage(for: nil), "no proxy country, none set: this Mac's")
        XCTAssertEqual(ProfileConfiguration(languageOverride: "ja-JP").webLanguage(for: germany), "ja-JP")
    }

    func testARandomPlaceIsAPairThatBelongsTogetherAndAnotherOneEachTime() {
        var generator = Seeded(state: 7)
        var previous: LocalePlaces.Place?
        for _ in 0..<200 {
            let place = LocalePlaces.random(using: &generator, otherThan: previous)
            XCTAssertNotEqual(place, previous)
            XCTAssertNotNil(TimeZone(identifier: place.timeZone), place.timeZone)
            XCTAssertTrue(LocalePlaces.isLanguageTag(place.language), place.language)
            XCTAssertEqual(LocalePlaces.place(timeZone: place.timeZone, language: place.language), place)
            previous = place
        }
        XCTAssertTrue(LocalePlaces.all.allSatisfy { LocalePlaces.languages.contains($0.language) })
    }

    func testLanguageTags() {
        for tag in ["de", "de-DE", "zh-Hant-TW", "es-419", "nb-NO"] { XCTAssertTrue(LocalePlaces.isLanguageTag(tag), tag) }
        for tag in ["", "d", "de_DE", "de-", "deutsch-DE", "de-DE;q=0.9", "ру-RU"] { XCTAssertFalse(LocalePlaces.isLanguageTag(tag), tag) }
    }

    func testKeptAndWrittenAsBeforeWithoutThem() throws {
        let plain = String(decoding: try JSONCoding.encoder.encode(ProfileConfiguration()), as: UTF8.self)
        XCTAssertFalse(plain.contains("languageOverride") || plain.contains("localeSource"), plain)
        let random = ProfileConfiguration(timeZoneIdentifier: "Asia/Seoul", languageOverride: "ko-KR", localeSource: .random)
        let read = try ProfileRepository.decodeConfiguration(try JSONCoding.encoder.encode(random))
        XCTAssertEqual(read.languageOverride, "ko-KR")
        XCTAssertEqual(read.effectiveLocaleSource, .random)
        let odd = try ProfileRepository.decodeConfiguration(Data(#"{"languageOverride":"de_DE;q=1","localeSource":"astrology"}"#.utf8))
        XCTAssertNil(odd.languageOverride)
        XCTAssertEqual(odd.effectiveLocaleSource, .connection)
        XCTAssertThrowsError(try ProfileConfiguration(languageOverride: "German").validate())
    }
}
