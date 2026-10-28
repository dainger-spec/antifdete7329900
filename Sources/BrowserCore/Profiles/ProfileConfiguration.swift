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

    /// The last location looked up for `proxy`: the time zone used without waiting for a new
    /// lookup, or when it fails, as long as the proxy is the same; and the exit IP the next
    /// launch compares with (`warnOnProxyIPChange`).
    public var lastProxyLocation: ProxyLocation?

    /// Warn when the proxy's exit IP differs from the one seen at the previous launch (the same
    /// proxy and credentials, `ProxyLocation.endpoint(of:)`, e.g. a provider that rotates or
    /// reassigned the address). Needs the lookup through the proxy, which then runs even without
    /// `matchProxyLocation`. The exit IP is stored only while this is on
    /// (`keepingStoredState(of:)`). Default off.
    public var warnOnProxyIPChange: Bool

    /// APPROXIMATION: JavaScript removal/wrapping of `RTCPeerConnection`.
    public var webRTCPolicy: WebRTCPolicy

    /// NATIVE: use `WKWebsiteDataStore.nonPersistent()` — no website data written to disk,
    /// everything discarded when the profile stops. History is kept in memory only;
    /// bookmarks (explicit user data) are still saved, encrypted.
    public var ephemeral: Bool

    /// Opt-in: open this profile's windows via Safari.framework (AppController path)
    /// instead of the in-process WKWebView. Requires the safari-framework-path build.
    /// Default off; older configurations decode as off.
    public var useSafariChrome: Bool

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

    /// AutoFill for user names and passwords, as Safari's setting of that name: after a sign-in the
    /// browser offers to save what was typed, and a login field shows the profile's saved logins
    /// for the site. Off: nothing is offered or saved; the explicit toolbar buttons still work.
    /// Default on; older configurations decode as on.
    public var passwordAutoFill: Bool

    /// Websites the user answered "Never for This Website" for: no offer to save there (any page
    /// of the same site, `WebOrigin.site`). Origins, `scheme://host[:port]`.
    public var passwordNeverSaveSites: [String]

    /// Sync this profile's persistent cookies with the other devices, when sync is set up
    /// (`cookies.bin`, merged per cookie). Session cookies never sync, nor does anything of an
    /// ephemeral profile. Default on; older configurations decode as on.
    public var syncCookies: Bool

    /// When the user last changed these settings (the editor, "Never for This Website", the
    /// passwords' excluded websites); not what the browser keeps for itself (the proxy location).
    /// When two devices changed a profile's settings, sync keeps the newer ones and the other
    /// device's as `config.bin.conflict`. Nil: not edited since the profile was created, or
    /// rewritten by an older build.
    public var settingsModifiedAt: Date?

    /// Set by the app for one launch, never stored: the relay in the packet tunnel that carries
    /// this profile's WebRTC through its SOCKS5 proxy. Nil when the tunnel is not available.
    public var webRTCRelay: WebRTCRelay?

    public init(startURL: URL? = nil,
                userAgent: String? = nil,
                proxy: ProxySettings? = nil,
                geolocation: GeolocationSetting = .deny,
                timeZoneIdentifier: String? = nil,
                webRTCPolicy: WebRTCPolicy = .disabled,
                ephemeral: Bool = false,
                useSafariChrome: Bool = false,
                safeBrowsingEnabled: Bool = false,
                historyEnabled: Bool = true,
                historyRetentionDays: Int? = 90,
                deviceGenerationID: String? = nil,
                matchProxyLocation: Bool = true,
                lastProxyLocation: ProxyLocation? = nil,
                warnOnProxyIPChange: Bool = false,
                passwordAutoFill: Bool = true,
                passwordNeverSaveSites: [String] = [],
                syncCookies: Bool = true,
                settingsModifiedAt: Date? = nil) {
        self.startURL = startURL
        self.userAgent = userAgent
        self.proxy = proxy
        self.geolocation = geolocation
        self.timeZoneIdentifier = timeZoneIdentifier
        self.webRTCPolicy = webRTCPolicy
        self.ephemeral = ephemeral
        self.useSafariChrome = useSafariChrome
        self.safeBrowsingEnabled = safeBrowsingEnabled
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.deviceGenerationID = deviceGenerationID
        self.matchProxyLocation = matchProxyLocation
        self.lastProxyLocation = lastProxyLocation
        self.warnOnProxyIPChange = warnOnProxyIPChange
        self.passwordAutoFill = passwordAutoFill
        self.passwordNeverSaveSites = passwordNeverSaveSites
        self.syncCookies = syncCookies
        self.settingsModifiedAt = settingsModifiedAt
    }

    /// Whether this profile's cookies take part in sync (never for an ephemeral profile).
    public var syncsCookies: Bool { syncCookies && !ephemeral }

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

    /// How this launch's pages do WebRTC. WebKit opens WebRTC's sockets (STUN, TURN over UDP or
    /// TCP, media) outside the data store's proxy, so with a proxy a page's ICE traffic would
    /// leave from this Mac's own address — STUN shows it to the page, a TURN server to whoever
    /// runs it. A proxied profile therefore gets WebRTC only through the packet tunnel's relay
    /// (`webRTCRelay`, set at launch when the tunnel is on and the proxy is SOCKS5, the kind that
    /// carries UDP); otherwise it is switched off. The stored choice is kept either way.
    public var webRTCRouting: WebRTCRouting {
        if webRTCPolicy == .disabled { return .off }
        guard let proxy else { return .native(webRTCPolicy) }
        if proxy.kind == .socks5, let webRTCRelay { return .relay(webRTCRelay) }
        return .off
    }

    /// The policy the routing amounts to: `.disabled` when WebRTC is off, `.relayOnly` through the
    /// tunnel's relay, the stored policy without a proxy.
    public var effectiveWebRTCPolicy: WebRTCPolicy {
        switch webRTCRouting {
        case .off: return .disabled
        case let .native(policy): return policy
        case .relay: return .relayOnly
        }
    }

    /// The profile runs in its proxy's time zone (`matchProxyLocation`).
    public var needsProxyLocation: Bool { matchProxyLocation && proxy != nil }

    /// Launching asks a geolocation service through the proxy: for its time zone, or for its exit
    /// IP (`warnOnProxyIPChange`). The same request also finds a proxy that wants credentials.
    public var needsProxyLookup: Bool { proxy != nil && (matchProxyLocation || warnOnProxyIPChange) }

    /// The location remembered for the current proxy, if any.
    public var rememberedProxyLocation: ProxyLocation? {
        guard let proxy, let cached = lastProxyLocation, cached.proxyEndpoint == ProxyLocation.endpoint(of: proxy) else { return nil }
        return cached
    }

    /// This configuration as an edit saves it: what the browser keeps itself is not part of the
    /// edit, so it is kept as `stored` has it (a lookup or a "Never for This Website" may have
    /// written something newer while the editor was open): the proxy location, with its exit IP
    /// only while the warning that asks for it is on, and the sites passwords are never saved for.
    public func keepingStoredState(of stored: ProfileConfiguration?) -> ProfileConfiguration {
        var edited = self
        if let stored {
            edited.lastProxyLocation = stored.lastProxyLocation
            edited.passwordNeverSaveSites = stored.passwordNeverSaveSites
        }
        if !edited.warnOnProxyIPChange || edited.proxy == nil { edited.lastProxyLocation?.exitIP = nil }
        return edited
    }

    /// What to store for the editor's version of a stored configuration: what the browser keeps
    /// for itself as `stored` has it (`keepingStoredState(of:)`), and `settingsModifiedAt` moved
    /// to `time` only when a setting changed (saving an unchanged editor is no newer edit).
    public func savingEdit(over stored: ProfileConfiguration?, at time: Date = Date()) -> ProfileConfiguration {
        var edited = keepingStoredState(of: stored)
        edited.settingsModifiedAt = stored?.settingsModifiedAt
        if !edited.hasSameSettings(as: stored) { edited.settingsModifiedAt = time }
        return edited
    }

    /// The same settings: equal but for what the browser keeps for itself (the proxy location
    /// found at a launch) and when they were last changed.
    func hasSameSettings(as other: ProfileConfiguration?) -> Bool {
        func settings(_ configuration: ProfileConfiguration) -> ProfileConfiguration {
            var settings = configuration
            settings.settingsModifiedAt = nil
            settings.lastProxyLocation = nil
            settings.webRTCRelay = nil
            return settings
        }
        return other.map { settings($0) == settings(self) } ?? false
    }

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
        case startURL, userAgent, proxy, geolocation, timeZoneIdentifier, webRTCPolicy, ephemeral, useSafariChrome,
             safeBrowsingEnabled, historyEnabled, historyRetentionDays, deviceGenerationID,
             matchProxyLocation, lastProxyLocation, warnOnProxyIPChange, passwordAutoFill, passwordNeverSaveSites,
             syncCookies, settingsModifiedAt
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
        useSafariChrome = try c.decodeIfPresent(Bool.self, forKey: .useSafariChrome) ?? defaults.useSafariChrome
        safeBrowsingEnabled = try c.decodeIfPresent(Bool.self, forKey: .safeBrowsingEnabled) ?? defaults.safeBrowsingEnabled
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? defaults.historyEnabled
        historyRetentionDays = c.contains(.historyRetentionDays)
            ? try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays)
            : defaults.historyRetentionDays
        deviceGenerationID = try c.decodeIfPresent(String.self, forKey: .deviceGenerationID)
        matchProxyLocation = try c.decodeIfPresent(Bool.self, forKey: .matchProxyLocation) ?? defaults.matchProxyLocation
        // A cache: one that no longer decodes is dropped, never a reason to fail the profile.
        lastProxyLocation = (try? c.decodeIfPresent(ProxyLocation.self, forKey: .lastProxyLocation)) ?? nil
        warnOnProxyIPChange = try c.decodeIfPresent(Bool.self, forKey: .warnOnProxyIPChange) ?? defaults.warnOnProxyIPChange
        passwordAutoFill = try c.decodeIfPresent(Bool.self, forKey: .passwordAutoFill) ?? defaults.passwordAutoFill
        passwordNeverSaveSites = try c.decodeIfPresent([String].self, forKey: .passwordNeverSaveSites) ?? defaults.passwordNeverSaveSites
        syncCookies = try c.decodeIfPresent(Bool.self, forKey: .syncCookies) ?? defaults.syncCookies
        settingsModifiedAt = try? c.decodeIfPresent(Date.self, forKey: .settingsModifiedAt)
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
        try c.encode(useSafariChrome, forKey: .useSafariChrome)
        try c.encode(safeBrowsingEnabled, forKey: .safeBrowsingEnabled)
        try c.encode(historyEnabled, forKey: .historyEnabled)
        try c.encode(historyRetentionDays, forKey: .historyRetentionDays)
        try c.encodeIfPresent(deviceGenerationID, forKey: .deviceGenerationID)
        try c.encode(matchProxyLocation, forKey: .matchProxyLocation)
        try c.encodeIfPresent(lastProxyLocation, forKey: .lastProxyLocation)
        try c.encode(warnOnProxyIPChange, forKey: .warnOnProxyIPChange)
        try c.encode(passwordAutoFill, forKey: .passwordAutoFill)
        try c.encode(passwordNeverSaveSites, forKey: .passwordNeverSaveSites)
        try c.encode(syncCookies, forKey: .syncCookies)
        try c.encodeIfPresent(settingsModifiedAt, forKey: .settingsModifiedAt)
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

