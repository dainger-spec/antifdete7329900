import XCTest
@testable import BrowserCore

/// The rule list of a profile with a proxy (`ProxiedContentRules`): what its patterns take as an
/// address on this Mac. WebKit compiles and applies the list; the self-test checks that in Safari's
/// chrome against a listener on this Mac.
final class ProxiedContentRulesTests: XCTestCase {
    let remotePage = "http://start-run.leak.example.com/pb-leak?run=run"

    func testEveryWayOfNamingThisMacIsBlockedFromARemotePage() {
        for url in ["http://127.0.0.1:18087/pb-leak/lo4", "http://127.1.2.3/", "https://127.0.0.1/x",
                    "ws://127.0.0.1:9222/devtools", "http://localhost:18087/pb-leak/lohost", "http://LOCALHOST:80/",
                    "http://localhost./", "http://localhost/", "http://app.localhost:3000/", "http://a.b.localhost./",
                    "http://[::1]:18087/pb-leak/lo6", "http://[::]:80/", "http://[::ffff:7f00:1]:8080/",
                    "http://0.0.0.0:18087/pb-leak/lo0"] {
            XCTAssertTrue(ProxiedContentRules.blocks(url, topURL: remotePage), url)
            XCTAssertTrue(ProxiedContentRules.blocks(url, resourceType: "document", topURL: remotePage), "a frame: \(url)")
        }
    }

    func testNamesThatOnlyLookLikeThisMacAndOtherHostsAreNot() {
        for url in ["http://127.example.com/", "http://localhost.example.com/", "http://a.localhost.example.com/",
                    "http://192.0.2.10:8080/pb-leak/fetch4", "http://[2001:db8::10]:8080/", "http://lan-run.local/pb-leak/lan",
                    "http://10.255.255.1:8080/", "http://example.com/127.0.0.1/", "http://example.com/?u=http://localhost/"] {
            XCTAssertFalse(ProxiedContentRules.blocks(url, topURL: remotePage), url)
        }
    }

    func testAPageTheUserOpenedOnThisMacKeepsItsOwnLoads() {
        let local = "http://127.0.0.1:18080/pb-leak/secure?run=run"
        XCTAssertFalse(ProxiedContentRules.blocks(local, resourceType: "document", topURL: local), "the page itself")
        XCTAssertFalse(ProxiedContentRules.blocks("http://127.0.0.1:18080/pb-leak/report?run=run", topURL: local))
        XCTAssertTrue(ProxiedContentRules.blocks("http://anything/", resourceType: "ping", topURL: local), "pings, always")
    }

    func testTheListIsWebKitsJSONWithEveryPattern() throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ProxiedContentRules.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 1 + ProxiedContentRules.thisMacURLPatterns.count)
        let triggers = rules.compactMap { $0["trigger"] as? [String: Any] }
        XCTAssertEqual(triggers.first?["resource-type"] as? [String], ["ping"])
        XCTAssertEqual(triggers.dropFirst().compactMap { $0["url-filter"] as? String }, ProxiedContentRules.thisMacURLPatterns)
        for trigger in triggers.dropFirst() {
            XCTAssertEqual(trigger["unless-top-url"] as? [String], ProxiedContentRules.thisMacURLPatterns)
            XCTAssertNil(trigger["if-domain"], "WebKit refuses domain and top-URL conditions in one list")
        }
        XCTAssertTrue(rules.allSatisfy { ($0["action"] as? [String: String])?["type"] == "block" })
        // The subset WebKit's url-filter accepts: no alternation, no counted repetition.
        for pattern in ProxiedContentRules.thisMacURLPatterns {
            XCTAssertFalse(pattern.contains("|") || pattern.contains("{"), pattern)
        }
    }
}
