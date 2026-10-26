import XCTest
@testable import BrowserCore

final class UserAgentTests: XCTestCase {
    private let mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    private func version(_ string: String) throws -> SafariVersion {
        try XCTUnwrap(SafariVersion(string), string)
    }

    // MARK: Resolution per mode

    func testSafariMacResolution() throws {
        let resolution = UserAgentBuilder.resolve(mode: .safariMac, customUserAgent: "ignored", safari: try version("26.0.1"))
        XCTAssertNil(resolution.customUserAgent, "Mac mode must keep WebKit's own UA and only add Safari's suffix")
        XCTAssertEqual(resolution.applicationNameForUserAgent, "Version/26.0.1 Safari/605.1.15")
        XCTAssertEqual(resolution.expectedUserAgent, mac + " Version/26.0.1 Safari/605.1.15")

        // Safari 26.0 → exactly the published Safari 26 Mac string.
        XCTAssertEqual(UserAgentBuilder.resolve(mode: .safariMac, customUserAgent: nil, safari: try version("26.0")).expectedUserAgent,
                       "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15")
        XCTAssertEqual(UserAgentBuilder.resolve(mode: .safariMac, customUserAgent: nil, safari: try version("18.6")).applicationNameForUserAgent,
                       "Version/18.6 Safari/605.1.15")
    }

    func testIPhoneAndIPadResolution() throws {
        let iPhone = UserAgentBuilder.resolve(mode: .iPhone, customUserAgent: nil, safari: try version("26.0.1"))
        XCTAssertNil(iPhone.applicationNameForUserAgent)
        XCTAssertEqual(iPhone.customUserAgent,
                       "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1")
        XCTAssertEqual(iPhone.expectedUserAgent, iPhone.customUserAgent)

        let iPad = UserAgentBuilder.resolve(mode: .iPad, customUserAgent: nil, safari: try version("26.0"))
        XCTAssertEqual(iPad.customUserAgent,
                       "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1")

        // From Safari 26.1 the frozen iOS token is 18_7, including later majors.
        XCTAssertTrue(UserAgentBuilder.resolve(mode: .iPhone, customUserAgent: nil, safari: try version("26.1"))
            .customUserAgent?.contains("iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile") == true)
        XCTAssertTrue(UserAgentBuilder.resolve(mode: .iPad, customUserAgent: nil, safari: try version("27.0.2"))
            .customUserAgent?.contains("(iPad; CPU OS 18_7 like Mac OS X)") == true)
        // Before Safari 26 the OS token followed the version.
        XCTAssertEqual(UserAgentBuilder.resolve(mode: .iPhone, customUserAgent: nil, safari: try version("17.4.1")).customUserAgent,
                       "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1")
        XCTAssertTrue(UserAgentBuilder.resolve(mode: .iPhone, customUserAgent: nil, safari: try version("18.6"))
            .customUserAgent?.contains("iPhone OS 18_6 like Mac OS X") == true)
    }

    func testCustomResolution() throws {
        let safari = try version("26.0")
        let custom = UserAgentBuilder.resolve(mode: .custom, customUserAgent: "Custom/1.0", safari: safari)
        XCTAssertEqual(custom, UserAgentResolution(customUserAgent: "Custom/1.0", applicationNameForUserAgent: nil))
        XCTAssertEqual(custom.expectedUserAgent, "Custom/1.0")
        // An empty custom string never yields WebKit's bare default; it falls back to Safari for Mac.
        let safariMac = UserAgentBuilder.resolve(mode: .safariMac, customUserAgent: nil, safari: safari)
        XCTAssertEqual(UserAgentBuilder.resolve(mode: .custom, customUserAgent: nil, safari: safari), safariMac)
        XCTAssertEqual(UserAgentBuilder.resolve(mode: .custom, customUserAgent: "", safari: safari), safariMac)

        // Through the configuration.
        XCTAssertEqual(ProfileConfiguration(userAgent: "Custom/2.0", userAgentMode: .custom).userAgentResolution(safari: safari).customUserAgent,
                       "Custom/2.0")
        XCTAssertNil(ProfileConfiguration(userAgent: "Custom/2.0", userAgentMode: .safariMac).userAgentResolution(safari: safari).customUserAgent)
        XCTAssertTrue(UserAgentMode.safariMac.matchesEngine)
        XCTAssertFalse(UserAgentMode.iPhone.matchesEngine)
    }

