import Foundation

/// A profile's way out for WebRTC, as the app hands it to the packet tunnel: the virtual TURN
/// address the profile's pages are pointed at, the credentials only those pages know, and the
/// profile's SOCKS5 proxy the relayed UDP leaves through.
///
/// One route per running profile, so several profiles with different proxies relay at the same
/// time: the tunnel tells them apart by the virtual address their TURN traffic is sent to (and
/// each one's credentials), not by anything the packets would have to carry.
public struct TunnelRoute: Codable, Equatable, Sendable {
    /// Random per profile launch; the extension never learns which profile it is.
    public var id: String
    public var relayIPv4: IPAddr
    public var relayIPv6: IPAddr
    public var port: UInt16
    public var realm: String
    public var username: String
    public var password: String
    public var proxy: SOCKSProxy
    /// STUN servers ("host:port") asked, through the proxy, for the proxy's public UDP address —
    /// the relayed address pages see. Names are resolved by the proxy.
    public var stunServers: [String]
    /// The same for an IPv6 relayed address: IPv6 literals, so the probe can only succeed when the
    /// proxy itself reaches the IPv6 Internet.
    public var stunServersIPv6: [String]

    public init(id: String, relayIPv4: IPAddr, relayIPv6: IPAddr, port: UInt16 = TunnelAddressing.turnPort,
                realm: String = TunnelAddressing.realm, username: String, password: String, proxy: SOCKSProxy,
                stunServers: [String] = TunnelAddressing.defaultSTUNServers,
                stunServersIPv6: [String] = TunnelAddressing.defaultSTUNServersIPv6) {
        self.id = id
        self.relayIPv4 = relayIPv4
        self.relayIPv6 = relayIPv6
        self.port = port
        self.realm = realm
        self.username = username
        self.password = password
        self.proxy = proxy
        self.stunServers = stunServers
        self.stunServersIPv6 = stunServersIPv6
    }

    /// The TURN URLs a page of this profile is given (UDP only, IPv4 and IPv6).
    public var turnURLs: [String] {
        ["turn:\(relayIPv4):\(port)?transport=udp", "turn:[\(relayIPv6)]:\(port)?transport=udp"]
    }

    public var endpoints: [SocketAddress] {
        [SocketAddress(ip: relayIPv4, port: port), SocketAddress(ip: relayIPv6, port: port)]
    }
}

public struct SOCKSProxy: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?

    public init(host: String, port: UInt16, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var credentials: SOCKS5.Credentials? {
        guard let username, let password, !username.isEmpty else { return nil }
        return SOCKS5.Credentials(username: username, password: password)
    }
}

/// The tunnel's addresses. Only these networks are routed into it, so it carries nothing but
/// the pages' TURN traffic to their virtual relays — every other app, and the profiles' own
/// TCP (which goes to their proxies directly), stays on the normal network.
public enum TunnelAddressing {
    /// TEST-NET-1 (RFC 5737): never routed on the Internet, never handed out on a LAN. Not the
    /// benchmarking range 198.18.0.0/15, which sing-box, Clash and Surge use for their fake IPs:
    /// a more specific route of ours there would take traffic of theirs.
    public static let ipv4Network = IPAddr("192.0.2.0")!
    public static let ipv4PrefixLength = 24
    public static let ipv4Mask = "255.255.255.0"
    /// The tunnel interface's own address (not a relay).
    public static let ipv4Interface = IPAddr("192.0.2.1")!
    /// A unique-local IPv6 /64 (RFC 4193, random global ID).
    public static let ipv6Network = IPAddr("fd6b:3a1c:94e2:1::")!
    public static let ipv6PrefixLength = 64
    public static let ipv6Interface = IPAddr("fd6b:3a1c:94e2:1::1")!
    public static let turnPort: UInt16 = 3478
    public static let realm = "privacybrowser.relay"
    public static let defaultSTUNServers = ["stun.cloudflare.com:3478", "stun.l.google.com:19302"]
    /// The AAAA records of the two names above (October 2026).
    public static let defaultSTUNServersIPv6 = ["[2606:4700:49::]:3478", "[2001:4860:4864:5:8000::1]:19302"]
    /// Relay slots: host numbers 10…249 of the /24 (and the same in the /64).
    public static let slots = 0..<240

    public static func relayIPv4(slot: Int) -> IPAddr {
        IPAddr(bytes: Array(ipv4Network.bytes[0..<3]) + [UInt8(10 + slot)])!
    }

    public static func relayIPv6(slot: Int) -> IPAddr {
        IPAddr(bytes: Array(ipv6Network.bytes[0..<15]) + [UInt8(10 + slot)])!
    }
}

/// What the app sends the extension (`NETunnelProviderSession.sendProviderMessage`), as JSON.
public enum TunnelControlMessage: Codable, Equatable, Sendable {
    case register(TunnelRoute)
    case unregister(id: String)
    case status

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> TunnelControlMessage { try JSONDecoder().decode(Self.self, from: data) }
}

/// The extension's answer to every control message.
public struct TunnelStatusReply: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var routes: [String]
    public var allocations: Int
    public var error: String?

    public init(version: Int = TunnelStatusReply.currentVersion, routes: [String], allocations: Int, error: String? = nil) {
        self.version = version
        self.routes = routes
        self.allocations = allocations
        self.error = error
    }
}
