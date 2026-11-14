import XCTest
@testable import VMNetCore

/// The guest is not trusted: whatever it puts on the wire arrives in Lumen's own process, where a
/// trap is the end of the app and of every other profile. So frames that are cut short, grown,
/// or have any byte changed — and plain noise — are run through everything that reads them. The
/// tests pass when nothing traps and the bounds that are promised hold.
/// Frames a guest might send, whole and damaged.
enum HostileFrames {
    static func valid() -> [[UInt8]] {
        let remote = VMNetIPv4(string: "198.18.0.1")!
        let arp = ARPPacket(operation: ARPPacket.request, senderMAC: Wire.guestMAC, senderAddress: Wire.guest,
                            targetMAC: VMNetMAC(raw: 0), targetAddress: Wire.gateway).frame(destination: .broadcast, source: Wire.guestMAC)
        let ping = [UInt8](repeating: 0x55, count: 56).withUnsafeBytes { bytes in
            FrameBuilder.icmp(destinationMAC: Wire.gatewayMAC, sourceMAC: Wire.guestMAC, source: Wire.guest, destination: Wire.gateway,
                              type: ICMPMessage.echoRequest, code: 0, rest: 1, payload: bytes, identification: 1)
        }
        return [
            arp,
            ping,
            Wire.udp(from: 68, to: .broadcast, 67, payload: Wire.dhcp(type: 1), source: .unspecified, destinationMAC: .broadcast),
            Wire.udp(from: 68, to: .broadcast, 67, payload: Wire.dhcp(type: 3, requested: Wire.guest, server: Wire.gateway), source: .unspecified, destinationMAC: .broadcast),
            Wire.udp(from: 40_000, to: Wire.gateway, 53, payload: Wire.dnsQuery("www.example.com", withOPT: true)),
            Wire.udp(from: 40_000, to: VMNetIPv4(string: "8.8.8.8")!, 53, payload: Wire.dnsQuery("a.b.c.d.example.org", type: 28)),
            Wire.udp(from: 40_000, to: VMNetIPv4(string: "8.8.8.8")!, 443, payload: [UInt8](repeating: 1, count: 1200)),
            Wire.tcp(from: 50_000, to: remote, 443, sequence: 1_000, flags: [.syn], options: Wire.synOptions()),
            Wire.tcp(from: 50_000, to: remote, 443, sequence: 1_001, acknowledgement: 5_001, flags: [.ack]),
            Wire.tcp(from: 50_000, to: remote, 443, sequence: 1_001, acknowledgement: 5_001, flags: [.ack, .psh], payload: [UInt8](repeating: 7, count: 900)),
            Wire.tcp(from: 50_000, to: remote, 443, sequence: 3_001, acknowledgement: 5_001, flags: [.ack], payload: [UInt8](repeating: 8, count: 1460)),
            Wire.tcp(from: 50_000, to: remote, 443, sequence: 1_901, acknowledgement: 5_001, flags: [.ack, .fin]),
            Wire.tcp(from: 50_000, to: remote, 443, sequence: 1_001, acknowledgement: 5_001, flags: [.rst]),
        ]
    }

