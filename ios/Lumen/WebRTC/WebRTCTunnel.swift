import Foundation
import LumenCore
import os

/// A proxied session's WebRTC through its proxy (the owner, 17 November: the relay, not a mask): the
/// Mac's relay (docs/TUNNEL.md, WebRTCRelays) — a TURN server on a UDP socket of the app bound to
/// 127.0.0.1, which the session's pages are given as their only ICE server, relay-only (the page
/// shim's "tunnel"); every allocation leaves through a SOCKS5 UDP association of the session's own
/// proxy and nowhere else, and gets a relayed address only when that association leaves from the
/// address the proxy's TCP does (the session's exit: what sites see). So a site sees the proxy's
/// address in WebRTC as in everything else, on its own STUN server too, and the iPhone's address
/// never: no candidate is gathered from the device (relay-only), and no UDP leaves the app but
/// through the proxy.
///
/// Only for a SOCKS5 proxy whose check found UDP: an HTTP proxy, a SOCKS5 proxy without UDP, or one
/// not checked yet keep WebRTC removed from the pages, as before.
///
/// Unlike the Mac, iOS cannot say which process a loopback socket belongs to, so a client is admitted
/// by the launch's own credentials alone (random per runtime, given only to the session's pages).
@MainActor
final class WebRTCTunnel {
    /// What the pages are given as their only ICE server.
    struct Relay: Codable, Equatable {
        var urls: [String]
        var username: String
        var credential: String
    }

    private(set) var relay: Relay?
    private var host: TURNUDPHost?
    /// What the relay was started for (the proxy, its password and exit): a change starts it again.
    private var startedFor: String?
    private let queue = DispatchQueue(label: "Lumen.webrtc-relay")
    private static let log = Logger(subsystem: "io.lumenbrowser.ios", category: "WebRTCRelay")

    /// The relay for the session's proxy now; nil when WebRTC cannot go through it.
    func apply(proxy: ProxyEntry?, password: String, locked: Bool) {
        guard !locked, let proxy, proxy.kind == .socks5, let check = proxy.check, check.alive,
              check.udp == .supported, let exit = check.exitIP.flatMap({ IPAddr($0) }), let port = UInt16(exactly: proxy.port) else {
            stop()
            return
        }
        let key = "\(proxy.host):\(proxy.port)|\(proxy.username)|\(password)|\(exit)"
        guard key != startedFor else { return }
        stop()
        let route = TunnelRoute(id: UUID().uuidString, relayIPv4: IPAddr("127.0.0.1")!, relayIPv6: IPAddr("::1")!,
                                username: Self.randomToken(8), password: Self.randomToken(16),
                                proxy: SOCKSProxy(host: proxy.host, port: port,
                                                  username: proxy.username.isEmpty ? nil : proxy.username,
                                                  password: password.isEmpty ? nil : password),
                                stunServers: Self.stunServers, exit: exit)
        let log = Self.log
        do {
            let host = try TURNUDPHost(route: route, bindTo: IPAddr("127.0.0.1")!, queue: queue,
                                       relays: SOCKS5RelayFactory(queue: queue, log: { log.info("relay: \($0, privacy: .private)") }),
                                       log: { log.info("turn: \($0, privacy: .private)") })
            self.host = host
            startedFor = key
            relay = Relay(urls: [host.turnURL], username: route.username, credential: route.password)
        } catch {
            log.error("WebRTC relay not started: \(String(describing: error), privacy: .public)")
            relay = nil
        }
    }

    /// The relay stopped: its allocations close, and with them their associations.
    func stop() {
        relay = nil
        startedFor = nil
        guard let host else { return }
        self.host = nil
        queue.async { host.stop() }
    }

    /// The STUN servers asked through the proxy for its public UDP address (the relayed address);
    /// a test build asks the testbed's.
    private static var stunServers: [String] {
        #if DEBUG
        if TestHooks.enabled, let stun = ProcessInfo.processInfo.environment["LUMEN_TEST_STUN"], !stun.isEmpty { return [stun] }
        #endif
        return TunnelAddressing.defaultSTUNServers
    }

    private static func randomToken(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
