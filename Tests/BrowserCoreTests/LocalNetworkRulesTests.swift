import XCTest
@testable import BrowserCore

/// A profile that protects its local requests: a page from the internet reaches neither this Mac
/// nor the local network, a page on them keeps its own loads, and the internet stays reachable.
final class LocalNetworkRulesTests: XCTestCase {
    private let page = "https://www.example.com/shop"

    func testThisMacAndTheLocalNetworkAreBlockedFromAPageOfTheInternet() {
        for url in ["http://127.0.0.1:8080/", "http://localhost:3000/x", "http://[::1]:9/", "http://0.0.0.0:631/",
                    "http://10.0.0.1/", "http://10.255.255.1:8080/lan10", "https://192.168.1.1/admin",
                    "http://172.16.0.1/", "http://172.20.4.5:81/", "http://172.31.255.255/",
                    "http://169.254.169.254/latest/meta-data", "http://100.64.0.1/", "http://100.100.100.100/",
                    "http://100.127.255.1/", "http://[fd12:3456::1]/", "http://[fc00::1]:8080/", "http://[fe80::1]/",
                    "http://[::ffff:c0a8:101]/", "http://[::ffff:a00:1]/", "http://[::ffff:ac10:1]/",
                    "http://[::ffff:a9fe:a9fe]/", "http://[::ffff:6440:1]/",
                    "http://printer.local/", "http://nas.local.:5000/", "http://router.home.arpa/",
                    "http://tv.lan/", "ws://service.internal:9000/socket"] {
            XCTAssertTrue(LocalNetworkRules.blocks(url, topURL: page), url)
        }
    }

    func testTheInternetIsNotTheLocalNetwork() {
        for url in ["https://8.8.8.8/", "http://11.0.0.1/", "http://172.15.0.1/", "http://172.32.0.1/",
                    "http://192.169.0.1/", "http://169.255.0.1/", "http://100.63.255.255/", "http://100.128.0.1/",
                    "http://[2001:db8::10]:8080/", "http://[::ffff:808:808]/", "https://local.example.com/",
                    "https://example.local.com/", "https://lan.example/", "https://www.example.com/"] {
            XCTAssertFalse(LocalNetworkRules.blocks(url, topURL: page), url)
        }
    }

    func testAPageOnThisMacOrTheLocalNetworkKeepsItsOwnLoads() {
        XCTAssertFalse(LocalNetworkRules.blocks("http://192.168.1.1/api", topURL: "http://192.168.1.1/"))
        XCTAssertFalse(LocalNetworkRules.blocks("http://127.0.0.1:5173/src/main.js", topURL: "http://localhost:5173/"))
        XCTAssertFalse(LocalNetworkRules.blocks("http://10.0.0.5/cam", topURL: "http://nas.local/"))
    }

    func testTheListIsOneBlockPerPatternEachUnlessTheTopIsLocal() throws {
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(LocalNetworkRules.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, LocalNetworkRules.patterns.count)
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertEqual((trigger["unless-top-url"] as? [String])?.count, LocalNetworkRules.patterns.count)
            XCTAssertEqual((rule["action"] as? [String: String])?["type"], "block")
            let pattern = try XCTUnwrap(trigger["url-filter"] as? String)
            XCTAssertFalse(pattern.contains("|"), "WebKit's url-filter has no alternation: \(pattern)")
            XCTAssertFalse(pattern.contains("{"), "nor counted repetition: \(pattern)")
        }
        XCTAssertNotEqual(LocalNetworkRules.identifier, ProxiedContentRules.identifier)
    }

    func testProtectedByDefaultAndTheListOnlyWithoutAProxy() throws {
        XCTAssertEqual(ProfileConfiguration().localRequests, .protected)
        XCTAssertTrue(ProfileConfiguration().blocksLocalNetwork)
        let proxied = ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080))
        XCTAssertFalse(proxied.blocksLocalNetwork, "with a proxy, this Mac is the proxied list's and the rest goes through the proxy")
        XCTAssertFalse(ProfileConfiguration(localRequests: .allowed).blocksLocalNetwork)

        let plain = String(decoding: try JSONCoding.encoder.encode(ProfileConfiguration()), as: UTF8.self)
        XCTAssertFalse(plain.contains("localRequests"), "the default is written as before")
        let allowed = try ProfileRepository.decodeConfiguration(try JSONCoding.encoder.encode(ProfileConfiguration(localRequests: .allowed)))
        XCTAssertEqual(allowed.localRequests, .allowed)
        let unknown = try ProfileRepository.decodeConfiguration(Data(#"{"localRequests":"sometimes"}"#.utf8))
        XCTAssertEqual(unknown.localRequests, .protected, "what does not read is the protected default")
    }
}
