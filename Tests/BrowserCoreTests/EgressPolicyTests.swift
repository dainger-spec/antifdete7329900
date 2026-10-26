import XCTest
@testable import BrowserCore

final class EgressPolicyTests: XCTestCase {
    private let socks = ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080)
    private let http = ProxySettings(kind: .httpConnect, host: "203.0.113.9", port: 8080)

    // MARK: Egress decision table

    func testNoProxyNoTunnelIsDirect() {
        let net = ProfileNetwork()
        XCTAssertEqual(net.egress(tunnelAvailable: false), .direct)
        XCTAssertEqual(net.egress(tunnelAvailable: true), .direct)
    }

    func testProxyWithoutTunnelIsTCPOnly() {
        let net = ProfileNetwork(proxy: socks)
        let egress = net.egress(tunnelAvailable: true)
        XCTAssertEqual(egress, .proxyTCPOnly(socks))
        // This is the whole reason the feature exists: UDP is not covered, WebRTC may leak.
        XCTAssertFalse(egress!.coversUDP)
        XCTAssertTrue(egress!.webRTCMayLeakRealIP)
    }

    func testTunnelFailsClosedWhenUnavailable() {
        // Requested but the packet tunnel can't run: no network, never a fallback.
        XCTAssertNil(ProfileNetwork(proxy: socks, unifiedTunnel: true).egress(tunnelAvailable: false))
        XCTAssertNil(ProfileNetwork(unifiedTunnel: true).egress(tunnelAvailable: false))
    }

    func testTunnelThroughSOCKSCarriesUDP() {
        let egress = ProfileNetwork(proxy: socks, unifiedTunnel: true).egress(tunnelAvailable: true)
        XCTAssertEqual(egress, .tunnel(.proxy(socks, udp: .throughProxy)))
        XCTAssertTrue(egress!.coversUDP)
        XCTAssertFalse(egress!.webRTCMayLeakRealIP)
    }

    func testTunnelThroughHTTPProxyDropsUDP() {
        // HTTP CONNECT can't carry UDP; the tunnel drops it rather than leak. Still covered.
        let egress = ProfileNetwork(proxy: http, unifiedTunnel: true).egress(tunnelAvailable: true)
        XCTAssertEqual(egress, .tunnel(.proxy(http, udp: .dropped)))
        XCTAssertTrue(egress!.coversUDP)
        XCTAssertFalse(egress!.webRTCMayLeakRealIP)
    }

    func testTunnelThroughTLSSOCKSDropsUDP() {
        var tlsSocks = socks
        tlsSocks.tlsToProxy = true // we don't claim UDP ASSOCIATE over a TLS-wrapped SOCKS link
        let egress = ProfileNetwork(proxy: tlsSocks, unifiedTunnel: true).egress(tunnelAvailable: true)
        XCTAssertEqual(egress, .tunnel(.proxy(tlsSocks, udp: .dropped)))
    }

    func testTunnelWithoutProxyUsesDirectInterface() {
        let egress = ProfileNetwork(unifiedTunnel: true).egress(tunnelAvailable: true)
        XCTAssertEqual(egress, .tunnel(.directInterface))
        XCTAssertTrue(egress!.coversUDP) // captured and consistent, even though the exit is this Mac
    }

    func testDirectEgressWebRTCDoesNotLeakThroughAProxy() {
        // With no proxy there is nothing to leak around: the real IP is the expected IP.
        XCTAssertFalse(ProfileEgress.direct.webRTCMayLeakRealIP)
    }

    // MARK: TunnelConfiguration round trip

    func testTunnelConfigFromNonTunnelEgressIsNil() {
        XCTAssertNil(TunnelConfiguration(egress: .direct, profileID: UUID()))
        XCTAssertNil(TunnelConfiguration(egress: .proxyTCPOnly(socks), profileID: UUID()))
    }

    func testTunnelConfigProxyRoundTrip() {
        let id = UUID()
        let config = TunnelConfiguration(egress: .tunnel(.proxy(socks, udp: .throughProxy)), profileID: id)
        XCTAssertNotNil(config)
        let restored = TunnelConfiguration(dictionary: config!.dictionary)
        XCTAssertEqual(restored, config)
        XCTAssertEqual(restored?.profileID, id)
        if case .proxy(let host, let port, let kind, let tls, let user) = restored?.exit {
            XCTAssertEqual(host, "203.0.113.5")
            XCTAssertEqual(port, 1080)
            XCTAssertEqual(kind, .socks5)
            XCTAssertFalse(tls)
            XCTAssertNil(user)
        } else {
            XCTFail("expected a proxy exit")
        }
        XCTAssertEqual(restored?.udp, .throughProxy)
    }

    func testTunnelConfigCarriesUsernameButNeverPassword() {
        let withAuth = ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080,
                                     username: "u", password: "secret")
        let config = TunnelConfiguration(egress: .tunnel(.proxy(withAuth, udp: .throughProxy)), profileID: UUID())!
        // The password must never travel in the provider dictionary; it goes in the keychain.
        XCTAssertFalse(config.dictionary.values.contains("secret"))
        XCTAssertEqual(config.dictionary[TunnelConfiguration.Key.username], "u")
        XCTAssertFalse(config.summary.contains("secret"))
    }

    func testTunnelConfigDirectInterfaceRoundTrip() {
        let config = TunnelConfiguration(egress: .tunnel(.directInterface), profileID: UUID())!
        let restored = TunnelConfiguration(dictionary: config.dictionary)
        XCTAssertEqual(restored?.exit, .directInterface)
    }

    func testTunnelConfigRejectsBadDictionary() {
        XCTAssertNil(TunnelConfiguration(dictionary: [:]))
        XCTAssertNil(TunnelConfiguration(dictionary: ["profileID": "not-a-uuid", "udp": "dropped", "exitKind": "direct"]))
        XCTAssertNil(TunnelConfiguration(dictionary: ["profileID": UUID().uuidString, "udp": "dropped",
                                                      "exitKind": "proxy", "host": "h", "port": "99999", "proxyKind": "socks5"]))
    }

    // MARK: Persistence

    func testUnifiedTunnelDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(ProfileConfiguration().unifiedTunnel)
        var config = ProfileConfiguration(proxy: socks)
        config.unifiedTunnel = true
        let data = try JSONCoding.encoder.encode(config)
        XCTAssertEqual(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: data).unifiedTunnel, true)
    }

    func testOldConfigWithoutTunnelFieldDecodesOff() throws {
        // A config written before the field existed (just a proxy) must decode with the tunnel off.
        let json = #"{"proxy":{"kind":"socks5","host":"203.0.113.5","port":1080,"tlsToProxy":false,"excludedDomains":[]},"geolocation":{"deny":{}},"webRTCPolicy":"disabled","ephemeral":false,"safeBrowsingEnabled":false,"historyEnabled":true,"userAgentMode":"safariMac"}"#
        let config = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(config.unifiedTunnel)
        XCTAssertEqual(config.network.egress(tunnelAvailable: true), .proxyTCPOnly(socks))
    }
}

final class TunnelCoordinatorTests: XCTestCase {
    func testFirstProfileMayStart() {
        var c = TunnelCoordinator()
        let a = UUID()
        XCTAssertNil(c.canStart(a))
        c.started(a)
        XCTAssertEqual(c.activeProfile, a)
    }

    func testSecondTunnelIsRefusedWhileFirstIsUp() {
        var c = TunnelCoordinator()
        let a = UUID(), b = UUID()
        c.started(a)
        XCTAssertEqual(c.canStart(b), .anotherTunnelActive(a))
        // The same profile re-starting (e.g. relaunch) is fine.
        XCTAssertNil(c.canStart(a))
    }

    func testStoppingFreesTheTunnel() {
        var c = TunnelCoordinator()
        let a = UUID(), b = UUID()
        c.started(a)
        c.stopped(b) // not the active one: no effect
        XCTAssertEqual(c.activeProfile, a)
        c.stopped(a)
        XCTAssertNil(c.activeProfile)
        XCTAssertNil(c.canStart(b))
    }
}
