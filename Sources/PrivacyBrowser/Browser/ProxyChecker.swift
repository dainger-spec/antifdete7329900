import BrowserCore
import Foundation

/// Checks proxies of the list: is it alive, where does it exit, how slow is it.
///
/// A check is the lookup a launch makes (`ProxyGeoLookup`), so it asks the same geolocation
/// services over HTTPS THROUGH the proxy, with the same `ProxyConfiguration` a profile's data store
/// gets (`ProxyConfigurationFactory`, `allowFailover = false`): a dead proxy fails the check, it is
/// never gone around — this Mac's own address is never what a service sees. A proxy whose settings
/// cannot be applied is not checked at all (there would be nothing to send the request through but
/// the direct connection). Each check has its own URLSession, cookie-less and cache-less, with this
/// Mac's Safari User-Agent, as a profile without one of its own would send.
///
/// PRIVACY: as the launch's lookup, every check is a request to a third-party service, made only
/// when the user asks for it (Check in the Proxies sheet).
@MainActor
enum ProxyChecker {
    /// Checks running at once: enough to get through a provider's list quickly, few enough not to
    /// look like a flood to the services (or to the proxies' provider).
    static var concurrentChecks = 8
    /// A proxy that has not answered by then is taken for dead.
    static var timeout: TimeInterval = 10

    /// What checking `proxy` finds.
    static func check(_ proxy: ProxySettings) async -> ProxyCheckResult {
        result(of: await lookUp(proxy))
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
    /// IP, country and time zone when the answer said), dead otherwise, and why.
    static func result(of lookup: ProxyGeoLookup.Result?, at time: Date = Date()) -> ProxyCheckResult {
        guard let lookup else { return .dead(.invalidSettings, at: time) }
        if lookup.proxyRequiresCredentials { return .dead(.needsCredentials, at: time) }
        guard lookup.answered else { return .dead(.noAnswer, at: time) }
        return .alive(location: lookup.location, latency: lookup.latency, at: time)
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
