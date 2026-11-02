import BrowserCore
import Foundation
import os
import TunnelCore

/// The IPv4 address a profile's SOCKS5 proxy sends its TCP from — the address sites see the
/// profile's pages come from. WebRTC goes through the relay only when the proxy's UDP leaves from
/// this very address (`ProxyUDPCheck` finds that one), and every allocation of the relay is held to
/// it (`TunnelRoute.exit`): a site shown one address by the pages and another by WebRTC has learned
/// the profile goes through a proxy, which is worse than no WebRTC (docs/TUNNEL.md, "One address").
///
/// PRIVACY: asked only THROUGH the proxy, never direct — whatever the profile's bypass list says
/// (`ProxyConfigurationFactory.makeWithoutBypass`, `allowFailover = false`) — over HTTPS, with the
/// certificate checked without this Mac fetching anything (`ServerTrust`), no cookies, no cache, the
/// profile's User-Agent. From Cloudflare's trace at Cloudflare's IPv4 addresses: no name is resolved
/// anywhere, and the answer can only be the proxy's IPv4 exit. Cloudflare's STUN server is one of
/// the two the UDP check asks already: no other party learns of the launch.
@MainActor
enum ProxyExitLookup {
    /// Asked in turn until one answers with an IPv4 address. Replaced by the self-test with the
    /// trace of its own proxy.
    static var endpoints = [URL(string: "https://1.1.1.1/cdn-cgi/trace")!, URL(string: "https://1.0.0.1/cdn-cgi/trace")!]

    /// How long one endpoint is waited for before the next is asked.
    static var perEndpoint: TimeInterval = 5

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProxyExitLookup")

    /// The proxy's IPv4 TCP exit; nil when no endpoint answered with one within `timeout` (the
    /// proxy refused, cut or held the request, or wants credentials the profile has not got).
    static func lookUp(proxy: ProxySettings, userAgent: String, timeout: TimeInterval = 9) async -> IPAddr? {
        guard let proxies = try? ProxyConfigurationFactory.makeWithoutBypass(proxy), !proxies.isEmpty else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = proxies
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "text/plain"]
        configuration.waitsForConnectivity = false
        let challenges = ProxyChallengeObserver(credential: proxy.username.map {
            URLCredential(user: $0, password: proxy.password ?? "", persistence: .forSession)
        })
        let session = URLSession(configuration: configuration, delegate: challenges, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(timeout)
        for endpoint in endpoints {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.5, !challenges.proxyRequiredCredentials else { break }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = min(left, perEndpoint)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let exit = ExitTrace.ipv4(in: String(decoding: data, as: UTF8.self)) {
                    return exit
                }
                log.notice("\(endpoint.host ?? "?", privacy: .public) gave no IPv4 exit through the proxy (HTTP \(status))")
            } catch {
                log.notice("\(endpoint.host ?? "?", privacy: .public) through the proxy failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        return nil
    }
}
