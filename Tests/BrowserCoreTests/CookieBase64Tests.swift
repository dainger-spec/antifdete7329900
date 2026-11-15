@testable import BrowserCore
import XCTest

/// Cookie exports wrapped in Base64 — how accounts are handed over with their cookies, and one of
/// the forms other multi-profile browsers take and give: read as what they wrap, in whichever of
/// Base64's spellings, and nothing else is taken for one.
final class CookieBase64Tests: XCTestCase {
    /// 2026-01-01T00:00:00Z: "now" for every test.
    let now = Date(timeIntervalSince1970: 1_767_225_600)

    /// An extension's export of two cookies; its Base64 holds both "+" and "/".
    private let json = """
        [{"domain":".example.com","expirationDate":1893456000,"hostOnly":false,"httpOnly":true,"name":"sid","path":"/","sameSite":"no_restriction","secure":true,"session":false,"storeId":"0","value":"abc123~~>>??"},
         {"domain":"shop.example.com","hostOnly":true,"httpOnly":false,"name":"cart","path":"/","secure":false,"session":true,"value":"x"}]
        """

    private func read(_ text: String) -> CookieImportReport {
        CookieImporter.read(Data(text.utf8), now: now)
    }

    func testAnExportInBase64IsReadAsWhatItWraps() {
        let plain = read(json)
        XCTAssertEqual(plain.cookies.map(\.name), ["sid", "cart"])
        XCTAssertEqual(plain.encoding, "UTF-8", "a JSON file is read as before")

        let wrapped = Data(json.utf8).base64EncodedString()
        let report = read(wrapped)
        XCTAssertEqual(report.format, .json)
        XCTAssertEqual(report.encoding, "UTF-8, Base64", "the report says how the export came")
        XCTAssertEqual(report.cookies, plain.cookies)
        XCTAssertEqual(report.entriesFound, 2)
        XCTAssertEqual(report.problems, [])
    }

    func testEverySpellingOfBase64() {
        let expected = read(json).cookies
        let wrapped = Data(json.utf8).base64EncodedString()
        XCTAssertTrue(wrapped.contains("+") && wrapped.contains("/"), "the sample exercises both alphabets")

        // Broken into lines of 76 characters, as mail and many tools write it; CRLF too.
        var lines: [String] = []
        var rest = Substring(wrapped)
        while !rest.isEmpty {
            lines.append(String(rest.prefix(76)))
            rest = rest.dropFirst(76)
        }
        XCTAssertEqual(read(lines.joined(separator: "\n")).cookies, expected)
        XCTAssertEqual(read(lines.joined(separator: "\r\n") + "\r\n").cookies, expected)
        // Spaces and a byte order mark around it.
        XCTAssertEqual(read("\u{FEFF}  " + wrapped + " \n").cookies, expected)
        // The URL-safe alphabet, with its padding left out.
        let urlSafe = wrapped.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(read(urlSafe).cookies, expected)
        let padded = Data((json + " ").utf8).base64EncodedString()
        XCTAssertTrue(padded.hasSuffix("="), "the sample exercises the padding")
        XCTAssertEqual(read(padded).cookies, expected)
        XCTAssertEqual(read(padded.replacingOccurrences(of: "=", with: "")).cookies, expected)
    }

    func testANetscapeFileInBase64() {
        let file = "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t1893456000\tsid\tabc123\n"
        let report = read(Data(file.utf8).base64EncodedString())
        XCTAssertEqual(report.format, .netscape)
        XCTAssertEqual(report.encoding, "UTF-8, Base64")
        XCTAssertEqual(report.cookies.map(\.name), ["sid"])
        XCTAssertEqual(report.cookies.first?.storedDomain, ".example.com")
    }

    func testWhatItWrapsIsCheckedAsAnyExport() {
        // An expired cookie inside the wrapping is left out and said, with its place in what was wrapped.
        let old = #"[{"domain":"example.com","name":"old","value":"v","expirationDate":1700000000},{"domain":"example.com","name":"new","value":"v"}]"#
        let report = read(Data(old.utf8).base64EncodedString())
        XCTAssertEqual(report.cookies.map(\.name), ["new"])
        XCTAssertEqual(report.problems.map(\.reason), [.expired(Date(timeIntervalSince1970: 1_700_000_000))])
        XCTAssertEqual(report.problems.map(\.location), [.entry(1, line: 1)])
    }

    func testNothingElseIsTakenForBase64() {
        // Base64 of something that is not a cookie export: not a cookie file, as before.
        let other = Data("hello, this is not a cookie file at all".utf8).base64EncodedString()
        XCTAssertEqual(read(other).problems.map(\.reason), [.unrecognizedFormat])
        XCTAssertNil(CookieImporter.base64Wrapped(other))
        // A word, a sentence, a short token.
        XCTAssertNil(CookieImporter.base64Wrapped("cookies"))
        XCTAssertNil(CookieImporter.base64Wrapped("these are my cookies for the shop account"))
        XCTAssertNil(CookieImporter.base64Wrapped("W3t9XQ=="))
        // JSON and Netscape files themselves: braces, tabs and dots are not Base64's.
        XCTAssertNil(CookieImporter.base64Wrapped(json))
        XCTAssertNil(CookieImporter.base64Wrapped(".example.com\tTRUE\t/\tTRUE\t1893456000\tsid\tabc123"))
        // Not Base64 at all: a length no encoding gives, padding in the middle.
        XCTAssertNil(CookieImporter.base64Wrapped(String(repeating: "A", count: 25)))
        XCTAssertNil(CookieImporter.base64Wrapped("W3siZG9tYWluIjoi=LmV4YW1wbGUuY29tIn1d"))
    }
}
