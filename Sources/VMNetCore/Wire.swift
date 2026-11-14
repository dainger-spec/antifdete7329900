import Foundation

// The frames on the guest's wire: Ethernet II, ARP, IPv4, ICMP, UDP and TCP, read from and written
// to plain bytes. Nothing here keeps state or touches a socket, so all of it is tested as data.

extension UnsafeRawBufferPointer {
    @inline(__always) func be16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    @inline(__always) func be32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func mac(_ offset: Int) -> VMNetMAC {
        var value: UInt64 = 0
        for index in 0..<6 { value = value << 8 | UInt64(self[offset + index]) }
        return VMNetMAC(raw: value)
    }

    /// The bytes from `start`, `length` of them (to the end when nil). The caller has checked the bounds.
    func part(_ start: Int, _ length: Int? = nil) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: self[start..<(start + (length ?? count - start))])
    }
}

extension UnsafeMutableRawBufferPointer {
    @inline(__always) func put16(_ offset: Int, _ value: UInt16) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    @inline(__always) func put32(_ offset: Int, _ value: UInt32) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    func putMAC(_ offset: Int, _ address: VMNetMAC) {
        for index in 0..<6 { self[offset + index] = UInt8(truncatingIfNeeded: address.raw >> UInt64(40 - 8 * index)) }
    }
}

/// The Internet checksum (RFC 1071): the one's-complement sum of 16-bit words that IPv4, ICMP, UDP
/// and TCP all carry.
enum InternetChecksum {
    /// Adds `bytes` to a running sum. Only the last piece of a message may have an odd length
    /// (its last byte is padded with a zero, as the RFC says).
    static func add(_ bytes: UnsafeRawBufferPointer, to sum: UInt64 = 0) -> UInt64 {
        var sum = sum
        var index = 0
        let count = bytes.count
        // Eight bytes at a time: 2^16 is 1 modulo 65535, so 32-bit words sum to the same result
        // as 16-bit ones once the carries are folded back in.
        while index + 8 <= count {
            let word = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self))
            sum &+= (word >> 32) &+ (word & 0xFFFF_FFFF)
            index += 8
        }
        while index + 2 <= count {
            sum &+= UInt64(bytes.be16(index))
            index += 2
        }
        if index < count { sum &+= UInt64(bytes[index]) << 8 }
        return sum
    }

    /// The part of a UDP or TCP checksum that covers the addresses, the protocol and the length.
    static func pseudoHeader(source: VMNetIPv4, destination: VMNetIPv4, proto: UInt8, length: Int) -> UInt64 {
        UInt64(source.value >> 16) + UInt64(source.value & 0xFFFF) + UInt64(destination.value >> 16)
            + UInt64(destination.value & 0xFFFF) + UInt64(proto) + UInt64(length)
    }

    /// The checksum field's value for a sum: the carries folded in, then every bit inverted.
    static func finish(_ sum: UInt64) -> UInt16 {
        var folded = sum
        while folded >> 16 != 0 { folded = (folded & 0xFFFF) + (folded >> 16) }
        return ~UInt16(truncatingIfNeeded: folded)
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        finish(add(bytes))
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        bytes.withUnsafeBytes { checksum($0) }
    }
}

enum EtherType {
    static let ipv4: UInt16 = 0x0800
    static let arp: UInt16 = 0x0806
    static let vlan: UInt16 = 0x8100
    static let ipv6: UInt16 = 0x86DD
}

enum IPProtocol {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

/// An Ethernet II frame: who it is for, who sent it, what it carries.
struct EthernetFrame {
    static let headerLength = 14

    var destination: VMNetMAC
    var source: VMNetMAC
    var etherType: UInt16
    var payload: UnsafeRawBufferPointer

    init?(_ frame: UnsafeRawBufferPointer) {
        guard frame.count >= Self.headerLength else { return nil }
        destination = frame.mac(0)
        source = frame.mac(6)
        etherType = frame.be16(12)
        payload = frame.part(Self.headerLength)
    }
}

/// An ARP message for IPv4 over Ethernet (RFC 826).
struct ARPPacket: Equatable {
    static let request: UInt16 = 1
    static let reply: UInt16 = 2
    static let length = 28

