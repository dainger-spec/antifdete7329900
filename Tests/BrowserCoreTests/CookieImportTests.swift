@testable import BrowserCore
import XCTest

final class CookieImportTests: XCTestCase {
    /// 2026-01-01T00:00:00Z: "now" for every test.
    let now = Date(timeIntervalSince1970: 1_767_225_600)
    let future = 1_893_456_000 // 2030-01-01
    let past = 1_700_000_000 // 2023-11-14

    private func reasons(_ report: CookieImportReport) -> [String] {
        report.problems.map { "\($0.location) \($0.reason)" }
    }

    // MARK: Netscape

    func testNetscapeFileLineByLine() throws {
        let lines = [
            "# Netscape HTTP Cookie File",
            "# This is a generated file! Do not edit.",
            "",
            ".example.com\tTRUE\t/\tTRUE\t\(future)\tsid\tabc123",          // 4: domain cookie, secure
            "login.example.com\tFALSE\t/account\tFALSE\t0\tsession\tx y",   // 5: host-only session cookie
            "#HttpOnly_.example.com\tTRUE\t/\tFALSE\t\(future)\tauth\tt0k", // 6: HttpOnly
            ".example.com\tTRUE\t/\tFALSE\t\(future)\tempty",               // 7: empty value, no tab
            "example.org  FALSE  /  FALSE  \(future)  spaced  v1",          // 8: spaces instead of tabs
            "broken\tline\twith four",                                      // 9: wrong field count
            ".example.com\tTRUE\t/\tFALSE\t\(past)\told\tv",                 // 10: expired
            ".co.uk\tTRUE\t/\tFALSE\t\(future)\tsuffix\tv",                 // 11: public suffix
            "example.com\tFALSE\t/\tFALSE\t\(future)\t__Host-id\tv",         // 12: __Host- without Secure
            "example.com\tFALSE\t/\tFALSE\tsoon\twhen\tv",                   // 13: unreadable expiry
            ".example.com\tTRUE\t/\tFALSE\t\(future)\tsid\tlater",          // 14: same as line 4 (not secure): replaces it
            "example.net\tFALSE\t/\tFALSE\t1893456000000\tms\tv",           // 15: milliseconds
        ]
        let report = CookieImporter.read(Data(lines.joined(separator: "\r\n").utf8), now: now)
        XCTAssertEqual(report.format, .netscape)
        XCTAssertEqual(report.encoding, "UTF-8")
        XCTAssertEqual(report.entriesFound, 12)
        let byName = Dictionary(uniqueKeysWithValues: report.cookies.map { ($0.name, $0) })
        XCTAssertEqual(report.cookies.map(\.name), ["session", "auth", "empty", "spaced", "sid", "ms"])

        let sid = try XCTUnwrap(byName["sid"])
        XCTAssertEqual(sid.value, "later")
        XCTAssertEqual(sid.storedDomain, ".example.com")
        XCTAssertFalse(sid.secure)
        let session = try XCTUnwrap(byName["session"])
        XCTAssertTrue(session.hostOnly)
        XCTAssertNil(session.expires)
        XCTAssertEqual(session.path, "/account")
        XCTAssertEqual(session.value, "x y")
        XCTAssertTrue(try XCTUnwrap(byName["auth"]).httpOnly)
        XCTAssertEqual(byName["empty"]?.value, "")
        XCTAssertEqual(byName["spaced"]?.domain, "example.org")
        XCTAssertEqual(byName["spaced"]?.value, "v1")
        XCTAssertEqual(byName["ms"]?.expires, Date(timeIntervalSince1970: TimeInterval(future)))

        XCTAssertEqual(report.problems.map(\.location), [.line(4), .line(9), .line(10), .line(11), .line(12), .line(13)])
        XCTAssertEqual(report.problems.map(\.reason), [
            .replacedByLaterEntry(.line(14)), .wrongFieldCount(3), .expired(Date(timeIntervalSince1970: TimeInterval(past))),
            .publicSuffixDomain("co.uk"), .prefixRequirements("__Host-"), .invalidExpiry("soon"),
        ])
        XCTAssertEqual(report.failures.count, 5)
    }

