import Foundation

/// How a profile identifies itself in the HTTP `User-Agent` header and `navigator.userAgent`.
///
/// The engine is always the system WebKit of the Mac the app runs on. A mode changes the
/// *declared* string only: it does not change rendering, the JavaScript feature set, touch
/// support, TLS or any other signal a site can measure.
public enum UserAgentMode: String, Codable, CaseIterable, Sendable {
    /// Default and recommended: exactly the UA Safari sends on this Mac. It is the only mode
    /// that is consistent with the engine actually rendering the page.
    case safariMac
    /// The UA string of Safari on iPhone, for sites that only offer a mobile layout. Nothing
    /// else about the page environment becomes iPhone-like.
    case iPhone
    /// The iPad-identifying UA string (what iPad Safari sends with "Request Mobile Website").
    /// Note that iPad Safari sends the *Mac* UA by default (desktop-class browsing), so this is
    /// the less common iPad string, useful for tablet layouts.
    case iPad
    /// `ProfileConfiguration.userAgent`, verbatim.
    case custom

    /// True only for `.safariMac`: the declared UA matches the engine that renders the page.
    public var matchesEngine: Bool { self == .safariMac }
}

/// A Safari marketing version ("26.0.1"), used to build the same UA Safari sends.
///
/// The app reads it from Safari.app's `Info.plist` (`detect`). WebKit's own framework
/// version (`20622.1.22…`) is not the Safari version and cannot be used instead.
public struct SafariVersion: Equatable, Sendable, CustomStringConvertible {
    /// Normalised marketing version, 1–3 decimal components, e.g. "26.0.1".
    public let string: String
    public let major: Int
    public let minor: Int
    /// `nil` when the version has no third component ("26.0").
    public let patch: Int?

    /// Accepts 1–3 dot-separated decimal components with a major version ≥ 1. Anything else
    /// (build numbers, "26.0 beta", localized separators) is rejected so it can never be
    /// pasted into a UA string.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...5).contains(part.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        guard numbers[0] >= 1 else { return nil }
        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : nil
        self.string = numbers.map(String.init).joined(separator: ".")
    }

    public var description: String { string }

    /// What Safari for Mac puts after `Version/`: the full marketing version, at least
    /// major.minor ("26.0", "26.0.1").
    ///
    /// Safari 26.0 sends `Version/26.0` (https://nielsleenheer.com/articles/2025/the-user-agent-string-of-safari-on-ios-26-and-macos-26/).
    /// Point releases keep the third component: Safari 15.6.2 was reported sending
    /// `Version/15.6,2` (https://developer.apple.com/forums/thread/715191), i.e. the patch is
    /// part of the token, so Safari 26.0.1 sends `Version/26.0.1`.
    public var uaVersionToken: String {
        patch.map { "\(major).\(minor).\($0)" } ?? "\(major).\(minor)"
    }

    /// The `Version/` token used for the iPhone/iPad strings: major.minor only. The Mac's patch
    /// level does not map onto an iOS point release, and every iOS x.y.z device also reports a
    /// valid x.y, so major.minor is the representative value.
    var mobileVersionToken: String { "\(major).\(minor)" }

    /// Reads `CFBundleShortVersionString` from an `Info.plist` (XML or binary). Works on Linux
    /// too (`PropertyListSerialization` is part of swift-corelibs-foundation).
    public static func parse(infoPlist data: Data) -> SafariVersion? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String else { return nil }
        return SafariVersion(version)
    }

    /// Approximate Safari version for a macOS release, used only when Safari.app's
    /// `Info.plist` cannot be read (e.g. blocked by the sandbox).
    ///
    /// macOS 26 and later ship Safari with the same version number (macOS 26.1 → Safari 26.1).
    /// Before that Safari was macOS + 3 (macOS 15 → Safari 18, 14 → 17, …), with x.6 the last
    /// minor of each line. This is a FALLBACK and can be behind: Safari is also updated on its
    /// own on older macOS (Safari 26 runs on macOS 14 and 15).
    public static func fallback(macOSMajor: Int, minor: Int) -> SafariVersion {
        let minor = max(0, minor)
        let string: String
        if macOSMajor >= 26 {
            string = "\(macOSMajor).\(minor)"
        } else {
            string = "\(max(macOSMajor, 11) + 3).\(min(minor, 6))"
        }
        return SafariVersion(string) ?? SafariVersion("26.0")!
    }

    /// Where Safari's `Info.plist` lives. Since macOS 13 Safari is installed in the App cryptex;
    /// `/Applications/Safari.app` still resolves to it.
    public static let infoPlistURLs: [URL] = [
        URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist"),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist"),
    ]

    /// The installed Safari's version, or the `fallback` for `operatingSystem` when none of
    /// `infoPlistURLs` can be read and parsed. Reads small files synchronously.
    public static func detect(infoPlistURLs: [URL] = infoPlistURLs,
                              operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> SafariVersion {
        for url in infoPlistURLs {
            if let data = try? Data(contentsOf: url), let version = parse(infoPlist: data) {
                return version
            }
        }
        return fallback(macOSMajor: operatingSystem.majorVersion, minor: operatingSystem.minorVersion)
    }
}

