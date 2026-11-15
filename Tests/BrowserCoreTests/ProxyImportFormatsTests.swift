import XCTest
@testable import BrowserCore

/// Proxy lines as people really have them: the forms providers and other browsers write, and rows
/// copied out of a spreadsheet, a provider's table or its CSV file. Each line of the table is one
/// such line with what it must be read as; the lines that must stay refused are below it.
final class ProxyImportFormatsTests: XCTestCase {
    private struct Expected {
        var kind: ProxySettings.Kind?
        var host: String
        var port: Int
        var user: String?
        var password: String?
        var tls = false
        var link: String?
    }

    private func expect(_ line: String, _ expected: Expected, file: StaticString = #filePath, line number: UInt = #line) {
        let report = ProxyListImport.read(line)
        guard report.problems.isEmpty, report.proxies.count == 1, let read = report.proxies.first else {
            return XCTFail("“\(line)” was not read as one proxy: \(report.problems.map(\.reason))", file: file, line: number)
        }
        XCTAssertEqual(read.proxy.host, expected.host, "host of “\(line)”", file: file, line: number)
        XCTAssertEqual(read.proxy.port, expected.port, "port of “\(line)”", file: file, line: number)
        XCTAssertEqual(read.proxy.username, expected.user, "user of “\(line)”", file: file, line: number)
        XCTAssertEqual(read.proxy.password, expected.password, "password of “\(line)”", file: file, line: number)
        XCTAssertEqual(read.kindGiven, expected.kind != nil, "whether “\(line)” says its type", file: file, line: number)
        if let kind = expected.kind { XCTAssertEqual(read.proxy.kind, kind, "type of “\(line)”", file: file, line: number) }
        XCTAssertEqual(read.proxy.tlsToProxy, expected.tls, "TLS of “\(line)”", file: file, line: number)
        XCTAssertEqual(read.changeIPURL?.absoluteString, expected.link, "IP-change link of “\(line)”", file: file, line: number)
    }

    // MARK: The forms read before: each is read as it was

    func testTheFormsProvidersAndOtherBrowsersWrite() {
        expect("203.0.113.5:8000", Expected(host: "203.0.113.5", port: 8000))
        expect("203.0.113.5:8000:alice:s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("alice:s3cret@203.0.113.5:8000", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5:8000@alice:s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("alice:s3cret:203.0.113.5:8000", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("socks5://alice:s3cret@203.0.113.5:1080",
               Expected(kind: .socks5, host: "203.0.113.5", port: 1080, user: "alice", password: "s3cret"))
        expect("SOCKS5H://203.0.113.5:1080", Expected(kind: .socks5, host: "203.0.113.5", port: 1080))
        expect("http://203.0.113.5:8000:alice:s3cret",
               Expected(kind: .httpConnect, host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("https://alice:s3cret@gate.example.net:443/",
               Expected(kind: .httpConnect, host: "gate.example.net", port: 443, user: "alice", password: "s3cret", tls: true))
        expect("[2001:db8::1]:1080", Expected(host: "2001:db8::1", port: 1080))
        // A residential gateway's long user name, with its country and session in it.
        expect("gate.example.net:7777:customer-acme-cc-de-sessid-0a1b2c3d-sesstime-30:Pa55w0rd",
               Expected(host: "gate.example.net", port: 7777, user: "customer-acme-cc-de-sessid-0a1b2c3d-sesstime-30", password: "Pa55w0rd"))
        // A mobile proxy with its IP-change link, as other browsers write it.
        expect("socks5://modem7:k3y@mobile.example.net:6001[https://api.example.net/changeip?key=abc123&format=json]",
               Expected(kind: .socks5, host: "mobile.example.net", port: 6001, user: "modem7", password: "k3y",
                        link: "https://api.example.net/changeip?key=abc123&format=json"))
    }

    /// A line that reads as written is never read as columns: what stands in a password stays there.
    func testAPasswordWithASeparatorInItStaysAPassword() {
        expect("alice:p;ss|w,rd@203.0.113.5:8000", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "p;ss|w,rd"))
        expect("203.0.113.5:8000:alice:p;ss|w,rd", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "p;ss|w,rd"))
        expect("socks5://al%20ice:p%40ss@203.0.113.5:1080",
               Expected(kind: .socks5, host: "203.0.113.5", port: 1080, user: "al ice", password: "p@ss"))
    }