    func testDamagedBytesCostOnlyTheirLine() {
        var data = Data("example.com\tFALSE\t/\tFALSE\t\(future)\tgood\tv\n".utf8)
        data += Data("example.com\tFALSE\t/\tFALSE\t\(future)\tbad\tv".utf8) + Data([0xC3, 0x28, 0xFF]) + Data("\n".utf8)
        data += Data("example.com\tFALSE\t/\tFALSE\t\(future)\talso\tv\n".utf8)
        let report = CookieImporter.read(data, now: now)
        XCTAssertEqual(report.cookies.map(\.name), ["good", "also"])
        XCTAssertEqual(report.damagedByteSequences, 2)
        XCTAssertEqual(report.problems, [CookieImportProblem(location: .line(2), name: "bad", reason: .damagedText)])
    }

    // MARK: JSON variants

    func testExtensionExportsEditThisCookieAndCookieEditor() throws {
        let json = """
        [
          {"domain": ".example.com", "expirationDate": \(future).5, "hostOnly": false, "httpOnly": true, "name": "a",
           "path": "/", "sameSite": "no_restriction", "secure": true, "session": false, "storeId": "0", "value": "1", "id": 1},
          {"domain": "www.example.com", "hostOnly": true, "httpOnly": false, "name": "b", "path": "/",
           "sameSite": "lax", "secure": false, "session": true, "value": "2"},
          {"domain": "example.com", "expirationDate": \(future), "name": "c", "path": "/", "sameSite": "unspecified", "value": "3"}
        ]
        """
        let report = CookieImporter.read(Data(json.utf8), now: now)
        XCTAssertEqual(report.format, .json)
        XCTAssertTrue(report.problems.isEmpty, "\(reasons(report))")
        XCTAssertEqual(report.cookies, [
            ImportedCookie(name: "a", value: "1", domain: "example.com", hostOnly: false, path: "/",
                           expires: Date(timeIntervalSince1970: TimeInterval(future) + 0.5), secure: true, httpOnly: true, sameSite: ImportedCookie.SameSite.none),
            ImportedCookie(name: "b", value: "2", domain: "www.example.com", hostOnly: true, sameSite: .lax),
            ImportedCookie(name: "c", value: "3", domain: "example.com", hostOnly: true,
                           expires: Date(timeIntervalSince1970: TimeInterval(future))),
        ])
    }

    func testAutomationExportsPlaywrightPuppeteerSelenium() throws {
        let storageState = """
        {"cookies": [
          {"name": "pw", "value": "1", "domain": ".example.com", "path": "/", "expires": -1, "httpOnly": false,
           "secure": true, "sameSite": "Lax"},
          {"name": "pp", "value": "2", "domain": "example.com", "path": "/", "expires": \(future), "size": 3, "httpOnly": true,
           "secure": true, "session": false, "sameSite": "Strict", "priority": "Medium"},
          {"name": "chips", "value": "3", "domain": "example.com", "path": "/", "expires": \(future), "secure": true,
           "partitionKey": {"topLevelSite": "https://example.com", "hasCrossSiteAncestor": false}},
          {"name": "never", "value": "4", "domain": "example.com", "path": "/", "expires": null, "session": false}
        ], "origins": [{"origin": "https://example.com", "localStorage": [{"name": "k", "value": "v"}]}]}
        """
        let state = CookieImporter.read(Data(storageState.utf8), now: now)
        XCTAssertEqual(state.problems.map(\.reason), [.partitioned], "\(reasons(state))")
        XCTAssertEqual(state.cookies.map(\.name), ["pw", "pp", "never"])
        XCTAssertEqual(state.cookies.last?.expires, now.addingTimeInterval(400 * 86_400), "null expiry, not a session: capped at 400 days")
        XCTAssertNil(state.cookies[0].expires)
        XCTAssertEqual(state.cookies[0].sameSite, .lax)
        XCTAssertEqual(state.cookies[1].sameSite, .strict)
        XCTAssertTrue(state.cookies[1].httpOnly)

        let selenium = #"[{"name": "se", "value": "4", "domain": "example.com", "path": "/", "expiry": \#(future), "secure": false, "httpOnly": false}]"#
        XCTAssertEqual(CookieImporter.read(Data(selenium.utf8), now: now).cookies.first?.expires,
                       Date(timeIntervalSince1970: TimeInterval(future)))
    }

