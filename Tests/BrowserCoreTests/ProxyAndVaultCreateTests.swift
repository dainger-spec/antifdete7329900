import XCTest
@testable import BrowserCore

final class ProxyHostFieldTests: XCTestCase {
    func testPlainHostsAndIPs() throws {
        XCTAssertEqual(try ProxyHostField.parse("proxy.example.com"), ProxyHostField(host: "proxy.example.com"))
        XCTAssertEqual(try ProxyHostField.parse("  10.0.0.5 \n"), ProxyHostField(host: "10.0.0.5"))
        XCTAssertEqual(try ProxyHostField.parse("\u{FEFF}my_proxy-1.local\r\n"), ProxyHostField(host: "my_proxy-1.local"))
        XCTAssertEqual(try ProxyHostField.parse("2001:db8::1"), ProxyHostField(host: "2001:db8::1"))
    }

    func testPastedProxyStringsAreSplit() throws {
        XCTAssertEqual(try ProxyHostField.parse("1.2.3.4:1080"), ProxyHostField(host: "1.2.3.4", port: 1080))
        XCTAssertEqual(try ProxyHostField.parse("socks5://user:p%40ss@1.2.3.4:1080/"),
                       ProxyHostField(host: "1.2.3.4", port: 1080, username: "user", password: "p@ss", kind: .socks5))
        XCTAssertEqual(try ProxyHostField.parse("socks5h://proxy.example:9050"),
                       ProxyHostField(host: "proxy.example", port: 9050, kind: .socks5))
        XCTAssertEqual(try ProxyHostField.parse("http://proxy.example:3128"),
                       ProxyHostField(host: "proxy.example", port: 3128, kind: .httpConnect, tlsToProxy: false))
        XCTAssertEqual(try ProxyHostField.parse("https://u:pw@proxy.example:443"),
                       ProxyHostField(host: "proxy.example", port: 443, username: "u", password: "pw", kind: .httpConnect, tlsToProxy: true))
        XCTAssertEqual(try ProxyHostField.parse("u:p:w@host.example"),
                       ProxyHostField(host: "host.example", username: "u", password: "p:w"))
        XCTAssertEqual(try ProxyHostField.parse("1.2.3.4:8000:alice:secret"),
                       ProxyHostField(host: "1.2.3.4", port: 8000, username: "alice", password: "secret"))
        XCTAssertEqual(try ProxyHostField.parse("[2001:db8::1]:1080"), ProxyHostField(host: "2001:db8::1", port: 1080))
    }

    /// The orders providers hand proxies out in, the credentials before or after the address
    /// (made-up addresses and passwords).
    func testProvidersOrdersAreRead() throws {
        let expected = ProxyHostField(host: "203.0.113.7", port: 1080, username: "demo_user", password: "Secr3tPass")
        XCTAssertEqual(try ProxyHostField.parse("203.0.113.7:1080@demo_user:Secr3tPass"), expected)
        XCTAssertEqual(try ProxyHostField.parse("demo_user:Secr3tPass:203.0.113.7:1080"), expected)
        XCTAssertEqual(try ProxyHostField.parse("demo_user:Secr3tPass@203.0.113.7:1080"), expected)
        XCTAssertEqual(try ProxyHostField.parse("203.0.113.7:1080:demo_user:Secr3tPass"), expected)
        XCTAssertEqual(try ProxyHostField.parse("socks5://203.0.113.7:1080@demo_user:Secr3tPass"),
                       ProxyHostField(host: "203.0.113.7", port: 1080, username: "demo_user", password: "Secr3tPass", kind: .socks5))
        // A password with "@" and ":" in it, the credentials last.
        XCTAssertEqual(try ProxyHostField.parse("proxy.example.net:8000@alice:p@ss:w"),
                       ProxyHostField(host: "proxy.example.net", port: 8000, username: "alice", password: "p@ss:w"))
        // Both readings make a proxy: the one whose host is an address or a name with a dot.
        XCTAssertEqual(try ProxyHostField.parse("198.51.100.4:3128@admin:9090"),
                       ProxyHostField(host: "198.51.100.4", port: 3128, username: "admin", password: "9090"))
        XCTAssertEqual(try ProxyHostField.parse("user:12345@proxy.example.com:1080"),
                       ProxyHostField(host: "proxy.example.com", port: 1080, username: "user", password: "12345"))
        XCTAssertEqual(try ProxyHostField.parse("user:1234:203.0.113.7:1080"),
                       ProxyHostField(host: "203.0.113.7", port: 1080, username: "user", password: "1234"))
        // A single-word host still reads where it is the only reading.
        XCTAssertEqual(try ProxyHostField.parse("user:pass@myproxy:3128"),
                       ProxyHostField(host: "myproxy", port: 3128, username: "user", password: "pass"))
        XCTAssertEqual(try ProxyHostField.parse("myproxy:3128@user:pass"),
                       ProxyHostField(host: "myproxy", port: 3128, username: "user", password: "pass"))
        // name@host is the URL's order: no port, no other reading.
        XCTAssertEqual(try ProxyHostField.parse("alice@proxy.example"),
                       ProxyHostField(host: "proxy.example", username: "alice", password: ""))
    }

