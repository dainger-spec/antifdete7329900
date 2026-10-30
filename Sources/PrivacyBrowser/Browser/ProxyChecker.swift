import BrowserCore
import Foundation

/// Checks proxies of the list: does it work — and when it does not, why — where does it exit, how
/// slow is it.
///
/// Two parts, both only ever talking to the proxy:
///   1. the proxy itself, step by step (`ProxyProbe`): its name, a connection, a SOCKS5 and an HTTP
///      handshake at once (the type is found, not taken from the list), the login, a tunnel to the
///      geolocation service, three tunnels for the latency. Each way of failing is its own verdict
///      (`ProxyDiagnosis`) — the port that takes the connection and says nothing among them;
///   2. when it works, the lookup a launch makes (`ProxyGeoLookup`) through it, with the type found:
///      the same geolocation services over HTTPS THROUGH the proxy, with the same
///      `ProxyConfiguration` a profile's data store gets (`ProxyConfigurationFactory`,
///      `allowFailover = false`) — where it exits, its city and network.
/// A dead proxy fails the check; it is never gone around — this Mac's own address is never what a
/// service sees. A proxy whose settings cannot be applied is not checked at all. The lookup has its
/// own URLSession, cookie-less and cache-less, with this Mac's Safari User-Agent.
///
/// PRIVACY: the probe's connections go to the proxy alone (the service is named to the proxy, which
/// resolves and reaches it); the lookup is a request to a third-party service through the proxy.
/// Both only when the user asks for a check (the Proxies section), and the probe when a profile with a
/// proxy starts (`ProfileManager`), to say why it would load nothing.
@MainActor
enum ProxyChecker {
    /// Checks running at once: enough to get through a provider's list quickly, few enough not to
    /// look like a flood to the services (or to the proxies' provider).
    static var concurrentChecks = 8
    /// The lookup through a working proxy has this long to answer.
    static var timeout: TimeInterval = 10
    /// The probe's own limits, per step.
    static var probeTimeouts = ProxyProbe.Timeouts()

    /// The probe as the checker runs it: the tunnel goes to the first geolocation service, the one
    /// the lookup asks next.
    static func probe(latencySamples: Int = 3) -> ProxyProbe {
        let url = ProxyGeoLookup.services.first?.url
        let port = url?.port ?? (url?.scheme == "http" ? 80 : 443)
        return ProxyProbe(targetHost: url?.host ?? "ipinfo.io", targetPort: port, timeouts: probeTimeouts,
                          latencySamples: latencySamples,
                          userAgent: ProfileConfiguration().userAgent(hostSafariVersion: HostSafari.version))
    }

    /// What checking `proxy` finds.
    static func check(_ proxy: ProxySettings) async -> ProxyCheckResult {
        let time = Date()
        // Settings that cannot be applied: nothing is sent at all (there would be nothing to send
        // the lookup through but the direct connection).
        guard (try? proxy.validate()) != nil, let configurations = try? ProxyConfigurationFactory.make(proxy), !configurations.isEmpty else {
            return .dead(.invalidSettings, at: time)
        }
        let diagnosis = await probe().run(proxy)
        guard diagnosis.isWorking else {
            var result = ProxyCheckResult.dead(diagnosis.verdict == .credentialsNeeded ? .needsCredentials : .noAnswer, at: time)
            result.diagnosis = diagnosis
            return result
        }
        // Through it, with the type it answered as.
        var found = proxy
        if let kind = diagnosis.kinds.first, !(proxy.kind == .httpConnect && proxy.tlsToProxy) {
            found.kind = kind
            if kind == .socks5 { found.tlsToProxy = false }
        }
        var result = self.result(of: await lookUp(found), at: time)
        result.diagnosis = diagnosis
        if let median = diagnosis.medianLatency { result.latencyMilliseconds = median }
        return result
    }

    /// The lookup through `proxy` a check makes; nil when its settings cannot be applied, and then
    /// no request is made at all.
    static func lookUp(_ proxy: ProxySettings) async -> ProxyGeoLookup.Result? {
        guard let configurations = try? ProxyConfigurationFactory.make(proxy), !configurations.isEmpty else { return nil }
        return await ProxyGeoLookup.lookUp(proxy: proxy,
                                           userAgent: ProfileConfiguration().userAgent(hostSafariVersion: HostSafari.version),
                                           timeout: timeout)
    }

    /// The verdict on a lookup: alive when a service's answer came back through the proxy (its exit
    /// IP, country, time zone, city and network when the answer said), dead otherwise, and why.
    static func result(of lookup: ProxyGeoLookup.Result?, at time: Date = Date()) -> ProxyCheckResult {
        guard let lookup else { return .dead(.invalidSettings, at: time) }
        if lookup.proxyRequiresCredentials { return .dead(.needsCredentials, at: time) }
        guard lookup.answered else { return .dead(.noAnswer, at: time) }
        var result = ProxyCheckResult.alive(location: lookup.location, latency: lookup.latency, at: time)
        result.city = lookup.details.city
        result.asn = lookup.details.asn
        result.organization = lookup.details.organization
        return result
    }

    /// Checks several, at most `limit` (`concurrentChecks`) at a time, and hands each result over
    /// as it comes. Cancelling the calling task stops it: what is still running is cancelled and
    /// reported nowhere (a cancelled check says nothing about the proxy).
    static func checkAll(_ proxies: [(id: UUID, proxy: ProxySettings)], limit: Int? = nil,
                         onResult: @escaping (UUID, ProxyCheckResult) -> Void) async {
        var queue = proxies[...]
        await withTaskGroup(of: (UUID, ProxyCheckResult).self) { group in
            for _ in 0..<max(1, limit ?? concurrentChecks) {
                guard let next = queue.popFirst() else { break }
                group.addTask { @MainActor in (next.id, await ProxyChecker.check(next.proxy)) }
            }
            while let (id, result) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                onResult(id, result)
                if let next = queue.popFirst() {
                    group.addTask { @MainActor in (next.id, await ProxyChecker.check(next.proxy)) }
                }
            }
        }
    }
}
