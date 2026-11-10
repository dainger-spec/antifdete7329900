import XCTest
@testable import LumenCore

/// A proxy written as one line, read by the Mac's rules (its ProxyHostField and ProxyListImport).
final class ProxyLineTests: XCTestCase {
    func line(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ProxyLine? {
        switch ProxyLine.read(text) {
        case let .success(read): return read
        case let .failure(problem):
            XCTFail("\(text) was not read: \(problem)", file: file, line: line)
            return nil
        }
    }

    func problem(_ text: String) -> ProxyLine.Problem? {
        if case let .failure(problem) = ProxyLine.read(text) { return problem }
        return nil
    }

    func testEveryFormProvidersHandOut() {
        XCTAssertEqual(line("1.2.3.4:1080"), ProxyLine(host: "1.2.3.4", port: 1080))
        XCTAssertEqual(line("1.2.3.4:1080:user:pass"), ProxyLine(host: "1.2.3.4", port: 1080, username: "user", password: "pass"))
        XCTAssertEqual(line("user:pass:1.2.3.4:1080"), ProxyLine(host: "1.2.3.4", port: 1080, username: "user", password: "pass"))
        XCTAssertEqual(line("user:pass@1.2.3.4:1080"), ProxyLine(host: "1.2.3.4", port: 1080, username: "user", password: "pass"))
        XCTAssertEqual(line("1.2.3.4:1080@user:pass"), ProxyLine(host: "1.2.3.4", port: 1080, username: "user", password: "pass"),
                       "the login and the password after the address")
        XCTAssertEqual(line("socks5://anna:secret@de.gw.example:1080"),
                       ProxyLine(kind: .socks5, host: "de.gw.example", port: 1080, username: "anna", password: "secret"))
        XCTAssertEqual(line("socks5h://de.gw.example:1080")?.kind, .socks5)
        XCTAssertEqual(line("SOCKS://de.gw.example:1080/")?.kind, .socks5)
        XCTAssertEqual(line("http://proxy.example.com:3128  # Berlin 1"),
                       ProxyLine(kind: .http, host: "proxy.example.com", port: 3128, label: "Berlin 1"))
        XCTAssertEqual(line("[2001:db8::1]:1080"), ProxyLine(host: "2001:db8::1", port: 1080))
        XCTAssertEqual(line("  \u{FEFF}127.0.0.1:28381\n"), ProxyLine(host: "127.0.0.1", port: 28381), "what a paste brings around the line is dropped")
    }

    func testWhatALineSaysAndWhatItDoesNot() {
        // No scheme: the type is not the line's to say.
        XCTAssertNil(line("1.2.3.4:1080")?.kind, "a line without a scheme says nothing of the type")
        // No login: no password either — an edited proxy keeps the one it has.
        XCTAssertNil(line("socks5://1.2.3.4:1080")?.password)
        XCTAssertEqual(line("socks5://anna@1.2.3.4:1080")?.password, "", "a login without a password: an empty one")
        // A password with what a URL escapes, and with an @ of its own.
        XCTAssertEqual(line("http://anna:p%40ss%3Aword@1.2.3.4:8080")?.password, "p@ss:word")
        XCTAssertEqual(line("anna:p@ss@1.2.3.4:8080")?.password, "p@ss")
        XCTAssertEqual(line("anna:p@ss@1.2.3.4:8080")?.host, "1.2.3.4")
    }

    func testWhatIsNotAProxy() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("  \n # only a comment"), .empty)
        XCTAssertEqual(problem("1.2.3.4:1080\n5.6.7.8:1080"), .several)
        XCTAssertEqual(problem("1.2.3.4 :1080"), .spaces)
        XCTAssertEqual(problem("https://1.2.3.4:443"), .scheme("https"), "the iPhone has no TLS to a proxy and says so")
        XCTAssertEqual(problem("ftp://1.2.3.4:21"), .scheme("ftp"))
        XCTAssertEqual(problem("http://1.2.3.4:8080/path"), .path)
        XCTAssertEqual(problem(":pass@1.2.3.4:1080"), .emptyUser)
        XCTAssertEqual(problem("1.2.3.4"), .missingPort)
        XCTAssertEqual(problem("proxy.example.com"), .missingPort)
        XCTAssertEqual(problem("1.2.3.4:99999"), .port)
        XCTAssertEqual(problem("1.2.3.4:port"), .port)
        XCTAssertEqual(problem("300.1.1.1:1080"), .notAHost)
        XCTAssertEqual(problem("-bad-.example:1080"), .notAHost)
        XCTAssertEqual(problem("a:b:c"), .notAHost)
        for problem in [ProxyLine.Problem.empty, .several, .spaces, .scheme("ftp"), .path, .emptyUser, .notAHost, .port, .missingPort] {
            XCTAssertFalse(problem.text.isEmpty)
        }
    }

    func testTheLineOfASavedProxyHasNoPassword() {
        XCTAssertEqual(ProxyLine.write(kind: .socks5, host: "de.gw.example", port: 1080, username: "anna"), "socks5://anna@de.gw.example:1080")
        XCTAssertEqual(ProxyLine.write(kind: .http, host: "1.2.3.4", port: 3128, username: ""), "http://1.2.3.4:3128")
        XCTAssertEqual(ProxyLine.write(kind: .socks5, host: "2001:db8::1", port: 1080, username: ""), "socks5://[2001:db8::1]:1080")
        // What is written is read back as the same proxy, a login with an @ included.
        let written = ProxyLine.write(kind: .http, host: "1.2.3.4", port: 3128, username: "team@corp")
        XCTAssertEqual(line(written), ProxyLine(kind: .http, host: "1.2.3.4", port: 3128, username: "team@corp", password: ""))
    }
}
