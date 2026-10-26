import Foundation

/// Per-profile settings. Persisted only in encrypted form (`config.bin`) and
/// decrypted when the profile is launched or edited.
///
/// Each field documents whether the app layer applies it through a native WebKit
/// API (hard guarantee) or through an injected JavaScript shim (approximation).
public struct ProfileConfiguration: Codable, Equatable, Sendable {
    /// First page loaded when the profile launches. `nil` → blank page.
    public var startURL: URL?

    /// NATIVE: `WKWebView.customUserAgent` — applied to the HTTP `User-Agent` header
    /// and `navigator.userAgent`. Other navigator properties (`platform`, `vendor`,
    /// client hints) are not changed by WebKit; see `UserAgentConsistency`.
    /// `nil` → WebKit default.
    public var userAgent: String?

    /// NATIVE (macOS 14+): `WKWebsiteDataStore.proxyConfigurations`.
    public var proxy: ProxySettings?

    /// APPROXIMATION: JavaScript override of `navigator.geolocation`.
    public var geolocation: GeolocationSetting

    /// APPROXIMATION: JavaScript override of `Intl` default time zone and `Date`
    /// local-time accessors. `nil` → the proxy's time zone (`matchProxyLocation`), else the
    /// system time zone. IANA identifier, e.g. "Europe/Berlin".
    public var timeZoneIdentifier: String?

    /// With a proxy and no `timeZoneIdentifier`: at launch the app asks a geolocation service,
    /// through the proxy, where the proxy exits, and the profile runs in that time zone (a site
    /// compares the time zone it is told with its own lookup of the IP). The country also picks
    /// the language websites see when this is the first profile of the app run (WebKit has one
    /// language list per process). Default on; older configurations decode as on.
    public var matchProxyLocation: Bool

    /// The last location looked up for `proxy` (`matchProxyLocation`): used when a later lookup
    /// fails, as long as the proxy is the same.
    public var lastProxyLocation: ProxyLocation?

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

    /// Target Apple OS generation (`DeviceGenerations`). Supplies the self-declared User-Agent
    /// and the behaviour set, unless `userAgent` overrides the UA. `nil` → the default generation.
    public var deviceGenerationID: String?

    public init(startURL: URL? = nil,
                userAgent: String? = nil,
                proxy: ProxySettings? = nil,
                geolocation: GeolocationSetting = .deny,
                timeZoneIdentifier: String? = nil,
                webRTCPolicy: WebRTCPolicy = .disabled,
                ephemeral: Bool = false,
                safeBrowsingEnabled: Bool = false,
                historyEnabled: Bool = true,
                historyRetentionDays: Int? = 90,
                deviceGenerationID: String? = nil,
                matchProxyLocation: Bool = true,
                lastProxyLocation: ProxyLocation? = nil) {
        self.startURL = startURL
        self.userAgent = userAgent
        self.proxy = proxy
        self.geolocation = geolocation
        self.timeZoneIdentifier = timeZoneIdentifier
        self.webRTCPolicy = webRTCPolicy
        self.ephemeral = ephemeral
        self.safeBrowsingEnabled = safeBrowsingEnabled
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.deviceGenerationID = deviceGenerationID
        self.matchProxyLocation = matchProxyLocation
        self.lastProxyLocation = lastProxyLocation
    }

    /// A new profile seeded from a generation: the generation supplies the UA (by reference,
    /// via `deviceGenerationID`) and its suggested defaults.
    public static func forGeneration(_ generation: DeviceGeneration) -> ProfileConfiguration {
        ProfileConfiguration(webRTCPolicy: generation.defaultWebRTCPolicy,
                             deviceGenerationID: generation.id)
    }

    /// The resolved generation (default if none/unknown is stored).
    public var deviceGeneration: DeviceGeneration { DeviceGenerations.resolved(id: deviceGenerationID) }

    /// The catalog User-Agent: an explicit `userAgent` override wins; otherwise the selected
    /// generation's catalog UA. `nil` when neither is set. The app applies
    /// `userAgent(hostSafariVersion:)`.
    public var effectiveUserAgent: String? {
        if let userAgent, !userAgent.isEmpty { return userAgent }
        return DeviceGenerations.generation(id: deviceGenerationID)?.userAgent
    }

    /// The User-Agent applied: an explicit `userAgent` override wins; otherwise the generation's
    /// (the default generation when none is stored), the macOS one naming the host's Safari
    /// version. Never WebKit's bare default, which lacks the "Version/… Safari/…" every Safari sends.
    public func userAgent(hostSafariVersion: String?) -> String {
        if let userAgent, !userAgent.isEmpty { return userAgent }
        return deviceGeneration.userAgent(hostSafariVersion: hostSafariVersion)
    }

