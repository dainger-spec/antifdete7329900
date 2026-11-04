import Foundation
import TunnelCore

/// Whether a SOCKS5 proxy relays UDP, found the way the relay will use it: one UDP association
/// (RFC 1928 §7) and a STUN Binding through it to public STUN servers, which are named so that the
/// proxy resolves them. What comes back is the proxy's UDP egress — the address a profile's relay
/// candidates will carry. Nothing is ever sent around the proxy: a step that fails ends the check.
public enum ProxyUDPCheck {
    public enum Outcome: Equatable, Sendable {
        /// The proxy relays UDP; `egress` is where its UDP leaves for the Internet.
        case supported(egress: SocketAddress)
        /// UDP ASSOCIATE refused, the proxy unreachable, or no STUN answer through the association.
        case unsupported(reason: String)
    }

    /// At most `timeout` for the handshake and the probe together (the relay's own six seconds of
    /// probing fit in the default).
    public static func run(proxy: SOCKSProxy, timeout: TimeInterval = 9,
                           stunServers: [String] = TunnelAddressing.defaultSTUNServers) async -> Outcome {
        let queue = DispatchQueue(label: "PrivacyBrowser.udp-check")
        return await withCheckedContinuation { continuation in
            queue.async {
                let route = TunnelRoute(id: "udp-check", relayIPv4: IPAddr("127.0.0.1")!, relayIPv6: IPAddr("::1")!,
                                        username: "", password: "", proxy: proxy, stunServers: stunServers)
                let factory = SOCKS5RelayFactory(queue: queue)
                factory.setupTimeout = timeout
                let check = Check(continuation)
                check.relay = factory.openRelay(for: route, family: .v4, onReady: { result in
                    switch result {
                    case .success(let egress): check.finish(.supported(egress: egress))
                    case .failure(let error): check.finish(.unsupported(reason: String(describing: error)))
                    }
                }, onReceive: { _, _ in }, onClosed: {
                    check.finish(.unsupported(reason: "the proxy closed the association"))
                })
                // A relay that failed before `openRelay` returned has called back already.
                if check.isFinished { check.relay?.close() }
            }
        }
    }

    /// One answer, whichever callback comes first; the association closed with it.
    private final class Check {
        private var continuation: CheckedContinuation<Outcome, Never>?
        var relay: PeerRelay?
        var isFinished: Bool { continuation == nil }

        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }

        func finish(_ outcome: Outcome) {
            guard let continuation else { return }
            self.continuation = nil
            relay?.close()
            continuation.resume(returning: outcome)
        }
    }
}
