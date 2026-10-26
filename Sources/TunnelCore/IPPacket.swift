/// A UDP datagram as the tunnel sees it: addresses and payload, IPv4 or IPv6.
public struct UDPDatagram: Equatable, Sendable {
    public var source: SocketAddress
    public var destination: SocketAddress
    public var payload: [UInt8]

    public init(source: SocketAddress, destination: SocketAddress, payload: [UInt8]) {
        self.source = source
        self.destination = destination
        self.payload = payload
    }
}

/// Reading and writing the IP packets of the tunnel interface (the `NEPacketTunnelFlow` side).
/// Only unfragmented UDP over IPv4 or IPv6 is understood; anything else is returned as `nil`
/// and dropped by the caller — the tunnel routes nothing but its own virtual subnet, so only
/// the browser's TURN traffic to the relay arrives here.
public enum IPPacket {
    public static let udp: UInt8 = 17

    /// The UDP datagram in `packet`, or nil for anything else: another protocol, an IP fragment,
    /// a truncated or inconsistent header, or a bad UDP checksum.
    public static func parseUDP(_ packet: [UInt8]) -> UDPDatagram? {
        guard let first = packet.first else { return nil }
        switch first >> 4 {
        case 4: return parseIPv4(packet)
        case 6: return parseIPv6(packet)
        default: return nil
        }
    }

    /// An IPv4 or IPv6 packet carrying `datagram` (both addresses must be of the same family),
    /// with valid header and UDP checksums.
    public static func buildUDP(_ datagram: UDPDatagram, hopLimit: UInt8 = 64) -> [UInt8]? {
        let source = datagram.source, destination = datagram.destination
        guard source.family == destination.family else { return nil }
        let udpLength = 8 + datagram.payload.count
        guard udpLength <= 0xFFFF else { return nil }
        var udp = [UInt8](repeating: 0, count: 8)
        put16(&udp, 0, source.port)
        put16(&udp, 2, destination.port)
        put16(&udp, 4, UInt16(udpLength))
        udp += datagram.payload
        var checksum = udpChecksum(udp, source: source.ip, destination: destination.ip)
        if checksum == 0 { checksum = 0xFFFF } // 0 means "no checksum" (IPv4) and is invalid for IPv6
        put16(&udp, 6, checksum)

        switch source.family {
        case .v4:
            let total = 20 + udpLength
            guard total <= 0xFFFF else { return nil }
            var header = [UInt8](repeating: 0, count: 20)
            header[0] = 0x45
            put16(&header, 2, UInt16(total))
            header[6] = 0x40 // don't fragment
            header[8] = hopLimit
            header[9] = IPPacket.udp
            header.replaceSubrange(12..<16, with: source.ip.bytes)
            header.replaceSubrange(16..<20, with: destination.ip.bytes)
            put16(&header, 10, onesComplement(sum(header)))
            return header + udp
        case .v6:
            var header = [UInt8](repeating: 0, count: 40)
            header[0] = 0x60
            put16(&header, 4, UInt16(udpLength))
            header[6] = IPPacket.udp
            header[7] = hopLimit
            header.replaceSubrange(8..<24, with: source.ip.bytes)
            header.replaceSubrange(24..<40, with: destination.ip.bytes)
            return header + udp
        }
    }

    // MARK: IPv4

    private static func parseIPv4(_ packet: [UInt8]) -> UDPDatagram? {
        guard packet.count >= 20 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let total = Int(get16(packet, 2))
        guard headerLength >= 20, total >= headerLength, total <= packet.count else { return nil }
        // Fragments (more-fragments set, or a non-zero offset) are not reassembled.
        let fragment = get16(packet, 6)
        guard fragment & 0x2000 == 0, fragment & 0x1FFF == 0 else { return nil }
        guard packet[9] == IPPacket.udp else { return nil }
        guard onesComplement(sum(Array(packet[0..<headerLength]))) == 0 else { return nil }
        guard let source = IPAddr(bytes: Array(packet[12..<16])),
              let destination = IPAddr(bytes: Array(packet[16..<20])) else { return nil }
        return parseUDPHeader(Array(packet[headerLength..<total]), source: source, destination: destination, checksumOptional: true)
    }

    // MARK: IPv6

    private static func parseIPv6(_ packet: [UInt8]) -> UDPDatagram? {
        guard packet.count >= 40 else { return nil }
        let payloadLength = Int(get16(packet, 4))
        guard 40 + payloadLength <= packet.count else { return nil }
        guard let source = IPAddr(bytes: Array(packet[8..<24])),
              let destination = IPAddr(bytes: Array(packet[24..<40])) else { return nil }
        var next = packet[6]
        var offset = 40
        let end = 40 + payloadLength
        // Skip hop-by-hop (0), routing (43) and destination options (60) headers; a fragment
        // header (44) means a fragment, which is dropped.
        while next == 0 || next == 43 || next == 60 {
            guard offset + 8 <= end else { return nil }
            let length = (Int(packet[offset + 1]) + 1) * 8
            guard offset + length <= end else { return nil }
            next = packet[offset]
            offset += length
        }
        guard next == IPPacket.udp else { return nil }
        return parseUDPHeader(Array(packet[offset..<end]), source: source, destination: destination, checksumOptional: false)
    }

    // MARK: UDP

    private static func parseUDPHeader(_ segment: [UInt8], source: IPAddr, destination: IPAddr,
                                       checksumOptional: Bool) -> UDPDatagram? {
        guard segment.count >= 8 else { return nil }
        let length = Int(get16(segment, 4))
        guard length >= 8, length <= segment.count else { return nil }
        let udpBytes = Array(segment[0..<length])
        let checksum = get16(udpBytes, 6)
        if checksum == 0 {
            guard checksumOptional else { return nil }
        } else {
            guard udpChecksum(udpBytes, source: source, destination: destination) == 0 else { return nil }
        }
        return UDPDatagram(source: SocketAddress(ip: source, port: get16(udpBytes, 0)),
                           destination: SocketAddress(ip: destination, port: get16(udpBytes, 2)),
                           payload: Array(udpBytes[8...]))
    }

    /// The UDP checksum over the pseudo-header and `udp` (whose checksum field is included as it
    /// is: 0 when computing, the received value when verifying — then a valid one sums to 0).
    static func udpChecksum(_ udp: [UInt8], source: IPAddr, destination: IPAddr) -> UInt16 {
        var pseudo = source.bytes + destination.bytes
        if source.family == .v4 {
            pseudo += [0, IPPacket.udp, UInt8(udp.count >> 8), UInt8(udp.count & 0xFF)]
        } else {
            pseudo += [UInt8((udp.count >> 24) & 0xFF), UInt8((udp.count >> 16) & 0xFF),
                       UInt8((udp.count >> 8) & 0xFF), UInt8(udp.count & 0xFF), 0, 0, 0, IPPacket.udp]
        }
        return onesComplement(sum(pseudo) &+ sum(udp))
    }

    /// The 32-bit sum of `bytes` as big-endian 16-bit words (an odd last byte padded with 0).
    static func sum(_ bytes: [UInt8]) -> UInt32 {
        var total: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            total &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { total &+= UInt32(bytes[index]) << 8 }
        return total
    }

    static func onesComplement(_ sum: UInt32) -> UInt16 {
        var folded = sum
        while folded >> 16 != 0 { folded = (folded & 0xFFFF) &+ (folded >> 16) }
        return ~UInt16(folded)
    }
}

@inline(__always)
func get16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

@inline(__always)
func get32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}

@inline(__always)
func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xFF)
}

func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}
