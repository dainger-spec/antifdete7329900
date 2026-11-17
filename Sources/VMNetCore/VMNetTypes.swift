import Foundation

/// An Ethernet hardware address.
public struct VMNetMAC: Equatable, Hashable, Sendable {
    /// The six bytes in the low 48 bits, the first byte highest.
    let raw: UInt64

    init(raw: UInt64) {
        self.raw = raw & 0xFFFF_FFFF_FFFF
    }

    /// "aa:bb:cc:dd:ee:ff", in any case. Nil for anything else.
    public init?(string: String) {
        let groups = string.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count == 6 else { return nil }
        var value: UInt64 = 0
        for group in groups {
            guard group.count == 2, group.allSatisfy({ $0.isASCII && $0.isHexDigit }), let byte = UInt8(group, radix: 16) else { return nil }
            value = value << 8 | UInt64(byte)
        }
        raw = value
    }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 6, "an Ethernet address is six bytes")
        raw = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    public var bytes: [UInt8] {
        (0..<6).map { UInt8(truncatingIfNeeded: raw >> UInt64(40 - 8 * $0)) }
    }

    /// Lower case, with colons.
    public var string: String {
        bytes.map { byte in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined(separator: ":")
    }

    static let broadcast = VMNetMAC(raw: 0xFFFF_FFFF_FFFF)

    /// Broadcast and multicast addresses: the lowest bit of the first byte.
    var isGroup: Bool { raw >> 40 & 1 == 1 }
}

/// An IPv4 address.
public struct VMNetIPv4: Equatable, Hashable, Sendable {
    /// In host byte order: 192.168.1.1 is 0xC0A80101.
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    /// A dotted quad of four decimal numbers, "192.168.1.1". Nil for anything else (a number
    /// written with a leading zero, which some parsers read as octal, included).
    public init?(string: String) {
        let groups = string.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return nil }
        var value: UInt32 = 0
        for group in groups {
            guard (1...3).contains(group.count), group.allSatisfy({ $0.isASCII && $0.isNumber }),
                  group.count == 1 || group.first != "0", let byte = UInt8(group) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        self.value = value
    }

    public var string: String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    static let broadcast = VMNetIPv4(0xFFFF_FFFF)
    static let unspecified = VMNetIPv4(0)

    /// Whether the address is inside `network`/`prefixLength`.
    func isIn(_ network: UInt32, _ prefixLength: Int) -> Bool {
        let mask = VMNetIPv4.mask(prefixLength)
        return value & mask == network & mask
    }

    /// The network mask of a prefix length: 24 is 255.255.255.0.
    static func mask(_ prefixLength: Int) -> UInt32 {
        let length = min(max(prefixLength, 0), 32)
        return length == 0 ? 0 : UInt32.max << UInt32(32 - length)
    }
}

/// Where a guest's connections leave: the profile's proxy, and nothing else.
public enum VMNetUpstream: Equatable, Sendable {
    case socks5(host: String, port: Int, username: String?, password: String?)
    case httpConnect(host: String, port: Int, username: String?, password: String?)
    /// Nothing leaves: every connection is refused. For a profile whose proxy cannot be used.
    case none
}

/// What one guest's network is made of.
public struct VMNetConfiguration: Sendable {
    /// The guest's network card. DHCP answers this address only.
    public var guestMAC: VMNetMAC
    /// The address the stack answers ARP with: the guest's router.
    public var gatewayMAC: VMNetMAC
    /// The router's address — also the DNS server and the DHCP server.
    public var gatewayAddress: VMNetIPv4
    /// The address DHCP hands the guest.
    public var guestAddress: VMNetIPv4
    public var prefixLength: Int
    public var upstream: VMNetUpstream
    /// Host names (a name itself and every subdomain) answered NXDOMAIN — e.g. Apple's
    /// software-update hosts, so a guest never downloads gigabytes of updates through a paid proxy.
    public var blockedHostSuffixes: [String]
    public var mtu: Int
    /// Names the guest was given fake addresses for at an earlier run of this network, with those
    /// addresses: a machine woken from a saved state still holds them (in its resolver's cache,
    /// in connections it is about to open) and must find the same names behind them.
    public var knownNames: [VMNetKnownName] = []
    /// The guest's UDP — QUIC (HTTP/3), WebRTC, anything but DNS and the time — is carried through
    /// the proxy's own UDP relay (SOCKS5 UDP ASSOCIATE, RFC 1928 §7), and no other way. Off, or
    /// with a proxy that is not SOCKS5, or one that refuses: answered "port unreachable", as
    /// before. The app turns it on for a run only when its check before the start found that the
    /// proxy carries UDP; DNS and the time are answered here either way, and never relayed.
    public var relaysUDP = false

