import BrowserCore
import Foundation
import NetworkGuardCore
import os
import TunnelCore
import TunnelTransport

/// The relays that carry the WebRTC of profiles with a SOCKS5 proxy (docs/TUNNEL.md): one TURN
/// server per running profile, on a UDP socket of this — the manager's — process, bound to
/// 127.0.0.1. Nothing outside this Mac can reach it, and a process on it needs the launch's own
/// credentials to use it (401 otherwise). Every allocation leaves through that profile's proxy (a
/// SOCKS5 UDP association of its own) and nowhere else: if the proxy refuses, the allocation fails.
///
/// The credentials are not enough by themselves: the profile's pages are given them, and a script
/// of a page can send them anywhere — to a page of another profile or browser on this Mac, which
/// would then get a relayed address at this profile's proxy exit. So a relay takes an allocation
/// only from a UDP socket the kernel counts for its profile's process (`RelayClients`): read in the
/// kernel's table here, or, where this process is shown only its own sockets (macOS 27, not root),
/// by the network guard, which reads it as root. A client neither says is the profile's gets 403.
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
    /// other gets no relayed address (`TunnelRoute.exit`). `clientPID`: the process whose pages these
    /// are — the profile's own process, the only one whose sockets may allocate. `admitsUnread`: a
    /// client whose socket neither this process nor a guard can read is let in (the self-test's
    /// stand-in for the guard, the capture harness); never for a launch the person makes.
    func start(profile id: UUID, proxy: ProxySettings, exit: IPAddr, clientPID: pid_t,
               admitsUnread: Bool = false) throws -> WebRTCRelay {
        stop(profile: id)
        guard proxy.kind == .socks5, let port = UInt16(exactly: proxy.port) else { throw RelayError.notSOCKS5 }
        let route = TunnelRoute(id: UUID().uuidString, relayIPv4: Self.loopback, relayIPv6: IPAddr("::1")!,
                                username: Self.randomToken(8), password: Self.randomToken(16),
                                proxy: SOCKSProxy(host: proxy.host, port: port, username: proxy.username, password: proxy.password),
                                exit: exit)
        let log = self.log
        let queue = self.queue
        let host = try TURNUDPHost(route: route, bindTo: Self.loopback, queue: queue,
                                   relays: SOCKS5RelayFactory(queue: queue, log: { log.info("relay: \($0, privacy: .private)") }),
                                   log: { log.info("turn: \($0, privacy: .private)") },
                                   admit: { client, server, answer in
                                       Self.admits(client, of: server, pid: clientPID, admitsUnread: admitsUnread) { admitted in
                                           queue.async { answer(admitted) }
                                       }
                                   })
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

    /// Whether the relay at `server` takes `client`: its socket is counted for `pid` by the kernel's
    /// table, read here first and then, if this process is not shown the client's socket, by the
    /// network guard. Called on the relays' queue; answers on any.
    nonisolated private static func admits(_ client: SocketAddress, of server: SocketAddress, pid: pid_t, admitsUnread: Bool,
                                           answer: @escaping (Bool) -> Void) {
        let verdict = { (sockets: [KernelSocket]) in
            RelayClients.verdict(clientAddress: client.ip.description, clientPort: client.port,
                                 relayAddress: server.ip.description, relayPort: server.port, profilePID: pid, in: sockets)
        }
        if case .success(let sockets) = SocketTable.read(.udp) {
            switch verdict(sockets) {
            case .profile: return answer(true)
            case .other(let owner):
                Self.relayLog.notice("WebRTC relay: an allocation from a socket of process \(owner, privacy: .private), not the profile's \(pid, privacy: .public), refused")
                return answer(false)
            case .notListed: break
            }
        }
        let port = client.port
        Task { @MainActor in
            let sockets = await NetworkGuard.shared.udpSockets(onPort: port)
            switch sockets.map(verdict) {
            case .profile?:
                answer(true)
            case .other(let owner)?:
                Self.relayLog.notice("WebRTC relay: an allocation from a socket of process \(owner, privacy: .private), not the profile's \(pid, privacy: .public), refused")
                answer(false)
            case .notListed?, nil:
                if !admitsUnread { Self.relayLog.notice("WebRTC relay: an allocation from a socket the kernel's table does not show, refused") }
                answer(admitsUnread)
            }
        }
    }

    nonisolated private static let relayLog = Logger(subsystem: "PrivacyBrowser", category: "WebRTCRelay")

    private static func randomToken(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