    var operation: UInt16
    var senderMAC: VMNetMAC
    var senderAddress: VMNetIPv4
    var targetMAC: VMNetMAC
    var targetAddress: VMNetIPv4

    init(operation: UInt16, senderMAC: VMNetMAC, senderAddress: VMNetIPv4, targetMAC: VMNetMAC, targetAddress: VMNetIPv4) {
        self.operation = operation
        self.senderMAC = senderMAC
        self.senderAddress = senderAddress
        self.targetMAC = targetMAC
        self.targetAddress = targetAddress
    }

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.length, bytes.be16(0) == 1, bytes.be16(2) == EtherType.ipv4, bytes[4] == 6, bytes[5] == 4 else { return nil }
        operation = bytes.be16(6)
        senderMAC = bytes.mac(8)
        senderAddress = VMNetIPv4(bytes.be32(14))
        targetMAC = bytes.mac(18)
        targetAddress = VMNetIPv4(bytes.be32(24))
    }

    /// The whole frame that carries this message from `source` to `destination`.
    func frame(destination: VMNetMAC, source: VMNetMAC) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: EthernetFrame.headerLength + Self.length)
        frame.withUnsafeMutableBytes { buffer in
            buffer.putMAC(0, destination)
            buffer.putMAC(6, source)
            buffer.put16(12, EtherType.arp)
            buffer.put16(14, 1)
            buffer.put16(16, EtherType.ipv4)
            buffer[18] = 6
            buffer[19] = 4
            buffer.put16(20, operation)
            buffer.putMAC(22, senderMAC)
            buffer.put32(28, senderAddress.value)
            buffer.putMAC(32, targetMAC)
            buffer.put32(38, targetAddress.value)
        }
        return frame
    }
}

/// An IPv4 packet whose header was checked: version, lengths, checksum.
struct IPv4Packet {
    static let minimumHeaderLength = 20

    var source: VMNetIPv4
    var destination: VMNetIPv4
    var proto: UInt8
    var timeToLive: UInt8
    /// More fragments follow, or this is not the first one: a piece of a datagram, not a whole one.
    var isFragment: Bool
    /// The header as it came, options included (an ICMP error quotes it).
    var header: UnsafeRawBufferPointer
    var payload: UnsafeRawBufferPointer

    /// Nil when the bytes are not a whole IPv4 packet or the header's checksum is wrong. Bytes
    /// after the packet's own length (Ethernet's padding of short frames) are left out.
    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.minimumHeaderLength, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        let totalLength = Int(bytes.be16(2))
        guard headerLength >= Self.minimumHeaderLength, totalLength >= headerLength, totalLength <= bytes.count else { return nil }
        header = bytes.part(0, headerLength)
        guard InternetChecksum.checksum(header) == 0 else { return nil }
        let fragment = bytes.be16(6)
        isFragment = fragment & 0x2000 != 0 || fragment & 0x1FFF != 0
        timeToLive = bytes[8]
        proto = bytes[9]
        source = VMNetIPv4(bytes.be32(12))
        destination = VMNetIPv4(bytes.be32(16))
        payload = bytes.part(headerLength, totalLength - headerLength)
    }
}

struct UDPDatagram {
    static let headerLength = 8

    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: UnsafeRawBufferPointer

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.headerLength else { return nil }
        let length = Int(bytes.be16(4))
        guard length >= Self.headerLength, length <= bytes.count else { return nil }
        sourcePort = bytes.be16(0)
        destinationPort = bytes.be16(2)
        payload = bytes.part(Self.headerLength, length - Self.headerLength)
    }
}

struct ICMPMessage {
    static let echoReply: UInt8 = 0
    static let destinationUnreachable: UInt8 = 3
    static let echoRequest: UInt8 = 8
    static let portUnreachable: UInt8 = 3
    static let headerLength = 8

    var type: UInt8
    var code: UInt8
    /// The four bytes after the checksum: an echo's identifier and sequence number.
    var rest: UInt32
    var payload: UnsafeRawBufferPointer

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.headerLength else { return nil }
        type = bytes[0]
        code = bytes[1]
        rest = bytes.be32(4)
        payload = bytes.part(Self.headerLength)
    }
}

