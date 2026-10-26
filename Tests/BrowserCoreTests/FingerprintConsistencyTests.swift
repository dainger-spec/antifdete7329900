import XCTest
@testable import BrowserCore

final class SafariUserAgentTests: XCTestCase {
    func testMacOSGenerationNamesTheHostSafari() {
        let mac = DeviceGenerations.resolved(id: DeviceGenerations.defaultID)
        XCTAssertEqual(mac.userAgent(hostSafariVersion: "26.0.1"),
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0.1 Safari/605.1.15")
        // Unknown or malformed host version: the catalog UA.
        XCTAssertEqual(mac.userAgent(hostSafariVersion: nil), mac.userAgent)
        XCTAssertEqual(mac.userAgent(hostSafariVersion: "26.0 beta"), mac.userAgent)
        // Mobile generations never take the Mac's Safari version.
        let ios = DeviceGenerations.resolved(id: "ios-26")
        XCTAssertEqual(ios.userAgent(hostSafariVersion: "18.6"), ios.userAgent)
    }

    func testSafariVersionFormat() {
        for good in ["26", "26.0", "26.0.1", "18.6", "17.4.1"] {
            XCTAssertTrue(DeviceGeneration.isSafariVersion(good), good)
        }
        for bad in ["", "26.", ".1", "26.0.1.2", "26a", "26 .0", "２６.0", "1234.0"] {
            XCTAssertFalse(DeviceGeneration.isSafariVersion(bad), bad)
        }
    }

    func testBundledSafariVersionByMacOS() {
        XCTAssertEqual(DeviceGenerations.bundledSafariVersion(macOSMajor: 14, minor: 4), "17.4")
        XCTAssertEqual(DeviceGenerations.bundledSafariVersion(macOSMajor: 14, minor: 7), "17.6")
        XCTAssertEqual(DeviceGenerations.bundledSafariVersion(macOSMajor: 15, minor: 0), "18.0")
        XCTAssertEqual(DeviceGenerations.bundledSafariVersion(macOSMajor: 15, minor: 7), "18.6")
        XCTAssertEqual(DeviceGenerations.bundledSafariVersion(macOSMajor: 26, minor: 1), "26.1")
        XCTAssertEqual(DeviceGenerations.bundledSafariVersion(macOSMajor: 27, minor: 0), "27.0")
    }

    func testAppliedUserAgentPrecedence() {
        // No generation stored (older profiles): the default macOS generation, not WebKit's bare
        // default without "Version/… Safari/…".
        XCTAssertTrue(ProfileConfiguration().userAgent(hostSafariVersion: "26.1").hasSuffix("Version/26.1 Safari/605.1.15"))
        XCTAssertEqual(ProfileConfiguration(userAgent: "Custom/1.0").userAgent(hostSafariVersion: "26.1"), "Custom/1.0")
        XCTAssertTrue(ProfileConfiguration(userAgent: "").userAgent(hostSafariVersion: "26.1").contains("Macintosh"))
        let ios = ProfileConfiguration(deviceGenerationID: "ios-27")
        XCTAssertEqual(ios.userAgent(hostSafariVersion: "26.1"), DeviceGenerations.generation(id: "ios-27")?.userAgent)
    }
}

final class ProxyLocationTests: XCTestCase {
    private let endpoint = "socks5://203.0.113.7:1080"