    func testDatabaseExportsChromeAndFirefox() throws {
        // Chrome: microseconds since 1601; samesite -1/0/1/2. Firefox: seconds; sameSite 0/1/2.
        let chromeTime = (Int64(future) + 11_644_473_600) * 1_000_000
        let json = """
        [{"host_key": ".example.com", "name": "ch", "value": "1", "path": "/", "expires_utc": \(chromeTime),
          "is_secure": 1, "is_httponly": 0, "samesite": 1},
         {"host": "example.org", "name": "ff", "value": "2", "path": "/", "expiry": \(future), "isSecure": 0,
          "isHttpOnly": 1, "sameSite": 2}]
        """
        let report = CookieImporter.read(Data(json.utf8), now: now)
        XCTAssertTrue(report.problems.isEmpty, "\(reasons(report))")
        let chrome = try XCTUnwrap(report.cookies.first)
        XCTAssertEqual(chrome.expires, Date(timeIntervalSince1970: TimeInterval(future)))
        XCTAssertTrue(chrome.secure)
        XCTAssertFalse(chrome.hostOnly)
        XCTAssertEqual(chrome.sameSite, .lax)
        let firefox = try XCTUnwrap(report.cookies.last)
        XCTAssertTrue(firefox.httpOnly)
        XCTAssertTrue(firefox.hostOnly)
        XCTAssertEqual(firefox.sameSite, .strict)
    }

    func testJSONLinesAndAURLInsteadOfADomain() {
        let lines = """
        {"name": "one", "value": "1", "domain": "example.com", "expires": "2030-01-01T00:00:00Z"}
        {"name": "two", "value": "2", "url": "https://shop.example.com/cart", "expires": "Tue, 01 Jan 2030 00:00:00 GMT"}
        """
        let report = CookieImporter.read(Data(lines.utf8), now: now)
        XCTAssertEqual(report.cookies.map(\.name), ["one", "two"])
        XCTAssertEqual(report.cookies.last?.domain, "shop.example.com")
        XCTAssertEqual(report.cookies.last?.hostOnly, true)
        XCTAssertEqual(report.cookies.first?.expires, Date(timeIntervalSince1970: TimeInterval(future)))
        XCTAssertEqual(report.cookies.last?.expires, Date(timeIntervalSince1970: TimeInterval(future)))
    }

    // MARK: Damaged JSON

    func testCutOffJSONKeepsTheCompleteEntries() throws {
        let json = """
        [
          {"name": "a", "value": "1", "domain": "example.com"},
          {"name": "b", "value": "2", "domain": "example.com", "extra": {"note": "an object inside the cookie"}},
          {"name": "c", "value": "3", "dom
        """
        let report = CookieImporter.read(Data(json.utf8), now: now)
        XCTAssertEqual(report.format, .json)
        XCTAssertEqual(report.cookies.map(\.name), ["a", "b"])
        XCTAssertEqual(report.entriesFound, 3)
        XCTAssertTrue(report.problems.contains(CookieImportProblem(location: .entry(3, line: 4), name: "c", reason: .cutOff)),
                      "\(reasons(report))")
        XCTAssertTrue(report.problems.contains { if case .damagedJSON = $0.reason { return $0.location == .file } else { return false } })
    }

