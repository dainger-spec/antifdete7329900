import XCTest
@testable import BrowserCore

/// The Proxies section's filter and order, and the proxies offered in place of one that stopped
/// answering.
final class ProxyListArrangementTests: XCTestCase {
    private func entry(_ label: String, host: String? = nil, alive: Bool? = nil, country: String? = nil, latency: Int? = nil,
                       kindKnown: Bool = true) -> ProxyListEntry {
        var check: ProxyCheckResult?
        if let alive {
            check = alive ? ProxyCheckResult(countryCode: country, latencyMilliseconds: latency) : ProxyCheckResult.dead(.noAnswer)
        }
        return ProxyListEntry(label: label, proxy: ProxySettings(kind: .socks5, host: host ?? "\(label.lowercased()).example", port: 1080),
                              kindKnown: kindKnown, lastCheck: check)
    }

    private func names(_ entries: [ProxyListEntry]) -> [String] { entries.map(\.label) }

    private func countryName(_ code: String) -> String {
        ["DE": "Germany", "US": "United States", "NL": "Netherlands", "FR": "France"][code] ?? code
    }

    // MARK: The filter

    func testEachFilterShowsTheProxiesInItsState() {
        let fast = entry("Fast", alive: true, country: "DE", latency: 80)
        let dead = entry("Dead", alive: false)
        let fresh = entry("Fresh")
        let usedBy: [String: Int] = ["Fast": 2, "Dead": 1]
        func shown(_ filter: ProxyListFilter) -> [String] {
            [fast, dead, fresh].filter { filter.includes($0, usedBy: usedBy[$0.label] ?? 0) }.map(\.label)
        }
        XCTAssertEqual(shown(.all), ["Fast", "Dead", "Fresh"])
        XCTAssertEqual(shown(.working), ["Fast"])
        XCTAssertEqual(shown(.failing), ["Dead"])
        XCTAssertEqual(shown(.unchecked), ["Fresh"])
        XCTAssertEqual(shown(.unused), ["Fresh"])
        // A proxy that asks for a login the entry has not is not working either.
        var locked = entry("Locked")
        locked.lastCheck = .dead(.needsCredentials)
        XCTAssertTrue(ProxyListFilter.failing.includes(locked, usedBy: 0))
        XCTAssertFalse(ProxyListFilter.working.includes(locked, usedBy: 0))
    }

    // MARK: The order

    func testAsAddedIsTheListsOwnOrder() {
        let entries = [entry("b"), entry("a"), entry("c")]
        XCTAssertEqual(names(ProxyListOrder.added.sorted(entries, countryName: countryName)), ["b", "a", "c"])
    }

    func testByNameUsesTheNameShownAndReadsNumbersAsNumbers() {
        // Without a label the address is the name shown.
        let bare = entry("", host: "alpha.example")
        let entries = [entry("Berlin 10"), entry("berlin 2"), bare, entry("Zurich")]
        let sorted = ProxyListOrder.name.sorted(entries, countryName: countryName)
        XCTAssertEqual(sorted.map(\.displayName), ["alpha.example:1080", "berlin 2", "Berlin 10", "Zurich"])
    }

    func testByCountryUsesTheNameShownAndPutsTheUnknownLast() {
        let entries = [entry("us", alive: true, country: "US"), entry("unchecked"), entry("de", alive: true, country: "DE"),
                       entry("dead", alive: false), entry("nl", alive: true, country: "NL"), entry("nowhere", alive: true),
                       entry("de 2", alive: true, country: "DE")]
        let sorted = ProxyListOrder.country.sorted(entries, countryName: countryName)
        XCTAssertEqual(names(sorted), ["de", "de 2", "nl", "us", "unchecked", "dead", "nowhere"])
    }

    func testByLatencyPutsTheFastestFirstThenTheUnmeasuredTheUncheckedAndTheDead() {
        let entries = [entry("dead", alive: false), entry("slow", alive: true, latency: 1900), entry("unchecked"),
                       entry("fast", alive: true, latency: 40), entry("unmeasured", alive: true), entry("middle", alive: true, latency: 300)]
        let sorted = ProxyListOrder.latency.sorted(entries, countryName: countryName)
        XCTAssertEqual(names(sorted), ["fast", "middle", "slow", "unmeasured", "unchecked", "dead"])
    }