    func testParsesEachServiceFormat() {
        let ipinfo = #"{"ip":"203.0.113.7","city":"Frankfurt am Main","country":"DE","timezone":"Europe/Berlin"}"#
        let geojs = #"{"country_code":"de","timezone":"Europe/Berlin","ip":"203.0.113.7"}"#
        let ipwho = #"{"success":true,"country_code":"DE","timezone":{"id":"Europe/Berlin","utc":"+02:00"}}"#
        let a = ProxyLocation.parse(Data(ipinfo.utf8), timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"], proxyEndpoint: endpoint)
        let b = ProxyLocation.parse(Data(geojs.utf8), timeZoneKeyPath: ["timezone"], countryKeyPath: ["country_code"], proxyEndpoint: endpoint)
        let c = ProxyLocation.parse(Data(ipwho.utf8), timeZoneKeyPath: ["timezone", "id"], countryKeyPath: ["country_code"], proxyEndpoint: endpoint)
        for location in [a, b, c] {
            XCTAssertEqual(location?.timeZoneIdentifier, "Europe/Berlin")
            XCTAssertEqual(location?.countryCode, "DE")
            XCTAssertEqual(location?.webLanguage, "de-DE")
            XCTAssertEqual(location?.proxyEndpoint, endpoint)
        }
    }

    func testRejectsAnswersWithoutAUsableTimeZone() {
        for body in [#"{"timezone":"Mars/Olympus"}"#, #"{"timezone":"UTC"}"#, #"{"timezone":42}"#,
                     #"{"error":"rate limited"}"#, "<html>blocked</html>", ""] {
            XCTAssertNil(ProxyLocation.parse(Data(body.utf8), timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"],
                                             proxyEndpoint: endpoint), body)
        }
        // A bad country is dropped, the time zone kept.
        let odd = ProxyLocation.parse(Data(#"{"timezone":"Asia/Tokyo","country":"Japan"}"#.utf8), timeZoneKeyPath: ["timezone"],
                                      countryKeyPath: ["country"], proxyEndpoint: endpoint)
        XCTAssertEqual(odd?.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertNil(odd?.countryCode)
        XCTAssertEqual(odd?.webLanguage, "en-US")
    }

    func testWebLanguages() {
        func language(_ country: String?) -> String {
            ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: country, proxyEndpoint: endpoint).webLanguage
        }
        XCTAssertEqual(language("DE"), "de-DE")
        XCTAssertEqual(language("US"), "en-US")
        XCTAssertEqual(language("BR"), "pt-BR")
        XCTAssertEqual(language("JP"), "ja-JP")
        XCTAssertEqual(language("AQ"), "en-US") // unknown country
        XCTAssertEqual(language(nil), "en-US")
        for tag in ProxyLocation.webLanguages.values {
            XCTAssertNotNil(tag.range(of: #"^[a-z]{2}-[A-Z]{2}$"#, options: .regularExpression), tag)
        }
    }

    func testLaunchUsesLookupThenCacheOfTheSameProxy() {
        let proxy = ProxySettings(kind: .socks5, host: "203.0.113.7", port: 1080)
        let berlin = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE", proxyEndpoint: ProxyLocation.endpoint(of: proxy))
        let tokyo = ProxyLocation(timeZoneIdentifier: "Asia/Tokyo", countryCode: "JP", proxyEndpoint: ProxyLocation.endpoint(of: proxy))
        var config = ProfileConfiguration(proxy: proxy, lastProxyLocation: berlin)
        XCTAssertTrue(config.needsProxyLocation)
        XCTAssertEqual(config.proxyLocation(lookedUp: tokyo), tokyo)        // a fresh answer wins
        XCTAssertEqual(config.proxyLocation(lookedUp: nil), berlin)         // lookup failed: the last one
        XCTAssertEqual(config.applying(berlin).timeZoneIdentifier, "Europe/Berlin")

        // Another proxy: the stored location does not apply.
        config.proxy = ProxySettings(kind: .socks5, host: "198.51.100.1", port: 1080)
        XCTAssertNil(config.proxyLocation(lookedUp: nil))

        // An explicit time zone is kept; no proxy or matching off: nothing is looked up.
        config.timeZoneIdentifier = "America/New_York"
        XCTAssertEqual(config.applying(berlin).timeZoneIdentifier, "America/New_York")
        XCTAssertFalse(ProfileConfiguration().needsProxyLocation)
        XCTAssertFalse(ProfileConfiguration(proxy: proxy, matchProxyLocation: false).needsProxyLocation)
        XCTAssertNil(ProfileConfiguration(proxy: proxy, matchProxyLocation: false).applying(berlin).timeZoneIdentifier)
    }

    func testProxyLocationFieldsRoundTripAndDefaultOnForOldConfigs() throws {
        let legacy = #"{"ephemeral":false,"geolocation":{"deny":{}},"safeBrowsingEnabled":false,"webRTCPolicy":"disabled"}"#
        let old = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.matchProxyLocation)
        XCTAssertNil(old.lastProxyLocation)

        let proxy = ProxySettings(kind: .httpConnect, host: "proxy.example", port: 3128)
        let config = ProfileConfiguration(proxy: proxy, matchProxyLocation: false,
                                          lastProxyLocation: ProxyLocation(timeZoneIdentifier: "Europe/Paris", countryCode: "FR",
                                                                           proxyEndpoint: ProxyLocation.endpoint(of: proxy),
                                                                           resolvedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(config))
        XCTAssertEqual(decoded, config)

        // A stored location that no longer decodes is dropped instead of failing the profile.
        let broken = #"{"geolocation":{"deny":{}},"webRTCPolicy":"disabled","lastProxyLocation":{"timeZoneIdentifier":7}}"#
        XCTAssertNil(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(broken.utf8)).lastProxyLocation)
    }
}

final class ProxiedWebRTCTests: XCTestCase {
    /// WebKit's WebRTC sockets never use the data store's proxy: a proxied profile gets no WebRTC.
    func testAProxyTurnsWebRTCOffWithoutForgettingTheChoice() throws {
        let proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080)
        for policy in WebRTCPolicy.allCases {
            XCTAssertEqual(ProfileConfiguration(webRTCPolicy: policy).effectiveWebRTCPolicy, policy)
            var proxied = ProfileConfiguration(proxy: proxy, webRTCPolicy: policy)
            XCTAssertEqual(proxied.effectiveWebRTCPolicy, .disabled, policy.rawValue)
            // The stored choice is kept (and saved) for when the proxy is removed.
            let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(proxied))
            XCTAssertEqual(decoded.webRTCPolicy, policy)
            proxied.proxy = nil
            XCTAssertEqual(proxied.effectiveWebRTCPolicy, policy)
        }
    }

    /// With the packet tunnel's relay, a SOCKS5 profile's WebRTC goes through it (relay-only);
    /// an HTTP proxy cannot carry UDP, and "disabled" stays disabled. The relay is never stored.
    func testRoutingThroughTheTunnelRelay() throws {
        let relay = WebRTCRelay(urls: ["turn:192.0.2.10:3478?transport=udp"], username: "u", credential: "c")
        var socks = ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080), webRTCPolicy: .unrestricted)
        XCTAssertEqual(socks.webRTCRouting, .off)
        socks.webRTCRelay = relay
        XCTAssertEqual(socks.webRTCRouting, .relay(relay))
        XCTAssertEqual(socks.effectiveWebRTCPolicy, .relayOnly)
        var http = ProfileConfiguration(proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 8080), webRTCPolicy: .relayOnly)
        http.webRTCRelay = relay
        XCTAssertEqual(http.webRTCRouting, .off)
        var off = socks
        off.webRTCPolicy = .disabled
        XCTAssertEqual(off.webRTCRouting, .off)
        XCTAssertEqual(ProfileConfiguration(webRTCPolicy: .unrestricted).webRTCRouting, .native(.unrestricted))
        let json = String(decoding: try JSONCoding.encoder.encode(socks), as: UTF8.self)
        XCTAssertFalse(json.contains("turn:"), json)
        XCTAssertNil(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(json.utf8)).webRTCRelay)
    }

    /// Safari on iOS 26.1 and later freezes the OS token; an iPad shows desktop websites.
    func testMobileGenerationsSendWhatSafariSends() {
        for id in ["ios-26", "ios-27"] {
            let ua = DeviceGenerations.generation(id: id)?.userAgent ?? ""
            XCTAssertTrue(ua.hasPrefix("Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/"), ua)
            XCTAssertTrue(ua.hasSuffix(" Mobile/15E148 Safari/604.1"), ua)
        }
        let iPad = DeviceGenerations.generation(id: "ipados-26")?.userAgent ?? ""
        XCTAssertTrue(iPad.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26."), iPad)
        XCTAssertTrue(iPad.hasSuffix(" Safari/605.1.15"), iPad)
    }
}