    func testOneBrokenEntryAndTrailingCommas() {
        let json = """
        {"cookies": [
          {"name": "a", "value": "1", "domain": "example.com",},
          {"name": "b", "value": "2 "domain": "example.com"},
          {"name": "c", "value": "3", "domain": "example.com"},
        ]}
        """
        let report = CookieImporter.read(Data(json.utf8), now: now)
        XCTAssertEqual(report.cookies.map(\.name), ["a", "c"])
        XCTAssertTrue(report.problems.contains { $0.location == .entry(2, line: 3) && $0.reason == .unreadableEntry("not valid JSON") },
                      "\(reasons(report))")
    }

    func testJunkAroundTheJSON() {
        let text = "Exported 2 cookies at 12:00\n[{\"name\": \"a\", \"value\": \"1\", \"domain\": \"example.com\"},\n"
            + "{\"name\": \"b\", \"value\": \"2\", \"domain\": \"example.com\"}] -- end of export\n"
        let report = CookieImporter.read(Data(text.utf8), now: now)
        XCTAssertEqual(report.format, .json)
        XCTAssertEqual(report.cookies.map(\.name), ["a", "b"])
    }

    func testDamagedBytesInsideAJSONValue() {
        var data = Data(#"[{"name": "ok", "value": "1", "domain": "example.com"}, {"name": "bad", "value": ""#.utf8)
        data += Data([0xE2, 0x82]) // a cut UTF-8 sequence
        data += Data(#"", "domain": "example.com"}]"#.utf8)
        let report = CookieImporter.read(data, now: now)
        XCTAssertEqual(report.cookies.map(\.name), ["ok"])
        XCTAssertEqual(report.damagedByteSequences, 1)
        XCTAssertEqual(report.problems.map(\.reason), [.damagedText])
        XCTAssertEqual(report.problems.first?.name, "bad")
    }

    // MARK: Encodings and files that are not cookies

    func testUTF16AndByteOrderMarks() {
        let json = #"[{"name": "u", "value": "ü", "domain": "example.com"}]"#
        var withBOM = Data([0xFF, 0xFE])
        withBOM += json.data(using: .utf16LittleEndian)!
        let utf16 = CookieImporter.read(withBOM, now: now)
        XCTAssertEqual(utf16.encoding, "UTF-16LE")
        XCTAssertEqual(utf16.cookies.first?.value, "ü")

        let noBOM = CookieImporter.read(json.data(using: .utf16BigEndian)!, now: now)
        XCTAssertEqual(noBOM.encoding, "UTF-16BE")
        XCTAssertEqual(noBOM.cookies.count, 1)

        let utf8BOM = CookieImporter.read(Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8), now: now)
        XCTAssertEqual(utf8BOM.encoding, "UTF-8 (BOM)")
        XCTAssertEqual(utf8BOM.cookies.count, 1)
    }

    func testFilesThatAreNotCookies() {
        let prose = CookieImporter.read(Data("Dear diary,\nToday I baked cookies with my grandmother.\n".utf8), now: now)
        XCTAssertNil(prose.format)
        XCTAssertEqual(prose.problems.map(\.reason), [.unrecognizedFormat])
        XCTAssertTrue(prose.cookies.isEmpty)

        let huge = CookieImporter.read(Data(count: CookieImporter.maximumFileSize + 1), now: now)
        XCTAssertEqual(huge.problems.map(\.reason), [.fileTooLarge(CookieImporter.maximumFileSize + 1)])

        let notCookies = CookieImporter.read(Data(#"[1, "two", {"origin": "x"}]"#.utf8), now: now)
        XCTAssertEqual(notCookies.problems.map(\.reason), [.notACookie, .notACookie, .notACookie])
    }

    // MARK: Checks

    func testChecksAsABrowserMakesThem() {
        func check(_ fields: String) -> CookieImportReason? {
            let report = CookieImporter.read(Data("[{\(fields)}]".utf8), now: now)
            return report.cookies.isEmpty ? report.problems.first?.reason : nil
        }
        XCTAssertEqual(check(#""name": "", "value": "1", "domain": "example.com""#), .missingName)
        XCTAssertEqual(check(#""name": "a;b", "value": "1", "domain": "example.com""#), .invalidName)
        XCTAssertEqual(check(#""name": "a", "value": "1;2", "domain": "example.com""#), .invalidValue)
        XCTAssertEqual(check(#""name": "a", "value": "line\nbreak", "domain": "example.com""#), .invalidValue)
        XCTAssertEqual(check(#""name": "a", "value": "\#(String(repeating: "x", count: 4096))", "domain": "example.com""#), .tooLarge)
        XCTAssertEqual(check(#""name": "a", "value": "1""#), .missingDomain)
        XCTAssertEqual(check(#""name": "a", "value": "1", "domain": "exa mple.com""#), .invalidDomain("exa mple.com"))
        XCTAssertEqual(check(#""name": "a", "value": "1", "domain": "пример.рф""#), .invalidDomain("пример.рф"))
        XCTAssertEqual(check(#""name": "a", "value": "1", "domain": ".github.io""#), .publicSuffixDomain("github.io"))
        XCTAssertEqual(check(#""name": "a", "value": "1", "domain": "example.com", "path": "/a;b""#), .invalidPath("/a;b"))
        XCTAssertEqual(check(#""name": "__Secure-a", "value": "1", "domain": "example.com""#), .prefixRequirements("__Secure-"))
        XCTAssertEqual(check(#""name": "__Host-a", "value": "1", "domain": ".example.com", "secure": true"#), .prefixRequirements("__Host-"))
        XCTAssertEqual(check(#""name": "a", "value": "1", "domain": "example.com", "expires": "someday""#), .invalidExpiry("someday"))
        // Accepted: a host-only cookie on a private suffix's own host, an IP address, a URL or a port in the domain.
        XCTAssertNil(check(#""name": "a", "value": "1", "domain": "alice.github.io", "hostOnly": true"#))
        XCTAssertNil(check(#""name": "a", "value": "1", "domain": ".192.168.1.10""#))
        XCTAssertNil(check(#""name": "a", "value": "1", "domain": "https://example.com:8443/""#))
        XCTAssertNil(check(#""name": "__Host-a", "value": "1", "domain": "example.com", "secure": true, "path": "/""#))
        let ip = CookieImporter.read(Data(#"[{"name": "a", "value": "1", "domain": ".192.168.1.10"}]"#.utf8), now: now).cookies.first
        XCTAssertEqual(ip?.hostOnly, true)
        // Spaces and tabs around a value are not part of it; a tab inside one is allowed; a relative path is "/".
        let trimmed = CookieImporter.read(Data(#"[{"name": " a ", "value": " x\ty ", "domain": "example.com", "path": "account"}]"#.utf8),
                                         now: now).cookies.first
        XCTAssertEqual(trimmed?.name, "a")
        XCTAssertEqual(trimmed?.value, "x\ty")
        XCTAssertEqual(trimmed?.path, "/")
        // An encrypted Chrome database row: refused, never imported with an empty value.
        XCTAssertEqual(check(#""name": "a", "value": "", "encrypted_value": "djEw...", "host_key": "example.com""#), .encryptedValue)
    }

    func testMoreShapesFromTheResearch() {
        // yt-dlp writes Chrome's 1601-based microseconds into cookies.txt.
        let chromeTime = (Int64(future) + 11_644_473_600) * 1_000_000
        let ytdlp = CookieImporter.read(Data(".example.com\tTRUE\t/\tFALSE\t\(chromeTime)\tyt\tv\n".utf8), now: now)
        XCTAssertEqual(ytdlp.cookies.first?.expires, Date(timeIntervalSince1970: TimeInterval(future)))
        // A tab in the value splits the line into eight fields: refused.
        let eight = CookieImporter.read(Data("example.com\tFALSE\t/\tFALSE\t0\ta\tb\tc\nexample.com\tFALSE\t/\tFALSE\t0\tok\tv\n".utf8), now: now)
        XCTAssertEqual(eight.cookies.map(\.name), ["ok"])
        XCTAssertEqual(eight.problems.map(\.reason), [.wrongFieldCount(8)])
        // JSON inside a string, and nested wrappers.
        let wrapped = CookieImporter.read(Data(#""[{\"name\": \"s\", \"value\": \"1\", \"domain\": \"example.com\"}]""#.utf8), now: now)
        XCTAssertEqual(wrapped.cookies.map(\.name), ["s"])
        let nested = CookieImporter.read(Data(#"{"result": {"ok": true, "data": [{"name": "n", "value": "1", "domain": "example.com"}]}}"#.utf8), now: now)
        XCTAssertEqual(nested.cookies.map(\.name), ["n"])
        XCTAssertTrue(nested.problems.isEmpty, "\(reasons(nested))")
        // JSON Lines read as such: no damage reported.
        let lines = CookieImporter.read(Data("{\"name\": \"a\", \"value\": \"1\", \"domain\": \"example.com\"}\r\n{\"name\": \"b\", \"value\": \"2\", \"domain\": \"example.com\"}\r\n".utf8), now: now)
        XCTAssertEqual(lines.cookies.map(\.name), ["a", "b"])
        XCTAssertTrue(lines.problems.isEmpty, "\(reasons(lines))")
        // UTF-32 with its BOM (not taken for UTF-16).
        var utf32 = Data([0xFF, 0xFE, 0x00, 0x00])
        utf32 += #"[{"name": "w", "value": "1", "domain": "example.com"}]"#.data(using: .utf32LittleEndian)!
        let wide = CookieImporter.read(utf32, now: now)
        XCTAssertEqual(wide.encoding, "UTF-32LE")
        XCTAssertEqual(wide.cookies.map(\.name), ["w"])
        // Files that are something else, named.
        XCTAssertEqual(CookieImporter.read(Data("SQLite format 3".utf8) + Data([0, 1, 2]), now: now).problems.first?.reason,
                       .unsupportedFile("SQLite database (a browser's cookie database: export it with an extension)"))
        XCTAssertEqual(CookieImporter.read(Data("\n<!DOCTYPE html><html><body>cookies</body></html>".utf8), now: now).problems.first?.reason,
                       .unsupportedFile("web page (HTML)"))
    }

    // MARK: Queue for the next launch

    func testQueuedForTheNextLaunchEncryptedAndMerged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let profile = try repository.create(name: "P", configuration: ProfileConfiguration())
        XCTAssertEqual(try repository.importedCookiesForLaunch(profile.id), [])

        let first = ImportedCookie(name: "sid", value: "secret-cookie-value", domain: "example.com", hostOnly: true)
        let other = ImportedCookie(name: "lang", value: "de", domain: "example.com", hostOnly: false)
        XCTAssertEqual(try repository.queueImportedCookies([first, other], for: profile.id), 2)
        var replaced = first
        replaced.value = "newer"
        XCTAssertEqual(try repository.queueImportedCookies([replaced], for: profile.id), 2)
        XCTAssertEqual(try repository.importedCookiesForLaunch(profile.id).map(\.value).sorted(), ["de", "newer"])

        let onDisk = try Data(contentsOf: repository.importedCookiesURL(for: profile.id))
        XCTAssertNil(onDisk.range(of: Data("newer".utf8)), "the queue is encrypted")
        XCTAssertNil(onDisk.range(of: Data("example.com".utf8)))

        repository.clearImportedCookies(profile.id)
        XCTAssertEqual(try repository.importedCookiesForLaunch(profile.id), [])
        XCTAssertThrowsError(try repository.queueImportedCookies([first], for: UUID()))
    }
}
