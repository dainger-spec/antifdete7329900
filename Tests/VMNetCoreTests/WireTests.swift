import XCTest
@testable import VMNetCore

final class WireTests: XCTestCase {
    // MARK: - The public value types

    func testMACIsParsedInAnyCaseAndPrintedInLowerCase() {
        let mac = VMNetMAC(string: "AA:bb:0C:dd:EE:ff")
        XCTAssertEqual(mac?.bytes, [0xAA, 0xBB, 0x0C, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(mac?.string, "aa:bb:0c:dd:ee:ff")
        XCTAssertEqual(VMNetMAC(bytes: [0, 1, 2, 3, 4, 5]).string, "00:01:02:03:04:05")
        XCTAssertEqual(VMNetMAC(bytes: [0xAA, 0xBB, 0x0C, 0xDD, 0xEE, 0xFF]), mac)
        for bad in ["", "aa:bb:cc:dd:ee", "aa:bb:cc:dd:ee:ff:00", "aa:bb:cc:dd:ee:fg", "aabbccddeeff", "a:b:c:d:e:f", "aa-bb-cc-dd-ee-ff", "aa:bb:cc:dd:ee:"] {
            XCTAssertNil(VMNetMAC(string: bad), bad)
        }
    }

    func testIPv4IsADottedQuad() {
        XCTAssertEqual(VMNetIPv4(string: "192.168.1.23")?.value, 0xC0A8_0117)
        XCTAssertEqual(VMNetIPv4(0xC0A8_0101).string, "192.168.1.1")
        XCTAssertEqual(VMNetIPv4(string: "0.0.0.0")?.value, 0)
        XCTAssertEqual(VMNetIPv4(string: "255.255.255.255")?.value, 0xFFFF_FFFF)
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-4", "1.2.3.04", "a.b.c.d", "1..2.3", " 1.2.3.4", "1.2.3.4 ", "0x1.2.3.4"] {
            XCTAssertNil(VMNetIPv4(string: bad), bad)
        }
    }

    func testConfigurationDefaults() {
        let configuration = Wire.configuration()
        XCTAssertEqual(configuration.gatewayAddress.string, "192.168.1.1")
        XCTAssertEqual(configuration.guestAddress.string, "192.168.1.23")
        XCTAssertEqual(configuration.prefixLength, 24)
        XCTAssertEqual(configuration.mtu, 1500)
        XCTAssertEqual(configuration.blockedHostSuffixes, [])
    }

    // MARK: - Checksums

    func testChecksumOfRFC1071Example() {
        // RFC 1071 §3: the words 0001 f203 f4f5 f6f7 sum to ddf2, whose complement is 220d.
        XCTAssertEqual(InternetChecksum.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]), 0x220D)
    }

    func testChecksumOfAKnownIPv4Header() {
        // A header whose checksum field (b861) is known; over the whole header the sum is zero.
        let header: [UInt8] = [0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0xB8, 0x61,
                               0xC0, 0xA8, 0x00, 0x01, 0xC0, 0xA8, 0x00, 0xC7]
        XCTAssertEqual(InternetChecksum.checksum(header), 0)
        var cleared = header
        cleared[10] = 0
        cleared[11] = 0
        XCTAssertEqual(InternetChecksum.checksum(cleared), 0xB861)
    }

    func testChecksumOfOddLengthsAndEverySplitAgrees() {
        var random = TestRandom(seed: 1)
        for length in [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 63, 1459, 1460] {
            let bytes = random.bytes(length)
            // The reference: 16-bit words, one at a time.
            var sum: UInt32 = 0
            var index = 0
            while index + 1 < length {
                sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
                index += 2
            }
            if index < length { sum += UInt32(bytes[index]) << 8 }
            while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
            XCTAssertEqual(InternetChecksum.checksum(bytes), ~UInt16(sum), "length \(length)")
            // Summed in two pieces (the first of even length) it is the same.
            if length >= 4 {
                let split = (length / 2) & ~1
                let pieces = bytes.withUnsafeBytes { all in
                    InternetChecksum.finish(InternetChecksum.add(all.part(split), to: InternetChecksum.add(all.part(0, split))))
                }
                XCTAssertEqual(pieces, ~UInt16(sum), "length \(length) in two pieces")
            }
        }
    }

    // MARK: - Frames, built and read back

    func testTCPFrameRoundTrip() {
        let payload = Array("GET / HTTP/1.1\r\n\r\n".utf8)
        let frame = Wire.tcp(from: 50_000, to: VMNetIPv4(0xC612_0001), 443, sequence: 0xFFFF_FFF0, acknowledgement: 77,
                             flags: [.ack, .psh], window: 4321, payload: payload)
        XCTAssertEqual(frame.count, 14 + 20 + 20 + payload.count)
        let seen = Wire.seenTCP(frame)
        XCTAssertEqual(seen?.source, Wire.guest)
        XCTAssertEqual(seen?.destination.string, "198.18.0.1")
        XCTAssertEqual(seen?.sourcePort, 50_000)
        XCTAssertEqual(seen?.destinationPort, 443)
        XCTAssertEqual(seen?.sequence, 0xFFFF_FFF0)
        XCTAssertEqual(seen?.acknowledgement, 77)
        XCTAssertEqual(seen?.flags, [.ack, .psh])
        XCTAssertEqual(seen?.window, 4321)
        XCTAssertEqual(seen?.payload, payload)
        XCTAssertEqual(seen?.checksumValid, true)
        frame.withUnsafeBytes { bytes in
            let ethernet = EthernetFrame(bytes)
            XCTAssertEqual(ethernet?.destination, Wire.gatewayMAC)
            XCTAssertEqual(ethernet?.source, Wire.guestMAC)
            XCTAssertEqual(ethernet?.etherType, EtherType.ipv4)
            let packet = IPv4Packet(ethernet!.payload)
            XCTAssertEqual(packet?.timeToLive, 64)
            XCTAssertEqual(packet?.isFragment, false)
        }
    }

    func testTCPOptionsAreRead() {
        let syn = Wire.tcp(from: 1, to: VMNetIPv4(0x0101_0101), 80, sequence: 1, flags: [.syn],
                           options: [2, 4, 0x05, 0xB4, 4, 2, 8, 10, 0, 0, 0, 1, 0, 0, 0, 0, 1, 3, 3, 6])
        let seen = Wire.seenTCP(syn)
        XCTAssertEqual(seen?.maximumSegmentSize, 1460)
        XCTAssertEqual(seen?.windowScale, 6)
        XCTAssertEqual(seen?.payload, [])
        // No options, and options cut short, are no options — not a crash.
        XCTAssertNil(Wire.seenTCP(Wire.tcp(from: 1, to: VMNetIPv4(0x0101_0101), 80, sequence: 1, flags: [.syn]))?.maximumSegmentSize)
        let cut = Wire.seenTCP(Wire.tcp(from: 1, to: VMNetIPv4(0x0101_0101), 80, sequence: 1, flags: [.syn], options: [2, 4, 0x05, 3]))
        XCTAssertNil(cut?.windowScale)
        let broken = Wire.seenTCP(Wire.tcp(from: 1, to: VMNetIPv4(0x0101_0101), 80, sequence: 1, flags: [.syn], options: [3, 0, 1, 1]))
        XCTAssertNil(broken?.windowScale)
    }

    func testUDPFrameRoundTrip() {
        let frame = Wire.udp(from: 5353, to: VMNetIPv4(0x0808_0808), 53, payload: [1, 2, 3, 4, 5])
        let seen = Wire.seenUDP(frame)
        XCTAssertEqual(seen?.sourcePort, 5353)
        XCTAssertEqual(seen?.destinationPort, 53)
        XCTAssertEqual(seen?.destination.string, "8.8.8.8")
        XCTAssertEqual(seen?.payload, [1, 2, 3, 4, 5])
        XCTAssertEqual(seen?.checksumValid, true)
    }

    func testIPv4RejectsABadHeaderAndFlagsFragments() {
        var frame = Wire.udp(from: 1, to: VMNetIPv4(0x0808_0808), 2, payload: [9])
        frame.withUnsafeBytes { XCTAssertNotNil(IPv4Packet($0.part(14))) }
        // One bit wrong in the header: its checksum no longer fits.
        frame[14 + 8] ^= 0x01
        frame.withUnsafeBytes { XCTAssertNil(IPv4Packet($0.part(14))) }
        frame[14 + 8] ^= 0x01
        // Version 6, a header length below 20, a total length past the bytes.
        var other = frame
        other[14] = 0x65
        other.withUnsafeBytes { XCTAssertNil(IPv4Packet($0.part(14))) }
        other = frame
        other[14] = 0x44
        other.withUnsafeBytes { XCTAssertNil(IPv4Packet($0.part(14))) }
        frame.withUnsafeBytes { XCTAssertNil(IPv4Packet($0.part(14, 28))) }
        frame.withUnsafeBytes { XCTAssertNil(IPv4Packet($0.part(14, 10))) }
        // "More fragments" set, with the checksum made right again.
        var fragment = frame
        fragment[14 + 6] = 0x20
        fragment[14 + 10] = 0
        fragment[14 + 11] = 0
        let checksum = InternetChecksum.checksum(Array(fragment[14..<34]))
        fragment[14 + 10] = UInt8(checksum >> 8)
        fragment[14 + 11] = UInt8(checksum & 0xFF)
        fragment.withUnsafeBytes { XCTAssertEqual(IPv4Packet($0.part(14))?.isFragment, true) }
    }

    func testEthernetPaddingIsNotPayload() {
        // A short frame padded to Ethernet's 60 bytes: the IPv4 length says where the packet ends.
        var frame = Wire.udp(from: 1, to: VMNetIPv4(0x0808_0808), 2, payload: [9])
        frame += [UInt8](repeating: 0xEE, count: 60 - frame.count)
        XCTAssertEqual(Wire.seenUDP(frame)?.payload, [9])
    }

    func testTruncatedFramesAreNotParsed() {
        let frame = Wire.tcp(from: 1, to: VMNetIPv4(0x0101_0101), 80, sequence: 1, flags: [.syn])
        for length in [0, 5, 13] {
            Array(frame[0..<length]).withUnsafeBytes { XCTAssertNil(EthernetFrame($0)) }
        }
        frame.withUnsafeBytes { bytes in
            XCTAssertNil(TCPSegment(bytes.part(34, 19)))
            XCTAssertNil(UDPDatagram(bytes.part(34, 7)))
            XCTAssertNil(ICMPMessage(bytes.part(34, 7)))
            XCTAssertNil(ARPPacket(bytes.part(14, 27)))
        }
    }

    // MARK: - ARP and ping, through the responder

    private func respond(_ responder: inout LinkResponder, _ frame: [UInt8], now: Double = 1) -> [UInt8]? {
        var counters = VMNetCounters()
        return frame.withUnsafeBytes { bytes -> [UInt8]? in
            if case .reply(let reply) = responder.handle(bytes, now: now, counters: &counters) { return reply }
            return nil
        }
    }

    func testARPForTheGatewayIsAnswered() {
        var responder = LinkResponder(configuration: Wire.configuration())
        let request = ARPPacket(operation: ARPPacket.request, senderMAC: Wire.guestMAC, senderAddress: Wire.guest,
                                targetMAC: VMNetMAC(raw: 0), targetAddress: Wire.gateway)
        let reply = respond(&responder, request.frame(destination: .broadcast, source: Wire.guestMAC))
        XCTAssertNotNil(reply)
        reply?.withUnsafeBytes { bytes in
            let ethernet = EthernetFrame(bytes)!
            XCTAssertEqual(ethernet.destination, Wire.guestMAC)
            XCTAssertEqual(ethernet.source, Wire.gatewayMAC)
            XCTAssertEqual(ethernet.etherType, EtherType.arp)
            XCTAssertEqual(ARPPacket(ethernet.payload), ARPPacket(operation: ARPPacket.reply, senderMAC: Wire.gatewayMAC, senderAddress: Wire.gateway,
                                                                   targetMAC: Wire.guestMAC, targetAddress: Wire.guest))
        }
    }

    func testARPForAnythingElseIsNotAnswered() {
        var responder = LinkResponder(configuration: Wire.configuration())
        // The guest's check of its own address, another address of the network, an ARP reply.
        for (operation, target) in [(ARPPacket.request, Wire.guest), (ARPPacket.request, VMNetIPv4(0xC0A8_0102)), (ARPPacket.reply, Wire.gateway)] {
            let packet = ARPPacket(operation: operation, senderMAC: Wire.guestMAC, senderAddress: .unspecified,
                                   targetMAC: VMNetMAC(raw: 0), targetAddress: target)
            XCTAssertNil(respond(&responder, packet.frame(destination: .broadcast, source: Wire.guestMAC)))
        }
    }

    private func ping(to destination: VMNetIPv4, destinationMAC: VMNetMAC = Wire.gatewayMAC, payload: [UInt8] = Array("abcdefgh".utf8)) -> [UInt8] {
        payload.withUnsafeBytes { bytes in
            FrameBuilder.icmp(destinationMAC: destinationMAC, sourceMAC: Wire.guestMAC, source: Wire.guest, destination: destination,
                              type: ICMPMessage.echoRequest, code: 0, rest: 0x1234_0007, payload: bytes, identification: 3)
        }
    }

    func testPingOfTheGatewayIsAnswered() {
        var responder = LinkResponder(configuration: Wire.configuration())
        let reply = respond(&responder, ping(to: Wire.gateway))
        XCTAssertNotNil(reply)
        reply?.withUnsafeBytes { bytes in
            let ethernet = EthernetFrame(bytes)!
            XCTAssertEqual(ethernet.destination, Wire.guestMAC)
            let packet = IPv4Packet(ethernet.payload)!
            XCTAssertEqual(packet.source, Wire.gateway)
            XCTAssertEqual(packet.destination, Wire.guest)
            XCTAssertEqual(packet.proto, IPProtocol.icmp)
            XCTAssertEqual(InternetChecksum.checksum(packet.payload), 0)
            let message = ICMPMessage(packet.payload)!
            XCTAssertEqual(message.type, ICMPMessage.echoReply)
            XCTAssertEqual(message.rest, 0x1234_0007)
            XCTAssertEqual(Array(message.payload), Array("abcdefgh".utf8))
        }
    }

    func testPingOfAnythingElseIsNotAnswered() {
        var responder = LinkResponder(configuration: Wire.configuration())
        XCTAssertNil(respond(&responder, ping(to: VMNetIPv4(0x0808_0808))))
        XCTAssertNil(respond(&responder, ping(to: VMNetIPv4(0xC0A8_0105))))
        XCTAssertNil(respond(&responder, ping(to: .broadcast, destinationMAC: .broadcast)))
    }

    // MARK: - What the responder leaves alone

    func testFramesNotForTheGatewayAreIgnored() {
        var responder = LinkResponder(configuration: Wire.configuration())
        let other = VMNetMAC(string: "52:54:00:99:99:99")!
        XCTAssertNil(respond(&responder, ping(to: Wire.gateway, destinationMAC: other)))
        // A frame that claims to come from the gateway itself.
        let request = ARPPacket(operation: ARPPacket.request, senderMAC: Wire.gatewayMAC, senderAddress: Wire.guest,
                                targetMAC: VMNetMAC(raw: 0), targetAddress: Wire.gateway)
        XCTAssertNil(respond(&responder, request.frame(destination: .broadcast, source: Wire.gatewayMAC)))
    }

    func testIPv6AndVLANAreIgnored() {
        var responder = LinkResponder(configuration: Wire.configuration())
        var frame = ping(to: Wire.gateway)
        frame[12] = 0x86
        frame[13] = 0xDD
        XCTAssertNil(respond(&responder, frame))
        frame[12] = 0x81
        frame[13] = 0x00
        XCTAssertNil(respond(&responder, frame))
    }

    func testFragmentsAreDropped() {
        var responder = LinkResponder(configuration: Wire.configuration())
        var frame = ping(to: Wire.gateway)
        frame[14 + 6] = 0x20
        frame[14 + 10] = 0
        frame[14 + 11] = 0
        let checksum = InternetChecksum.checksum(Array(frame[14..<34]))
        frame[14 + 10] = UInt8(checksum >> 8)
        frame[14 + 11] = UInt8(checksum & 0xFF)
        XCTAssertNil(respond(&responder, frame))
    }

    // MARK: - UDP that has no way out

    func testOtherUDPIsCountedAndAnsweredPortUnreachable() {
        var responder = LinkResponder(configuration: Wire.configuration())
        var counters = VMNetCounters()
        let datagram = Wire.udp(from: 40_000, to: VMNetIPv4(0x5DB8_D822), 443, payload: Array("a QUIC initial packet".utf8))
        let verdict = datagram.withUnsafeBytes { responder.handle($0, now: 1, counters: &counters) }
        XCTAssertEqual(counters.datagramsDropped, 1)
        guard case .reply(let reply) = verdict else { return XCTFail("no answer") }
        reply.withUnsafeBytes { bytes in
            let packet = IPv4Packet(EthernetFrame(bytes)!.payload)!
            // It comes "from" the host the datagram was for, as that host's own answer would.
            XCTAssertEqual(packet.source.string, "93.184.216.34")
            XCTAssertEqual(packet.destination, Wire.guest)
            XCTAssertEqual(InternetChecksum.checksum(packet.payload), 0)
            let message = ICMPMessage(packet.payload)!
            XCTAssertEqual(message.type, ICMPMessage.destinationUnreachable)
            XCTAssertEqual(message.code, ICMPMessage.portUnreachable)
            // It quotes the datagram's IP header and UDP header.
            XCTAssertEqual(Array(message.payload), Array(datagram[14..<(14 + 28)]))
        }
    }

    func testBroadcastAndMulticastUDPIsCountedButNotAnswered() {
        var responder = LinkResponder(configuration: Wire.configuration())
        var counters = VMNetCounters()
        let multicastMAC = VMNetMAC(string: "01:00:5e:00:00:fb")!
        let frames = [
            Wire.udp(from: 5353, to: VMNetIPv4(0xE000_00FB), 5353, payload: [1], destinationMAC: multicastMAC),
            Wire.udp(from: 137, to: VMNetIPv4(0xC0A8_01FF), 137, payload: [1], destinationMAC: .broadcast),
            Wire.udp(from: 68, to: .broadcast, 1900, payload: [1], destinationMAC: .broadcast),
            // Addressed to the gateway's card but to a broadcast address: still no error.
            Wire.udp(from: 137, to: VMNetIPv4(0xC0A8_01FF), 137, payload: [1]),
        ]
        for frame in frames {
            let verdict = frame.withUnsafeBytes { responder.handle($0, now: 1, counters: &counters) }
            if case .ignore = verdict {} else { XCTFail("answered") }
        }
        XCTAssertEqual(counters.datagramsDropped, 4)
    }

    func testPortUnreachableIsRateLimited() {
        var responder = LinkResponder(configuration: Wire.configuration())
        var counters = VMNetCounters()
        let datagram = Wire.udp(from: 40_000, to: VMNetIPv4(0x5DB8_D822), 443, payload: [1])
        func answered(at now: Double) -> Bool {
            let verdict = datagram.withUnsafeBytes { responder.handle($0, now: now, counters: &counters) }
            if case .reply = verdict { return true }
            return false
        }
        // A burst at one instant: the first hundred are answered, the rest are not.
        var count = 0
        for _ in 0..<500 where answered(at: 10) { count += 1 }
        XCTAssertEqual(count, Int(LinkResponder.unreachableBurst))
        XCTAssertEqual(counters.datagramsDropped, 500)
        // A tenth of a second later there is room for ten more.
        count = 0
        for _ in 0..<500 where answered(at: 10.1) { count += 1 }
        XCTAssertTrue((9...11).contains(count), "\(count)")
    }

    // MARK: - The queue of bytes

    func testByteQueueKeepsOrderThroughManySmallSteps() {
        var queue = ByteQueue()
        var random = TestRandom(seed: 5)
        var expected: [UInt8] = []
        var taken: [UInt8] = []
        var all: [UInt8] = []
        for _ in 0..<2_000 {
            let piece = random.bytes(Int(random.next() % 3_000))
            queue.append(piece)
            expected += piece
            all += piece
            let amount = min(Int(random.next() % 4_000), queue.count)
            queue.withBytes(from: 0, length: amount) { taken += Array($0) }
            queue.removeFirst(amount)
            expected.removeFirst(amount)
            XCTAssertEqual(queue.count, expected.count)
        }
        queue.withBytes { taken += Array($0) }
        XCTAssertTrue(taken == all, "the bytes differ")
        // A piece from the middle, and one that asks for more than there is.
        var other = ByteQueue()
        other.append([1, 2, 3, 4, 5])
        other.removeFirst(1)
        XCTAssertEqual(other.withBytes(from: 1, length: 2) { Array($0) }, [3, 4])
        XCTAssertEqual(other.withBytes(from: 3, length: 100) { Array($0) }, [5])
        XCTAssertEqual(other.withBytes(from: 9, length: 1) { Array($0) }, [])
        other.removeFirst(100)
        XCTAssertTrue(other.isEmpty)
    }
}
