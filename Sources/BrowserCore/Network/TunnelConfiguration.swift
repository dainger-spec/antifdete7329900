import Foundation

/// The parameters the app passes to a per-profile packet tunnel (`NEPacketTunnelProvider` on
/// macOS, through `NETunnelProviderProtocol.providerConfiguration`). Kept here, platform-free and
/// unit-tested, so both the app (which builds it) and the provider (which reads it) agree on the
/// shape, and so the proxy credentials are handled in one audited place.
///
/// It round-trips through a `[String: String]` dictionary because that is what
/// `providerConfiguration` stores. The proxy password is NOT put here: it goes into the system
/// keychain via `NETunnelProviderProtocol.passwordReference`, and the provider reads it from
/// there. Only non-secret routing parameters travel in the dictionary.
public struct TunnelConfiguration: Equatable, Sendable {
    public enum Exit: Equatable, Sendable {
        case proxy(host: String, port: Int, kind: ProxySettings.Kind, tlsToProxy: Bool, username: String?)
        case directInterface
    }

    public var exit: Exit
    /// How the provider must treat UDP (QUIC/WebRTC): forward to the exit, or drop it. Never leak.
    public var udp: ProfileEgress.UDPHandling
    /// Profile id, so the provider can label the tunnel and the keychain item.
    public var profileID: UUID

    public init(exit: Exit, udp: ProfileEgress.UDPHandling, profileID: UUID) {
        self.exit = exit
        self.udp = udp
        self.profileID = profileID
    }

    /// Builds the tunnel config from a resolved egress, or nil when the egress is not a tunnel.
    public init?(egress: ProfileEgress, profileID: UUID) {
        switch egress {
        case .direct, .proxyTCPOnly:
            return nil
        case .tunnel(let exit):
            self.profileID = profileID
            switch exit {
            case .directInterface:
                self.exit = .directInterface
                self.udp = .throughProxy // direct exit carries UDP natively
            case .proxy(let proxy, let udp):
                self.exit = .proxy(host: proxy.host, port: proxy.port, kind: proxy.kind,
                                   tlsToProxy: proxy.tlsToProxy, username: proxy.username)
                self.udp = udp
            }
        }
    }

    // MARK: Dictionary form (for NETunnelProviderProtocol.providerConfiguration)

    enum Key {
        static let exitKind = "exitKind"      // "proxy" | "direct"
        static let host = "host"
        static let port = "port"
        static let proxyKind = "proxyKind"    // ProxySettings.Kind.rawValue
        static let tls = "tls"                // "1" | "0"
        static let username = "username"
        static let udp = "udp"                // UDPHandling.rawValue
        static let profileID = "profileID"
    }

    public var dictionary: [String: String] {
        var d: [String: String] = [Key.udp: udp.rawValue, Key.profileID: profileID.uuidString]
        switch exit {
        case .directInterface:
            d[Key.exitKind] = "direct"
        case let .proxy(host, port, kind, tls, username):
            d[Key.exitKind] = "proxy"
            d[Key.host] = host
            d[Key.port] = String(port)
            d[Key.proxyKind] = kind.rawValue
            d[Key.tls] = tls ? "1" : "0"
            if let username { d[Key.username] = username }
        }
        return d
    }

    public init?(dictionary d: [String: String]) {
        guard let profileID = d[Key.profileID].flatMap(UUID.init(uuidString:)),
              let udp = d[Key.udp].flatMap(ProfileEgress.UDPHandling.init(rawValue:)) else { return nil }
        self.profileID = profileID
        self.udp = udp
        switch d[Key.exitKind] {
        case "direct":
            exit = .directInterface
        case "proxy":
            guard let host = d[Key.host], !host.isEmpty,
                  let port = d[Key.port].flatMap(Int.init), (1...65535).contains(port),
                  let kind = d[Key.proxyKind].flatMap(ProxySettings.Kind.init(rawValue:)) else { return nil }
            exit = .proxy(host: host, port: port, kind: kind, tlsToProxy: d[Key.tls] == "1",
                          username: d[Key.username])
        default:
            return nil
        }
    }

    /// A one-line, non-secret description for the log and the UI (never the password).
    public var summary: String {
        switch exit {
        case .directInterface:
            return "tunnel → direct interface (UDP+TCP)"
        case let .proxy(host, port, kind, tls, _):
            let scheme = kind == .socks5 ? "socks5" : (tls ? "https" : "http")
            return "tunnel → \(scheme)://\(host):\(port) (UDP \(udp.rawValue))"
        }
    }
}
