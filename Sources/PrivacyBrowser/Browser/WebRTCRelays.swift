import BrowserCore
import Foundation
import os
import TunnelCore
import TunnelTransport

/// The relays that carry the WebRTC of profiles with a SOCKS5 proxy (docs/TUNNEL.md): one TURN
/// server per running profile, on a UDP socket of this — the manager's — process, bound to
/// 127.0.0.1. Nothing outside this Mac can reach it, and a process on it needs the launch's own
/// credentials to use it (401 otherwise). Every allocation leaves through that profile's proxy (a
/// SOCKS5 UDP association of its own) and nowhere else: if the proxy refuses, the allocation fails.
///
/// In the manager, not in the profile's process: the kernel refuses that process every UDP datagram
/// it would send (`ProfileNetworkGuard.closeTheProcess`), QUIC above all, and it stays so. WebKit's
/// own processes of the profile reach the relay over loopback; what they send anywhere else, the
/// network guard drops (`NetworkGuard`).
@MainActor
final class WebRTCRelays {
    static let shared = WebRTCRelays()

    enum RelayError: Error, CustomStringConvertible {
        case notSOCKS5
        var description: String { "the relay carries a SOCKS5 proxy's UDP only" }
    }

    private var hosts: [UUID: TURNUDPHost] = [:]
    private let queue = DispatchQueue(label: "PrivacyBrowser.webrtc-relay")
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WebRTCRelay")
    private static let loopback = IPAddr("127.0.0.1")!

    /// Starts the relay for one launch of a profile; what its pages are given as their only ICE
    /// server. One relay per profile: a second start replaces the first. `exit` is the address the
    /// proxy's TCP leaves from, found by this launch: an allocation whose association leaves from any
    /// other gets no relayed address (`TunnelRoute.exit`).
    func start(profile id: UUID, proxy: ProxySettings, exit: IPAddr) throws -> WebRTCRelay {
        stop(profile: id)
        guard proxy.kind == .socks5, let port = UInt16(exactly: proxy.port) else { throw RelayError.notSOCKS5 }
        let route = TunnelRoute(id: UUID().uuidString, relayIPv4: Self.loopback, relayIPv6: IPAddr("::1")!,
                                username: Self.randomToken(8), password: Self.randomToken(16),
                                proxy: SOCKSProxy(host: proxy.host, port: port, username: proxy.username, password: proxy.password),
                                exit: exit)
        let log = self.log
        let host = try TURNUDPHost(route: route, bindTo: Self.loopback, queue: queue,
                                   relays: SOCKS5RelayFactory(queue: queue, log: { log.info("relay: \($0, privacy: .private)") }),
                                   log: { log.info("turn: \($0, privacy: .private)") })
        hosts[id] = host
        log.notice("WebRTC relay for a profile on 127.0.0.1:\(host.address.port, privacy: .public)")
        return WebRTCRelay(urls: [host.turnURL], username: route.username, credential: route.password)
    }

    /// The relay of a profile that stopped: its allocations close, and with them their associations.
    /// With `relay`, only if that is still the profile's (a relaunch may have made another since).
    func stop(profile id: UUID, onlyIf relay: WebRTCRelay? = nil) {
        if let relay, hosts[id]?.route.password != relay.credential { return }
        guard let host = hosts.removeValue(forKey: id) else { return }
        // The host runs on its queue; it is stopped there.
        queue.async { host.stop() }
    }

    func stopAll() {
        for id in Array(hosts.keys) { stop(profile: id) }
    }

    func isRunning(profile id: UUID) -> Bool { hosts[id] != nil }

    private static func randomToken(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
