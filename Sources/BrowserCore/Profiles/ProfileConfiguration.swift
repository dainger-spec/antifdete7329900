import Foundation

/// Per-profile settings. Persisted only in encrypted form (`config.bin`) and
/// decrypted when the profile is launched or edited.
///
/// Each field documents whether the app layer applies it through a native WebKit
/// API (hard guarantee) or through an injected JavaScript shim (approximation).
public struct ProfileConfiguration: Codable, Equatable, Sendable {
    /// First page loaded when the profile launches. `nil` → blank page.
    public var startURL: URL?

    /// NATIVE: which User-Agent the profile declares (HTTP header + `navigator.userAgent`),
    /// resolved by `userAgentResolution(safari:)`. Default `.safariMac`, the real Safari UA of
    /// this Mac. Other navigator properties (`platform`, `vendor`, touch) and every measurable
    /// engine signal stay those of macOS WebKit whatever the mode.
    public var userAgentMode: UserAgentMode

    /// The string used by `.custom` mode (`WKWebView.customUserAgent`). Ignored, and not
    /// validated, in every other mode; it is kept so switching back to `.custom` restores it.
    public var userAgent: String?

    /// NATIVE (macOS 14+): `WKWebsiteDataStore.proxyConfigurations`.
    public var proxy: ProxySettings?

    /// APPROXIMATION: JavaScript override of `navigator.geolocation`.
    public var geolocation: GeolocationSetting

    /// APPROXIMATION: JavaScript override of `Intl` default time zone and `Date`
    /// local-time accessors. `nil` → system time zone. IANA identifier, e.g. "Europe/Berlin".
    public var timeZoneIdentifier: String?

    /// APPROXIMATION: JavaScript removal/wrapping of `RTCPeerConnection`.
    public var webRTCPolicy: WebRTCPolicy

    /// NATIVE: use `WKWebsiteDataStore.nonPersistent()` — no website data written to disk,
    /// everything discarded when the profile stops. History is kept in memory only;
    /// bookmarks (explicit user data) are still saved, encrypted.
    public var ephemeral: Bool

    /// NATIVE: `WKPreferences.isFraudulentWebsiteWarningEnabled`. Safe Browsing lookups
    /// are made by WebKit outside the per-profile proxy, so default is off.
    public var safeBrowsingEnabled: Bool

    /// Record visited pages in the profile's encrypted history. Ephemeral profiles keep
    /// history in memory only, regardless of this flag.
    public var historyEnabled: Bool

    /// History entries older than this are pruned. `nil` = keep forever.
    public var historyRetentionDays: Int?

    /// The profile's language as a BCP-47 tag ("de-DE"). `nil` → the Mac's language settings.
    ///
    /// APPROXIMATION (app layer): WebKit has no public per-web-view or per-data-store language
    /// API. `navigator.language(s)` and the `Accept-Language` header come from the app
    /// process's language list, shared by all profiles. The app applies `languages` /
    /// `acceptLanguage` where it can (injected script, requests it starts itself); requests
    /// WebKit makes on its own keep the Mac's language.
    public var locale: String?

    /// Reopen the windows and tabs of the last session when the profile launches
    /// (`SessionStore`). Ephemeral profiles keep their session in memory only.
    public var restoreTabs: Bool

    /// `userAgentMode: nil` infers the mode the same way an old file without the field is
    /// decoded: `.custom` when `userAgent` is non-empty, `.safariMac` otherwise.
    public init(startURL: URL? = nil,
                userAgent: String? = nil,
                userAgentMode: UserAgentMode? = nil,
                proxy: ProxySettings? = nil,
                geolocation: GeolocationSetting = .deny,
                timeZoneIdentifier: String? = nil,
                webRTCPolicy: WebRTCPolicy = .disabled,
                ephemeral: Bool = false,
                safeBrowsingEnabled: Bool = false,
                historyEnabled: Bool = true,
                historyRetentionDays: Int? = 90,
                locale: String? = nil,
                restoreTabs: Bool = true) {
        self.startURL = startURL
        self.userAgentMode = userAgentMode ?? Self.inferredMode(userAgent: userAgent)
        self.userAgent = userAgent
        self.proxy = proxy
        self.geolocation = geolocation
        self.timeZoneIdentifier = timeZoneIdentifier
        self.webRTCPolicy = webRTCPolicy
        self.ephemeral = ephemeral
        self.safeBrowsingEnabled = safeBrowsingEnabled
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.locale = locale
        self.restoreTabs = restoreTabs
    }

    // MARK: User agent and language

    /// What the app applies to the profile's web views. `safari` is the installed Safari's
    /// version (`SafariVersion.detect()`).
    public func userAgentResolution(safari: SafariVersion) -> UserAgentResolution {
        UserAgentBuilder.resolve(mode: userAgentMode, customUserAgent: userAgent, safari: safari)
    }