    // MARK: Safari version

    func testSafariVersionParsing() throws {
        XCTAssertEqual(try version("26").uaVersionToken, "26.0")
        XCTAssertEqual(try version("26.0").uaVersionToken, "26.0")
        XCTAssertEqual(try version("26.0.1").uaVersionToken, "26.0.1")
        XCTAssertEqual(try version("026.1").string, "26.1")
        let v = try version("18.6.2")
        XCTAssertEqual([v.major, v.minor], [18, 6])
        XCTAssertEqual(v.patch, 2)
        XCTAssertEqual(v.mobileVersionToken, "18.6")
        for bad in ["", "0", "0.1", "26.", ".26", "26..1", "26.0.1.2", "26.a", "-1", " 26.0", "26.0 ", "26,0",
                    "26.0 beta", "２６.0", "20622.1.22.118.4", "123456.0"] {
            XCTAssertNil(SafariVersion(bad), bad)
        }
    }

    func testInfoPlistParsingXMLAndBinary() throws {
        let plist: [String: Any] = ["CFBundleShortVersionString": "26.0.1", "CFBundleVersion": "20622.1.22.118.4",
                                    "CFBundleIdentifier": "com.apple.Safari"]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(binary.prefix(6), Data("bplist".utf8))
        XCTAssertEqual(SafariVersion.parse(infoPlist: xml)?.string, "26.0.1")
        XCTAssertEqual(SafariVersion.parse(infoPlist: binary)?.string, "26.0.1")

        // Hand-written XML as Safari.app ships it.
        let literal = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>Safari</string>
            <key>CFBundleShortVersionString</key>
            <string>18.6</string>
        </dict>
        </plist>
        """
        XCTAssertEqual(SafariVersion.parse(infoPlist: Data(literal.utf8))?.string, "18.6")

        XCTAssertNil(SafariVersion.parse(infoPlist: Data("not a plist".utf8)))
        XCTAssertNil(SafariVersion.parse(infoPlist: Data()))
        XCTAssertNil(SafariVersion.parse(infoPlist: try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "20622.1.22"], format: .xml, options: 0)))
        XCTAssertNil(SafariVersion.parse(infoPlist: try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "26.0 beta"], format: .binary, options: 0)))
        XCTAssertNil(SafariVersion.parse(infoPlist: try PropertyListSerialization.data(
            fromPropertyList: ["26.0"], format: .xml, options: 0)))
    }

    func testFallbackTableAndDetect() throws {
        let cases: [(Int, Int, String)] = [(26, 0, "26.0"), (26, 1, "26.1"), (27, 0, "27.0"),
                                           (15, 0, "18.0"), (15, 4, "18.4"), (15, 7, "18.6"),
                                           (14, 0, "17.0"), (14, 6, "17.6"), (13, 3, "16.3"), (6, 18, "14.6")]
        for (major, minor, expected) in cases {
            XCTAssertEqual(SafariVersion.fallback(macOSMajor: major, minor: minor).string, expected, "macOS \(major).\(minor)")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pb-ua-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.plist")
        let garbage = directory.appendingPathComponent("garbage.plist")
        let real = directory.appendingPathComponent("Info.plist")
        try Data("garbage".utf8).write(to: garbage)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "26.0.1"], format: .binary, options: 0)
            .write(to: real)

        let os = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)
        XCTAssertEqual(SafariVersion.detect(infoPlistURLs: [missing, garbage, real], operatingSystem: os).string, "26.0.1")
        XCTAssertEqual(SafariVersion.detect(infoPlistURLs: [missing, garbage], operatingSystem: os).string, "18.6")
    }

    // MARK: Configuration

    private func decode(_ json: String) throws -> ProfileConfiguration {
        try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(json.utf8))
    }

    func testMigrationFromDeviceGenerationAndUserAgent() throws {
        let base = #""ephemeral":false,"geolocation":{"deny":{}},"safeBrowsingEnabled":false,"webRTCPolicy":"disabled""#
        XCTAssertEqual(try decode("{\(base)}").userAgentMode, .safariMac)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":"macos-26"}"#).userAgentMode, .safariMac)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":"ios-26"}"#).userAgentMode, .iPhone)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":"ios-27"}"#).userAgentMode, .iPhone)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":"ipados-26"}"#).userAgentMode, .iPad)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":"android-1"}"#).userAgentMode, .safariMac)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":null}"#).userAgentMode, .safariMac)

        // An explicit old UA override won over the generation → custom, string kept.
        let overridden = try decode(#"{\#(base),"deviceGenerationID":"ios-27","userAgent":"Custom/1.0"}"#)
        XCTAssertEqual(overridden.userAgentMode, .custom)
        XCTAssertEqual(overridden.userAgent, "Custom/1.0")
        XCTAssertEqual(try decode(#"{\#(base),"userAgent":"Mozilla/5.0 Test"}"#).userAgentMode, .custom)
        XCTAssertEqual(try decode(#"{\#(base),"deviceGenerationID":"ios-26","userAgent":""}"#).userAgentMode, .iPhone)

        // A stored mode wins; an unknown one (newer build) goes through the fallbacks.
        XCTAssertEqual(try decode(#"{\#(base),"userAgentMode":"iPad","userAgent":"Custom/1.0"}"#).userAgentMode, .iPad)
        XCTAssertEqual(try decode(#"{\#(base),"userAgentMode":"future"}"#).userAgentMode, .safariMac)
        XCTAssertEqual(try decode(#"{\#(base),"userAgentMode":"future","userAgent":"X/1"}"#).userAgentMode, .custom)
        XCTAssertEqual(try decode(#"{\#(base),"userAgentMode":"future","deviceGenerationID":"ios-26"}"#).userAgentMode, .iPhone)

        // Re-encoding writes the mode and never the old generation id.
        let migrated = try decode(#"{\#(base),"deviceGenerationID":"ipados-26"}"#)
        let encoded = String(decoding: try JSONCoding.encoder.encode(migrated), as: UTF8.self)
        XCTAssertFalse(encoded.contains("deviceGenerationID"), encoded)
        XCTAssertTrue(encoded.contains(#""userAgentMode":"iPad""#), encoded)
        XCTAssertEqual(try decode(encoded), migrated)
    }

    func testNewFieldsDefaultsAndRoundTrip() throws {
        let legacy = try decode(#"{"ephemeral":false,"geolocation":{"deny":{}},"safeBrowsingEnabled":false,"webRTCPolicy":"disabled"}"#)
        XCTAssertEqual(legacy.userAgentMode, .safariMac)
        XCTAssertNil(legacy.locale)
        XCTAssertTrue(legacy.restoreTabs)
        XCTAssertEqual(legacy, ProfileConfiguration())

        let config = ProfileConfiguration(userAgent: "kept for later", userAgentMode: .iPhone, locale: "de-DE", restoreTabs: false)
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.userAgent, "kept for later", "the custom string survives switching modes")

        // init infers the mode like decoding does when none is given.
        XCTAssertEqual(ProfileConfiguration().userAgentMode, .safariMac)
        XCTAssertEqual(ProfileConfiguration(userAgent: "X/1").userAgentMode, .custom)
        XCTAssertEqual(ProfileConfiguration(userAgent: "").userAgentMode, .safariMac)
        XCTAssertEqual(ProfileConfiguration(userAgent: "X/1", userAgentMode: .iPad).userAgentMode, .iPad)
    }

    func testUserAgentValidationOnlyForCustom() {
        XCTAssertThrowsError(try ProfileConfiguration(userAgentMode: .custom).validate())
        XCTAssertThrowsError(try ProfileConfiguration(userAgent: "", userAgentMode: .custom).validate())
        XCTAssertThrowsError(try ProfileConfiguration(userAgent: "bad\nua", userAgentMode: .custom).validate())
        XCTAssertThrowsError(try ProfileConfiguration(userAgent: String(repeating: "a", count: 513), userAgentMode: .custom).validate())
        XCTAssertNoThrow(try ProfileConfiguration(userAgent: "Custom/1.0", userAgentMode: .custom).validate())
        // Ignored, so not validated, in the other modes.
        XCTAssertNoThrow(try ProfileConfiguration(userAgent: "bad\nua", userAgentMode: .safariMac).validate())
        XCTAssertNoThrow(try ProfileConfiguration(userAgentMode: .iPhone).validate())
    }

    func testLocaleValidationAndLanguages() {
        for good in ["de", "de-DE", "deu", "zh-Hant-TW", "es-419", "en-US-POSIX", "de-de", "sr-Latn-RS",
                     "ab-" + String(repeating: "a", count: 8) + "-cd-ef-gh-ij-kl-mn"] {
            XCTAssertTrue(ProfileConfiguration.isValidLocale(good), good)
            XCTAssertNoThrow(try ProfileConfiguration(locale: good).validate(), good)
        }
        for bad in ["", "d", "DE", "De-DE", "dexx", "de_DE", "de-", "-de", "de--DE", "de-DE-", "de-D", "de-ABCDEFGHI",
                    "de-DÉ", "dé", "de-DE\n", " de", "de DE", "en-u-ca-gregory", "x-private",
                    "ab-" + String(repeating: "abcdefgh-", count: 4)] {
            XCTAssertFalse(ProfileConfiguration.isValidLocale(bad), bad)
            XCTAssertThrowsError(try ProfileConfiguration(locale: bad).validate(), bad)
        }
        // 35 characters is the limit.
        let thirtyFive = "de-" + String(repeating: "a", count: 8) + "-" + String(repeating: "b", count: 8) + "-"
            + String(repeating: "c", count: 8) + "-12345"
        XCTAssertEqual(thirtyFive.count, 35)
        XCTAssertTrue(ProfileConfiguration.isValidLocale(thirtyFive))
        XCTAssertFalse(ProfileConfiguration.isValidLocale(thirtyFive + "6"))

        XCTAssertEqual(ProfileConfiguration().languages, [])
        XCTAssertNil(ProfileConfiguration().acceptLanguage)
        XCTAssertEqual(ProfileConfiguration(locale: "de-DE").languages, ["de-DE", "de"])
        XCTAssertEqual(ProfileConfiguration(locale: "de-DE").acceptLanguage, "de-DE,de;q=0.9")
        XCTAssertEqual(ProfileConfiguration(locale: "fr").languages, ["fr"])
        XCTAssertEqual(ProfileConfiguration(locale: "fr").acceptLanguage, "fr")
        XCTAssertEqual(ProfileConfiguration(locale: "de-de").languages, ["de-DE", "de"])
        XCTAssertEqual(ProfileConfiguration(locale: "zh-hant-tw").languages, ["zh-Hant-TW", "zh"])
        XCTAssertEqual(ProfileConfiguration(locale: "es-419").languages, ["es-419", "es"])
        XCTAssertEqual(ProfileConfiguration(locale: "en-US-POSIX").languages, ["en-US-posix", "en"])
        // An invalid stored value never reaches the page.
        XCTAssertEqual(ProfileConfiguration(locale: "de_DE").languages, [])
    }
}
