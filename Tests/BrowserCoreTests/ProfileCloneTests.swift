import XCTest
@testable import BrowserCore

final class ProfileCloneTests: XCTestCase {
    private let berlin = ProxySettings(kind: .socks5, host: "de1.example", port: 1080, username: "u", password: "p",
                                       excludedDomains: ["bank.example"])

    func testACopyIsSetUpAsTheOriginalWithNothingOfItsOwn() {
        var original = ProfileConfiguration(proxy: berlin, matchProxyLocation: true)
        original.tags = ["shop"]
        original.notes = "login: alice"
        original.avatar = ProfileAvatarStyle(color: 3, letters: "AL")
        original.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE", proxyEndpoint: "de1.example:1080")
        original.settingsModifiedAt = Date()
        original.searchEngine = .google

        let same = ProfileClone.configuration(from: original, proxy: original.proxy)
        XCTAssertEqual(same.proxy, berlin, "the original's own proxy keeps its bypass list")
        XCTAssertEqual(same.tags, ["shop"])
        XCTAssertEqual(same.searchEngine, .google)
        XCTAssertTrue(same.matchProxyLocation)
        XCTAssertEqual(same.notes, "")
        XCTAssertNil(same.avatar)
        XCTAssertNil(same.lastProxyLocation)
        XCTAssertNil(same.settingsModifiedAt)

        let other = ProxySettings(kind: .httpConnect, host: "fr1.example", port: 3128)
        XCTAssertEqual(ProfileClone.configuration(from: original, proxy: other).proxy?.excludedDomains, [], "another proxy, no bypass list")
        XCTAssertNil(ProfileClone.configuration(from: original, proxy: nil).proxy)
    }

    func testNamesGoOnFromTheOriginalsAndNeverRepeatOne() {
        XCTAssertEqual(ProfileClone.names(for: "Shop", count: 3, taken: ["Shop", "shop 3"]), ["Shop 2", "Shop 4", "Shop 5"])
        XCTAssertEqual(ProfileClone.names(for: "Shop 4", count: 2, taken: ["Shop 4"]), ["Shop 5", "Shop 6"])
        XCTAssertEqual(ProfileClone.names(for: "2024", count: 1, taken: []), ["2024 2"], "a name that is only a number keeps it")
        let long = String(repeating: "x", count: 128)
        XCTAssertTrue(ProfileClone.names(for: long, count: 2, taken: [long]).allSatisfy { $0.count <= 128 })
        XCTAssertEqual(ProfileClone.names(for: "A", count: 0, taken: []), [])
    }

    func testProxiesGoUnusedFirstOfTheCountryAskedInTurn() {
        func entry(_ host: String, country: String?, alive: Bool = true, known: Bool = true) -> ProxyListEntry {
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: host, port: 1080), kindKnown: known,
                           lastCheck: country.map { ProxyCheckResult(checkedAt: Date(), failure: alive ? nil : .noAnswer, countryCode: $0) })
        }
        let usedDE = entry("de-used.example", country: "DE")
        let deadDE = entry("de-dead.example", country: "DE", alive: false)
        let freeDE = entry("de-free.example", country: "DE")
        let fr = entry("fr.example", country: "FR")
        let unknown = entry("unknown.example", country: nil, known: false)
        let list = [usedDE, deadDE, fr, freeDE, unknown]
        let used: Set<String> = [ProxyList.identity(of: usedDE.proxy)]

        let picked = ProfileClone.proxies(from: list, count: 4, country: "de", used: used)
        XCTAssertEqual(picked.map(\.proxy.host), ["de-free.example", "de-dead.example", "de-used.example", "de-free.example"])
        XCTAssertEqual(ProfileClone.proxies(from: list, count: 2, country: nil, used: used).map(\.proxy.host), ["fr.example", "de-free.example"])
        XCTAssertEqual(ProfileClone.proxies(from: list, count: 2, country: "US", used: used), [])
        XCTAssertEqual(ProfileClone.proxies(from: [unknown], count: 1, country: nil, used: []), [], "a type no check found is given to no profile")
    }
}