    // MARK: Columns: a spreadsheet's row, a provider's table, a CSV file

    func testARowCopiedFromASpreadsheet() {
        expect("203.0.113.5\t8000\talice\ts3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5\t8000", Expected(host: "203.0.113.5", port: 8000))
        expect("203.0.113.5:8000\talice\ts3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5:8000\talice:s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("alice\ts3cret\t203.0.113.5\t8000", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        // An empty cell between two tabs, and spaces around a cell.
        expect("gate.example.net \t 7777\t\talice\ts3cret", Expected(host: "gate.example.net", port: 7777, user: "alice", password: "s3cret"))
    }

    func testSpacesBetweenTheParts() {
        expect("203.0.113.5 8000 alice s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5   8000", Expected(host: "203.0.113.5", port: 8000))
        expect("203.0.113.5:8000 alice s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        // A no-break space, as a web page's table gives it.
        expect("203.0.113.5\u{00A0}8000\u{00A0}alice\u{00A0}s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        // A password of digits is not a port of a second proxy.
        expect("203.0.113.5:8000 alice:12345", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "12345"))
    }

    func testTheTypeAsAWordOfItsOwn() {
        expect("socks5 203.0.113.5 1080", Expected(kind: .socks5, host: "203.0.113.5", port: 1080))
        expect("SOCKS5\t203.0.113.5\t1080\talice\ts3cret", Expected(kind: .socks5, host: "203.0.113.5", port: 1080, user: "alice", password: "s3cret"))
        expect("HTTP 203.0.113.5:8000:alice:s3cret", Expected(kind: .httpConnect, host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("https gate.example.net 443 alice s3cret",
               Expected(kind: .httpConnect, host: "gate.example.net", port: 443, user: "alice", password: "s3cret", tls: true))
        // The type in the table's last column.
        expect("203.0.113.5\t1080\talice\ts3cret\tSOCKS5", Expected(kind: .socks5, host: "203.0.113.5", port: 1080, user: "alice", password: "s3cret"))
        // A type chosen for the import is for the lines that say none.
        let chosen = ProxyListImport.read("203.0.113.5 8000\nsocks5 203.0.113.6 1080", defaultKind: .httpConnect)
        XCTAssertEqual(chosen.proxies.map(\.proxy.kind), [.httpConnect, .socks5])
        XCTAssertEqual(chosen.proxies.map(\.kindGiven), [true, true])
    }

    func testARowOfACSVFile() {
        expect("203.0.113.5;8000;alice;s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5,8000,alice,s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("\"203.0.113.5\",\"8000\",\"alice\",\"s3cret\"", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5:8000|alice|s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("203.0.113.5:8000 | alice:s3cret", Expected(host: "203.0.113.5", port: 8000, user: "alice", password: "s3cret"))
        expect("socks5;gate.example.net;1080;alice;s3cret", Expected(kind: .socks5, host: "gate.example.net", port: 1080, user: "alice", password: "s3cret"))
    }

    func testTheIPChangeLinkAsAColumnOfItsOwn() {
        let link = "https://api.example.net/changeip?key=abc123"
        expect("mobile.example.net:6001:modem7:k3y \(link)",
               Expected(host: "mobile.example.net", port: 6001, user: "modem7", password: "k3y", link: link))
        expect("socks5://modem7:k3y@mobile.example.net:6001\t\(link)",
               Expected(kind: .socks5, host: "mobile.example.net", port: 6001, user: "modem7", password: "k3y", link: link))
        expect("mobile.example.net\t6001\tmodem7\tk3y\thttp://203.0.113.9:7001/api/reboot/7",
               Expected(host: "mobile.example.net", port: 6001, user: "modem7", password: "k3y", link: "http://203.0.113.9:7001/api/reboot/7"))
        expect("socks5 mobile.example.net 6001 modem7 k3y | \(link)",
               Expected(kind: .socks5, host: "mobile.example.net", port: 6001, user: "modem7", password: "k3y", link: link))
        // The name still goes after " #".
        let named = ProxyListImport.read("203.0.113.5\t8000\talice\ts3cret  # Berlin 1")
        XCTAssertEqual(named.problems, [])
        XCTAssertEqual(named.proxies.map(\.label), ["Berlin 1"])
        XCTAssertEqual(named.proxies.first?.proxy.username, "alice")
    }

    func testAWholeTablePastedAtOnce() {
        let report = ProxyListImport.read("""
            Host\tPort\tLogin\tPassword
            203.0.113.5\t8000\talice\ts3cret
            203.0.113.6\t8000\tbob\thunter2

            203.0.113.5\t8000\talice\tother
            """)
        XCTAssertEqual(report.proxies.map(\.proxy.host), ["203.0.113.5", "203.0.113.6"])
        XCTAssertEqual(report.proxies.map(\.proxy.password), ["s3cret", "hunter2"])
        XCTAssertEqual(report.linesRead, 4)
        // The table's own heading is said, not taken for a proxy; the same proxy again is a repeat.
        XCTAssertEqual(report.problems.map(\.line), [1, 5])
        XCTAssertEqual(report.problems.map(\.reason), [.unreadable(.containsWhitespace), .duplicate(ofLine: 2)])
    }

    // MARK: What stays refused, and said

    private func refused(_ line: String, _ reason: ProxyListImport.Reason, file: StaticString = #filePath, line number: UInt = #line) {
        let report = ProxyListImport.read(line)
        XCTAssertEqual(report.proxies.count, 0, "“\(line)” was read as a proxy: \(report.proxies.map(\.proxy))", file: file, line: number)
        XCTAssertEqual(report.problems.map(\.reason), [reason], "“\(line)”", file: file, line: number)
    }

    func testTwoProxiesOnOneLineAreNotReadAsOneWithALogin() {
        refused("203.0.113.5:8000 203.0.113.6:8000", .unreadable(.containsWhitespace))
        refused("203.0.113.5:8000\tgate.example.net:8000", .unreadable(.containsWhitespace))
        refused("203.0.113.5 8000 203.0.113.6 8000", .unreadable(.containsWhitespace))
        refused("203.0.113.5:8000, 203.0.113.6:8000", .unreadable(.containsWhitespace))
    }

    func testWhatIsNotAProxyInColumnsEitherIsReportedAsItWasWritten() {
        refused("not a proxy at all", .unreadable(.containsWhitespace))
        refused("203.0.113.5 port alice s3cret", .unreadable(.containsWhitespace))
        refused("203.0.113.5 8000 alice", .unreadable(.containsWhitespace))
        refused("socks4 203.0.113.5 1080", .unreadable(.containsWhitespace))
        refused("ftp://203.0.113.5:21", .unreadable(.unsupportedScheme("ftp")))
        refused("203.0.113.5", .missingPort)
        // A link that is not one to the internet is not dropped silently: the line is not read.
        refused("203.0.113.5:8000:alice:s3cret http://192.168.1.1/reboot", .unreadable(.containsWhitespace))
        // More columns than a proxy has.
        refused("Berlin 203.0.113.5 8000 alice s3cret extra", .unreadable(.containsWhitespace))
    }

    // MARK: One field

    func testOneFieldTakesARowToo() {
        guard case .proxy(let line) = ProxyListImport.readField("socks5\t203.0.113.5\t1080\talice\ts3cret") else {
            return XCTFail("a row pasted into the field is one proxy")
        }
        XCTAssertEqual(line.proxy, ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080, username: "alice", password: "s3cret"))
        XCTAssertTrue(line.kindGiven)
        // Where its password stands in such a row is not looked for: the field then shows the
        // proxy's own address with dots, never the password.
        XCTAssertNil(ProxyListImport.passwordRange(in: "203.0.113.5 8000 alice s3cret"))
        XCTAssertEqual(ProxyListImport.readField("203.0.113.5:8000 203.0.113.6:8000"), .problem(.unreadable(.containsWhitespace)))
    }
}