struct TCPFlags: OptionSet, Equatable {
    let rawValue: UInt8
    static let fin = TCPFlags(rawValue: 0x01)
    static let syn = TCPFlags(rawValue: 0x02)
    static let rst = TCPFlags(rawValue: 0x04)
    static let psh = TCPFlags(rawValue: 0x08)
    static let ack = TCPFlags(rawValue: 0x10)
}

/// A TCP segment and the two options this stack uses.
struct TCPSegment {
    static let minimumHeaderLength = 20

    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequence: UInt32
    var acknowledgement: UInt32
    var flags: TCPFlags
    /// The window field as sent (not yet scaled).
    var window: UInt16
    /// The largest segment the sender takes (option 2). Only a SYN carries it.
    var maximumSegmentSize: UInt16?
    /// The sender's window shift (option 3). Only a SYN carries it.
    var windowScale: UInt8?
    var payload: UnsafeRawBufferPointer

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.minimumHeaderLength else { return nil }
        let headerLength = Int(bytes[12] >> 4) * 4
        guard headerLength >= Self.minimumHeaderLength, headerLength <= bytes.count else { return nil }
        sourcePort = bytes.be16(0)
        destinationPort = bytes.be16(2)
        sequence = bytes.be32(4)
        acknowledgement = bytes.be32(8)
        flags = TCPFlags(rawValue: bytes[13] & 0x1F)
        window = bytes.be16(14)
        payload = bytes.part(headerLength)
        var index = Self.minimumHeaderLength
        while index < headerLength {
            let kind = bytes[index]
            if kind == 0 { break }
            if kind == 1 { index += 1; continue }
            guard index + 1 < headerLength else { break }
            let length = Int(bytes[index + 1])
            guard length >= 2, index + length <= headerLength else { break }
            if kind == 2, length == 4 { maximumSegmentSize = bytes.be16(index + 2) }
            if kind == 3, length == 3 { windowScale = bytes[index + 2] }
            index += length
        }
    }
}

/// Writes the frames the stack sends. Every one is IPv4 with "don't fragment" set and a TTL of 64.
enum FrameBuilder {
    static let ipOffset = EthernetFrame.headerLength
    static let transportOffset = EthernetFrame.headerLength + IPv4Packet.minimumHeaderLength

    /// The Ethernet and IPv4 headers of a packet with `payloadLength` bytes after the IPv4 header.
    static func writeHeaders(_ buffer: UnsafeMutableRawBufferPointer, destinationMAC: VMNetMAC, sourceMAC: VMNetMAC,
                             source: VMNetIPv4, destination: VMNetIPv4, proto: UInt8, payloadLength: Int, identification: UInt16) {
        buffer.putMAC(0, destinationMAC)
        buffer.putMAC(6, sourceMAC)
        buffer.put16(12, EtherType.ipv4)
        let ip = ipOffset
        buffer[ip] = 0x45
        buffer[ip + 1] = 0
        buffer.put16(ip + 2, UInt16(IPv4Packet.minimumHeaderLength + payloadLength))
        buffer.put16(ip + 4, identification)
        buffer.put16(ip + 6, 0x4000)
        buffer[ip + 8] = 64
        buffer[ip + 9] = proto
        buffer.put16(ip + 10, 0)
        buffer.put32(ip + 12, source.value)
        buffer.put32(ip + 16, destination.value)
        let header = UnsafeRawBufferPointer(rebasing: buffer[ip..<(ip + IPv4Packet.minimumHeaderLength)])
        buffer.put16(ip + 10, InternetChecksum.checksum(header))
    }

