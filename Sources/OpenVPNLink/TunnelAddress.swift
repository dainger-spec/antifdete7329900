#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An IPv4 or IPv6 address inside the tunnel, as bytes in network order.
public struct TunnelAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Family: Int32, Sendable { case v4 = 4, v6 = 6 }

    public let family: Family
    /// 4 bytes for IPv4, 16 for IPv6.
    public let bytes: [UInt8]

    public init?(family: Family, bytes: [UInt8]) {
        guard bytes.count == (family == .v4 ? 4 : 16) else { return nil }
        self.family = family
        self.bytes = bytes
    }

    /// A literal ("10.8.0.1", "fd00::1"); nil for anything else, a host name included.
    public init?(_ text: String) {
        var trimmed = Substring(text)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { trimmed = trimmed.dropFirst().dropLast() }
        guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.contains("%") else { return nil }
        var four = in_addr()
        if inet_pton(AF_INET, String(trimmed), &four) == 1 {
            self.family = .v4
            self.bytes = withUnsafeBytes(of: &four) { Array($0) }
            return
        }
        var six = in6_addr()
        if inet_pton(AF_INET6, String(trimmed), &six) == 1 {
            self.family = .v6
            self.bytes = withUnsafeBytes(of: &six) { Array($0) }
            return
        }
        return nil
    }

    public var isAny: Bool { bytes.allSatisfy { $0 == 0 } }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: 64)
        let ok: Bool = bytes.withUnsafeBufferPointer { source in
            inet_ntop(family == .v4 ? AF_INET : AF_INET6, source.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok else { return "?" }
        return String(cString: buffer)
    }
}
