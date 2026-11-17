import XCTest
@testable import BrowserCore

/// The two kinds of proxy a relay of the app's carries — a share link's (Xray) and an OpenVPN
/// connection — as one: which relay a proxy needs (`ProxySettings.localRelay`), how its route is
/// known and handed over (`ProxyRoutes`), and the one format rule that keeps both from 0.1.17 and
/// earlier while every other profile stays readable there (docs/UPDATES.md §4).
final class LocalRelayTests: XCTestCase {
    private func link() throws -> ProxySettings { try ProxySettings(shareLink: XrayLinkProxyTests.reality) }

    private func vpn(username: String? = "alice", password: String? = "s3cret", _ extra: String = "auth-user-pass") throws -> ProxySettings {
        ProxySettings.openVPN(try OpenVPNConfiguration.parse(OpenVPNConfigurationTests.typical(extra)), username: username, password: password)
    }

    private var plain: [ProxySettings] {
        [ProxySettings(kind: .socks5, host: "1.2.3.4", port: 1080, username: "u", password: "p"),
         ProxySettings(kind: .httpConnect, host: "proxy.example.net", port: 8080, tlsToProxy: true)]
    }

    /// No proxy, and every proxy reached as it is.
    private var unrelayed: [ProxySettings?] {
        var all: [ProxySettings?] = [nil]
        for proxy in plain { all.append(proxy) }
        return all
    }

    // MARK: Which relay

    func testEachProxySaysWhichRelayItNeeds() throws {
        for proxy in plain { XCTAssertNil(proxy.localRelay, "\(proxy.kind) is reached as it is") }
        XCTAssertEqual(try link().localRelay, .xray)
        let openVPN = try vpn()
        XCTAssertEqual(openVPN.localRelay, .openVPN)
        XCTAssertEqual(openVPN.kind, .socks5, "an OpenVPN connection is given to a profile as SOCKS5")
    }

    // MARK: The one format rule