    func testByStatePutsWhatNeedsAttentionFirst() {
        let entries = [entry("ok 1", alive: true), entry("dead 1", alive: false), entry("new"), entry("ok 2", alive: true),
                       entry("dead 2", alive: false)]
        let sorted = ProxyListOrder.state.sorted(entries, countryName: countryName)
        XCTAssertEqual(names(sorted), ["dead 1", "dead 2", "new", "ok 1", "ok 2"])
    }

    /// The names the choice is kept under between launches, and the filters' — the strings table
    /// has a title for each (`proxies.filter.<name>`).
    func testTheNamesTheChoicesAreKeptUnderStay() {
        XCTAssertEqual(ProxyListOrder.allCases.map(\.rawValue), ["added", "name", "country", "latency", "state"])
        XCTAssertEqual(ProxyListFilter.allCases.map(\.rawValue), ["all", "working", "failing", "unchecked", "unused"])
    }

    // MARK: Replacing a proxy that stopped answering

    func testReplacementsAreWorkingProxiesOfTheSameCountryUnusedFirst() {
        let dead = entry("Dead DE", alive: false)
        let usedDE = entry("Used DE", alive: true, country: "DE", latency: 50)
        let freeDE = entry("Free DE", alive: true, country: "de", latency: 400)
        let freeUS = entry("Free US", alive: true, country: "US", latency: 20)
        let deadToo = entry("Dead too", alive: false)
        let unchecked = entry("Unchecked")
        let unknownKind = entry("No type", alive: true, country: "DE", latency: 10, kindKnown: false)
        let all = [dead, usedDE, freeUS, deadToo, unchecked, unknownKind, freeDE]
        let used: Set<String> = [ProxyList.identity(of: dead.proxy), ProxyList.identity(of: usedDE.proxy)]

        // One profile: the free proxy of its country, though a faster one of that country is in use
        // and a faster free one is elsewhere.
        XCTAssertEqual(names(ProxyList.replacements(for: dead, among: all, count: 1, country: "DE", used: used)), ["Free DE"])
        // Three profiles: the country first, then the others; never the dead, the unchecked, one of
        // unknown type, or the proxy itself.
        XCTAssertEqual(names(ProxyList.replacements(for: dead, among: all, count: 3, country: "DE", used: used)),
                       ["Free DE", "Used DE", "Free US"])
        // More profiles than proxies: each proxy once (the assignment goes round them).
        XCTAssertEqual(ProxyList.replacements(for: dead, among: all, count: 10, country: "DE", used: used).count, 3)
        // Where the profiles came out is not known: free before used, the faster first.
        XCTAssertEqual(names(ProxyList.replacements(for: dead, among: all, count: 3, country: nil, used: used)),
                       ["Free US", "Free DE", "Used DE"])
    }

    func testTheCountryMostProfilesCameOutIn() {
        XCTAssertEqual(ProxyList.commonCountry(["de", "US", "DE", "us", "de"]), "DE")
        XCTAssertEqual(ProxyList.commonCountry(["US", "DE"]), "DE", "of two as common, the same one every time")
        XCTAssertEqual(ProxyList.commonCountry(["", "nl"]), "NL")
        XCTAssertNil(ProxyList.commonCountry([]))
    }

    func testNoReplacementIsOfferedWhenNothingAnswers() {
        let dead = entry("Dead", alive: false)
        XCTAssertEqual(ProxyList.replacements(for: dead, among: [dead, entry("Also dead", alive: false), entry("New")],
                                              count: 2, country: "DE", used: []), [])
        // A working proxy asked about itself is not its own replacement.
        let only = entry("Only", alive: true, country: "DE")
        XCTAssertEqual(ProxyList.replacements(for: only, among: [only], count: 1, country: "DE", used: []), [])
    }
}
