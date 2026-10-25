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
///
/// What it does NOT cover (platform limitations):
///   * WebRTC UDP (STUN/TURN, media). See `PrivacyScripts` for the JS-level mitigation.
///   * Traffic the app process itself makes outside WebKit (none in this prototype besides sync).
///   * WebKit's Safe Browsing lookups (made by the system outside the data store); this is
///     why `safeBrowsingEnabled` defaults to false.
///   * DNS prefetching of link hostnames before navigation (WebKit may resolve via the system
///     resolver). There is no public switch to disable DNS prefetch in WKWebView.
enum ProxyConfigurationFactory {
    static func make(_ settings: ProxySettings?) -> [ProxyConfiguration] {
        guard let settings, let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.port)) else { return [] }
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
            configuration.applyCredential(username: username, password: password)
        }
        configuration.allowFailover = false
        configuration.excludedDomains = settings.excludedDomains
        return [configuration]
    }
}
