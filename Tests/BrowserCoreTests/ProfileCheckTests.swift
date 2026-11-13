import XCTest
@testable import BrowserCore

/// The profile's check: what a page says next to where the profile leaves for the internet, each
/// mismatch a finding, and each fix a change of the settings that takes the finding away.
final class ProfileCheckTests: XCTestCase {
    private let host = "26.6.2"
    private let safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Safari/605.1.15"
    private let winter = Date(timeIntervalSince1970: 1_768_000_000) // January: no summer time anywhere north

    private func berlin() -> ProxyLocation {
        ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE", proxyEndpoint: "socks5://127.0.0.1:1080", exitIP: "203.0.113.7")
    }

    private func proxied() -> ProfileConfiguration {
        ProfileConfiguration(proxy: ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080))
    }

    /// A profile as it should be: a German exit, pages in Berlin's time and in German, this Mac's Safari.
    private func facts(_ configuration: ProfileConfiguration? = nil) -> ProfileCheck.Facts {
        var facts = ProfileCheck.Facts(configuration: configuration ?? proxied(), hostSafariVersion: host, webRTC: .off)
        facts.page = ProfileCheck.Page(timeZone: "Europe/Berlin", language: "de-DE", userAgent: safari,
                                       screen: .init(width: 1512, height: 982), window: .init(width: 1280, height: 800))
        facts.exit = berlin()
        facts.exitCoordinate = .init(latitude: 52.52, longitude: 13.40)
        facts.lookupAnswered = true
        facts.network = .init()
        return facts
    }

    private func finding(_ topic: ProfileCheck.Topic, _ facts: ProfileCheck.Facts) -> ProfileCheck.Finding {
        ProfileCheck.findings(facts, now: winter).first { $0.topic == topic }!
    }

    func testAProfileInOrderHasNothingHeldAgainstIt() {
        let findings = ProfileCheck.findings(facts(), now: winter)
        XCTAssertEqual(findings.map(\.topic), ProfileCheck.Topic.allCases, "one finding a topic, in the order shown")
        XCTAssertEqual(ProfileCheck.attention(in: findings), 0, "\(findings.filter { $0.level != .ok })")
        XCTAssertEqual(findings.map(\.key), ["check.proxy.alive", "check.timeZone.matches", "check.language.matches",
                                             "check.geolocation.denied", "check.webRTC.off", "check.dns.throughProxy",
                                             "check.engine.same", "check.window.fits"])
        XCTAssertEqual(finding(.proxy, facts()).values, ["country:DE", "203.0.113.7"])
    }

    func testATimeZoneElsewhereIsFoundAndFixed() {
        var configuration = proxied()
        configuration.timeZoneIdentifier = "America/New_York"
        var checked = facts(configuration)
        checked.page?.timeZone = "America/New_York"
        let found = finding(.timeZone, checked)
        XCTAssertEqual(found.level, .attention)
        XCTAssertEqual(found.code, "differs")
        XCTAssertEqual(found.values, ["America/New_York", "Europe/Berlin"])
        XCTAssertEqual(found.fix, .timeZoneFromConnection)

        // The fix: the settings follow the connection again; the next start's pages are in Berlin.
        let fixed = ProfileCheck.applying(.timeZoneFromConnection, to: configuration)
        XCTAssertNil(fixed.timeZoneIdentifier)
        XCTAssertTrue(fixed.matchProxyLocation)
        XCTAssertEqual(fixed.effectiveLocaleSource, .connection)
        var after = facts(fixed)
        after.page?.timeZone = "Europe/Berlin"
        XCTAssertEqual(finding(.timeZone, after).level, .ok)

        // Another name of the same clock is the same to a page.
        var paris = facts()
        paris.page?.timeZone = "Europe/Paris"
        XCTAssertEqual(finding(.timeZone, paris).level, .ok)

        // Following the connection and still elsewhere: the exit moved; no setting to change.
        var stale = facts()
        stale.page?.timeZone = "Asia/Tokyo"
        XCTAssertEqual(finding(.timeZone, stale).code, "stale")
        XCTAssertNil(finding(.timeZone, stale).fix)
    }

    func testALanguageOfAnotherCountryIsFoundAndFixed() {
        var configuration = proxied()
        configuration.languageOverride = "ru-RU"
        var checked = facts(configuration)
        checked.page?.language = "ru-RU"
        let found = finding(.language, checked)
        XCTAssertEqual(found.level, .attention)
        XCTAssertEqual(found.values, ["ru-RU", "country:DE", "de-DE"])
        XCTAssertEqual(found.fix, .languageFromConnection)
        let fixed = ProfileCheck.applying(.languageFromConnection, to: configuration)
        XCTAssertNil(fixed.languageOverride)
        XCTAssertEqual(fixed.webLanguage(for: berlin()), "de-DE")

        // The same language of another country is that language.
        var austrian = facts()
        austrian.page?.language = "de-AT"
        XCTAssertEqual(finding(.language, austrian).level, .ok)
        // A country with no rule here is not judged.
        var unknown = facts()
        unknown.exit?.countryCode = "ZZ"
        XCTAssertEqual(finding(.language, unknown).level, .unknown)
    }

    func testAFixedPositionFarFromTheExit() {
        var configuration = proxied()
        configuration.geolocation = .fixed(latitude: 40.71, longitude: -74.0, accuracyMeters: 25) // New York
        let found = finding(.geolocation, facts(configuration))
        XCTAssertEqual(found.level, .attention)
        XCTAssertEqual(found.fix, .geolocationAtExit)
        XCTAssertEqual(Int(found.values[0]).map { (6300...6500).contains($0) }, true, "Berlin to New York is about 6400 km: \(found.values)")

        let fixed = ProfileCheck.applying(.geolocationAtExit, to: configuration, exit: .init(latitude: 52.52, longitude: 13.40))
        XCTAssertEqual(fixed.geolocation, .fixed(latitude: 52.52, longitude: 13.40, accuracyMeters: 25))
        XCTAssertEqual(finding(.geolocation, facts(fixed)).level, .ok)
        // Without the exit's place there is nothing to hold it against, and nothing to move it to.
        var nowhere = facts(configuration)
        nowhere.exitCoordinate = nil
        XCTAssertEqual(finding(.geolocation, nowhere).level, .unknown)
        XCTAssertEqual(ProfileCheck.applying(.geolocationAtExit, to: configuration), configuration)
    }

    func testTheUserAgentAgainstTheEngine() {
        XCTAssertEqual(ProfileCheck.safariVersion(inUserAgent: safari), "26.6")
        XCTAssertNil(ProfileCheck.safariVersion(inUserAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"))

        var old = facts()
        old.page?.userAgent = safari.replacingOccurrences(of: "Version/26.6", with: "Version/18.4")
        XCTAssertEqual(finding(.engine, old).code, "far")
        XCTAssertEqual(finding(.engine, old).fix, .safariOfThisMac)

        var near = facts()
        near.page?.userAgent = safari.replacingOccurrences(of: "Version/26.6", with: "Version/26.2")
        XCTAssertEqual(finding(.engine, near).level, .ok)

        var chrome = facts()
        chrome.page?.userAgent = "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
        XCTAssertEqual(finding(.engine, chrome).code, "notSafari")

        var configuration = proxied()
        configuration.userAgent = "typed"
        configuration.safariVersion = "18.4"
        let fixed = ProfileCheck.applying(.safariOfThisMac, to: configuration)
        XCTAssertNil(fixed.userAgent)
        XCTAssertNil(fixed.safariVersion)

        // An iPhone view is Safari of another device by design: not judged against this Mac's.
        var phone = facts()
        phone.isMobileView = true
        XCTAssertEqual(finding(.engine, phone).level, .unknown)
        XCTAssertEqual(finding(.window, phone).level, .unknown)
    }

    func testAWindowTheScreenCannotHold() {
        var configuration = proxied()
        configuration.windowSize = .custom(width: 2560, height: 1440)
        let found = finding(.window, facts(configuration))
        XCTAssertEqual(found.code, "cut")
        XCTAssertEqual(found.values, ["2560 × 1440", "1512 × 982"])
        XCTAssertEqual(found.fix, .windowOfTheApp)
        XCTAssertNil(ProfileCheck.applying(.windowOfTheApp, to: configuration).windowSize)

        var larger = facts()
        larger.page?.window = .init(width: 1600, height: 900)
        XCTAssertEqual(finding(.window, larger).code, "larger")
    }

    func testTheProxyAndTheNetwork() {
        var silent = facts()
        silent.exit = nil
        silent.lookupAnswered = false
        XCTAssertEqual(finding(.proxy, silent).key, "check.proxy.silent")
        XCTAssertEqual(finding(.timeZone, silent).level, .unknown, "nothing to compare with is not a mismatch")
        silent.proxyNeedsCredentials = true
        XCTAssertEqual(finding(.proxy, silent).key, "check.proxy.credentials")

        var leaking = facts()
        leaking.network = .init(webViewsWithWebRTC: 1, webViewsWithDNSPrefetch: 2, udpClosed: false)
        XCTAssertEqual(finding(.webRTC, leaking).key, "check.webRTC.onWhereOff")
        XCTAssertEqual(finding(.dns, leaking).key, "check.dns.prefetch")
        XCTAssertEqual(ProfileCheck.attention(in: ProfileCheck.findings(leaking, now: winter)), 2)

        // With no proxy the Mac's own address is the profile's: nothing leaks that is not shown.
        var direct = facts(ProfileConfiguration())
        direct.webRTC = .direct
        direct.exit = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE", proxyEndpoint: "direct", exitIP: "198.51.100.4")
        XCTAssertEqual(finding(.proxy, direct).key, "check.proxy.direct")
        XCTAssertEqual(finding(.webRTC, direct).key, "check.webRTC.directNoProxy")
        XCTAssertEqual(finding(.dns, direct).key, "check.dns.direct")
        XCTAssertEqual(ProfileCheck.attention(in: ProfileCheck.findings(direct, now: winter)), 0)
    }

    func testAPageFromASnapshotsValues() {
        let page = ProfileCheck.Page(snapshot: ["probe.timeZone": "Europe/Berlin", "probe.language": "de-DE", "probe.ua": safari,
                                                "geometry.screen": "1512x982x1512x944x0x38", "geometry.outer": "1280x800"])
        XCTAssertEqual(page, ProfileCheck.Page(timeZone: "Europe/Berlin", language: "de-DE", userAgent: safari,
                                               screen: .init(width: 1512, height: 982), window: .init(width: 1280, height: 800)))
        XCTAssertNil(ProfileCheck.Page(snapshot: [:]).screen)
    }

    func testThePlaceInAServicesAnswer() {
        func place(_ json: String) -> [Double]? {
            ProxyExitDetails.coordinates(in: Data(json.utf8)).map { [$0.latitude, $0.longitude] }
        }
        XCTAssertEqual(place(#"{"loc":"52.5200,13.4050"}"#), [52.52, 13.405])                       // ipinfo.io
        XCTAssertEqual(place(#"{"latitude":"50.1109","longitude":"8.6821"}"#), [50.1109, 8.6821])   // geojs.io
        XCTAssertEqual(place(#"{"latitude":35.6895,"longitude":139.6917}"#), [35.6895, 139.6917])   // ipwho.is, ipapi.co
        XCTAssertNil(place(#"{"latitude":0,"longitude":0}"#), "the middle of the ocean is a service's 'unknown'")
        XCTAssertNil(place(#"{"latitude":120,"longitude":10}"#))
        XCTAssertNil(place(#"{"city":"Berlin"}"#))
        XCTAssertEqual(ProxyExitDetails.parse(Data(#"{"city":"Berlin","loc":"52.52,13.40"}"#.utf8), cityKeyPath: ["city"],
                                              asnKeyPath: nil, organizationKeyPath: nil).latitude, 52.52)
    }
}