    func testGarbageIsRejected() {
        for bad in ["", "   ", "pro xy.example", "proxy.example\nother", "ftp://proxy.example", "socks5://host/path",
                    "host:99999", "host:0", "host:port", "1.2.3", "300.1.1.1", "-bad.example", "прокси.рф",
                    "[2001:db8::1", "[::1]x", "a:b:c", "@host", "1:2:3:4:5:6:7:8:9", "::1::2", "host..example",
                    "1.2.3.4:1080@", "1.2.3.4:1080@:secret", "user:pass@", "a:b:c:d", "user:pass:host:port"] {
            XCTAssertThrowsError(try ProxyHostField.parse(bad), "accepted “\(bad)”")
        }
    }

    func testValidateRejectsWhatNWEndpointCannotResolve() {
        for bad in ["1.2.3.4:1080", "user:pass@host", "socks5://host", "host\n", "a b", "[::1]"] {
            XCTAssertThrowsError(try ProxySettings(kind: .socks5, host: bad, port: 1080).validate(), "accepted “\(bad)”")
        }
        XCTAssertNoThrow(try ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080).validate())
        XCTAssertNoThrow(try ProxySettings(kind: .httpConnect, host: "::1", port: 3128).validate())
        XCTAssertNoThrow(try ProxySettings(kind: .httpConnect, host: "proxy.example", port: 3128, username: "u", password: "p").validate())
    }
}

final class VaultCreateTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-create-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateNewNeverReplaces() throws {
        let url = root.appendingPathComponent("file.json")
        XCTAssertTrue(try SecureFile.createNew(Data("first".utf8), at: url))
        XCTAssertFalse(try SecureFile.createNew(Data("second".utf8), at: url))
        XCTAssertEqual(try SecureFile.read(url), Data("first".utf8))
        // No temp files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    /// Two creates that both passed the "no vault yet" check: exactly one header lands, the other
    /// caller gets vaultAlreadyExists, and the vault on disk opens with the winner's password.
    func testConcurrentCreatesHaveExactlyOneWinner() throws {
        let attempts = 6
        var outcomes = [Result<UnlockedVault, Error>?](repeating: nil, count: attempts)
        let lock = NSLock()
        let root = root!
        DispatchQueue.concurrentPerform(iterations: attempts) { i in
            let result = Result { try MasterVault.create(in: root, password: "password \(i)", iterations: 1_000) }
            lock.lock(); outcomes[i] = result; lock.unlock()
        }
        let winners = outcomes.enumerated().compactMap { index, outcome -> (Int, UnlockedVault)? in
            if case .success(let vault) = outcome { return (index, vault) }
            return nil
        }
        XCTAssertEqual(winners.count, 1)
        for case .failure(let error)? in outcomes {
            XCTAssertEqual(error as? CoreError, .vaultAlreadyExists)
        }
        let (index, vault) = try XCTUnwrap(winners.first)
        XCTAssertEqual(try MasterVault.unlock(in: root, password: "password \(index)").vaultID, vault.vaultID)
    }
}
