import XCTest
@testable import BrowserCore

/// The proxy manager's model: a pasted list read (the four forms providers sell proxies in, the
/// type unknown until a check without a scheme), the type a check found taken by the entry, the
/// profiles' own proxies taken into the list once, an edited entry followed by the profiles that use
/// it, and the list written out and read back.
final class ProxyManagerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-proxy-manager-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Reading a pasted list

    func testTheFourFormsProvidersSellProxiesIn() {
        let report = ProxyListImport.read("""
            203.0.113.5:8000:alice:s3cret
            bob:pw@proxy.example.com:3128
            socks5://carol:c@t@198.51.100.7:1080
            http://dave:d@h.example:8080
            gw.example:9000
            [2001:db8::1]:1083
            """)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.proxies.map(\.proxy.host), ["203.0.113.5", "proxy.example.com", "198.51.100.7", "h.example", "gw.example", "2001:db8::1"])
        XCTAssertEqual(report.proxies.map(\.proxy.port), [8000, 3128, 1080, 8080, 9000, 1083])
        XCTAssertEqual(report.proxies.map(\.proxy.username), ["alice", "bob", "carol", "dave", nil, nil])
        XCTAssertEqual(report.proxies.map(\.proxy.password), ["s3cret", "pw", "c@t", "d", nil, nil])
        // A scheme says the type; without one it is found by checking.
        XCTAssertEqual(report.proxies.map(\.kindGiven), [false, false, true, true, false, false])
        XCTAssertEqual(report.proxies[2].proxy.kind, .socks5)
        XCTAssertEqual(report.proxies[3].proxy.kind, .httpConnect)
        // A type chosen for the import is given to the lines without a scheme.
        let chosen = ProxyListImport.read("203.0.113.5:8000:alice:s3cret\nsocks5://h.example:1", defaultKind: .httpConnect)
        XCTAssertEqual(chosen.proxies.map(\.kindGiven), [true, true])
        XCTAssertEqual(chosen.proxies.map(\.proxy.kind), [.httpConnect, .socks5])
    }

    func testGarbagePortsOutOfRangeAndBadIPv6AreReportedByLine() {
        let report = ProxyListImport.read("""
            h.example:0
            h.example:65536
            h.example:65535
            [2001:db8::1]:70000
            [2001:db8::1:1080
            2001:db8::1:1080:user:pass
            not a proxy at all
            ftp://h.example:21
            """)
        XCTAssertEqual(report.proxies.map(\.line), [3])
        XCTAssertEqual(report.problems.map(\.line), [1, 2, 4, 5, 6, 7, 8])
        XCTAssertEqual(report.problems.map(\.reason), [
            .unreadable(.invalidPort("0")),
            .unreadable(.invalidPort("65536")),
            .unreadable(.invalidPort("70000")),
            .unreadable(.unterminatedIPv6),
            // An IPv6 address with a port and a login has to be in brackets: without them it is no host.
            .unreadable(.notAHost("2001:db8::1:1080:user:pass")),
            .unreadable(.containsWhitespace),
            .unreadable(.unsupportedScheme("ftp")),
        ])
    }

    // MARK: The type a check finds

    private func diagnosis(_ kinds: [ProxySettings.Kind]) -> ProxyCheckResult {
        ProxyCheckResult(diagnosis: ProxyDiagnosis(verdict: kinds.isEmpty ? .silent : .works, kinds: kinds))
    }

    func testTheEntryTakesTheTypeACheckFound() {
        var list = ProxyList()
        let ids = list.add(ProxyListImport.read("h1.example:1\nsocks5://h2.example:2\nhttp://h3.example:3\nh4.example:4").proxies).added
        XCTAssertEqual(list.entries.map(\.kindKnown), [false, true, true, false])
        XCTAssertNil(list.entries[0].usableProxy, "an entry of unknown type is no profile's proxy yet")

        // Unknown, found HTTP.
        let before = list.record(diagnosis([.httpConnect]), for: ids[0])
        XCTAssertEqual(before?.kind, .socks5, "the placeholder it had")
        XCTAssertEqual(list.entries[0].proxy.kind, .httpConnect)
        XCTAssertTrue(list.entries[0].kindKnown)
        XCTAssertEqual(list.entries[0].lastCheck?.kindFinding, .found)
        // Listed SOCKS5, answers only as HTTP: corrected.
        XCTAssertNotNil(list.record(diagnosis([.httpConnect]), for: ids[1]))
        XCTAssertEqual(list.entries[1].proxy.kind, .httpConnect)
        XCTAssertEqual(list.entries[1].lastCheck?.kindFinding, .corrected(from: .socks5))
        // Listed HTTP, answers both ways: its type stays.
        XCTAssertNil(list.record(diagnosis([.socks5, .httpConnect]), for: ids[2]))
        XCTAssertEqual(list.entries[2].proxy.kind, .httpConnect)
        XCTAssertNil(list.entries[2].lastCheck?.kindFinding)
        // Nothing answered: nothing is learnt about the type.
        XCTAssertNil(list.record(diagnosis([]), for: ids[3]))
        XCTAssertFalse(list.entries[3].kindKnown)
    }

    // MARK: The profiles' own proxies

    func testTheProfilesProxiesAreTakenInOnceWithoutTheirBypassLists() throws {
        var list = ProxyList()
        list.add(ProxyListImport.read("socks5://u:p@listed.example:1080").proxies)
        var own = ProxySettings(kind: .httpConnect, host: "own.example", port: 3128, username: "me", password: "pw")
        own.excludedDomains = ["intranet.example"]
        let listedWithOtherPassword = ProxySettings(kind: .socks5, host: "LISTED.example", port: 1080, username: "u", password: "new")
        let added = list.takeIn(profileProxies: [own, listedWithOtherPassword, own])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(list.entries.count, 2)
        XCTAssertEqual(list.entry(for: own)?.proxy.excludedDomains, [])
        XCTAssertTrue(list.entry(for: own)?.kindKnown == true)
        XCTAssertEqual(list.entry(for: listedWithOtherPassword)?.id, list.entries[0].id, "the same host, port and user")
        XCTAssertTrue(list.profilesTakenIn)
        // Once: a proxy removed from the list afterwards does not come back.
        list.remove([list.entries[1].id])
        XCTAssertEqual(list.takeIn(profileProxies: [own]), [])
        XCTAssertEqual(list.entries.count, 1)
        // Kept across a save.
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        try list.save(to: vault)
        XCTAssertTrue(try ProxyList.load(from: vault).profilesTakenIn)
    }

    func testAnEditedEntryIsFollowedByTheProfilesThatUseIt() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        var used = ProxySettings(kind: .socks5, host: "gw.example", port: 9000, username: "u", password: "old")
        used.excludedDomains = ["intranet.example"]
        let a = try repository.create(name: "A", configuration: ProfileConfiguration(proxy: used))
        // The same proxy typed into B in another case, and another proxy in C.
        let b = try repository.create(name: "B", configuration: ProfileConfiguration(proxy: ProxySettings(
            kind: .socks5, host: "GW.example", port: 9000, username: "u", password: "old")))
        let c = try repository.create(name: "C", configuration: ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "other.example", port: 1)))
        let d = try repository.create(name: "D", configuration: ProfileConfiguration())

        var list = ProxyList()
        list.takeIn(profileProxies: repository.profileProxies())
        XCTAssertEqual(list.entries.count, 2)
        let entry = try XCTUnwrap(list.entry(for: used))
        // A new password and type for that proxy, in the list.
        var changed = entry.proxy
        changed.password = "new"
        changed.kind = .httpConnect
        let previous = try list.update(entry.id, label: "Gateway", proxy: changed)
        let outcome = repository.follow(try XCTUnwrap(list.entry(entry.id)), previous: previous)
        XCTAssertEqual(Set(outcome.changed), [a.id, b.id])
        XCTAssertEqual(outcome.failed, [:])
        let savedA = try XCTUnwrap(repository.loadConfiguration(a.id).proxy)
        XCTAssertEqual(savedA.password, "new")
        XCTAssertEqual(savedA.kind, .httpConnect)
        XCTAssertEqual(savedA.excludedDomains, ["intranet.example"], "the profile's own bypass list stays")
        XCTAssertEqual(try repository.loadConfiguration(b.id).proxy?.password, "new")
        XCTAssertEqual(try repository.loadConfiguration(c.id).proxy?.host, "other.example")
        XCTAssertNil(try repository.loadConfiguration(d.id).proxy)
        // Followed again: nothing to change.
        XCTAssertEqual(Set(repository.follow(try XCTUnwrap(list.entry(entry.id)), previous: changed).unchanged), [a.id, b.id])
    }

    func testEditingAnEntry() throws {
        var list = ProxyList()
        let ids = list.add(ProxyListImport.read("socks5://u:p@a.example:1\nsocks5://u:p@b.example:2").proxies).added
        list.record(ProxyCheckResult(exitIP: "203.0.113.9"), for: ids[0])
        // The label alone: the check stays.
        try list.update(ids[0], label: "  Berlin ", proxy: list.entries[0].proxy)
        XCTAssertEqual(list.entries[0].label, "Berlin")
        XCTAssertEqual(list.entries[0].lastCheck?.exitIP, "203.0.113.9")
        // Another password: the check was about the old one.
        var changed = list.entries[0].proxy
        changed.password = "q"
        try list.update(ids[0], label: "Berlin", proxy: changed)
        XCTAssertNil(list.entries[0].lastCheck)
        // Not into another entry's proxy, not into something invalid.
        XCTAssertThrowsError(try list.update(ids[0], label: "", proxy: list.entries[1].proxy)) { error in
            XCTAssertEqual(error as? ProxyList.EditProblem, .alreadyListed(ids[1]))
        }
        XCTAssertThrowsError(try list.update(ids[0], label: "", proxy: ProxySettings(kind: .socks5, host: "bad host", port: 1))) { error in
            guard case .invalid? = error as? ProxyList.EditProblem else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try list.update(UUID(), label: "", proxy: changed))
    }

    func testAnEntryOfUnknownTypeIsGivenToNoProfile() throws {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        let profile = try repository.create(name: "A", configuration: ProfileConfiguration())
        var list = ProxyList()
        list.add(ProxyListImport.read("h.example:1080").proxies)
        let outcome = repository.assign([ProxyAssignment(profileID: profile.id, entry: list.entries[0])])
        XCTAssertEqual(Array(outcome.failed.keys), [profile.id])
        XCTAssertNil(try repository.loadConfiguration(profile.id).proxy)
    }

    // MARK: Writing the list out

    func testTheExportedListReadsBackAsItWas() {
        var list = ProxyList()
        list.add([
            ProxyListImport.Line(line: 1, proxy: ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080, username: "al:ice",
                                                               password: "p@ss #1 %x"), label: "Berlin # 1"),
            ProxyListImport.Line(line: 2, proxy: ProxySettings(kind: .httpConnect, host: "2001:db8::1", port: 3128)),
            ProxyListImport.Line(line: 3, proxy: ProxySettings(kind: .httpConnect, host: "tls.example", port: 443, username: "u",
                                                               password: "p", tlsToProxy: true)),
            ProxyListImport.Line(line: 4, proxy: ProxySettings(kind: .socks5, host: "gw.example", port: 9000, username: "u", password: "p"),
                                 kindGiven: false),
        ])
        let text = ProxyList.exportText(list.entries)
        XCTAssertTrue(text.hasPrefix("# "), "it says, first, that passwords are in plaintext")
        XCTAssertTrue(text.contains("[2001:db8::1]:3128"))
        let read = ProxyListImport.read(text)
        XCTAssertEqual(read.problems, [])
        XCTAssertEqual(read.proxies.map(\.proxy), list.entries.map(\.proxy))
        XCTAssertEqual(read.proxies.map(\.label), ["Berlin # 1", "", "", ""])
        XCTAssertEqual(read.proxies.map(\.kindGiven), [true, true, true, false])
    }

    // MARK: What the check keeps

    func testCheckResultsOfEarlierBuildsStillRead() throws {
        let earlier = Data(#"{"checkedAt":"2026-10-01T00:00:00Z","exitIP":"203.0.113.9","latencyMilliseconds":42}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(ProxyCheckResult.self, from: earlier)
        XCTAssertEqual(result.exitIP, "203.0.113.9")
        XCTAssertNil(result.diagnosis)
        XCTAssertTrue(result.isAlive)
        var full = result
        full.diagnosis = ProxyDiagnosis(verdict: .works, kinds: [.socks5], authentication: .accepted, latencies: [10, 30, 20], latencyAttempts: 3)
        full.city = "Berlin"
        full.asn = "AS64500"
        full.kindFinding = .corrected(from: .httpConnect)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ProxyCheckResult.self, from: encoder.encode(full)), full)
    }

    func testTheExitsCityAndNetworkFromEachService() {
        func parse(_ json: String, _ city: [String]?, _ asn: [String]?, _ organization: [String]?) -> ProxyExitDetails {
            ProxyExitDetails.parse(Data(json.utf8), cityKeyPath: city, asnKeyPath: asn, organizationKeyPath: organization)
        }
        // ipinfo.io
        XCTAssertEqual(parse(#"{"city":"Berlin","org":"AS13335 Cloudflare, Inc."}"#, ["city"], ["org"], ["org"]),
                       ProxyExitDetails(city: "Berlin", asn: "AS13335", organization: "Cloudflare, Inc."))
        // geojs
        XCTAssertEqual(parse(#"{"city":"Frankfurt am Main","asn":24940,"organization_name":"Hetzner Online GmbH"}"#,
                             ["city"], ["asn"], ["organization_name"]),
                       ProxyExitDetails(city: "Frankfurt am Main", asn: "AS24940", organization: "Hetzner Online GmbH"))
        // ipwho.is
        XCTAssertEqual(parse(#"{"city":"Tokyo","connection":{"asn":2516,"org":"KDDI"}}"#, ["city"], ["connection", "asn"], ["connection", "org"]),
                       ProxyExitDetails(city: "Tokyo", asn: "AS2516", organization: "KDDI"))
        // Missing, empty, or not JSON at all: nothing, never a guess.
        XCTAssertEqual(parse(#"{"city":""}"#, ["city"], ["org"], ["org"]), ProxyExitDetails())
        XCTAssertEqual(parse("not json", ["city"], nil, nil), ProxyExitDetails())
        XCTAssertEqual(ProxyExitDetails.splitASN("as64500").asn, "AS64500")
        XCTAssertNil(ProxyExitDetails.splitASN("as64500").rest)
        XCTAssertEqual(ProxyExitDetails.splitASN("Some ISP").asn, nil)
    }
}
