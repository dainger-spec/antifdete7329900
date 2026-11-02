import XCTest
@testable import BrowserCore

/// "What sites see" told for a person: the profile's identity apart from what should have been the
/// real Safari's, and each difference by what it is about.
final class SiteVerdictTests: XCTestCase {
    private func signal(_ key: String, _ profile: String?, _ safari: String?) -> SiteSignal {
        let verdict: SiteSignal.Verdict
        if SiteComparison.perWindow(key) {
            verdict = .perWindow
        } else if let profile, let safari {
            verdict = profile == safari ? .same : .differs
        } else {
            verdict = profile == nil ? .onlySafari : .onlyProfile
        }
        return SiteSignal(key: key, category: SiteComparison.category(of: key), profile: profile, safari: safari, verdict: verdict)
    }

    /// A profile that plays Germany on a Mac in Moscow: its time and its language differ on purpose,
    /// a missing interface does not.
    private var germanProfile: [SiteSignal] {
        [
            signal("probe.timeZone", "Europe/Berlin", "Europe/Moscow"),
            signal("probe.tzOffset", "-60/-120", "-180/-180"),
            signal("probe.language", "de-DE", "ru-RU"),
            signal("headers.navigation.accept-language", "de-DE,de;q=0.9", "ru-RU,ru;q=0.9"),
            signal("probe.features.RTCPeerConnection", "undefined", "function"),
            signal("probe.screen", "1512x982x1512x945x2", "1512x982x1512x945x2"),
            signal("geometry.outer", "1200x800", "1400x900"),
        ]
    }

    func testTheProfilesIdentityDiffersOnPurposeAndTheRestIsWorthALook() {
        let verdict = SiteComparison.verdict(germanProfile, expected: ExpectedIdentity(timeZone: "Europe/Berlin", language: "de-DE"))
        XCTAssertEqual(verdict.intended.map(\.key),
                       ["probe.timeZone", "probe.tzOffset", "probe.language", "headers.navigation.accept-language"])
        XCTAssertEqual(verdict.attention.map(\.key), ["probe.features.RTCPeerConnection"])
        XCTAssertEqual(verdict.same, 1)
        XCTAssertEqual(verdict.compared, 6)
        XCTAssertEqual(verdict.notCompared.map(\.key), ["geometry.outer"])
        XCTAssertEqual(verdict.aspects, [.timeZone, .language])
    }

    /// Nothing known of what the profile was set to: its identity is still the profile's.
    func testWithoutKnowingTheSettingsTheIdentityStaysIntended() {
        let verdict = SiteComparison.verdict(germanProfile)
        XCTAssertEqual(verdict.intended.count, 4)
        XCTAssertEqual(verdict.attention.map(\.key), ["probe.features.RTCPeerConnection"])
    }

    /// A time zone that is not the one the profile was set to is no part of its identity: worth a
    /// look, with what it was set to; its language stays intended.
    func testAnIdentityThatIsNotAsSetIsWorthALook() {
        let expected = ExpectedIdentity(timeZone: "America/New_York", language: "de")
        let verdict = SiteComparison.verdict(germanProfile, expected: expected)
        XCTAssertEqual(verdict.attention.map(\.key),
                       ["probe.timeZone", "probe.tzOffset", "probe.features.RTCPeerConnection"])
        XCTAssertEqual(verdict.intended.map(\.key), ["probe.language", "headers.navigation.accept-language"])
        XCTAssertEqual(verdict.aspects, [.language])
        XCTAssertEqual(SiteComparison.difference(of: germanProfile[0], expected: expected), .notAsSet(expected: "America/New_York"))
    }

    func testAZoneUnderEitherOfItsNamesIsTheSameZone() {
        XCTAssertTrue(SiteComparison.sameZone("Asia/Calcutta", "Asia/Kolkata"))
        XCTAssertFalse(SiteComparison.sameZone("Europe/Berlin", "Europe/Moscow"))
        XCTAssertFalse(SiteComparison.sameZone("Europe/Berlin", "Not/AZone"))
        XCTAssertTrue(SiteComparison.sameLanguage("de-DE", "de"))
        XCTAssertFalse(SiteComparison.sameLanguage("en-US", "de-DE"))
    }

    /// A difference is told by the names it is about: the property the profile lacks, not 40 against 41.
    func testADifferenceIsToldByTheNamesItIsAbout() {
        let difference = { (key: String, profile: String, safari: String) in
            SiteComparison.difference(of: self.signal(key, profile, safari))
        }
        XCTAssertEqual(difference("probe.navigatorProperties", "appName,cookieEnabled,language", "appName,cookieEnabled,credentials,language"),
                       .names(missing: ["credentials"], extra: []))
        XCTAssertEqual(difference("probe.windowProperties", "Array,webkit,Date", "Array,Date"),
                       .names(missing: [], extra: ["webkit"]))
        XCTAssertEqual(difference("probe.plugins", "PDF Viewer", "PDF Viewer|Chrome PDF Viewer"),
                       .names(missing: ["Chrome PDF Viewer"], extra: []))
        XCTAssertEqual(difference("probe.features.window.ApplePaySetup", "undefined", "function"),
                       .names(missing: ["window.ApplePaySetup"], extra: []))
        XCTAssertEqual(difference("probe.features.window.webkit", "object", "undefined"),
                       .names(missing: [], extra: ["window.webkit"]))
        XCTAssertEqual(difference("probe.natives.RTCPeerConnection", "absent", "native-text len=0 own=length+name proto=true"),
                       .names(missing: ["RTCPeerConnection"], extra: []))
        XCTAssertEqual(difference("probe.natives.Date.prototype.getTimezoneOffset",
                                  "TEXT:function getTimezoneOffset() { return zone", "native-text len=0 own=length+name proto=true"),
                       .replacedFunction("Date.prototype.getTimezoneOffset"))
        XCTAssertEqual(difference("headers.navigation.order", "host,accept,user-agent", "host,user-agent,accept"), .order)
        XCTAssertEqual(difference("probe.hardwareConcurrency", "8", "10"), .values)
        XCTAssertEqual(SiteComparison.difference(of: signal("probe.webgl.kind", nil, "webgl2")), .onlyInSafari)
        XCTAssertNil(SiteComparison.difference(of: signal("probe.platform", "MacIntel", "MacIntel")))
        XCTAssertNil(SiteComparison.difference(of: signal("geometry.outer", "1200x800", "1400x900")))
    }

    /// The same item twice in one list and once in the other is one too many, not the same list.
    func testAnItemListedMoreTimesIsCounted() {
        XCTAssertEqual(SiteComparison.difference(of: signal("apis.devices", "audioinput+label+id,audioinput+label+id,videoinput",
                                                            "audioinput+label+id,videoinput")),
                       .names(missing: [], extra: ["audioinput+label+id"]))
    }
}
