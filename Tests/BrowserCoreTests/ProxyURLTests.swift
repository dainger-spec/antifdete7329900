import XCTest
@testable import BrowserCore

final class ProxyURLTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProxySettings {
        do {
            return try ProxySettings(parsing: text)
        } catch {
            XCTFail("\(text.debugDescription) should parse: \(error)", file: file, line: line)
            throw error
        }
    }

    func testSchemes() throws {
        XCTAssertEqual(try parse("http://proxy.example:3128"),
                       ProxySettings(kind: .httpConnect, host: "proxy.example", port: 3128))
        XCTAssertEqual(try parse("https://proxy.example:8443"),
                       ProxySettings(kind: .httpConnect, host: "proxy.example", port: 8443, tlsToProxy: true))
        XCTAssertEqual(try parse("socks5://203.0.113.5:1080"),
                       ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080))
        // socks5h is the same thing here: Network.framework always resolves on the proxy.
        XCTAssertEqual(try parse("socks5h://203.0.113.5:1080"), try parse("socks5://203.0.113.5:1080"))
        XCTAssertEqual(try parse("SOCKS5H://Proxy.Example:9050"),
                       ProxySettings(kind: .socks5, host: "proxy.example", port: 9050))
    }

    func testDefaultPorts() throws {
        XCTAssertEqual(try parse("http://proxy.example").port, ProxySettings.defaultHTTPPort)
        XCTAssertEqual(try parse("https://proxy.example").port, ProxySettings.defaultHTTPSPort)
        XCTAssertEqual(try parse("socks5://proxy.example").port, ProxySettings.defaultSOCKSPort)
        XCTAssertEqual(try parse("socks5h://u:p@[::1]").port, 1080)
        XCTAssertEqual([ProxySettings.defaultHTTPPort, ProxySettings.defaultHTTPSPort, ProxySettings.defaultSOCKSPort],
                       [8080, 443, 1080])
    }

    func testCredentials() throws {
        let encoded = try parse("socks5://us%40er:p%3Ass%20w%C3%B6rd@proxy.example:1080")
        XCTAssertEqual(encoded.username, "us@er")
        XCTAssertEqual(encoded.password, "p:ss wörd")

        // Unencoded '@' in the password: the last '@' separates the host.
        let rawAt = try parse("http://user:p@ss@proxy.example:3128")
        XCTAssertEqual(rawAt.username, "user")
        XCTAssertEqual(rawAt.password, "p@ss")
        XCTAssertEqual(rawAt.host, "proxy.example")

        // Password containing ':' (only the first ':' separates the user).
        XCTAssertEqual(try parse("http://user:a:b@proxy.example:1").password, "a:b")

        // Username only (token-style proxies): empty password so both are set, as validate() wants.
        let userOnly = try parse("http://token123@proxy.example:8000")
        XCTAssertEqual(userOnly.username, "token123")
        XCTAssertEqual(userOnly.password, "")
        XCTAssertNoThrow(try userOnly.validate())

        let none = try parse("http://proxy.example:8000")
        XCTAssertNil(none.username)
        XCTAssertNil(none.password)
    }

    func testIPv6() throws {
        let v6 = try parse("http://[2001:DB8::1]:8080")
        XCTAssertEqual(v6.host, "2001:db8::1")
        XCTAssertEqual(v6.port, 8080)
        XCTAssertEqual(v6.urlString(includePassword: true), "http://[2001:db8::1]:8080")
        XCTAssertEqual(v6.displayName, "HTTP [2001:db8::1]:8080")
        XCTAssertEqual(try parse("socks5://[::ffff:203.0.113.5]:1080").host, "::ffff:203.0.113.5")
        XCTAssertEqual(try parse("[::1]:3128"), ProxySettings(kind: .httpConnect, host: "::1", port: 3128))
    }

    func testProviderShorthand() throws {
        XCTAssertEqual(try parse("203.0.113.5:3128"),
                       ProxySettings(kind: .httpConnect, host: "203.0.113.5", port: 3128))
        XCTAssertEqual(try parse("203.0.113.5:3128:alice:s3cret"),
                       ProxySettings(kind: .httpConnect, host: "203.0.113.5", port: 3128,
                                     username: "alice", password: "s3cret"))
        // Shorthand is literal: no percent-decoding, extra ':' belong to the password.
        XCTAssertEqual(try parse("proxy.example:8000:alice:pa:ss%41").password, "pa:ss%41")
        XCTAssertEqual(try parse("proxy.example:8000:alice:").password, "")
        // E-mail address as the username.
        let email = try parse("proxy.example:8000:alice@mail.example:pw")
        XCTAssertEqual(email.host, "proxy.example")
        XCTAssertEqual(email.username, "alice@mail.example")
        XCTAssertEqual(email.password, "pw")
        // URL without a scheme → HTTP, credentials literal.
        XCTAssertEqual(try parse("alice:pw%41@proxy.example:8000"),
                       ProxySettings(kind: .httpConnect, host: "proxy.example", port: 8000,
                                     username: "alice", password: "pw%41"))
    }

    func testTrimmingAndTrailingSlash() throws {
        XCTAssertEqual(try parse("  socks5://proxy.example:1080/\n"),
                       ProxySettings(kind: .socks5, host: "proxy.example", port: 1080))
        XCTAssertEqual(try parse("\t203.0.113.5:3128 ").host, "203.0.113.5")
    }

    func testRejectsMalformedInput() {
        let bad = [
            "", "   ", "\n",
            "ftp://proxy.example:21", "socks4://proxy.example:1080", "socks://proxy.example:1080",
            "socks4a://proxy.example:1080", "://proxy.example:1", "http//proxy.example:1",
            "http://", "http://:8080", "http://user:pw@:8080", "http://user:pw@",
            "http://proxy.example:0", "http://proxy.example:65536", "http://proxy.example:99999999999999999999",
            "http://proxy.example:abc", "http://proxy.example:", "http://proxy.example:-1", "http://proxy.example:+80",
            "http://proxy.example:80/path", "http://proxy.example:80?x=1", "http://proxy.example:80#frag",
            "http://proxy.example:80//", "http://pro xy.example:80", "http://proxy.example :80",
            "http://proxy..example:80", "http://.proxy.example:80", "http://прокси.example:80", "http://proxy!:80",
            "http://2001:db8::1:8080", "http://[2001:db8::1", "http://[2001:db8::1]x", "http://[zz::1]:80",
            "http://[]:80", "http://[fe80::1%25en0]:80", "http://[203.0.113.5]:80",
            "http://us%ZZer:pw@proxy.example:80", "http://:pw@proxy.example:80", "http://us%00er:pw@proxy.example:80",
            "proxy.example", "proxy.example:1:user", "proxy.example:port", "proxy.example:8000::pw",
            "user:pw@proxy.example", "proxy.example:80\u{0}",
            "https+socks5://proxy.example:1",
            String(repeating: "a", count: 3000) + ":80",
        ]
        for text in bad {
            XCTAssertThrowsError(try ProxySettings(parsing: text), "\(text.debugDescription) should be rejected") { error in
                guard case let CoreError.invalidConfiguration(message) = error else {
                    return XCTFail("\(text.debugDescription): expected invalidConfiguration, got \(error)")
                }
                XCTAssertFalse(message.isEmpty)
                XCTAssertLessThan(message.count, 200, "messages are short")
            }
        }
    }

    func testURLStringAndRoundTrip() throws {
        let settings = [
            ProxySettings(kind: .httpConnect, host: "proxy.example", port: 3128),
            ProxySettings(kind: .httpConnect, host: "proxy.example", port: 443, username: "u", password: "p", tlsToProxy: true),
            ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080, username: "us@er:x", password: "p@ss:w/rd wörd%"),
            ProxySettings(kind: .socks5, host: "2001:db8::1", port: 9050, username: "token", password: ""),
        ]
        for original in settings {
            let url = original.urlString(includePassword: true)
            XCTAssertEqual(try ProxySettings(parsing: url), original, url)
        }

        XCTAssertEqual(settings[0].urlString(includePassword: true), "http://proxy.example:3128")
        XCTAssertEqual(settings[1].urlString(includePassword: true), "https://u:p@proxy.example:443")
        XCTAssertEqual(settings[2].urlString(includePassword: true),
                       "socks5h://us%40er%3Ax:p%40ss%3Aw%2Frd%20w%C3%B6rd%25@203.0.113.5:1080")
        XCTAssertEqual(settings[3].urlString(includePassword: true), "socks5h://token@[2001:db8::1]:9050")

        let masked = settings[2].urlString(includePassword: false)
        XCTAssertEqual(masked, "socks5h://us%40er%3Ax:•••@203.0.113.5:1080")
        XCTAssertFalse(masked.contains("ss"))
        XCTAssertEqual(settings[3].urlString(includePassword: false), "socks5h://token@[2001:db8::1]:9050")

        // Bypass domains are not part of a URL.
        var withBypass = settings[0]
        withBypass.excludedDomains = ["intranet.example"]
        XCTAssertEqual(withBypass.urlString(includePassword: true), "http://proxy.example:3128")
    }

    func testDisplayName() throws {
        XCTAssertEqual(try parse("socks5://alice:secret@203.0.113.5:1080").displayName, "SOCKS5 203.0.113.5:1080")
        XCTAssertEqual(try parse("http://proxy.example:3128").displayName, "HTTP proxy.example:3128")
        XCTAssertEqual(try parse("https://proxy.example").displayName, "HTTPS proxy.example:443")
        XCTAssertFalse(try parse("socks5://alice:secret@203.0.113.5:1080").displayName.contains("secret"))
    }

    func testParsedSettingsSurviveConfigurationCoding() throws {
        // The parser produces ordinary ProxySettings: they persist like hand-entered ones.
        var configuration = ProfileConfiguration()
        configuration.proxy = try parse("socks5h://alice:secret@203.0.113.5:1080")
        try configuration.validate()
        let decoded = try JSONDecoder().decode(ProfileConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.proxy, configuration.proxy)
    }
}
