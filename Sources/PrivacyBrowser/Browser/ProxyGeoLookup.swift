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
        /// Where the answer says the exit's city and network (`ProxyExitDetails`), when it does.
        var cityKeyPath: [String]? = nil
        var asnKeyPath: [String]? = nil
        var organizationKeyPath: [String]? = nil
    }

    /// HTTPS services that need no API key, asked in order until one answers (`nextServiceAfter`):
    /// a proxy that cuts or holds one of them (they are blocked often) must leave time for the
    /// others. Replaced by the self-test with endpoints of its local proxy.
    static var services: [Service] = [
        Service(url: URL(string: "https://ipinfo.io/json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country"],
                cityKeyPath: ["city"], asnKeyPath: ["org"], organizationKeyPath: ["org"]),
        Service(url: URL(string: "https://get.geojs.io/v1/ip/geo.json")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country_code"],
                cityKeyPath: ["city"], asnKeyPath: ["asn"], organizationKeyPath: ["organization_name"]),
        Service(url: URL(string: "https://ipwho.is/")!, timeZoneKeyPath: ["timezone", "id"], countryKeyPath: ["country_code"],
                cityKeyPath: ["city"], asnKeyPath: ["connection", "asn"], organizationKeyPath: ["connection", "org"]),
        Service(url: URL(string: "https://ipapi.co/json/")!, timeZoneKeyPath: ["timezone"], countryKeyPath: ["country_code"],
                cityKeyPath: ["city"], asnKeyPath: ["asn"], organizationKeyPath: ["org"]),
    ]

    /// How long a service is waited for alone: after that the next one is asked as well, and the
    /// first answer with a location wins. One that fails is followed by the next at once. The first
    /// service used to have the whole lookup's time: a proxy that held ipinfo.io's connection open
    /// used it all, and the services after it were never asked (the owner's Mac, 2026-10-30:
    /// "ipinfo.io through the proxy failed" at every launch, and no location). A hard limit per
    /// service would cut off one that is slow through a slow proxy, and is the only one that
    /// answers: none here, a service keeps going until the lookup's own time is up. When the first
    /// answers in time, it is the only one asked, as before.
    static var nextServiceAfter: TimeInterval = 3

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProxyGeoLookup")

    struct Result: Sendable {
        /// nil when no service answered within the timeout (proxy down, services blocked or rate-limited).
        var location: ProxyLocation?
        /// The proxy answered 407 and the profile has no credentials for it. Only this lookup sees
        /// that: WebKit keeps a proxy's challenge to itself and leaves the page loading forever.
        var proxyRequiresCredentials = false
        /// A service's HTTP answer came back through the proxy, whatever it said (a rate-limited
        /// service answers without a location): the proxy carries traffic. The proxy checker's
        /// "alive" (`ProxyChecker`).
        var answered = false
        /// How long the first request that got an answer took: the connection to the proxy, the
        /// tunnel through it and the service's reply. Nil when nothing answered.
        var latency: TimeInterval?
        /// The exit's city and network, from the answer that gave the location.
        var details = ProxyExitDetails()
        /// Every connection the lookup's requests were made on, as the URL loading system reports
        /// them (`URLSessionTaskMetrics`): the proxy's own address, never a service's. The
        /// self-test checks that a dead proxy was not gone around.
        var connections: [Connection] = []
    }

    struct Connection: Equatable, Sendable, CustomStringConvertible {
        var address: String
        var port: Int?
        var description: String { "\(address.contains(":") ? "[\(address)]" : address):\(port.map(String.init) ?? "?")" }
    }

    static func lookUp(proxy: ProxySettings, userAgent: String, timeout: TimeInterval = 12) async -> Result {
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
        let services = Self.services
        let stagger = UInt64(max(0.1, nextServiceAfter) * 1_000_000_000)
        let untilDeadline = UInt64(max(0, timeout) * 1_000_000_000)
        await withTaskGroup(of: Event.self) { group in
            var next = 0
            var asking = 0
            group.addTask {
                try? await Task.sleep(nanoseconds: untilDeadline)
                return .deadline
            }
            var askNext = !services.isEmpty
            while true {
                if askNext, next < services.count {
                    let service = services[next]
                    next += 1
                    asking += 1
                    group.addTask { .answer(await ask(service, session: session, endpoint: endpoint, deadline: deadline)) }
                    if next < services.count {
                        group.addTask {
                            try? await Task.sleep(nanoseconds: stagger)
                            return .nextDue
                        }
                    }
                }
                askNext = false
                if asking == 0 {
                    break // every service asked has failed, and there is none left
                }
                guard let event = await group.next() else { break }
                switch event {
                case .deadline:
                    group.cancelAll()
                    return
                case .nextDue:
                    askNext = true
                case .answer(let answer):
                    asking -= 1
                    if let latency = answer.answeredAfter, !result.answered {
                        result.answered = true
                        result.latency = latency
                    }
                    if let location = answer.location {
                        result.location = location
                        result.details = answer.details
                        group.cancelAll()
                        return
                    }
                    // A proxy that wants a login it has not got answers no service: no use asking more.
                    if challenges.proxyRequiredCredentials {
                        group.cancelAll()
                        return
                    }
                    askNext = true // this one failed: the next at once
                }
            }
            group.cancelAll()
        }
        result.proxyRequiresCredentials = challenges.proxyRequiredCredentials
        result.connections = challenges.connections
        return result
    }

    private enum Event: Sendable {
        case answer(Answer)
        /// The service asked last has been waited for alone long enough (`nextServiceAfter`).
        case nextDue
        /// The lookup's own time is up.
        case deadline
    }

    private struct Answer: Sendable {
        var location: ProxyLocation?
        var details = ProxyExitDetails()
        /// How long the service took to answer at all (any HTTP answer); nil when it did not.
        var answeredAfter: TimeInterval?
    }

    /// One service, asked through the lookup's session, until the lookup's deadline.
    private static func ask(_ service: Service, session: URLSession, endpoint: String, deadline: Date) async -> Answer {
        var request = URLRequest(url: service.url)
        request.timeoutInterval = max(0.5, deadline.timeIntervalSinceNow)
        let asked = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answeredAfter = response is HTTPURLResponse ? Date().timeIntervalSince(asked) : nil
            if status == 200, let location = ProxyLocation.parse(data, timeZoneKeyPath: service.timeZoneKeyPath,
                                                                 countryKeyPath: service.countryKeyPath,
                                                                 ipKeyPath: service.ipKeyPath, proxyEndpoint: endpoint) {
                log.info("Proxy \(endpoint, privacy: .private) exits in \(location.timeZoneIdentifier, privacy: .private) (\(location.countryCode ?? "?", privacy: .private)) per \(service.url.host ?? "?", privacy: .public)")
                return Answer(location: location,
                              details: ProxyExitDetails.parse(data, cityKeyPath: service.cityKeyPath, asnKeyPath: service.asnKeyPath,
                                                              organizationKeyPath: service.organizationKeyPath),
                              answeredAfter: answeredAfter)
            }
            log.notice("\(service.url.host ?? "?", privacy: .public) gave no location (HTTP \(status))")
            return Answer(answeredAfter: answeredAfter)
        } catch {
            // One the lookup no longer waits for (another answered, or its time is up) says nothing.
            if !Task.isCancelled {
                log.notice("\(service.url.host ?? "?", privacy: .public) through the proxy failed: \(error.localizedDescription, privacy: .private)")
            }
            return Answer()
        }
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

    private var _connections: [ProxyGeoLookup.Connection] = []
    var connections: [ProxyGeoLookup.Connection] { lock.withLock { _connections } }

    /// Delivered before the task completes, so a request's connections are known once it returned.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let connections = metrics.transactionMetrics.compactMap { transaction -> ProxyGeoLookup.Connection? in
            transaction.remoteAddress.map { ProxyGeoLookup.Connection(address: $0, port: transaction.remotePort) }
        }
        lock.withLock { _connections += connections }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        // The lookup always goes through the profile's proxy: the service's certificate is checked
        // without this Mac fetching anything for it, as a page's is (`ServerTrust`).
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            ServerTrust.answerWithoutFetching(challenge, completionHandler)
            return
        }
        guard space.isProxy() else {
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
