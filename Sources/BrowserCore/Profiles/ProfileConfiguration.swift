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
    /// local-time accessors. `nil` → system time zone. IANA identifier, e.g. "Europe/Berlin".
    public var timeZoneIdentifier: String?

    /// APPROXIMATION: JavaScript removal/wrapping of `RTCPeerConnection`.
    public var webRTCPolicy: WebRTCPolicy

    /// NATIVE: use `WKWebsiteDataStore.nonPersistent()` — nothing written to disk,
    /// everything discarded when the profile stops.
    public var ephemeral: Bool

    /// NATIVE: `WKPreferences.isFraudulentWebsiteWarningEnabled`. Safe Browsing lookups
    /// are made by WebKit outside the per-profile proxy, so default is off.
    public var safeBrowsingEnabled: Bool

    public init(startURL: URL? = nil,
                userAgent: String? = nil,
                proxy: ProxySettings? = nil,
                geolocation: GeolocationSetting = .deny,
                timeZoneIdentifier: String? = nil,
                webRTCPolicy: WebRTCPolicy = .disabled,
                ephemeral: Bool = false,
                safeBrowsingEnabled: Bool = false) {
        self.startURL = startURL
        self.userAgent = userAgent
        self.proxy = proxy
        self.geolocation = geolocation
        self.timeZoneIdentifier = timeZoneIdentifier
        self.webRTCPolicy = webRTCPolicy
        self.ephemeral = ephemeral
        self.safeBrowsingEnabled = safeBrowsingEnabled
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
