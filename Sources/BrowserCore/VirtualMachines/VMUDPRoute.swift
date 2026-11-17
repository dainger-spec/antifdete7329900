import Foundation

/// Whether a machine's UDP — HTTP/3 (QUIC), WebRTC, anything but DNS and the time, which its
/// network answers itself — leaves it in a run, and why not (docs/VM_NETWORK.md, "UDP").
///
/// Decided before each start, from the check of its proxy (`ProxyCheckResult.udp`: a UDP
/// association and a STUN request through it, to a STUN server named so that the proxy resolves
/// it, then where its UDP leaves from against where its pages do). What cannot be told keeps UDP
/// off. Never a path around the proxy: a machine whose proxy does not carry UDP has none.
public enum VMUDPRoute: String, Codable, Equatable, Sendable, CaseIterable {
    /// Through the proxy's own UDP relay (SOCKS5 UDP ASSOCIATE), from the address its pages leave
    /// from: WebRTC shows the proxy's address, HTTP/3 works.
    case throughProxy
    /// The proxy is an HTTP one: it carries TCP only.
    case httpProxy
    /// A SOCKS5 proxy that did not carry UDP in the check: UDP ASSOCIATE refused, or nothing came
    /// back through the association.
    case notCarried
    /// The proxy carries UDP, but from another address than its TCP: a site would see two
    /// addresses, which tells it the machine goes through a proxy.
    case elsewhere
    /// Whether the proxy carries UDP could not be found out before the start.
    case unknown
    /// No proxy: UDP goes out as this Mac's own, as the machine's TCP does (`VMNetDirectConnector`)
    /// — not while this Mac's network settings name a proxy, which is not asked for UDP.
    case direct

    /// The route for a machine with `proxy`, from what the check before its start found of the
    /// proxy's UDP (`check.udp`; nil: not tried, or a dead proxy).
    public static func forProxy(_ proxy: ProxySettings, check: ProxyCheckResult?) -> VMUDPRoute {
        guard proxy.carriesUDP, !proxy.tlsToProxy else { return .httpProxy }
        guard let check, check.isAlive else { return .unknown }
        switch check.udp {
        case .supported?: return .throughProxy
        case .unsupported?: return .notCarried
        case .elsewhere?: return .elsewhere
        case .unknown?, .exitUnknown?, nil: return .unknown
        }
    }

    /// The route for a machine of `profile`'s, as far as it is known before a start: a machine
    /// without a proxy has `direct`; one with a proxy what its last check found.
    public static func expected(for proxy: ProxySettings?, check: ProxyCheckResult?) -> VMUDPRoute {
        guard let proxy else { return .direct }
        return forProxy(proxy, check: check)
    }

    /// The machine's network carries UDP in this run (`VMHelperRequest.relaysUDP`).
    public var carriesUDP: Bool { self == .throughProxy || self == .direct }
}