    /// Language list for `navigator.languages`: the locale, then its base language
    /// (`"de-DE"` → `["de-DE", "de"]`), with canonical casing. `[]` when `locale` is nil or invalid.
    public var languages: [String] {
        guard let locale, Self.isValidLocale(locale) else { return [] }
        let canonical = Self.canonicalLocale(locale)
        let base = String(canonical.prefix { $0 != "-" })
        return canonical == base ? [canonical] : [canonical, base]
    }

    /// `Accept-Language` value in Safari's format (`"de-DE,de;q=0.9"`). `nil` when `languages`
    /// is empty, i.e. leave WebKit's default.
    public var acceptLanguage: String? {
        let languages = languages
        guard let first = languages.first else { return nil }
        return ([first] + languages.dropFirst().map { "\($0);q=0.9" }).joined(separator: ",")
    }

    /// BCP-47 shape check, equivalent to `^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$` with at most 35
    /// characters (ASCII only; implemented by hand because ICU's `$` also matches before a
    /// trailing newline). Single-letter extension/private-use subtags are not accepted.
    public static func isValidLocale(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.utf8.count <= 35 else { return false }
        let subtags = tag.split(separator: "-", omittingEmptySubsequences: false)
        func isLower(_ b: UInt8) -> Bool { (0x61...0x7A).contains(b) }
        func isAlnum(_ b: UInt8) -> Bool { isLower(b) || (0x41...0x5A).contains(b) || (0x30...0x39).contains(b) }
        guard let language = subtags.first, (2...3).contains(language.utf8.count),
              language.utf8.allSatisfy(isLower) else { return false }
        return subtags.dropFirst().allSatisfy { (2...8).contains($0.utf8.count) && $0.utf8.allSatisfy(isAlnum) }
    }

    /// RFC 5646 §2.1.1 casing for the tags `isValidLocale` accepts: language lowercase,
    /// 4-letter script title case, 2-letter region uppercase, everything else lowercase.
    static func canonicalLocale(_ tag: String) -> String {
        tag.split(separator: "-").enumerated().map { index, subtag -> String in
            let text = String(subtag)
            guard index > 0 else { return text.lowercased() }
            let letters = text.utf8.allSatisfy { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
            if letters && text.utf8.count == 2 { return text.uppercased() }
            if letters && text.utf8.count == 4 { return text.prefix(1).uppercased() + text.dropFirst().lowercased() }
            return text.lowercased()
        }.joined(separator: "-")
    }

    private static func inferredMode(userAgent: String?) -> UserAgentMode {
        if let userAgent, !userAgent.isEmpty { return .custom }
        return .safariMac
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case startURL, userAgent, userAgentMode, proxy, geolocation, timeZoneIdentifier, webRTCPolicy, ephemeral,
             safeBrowsingEnabled, historyEnabled, historyRetentionDays, locale, restoreTabs
    }

    /// Read-only keys of older formats. Decoded for migration, never written.
    private enum LegacyCodingKeys: String, CodingKey {
        /// Removed "device generation" (macos-* / ios-* / ipados-*), replaced by `userAgentMode`.
        case deviceGenerationID
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults, so
    /// configurations written by older builds keep decrypting and decoding.
    ///
    /// `userAgentMode` precedence: a known stored mode; else `.custom` if a non-empty
    /// `userAgent` is stored (in the old format it overrode the generation); else the mode of
    /// the old `deviceGenerationID`; else `.safariMac`. An unknown mode (written by a newer
    /// build) goes through the same fallbacks instead of failing the whole profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProfileConfiguration()
        startURL = try c.decodeIfPresent(URL.self, forKey: .startURL)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        proxy = try c.decodeIfPresent(ProxySettings.self, forKey: .proxy)
        geolocation = try c.decodeIfPresent(GeolocationSetting.self, forKey: .geolocation) ?? defaults.geolocation
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        webRTCPolicy = try c.decodeIfPresent(WebRTCPolicy.self, forKey: .webRTCPolicy) ?? defaults.webRTCPolicy
        ephemeral = try c.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? defaults.ephemeral
        safeBrowsingEnabled = try c.decodeIfPresent(Bool.self, forKey: .safeBrowsingEnabled) ?? defaults.safeBrowsingEnabled
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? defaults.historyEnabled
        historyRetentionDays = c.contains(.historyRetentionDays)
            ? try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays)
            : defaults.historyRetentionDays
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        restoreTabs = try c.decodeIfPresent(Bool.self, forKey: .restoreTabs) ?? defaults.restoreTabs

        if let stored = (try? c.decodeIfPresent(String.self, forKey: .userAgentMode)).flatMap({ $0 }),
           let mode = UserAgentMode(rawValue: stored) {
            userAgentMode = mode
        } else if let userAgent, !userAgent.isEmpty {
            userAgentMode = .custom
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self)
            let generationID = (try? legacy?.decodeIfPresent(String.self, forKey: .deviceGenerationID)).flatMap { $0 }
            userAgentMode = LegacyDeviceGeneration.userAgentMode(forGenerationID: generationID) ?? defaults.userAgentMode
        }
    }

    /// Explicit so that `historyRetentionDays: nil` ("keep forever") is written as JSON null
    /// and not confused with "field absent" (→ default) when decoding.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(startURL, forKey: .startURL)
        try c.encode(userAgentMode, forKey: .userAgentMode)
        try c.encodeIfPresent(userAgent, forKey: .userAgent)
        try c.encodeIfPresent(proxy, forKey: .proxy)
        try c.encode(geolocation, forKey: .geolocation)
        try c.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try c.encode(webRTCPolicy, forKey: .webRTCPolicy)
        try c.encode(ephemeral, forKey: .ephemeral)
        try c.encode(safeBrowsingEnabled, forKey: .safeBrowsingEnabled)
        try c.encode(historyEnabled, forKey: .historyEnabled)
        try c.encode(historyRetentionDays, forKey: .historyRetentionDays)
        try c.encodeIfPresent(locale, forKey: .locale)
        try c.encode(restoreTabs, forKey: .restoreTabs)
    }

    public var historyPolicy: HistoryStore.Policy {
        HistoryStore.Policy(retentionDays: historyRetentionDays)
    }

    public func validate() throws {
        if let startURL {
            guard let scheme = startURL.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) else {
                throw CoreError.invalidConfiguration("start URL must be http(s) or about:")
            }
        }
        if userAgentMode == .custom {
            guard let userAgent, !userAgent.isEmpty, userAgent.count <= 512,
                  userAgent.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
                throw CoreError.invalidConfiguration("custom user agent must be 1–512 printable ASCII characters")
            }
        }
        if let locale, !Self.isValidLocale(locale) {
            throw CoreError.invalidConfiguration("locale must be a language tag such as de-DE")
        }
        if let timeZoneIdentifier {
            guard TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw CoreError.invalidConfiguration("unknown time zone \(timeZoneIdentifier)")
            }
        }
        if let historyRetentionDays, !(1...3650).contains(historyRetentionDays) {
            throw CoreError.invalidConfiguration("history retention must be 1–3650 days")
        }
        try proxy?.validate()
        try geolocation.validate()
    }
}

