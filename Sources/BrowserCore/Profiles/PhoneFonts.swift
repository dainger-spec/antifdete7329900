import Foundation

/// The fonts an iPhone's Safari gives a page: what an iPhone view's pages may find by name, so that
/// a font this Mac has and an iPhone has not is not installed for them (`PhoneEngine.restrictFonts`
/// gives WebKit the list; nothing in the page is a script's).
///
/// WHERE THE LIST COMES FROM. The font families Apple lists as included with iOS (Apple's "Fonts
/// for Apple platforms" list, developer.apple.com/fonts/system-fonts, the iOS column, and its "iOS
/// font list" support pages, as of iOS 17 and 18 — written from that list, not read off an iOS 26
/// or 27 device), with the names CoreText answers a page by: a family name, as CSS `font-family`
/// asks for it. Checked against what a real iPhone 17 Pro
/// (iOS 27.0, Safari 27.0) showed pixelscan.net on 16 November 2026 (the owner's reading, about 85
/// of the names pixelscan tries): every name it found is here. Three names come from that reading
/// alone, where the iPhone answers a name Apple's list gives in another form: "Hiragino Kaku Gothic
/// StdN" (beside ProN), "Times" (beside Times New Roman) and "Microsoft JhengHei". A name here that
/// this Mac has not (Microsoft JhengHei, on most Macs) changes nothing: the list only takes fonts away.
///
/// What it does not touch: the system interface font (`-apple-system`, `system-ui`, the names that
/// begin with a dot), which WebKit resolves apart from the list; the fonts the system falls back to
/// for a character no named font has (a script's own letters, emoji); and web fonts a page loads.
/// An iPad view keeps this Mac's fonts: it sends the Mac's User-Agent, as an iPad's Safari does by
/// default, and a page takes it for a Mac.
public enum PhoneFonts {
    /// The iPhone's font families, as a page names them.
    public static let iOSFamilies: [String] = [
        "Academy Engraved LET", "Al Nile", "American Typewriter", "Apple Color Emoji", "Apple SD Gothic Neo",
        "Apple Symbols", "Arial", "Arial Hebrew", "Arial Rounded MT Bold", "Avenir", "Avenir Next",
        "Avenir Next Condensed", "Bangla Sangam MN", "Baskerville", "Bodoni 72", "Bodoni 72 Oldstyle",
        "Bodoni 72 Smallcaps", "Bodoni Ornaments", "Bradley Hand", "Chalkboard SE", "Chalkduster", "Charter",
        "Cochin", "Copperplate", "Courier", "Courier New", "Damascus", "Devanagari Sangam MN", "Didot",
        "DIN Alternate", "DIN Condensed", "Euphemia UCAS", "Farah", "Futura", "Galvji", "Geeza Pro", "Georgia",
        "Gill Sans", "Grantha Sangam MN", "Gujarati Sangam MN", "Gurmukhi MN", "Helvetica", "Helvetica Neue",
        "Hiragino Kaku Gothic ProN", "Hiragino Kaku Gothic StdN", "Hiragino Maru Gothic ProN",
        "Hiragino Mincho ProN", "Hiragino Sans", "Hoefler Text", "Impact", "Kailasa", "Kannada Sangam MN", "Kefa",
        "Khmer Sangam MN", "Kohinoor Bangla", "Kohinoor Devanagari", "Kohinoor Gujarati", "Kohinoor Telugu",
        "Lao Sangam MN", "Malayalam Sangam MN", "Marker Felt", "Menlo", "Microsoft JhengHei", "Mishafi",
        "Mukta Mahee", "Myanmar Sangam MN", "Noteworthy", "Noto Nastaliq Urdu", "Noto Sans Kannada",
        "Noto Sans Myanmar", "Noto Sans Oriya", "Optima", "Oriya Sangam MN", "Palatino", "Papyrus", "Party LET",
        "PingFang HK", "PingFang MO", "PingFang SC", "PingFang TC", "Rockwell", "Savoye LET", "SignPainter", "Sinhala Sangam MN",
        "Snell Roundhand", "STIX Two Math", "STIX Two Text", "Sukhumvit Set", "Symbol", "Tamil Sangam MN",
        "Telugu Sangam MN", "Thonburi", "Times", "Times New Roman", "Trebuchet MS", "Verdana", "Zapf Dingbats",
        "Zapfino",
    ]

    /// CSS `cursive` on an iPhone: WebKit's default there ("Snell Roundhand"); on a Mac it is Apple
    /// Chancery, which an iPhone has not. `fantasy` (Papyrus) and the other generic families are
    /// the same on both.
    public static let iOSCursiveFamily = "Snell Roundhand"

    /// The families a profile's pages may find by name; nil — every font of the system, as Safari on
    /// this Mac has them — for a Mac profile and an iPad view. Both of an iPhone view's disguises:
    /// the list is the engine's own, not a script's.
    public static func allowedFamilies(for configuration: ProfileConfiguration) -> [String]? {
        configuration.deviceGeneration.platform == .iOS ? iOSFamilies : nil
    }

    /// The list as WebKit is given it: each name as written, and in lower case — a page may write a
    /// family in any case, and CSS matches family names without regard to it.
    public static func engineList(_ families: [String]) -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for name in families + families.map({ $0.lowercased() }) where seen.insert(name).inserted {
            list.append(name)
        }
        return list
    }
}
