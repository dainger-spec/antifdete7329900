import BrowserCore
import Foundation
import Network
import os

/// Where a profile's proxy exits: a geolocation service asked THROUGH the proxy sees the
/// proxy's exit IP and answers with its time zone and country (`ProxyLocation`).
///
/// PRIVACY: the query goes to a third-party service (below), over HTTPS, only through the
/// profile's proxy — never direct: `ProxyConfigurationFactory` sets `allowFailover = false` —
/// with the profile's User-Agent, no cookies and no cache. It runs when a profile with a proxy
/// and `matchProxyLocation` launches.
@MainActor
enum ProxyGeoLookup {
    struct Service {
        let url: URL
        let timeZoneKeyPath: [String]
        let countryKeyPath: [String]
    }

    /// HTTPS services that need no API key, tried in order until one answers. Replaced by the
    /// self-test with an endpoint of its local proxy.
    static var services: [Service] = [
        Service(url: URL(string: "https://ipinfo.io/json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"]),
        Service(url: URL(string: "https://get.geojs.io/v1/ip/geo.json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country_code"]),
        Service(url: URL(string: "https://ipwho.is/")!, timeZoneKeyPath: ["timezone", "id"], countryKeyPath: ["country_code"]),
    ]

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProxyGeoLookup")

    /// nil when no service answered within `timeout` seconds in total (proxy down, services
    /// blocked or rate-limited).
    static func lookUp(proxy: ProxySettings, userAgent: String, timeout: TimeInterval = 6) async -> ProxyLocation? {
        guard let proxies = try? ProxyConfigurationFactory.make(proxy), !proxies.isEmpty else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = proxies
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json"]
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(timeout)
        let endpoint = ProxyLocation.endpoint(of: proxy)
        for service in services {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.5 else { break }
            var request = URLRequest(url: service.url)
            request.timeoutInterval = remaining
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let location = ProxyLocation.parse(data, timeZoneKeyPath: service.timeZoneKeyPath,
                                                                     countryKeyPath: service.countryKeyPath,
                                                                     proxyEndpoint: endpoint) {
                    log.info("Proxy \(endpoint, privacy: .private) exits in \(location.timeZoneIdentifier, privacy: .public) (\(location.countryCode ?? "?", privacy: .public)) per \(service.url.host ?? "?", privacy: .public)")
                    return location
                }
                log.notice("\(service.url.host ?? "?", privacy: .public) gave no location (HTTP \(status))")
            } catch {
                log.notice("\(service.url.host ?? "?", privacy: .public) through the proxy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}