    public init(guestMAC: VMNetMAC, gatewayMAC: VMNetMAC,
                gatewayAddress: VMNetIPv4 = VMNetIPv4(0xC0A8_0101), guestAddress: VMNetIPv4 = VMNetIPv4(0xC0A8_0117),
                prefixLength: Int = 24, upstream: VMNetUpstream, blockedHostSuffixes: [String] = [], mtu: Int = 1500) {
        self.guestMAC = guestMAC
        self.gatewayMAC = gatewayMAC
        self.gatewayAddress = gatewayAddress
        self.guestAddress = guestAddress
        self.prefixLength = prefixLength
        self.upstream = upstream
        self.blockedHostSuffixes = blockedHostSuffixes
        self.mtu = mtu
    }

    /// The MTU the stack works with: what was asked for, kept inside what Ethernet and the
    /// protocols' headers allow.
    var effectiveMTU: Int { min(max(mtu, 576), 9000) }
}

/// What the network has carried so far. Counts only: never a name or an address.
public struct VMNetCounters: Equatable, Sendable {
    /// TCP payload sent on through the proxy.
    public var bytesFromGuest: UInt64 = 0
    /// TCP payload delivered to the guest (acknowledged by it).
    public var bytesToGuest: UInt64 = 0
    /// Connections whose tunnel through the proxy came up.
    public var connectionsOpened: UInt64 = 0
    /// Connections the proxy refused or did not answer (and, with no proxy, every connection).
    public var connectionsFailed: UInt64 = 0
    /// Connections open through the proxy now.
    public var connectionsActive: Int = 0
    public var dnsQueries: UInt64 = 0
    /// Queries answered "no such name" because the name is under a blocked suffix.
    public var dnsBlocked: UInt64 = 0
    /// UDP that is not DHCP, DNS or a question for the time and was not carried: answered "port
    /// unreachable" (or, for broadcasts, multicast and a full queue, nothing).
    public var datagramsDropped: UInt64 = 0
    /// Questions for the time (NTP) answered with this Mac's clock.
    public var timeQueries: UInt64 = 0
    /// The guest's datagrams sent on through the proxy's UDP relay (`relaysUDP`), and their payload.
    public var datagramsRelayed: UInt64 = 0
    public var udpBytesFromGuest: UInt64 = 0
    /// Datagrams from the relay delivered to the guest, and their payload.
    public var datagramsToGuest: UInt64 = 0
    public var udpBytesToGuest: UInt64 = 0
    /// UDP associations with the proxy that came up, that did not (refused, not answered, not
    /// understood), and that are open now. One per port the guest sends from.
    public var udpAssociationsOpened: UInt64 = 0
    public var udpAssociationsFailed: UInt64 = 0
    public var udpAssociationsActive: Int = 0
    /// The guest's connections the proxy failed one after another, by its own fault, since it last
    /// carried one (`VMNetProxyTrouble`): a proxy that went down, or stopped taking its sign-in,
    /// while the machine runs. A site the proxy answers it cannot reach neither counts nor resets.
    public var proxyFailuresInARow: UInt64 = 0
    /// Why the last of them failed; nil once a connection is carried again.
    public var proxyTrouble: VMNetProxyTrouble?

    public init() {}
}

/// Why the proxy itself gave a connection no tunnel — a kind, never where the connection was going.
public enum VMNetProxyTrouble: String, Equatable, Sendable, CaseIterable {
    /// The proxy's address was not found, its port did not take the connection, or it closed the
    /// connection or said nothing in time: the proxy is down, or not where its entry says.
    case unreachable
    /// The proxy refused the sign-in: SOCKS5's user name and password, or HTTP's 407.
    case login
    /// The proxy's answer is not the protocol the profile names (an HTTP proxy's port given as
    /// SOCKS5, or the other way round).
    case notUnderstood
}

/// A name the guest asked for and the fake address it was given for it (`FakeAddressPool`).
public struct VMNetKnownName: Equatable, Sendable {
    public var name: String
    /// In host byte order, as `VMNetIPv4.value`.
    public var address: UInt32

    public init(name: String, address: UInt32) {
        self.name = name
        self.address = address
    }
}

/// What the network has carried to and from one host the guest asked for, since it started. This
/// IS the person's browsing — shown to them while the machine runs, kept in memory only, and
/// never written to a log.
public struct VMNetHost: Equatable, Sendable {
    /// The name the guest asked for, or the address it connected to as written.
    public var name: String
    /// Connections the guest opened to it, made or not.
    public var connections: UInt64
    /// Of them, open now.
    public var open: Int
    public var bytesFromGuest: UInt64
    public var bytesToGuest: UInt64
    /// Questions for the name and connections to it refused because it is blocked.
    public var blocked: UInt64
    /// Seconds since the guest last asked for it or carried anything to or from it.
    public var idle: Double

    public init(name: String, connections: UInt64 = 0, open: Int = 0, bytesFromGuest: UInt64 = 0, bytesToGuest: UInt64 = 0,
                blocked: UInt64 = 0, idle: Double = 0) {
        self.name = name
        self.connections = connections
        self.open = open
        self.bytesFromGuest = bytesFromGuest
        self.bytesToGuest = bytesToGuest
        self.blocked = blocked
        self.idle = idle
    }
}
