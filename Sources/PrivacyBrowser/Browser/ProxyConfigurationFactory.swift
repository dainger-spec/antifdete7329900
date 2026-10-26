import BrowserCore
import Foundation
import Network

/// Maps `ProxySettings` onto Network.framework `ProxyConfiguration`, which WebKit applies
/// per data store via `WKWebsiteDataStore.proxyConfigurations` (macOS 14+).
///
/// What this covers (native, enforced by WebKit's network process for that data store):
///   * HTTP and HTTPS loads, WebSockets, fetch/XHR, service-worker fetches, media loads.
///   * `allowFailover = false`: if the proxy is unreachable, loads fail instead of
///     silently going direct (fail-closed).
///   * DNS: with HTTP CONNECT the hostname is sent to the proxy in the CONNECT request;
///     with SOCKS5 Network.framework sends the hostname (remote resolution). Verify on
///     your setup with a packet capture (`sudo tcpdump -i any port 53`), as Apple does not
///     document this explicitly.
///   * QUIC: with a proxy WebKit's loads stay on HTTP/2 through it; HTTP/3 is not used
///     (measured by `scripts/leak_check.py` against a site that offers HTTP/3).
///
/// What it does NOT cover (platform limitations):
///   * WebRTC (STUN, TURN over UDP or TCP, media): WebKit opens those sockets itself, without
///     the proxy. A proxied profile runs with WebRTC off, or relay-only through the packet
///     tunnel's relay for a SOCKS5 proxy (`ProfileConfiguration.webRTCRouting`, docs/TUNNEL.md).
///   * Traffic the app process itself makes outside WebKit (none in this prototype besides sync).
///   * WebKit's Safe Browsing lookups (made by the system outside the data store); this is
///     why `safeBrowsingEnabled` defaults to false.
///   * DNS prefetching of link hostnames before navigation (WebKit may resolve via the system
///     resolver). There is no public switch to disable DNS prefetch in WKWebView.
enum ProxyConfigurationFactory {
    /// `[]` only for "no proxy configured". A configured proxy that cannot be applied throws:
    /// returning `[]` would mean a direct connection, i.e. fail-open.
    static func make(_ settings: ProxySettings?) throws -> [ProxyConfiguration] {
        guard let settings else { return [] }
        try settings.validate() // a bare host name or IP, port 1–65535, consistent credentials
        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.port)) else {
            throw CoreError.invalidConfiguration("proxy port \(settings.port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(settings.host), port: port)

        var configuration: ProxyConfiguration
        switch settings.kind {
        case .httpConnect:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint,
                                               tlsOptions: settings.tlsToProxy ? NWProtocolTLS.Options() : nil)
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        if let username = settings.username, let password = settings.password {
            // Also answered by BrowserTab when WebKit forwards the proxy's auth challenge.
            configuration.applyCredential(username: username, password: password)
        }
        configuration.allowFailover = false
        configuration.excludedDomains = settings.excludedDomains
        return [configuration]
    }
}