    /// A frame with something wrong with it: bytes changed, the end cut off, noise appended.
    static func damaged(_ frame: [UInt8], _ random: inout TestRandom) -> [UInt8] {
        var bytes = frame
        switch random.next() % 6 {
        case 0:
            bytes = Array(bytes.prefix(Int(random.next() % UInt64(bytes.count + 1))))
        case 1:
            bytes += random.bytes(Int(random.next() % 64))
        case 2:
            // The lengths and offsets that parsers trust most: the IPv4 and TCP header bytes.
            for _ in 0..<(1 + random.next() % 3) where bytes.count > 14 {
                bytes[14 + Int(random.next() % UInt64(min(bytes.count - 14, 44)))] = UInt8(truncatingIfNeeded: random.next())
            }
            fixIPChecksum(&bytes)
        default:
            for _ in 0..<(1 + random.next() % 8) where !bytes.isEmpty {
                bytes[Int(random.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: random.next())
            }
            if random.next() % 2 == 0 { fixIPChecksum(&bytes) }
        }
        return bytes
    }

    /// Makes the IPv4 header's checksum right again, so that a changed header is read at all.
    static func fixIPChecksum(_ frame: inout [UInt8]) {
        guard frame.count >= 34, frame[12] == 0x08, frame[13] == 0x00 else { return }
        let length = min(Int(frame[14] & 0x0F) * 4, frame.count - 14)
        guard length >= 20 else { return }
        frame[24] = 0
        frame[25] = 0
        let checksum = InternetChecksum.checksum(Array(frame[14..<(14 + length)]))
        frame[24] = UInt8(checksum >> 8)
        frame[25] = UInt8(checksum & 0xFF)
    }

    /// The next frame of a hostile guest: noise, a good frame, or — mostly — a damaged one.
    static func next(from frames: [[UInt8]], _ random: inout TestRandom) -> [UInt8] {
        switch random.next() % 10 {
        case 0: return random.bytes(Int(random.next() % 120))
        case 1: return frames[Int(random.next() % UInt64(frames.count))]
        default: return damaged(frames[Int(random.next() % UInt64(frames.count))], &random)
        }
    }
}

final class HostileInputTests: XCTestCase {
    func testDamagedFramesAndNoiseTrapNothing() {
        var random = TestRandom(seed: 2026)
        var responder = LinkResponder(configuration: Wire.configuration(blocked: ["blocked.example"]), dnsPoolCapacity: 50)
        var counters = VMNetCounters()
        let sink = CollectingSink()
        let scratch = FrameScratch()
        var tuning = TCPConnection.Tuning()
        tuning.receiveBufferLimit = 8_192
        tuning.sendBufferLimit = 8_192
        tuning.earlySegmentLimit = 16
        var connections: [TCPConnection] = []
        func freshConnections(_ now: Double) {
            // One connection in each state a segment can meet.
            connections = (0..<4).map { index in
                let syn = Wire.tcp(from: 50_000, to: VMNetIPv4(string: "198.18.0.1")!, 443, sequence: 1_000, flags: [.syn], options: Wire.synOptions())
                let key = FlowKey(guestAddress: Wire.guest.value, guestPort: 50_000, remoteAddress: 0xC612_0001, remotePort: 443)
                let connection = Wire.withSegment(syn) { _, segment in
                    TCPConnection(key: key, guestMAC: Wire.guestMAC, gatewayMAC: Wire.gatewayMAC, mtu: 1500, syn: segment, now: now,
                                  tuning: tuning, scratch: scratch, sink: sink, initialSequence: 5_000)
                }
                if index >= 1 { connection.tunnelEstablished(now: now) }
                if index >= 2 {
                    let ack = Wire.tcp(from: 50_000, to: VMNetIPv4(string: "198.18.0.1")!, 443, sequence: 1_001, acknowledgement: 5_001, flags: [.ack], window: 64)
                    Wire.withSegment(ack) { _, segment in connection.receive(segment, now: now) }
                }
                if index == 3 {
                    [UInt8](repeating: 9, count: 6_000).withUnsafeBytes { connection.upstreamData($0, now: now) }
                    connection.upstreamFinished(now: now)
                }
                return connection
            }
        }

        let frames = HostileFrames.valid()
        var now = 1.0
        freshConnections(now)
        var replies = 0, segments = 0
        for round in 0..<120_000 {
            now += 0.001
            let frame = HostileFrames.next(from: frames, &random)
            frame.withUnsafeBytes { bytes in
                switch responder.handle(bytes, now: now, counters: &counters) {
                case .ignore:
                    break
                case .reply(let reply):
                    replies += 1
                    // What the stack sends back is itself well formed.
                    reply.withUnsafeBytes { answer in
                        let ethernet = EthernetFrame(answer)
                        XCTAssertNotNil(ethernet)
                        if let ethernet, ethernet.etherType == EtherType.ipv4 {
                            XCTAssertNotNil(IPv4Packet(ethernet.payload), "a reply with a bad IPv4 header")
                        }
                    }
                    XCTAssertLessThanOrEqual(reply.count, 65_535 + 14)
                case .tcp(_, let packet, let segment):
                    segments += 1
                    for connection in connections {
                        connection.receive(segment, now: now)
                        connection.flush(now: now)
                        connection.timerFired(now: now)
                        XCTAssertLessThanOrEqual(connection.upstreamBacklog, 8_192)
                        XCTAssertLessThanOrEqual(connection.earlySegmentCount, 16)
                        if random.next() % 4 == 0 { connection.upstreamConsumed(connection.upstreamBacklog, now: now) }
                    }
                    _ = TCPConnection.resetFrame(answering: segment, from: packet.destination, to: packet.source,
                                                 guestMAC: Wire.guestMAC, gatewayMAC: Wire.gatewayMAC, scratch: scratch)
                }
            }
            // Every frame the connections sent is a well-formed TCP segment.
            for sent in sink.take() {
                let seen = Wire.seenTCP(sent)
                XCTAssertNotNil(seen)
                XCTAssertEqual(seen?.checksumValid, true)
                XCTAssertLessThanOrEqual(sent.count, 1514)
            }
            if round % 500 == 499 { freshConnections(now) }
        }
        XCTAssertGreaterThan(replies, 1_000)
        XCTAssertGreaterThan(segments, 1_000)
        XCTAssertLessThanOrEqual(responder.dns.pool.count, 50)
    }

