import BrowserCore
import Foundation
import Network
import os

/// Where a profile's proxy exits: a geolocation service asked THROUGH the proxy sees the
/// proxy's exit IP and answers with it, its time zone and country (`ProxyLocation`).
///
/// PRIVACY: the query goes to a third-party service (below), over HTTPS, only through the
/// profile's proxy — never direct: `ProxyConfigurationFactory` sets `allowFailover = false` —
/// with the profile's User-Agent, no cookies and no cache. It runs when a profile with a proxy
/// launches with `matchProxyLocation` or `warnOnProxyIPChange` (`needsProxyLookup`). Each lookup
/// has its own URLSession with that profile's proxy: lookups of profiles launched together do
/// not share connections or credentials.
@MainActor
enum ProxyGeoLookup {
    struct Service {
        let url: URL
        let timeZoneKeyPath: [String]
        let countryKeyPath: [String]
        var ipKeyPath: [String] = ["ip"]
    }

    /// HTTPS services that need no API key, tried in order until one answers. Replaced by the
    /// self-test with an endpoint of its local proxy.
    static var services: [Service] = [
        Service(url: URL(string: "https://ipinfo.io/json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"]),
        Service(url: URL(string: "https://get.geojs.io/v1/ip/geo.json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country_code"]),
        Service(url: URL(string: "https://ipwho.is/")!, timeZoneKeyPath: ["timezone", "id"], countryKeyPath: ["country_code"]),
    ]

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProxyGeoLookup")

    struct Result: Sendable {
        /// nil when no service answered within the timeout (proxy down, services blocked or rate-limited).
        var location: ProxyLocation?
        /// The proxy answered 407 and the profile has no credentials for it. Only this lookup sees
        /// that: WebKit keeps a proxy's challenge to itself and leaves the page loading forever.
        var proxyRequiresCredentials = false
    }

    static func lookUp(proxy: ProxySettings, userAgent: String, timeout: TimeInterval = 6) async -> Result {
        guard let proxies = try? ProxyConfigurationFactory.make(proxy), !proxies.isEmpty else { return Result() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = proxies
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json"]
        configuration.waitsForConnectivity = false
        let challenges = ProxyChallengeObserver(credential: proxy.username.map {
            URLCredential(user: $0, password: proxy.password ?? "", persistence: .forSession)
        })
        let session = URLSession(configuration: configuration, delegate: challenges, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var result = Result()
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
                                                                     ipKeyPath: service.ipKeyPath, proxyEndpoint: endpoint) {
                    log.info("Proxy \(endpoint, privacy: .private) exits in \(location.timeZoneIdentifier, privacy: .public) (\(location.countryCode ?? "?", privacy: .public)) per \(service.url.host ?? "?", privacy: .public)")
                    result.location = location
                    return result
                }
                log.notice("\(service.url.host ?? "?", privacy: .public) gave no location (HTTP \(status))")
            } catch {
                log.notice("\(service.url.host ?? "?", privacy: .public) through the proxy failed: \(error.localizedDescription, privacy: .public)")
            }
            if challenges.proxyRequiredCredentials {
                result.proxyRequiresCredentials = true
                return result
            }
        }
        result.proxyRequiresCredentials = challenges.proxyRequiredCredentials
        return result
    }
}

/// Answers the proxy's own challenge with the profile's credentials, and notes when it has none
/// to give (the load is then cancelled: fail-closed).
private final class ProxyChallengeObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let credential: URLCredential?
    private let lock = NSLock()
    private var _proxyRequiredCredentials = false

    init(credential: URLCredential?) {
        self.credential = credential
    }

    var proxyRequiredCredentials: Bool { lock.withLock { _proxyRequiredCredentials } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.isProxy(), space.authenticationMethod != NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if challenge.previousFailureCount == 0, let credential {
            completionHandler(.useCredential, credential)
        } else {
            if credential == nil { lock.withLock { _proxyRequiredCredentials = true } }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