public struct ProxySettings: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// HTTP CONNECT tunnel. Used for both http:// and https:// traffic.
        case httpConnect
        case socks5
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    /// Wrap the connection to the proxy itself in TLS (HTTPS proxy). httpConnect only.
    public var tlsToProxy: Bool
    /// Domains that bypass the proxy. Empty by default: everything goes via the proxy.
    public var excludedDomains: [String]

    public init(kind: Kind, host: String, port: Int, username: String? = nil, password: String? = nil,
                tlsToProxy: Bool = false, excludedDomains: [String] = []) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tlsToProxy = tlsToProxy
        self.excludedDomains = excludedDomains
    }

    public func validate() throws {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == host, !host.contains("/") else {
            throw CoreError.invalidConfiguration("proxy host must be a bare hostname or IP")
        }
        guard (1...65535).contains(port) else { throw CoreError.invalidConfiguration("proxy port out of range") }
        if tlsToProxy && kind == .socks5 {
            throw CoreError.invalidConfiguration("TLS to proxy is only supported for HTTP CONNECT proxies")
        }
        if (username == nil) != (password == nil) {
            throw CoreError.invalidConfiguration("proxy username and password must both be set or both empty")
        }
    }
}

public enum GeolocationSetting: Codable, Equatable, Sendable {
    /// Every geolocation request fails with PERMISSION_DENIED. Default.
    case deny
    /// Return fixed coordinates. Note: the page can still infer location from the
    /// egress IP; set a matching proxy.
    case fixed(latitude: Double, longitude: Double, accuracyMeters: Double)

    public func validate() throws {
        if case let .fixed(latitude, longitude, accuracy) = self {
            guard (-90...90).contains(latitude), (-180...180).contains(longitude),
                  accuracy > 0, accuracy.isFinite else {
                throw CoreError.invalidConfiguration("geolocation out of range")
            }
        }
    }
}

public enum WebRTCPolicy: String, Codable, CaseIterable, Sendable {
    /// Remove RTCPeerConnection & friends from the page. Strongest option. Breaks WebRTC sites.
    case disabled
    /// Force `iceTransportPolicy: "relay"`: no host/srflx candidates are gathered, so the
    /// local and STUN-discovered public IP are not exposed. Requires the site to provide TURN.
    case relayOnly
    /// WebKit default (host candidates are mDNS-obfuscated by WebKit, but STUN
    /// requests go out over UDP *outside* the proxy and reveal the real public IP).
    case unrestricted
}