/// What the app layer applies to a web view. `customUserAgent` (when set) replaces the whole
/// string (`WKWebView.customUserAgent`); otherwise `applicationNameForUserAgent`
/// (`WKWebViewConfiguration.applicationNameForUserAgent`) is appended to WebKit's default.
public struct UserAgentResolution: Equatable, Sendable {
    public var customUserAgent: String?
    public var applicationNameForUserAgent: String?

    public init(customUserAgent: String?, applicationNameForUserAgent: String?) {
        self.customUserAgent = customUserAgent
        self.applicationNameForUserAgent = applicationNameForUserAgent
    }

    /// The string WebKit is expected to send: for display in the editor and for the self-test.
    /// WebKit builds the real one; its macOS prefix has been frozen since 2020.
    public var expectedUserAgent: String {
        if let customUserAgent { return customUserAgent }
        guard let applicationNameForUserAgent, !applicationNameForUserAgent.isEmpty else {
            return UserAgentBuilder.macWebKitPrefix
        }
        return UserAgentBuilder.macWebKitPrefix + " " + applicationNameForUserAgent
    }
}

/// Builds the UA strings Safari itself sends, for a given Safari version.
///
/// Reference strings for Safari 26 (https://nielsleenheer.com/articles/2025/the-user-agent-string-of-safari-on-ios-26-and-macos-26/):
/// ```
/// Mac:    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15
/// iPhone: Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1
/// iPad:   Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1
/// ```
/// The iPad string is only sent with "Request Mobile Website"; by default iPad Safari sends
/// the Mac string above.
public enum UserAgentBuilder {
    /// WebKit's default UA on macOS (`WKWebView` without customisation). The OS token is frozen
    /// at 10_15_7 and the WebKit token at 605.1.15 regardless of the real versions.
    public static let macWebKitPrefix = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    public static func resolve(mode: UserAgentMode, customUserAgent: String?, safari: SafariVersion) -> UserAgentResolution {
        switch mode {
        case .safariMac:
            // WKWebView's default UA lacks Safari's "Version/x Safari/605.1.15" suffix; with it
            // the string equals the one Safari sends on this Mac.
            return UserAgentResolution(customUserAgent: nil,
                                       applicationNameForUserAgent: "Version/\(safari.uaVersionToken) Safari/605.1.15")
        case .iPhone:
            return UserAgentResolution(customUserAgent: mobileUserAgent(device: "iPhone; CPU iPhone OS", safari: safari),
                                       applicationNameForUserAgent: nil)
        case .iPad:
            return UserAgentResolution(customUserAgent: mobileUserAgent(device: "iPad; CPU OS", safari: safari),
                                       applicationNameForUserAgent: nil)
        case .custom:
            guard let customUserAgent, !customUserAgent.isEmpty else {
                // `ProfileConfiguration.validate()` rejects this; never fall back to the bare
                // WebKit default, which no real browser sends.
                return resolve(mode: .safariMac, customUserAgent: nil, safari: safari)
            }
            return UserAgentResolution(customUserAgent: customUserAgent, applicationNameForUserAgent: nil)
        }
    }

    private static func mobileUserAgent(device: String, safari: SafariVersion) -> String {
        "Mozilla/5.0 (\(device) \(mobileOSToken(safari: safari)) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safari.mobileVersionToken) Mobile/15E148 Safari/604.1"
    }

    /// The OS version iOS/iPadOS Safari reports for a Safari version.
    ///
    /// From Safari 26 the OS token is frozen and no longer follows iOS: Safari 26.0 on iOS 26
    /// reports 18_6 (https://bugs.webkit.org/show_bug.cgi?id=298260, "Our plan is to hold the OS
    /// release constant forever"). From 26.1 on, all Apple platforms report 18_7 (same bug,
    /// comments 9–10; WebKit `Quirks.cpp`: `frozenVersion = "18_7"`). Before Safari 26 the token
    /// was the real iOS version, which shipped with the same Safari major.minor.
    static func mobileOSToken(safari: SafariVersion) -> String {
        if safari.major >= 26 {
            return safari.major == 26 && safari.minor == 0 ? "18_6" : "18_7"
        }
        return "\(safari.major)_\(safari.minor)"
    }
}

/// Migration from the removed "device generation" catalogue (`deviceGenerationID` values such
/// as "macos-26", "ios-27", "ipados-26" in configurations written by earlier builds).
enum LegacyDeviceGeneration {
    static func userAgentMode(forGenerationID id: String?) -> UserAgentMode? {
        guard let id = id?.lowercased() else { return nil }
        if id.hasPrefix("macos-") { return .safariMac }
        if id.hasPrefix("ipados-") { return .iPad }
        if id.hasPrefix("ios-") { return .iPhone }
        return nil
    }
}