    /// The WebRTC policy pages get: `.disabled` whenever a proxy is set. WebKit opens WebRTC's
    /// sockets (STUN, TURN over UDP or TCP, media) outside the data store's proxy, so with any
    /// other policy a page's ICE traffic leaves from this Mac's own address — STUN shows it to
    /// the page, a TURN server (relay-only) to whoever runs it. The stored choice comes back when
    /// the proxy is removed.
    public var effectiveWebRTCPolicy: WebRTCPolicy { proxy == nil ? webRTCPolicy : .disabled }

    /// Launching looks up where the proxy exits (`matchProxyLocation`).
    public var needsProxyLocation: Bool { matchProxyLocation && proxy != nil }

    /// This launch's lookup, or else the last location found for the same proxy.
    public func proxyLocation(lookedUp: ProxyLocation?) -> ProxyLocation? {
        guard needsProxyLocation, let proxy else { return nil }
        let endpoint = ProxyLocation.endpoint(of: proxy)
        if let lookedUp, lookedUp.proxyEndpoint == endpoint { return lookedUp }
        if let cached = lastProxyLocation, cached.proxyEndpoint == endpoint { return cached }
        return nil
    }

    /// The configuration a launch runs with: the proxy's time zone unless one is set explicitly.
    public func applying(_ location: ProxyLocation?) -> ProfileConfiguration {
        var configuration = self
        if timeZoneIdentifier == nil, let location, needsProxyLocation {
            configuration.timeZoneIdentifier = location.timeZoneIdentifier
        }
        return configuration
    }

    private enum CodingKeys: String, CodingKey {
        case startURL, userAgent, proxy, geolocation, timeZoneIdentifier, webRTCPolicy, ephemeral,
             safeBrowsingEnabled, historyEnabled, historyRetentionDays, deviceGenerationID,
             matchProxyLocation, lastProxyLocation
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults, so
    /// configurations written by older builds keep decrypting and decoding.
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
        deviceGenerationID = try c.decodeIfPresent(String.self, forKey: .deviceGenerationID)
        matchProxyLocation = try c.decodeIfPresent(Bool.self, forKey: .matchProxyLocation) ?? defaults.matchProxyLocation
        // A cache: one that no longer decodes is dropped, never a reason to fail the profile.
        lastProxyLocation = (try? c.decodeIfPresent(ProxyLocation.self, forKey: .lastProxyLocation)) ?? nil
    }

    /// Explicit so that `historyRetentionDays: nil` ("keep forever") is written as JSON null
    /// and not confused with "field absent" (→ default) when decoding.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(startURL, forKey: .startURL)
        try c.encodeIfPresent(userAgent, forKey: .userAgent)
        try c.encodeIfPresent(proxy, forKey: .proxy)
        try c.encode(geolocation, forKey: .geolocation)
        try c.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try c.encode(webRTCPolicy, forKey: .webRTCPolicy)
        try c.encode(ephemeral, forKey: .ephemeral)
        try c.encode(safeBrowsingEnabled, forKey: .safeBrowsingEnabled)
        try c.encode(historyEnabled, forKey: .historyEnabled)
        try c.encode(historyRetentionDays, forKey: .historyRetentionDays)
        try c.encodeIfPresent(deviceGenerationID, forKey: .deviceGenerationID)
        try c.encode(matchProxyLocation, forKey: .matchProxyLocation)
        try c.encodeIfPresent(lastProxyLocation, forKey: .lastProxyLocation)
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
        if let userAgent {
            guard !userAgent.isEmpty, userAgent.count <= 512,
                  userAgent.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
                throw CoreError.invalidConfiguration("user agent must be 1–512 printable ASCII characters")
            }
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
        // Anything else (scheme, port, credentials, spaces, newlines) is not resolvable by
        // NWEndpoint.Host and would make every load of the profile fail. See ProxyHostField.
        guard Self.isValidHost(host) else {
            throw CoreError.invalidConfiguration("proxy host must be a bare host name or IP address, not “\(host)”")
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
    /// local and STUN-discovered public IP are not exposed to the page. Requires the site to
    /// provide TURN, and the TURN server sees this Mac's address (WebKit never sends WebRTC
    /// through a proxy, so a proxied profile gets `.disabled`: `effectiveWebRTCPolicy`).
    case relayOnly
    /// WebKit default (host candidates are mDNS-obfuscated by WebKit, but STUN
    /// requests go out over UDP *outside* the proxy and reveal the real public IP).
    case unrestricted
}
