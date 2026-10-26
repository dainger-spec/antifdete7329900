import Foundation

/// How a profile's traffic leaves this Mac, and — crucially — whether **UDP** (QUIC/HTTP3 and
/// WebRTC) shares the same exit as TCP.
///
/// ## The platform limitation this exists for
///
/// `WKWebsiteDataStore.proxyConfigurations` (the `ProxyConfiguration` API, macOS 14+) proxies
/// **TCP only**: HTTP(S) over TCP is tunnelled through the HTTP CONNECT / SOCKS5 proxy, but the
/// system does not perform SOCKS5 UDP ASSOCIATE, so UDP flows — QUIC/HTTP3 and WebRTC media and
/// STUN — leave through this Mac's real interface, revealing its IP even when every TCP byte goes
/// through the proxy. There is no public per-data-store API to proxy UDP.
///
/// To make UDP and TCP share one exit IP, all of a profile's packets must be captured below the
/// socket layer and forwarded by a tunnel. On macOS the supported way is a
/// `NEPacketTunnelProvider` (a per-profile VPN). This type is the platform-independent decision
/// model for that: given a profile's proxy and whether the unified tunnel is switched on, it says
/// what the egress is and whether UDP is covered. The tunnel provider itself is macOS-only and
/// needs a provisioning profile with the packet-tunnel entitlement; see the app layer and
/// `docs/NETWORK.md`.
public enum ProfileEgress: Equatable, Sendable {
    /// No proxy, no tunnel: ordinary network of this Mac. TCP and UDP both use the real IP.
    case direct
    /// Today's default when a proxy is set and the tunnel is off: TCP goes through the proxy,
    /// UDP is NOT covered (it uses the real IP). `proxy` is the TCP proxy.
    case proxyTCPOnly(ProxySettings)
    /// The unified tunnel is on: every packet (TCP and UDP) enters the tunnel and leaves through
    /// `exit`. One exit IP for everything; nothing bypasses.
    case tunnel(TunnelExit)

    /// Where a tunnel sends the traffic it captures.
    public enum TunnelExit: Equatable, Sendable {
        /// Out through the given proxy. `udp` says how the tunnel handles UDP given this proxy
        /// (the proxy may not carry UDP; see `UDPHandling`).
        case proxy(ProxySettings, udp: UDPHandling)
        /// Out through this Mac's real interface, but still via the tunnel, so the app's UDP and
        /// TCP are observed as one consistent source. (Exit IP is this Mac's IP.)
        case directInterface
    }

    /// What a tunnel does with the profile's UDP, decided by whether its exit proxy can carry UDP.
    public enum UDPHandling: String, Equatable, Sendable {
        /// The exit proxy carries UDP to the same exit as TCP (SOCKS5 with UDP ASSOCIATE). UDP and
        /// TCP share the exit IP.
        case throughProxy
        /// The exit proxy is TCP-only (HTTP CONNECT, or SOCKS5 without UDP ASSOCIATE). The tunnel
        /// DROPS UDP rather than letting it leak. QUIC falls back to TCP; WebRTC gets no
        /// candidates. Never the real IP.
        case dropped
    }

    /// Does this egress cover UDP (QUIC/HTTP3, WebRTC) — i.e. UDP cannot escape to the real IP?
    public var coversUDP: Bool {
        switch self {
        case .direct: return true // nothing is hidden; "covered" means consistent, and direct is consistent
        case .proxyTCPOnly: return false // the leak this whole type documents
        case .tunnel: return true // captured: either sent to the exit or dropped, never leaked
        }
    }

    /// True when a page's WebRTC could reveal this Mac's real public IP. The UI warns on this.
    public var webRTCMayLeakRealIP: Bool {
        if case .proxyTCPOnly = self { return true }
        return false
    }
}

/// A profile's network mode as chosen in the editor.
public struct ProfileNetwork: Codable, Equatable, Sendable {
    public var proxy: ProxySettings?
    /// Capture all traffic (TCP+UDP) in a per-profile tunnel so one exit IP serves both. Off by
    /// default: the tunnel needs a Network Extension that only a provisioned build can load.
    public var unifiedTunnel: Bool

    public init(proxy: ProxySettings? = nil, unifiedTunnel: Bool = false) {
        self.proxy = proxy
        self.unifiedTunnel = unifiedTunnel
    }

    /// The egress for this profile. `tunnelAvailable` is whether the app can actually run the
    /// packet tunnel on this build (entitlement + provisioning present and the provider loaded).
    ///
    /// Fail-closed: if the unified tunnel is requested but the tunnel can't run, the result is
    /// `nil` — the session must get NO network rather than silently falling back to TCP-only
    /// (which would leak UDP) or to direct.
    public func egress(tunnelAvailable: Bool) -> ProfileEgress? {
        if unifiedTunnel {
            guard tunnelAvailable else { return nil } // fail-closed
            if let proxy {
                return .tunnel(.proxy(proxy, udp: Self.udpHandling(for: proxy)))
            }
            return .tunnel(.directInterface)
        }
        if let proxy { return .proxyTCPOnly(proxy) }
        return .direct
    }

    /// Whether the exit proxy can carry UDP to the same exit as TCP. Conservative: only SOCKS5
    /// may (via UDP ASSOCIATE), and only when we don't tunnel to it over TLS; HTTP CONNECT never
    /// does. When unsure, UDP is dropped, never leaked.
    static func udpHandling(for proxy: ProxySettings) -> ProfileEgress.UDPHandling {
        switch proxy.kind {
        case .socks5 where !proxy.tlsToProxy: return .throughProxy
        case .socks5, .httpConnect: return .dropped
        }
    }
}