    /// `config.bin`: 2 for either relay's proxy, refused by a version that reads 1 (0.1.17 and
    /// earlier); any other profile written as before, with no format at all, which they read.
    func testTheSettingsOfAProfileOnEitherRelayAreFormat2AndOthersAsBefore() throws {
        var configuration = ProfileConfiguration()
        for proxy in unrelayed {
            configuration.proxy = proxy
            let data = try JSONCoding.encoder.encode(configuration)
            XCTAssertEqual(configuration.format, 1)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"format\""), "written as 0.1.17 reads it")
            XCTAssertNoThrow(try DocumentFormat.check(data, supported: 1, what: "config.bin"))
        }
        for proxy in [try link(), try vpn()] {
            configuration.proxy = proxy
            let data = try JSONCoding.encoder.encode(configuration)
            XCTAssertEqual(DocumentFormat.declared(in: data), 2)
            XCTAssertThrowsError(try DocumentFormat.check(data, supported: 1, what: "config.bin")) { error in
                guard case CoreError.newerFormat = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try ProfileRepository.decodeConfiguration(data).proxy, proxy)
        }
        XCTAssertEqual(ProfileRepository.configurationFormat, 2, "one bump for the two")
    }

    /// `proxies.bin`: 4 once it holds either, refused by a version that reads 3 (0.1.17); a list
    /// without one is written in the format it had before.
    func testAListWithEitherRelaysProxyIsFormat4AndOthersAsBefore() throws {
        let plainEntries = plain.map { ProxyListEntry(proxy: $0) }
        XCTAssertEqual(ProxyList.format(for: plainEntries), 1)
        var ipChange = ProxyListEntry(proxy: plain[0])
        ipChange.changeIPURL = URL(string: "https://provider.example/change?key=1")
        XCTAssertEqual(ProxyList.format(for: plainEntries + [ipChange]), 3)
        for proxy in [try link(), try vpn()] {
            let entries = plainEntries + [ProxyListEntry(proxy: proxy)]
            XCTAssertEqual(ProxyList.format(for: entries), 4)
            let data = try JSONCoding.encoder.encode(ProxyList(entries: entries))
            XCTAssertEqual(DocumentFormat.declared(in: data), 4)
            XCTAssertThrowsError(try DocumentFormat.check(data, supported: 3, what: "proxies.bin"))
            XCTAssertNoThrow(try DocumentFormat.check(data, supported: ProxyList.supportedFormat, what: "proxies.bin"))
        }
        XCTAssertEqual(ProxyList.supportedFormat, 4, "one bump for the two")
    }

    /// A profile export (`.pbprofile`): 4 for either, 2 (3 with a one-time code) otherwise.
    func testTheExportOfAProfileOnEitherRelayIsFormat4AndOthersAsBefore() throws {
        var configuration = ProfileConfiguration()
        let documents = ProfileTransfer.Documents(passwords: [], history: nil, bookmarks: nil, warmUpPlan: nil)
        for proxy in unrelayed {
            configuration.proxy = proxy
            XCTAssertEqual(ProfileTransfer.exportFormat(configuration: configuration, documents: documents), 2)
        }
        for proxy in [try link(), try vpn()] {
            configuration.proxy = proxy
            XCTAssertEqual(ProfileTransfer.exportFormat(configuration: configuration, documents: documents), 4)
        }
        XCTAssertEqual(ProfileTransfer.format, 4, "one bump for the two")
    }

    // MARK: Routes

    /// An OpenVPN connection is reached through its tunnel's route alone, as a link is through its
    /// relay's — never the VPN server as if it were a SOCKS5 proxy.
    func testAnOpenVPNConnectionIsReachedThroughItsRelayOrNotAtAll() throws {
        let routes = ProxyRoutes()
        var proxy = try vpn()
        proxy.excludedDomains = ["intranet.example"]
        XCTAssertNil(routes.connectable(proxy), "no tunnel: nothing to connect to, never the VPN server")
        let key = try XCTUnwrap(ProxyRoutes.key(of: proxy))
        let id = UUID()
        routes.add(ProxyRoutes.Route(port: 41000, username: "lumen-ab", password: "cd"), for: key, id: id)
        XCTAssertEqual(routes.connectable(proxy),
                       ProxySettings(kind: .socks5, host: "127.0.0.1", port: 41000, username: "lumen-ab", password: "cd",
                                     excludedDomains: ["intranet.example"]))
        XCTAssertNil(routes.connectable(proxy)?.localRelay, "what is connected to is a plain SOCKS5 proxy")
        routes.remove(id: id)
        XCTAssertNil(routes.connectable(proxy))
    }

    /// Another configuration or another login is another relay's route; the key says neither in
    /// clear (it travels to the profile's process).
    func testAnOpenVPNRouteIsKnownByItsConfigurationAndLogin() throws {
        let proxy = try vpn()
        let key = try XCTUnwrap(ProxyRoutes.key(of: proxy))
        XCTAssertTrue(key.hasPrefix("openvpn:"))
        XCTAssertFalse(key.contains("s3cret"))
        XCTAssertFalse(key.contains("alice"))
        XCTAssertFalse(key.contains("BEGIN"))
        XCTAssertEqual(ProxyRoutes.key(of: try vpn()), key)
        XCTAssertNotEqual(ProxyRoutes.key(of: try vpn(password: "other")), key)
        XCTAssertNotEqual(ProxyRoutes.key(of: try vpn(username: "bob")), key)
        XCTAssertNotEqual(ProxyRoutes.key(of: try vpn("auth-user-pass\nauth-nocache")), key)
        // The bypass list is the profile's, not the relay's.
        var bypassing = proxy
        bypassing.excludedDomains = ["intranet.example"]
        XCTAssertEqual(ProxyRoutes.key(of: bypassing), key)
        XCTAssertEqual(ProxyRoutes.key(of: try link()), try link().link)
        for proxy in plain { XCTAssertNil(ProxyRoutes.key(of: proxy)) }
    }

    /// The record a profile's process is given carries either relay's route the same way.
    func testTheRecordCarriesEitherRelaysRoute() throws {
        let routes = [try XCTUnwrap(ProxyRoutes.key(of: try vpn())): ProxyRoutes.Route(port: 41000, username: "lumen-ab", password: "cd"),
                      try XCTUnwrap(try link().link): ProxyRoutes.Route(port: 41001, username: "u", password: "p")]
        let record = try ProxyRoutes.encodeRecord(routes)
        XCTAssertEqual(try ProxyRoutes.readRecord(XrayLinkProxyTests.reader(record)), routes)
    }

    func testTheProbeAsksNoOpenVPNServerWithoutItsTunnel() throws {
        let diagnosis = ProxyProbe(targetHost: "example.com").runNow(try vpn())
        XCTAssertEqual(diagnosis.verdict, .relayNotStarted)
        XCTAssertFalse(diagnosis.isWorking)
    }

    // MARK: Where it exits

    /// An OpenVPN connection's place is its server, login and configuration — not the tunnel's port,
    /// another at every launch — so what was found last time is kept for the next.
    func testWhereAnOpenVPNConnectionExitsIsKeyedByItsServerNeverByItsTunnel() throws {
        let proxy = try vpn()
        let endpoint = ProxyLocation.endpoint(of: proxy)
        XCTAssertTrue(endpoint.hasPrefix("socks5://vpn.example.net:1194#"))
        XCTAssertEqual(ProxyLocation.endpoint(of: try vpn()), endpoint)
        XCTAssertNotEqual(ProxyLocation.endpoint(of: try vpn("auth-user-pass\nauth-nocache")), endpoint)
        XCTAssertNotEqual(ProxyLocation.endpoint(of: try vpn(password: "other")), endpoint)
        XCTAssertFalse(endpoint.contains("s3cret"))
        // Without a login it is still told apart from a SOCKS5 proxy at the same address.
        let anonymous = try vpn(username: nil, password: nil, "")
        XCTAssertNotEqual(ProxyLocation.endpoint(of: anonymous), "socks5://vpn.example.net:1194")
    }

    /// The automation API names an OpenVPN connection as one, by its first server, never its login.
    func testTheAutomationAPINamesAnOpenVPNConnectionAsOne() throws {
        let summary = ProfileSummary(id: UUID(), name: "P", createdAt: Date(), lastLaunchedAt: nil, revision: 0)
        let row = AutomationProfiles.Entry(summary, running: false, busy: false, proxy: try vpn())
        XCTAssertEqual(row.proxy, "openvpn://vpn.example.net:1194")
        let plainRow = AutomationProfiles.Entry(summary, running: false, busy: false, proxy: plain[0])
        XCTAssertEqual(plainRow.proxy, "socks5://1.2.3.4:1080")
    }

    /// WebRTC through an OpenVPN connection goes as through the SOCKS5 proxy its tunnel is, with UDP.
    func testTheGateTreatsAnOpenVPNConnectionAsTheSOCKS5ProxyItsTunnelIs() throws {
        let proxy = try vpn()
        XCTAssertTrue(proxy.carriesUDP)
        XCTAssertTrue(WebRTCGate.wantsRelay(policy: .unrestricted, proxy: proxy))
        XCTAssertEqual(WebRTCGate.decide(policy: .unrestricted, proxy: proxy, ownProcess: true, guardState: .ready, udp: .supported), .relay)
    }
}
