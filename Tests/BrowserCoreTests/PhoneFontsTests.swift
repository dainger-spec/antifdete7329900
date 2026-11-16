import XCTest
@testable import BrowserCore

/// An iPhone view's pages find an iPhone's fonts only (`PhoneFonts`); a Mac profile and an iPad
/// view keep this Mac's.
final class PhoneFontsTests: XCTestCase {
    func testOnlyAnIPhoneViewHasAFontList() {
        for id in ["ios-27", "ios-26"] {
            for disguise in PhoneDisguise.allCases {
                let configuration = ProfileConfiguration(deviceGenerationID: id, phoneDisguise: disguise)
                XCTAssertEqual(PhoneFonts.allowedFamilies(for: configuration), PhoneFonts.iOSFamilies, "\(id) \(disguise)")
            }
        }
        XCTAssertNil(PhoneFonts.allowedFamilies(for: ProfileConfiguration()), "a new profile is a Mac's")
        XCTAssertNil(PhoneFonts.allowedFamilies(for: ProfileConfiguration(deviceGenerationID: DeviceGenerations.defaultID)))
        XCTAssertNil(PhoneFonts.allowedFamilies(for: ProfileConfiguration(deviceGenerationID: "ipados-26")),
                     "an iPad view sends the Mac's User-Agent and keeps the Mac's fonts")
    }

    /// Every family a real iPhone 17 Pro (iOS 27.0) showed pixelscan.net (the owner, 16 November),
    /// but "System Font", pixelscan's name for the interface font WebKit resolves apart from the list.
    func testTheOwnersIPhoneReadingIsOnTheList() {
        let reading = ["Arial", "Arial Hebrew", "Arial Rounded MT Bold", "Courier", "Courier New", "Georgia", "Helvetica",
                       "Helvetica Neue", "Impact", "Palatino", "Times", "Times New Roman", "Trebuchet MS", "Verdana",
                       "Chalkduster", "PingFang SC", "PingFang TC", "PingFang HK", "Optima", "Zapfino",
                       "Hiragino Mincho ProN", "Noteworthy", "Didot", "Hiragino Sans", "Avenir", "Hoefler Text", "Papyrus",
                       "Kohinoor Bangla", "Sinhala Sangam MN", "Symbol", "Hiragino Kaku Gothic StdN", "Khmer Sangam MN",
                       "Noto Nastaliq Urdu", "Avenir Next", "SignPainter", "Snell Roundhand", "Futura", "Kohinoor Devanagari",
                       "Marker Felt", "Apple SD Gothic Neo", "Bodoni Ornaments", "Kohinoor Telugu", "American Typewriter",
                       "Lao Sangam MN", "DIN Alternate", "Chalkboard SE", "Damascus", "Thonburi", "Malayalam Sangam MN",
                       "Bodoni 72 Smallcaps", "Sukhumvit Set", "Hiragino Maru Gothic ProN", "Myanmar Sangam MN",
                       "Telugu Sangam MN", "Bodoni 72", "Kailasa", "Tamil Sangam MN", "Gill Sans", "Apple Symbols",
                       "Copperplate", "Bradley Hand", "Geeza Pro", "Savoye LET", "DIN Condensed", "Mishafi", "Menlo",
                       "Apple Color Emoji", "Rockwell", "Euphemia UCAS", "Cochin", "Charter", "Al Nile", "Farah",
                       "Microsoft JhengHei"]
        let list = Set(PhoneFonts.iOSFamilies)
        XCTAssertEqual(reading.filter { !list.contains($0) }, [])
    }

    /// Fonts every Mac has and no iPhone (Apple's iOS font list), which fingerprinting pages try.
    func testMacOnlyFontsAreNotOnTheList() {
        let lowered = Set(PhoneFonts.engineList(PhoneFonts.iOSFamilies).map { $0.lowercased() })
        for macOnly in ["Monaco", "Apple Chancery", "Andale Mono", "Lucida Grande", "Comic Sans MS", "Arial Black",
                        "Arial Narrow", "Tahoma", "Brush Script MT", "Herculanum", "Luminari", "Skia", "Geneva",
                        "Big Caslon", "Chalkboard", "Trattatello", "Webdings", "Wingdings", "Microsoft Sans Serif",
                        "Silom", "Krungthep", "PT Sans", "Phosphate", "Ayuthaya", "Marion", "Apple Braille"] {
            XCTAssertFalse(lowered.contains(macOnly.lowercased()), macOnly)
        }
        // Not a name of the interface font either: WebKit resolves it apart from the list.
        XCTAssertFalse(lowered.contains("-apple-system"))
        XCTAssertFalse(lowered.contains("system-ui"))
    }

    func testTheEnginesListHasEachNameOnceAsWrittenAndInLowerCase() {
        let list = PhoneFonts.engineList(["Arial", "PingFang SC", "arial"])
        XCTAssertEqual(list, ["Arial", "PingFang SC", "arial", "pingfang sc"])
        let full = PhoneFonts.engineList(PhoneFonts.iOSFamilies)
        XCTAssertEqual(full.count, Set(full).count)
        XCTAssertEqual(Set(PhoneFonts.iOSFamilies).count, PhoneFonts.iOSFamilies.count, "no family twice")
        XCTAssertTrue(PhoneFonts.iOSFamilies.contains(PhoneFonts.iOSCursiveFamily))
        XCTAssertTrue(PhoneFonts.iOSFamilies.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces) })
    }
}
