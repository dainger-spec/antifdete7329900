import Foundation
import TunnelCore
#if canImport(Darwin)
import Darwin
#endif

/// One socket as the kernel keeps it: its ends, the process that last used it, and the process it
/// is counted for when another process opened it on that one's behalf (a delegated socket).
///
/// WebKit's network process opens a page's WebRTC sockets for the profile's process and marks each
/// as the profile's (SO_DELEGATED). A packet capture names that process as `eproc`; on the owner's
/// Mac (0.1.2, macOS 27.0.1, 4 November) every STUN packet of the guard's probe was `eproc
/// LumenProfile:1738` while the content filter was given the network process (1741) as the flow's
/// source application. This is where the capture reads it from (`so_e_pid` while `SOF_DELEGATED`).
public struct KernelSocket: Codable, Equatable, Sendable, CustomStringConvertible {
    public var transport: GuardTransport
    /// The local address, canonical; nil when the socket is bound to any address.
    public var localAddress: String?
    public var localPort: UInt16
    /// The remote end; nil (and port 0) when the socket is not connected.
    public var remoteAddress: String?
    public var remotePort: UInt16
    /// The process that last sent or received on the socket (the one that opened it, here).
    public var lastPID: Int32
    /// The process it is counted for, when `delegated`.
    public var effectivePID: Int32
    public var delegated: Bool

    public init(transport: GuardTransport, localAddress: String?, localPort: UInt16, remoteAddress: String?, remotePort: UInt16,
                lastPID: Int32, effectivePID: Int32, delegated: Bool) {
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.lastPID = lastPID
        self.effectivePID = effectivePID
        self.delegated = delegated
    }

    /// Whom the kernel counts the socket for: the process it was opened for when delegated, else
    /// the process that uses it — what a packet capture names as `eproc`, or `proc` without one.
    public var countedFor: Int32 { delegated ? effectivePID : lastPID }

    /// "udp :53895 → 203.0.113.1:3478, used by pid 10416, counted for pid 10412 (delegated)"
    public var description: String {
        let local = "\(localAddress ?? "*"):\(localPort)"
        let remote: String = remoteAddress.map { "\($0):\(remotePort)" } ?? "*"
        let counted = delegated ? "counted for pid \(effectivePID) (delegated)" : "not delegated"
        return "\(transport.rawValue) \(local) → \(remote), used by pid \(lastPID), \(counted)"
    }
}

/// The kernel's table of a transport's sockets, as `netstat` reads it: the sysctl
/// `net.inet.udp.pcblist_n` / `net.inet.tcp.pcblist_n` (xnu bsd/netinet/in_pcblist.c). A header
/// (`struct xinpgen`), then for each socket records that each begin with their length and kind —
/// the inpcb's (`struct xinpcb_n`: ports, addresses), the socket's (`struct xsocket_n`: last and
/// effective pid, flags), its buffers and statistics — each padded to 8 bytes, and the header again
/// at the end. The two layouts are xnu's (`#pragma pack(4)`), checked here by the length each record
/// gives itself: a shorter record than the layout read is refused, never read past.
public enum SocketTable {
    static let kindInpcb: UInt32 = 0x010     // XSO_INPCB
    static let kindSocket: UInt32 = 0x001    // XSO_SOCKET
    static let delegatedFlag: UInt32 = 0x1000_0000   // SOF_DELEGATED
    /// The bytes of each layout this reads (both xnu's are 104 long).
    static let inpcbLength = 104
    static let socketLength = 104
    static let headerLength = 24             // struct xinpgen

    // struct xinpcb_n, #pragma pack(4)
    static let foreignPortOffset = 16
    static let localPortOffset = 18
    static let versionFlagOffset = 44        // inp_vflag: INP_IPV4 0x1, INP_IPV6 0x2
    static let foreignAddressOffset = 48     // a 16-byte union: in6_addr, or IPv4 in its last 4
    static let localAddressOffset = 64
    // struct xsocket_n, #pragma pack(4)
    static let lastPIDOffset = 68
    static let effectivePIDOffset = 72
    static let flagsOffset = 84

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        /// The sysctl refused (its errno): in a sandbox that does not allow it, say.
        case refused(Int32)
        /// It answered with something that is not the table's layout.
        case unreadable

        public var description: String {
            switch self {
            case .refused(let code): return "the kernel refused the table (errno \(code): \(Self.message(code)))"
            case .unreadable: return "the table's bytes are not the layout read (xinpgen, xinpcb_n, xsocket_n)"
            }
        }