/// A TURN relay a profile's pages are given as their only ICE server (the packet tunnel's).
public struct WebRTCRelay: Equatable, Sendable {
    public var urls: [String]
    public var username: String
    public var credential: String

    public init(urls: [String], username: String, credential: String) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public enum WebRTCRouting: Equatable, Sendable {
    /// No proxy: WebKit's own WebRTC as the stored policy says.
    case native(WebRTCPolicy)
    /// Switched off in the engine.
    case off
    /// Relay-only through the packet tunnel's TURN server and the profile's SOCKS5 proxy.
    case relay(WebRTCRelay)
}

public enum WebRTCPolicy: String, Codable, CaseIterable, Sendable {
    /// Remove RTCPeerConnection & friends from the page. Strongest option. Breaks WebRTC sites.
    case disabled
    /// Force `iceTransportPolicy: "relay"`: no host/srflx candidates are gathered, so the
    /// local and STUN-discovered public IP are not exposed to the page. Requires the site to
    /// provide TURN, and the TURN server sees this Mac's address. With a proxy, WebRTC instead
    /// goes through the packet tunnel's relay, or is off (`webRTCRouting`).
    case relayOnly
    /// WebKit default (host candidates are mDNS-obfuscated by WebKit, but STUN
    /// requests go out over UDP *outside* the proxy and reveal the real public IP).
    case unrestricted
}