    func testNoiseForTheDNSResponderAndTheDHCPServer() {
        var random = TestRandom(seed: 7)
        var responder = DNSResponder(blockedHostSuffixes: ["blocked.example"], poolCapacity: 20)
        let server = DHCPServer(guestMAC: Wire.guestMAC, guestAddress: Wire.guest, gatewayAddress: Wire.gateway, prefixLength: 24, mtu: 1500)
        let query = Wire.dnsQuery("www.example.com", withOPT: true)
        let discover = Wire.dhcp(type: 1)
        for _ in 0..<40_000 {
            var message: [UInt8]
            switch random.next() % 4 {
            case 0:
                message = random.bytes(Int(random.next() % 600))
            case 1:
                message = query
                for _ in 0..<(1 + random.next() % 4) { message[Int(random.next() % UInt64(message.count))] = UInt8(truncatingIfNeeded: random.next()) }
                message = Array(message.prefix(Int(random.next() % UInt64(message.count + 8))))
            case 2:
                // A name of random labels, some of them not text.
                message = Array(query[0..<12])
                for _ in 0..<(random.next() % 6) {
                    let label = random.bytes(Int(random.next() % 70))
                    message.append(UInt8(truncatingIfNeeded: label.count + Int(random.next() % 3) - 1))
                    message += label
                }
                message += [0, 0, UInt8(random.next() % 70), 0, 1]
            default:
                message = discover
                for _ in 0..<(1 + random.next() % 6) { message[Int(random.next() % UInt64(message.count))] = UInt8(truncatingIfNeeded: random.next()) }
                message = Array(message.prefix(Int(random.next() % UInt64(message.count + 8))))
            }
            message.withUnsafeBytes { bytes in
                let (reply, outcome) = responder.respond(to: bytes)
                if let reply {
                    XCTAssertNotEqual(outcome, .dropped)
                    // An answer is the question and at most one record: never much longer than what was asked.
                    XCTAssertLessThanOrEqual(reply.count, bytes.count + 16 + 11)
                    XCTAssertEqual(reply[2] & 0x80, 0x80)
                } else {
                    XCTAssertEqual(outcome, .dropped)
                }
                if let message = DHCPServer.Message(bytes), let reply = server.reply(to: message) {
                    XCTAssertGreaterThanOrEqual(reply.count, 300)
                    XCTAssertEqual(reply[0], 2)
                }
            }
        }
        XCTAssertLessThanOrEqual(responder.pool.count, 20)
    }

    func testNoiseFromAProxy() {
        var random = TestRandom(seed: 11)
        let targets: [ProxyTarget] = [.name("example.com", port: 443), .address(VMNetIPv4(string: "1.2.3.4")!, port: 80)]
        let credentials = ProxyCredentials(username: "user", password: "pass")
        for round in 0..<6_000 {
            var handshakes: [ProxyHandshake] = [
                SOCKS5Handshake(target: targets[round % 2], credentials: round % 3 == 0 ? credentials : nil),
                HTTPConnectHandshake(target: targets[round % 2], credentials: round % 3 == 0 ? credentials : nil),
            ]
            for index in handshakes.indices {
                _ = handshakes[index].begin()
                var total = 0
                for _ in 0..<40 {
                    // Mostly bytes that begin like the protocol's own, so that the later stages are reached.
                    var bytes = random.bytes(Int(random.next() % 40))
                    if !bytes.isEmpty && random.next() % 2 == 0 { bytes[0] = index == 0 ? 5 : 0x48 }
                    if bytes.count > 1 && random.next() % 2 == 0 { bytes[1] = UInt8(random.next() % 3) }
                    total += bytes.count
                    let step = handshakes[index].receive(bytes)
                    if case .established(let leftover) = step {
                        XCTAssertLessThanOrEqual(leftover.count, total)
                        break
                    }
                    if case .failed = step { break }
                }
            }
        }
    }
}