        static func message(_ code: Int32) -> String {
            #if canImport(Darwin)
            return String(cString: strerror(code))
            #else
            return "errno"
            #endif
        }
    }

    /// The sockets in a table's bytes; nil when they are not its layout.
    public static func parse(_ bytes: [UInt8], transport: GuardTransport) -> [KernelSocket]? {
        guard bytes.count >= headerLength, let first = word(bytes, 0), Int(first) == headerLength else { return nil }
        var sockets: [KernelSocket] = []
        var offset = headerLength
        var inpcb: (localPort: UInt16, remotePort: UInt16, local: String?, remote: String?)?
        while offset + 8 <= bytes.count {
            guard let length = word(bytes, offset).map(Int.init), let kind = word(bytes, offset + 4) else { return nil }
            // The trailing header: the table's end.
            if length == headerLength, offset + headerLength >= bytes.count { break }
            guard length >= 8, offset + length <= bytes.count else { return nil }
            switch kind {
            case kindInpcb:
                guard length >= inpcbLength else { return nil }
                let version = bytes[offset + versionFlagOffset]
                inpcb = (localPort: port(bytes, offset + localPortOffset),
                         remotePort: port(bytes, offset + foreignPortOffset),
                         local: address(bytes, offset + localAddressOffset, version: version),
                         remote: address(bytes, offset + foreignAddressOffset, version: version))
            case kindSocket:
                guard length >= socketLength else { return nil }
                if let pcb = inpcb, let last = word(bytes, offset + lastPIDOffset),
                   let effective = word(bytes, offset + effectivePIDOffset), let flags = word(bytes, offset + flagsOffset) {
                    sockets.append(KernelSocket(transport: transport, localAddress: pcb.local, localPort: pcb.localPort,
                                                remoteAddress: pcb.remote,
                                                remotePort: pcb.remotePort, lastPID: Int32(bitPattern: last),
                                                effectivePID: Int32(bitPattern: effective),
                                                delegated: flags & delegatedFlag != 0))
                }
                inpcb = nil
            default:
                break
            }
            offset += (length + 7) & ~7
        }
        return sockets
    }

    /// The socket of a flow: same transport and local port, and — among several on that port (a
    /// listener and its connections share one) — the one connected to the flow's remote end, else one
    /// not connected; among those, one the flow's opener last used. Nil when none is on that port.
    public static func socket(of transport: GuardTransport, localPort: UInt16, remoteAddress: String?, remotePort: UInt16?,
                              openerPID: Int32?, in sockets: [KernelSocket]) -> KernelSocket? {
        let onPort = sockets.filter { $0.transport == transport && $0.localPort == localPort && localPort != 0 }
        let remote = remoteAddress.flatMap(GuardPolicy.canonicalAddress)
        let connected = onPort.filter { $0.remoteAddress != nil && $0.remoteAddress == remote && $0.remotePort == (remotePort ?? 0) }
        let candidates = !connected.isEmpty ? connected : onPort.filter { $0.remoteAddress == nil }
        return candidates.first { $0.lastPID == openerPID } ?? candidates.first
    }

    #if canImport(Darwin)
    /// The kernel's table of a transport's sockets, read now.
    public static func read(_ transport: GuardTransport) -> Result<[KernelSocket], ReadError> {
        let name: String
        switch transport {
        case .udp: name = "net.inet.udp.pcblist_n"
        case .tcp: name = "net.inet.tcp.pcblist_n"
        case .other: return .success([])
        }
        // The table grows between asking its size and reading it: asked again, with room to spare.
        for _ in 0..<3 {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return .failure(.refused(errno)) }
            size += size / 4 + 4096
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctlbyname(name, &buffer, &size, nil, 0) == 0 {
                guard let sockets = parse(Array(buffer.prefix(size)), transport: transport) else { return .failure(.unreadable) }
                return .success(sockets)
            }
            if errno != ENOMEM { return .failure(.refused(errno)) }
        }
        return .failure(.refused(ENOMEM))
    }
    #endif

    // MARK: Bytes

    static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        // The kernel's own byte order: little-endian on every Mac this runs on.
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// A port, kept in network byte order by the kernel.
    static func port(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    /// The address in a 16-byte union: IPv4 in its last four bytes, else IPv6; nil when all zero.
    static func address(_ bytes: [UInt8], _ offset: Int, version: UInt8) -> String? {
        let raw = Array(bytes[offset..<offset + 16])
        let ipv6 = version & 0x2 != 0
        let zeroPrefix = raw[0..<12].allSatisfy { $0 == 0 }
        let mapped = raw[0..<10].allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff
        if !ipv6 || mapped || (version & 0x1 != 0 && zeroPrefix) {
            let v4 = Array(raw[12..<16])
            guard v4.contains(where: { $0 != 0 }) else { return nil }
            return v4.map(String.init).joined(separator: ".")
        }
        guard raw.contains(where: { $0 != 0 }) else { return nil }
        let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]), radix: 16) }
        return GuardPolicy.canonicalAddress(groups.joined(separator: ":"))
    }
}

/// Whom the guard holds a flow for, and by which answer.
///
/// The content filter names a flow's source application (`sourceAppAuditToken`). On the owner's
/// Mac (0.1.2, macOS 27.0.1) it named WebKit's network process for the probe's STUN request, while
/// the kernel counted every packet of it for the probe (`eproc`): the guard, which holds the probe,
/// let it through. The kernel's record of the flow's socket (`KernelSocket.countedFor`) is the
/// other answer.
public enum GuardAttribution {
    public enum Source: String, Codable, Sendable {
        /// The content filter's source application.
        case sourceApplication
        /// The kernel's record of the flow's socket: the process it is counted for.
        case kernelSocket
    }

    /// The held process a flow is for: the source application when the guard holds it; nil when it
    /// does not. (The kernel's record is read and said, not yet taken: this is the guard of 0.1.2.)
    public static func holder(appPID: Int32?, socket: KernelSocket?, isHeld: (Int32) -> Bool) -> (pid: Int32, source: Source)? {
        if let appPID, isHeld(appPID) { return (appPID, .sourceApplication) }
        return nil
    }
}
