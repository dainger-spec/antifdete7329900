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
