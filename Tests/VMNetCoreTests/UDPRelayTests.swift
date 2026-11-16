#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// The guest's UDP through the proxy's relay, as data: UDP ASSOCIATE byte by byte, the header of
/// every relayed datagram, where the relay is, which destination an answer belongs to, and what
/// the link layer hands over at all. The same over real sockets is in UDPRelayLoopTests.
final class UDPRelayTests: XCTestCase {
    // MARK: - UDP ASSOCIATE (RFC 1928 §4, §6, §7; RFC 1929)

    func testUDPAssociateWithoutASignIn() {
        var handshake = SOCKS5Handshake.udpAssociate(credentials: nil)
        XCTAssertEqual(handshake.begin(), .send([5, 1, 0]))
        // CMD 3; the address the datagrams will come from is not known yet: all zeros.
        XCTAssertEqual(handshake.receive([5, 0]), .send([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(handshake.bound)
        XCTAssertEqual(handshake.receive([5, 0, 0, 1, 203, 0, 113, 5, 0x1F, 0x90]), .established(leftover: []))
        XCTAssertEqual(handshake.bound?.address, .ipv4(0xCB00_7105))
        XCTAssertEqual(handshake.bound?.port, 8080)
    }

    func testUDPAssociateWithAUserNameAndPassword() {
        var handshake = SOCKS5Handshake.udpAssociate(credentials: ProxyCredentials(username: "user", password: "pass"))
        XCTAssertEqual(handshake.begin(), .send([5, 2, 0, 2]))
        XCTAssertEqual(handshake.receive([5, 2]), .send([1, 4] + Array("user".utf8) + [4] + Array("pass".utf8)))
        XCTAssertEqual(handshake.receive([1, 0]), .send([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]))
        // The relay named as IPv6, in pieces.
        let reply: [UInt8] = [5, 0, 0, 4] + [0x20, 0x01, 0x48, 0x60] + [UInt8](repeating: 0, count: 11) + [9] + [0x30, 0x39]
        for byte in reply.dropLast() { XCTAssertEqual(handshake.receive([byte]), .needMore) }
        XCTAssertEqual(handshake.receive([reply.last!]), .established(leftover: []))
        XCTAssertEqual(handshake.bound?.address, .ipv6([0x20, 0x01, 0x48, 0x60] + [UInt8](repeating: 0, count: 11) + [9]))
        XCTAssertEqual(handshake.bound?.port, 12_345)
    }

    func testUDPAssociateRefusals() {
        // 7: command not supported — the proxy has no UDP; 2: not allowed by its rules.
        for code: UInt8 in [7, 2, 1] {
            var handshake = SOCKS5Handshake.udpAssociate(credentials: nil)
            _ = handshake.begin()
            _ = handshake.receive([5, 0])
            XCTAssertEqual(handshake.receive([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), .failed(.refused(Int(code))))
            XCTAssertNil(handshake.bound)
        }
        // A sign-in that is refused, an answer that is not SOCKS5, an address type that does not exist.
        var handshake = SOCKS5Handshake.udpAssociate(credentials: ProxyCredentials(username: "user", password: "wrong"))
        _ = handshake.begin()
        _ = handshake.receive([5, 2])
        XCTAssertEqual(handshake.receive([1, 1]), .failed(.authenticationRejected))
        handshake = SOCKS5Handshake.udpAssociate(credentials: nil)
        _ = handshake.begin()
        XCTAssertEqual(handshake.receive([4, 0]), .failed(.malformedReply))
        handshake = SOCKS5Handshake.udpAssociate(credentials: nil)
        _ = handshake.begin()
        _ = handshake.receive([5, 0])
        XCTAssertEqual(handshake.receive([5, 0, 0, 9, 1, 2, 3, 4, 0, 1]), .failed(.malformedReply))
    }

    func testCONNECTKeepsItsBoundAddressToo() {
        var handshake = SOCKS5Handshake(target: .name("example.com", port: 443), credentials: nil)
        _ = handshake.begin()
        _ = handshake.receive([5, 0])
        XCTAssertEqual(handshake.receive([5, 0, 0, 3, 4] + Array("host".utf8) + [0, 80]), .established(leftover: []))
        XCTAssertEqual(handshake.bound?.address, .name("host"))
    }

    // MARK: - The header of a relayed datagram

    func testAGuestsDatagramToANameGoesAsTheName() {
        let payload: [UInt8] = [0xC3, 0, 0, 0, 1]
        let wrapped = payload.withUnsafeBytes { SOCKSDatagram.wrap($0, to: .name("quic.example", port: 443)) }
        XCTAssertEqual(wrapped, [0, 0, 0, 3, 12] + Array("quic.example".utf8) + [0x01, 0xBB] + payload)
    }

    func testAGuestsDatagramToAnAddressGoesAsTheAddress() {
        let wrapped = [UInt8]().withUnsafeBytes { SOCKSDatagram.wrap($0, to: .address(VMNetIPv4(string: "203.0.113.9")!, port: 3478)) }
        XCTAssertEqual(wrapped, [0, 0, 0, 1, 203, 0, 113, 9, 0x0D, 0x96])
    }

    func testANameSOCKS5CannotCarryIsNotWrapped() {
        XCTAssertNil([1].withUnsafeBytes { SOCKSDatagram.wrap($0, to: .name(String(repeating: "a", count: 256), port: 1)) })
        XCTAssertNil([1].withUnsafeBytes { SOCKSDatagram.wrap($0, to: .name("", port: 1)) })
    }

    func testAnswersFromTheRelayAreRead() {
        func unwrap(_ bytes: [UInt8]) -> (SOCKSAddress, UInt16, [UInt8])? {
            bytes.withUnsafeBytes { raw in
                SOCKSDatagram.unwrap(raw).map { ($0.source, $0.port, Array(raw[$0.payloadOffset...])) }
            }
        }
        var read = unwrap([0, 0, 0, 1, 203, 0, 113, 9, 0x0D, 0x96, 7, 8])
        XCTAssertEqual(read?.0, .ipv4(0xCB00_7109))
        XCTAssertEqual(read?.1, 3478)
        XCTAssertEqual(read?.2, [7, 8])
        // A name, as some proxies answer; and an empty payload.
        read = unwrap([0, 0, 0, 3, 4] + Array("host".utf8) + [0, 53])
        XCTAssertEqual(read?.0, .name("host"))
        XCTAssertEqual(read?.2, [])
        // IPv6, and an IPv4 address written as IPv6.
        read = unwrap([0, 0, 0, 4] + [0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 12) + [0, 1, 9])
        XCTAssertEqual(read?.0, .ipv6([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 12)))
        read = unwrap([0, 0, 0, 4] + [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 203, 0, 113, 9] + [0, 1])
        XCTAssertEqual(read?.0, .ipv4(0xCB00_7109))
    }

    func testFragmentsAndMalformedAnswersAreNotRead() {
        let good: [UInt8] = [0, 0, 0, 1, 203, 0, 113, 9, 0x0D, 0x96, 1]
        func reads(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBytes { SOCKSDatagram.unwrap($0) != nil } }
        XCTAssertTrue(reads(good))
        // FRAG ≠ 0: a fragment, which is not reassembled here.
        for frag: UInt8 in [1, 0x7F, 0x80, 0xFF] {
            var fragment = good
            fragment[2] = frag
            XCTAssertFalse(reads(fragment), "FRAG \(frag)")
        }
        // RSV that is not zero, an address type that does not exist, every truncation, an empty name.
        var reserved = good
        reserved[0] = 1
        XCTAssertFalse(reads(reserved))
        var unknown = good
        unknown[3] = 2
        XCTAssertFalse(reads(unknown))
        for length in 0..<10 { XCTAssertFalse(reads(Array(good.prefix(length))), "cut at \(length)") }
        XCTAssertFalse(reads([0, 0, 0, 3, 0, 0, 53]))
        XCTAssertFalse(reads([0, 0, 0, 3, 200, 1, 2]))
        XCTAssertFalse(reads([0, 0, 0, 4] + [UInt8](repeating: 1, count: 17)))
    }

    func testNoiseFromTheRelayIsNeverATrap() {
        var random = TestRandom(seed: 99)
        for length in 0..<300 {
            let noise = random.bytes(length)
            _ = noise.withUnsafeBytes { SOCKSDatagram.unwrap($0) }
            var framed = noise
            if framed.count >= 4 { framed[0] = 0; framed[1] = 0; framed[2] = 0; framed[3] = [1, 3, 4][length % 3] }
            _ = framed.withUnsafeBytes { SOCKSDatagram.unwrap($0) }
        }
    }

    // MARK: - Where the relay is

    private let proxy = SocketEndpoint.ipv4(0xCB00_7101, port: 1080)

    func testTheRelayIsTheProxysOwnAddressWhenItSaysSo() {
        // 0.0.0.0: "my own address" — the one the TCP connection reached.
        let unspecified = UDPRelayRules.relayEndpoint(bound: .ipv4(0), port: 40_000, proxy: proxy)
        XCTAssertEqual(unspecified?.address, .ipv4(0xCB00_7101))
        XCTAssertEqual(unspecified?.port, 40_000)
        XCTAssertEqual(UDPRelayRules.relayEndpoint(bound: .ipv6([UInt8](repeating: 0, count: 16)), port: 1, proxy: proxy)?.address, .ipv4(0xCB00_7101))
        // Its own address named.
        XCTAssertEqual(UDPRelayRules.relayEndpoint(bound: .ipv4(0xCB00_7101), port: 2, proxy: proxy)?.address, .ipv4(0xCB00_7101))
    }

    func testAPublicRelayIsTakenAsNamedAndAPrivateOneIsTheProxysOwn() {
        let elsewhere = UDPRelayRules.relayEndpoint(bound: .ipv4(0xC633_6407), port: 5000, proxy: proxy)
        XCTAssertEqual(elsewhere?.address, .ipv4(0xC633_6407))
        XCTAssertEqual(elsewhere?.port, 5000)
        // A proxy behind NAT names its address inside its own network; nothing goes to a local
        // network on a proxy's word.
        for local in ["10.0.0.5", "172.17.0.2", "192.168.0.1", "127.0.0.1", "169.254.169.254", "100.64.1.1", "224.0.0.1", "255.255.255.255"] {
            let endpoint = UDPRelayRules.relayEndpoint(bound: .ipv4(VMNetIPv4(string: local)!.value), port: 5000, proxy: proxy)
            XCTAssertEqual(endpoint?.address, .ipv4(0xCB00_7101), local)
            XCTAssertEqual(endpoint?.port, 5000, local)
        }
        // IPv6: a public one as named; loopback, link-local, unique-local, documentation: the proxy's own.
        // Sixteen bytes: the head given, zeros, then the tail given (kept simple for the type checker).
        func v6(_ head: [UInt8], _ tail: [UInt8] = []) -> [UInt8] {
            var bytes = head
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - head.count - tail.count))
            bytes.append(contentsOf: tail)
            return bytes
        }
        let public6 = v6([0x26, 0x06, 0x47, 0], [1])
        XCTAssertEqual(UDPRelayRules.relayEndpoint(bound: .ipv6(public6), port: 7, proxy: proxy)?.address, .ipv6(public6))
        let locals: [[UInt8]] = [v6([], [1]), v6([0xFE, 0x80], [1]), v6([0xFD, 0x12]), v6([0x20, 0x01, 0x0D, 0xB8]), v6([0xFF, 0x02], [1])]
        for local in locals {
            XCTAssertEqual(UDPRelayRules.relayEndpoint(bound: .ipv6(local), port: 7, proxy: proxy)?.address, .ipv4(0xCB00_7101))
        }
    }

    func testARelayNamedByNameOrOnPortZeroIsNoRelay() {
        XCTAssertNil(UDPRelayRules.relayEndpoint(bound: .name("relay.example"), port: 5000, proxy: proxy))
        XCTAssertNil(UDPRelayRules.relayEndpoint(bound: .ipv4(0), port: 0, proxy: proxy))
    }

    func testEndpointsRoundTrip() {
        let v4 = SocketEndpoint.ipv4(0x7F00_0001, port: 65_535)
        XCTAssertEqual(v4.family, AF_INET)
        XCTAssertEqual(v4.address, .ipv4(0x7F00_0001))
        XCTAssertEqual(v4.port, 65_535)
        XCTAssertEqual(v4.withPort(1).port, 1)
        XCTAssertEqual(v4.withPort(1).address, .ipv4(0x7F00_0001))
        let bytes: [UInt8] = [0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11]
        let v6 = SocketEndpoint.ipv6(bytes, port: 443)
        XCTAssertEqual(v6.family, AF_INET6)
        XCTAssertEqual(v6.address, .ipv6(bytes))
        XCTAssertEqual(v6.withPort(8443).port, 8443)
    }

    // MARK: - Which destination an answer is from

    private func association() -> UDPAssociation {
        UDPAssociation(key: UDPKey(guestAddress: Wire.guest.value, guestPort: 50_000), guestMAC: Wire.guestMAC, credentials: nil,
                       now: 0, setupTimeout: 10)
    }

    private let fake = VMNetIPv4(string: "198.18.0.7")!
    private let otherFake = VMNetIPv4(string: "198.18.0.8")!
    private let literal = VMNetIPv4(string: "203.0.113.9")!

    func testAnAnswerFromAnAddressTheGuestSentToIsFromThatAddress() {
        let relay = association()
        XCTAssertTrue(relay.noteDestination(literal, port: 3478, target: .address(literal, port: 3478), host: "203.0.113.9", now: 1))
        XCTAssertFalse(relay.noteDestination(literal, port: 3478, target: .address(literal, port: 3478), host: "203.0.113.9", now: 2))
        let found = relay.destination(answering: .ipv4(literal.value), port: 3478, now: 3)
        XCTAssertEqual(found?.guestAddress, literal)
        XCTAssertEqual(found?.port, 3478)
        // The same address on another port, or another address: the guest sent nothing there.
        XCTAssertNil(relay.destination(answering: .ipv4(literal.value), port: 3479, now: 3))
        XCTAssertNil(relay.destination(answering: .ipv4(0xCB00_710A), port: 3478, now: 3))
    }

    func testANamesFirstAnswerTeachesWhereItsAnswersComeFrom() {
        let relay = association()
        relay.noteDestination(fake, port: 443, target: .name("quic.example", port: 443), host: "quic.example", now: 1)
        // The proxy resolved the name; its answers come from the address it chose.
        let first = relay.destination(answering: .ipv4(0x5DB8_D822), port: 443, now: 2)
        XCTAssertEqual(first?.guestAddress, fake)
        XCTAssertEqual(first?.answeredFrom, .ipv4(0x5DB8_D822))
        XCTAssertEqual(relay.destination(answering: .ipv4(0x5DB8_D822), port: 443, now: 3)?.guestAddress, fake)
        // Once it has answered from there, an answer from another address is from nobody.
        XCTAssertNil(relay.destination(answering: .ipv4(0x5DB8_D823), port: 443, now: 4))
        // An answer that names the name (some proxies do) is from it as well.
        XCTAssertEqual(relay.destination(answering: .name("QUIC.example."), port: 443, now: 5)?.guestAddress, fake)
    }

    func testTwoNamesOnOnePortAreToldApartByWhereTheyAnswerFrom() {
        let relay = association()
        relay.noteDestination(fake, port: 3478, target: .name("stun1.example", port: 3478), host: "stun1.example", now: 1)
        relay.noteDestination(otherFake, port: 3478, target: .name("stun2.example", port: 3478), host: "stun2.example", now: 2)
        // The first answer goes to the name sent to last that has not answered yet, and the next
        // answer from another address to the other one.
        XCTAssertEqual(relay.destination(answering: .ipv4(0x0A0B_0C0D), port: 3478, now: 3)?.guestAddress, otherFake)
        XCTAssertEqual(relay.destination(answering: .ipv4(0x0A0B_0C0E), port: 3478, now: 4)?.guestAddress, fake)
        XCTAssertEqual(relay.destination(answering: .ipv4(0x0A0B_0C0D), port: 3478, now: 5)?.guestAddress, otherFake)
        XCTAssertNil(relay.destination(answering: .ipv4(0x0A0B_0C0F), port: 3478, now: 6))
    }

    /// WebRTC asks several STUN servers from one socket, often on one port: the first answer is
    /// the one whose request it names, whichever was sent to last.
    func testTwoSTUNServersOnOnePortAreToldApartByTheRequestTheirAnswerNames() {
        let relay = association()
        func request(_ id: UInt8) -> [UInt8] { [0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42] + [UInt8](repeating: id, count: 12) }
        func answer(_ id: UInt8) -> [UInt8] { [1, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42] + [UInt8](repeating: id, count: 12) }
        _ = request(1).withUnsafeBytes {
            relay.noteDestination(fake, port: 19_302, target: .name("stun.example", port: 19_302), host: "stun.example", now: 1, payload: $0)
        }
        _ = request(2).withUnsafeBytes {
            relay.noteDestination(otherFake, port: 19_302, target: .name("stun1.example", port: 19_302), host: "stun1.example", now: 2, payload: $0)
        }
        // The server sent to first answers first.
        let first = answer(1).withUnsafeBytes { relay.destination(answering: .ipv4(0x4A7D_0001), port: 19_302, now: 3, payload: $0) }
        XCTAssertEqual(first?.guestAddress, fake)
        let second = answer(2).withUnsafeBytes { relay.destination(answering: .ipv4(0x4A7D_0002), port: 19_302, now: 4, payload: $0) }
        XCTAssertEqual(second?.guestAddress, otherFake)
        // From then on by where they answer from, whatever they carry.
        XCTAssertEqual(relay.destination(answering: .ipv4(0x4A7D_0001), port: 19_302, now: 5)?.guestAddress, fake)
        XCTAssertEqual(relay.destination(answering: .ipv4(0x4A7D_0002), port: 19_302, now: 6)?.guestAddress, otherFake)
        // An answer to a request nobody sent, from a third address: nobody's.
        XCTAssertNil(answer(9).withUnsafeBytes { relay.destination(answering: .ipv4(0x4A7D_0003), port: 19_302, now: 7, payload: $0) })
        // What is not STUN has no transaction.
        XCTAssertNil([UInt8](repeating: 0, count: 20).withUnsafeBytes { UDPAssociation.stunTransaction($0) })
        XCTAssertNil(Array(request(1).prefix(19)).withUnsafeBytes { UDPAssociation.stunTransaction($0) })
        XCTAssertEqual(request(7).withUnsafeBytes { UDPAssociation.stunTransaction($0) }, [UInt8](repeating: 7, count: 12))
    }

    func testAFakeAddressGivenToAnotherNameForgetsWhatWasLearned() {
        let relay = association()
        relay.noteDestination(fake, port: 443, target: .name("old.example", port: 443), host: "old.example", now: 1)
        _ = relay.destination(answering: .ipv4(0x5DB8_D822), port: 443, now: 2)
        relay.noteDestination(fake, port: 443, target: .name("new.example", port: 443), host: "new.example", now: 3)
        XCTAssertNil(relay.destinations.first?.answeredFrom)
        XCTAssertEqual(relay.destination(answering: .ipv4(0x0102_0304), port: 443, now: 4)?.host, "new.example")
    }

    func testABlockedNamesAnswersAreNotShownAndTheDestinationsAreBounded() {
        let relay = association()
        relay.noteDestination(fake, port: 443, target: .name("ads.example", port: 443), host: "ads.example", now: 1)
        relay.noteDestination(literal, port: 443, target: .address(literal, port: 443), host: "203.0.113.9", now: 1)
        relay.forgetDestinations { $0.hasSuffix("ads.example") }
        XCTAssertEqual(relay.destinations.count, 1)
        XCTAssertNil(relay.destination(answering: .name("ads.example"), port: 443, now: 2))

        for index in 0..<(UDPAssociation.destinationLimit + 10) {
            let address = VMNetIPv4(0xCB00_7100 + UInt32(index % 200))
            relay.noteDestination(address, port: UInt16(1000 + index), target: .address(address, port: UInt16(1000 + index)),
                                  host: address.string, now: Double(10 + index))
        }
        XCTAssertEqual(relay.destinations.count, UDPAssociation.destinationLimit)
        // The ones unused the longest went first.
        XCTAssertNil(relay.destinations.first { $0.port == 1000 })
        XCTAssertNotNil(relay.destinations.first { $0.port == UInt16(1000 + UDPAssociation.destinationLimit + 9) })
    }

    func testWhatWaitsForAnAssociationIsBounded() {
        let relay = association()
        func waiting(_ size: Int) -> UDPAssociation.Waiting {
            UDPAssociation.Waiting(datagram: [UInt8](repeating: 1, count: size), payloadLength: size, host: "h", quote: [], destination: literal)
        }
        for _ in 0..<UDPAssociation.waitingLimit { XCTAssertTrue(relay.hold(waiting(10))) }
        XCTAssertFalse(relay.hold(waiting(10)))
        XCTAssertEqual(relay.takeWaiting().count, UDPAssociation.waitingLimit)
        XCTAssertTrue(relay.takeWaiting().isEmpty)
        XCTAssertTrue(relay.hold(waiting(UDPAssociation.waitingBytesLimit - 100)))
        XCTAssertFalse(relay.hold(waiting(200)))
    }

    // MARK: - What the link layer hands over

    private func relaying() -> LinkResponder {
        var configuration = Wire.configuration(upstream: .socks5(host: "127.0.0.1", port: 1080, username: nil, password: nil))
        configuration.relaysUDP = true
        return LinkResponder(configuration: configuration)
    }

    private func verdict(_ responder: inout LinkResponder, _ frame: [UInt8], counters: inout VMNetCounters) -> String {
        frame.withUnsafeBytes { bytes -> String in
            switch responder.handle(bytes, now: 1, counters: &counters) {
            case .ignore: return "ignore"
            case .reply: return "reply"
            case .tcp: return "tcp"
            case .udp(_, let packet, let datagram): return "udp \(packet.destination.string):\(datagram.destinationPort)"
            }
        }
    }

    func testUnicastUDPIsHandedOverOnlyWhereItIsRelayed() {
        var responder = relaying()
        var counters = VMNetCounters()
        let quic = Wire.udp(from: 50_000, to: literal, 443, payload: [1, 2, 3])
        XCTAssertEqual(verdict(&responder, quic, counters: &counters), "udp 203.0.113.9:443")
        XCTAssertEqual(counters.datagramsDropped, 0)
        // Without the relay: "port unreachable", as before.
        var plain = LinkResponder(configuration: Wire.configuration())
        XCTAssertEqual(verdict(&plain, quic, counters: &counters), "reply")
        XCTAssertEqual(counters.datagramsDropped, 1)
    }

    func testDNSAndTheTimeAreAnsweredHereAndNeverHandedOver() {
        var responder = relaying()
        var counters = VMNetCounters()
        // A query to any resolver: the stack's own answer.
        let query = Wire.udp(from: 50_001, to: VMNetIPv4(string: "8.8.8.8")!, 53, payload: Wire.dnsQuery("example.com"))
        XCTAssertEqual(verdict(&responder, query, counters: &counters), "reply")
        XCTAssertEqual(counters.dnsQueries, 1)
        // Not a query at all, to port 53: not answered, and not handed over either.
        XCTAssertEqual(verdict(&responder, Wire.udp(from: 50_002, to: VMNetIPv4(string: "8.8.8.8")!, 53, payload: [1, 2, 3]),
                               counters: &counters), "ignore")
        var ntp = [UInt8](repeating: 0, count: 48)
        ntp[0] = 0x23
        XCTAssertEqual(verdict(&responder, Wire.udp(from: 50_003, to: literal, 123, payload: ntp), counters: &counters), "reply")
        XCTAssertEqual(counters.timeQueries, 1)
        // A malformed question for the time, DHCP's client port, NetBIOS, SSDP, mDNS and LLMNR to
        // a unicast address: "port unreachable", never the relay. (DHCP's server port is the
        // stack's own: what is not a DHCP message there is not answered.)
        XCTAssertEqual(verdict(&responder, Wire.udp(from: 68, to: literal, 67, payload: [9]), counters: &counters), "ignore")
        for port: UInt16 in [123, 68, 137, 138, 1900, 5353, 5355] {
            let frame = Wire.udp(from: 50_004, to: literal, port, payload: [9])
            XCTAssertEqual(verdict(&responder, frame, counters: &counters), "reply", "port \(port)")
        }
        XCTAssertEqual(verdict(&responder, Wire.udp(from: 50_005, to: literal, 0, payload: [9]), counters: &counters), "reply")
    }

    func testBroadcastsAndMulticastAreNeverHandedOver() {
        var responder = relaying()
        var counters = VMNetCounters()
        let multicastMAC = VMNetMAC(string: "01:00:5e:00:00:fb")!
        let frames = [
            Wire.udp(from: 5353, to: VMNetIPv4(0xE000_00FB), 5353, payload: [1], destinationMAC: multicastMAC),
            Wire.udp(from: 40_000, to: VMNetIPv4(0xEFFF_FFFA), 40_000, payload: [1], destinationMAC: multicastMAC),
            Wire.udp(from: 40_000, to: VMNetIPv4(0xE000_00FB), 443, payload: [1]),
            Wire.udp(from: 40_000, to: .broadcast, 443, payload: [1], destinationMAC: .broadcast),
            Wire.udp(from: 40_000, to: VMNetIPv4(0xC0A8_01FF), 443, payload: [1]),
            // A public address, but on a frame for everybody rather than for the gateway.
            Wire.udp(from: 40_000, to: literal, 443, payload: [1], destinationMAC: .broadcast),
            // From an address that is nobody's.
            Wire.udp(from: 40_000, to: literal, 443, payload: [1], source: .unspecified),
        ]
        for frame in frames { XCTAssertEqual(verdict(&responder, frame, counters: &counters), "ignore") }
        XCTAssertEqual(counters.datagramsDropped, UInt64(frames.count))
    }

    func testTheRelayIsOnlyForSOCKS5() {
        XCTAssertTrue(VMNetUpstream.socks5(host: "h", port: 1, username: nil, password: nil).carriesUDP)
        XCTAssertFalse(VMNetUpstream.httpConnect(host: "h", port: 1, username: nil, password: nil).carriesUDP)
        XCTAssertFalse(VMNetUpstream.none.carriesUDP)
        XCTAssertFalse(Wire.configuration().relaysUDP, "off unless the app turns it on")
    }

    func testThePortsNeverRelayedAndTheAssociationsLimit() {
        for port: UInt16 in [0, 53, 67, 68, 123, 137, 138, 1900, 5353, 5355] { XCTAssertFalse(UDPRelayRules.isRelayable(port: port), "\(port)") }
        for port: UInt16 in [443, 3478, 19_302, 853, 8443, 50_000] { XCTAssertTrue(UDPRelayRules.isRelayable(port: port), "\(port)") }
        XCTAssertEqual(NetworkLoop.udpLimit(wanted: 128, connectionLimit: 2048), 128)
        XCTAssertEqual(NetworkLoop.udpLimit(wanted: 128, connectionLimit: 128), 16)
        XCTAssertEqual(NetworkLoop.udpLimit(wanted: 128, connectionLimit: 16), 4)
        XCTAssertEqual(NetworkLoop.udpLimit(wanted: 2, connectionLimit: 2048), 2)
    }
}
