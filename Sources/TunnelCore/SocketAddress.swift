import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An IPv4 or IPv6 address as its network-order bytes (4 or 16).
public struct IPAddr: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Family: Sendable { case v4, v6 }

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// A literal: dotted IPv4, or IPv6 with or without brackets. Host names are not resolved.
    public init?(_ text: String) {
        var literal = text
        if literal.hasPrefix("["), literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
        var v4 = [UInt8](repeating: 0, count: 4)
        if literal.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            bytes = v4
            return
        }
        var v6 = [UInt8](repeating: 0, count: 16)
        if literal.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            bytes = v6
            return
        }
        return nil
    }

    public var family: Family { bytes.count == 4 ? .v4 : .v6 }

    /// IPv4 dotted, IPv6 in the shortest form (RFC 5952), both without brackets.
    public var description: String {
        var buffer = [CChar](repeating: 0, count: 64)
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        return ok ? String(cString: buffer) : "?"
    }

    public static let anyV4 = IPAddr(bytes: [0, 0, 0, 0])!
    public static let anyV6 = IPAddr(bytes: [UInt8](repeating: 0, count: 16))!

    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }

    /// Whether the first `length` bits are those of `prefix` (an address of the same family).
    public func isIn(_ prefix: IPAddr, length: Int) -> Bool {
        guard prefix.bytes.count == bytes.count, length >= 0, length <= bytes.count * 8 else { return false }
        for bit in 0..<length where (bytes[bit / 8] ^ prefix.bytes[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 { return false }
        return true
    }

    /// Whether a relay may send to this address from the proxy's side (RFC 8656 §21.3–4): an
    /// Internet unicast address, not one of the proxy's own host or networks (unspecified,
    /// loopback, link-local, private, shared, multicast, reserved, the tunnel's relays), nor an
    /// IPv6 address that stands for an IPv4 one (mapped, 6to4, Teredo).
    public var isGlobalUnicast: Bool {
        let blocked = family == .v4 ? Self.nonGlobalIPv4 : Self.nonGlobalIPv6
        if blocked.contains(where: { isIn($0.prefix, length: $0.length) }) { return false }
        // NAT64 (RFC 6052): as global as the IPv4 address it carries.
        if isIn(Self.nat64.prefix, length: Self.nat64.length) { return IPAddr(bytes: Array(bytes[12..<16]))!.isGlobalUnicast }
        return true
    }

    private static func block(_ literal: String, _ length: Int) -> (prefix: IPAddr, length: Int) { (IPAddr(literal)!, length) }
    private static let nonGlobalIPv4 = [
        block("0.0.0.0", 8), block("10.0.0.0", 8), block("100.64.0.0", 10), block("127.0.0.0", 8),
        block("169.254.0.0", 16), block("172.16.0.0", 12), block("192.0.0.0", 24), block("192.0.2.0", 24),
        block("192.168.0.0", 16), block("198.18.0.0", 15), block("224.0.0.0", 4), block("240.0.0.0", 4),
    ]
    private static let nonGlobalIPv6 = [
        block("::", 128), block("::1", 128), block("::ffff:0:0", 96), block("2001::", 32), block("2002::", 16),
        block("fc00::", 7), block("fe80::", 10), block("ff00::", 8),
    ]
    private static let nat64 = block("64:ff9b::", 96)

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let address = IPAddr(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an IP literal: \(text)"))
        }
        self = address
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// An IP address and a UDP/TCP port.
public struct SocketAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public var ip: IPAddr
    public var port: UInt16

    public init(ip: IPAddr, port: UInt16) {
        self.ip = ip
        self.port = port
    }

    public var family: IPAddr.Family { ip.family }

    /// "1.2.3.4:5" or "[::1]:5".
    public var description: String {
        ip.family == .v4 ? "\(ip):\(port)" : "[\(ip)]:\(port)"
    }
}

/// A destination for the proxy: an address, or a name the proxy resolves (so no DNS query
/// leaves this Mac for it).
public enum ProxyDestination: Hashable, Sendable {
    case address(SocketAddress)
    case name(String, port: UInt16)
}
