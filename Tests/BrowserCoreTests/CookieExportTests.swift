import XCTest
@testable import BrowserCore

/// A profile's cookies written out (`CookieExport`) and read back by this app's own import.
final class CookieExportTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    lazy var cookies: [ImportedCookie] = [
        ImportedCookie(name: "sid", value: "s3cr3t", domain: "shop.example", hostOnly: true, path: "/",
                       expires: now.addingTimeInterval(86_400 * 30), secure: true, httpOnly: true, sameSite: .lax),
        ImportedCookie(name: "pref", value: "dark mode=1", domain: "example.org", hostOnly: false, path: "/account",
                       expires: now.addingTimeInterval(3_600), secure: false, httpOnly: false, sameSite: ImportedCookie.SameSite.none),
        ImportedCookie(name: "csrf", value: "abc", domain: "news.example", hostOnly: true, path: "/",
                       expires: nil, secure: true, httpOnly: false, sameSite: .strict),
    ]

    private func readBack(_ data: Data) -> [ImportedCookie] {
        CookieImporter.read(data, now: now).cookies.sorted { CookieKey($0) < CookieKey($1) }
    }

    private func sameCookie(_ a: ImportedCookie, _ b: ImportedCookie, sameSite: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var a = a, b = b
        if !sameSite { a.sameSite = nil; b.sameSite = nil }
        XCTAssertTrue(a.isSameState(as: b), "\(a) is not \(b)", file: file, line: line)
    }

    func testNetscapeFileReadsBackTheSameCookies() {
        let data = CookieExport.data(cookies, format: .netscape)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("# Netscape HTTP Cookie File"))
        XCTAssertTrue(text.contains("#HttpOnly_shop.example\tFALSE\t/\tTRUE\t"), text)
        XCTAssertTrue(text.contains(".example.org\tTRUE\t/account\tFALSE\t"), text)
        XCTAssertTrue(text.contains("news.example\tFALSE\t/\tTRUE\t0\tcsrf\tabc"), "a session cookie has expiry 0: \(text)")
        let read = readBack(data)
        XCTAssertEqual(read.count, 3)
        let expected = cookies.sorted { CookieKey($0) < CookieKey($1) }
        for (a, b) in zip(read, expected) { sameCookie(a, b, sameSite: false) } // the format has no SameSite
    }

    func testExtensionJSONReadsBackTheSameCookiesWithSameSite() throws {
        let data = CookieExport.data(cookies, format: .extensionJSON)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(entries.count, 3)
        let session = try XCTUnwrap(entries.first { $0["name"] as? String == "csrf" })
        XCTAssertEqual(session["session"] as? Bool, true)
        XCTAssertNil(session["expirationDate"])
        XCTAssertEqual(entries.first { $0["name"] as? String == "pref" }?["domain"] as? String, ".example.org")
        XCTAssertEqual(entries.first { $0["name"] as? String == "pref" }?["sameSite"] as? String, "no_restriction")
        let read = readBack(data)
        XCTAssertEqual(read.count, 3)
        let expected = cookies.sorted { CookieKey($0) < CookieKey($1) }
        for (a, b) in zip(read, expected) { sameCookie(a, b, sameSite: true) }
    }

    func testPlaywrightCookiesAreWhatItsStorageStateHolds() throws {
        let data = CookieExport.data(cookies, format: .playwright)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let session = try XCTUnwrap(entries.first { $0["name"] as? String == "csrf" })
        XCTAssertEqual(session["expires"] as? Double, -1)
        XCTAssertEqual(session["sameSite"] as? String, "Strict")
        XCTAssertEqual(entries.first { $0["name"] as? String == "sid" }?["domain"] as? String, "shop.example")
        let read = readBack(data)
        XCTAssertEqual(read.count, 3)
        let expected = cookies.sorted { CookieKey($0) < CookieKey($1) }
        for (a, b) in zip(read, expected) { sameCookie(a, b, sameSite: true) }
    }

    func testAFieldWithATabIsLeftOutOfTheNetscapeFileOnly() {
        var odd = cookies[0]
        odd.name = "tab\tname"
        let all = cookies + [odd]
        XCTAssertEqual(CookieExport.count(all, format: .netscape), 3)
        XCTAssertEqual(CookieExport.count(all, format: .extensionJSON), 4)
        XCTAssertFalse(String(decoding: CookieExport.data(all, format: .netscape), as: UTF8.self).contains("tab\tname"))
    }
}