    static func udp(destinationMAC: VMNetMAC, sourceMAC: VMNetMAC, source: VMNetIPv4, sourcePort: UInt16,
                    destination: VMNetIPv4, destinationPort: UInt16, payload: [UInt8], identification: UInt16) -> [UInt8] {
        let length = UDPDatagram.headerLength + payload.count
        var frame = [UInt8](repeating: 0, count: transportOffset + length)
        frame.withUnsafeMutableBytes { buffer in
            writeHeaders(buffer, destinationMAC: destinationMAC, sourceMAC: sourceMAC, source: source, destination: destination,
                         proto: IPProtocol.udp, payloadLength: length, identification: identification)
            let udp = transportOffset
            buffer.put16(udp, sourcePort)
            buffer.put16(udp + 2, destinationPort)
            buffer.put16(udp + 4, UInt16(length))
            payload.withUnsafeBytes { bytes in
                UnsafeMutableRawBufferPointer(rebasing: buffer[(udp + 8)...]).copyMemory(from: bytes)
            }
            let sum = InternetChecksum.add(UnsafeRawBufferPointer(rebasing: buffer[udp...]),
                                           to: InternetChecksum.pseudoHeader(source: source, destination: destination, proto: IPProtocol.udp, length: length))
            let checksum = InternetChecksum.finish(sum)
            // Zero means "no checksum" in UDP; a sum that comes out zero is sent as all ones.
            buffer.put16(udp + 6, checksum == 0 ? 0xFFFF : checksum)
        }
        return frame
    }

    static func icmp(destinationMAC: VMNetMAC, sourceMAC: VMNetMAC, source: VMNetIPv4, destination: VMNetIPv4,
                     type: UInt8, code: UInt8, rest: UInt32, payload: UnsafeRawBufferPointer, identification: UInt16) -> [UInt8] {
        let length = ICMPMessage.headerLength + payload.count
        var frame = [UInt8](repeating: 0, count: transportOffset + length)
        frame.withUnsafeMutableBytes { buffer in
            writeHeaders(buffer, destinationMAC: destinationMAC, sourceMAC: sourceMAC, source: source, destination: destination,
                         proto: IPProtocol.icmp, payloadLength: length, identification: identification)
            let icmp = transportOffset
            buffer[icmp] = type
            buffer[icmp + 1] = code
            buffer.put32(icmp + 4, rest)
            UnsafeMutableRawBufferPointer(rebasing: buffer[(icmp + 8)...]).copyMemory(from: payload)
            buffer.put16(icmp + 2, InternetChecksum.checksum(UnsafeRawBufferPointer(rebasing: buffer[icmp...])))
        }
        return frame
    }

    /// Writes a TCP segment's whole frame into `buffer` and returns its length. `options` is a
    /// multiple of four bytes.
    static func tcp(into buffer: UnsafeMutableRawBufferPointer, destinationMAC: VMNetMAC, sourceMAC: VMNetMAC,
                    source: VMNetIPv4, sourcePort: UInt16, destination: VMNetIPv4, destinationPort: UInt16,
                    sequence: UInt32, acknowledgement: UInt32, flags: TCPFlags, window: UInt16,
                    options: [UInt8] = [], payload: UnsafeRawBufferPointer, identification: UInt16) -> Int {
        let headerLength = TCPSegment.minimumHeaderLength + options.count
        let length = headerLength + payload.count
        writeHeaders(buffer, destinationMAC: destinationMAC, sourceMAC: sourceMAC, source: source, destination: destination,
                     proto: IPProtocol.tcp, payloadLength: length, identification: identification)
        let tcp = transportOffset
        buffer.put16(tcp, sourcePort)
        buffer.put16(tcp + 2, destinationPort)
        buffer.put32(tcp + 4, sequence)
        buffer.put32(tcp + 8, acknowledgement)
        buffer[tcp + 12] = UInt8(headerLength / 4) << 4
        buffer[tcp + 13] = flags.rawValue
        buffer.put16(tcp + 14, window)
        buffer.put16(tcp + 16, 0)
        buffer.put16(tcp + 18, 0)
        for (index, byte) in options.enumerated() { buffer[tcp + 20 + index] = byte }
        if !payload.isEmpty {
            UnsafeMutableRawBufferPointer(rebasing: buffer[(tcp + headerLength)..<(tcp + length)]).copyMemory(from: payload)
        }
        let sum = InternetChecksum.add(UnsafeRawBufferPointer(rebasing: buffer[tcp..<(tcp + length)]),
                                       to: InternetChecksum.pseudoHeader(source: source, destination: destination, proto: IPProtocol.tcp, length: length))
        buffer.put16(tcp + 16, InternetChecksum.finish(sum))
        return tcp + length
    }
}
