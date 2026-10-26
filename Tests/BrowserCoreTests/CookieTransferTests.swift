import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BrowserCore

final class CookieTransferTests: XCTestCase {
    private let jan2030 = Date(timeIntervalSince1970: 1_893_456_000)

    private func cookie(_ name: String, domain: String = ".example.com", path: String = "/", value: String = "v",
                        secure: Bool = false, httpOnly: Bool = false, expires: Date? = nil,
                        sameSite: CookieRecord.SameSite? = nil) -> CookieRecord {
        CookieRecord(domain: domain, path: path, name: name, value: value, secure: secure,
                     httpOnly: httpOnly, expires: expires, sameSite: sameSite)
    }

    private func assertInvalidConfiguration(_ expression: @autoclosure () throws -> Any,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case CoreError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertUnsupportedFormat(_ expression: @autoclosure () throws -> Any,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case CoreError.unsupportedFormat = error else {
                return XCTFail("expected unsupportedFormat, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: Record

    func testRecordBasics() {
        let domainCookie = cookie("a", domain: ".Example.COM", expires: jan2030)
        XCTAssertFalse(domainCookie.hostOnly)
        XCTAssertEqual(domainCookie.bareDomain, "Example.COM")
        XCTAssertTrue(domainCookie.isValid)
        XCTAssertEqual(domainCookie.normalized()?.domain, ".example.com")

        let hostCookie = cookie("b", domain: "www.example.com")
        XCTAssertTrue(hostCookie.hostOnly)
        XCTAssertTrue(hostCookie.isSession)
        XCTAssertFalse(hostCookie.isExpired(at: .distantFuture), "session cookies never count as expired")

        XCTAssertFalse(domainCookie.isExpired(at: jan2030.addingTimeInterval(-1)))
        XCTAssertTrue(domainCookie.isExpired(at: jan2030))
        XCTAssertTrue(domainCookie.isExpired(at: jan2030.addingTimeInterval(1)))

        XCTAssertEqual(cookie("c", path: "").normalized()?.path, "/")
        XCTAssertEqual(cookie("d", expires: Date(timeIntervalSince1970: 1_893_456_000.75)).normalized()?.expires, jan2030,
                       "expiry is truncated to whole seconds")
    }

    func testRecordValidation() {
        let invalid: [CookieRecord] = [
            cookie(""),
            cookie("a", domain: ""),
            cookie("a", domain: "."),
            cookie("a", domain: "..example.com"),
            cookie("a", domain: "exa mple.com"),
            cookie("a", domain: "example.com/path"),
            cookie("a", domain: "exa\tmple.com"),
            cookie("a", domain: "a..b"),
            cookie("a", path: "relative"),
            cookie("a", path: "/a;b"),
            cookie("a", path: "/a\nb"),
            cookie("a\u{1}"),
            cookie("a=b"),
            cookie("a;b"),
            cookie("a\tb"),
            cookie("a", value: "x\ny"),
            cookie("a", value: "x\u{7F}"),
            cookie("a", value: "x\u{85}"),
            cookie("a", value: "x;y"),
            cookie("a", expires: Date(timeIntervalSince1970: -10)),
            cookie("a", expires: Date(timeIntervalSince1970: 1e13)),
        ]
        for record in invalid {
            XCTAssertFalse(record.isValid, "\(record) should be invalid")
        }
        XCTAssertTrue(cookie("a", value: "tab\tinside and spaces").isValid, "RFC 6265bis allows HTAB in values")
        XCTAssertTrue(cookie("a", value: "").isValid)
        XCTAssertTrue(cookie("a", value: "юникод ✓").isValid)
        XCTAssertTrue(cookie("a", domain: "127.0.0.1").isValid)
    }

    func testRecordCodableIsTolerant() throws {
        let minimal = #"{"domain":"example.com","name":"sid"}"#
        let decoded = try JSONDecoder().decode(CookieRecord.self, from: Data(minimal.utf8))
        XCTAssertEqual(decoded, CookieRecord(domain: "example.com", name: "sid", value: ""))

        let unknownSameSite = #"{"domain":"example.com","name":"sid","value":"1","sameSite":"future-mode","secure":true}"#
        let decoded2 = try JSONDecoder().decode(CookieRecord.self, from: Data(unknownSameSite.utf8))
        XCTAssertNil(decoded2.sameSite)
        XCTAssertTrue(decoded2.secure)

        let full = cookie("x", secure: true, httpOnly: true, expires: jan2030, sameSite: .strict)
        XCTAssertEqual(try JSONDecoder().decode(CookieRecord.self, from: JSONEncoder().encode(full)), full)
    }

    // MARK: Netscape

    func testParseNetscape() {
        let text = [
            "# Netscape HTTP Cookie File",
            "# comment line",
            "",
            ".example.com\tTRUE\t/\tTRUE\t1893456000\tsid\tabc123",
            "#HttpOnly_www.example.com\tFALSE\t/account\tFALSE\t0\ttoken\txyz",
            "Sub.Example.org\tfalse\t/\tfalse\t1893456000\tempty",            // 6 fields: blank value (curl)
            "example.net\tFALSE\t/\tFALSE\t1893456000\twithtabs\tpart1\tpart2", // extra tab belongs to the value
            "   ",
        ].joined(separator: "\r\n")
        let result = CookieTransfer.parseNetscape(text)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.cookies, [
            CookieRecord(domain: ".example.com", path: "/", name: "sid", value: "abc123", secure: true,
                         httpOnly: false, expires: jan2030),
            CookieRecord(domain: "www.example.com", path: "/account", name: "token", value: "xyz", secure: false,
                         httpOnly: true, expires: nil),
            CookieRecord(domain: "sub.example.org", path: "/", name: "empty", value: "", expires: jan2030),
            CookieRecord(domain: "example.net", path: "/", name: "withtabs", value: "part1\tpart2", expires: jan2030),
        ])
    }

    func testNetscapeIncludeSubdomainsFlagDecidesTheDot() {
        let text = """
        example.com\tTRUE\t/\tFALSE\t0\ta\t1
        .example.com\tFALSE\t/\tFALSE\t0\tb\t2
        """
        let cookies = CookieTransfer.parseNetscape(text).cookies
        XCTAssertEqual(cookies.map(\.domain), [".example.com", "example.com"])
        XCTAssertEqual(cookies.map(\.hostOnly), [false, true])
    }

    func testNetscapeLineEndingsBOMAndSpaceFallback() {
        let lines = [".a.test\tTRUE\t/\tFALSE\t0\tone\t1", "b.test\tFALSE\t/\tFALSE\t0\ttwo\t2"]
        for separator in ["\n", "\r\n", "\r"] {
            let result = CookieTransfer.parseNetscape("\u{FEFF}" + lines.joined(separator: separator) + separator)
            XCTAssertEqual(result.cookies.map(\.name), ["one", "two"], "separator \(separator.debugDescription)")
            XCTAssertEqual(result.skipped, 0)
        }
        // Tabs lost in copy and paste: split on runs of spaces, the value keeps inner spaces.
        let spaced = CookieTransfer.parseNetscape(".c.test   TRUE  /  TRUE  1893456000  sid  some value")
        XCTAssertEqual(spaced.cookies, [CookieRecord(domain: ".c.test", name: "sid", value: "some value",
                                                     secure: true, expires: jan2030)])
    }

    func testNetscapeSkipsMalformedLines() {
        let text = [
            "only\tthree\tfields",
            ".x.test\tMAYBE\t/\tFALSE\t0\tn\tv",           // bad flag
            ".x.test\tTRUE\t/\tYES\t0\tn\tv",              // bad secure flag
            ".x.test\tTRUE\t/\tFALSE\tsoon\tn\tv",         // bad expiry
            ".x.test\tTRUE\t/\tFALSE\tnan\tn\tv",
            ".x.test\tTRUE\t/\tFALSE\tinf\tn\tv",
            ".x.test\tTRUE\t/\tFALSE\t1e308\tn\tv",
            ".x.test\tTRUE\t/\tFALSE\t99999999999999999999999\tn\tv",
            ".x.test\tTRUE\t/\tFALSE\t1893456000000\tn\tv", // milliseconds
            ".x.test\tTRUE\t/\tFALSE\t-5\tn\tv",
            ".x.test\tTRUE\t/\tFALSE\t0\t\tv",             // empty name
            "\tTRUE\t/\tFALSE\t0\tn\tv",                   // empty domain
            "ex ample.test\tFALSE\t/\tFALSE\t0\tn\tv",
            "example.test/x\tFALSE\t/\tFALSE\t0\tn\tv",
            "example.test\tFALSE\t/\tFALSE\t0\tn\u{0}\tv",
            "Set-Cookie: a=b; Path=/",
            ".ok.test\tTRUE\t/\tFALSE\t-1\tgood\tv",          // -1 = session
        ].joined(separator: "\n")
        let result = CookieTransfer.parseNetscape(text)
        XCTAssertEqual(result.cookies, [CookieRecord(domain: ".ok.test", name: "good", value: "v")])
        XCTAssertEqual(result.skipped, 16)
    }

    func testNetscapeRoundTrip() throws {
        let cookies = [
            cookie("sid", value: "abc", secure: true, httpOnly: true, expires: jan2030),
            cookie("host", domain: "www.example.com", path: "/p", value: "tab\there"),
            cookie("empty", domain: "example.org", value: "", expires: Date(timeIntervalSince1970: 1)),
        ]
        let text = CookieTransfer.exportNetscape(cookies)
        XCTAssertTrue(text.hasPrefix("# Netscape HTTP Cookie File\n"))
        XCTAssertTrue(text.contains("\n#HttpOnly_.example.com\tTRUE\t/\tTRUE\t1893456000\tsid\tabc\n"))
        XCTAssertTrue(text.contains("\nwww.example.com\tFALSE\t/p\tFALSE\t0\thost\ttab\there\n"))
        XCTAssertTrue(text.hasSuffix("\n"))

        let parsed = try CookieTransfer.parse(Data(text.utf8))
        XCTAssertEqual(parsed.cookies, cookies)
        XCTAssertEqual(parsed.skipped, 0)
    }

    func testNetscapeExportDropsSameSiteAndInvalidRecords() {
        let text = CookieTransfer.exportNetscape([
            cookie("keep", sameSite: .strict),
            cookie("bad\nname"),
            cookie("", domain: "x.test"),
        ])
        let parsed = CookieTransfer.parseNetscape(text)
        XCTAssertEqual(parsed.cookies, [cookie("keep")])
        XCTAssertEqual(parsed.skipped, 0)
    }

    func testNetscapeLatin1Fallback() throws {
        var data = Data(".a.test\tTRUE\t/\tFALSE\t0\tname\tcaf".utf8)
        data.append(0xE9) // 'é' in Latin-1, invalid as UTF-8
        let result = try CookieTransfer.parse(data)
        XCTAssertEqual(result.cookies.first?.value, "café")
    }

    // MARK: JSON

    func testParseCookieEditorExport() throws {
        let json = """
        [
          {
            "domain": ".example.com", "expirationDate": 1893456000.123456, "hostOnly": false,
            "httpOnly": true, "name": "sid", "path": "/", "sameSite": "no_restriction",
            "secure": true, "session": false, "storeId": "0", "value": "abc", "id": 1
          },
          {
            "domain": "www.example.com", "hostOnly": true, "httpOnly": false, "name": "pref",
            "path": "/settings", "sameSite": "unspecified", "secure": false, "session": true,
            "storeId": "0", "value": "dark"
          },
          {
            "domain": "example.org", "hostOnly": false, "name": "dotless", "value": "1",
            "sameSite": "lax", "expirationDate": 1893456000
          },
          {
            "domain": ".example.net", "hostOnly": true, "name": "hostonly", "value": "1", "sameSite": "Strict"
          },
          {
            "domain": "example.io", "name": "sessionwins", "value": "1", "session": true,
            "expirationDate": 1893456000
          }
        ]
        """
        let result = try CookieTransfer.parse(Data(json.utf8))
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.cookies, [
            cookie("sid", value: "abc", secure: true, httpOnly: true, expires: jan2030, sameSite: CookieRecord.SameSite.none),
            cookie("pref", domain: "www.example.com", path: "/settings", value: "dark"),
            cookie("dotless", domain: ".example.org", value: "1", expires: jan2030, sameSite: .lax),
            cookie("hostonly", domain: "example.net", value: "1", sameSite: .strict),
            cookie("sessionwins", domain: "example.io", value: "1"),
        ])
    }

    func testParseAutomationToolFormats() throws {
        // Playwright storageState: {"cookies": [...], "origins": [...]}, expires -1 = session.
        let playwright = """
        {"cookies": [
          {"name": "a", "value": "1", "domain": ".example.com", "path": "/", "expires": -1,
           "httpOnly": false, "secure": true, "sameSite": "Lax"},
          {"name": "b", "value": "2", "domain": "example.com", "path": "/", "expires": 1893456000,
           "httpOnly": true, "secure": false, "sameSite": "None"}
        ], "origins": []}
        """
        XCTAssertEqual(try CookieTransfer.parse(Data(playwright.utf8)).cookies, [
            cookie("a", value: "1", secure: true, sameSite: .lax),
            cookie("b", domain: "example.com", value: "2", httpOnly: true, expires: jan2030,
                   sameSite: CookieRecord.SameSite.none),
        ])

        // Selenium: "expiry"; also numeric/ISO strings and string booleans from hand-made files.
        let selenium = """
        [
          {"name": "s", "value": "1", "domain": "example.com", "path": "/", "expiry": 1893456000, "secure": "true"},
          {"name": "t", "value": "2", "domain": "example.com", "expires": "1893456000", "httpOnly": 1},
          {"name": "u", "value": "3", "domain": "example.com", "expires": "2030-01-01T00:00:00Z"},
          {"name": "w", "value": "4", "domain": "example.com", "expires": "2030-01-01T00:00:00.500Z"},
          {"name": "x", "value": "5", "domain": "example.com", "expires": null}
        ]
        """
        let parsed = try CookieTransfer.parse(Data(selenium.utf8)).cookies
        XCTAssertEqual(parsed, [
            cookie("s", domain: "example.com", value: "1", secure: true, expires: jan2030),
            cookie("t", domain: "example.com", value: "2", httpOnly: true, expires: jan2030),
            cookie("u", domain: "example.com", value: "3", expires: jan2030),
            cookie("w", domain: "example.com", value: "4", expires: jan2030),
            cookie("x", domain: "example.com", value: "5"),
        ])
    }

    func testJSONSkipsInvalidRecords() throws {
        let json = """
        [
          {"name": "ok", "value": "1", "domain": "example.com"},
          "not an object",
          42,
          {"value": "1", "domain": "example.com"},
          {"name": "", "value": "1", "domain": "example.com"},
          {"name": "n", "value": "1"},
          {"name": "n", "value": "1", "domain": "exa mple.com"},
          {"name": "n", "value": "1", "domain": "example.com/x"},
          {"name": "n\\u0007", "value": "1", "domain": "example.com"},
          {"name": "n", "value": "a\\nb", "domain": "example.com"},
          {"name": "n", "value": 5, "domain": "example.com"},
          {"name": "n", "value": "1", "domain": "example.com", "path": 7},
          {"name": "n", "value": "1", "domain": "example.com", "expirationDate": 1893456000000},
          {"name": "n", "value": "1", "domain": "example.com", "expirationDate": -100},
          {"name": "n", "value": "1", "domain": "example.com", "expirationDate": 1e300},
          {"name": "n", "value": "1", "domain": "example.com", "expires": "tomorrow"},
          {"name": "n", "value": "1", "domain": "example.com", "expires": "NaN"},
          {"name": "n", "value": "1", "domain": "example.com", "expires": {"a": 1}}
        ]
        """
        let result = try CookieTransfer.parseJSON(Data(json.utf8))
        XCTAssertEqual(result.cookies, [cookie("ok", domain: "example.com", value: "1")])
        XCTAssertEqual(result.skipped, 17)
    }

    func testMalformedJSONThrows() {
        assertUnsupportedFormat(try CookieTransfer.parse(Data("[{\"name\": ".utf8)))
        assertUnsupportedFormat(try CookieTransfer.parse(Data("{\"origins\": []}".utf8)))
        assertUnsupportedFormat(try CookieTransfer.parse(Data("{\"cookies\": 5}".utf8)))
        assertUnsupportedFormat(try CookieTransfer.parseJSON(Data("\"just a string\"".utf8)))
        assertUnsupportedFormat(try CookieTransfer.parseJSON(Data()))
        // Pathological nesting must fail cleanly, not overflow the stack.
        assertUnsupportedFormat(try CookieTransfer.parse(Data(String(repeating: "[", count: 200_000).utf8)))
        assertUnsupportedFormat(try CookieTransfer.parse(Data((String(repeating: "[", count: 33) + String(repeating: "]", count: 33)).utf8)))
        // Brackets inside strings do not count; Playwright's storageState depth is fine.
        let deepButValid = #"{"cookies":[{"name":"a[[[[","value":"\"{{{{","domain":"x.test","partitionKey":{"topLevelSite":"https://x.test"}}],"origins":[{"origin":"https://x.test","localStorage":[{"name":"k","value":"v"}]}]}"#
        XCTAssertEqual(try CookieTransfer.parse(Data(deepButValid.utf8)).cookies.map(\.value), ["\"{{{{"])

        // A number Double cannot hold: corelibs rejects the document, Apple's parser may
        // yield infinity, which then skips the record. Either way nothing is imported.
        do {
            let result = try CookieTransfer.parse(Data("[{\"name\":\"a\",\"domain\":\"b.c\",\"expires\":1e400}]".utf8))
            XCTAssertEqual(result, CookieParseResult(cookies: [], skipped: 1))
        } catch CoreError.unsupportedFormat {
            // expected on Linux
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testJSONRoundTripAndShape() throws {
        let cookies = [
            cookie("sid", value: "abc", secure: true, httpOnly: true, expires: jan2030, sameSite: CookieRecord.SameSite.none),
            cookie("host", domain: "www.example.com", path: "/a/b", value: "x/y", sameSite: .lax),
            cookie("strict", domain: "example.org", value: "юникод", expires: Date(timeIntervalSince1970: 1), sameSite: .strict),
            cookie("plain"),
        ]
        let data = try CookieTransfer.exportJSON(cookies)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
        XCTAssertTrue(text.contains("\"path\" : \"/a/b\""), "slashes are not escaped: \(text)")
        XCTAssertFalse(text.contains("storeId"))

        let array = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(Set(array[0].keys), ["domain", "expirationDate", "hostOnly", "httpOnly", "name", "path",
                                           "sameSite", "secure", "session", "value"])
        XCTAssertEqual(array[0]["sameSite"] as? String, "no_restriction")
        XCTAssertEqual((array[0]["expirationDate"] as? NSNumber)?.doubleValue, 1_893_456_000)
        XCTAssertEqual(array[0]["hostOnly"] as? Bool, false)
        XCTAssertEqual(array[0]["session"] as? Bool, false)
        XCTAssertNil(array[1]["expirationDate"], "session cookies have no expirationDate")
        XCTAssertEqual(array[1]["session"] as? Bool, true)
        XCTAssertEqual(array[1]["hostOnly"] as? Bool, true)
        XCTAssertEqual(array[1]["sameSite"] as? String, "lax")
        XCTAssertEqual(array[2]["sameSite"] as? String, "strict")
        XCTAssertEqual(array[3]["sameSite"] as? String, "unspecified")

        // Keys are sorted within each object.
        let firstObject = try XCTUnwrap(text.range(of: "{").map { text[$0.lowerBound...] })
        let keyOrder = ["domain", "expirationDate", "hostOnly", "httpOnly", "name", "path", "sameSite", "secure", "session", "value"]
            .compactMap { firstObject.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertEqual(keyOrder.count, 10)
        XCTAssertEqual(keyOrder, keyOrder.sorted())

        let reparsed = try CookieTransfer.parse(data)
        XCTAssertEqual(reparsed.cookies, cookies)
        XCTAssertEqual(reparsed.skipped, 0)
    }

    func testCrossFormatRoundTrip() throws {
        let original = [
            cookie("a", secure: true, httpOnly: true, expires: jan2030, sameSite: .lax),
            cookie("b", domain: "host.example.com", value: "2"),
        ]
        let viaNetscape = try CookieTransfer.parse(Data(CookieTransfer.exportNetscape(original).utf8)).cookies
        let back = try CookieTransfer.parse(CookieTransfer.exportJSON(viaNetscape)).cookies
        // Netscape has no SameSite column: everything else survives.
        var expected = original
        expected[0].sameSite = nil
        XCTAssertEqual(back, expected)
    }

    // MARK: Detection, limits, de-duplication

    func testDetectFormat() {
        XCTAssertEqual(CookieTransfer.detectFormat(Data("[]".utf8)), .json)
        XCTAssertEqual(CookieTransfer.detectFormat(Data("\u{FEFF}  \r\n\t{\"cookies\":[]}".utf8)), .json)
        XCTAssertEqual(CookieTransfer.detectFormat(Data("# Netscape HTTP Cookie File\n".utf8)), .netscape)
        XCTAssertEqual(CookieTransfer.detectFormat(Data(".example.com\tTRUE\t/\tFALSE\t0\ta\tb".utf8)), .netscape)
        XCTAssertEqual(CookieTransfer.detectFormat(Data()), .netscape)
        XCTAssertEqual(CookieFormat.netscape.fileExtension, "txt")
        XCTAssertEqual(CookieFormat.json.fileExtension, "json")

        XCTAssertEqual(try CookieTransfer.parse(Data()), CookieParseResult(cookies: [], skipped: 0))
        let bomJSON = Data([0xEF, 0xBB, 0xBF]) + Data(#"[{"name":"a","value":"1","domain":"x.test"}]"#.utf8)
        XCTAssertEqual(try CookieTransfer.parse(bomJSON).cookies.map(\.name), ["a"])
    }

    func testRejectsOversizedInput() {
        var big = Data(repeating: UInt8(ascii: " "), count: CookieTransfer.maxInputBytes + 1)
        assertInvalidConfiguration(try CookieTransfer.parse(big))
        big[0] = UInt8(ascii: "[")
        assertInvalidConfiguration(try CookieTransfer.parse(big))
        assertInvalidConfiguration(try CookieTransfer.parseJSON(big))

        var atLimit = Data(repeating: UInt8(ascii: " "), count: CookieTransfer.maxInputBytes)
        atLimit[0] = UInt8(ascii: "[")
        atLimit[atLimit.count - 1] = UInt8(ascii: "]")
        XCTAssertEqual(try CookieTransfer.parse(atLimit), CookieParseResult(cookies: [], skipped: 0))
    }

    func testCookieCapCountsTheRestAsSkipped() throws {
        let total = CookieTransfer.maxCookies + 5
        var text = "# Netscape HTTP Cookie File\n"
        text.reserveCapacity(total * 40)
        for i in 0..<total {
            text += ".example.com\tTRUE\t/\tFALSE\t0\tc\(i)\tv\n"
        }
        let result = try CookieTransfer.parse(Data(text.utf8))
        XCTAssertEqual(result.cookies.count, CookieTransfer.maxCookies)
        XCTAssertEqual(result.skipped, 5)
        XCTAssertEqual(result.cookies.last?.name, "c\(CookieTransfer.maxCookies - 1)")
    }

    func testDuplicatesKeepTheLastValue() {
        let text = """
        .example.com\tTRUE\t/\tFALSE\t0\tsid\tfirst
        example.com\tFALSE\t/\tFALSE\t0\tsid\thost-only is a different cookie
        .EXAMPLE.com\tTRUE\t/\tFALSE\t0\tsid\tsecond
        .example.com\tTRUE\t/other\tFALSE\t0\tsid\tother path
        """
        let result = CookieTransfer.parseNetscape(text)
        XCTAssertEqual(result.cookies.map(\.value), ["second", "host-only is a different cookie", "other path"])
        XCTAssertEqual(result.skipped, 0)
    }

    // MARK: HTTPCookie bridge

    func testHTTPCookieRoundTrip() throws {
        let records = [
            cookie("sid", value: "abc", secure: true, httpOnly: true, expires: jan2030),
            cookie("host", domain: "www.example.com", path: "/p", value: "v"),
            cookie("plain", domain: "example.org", value: ""),
        ]
        for record in records {
            let httpCookie = try XCTUnwrap(record.httpCookie, "\(record)")
            XCTAssertEqual(httpCookie.domain, record.domain)
            XCTAssertEqual(httpCookie.path, record.path)
            XCTAssertEqual(httpCookie.name, record.name)
            XCTAssertEqual(httpCookie.value, record.value)
            XCTAssertEqual(httpCookie.isSecure, record.secure)
            XCTAssertEqual(httpCookie.isHTTPOnly, record.httpOnly)
            XCTAssertEqual(httpCookie.isSessionOnly, record.expires == nil)
            XCTAssertEqual(httpCookie.expiresDate, record.expires)
            XCTAssertEqual(CookieRecord(httpCookie), record)
        }

        // A Foundation cookie built elsewhere (domain case, no explicit discard flag).
        let foreign = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".Example.COM", .path: "/", .name: "f", .value: "1",
        ]))
        let converted = try XCTUnwrap(CookieRecord(foreign))
        XCTAssertEqual(converted.domain, ".example.com")
        XCTAssertNil(converted.expires)

        XCTAssertNil(cookie("bad;name").httpCookie)
    }

    func testHTTPCookieSameSite() throws {
        let lax = try XCTUnwrap(cookie("a", sameSite: .lax).httpCookie)
        let strict = try XCTUnwrap(cookie("b", sameSite: .strict).httpCookie)
        let none = try XCTUnwrap(cookie("c", sameSite: CookieRecord.SameSite.none).httpCookie)
        #if canImport(Darwin)
        XCTAssertEqual(lax.sameSitePolicy, .sameSiteLax)
        XCTAssertEqual(strict.sameSitePolicy, .sameSiteStrict)
        XCTAssertNil(none.sameSitePolicy)
        XCTAssertEqual(CookieRecord(lax)?.sameSite, .lax)
        XCTAssertEqual(CookieRecord(strict)?.sameSite, .strict)
        #else
        // swift-corelibs-foundation has no SameSite support: the attribute is dropped.
        XCTAssertNil(CookieRecord(lax)?.sameSite)
        XCTAssertNil(CookieRecord(strict)?.sameSite)
        #endif
        XCTAssertNil(CookieRecord(none)?.sameSite)
    }
}
