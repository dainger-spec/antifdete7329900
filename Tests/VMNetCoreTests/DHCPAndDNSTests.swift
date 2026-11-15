import XCTest
@testable import VMNetCore

final class DHCPTests: XCTestCase {
    private let server = DHCPServer(guestMAC: Wire.guestMAC, guestAddress: Wire.guest, gatewayAddress: Wire.gateway, prefixLength: 24, mtu: 1500)

    private func reply(_ message: [UInt8]) -> [UInt8]? {
        message.withUnsafeBytes { bytes in
            DHCPServer.Message(bytes).flatMap { server.reply(to: $0) }
        }
    }

    private func address(_ reply: [UInt8], at offset: Int) -> String {
        VMNetIPv4(UInt32(reply[offset]) << 24 | UInt32(reply[offset + 1]) << 16 | UInt32(reply[offset + 2]) << 8 | UInt32(reply[offset + 3])).string
    }

    func testDiscoverIsAnsweredWithAnOffer() throws {
        let offer = try XCTUnwrap(reply(Wire.dhcp(type: 1)))
        XCTAssertGreaterThanOrEqual(offer.count, 300)
        XCTAssertEqual(offer[0], 2)
        XCTAssertEqual(Array(offer[4..<8]), [0xAB, 0xCD, 0x01, 0x23])
        XCTAssertEqual(address(offer, at: 16), "192.168.1.23")
        XCTAssertEqual(Array(offer[28..<34]), Wire.guestMAC.bytes)
        let options = Wire.dhcpOptions(offer)
        XCTAssertEqual(options[53], [2])
        XCTAssertEqual(options[54], [192, 168, 1, 1])
        XCTAssertEqual(options[51], [0, 1, 0x51, 0x80])
        XCTAssertEqual(options[1], [255, 255, 255, 0])
        XCTAssertEqual(options[3], [192, 168, 1, 1])
        XCTAssertEqual(options[6], [192, 168, 1, 1])
        XCTAssertEqual(options[28], [192, 168, 1, 255])
        XCTAssertEqual(options[26], [0x05, 0xDC])
    }

    func testRequestIsAcknowledged() throws {
        let ack = try XCTUnwrap(reply(Wire.dhcp(type: 3, requested: Wire.guest, server: Wire.gateway)))
        XCTAssertEqual(Wire.dhcpOptions(ack)[53], [5])
        XCTAssertEqual(address(ack, at: 16), "192.168.1.23")
        XCTAssertEqual(Wire.dhcpOptions(ack)[51], [0, 1, 0x51, 0x80])
        // A renewal names the address in the header instead of an option.
        let renewal = try XCTUnwrap(reply(Wire.dhcp(type: 3, clientAddress: Wire.guest)))
        XCTAssertEqual(Wire.dhcpOptions(renewal)[53], [5])
        XCTAssertEqual(address(renewal, at: 12), "192.168.1.23")
    }

    func testRequestForAnotherAddressIsRefused() throws {
        let nak = try XCTUnwrap(reply(Wire.dhcp(type: 3, requested: VMNetIPv4(0xC0A8_0150))))
        let options = Wire.dhcpOptions(nak)
        XCTAssertEqual(options[53], [6])
        XCTAssertEqual(address(nak, at: 16), "0.0.0.0")
        XCTAssertNil(options[51])
        XCTAssertNil(options[3])
    }

    func testInformGetsTheSettingsWithoutALease() throws {
        let ack = try XCTUnwrap(reply(Wire.dhcp(type: 8, clientAddress: Wire.guest)))
        let options = Wire.dhcpOptions(ack)
        XCTAssertEqual(options[53], [5])
        XCTAssertEqual(address(ack, at: 16), "0.0.0.0")
        XCTAssertEqual(address(ack, at: 12), "192.168.1.23")
        XCTAssertNil(options[51])
        XCTAssertEqual(options[6], [192, 168, 1, 1])
        XCTAssertEqual(options[1], [255, 255, 255, 0])
    }

    func testOnlyTheGuestsCardIsServed() {
        XCTAssertNil(reply(Wire.dhcp(type: 1, mac: VMNetMAC(string: "52:54:00:99:99:99")!)))
        // A request that chose another server, a release, a decline: no answer.
        XCTAssertNil(reply(Wire.dhcp(type: 3, requested: Wire.guest, server: VMNetIPv4(0xC0A8_0102))))
        XCTAssertNil(reply(Wire.dhcp(type: 7, clientAddress: Wire.guest)))
        XCTAssertNil(reply(Wire.dhcp(type: 4, requested: Wire.guest)))
    }

    func testMalformedMessagesAreNotMessages() {
        var message = Wire.dhcp(type: 1)
        message[236] = 0
        message.withUnsafeBytes { XCTAssertNil(DHCPServer.Message($0)) }
        Array(Wire.dhcp(type: 1)[0..<200]).withUnsafeBytes { XCTAssertNil(DHCPServer.Message($0)) }
        // A reply (op 2) is not a client's message; nor is one without a type.
        message = Wire.dhcp(type: 1)
        message[0] = 2
        message.withUnsafeBytes { XCTAssertNil(DHCPServer.Message($0)) }
        Array(Wire.dhcp(type: 1)[0..<240]).withUnsafeBytes { XCTAssertNil(DHCPServer.Message($0)) }
        // An option whose length runs past the end.
        (Array(Wire.dhcp(type: 1)[0..<240]) + [53, 9, 1]).withUnsafeBytes { XCTAssertNil(DHCPServer.Message($0)) }
    }

    func testAPrefixOtherThan24() throws {
        let other = DHCPServer(guestMAC: Wire.guestMAC, guestAddress: VMNetIPv4(0x0A00_0005), gatewayAddress: VMNetIPv4(0x0A00_0001), prefixLength: 20, mtu: 1400)
        let offer = try XCTUnwrap(Wire.dhcp(type: 1).withUnsafeBytes { DHCPServer.Message($0).flatMap { other.reply(to: $0) } })
        let options = Wire.dhcpOptions(offer)
        XCTAssertEqual(options[1], [255, 255, 240, 0])
        XCTAssertEqual(options[28], [10, 0, 15, 255])
        XCTAssertEqual(options[26], [0x05, 0x78])
    }

    func testTheExchangeOnTheWire() throws {
        // DISCOVER from 0.0.0.0 to everybody; the OFFER comes back to everybody from the gateway.
        var responder = LinkResponder(configuration: Wire.configuration())
        var counters = VMNetCounters()
        let discover = Wire.udp(from: 68, to: .broadcast, 67, payload: Wire.dhcp(type: 1), source: .unspecified, destinationMAC: .broadcast)
        guard case .reply(let frame) = discover.withUnsafeBytes({ responder.handle($0, now: 1, counters: &counters) }) else { return XCTFail("no offer") }
        let offer = try XCTUnwrap(Wire.seenUDP(frame))
        XCTAssertEqual(offer.destinationMAC, .broadcast)
        XCTAssertEqual(offer.sourceMAC, Wire.gatewayMAC)
        XCTAssertEqual(offer.source, Wire.gateway)
        XCTAssertEqual(offer.destination, .broadcast)
        XCTAssertEqual(offer.sourcePort, 67)
        XCTAssertEqual(offer.destinationPort, 68)
        XCTAssertTrue(offer.checksumValid)
        XCTAssertEqual(Wire.dhcpOptions(offer.payload)[53], [2])
        XCTAssertEqual(counters.datagramsDropped, 0)
    }
}

final class DNSResponderTests: XCTestCase {
    private func ask(_ responder: inout DNSResponder, _ query: [UInt8]) -> (reply: [UInt8]?, outcome: DNSResponder.Outcome) {
        query.withUnsafeBytes { responder.respond(to: $0) }
    }

    func testAnAddressQueryGetsAFakeAddress() throws {
        var responder = DNSResponder(blockedHostSuffixes: [])
        let query = Wire.dnsQuery("example.com", id: 0xBEEF)
        let (reply, outcome) = ask(&responder, query)
        XCTAssertEqual(outcome, .answered)
        let bytes = try XCTUnwrap(reply)
        let answer = Wire.dnsAnswer(bytes)
        XCTAssertEqual(answer.id, 0xBEEF)
        XCTAssertEqual(answer.code, 0)
        XCTAssertEqual(answer.answers, 1)
        XCTAssertEqual(answer.address?.string, "198.18.0.1")
        // A response, recursion desired and available.
        XCTAssertEqual(bytes[2], 0x81)
        XCTAssertEqual(bytes[3], 0x80)
        // The question is echoed, then: a pointer to it, A, IN, TTL 60, four bytes.
        XCTAssertEqual(Array(bytes[12..<query.count]), Array(query[12...]))
        XCTAssertEqual(Array(bytes[query.count..<(query.count + 12)]), [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4])
        XCTAssertEqual(responder.name(for: VMNetIPv4(string: "198.18.0.1")!), "example.com")
    }

    func testANameKeepsItsAddressWhateverItsCase() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        let first = Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("Example.COM")).reply!).address
        let other = Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("other.example.com")).reply!).address
        let again = Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("eXAMPLE.com")).reply!).address
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first?.string, "198.18.0.1")
        XCTAssertEqual(other?.string, "198.18.0.2")
        XCTAssertEqual(responder.name(for: first!), "example.com")
        // The question comes back in the case it was asked in.
        let query = Wire.dnsQuery("eXAMPLE.com")
        let reply = ask(&responder, query).reply!
        XCTAssertEqual(Array(reply[12..<query.count]), Array(query[12...]))
    }

    func testEveryOtherRecordTypeIsEmpty() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        // AAAA, HTTPS, SVCB, MX, TXT, PTR, ANY; and an address in another class.
        for type in [28, 65, 64, 15, 16, 12, 255] as [UInt16] {
            let (reply, outcome) = ask(&responder, Wire.dnsQuery("example.com", type: type))
            XCTAssertEqual(outcome, .answered)
            let answer = Wire.dnsAnswer(reply!)
            XCTAssertEqual(answer.code, 0, "type \(type)")
            XCTAssertEqual(answer.answers, 0, "type \(type)")
        }
        let chaos = Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("example.com", questionClass: 3)).reply!)
        XCTAssertEqual(chaos.code, 0)
        XCTAssertEqual(chaos.answers, 0)
        // None of them gave the name an address.
        XCTAssertEqual(responder.pool.count, 0)
    }

    func testBlockedSuffixesDoNotExist() {
        var responder = DNSResponder(blockedHostSuffixes: ["swscan.apple.com", ".Updates.Example.", ""])
        for name in ["swscan.apple.com", "a.b.swscan.apple.com", "SWSCAN.Apple.Com", "updates.example", "x.updates.example"] {
            let (reply, outcome) = ask(&responder, Wire.dnsQuery(name))
            XCTAssertEqual(outcome, .blocked, name)
            XCTAssertEqual(Wire.dnsAnswer(reply!).code, 3, name)
            XCTAssertEqual(Wire.dnsAnswer(reply!).answers, 0, name)
        }
        // Blocked for every type, not only addresses.
        XCTAssertEqual(Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("swscan.apple.com", type: 28)).reply!).code, 3)
        // A name that only ends in the same letters is another name.
        for name in ["notswscan.apple.com", "apple.com", "swscan.apple.com.evil.example"] {
            let (reply, outcome) = ask(&responder, Wire.dnsQuery(name))
            XCTAssertEqual(outcome, .answered, name)
            XCTAssertEqual(Wire.dnsAnswer(reply!).code, 0, name)
        }
    }

    func testNamesOfThisMachineAndTheLocalNetworkDoNotExist() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        for name in ["localhost", "printer", "foo.localhost", "macbook.local", "LOCALHOST"] {
            let (reply, outcome) = ask(&responder, Wire.dnsQuery(name))
            XCTAssertEqual(outcome, .answered, name)
            XCTAssertEqual(Wire.dnsAnswer(reply!).code, 3, name)
        }
        XCTAssertEqual(responder.pool.count, 0)
    }

    /// An address written as a name is no name: a fake address standing for it would take the
    /// guest to that address — this Mac, its local network — by way of whatever resolves it.
    func testAnAddressWrittenAsANameDoesNotExist() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        for name in ["192.168.1.1", "127.0.0.1", "169.254.169.254", "10.0.0.1", "8.8.8.8", "127.1", "0x7f.1", "0x7f.0x1",
                     "0177.0.0.1", "0x7F.0X0.0.1", "10.0x0", "a.b.0x7f", "www.example.123", "1.0x"] {
            let (reply, outcome) = ask(&responder, Wire.dnsQuery(name))
            XCTAssertEqual(outcome, .answered, name)
            XCTAssertEqual(Wire.dnsAnswer(reply!).code, 3, name)
        }
        XCTAssertEqual(responder.pool.count, 0)
        // A number is fine anywhere but last; a top-level domain with digits and letters too.
        for name in ["123.example", "1.2.3.example.com", "0x7f.example", "example.xn--p1ai", "a.b0", "a.0xg"] {
            XCTAssertEqual(Wire.dnsAnswer(ask(&responder, Wire.dnsQuery(name)).reply!).answers, 1, name)
        }
        for label in ["1", "0177", "0x", "0X1f", "4294967295"] { XCTAssertTrue(DNSResponder.isNumeric(label: label), label) }
        for label in ["", "com", "0xg", "1a", "x1", "-1"] { XCTAssertFalse(DNSResponder.isNumeric(label: label), label) }
    }

    func testANameThatIsNotAHostNameDoesNotExist() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        // Labels with a space, a line break, a dot inside a label, bytes that are not text.
        let header: [UInt8] = [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        let com: [UInt8] = [3, 0x63, 0x6F, 0x6D, 0, 0, 1, 0, 1]
        let withLineBreak: [UInt8] = [9] + Array("evil\r\nX: y".utf8.prefix(9))
        XCTAssertEqual(Wire.dnsAnswer(ask(&responder, header + withLineBreak + com).reply!).code, 3)
        let withDot: [UInt8] = [3, 0x61, 0x2E, 0x62]
        XCTAssertEqual(Wire.dnsAnswer(ask(&responder, header + withDot + com).reply!).code, 3)
        let notText: [UInt8] = [2, 0xFF, 0xFE]
        XCTAssertEqual(Wire.dnsAnswer(ask(&responder, header + notText + com).reply!).code, 3)
        XCTAssertEqual(responder.pool.count, 0)
        // Underscores and hyphens are fine.
        XCTAssertEqual(Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("_dmarc.my-site.example")).reply!).answers, 1)
    }

    func testTheRootHasNoAddress() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        let answer = Wire.dnsAnswer(ask(&responder, [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1]).reply!)
        XCTAssertEqual(answer.code, 0)
        XCTAssertEqual(answer.answers, 0)
    }

    func testMalformedQueriesAreDropped() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        let good = Wire.dnsQuery("example.com")
        var cases: [[UInt8]] = []
        cases.append([])
        cases.append(Array(good[0..<11]))
        cases.append(Array(good[0..<(good.count - 1)]))    // the question's class cut short
        cases.append(Array(good[0..<20]))                  // the name cut short
        var response = good
        response[2] |= 0x80                                // a response, not a query
        cases.append(response)
        var none = good
        none[5] = 0                                        // no question
        cases.append(none)
        var two = good
        two[5] = 2                                         // two questions
        cases.append(two)
        var withAnswer = good
        withAnswer[7] = 1                                  // a query that brings an answer
        cases.append(withAnswer)
        cases.append([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1])   // a pointer for a name
        let header: [UInt8] = [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        let tail: [UInt8] = [0, 0, 1, 0, 1]
        cases.append(header + [64] + [UInt8](repeating: 0x61, count: 64) + tail)   // a label of 64
        var long = header
        for _ in 0..<5 {                                   // a name of more than 255 bytes
            long.append(60)
            long += [UInt8](repeating: 0x61, count: 60)
        }
        long += tail
        cases.append(long)
        for (index, query) in cases.enumerated() {
            let (reply, outcome) = ask(&responder, query)
            XCTAssertNil(reply, "case \(index)")
            XCTAssertEqual(outcome, .dropped, "case \(index)")
        }
        XCTAssertEqual(responder.pool.count, 0)
    }

    func testOtherOperationsAreNotImplemented() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        var query = Wire.dnsQuery("example.com")
        query[2] = 0x28   // opcode 5, UPDATE
        let reply = ask(&responder, query).reply!
        XCTAssertEqual(Wire.dnsAnswer(reply).code, 4)
        XCTAssertEqual(reply[2] & 0x78, 0x28)
    }

    func testAnEDNSQueryIsAnsweredWithEDNS() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        let reply = ask(&responder, Wire.dnsQuery("example.com", withOPT: true)).reply!
        let answer = Wire.dnsAnswer(reply)
        XCTAssertEqual(answer.answers, 1)
        XCTAssertEqual(answer.additional, 1)
        XCTAssertEqual(Array(reply.suffix(11)), [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("example.com")).reply!).additional, 0)
    }

    // MARK: - The pool of fake addresses

    func testFakeAddressesStayInsideTheRangeAndSkipTheEnds() {
        var pool = FakeAddressPool(capacity: 1_000)
        var seen = Set<UInt32>()
        for index in 0..<600 {
            let address = pool.address(for: "host\(index).example")
            XCTAssertTrue(FakeAddressPool.contains(address))
            XCTAssertTrue(address.isIn(0xC612_0000, 15))
            XCTAssertNotEqual(address.value & 0xFF, 0)
            XCTAssertNotEqual(address.value & 0xFF, 255)
            XCTAssertTrue(seen.insert(address.value).inserted)
        }
        // The 254th name got the last address of the first /24, the 255th the first of the next.
        XCTAssertEqual(pool.address(for: "host253.example").string, "198.18.0.254")
        XCTAssertEqual(pool.address(for: "host254.example").string, "198.18.1.1")
        XCTAssertFalse(FakeAddressPool.contains(VMNetIPv4(string: "198.20.0.1")!))
        XCTAssertFalse(FakeAddressPool.contains(VMNetIPv4(string: "198.17.255.255")!))
        XCTAssertTrue(FakeAddressPool.contains(VMNetIPv4(string: "198.19.255.254")!))
    }

    func testTheNameUnusedLongestIsForgottenWhenThePoolIsFull() {
        var pool = FakeAddressPool(capacity: 3)
        let a = pool.address(for: "a.example")
        let b = pool.address(for: "b.example")
        let c = pool.address(for: "c.example")
        // Using "a" (a connection to its address) makes "b" the one unused longest.
        XCTAssertEqual(pool.name(for: a), "a.example")
        let d = pool.address(for: "d.example")
        XCTAssertNil(pool.name(for: b))
        XCTAssertEqual(pool.name(for: a), "a.example")
        XCTAssertEqual(pool.name(for: c), "c.example")
        XCTAssertEqual(pool.name(for: d), "d.example")
        XCTAssertEqual(pool.count, 3)
        // A forgotten address is not given to another name while fresh ones are left.
        XCTAssertNotEqual(d, b)
        // "b" asked again is a new name with a new address.
        let again = pool.address(for: "b.example")
        XCTAssertNotEqual(again, b)
        XCTAssertEqual(pool.name(for: again), "b.example")
    }

    func testAddressesAreUsedAgainOnlyAfterTheWholeRange() {
        // A small pool that goes round the whole range: every address is given once before any
        // is given twice, and a name always maps back from its address.
        var pool = FakeAddressPool(capacity: 100)
        var lastGiven: [UInt32: Int] = [:]
        let total = FakeAddressPool.usableAddresses + 5_000
        for index in 0..<total {
            let address = pool.address(for: "n\(index).example")
            if let before = lastGiven[address.value] {
                XCTAssertGreaterThanOrEqual(index - before, FakeAddressPool.usableAddresses - 100, "address used again too soon")
            }
            lastGiven[address.value] = index
            if index % 997 == 0 { XCTAssertEqual(pool.name(for: address), "n\(index).example") }
        }
        XCTAssertEqual(pool.count, 100)
        XCTAssertEqual(lastGiven.count, FakeAddressPool.usableAddresses)
    }

    func testThePoolHoldsSixtyThousandNames() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        XCTAssertEqual(responder.pool.capacity, 60_000)
        var first: VMNetIPv4?
        for index in 0..<60_000 {
            let address = Wire.dnsAnswer(ask(&responder, Wire.dnsQuery("h\(index).example")).reply!).address
            if index == 0 { first = address }
        }
        XCTAssertEqual(responder.pool.count, 60_000)
        XCTAssertEqual(responder.name(for: first!), "h0.example")
        // One more name: the pool stays at its limit, and the name unused longest (h1 — h0 was
        // just looked up) is the one forgotten.
        _ = ask(&responder, Wire.dnsQuery("one-more.example"))
        XCTAssertEqual(responder.pool.count, 60_000)
        XCTAssertEqual(responder.name(for: first!), "h0.example")
        XCTAssertNil(responder.name(for: VMNetIPv4(string: "198.18.0.2")!))
    }

    // MARK: - On the wire

    func testEveryResolverTheGuestAsksIsTheStack() throws {
        var responder = LinkResponder(configuration: Wire.configuration(blocked: ["blocked.example"]))
        var counters = VMNetCounters()
        var addresses: [VMNetIPv4] = []
        for resolver in [Wire.gateway, VMNetIPv4(string: "8.8.8.8")!, VMNetIPv4(string: "1.1.1.1")!] {
            let query = Wire.udp(from: 40_001, to: resolver, 53, payload: Wire.dnsQuery("example.com"))
            guard case .reply(let frame) = query.withUnsafeBytes({ responder.handle($0, now: 1, counters: &counters) }) else { return XCTFail("no answer") }
            let reply = try XCTUnwrap(Wire.seenUDP(frame))
            // The answer comes "from" the resolver that was asked.
            XCTAssertEqual(reply.source, resolver)
            XCTAssertEqual(reply.sourcePort, 53)
            XCTAssertEqual(reply.destination, Wire.guest)
            XCTAssertEqual(reply.destinationPort, 40_001)
            XCTAssertEqual(reply.destinationMAC, Wire.guestMAC)
            XCTAssertTrue(reply.checksumValid)
            addresses.append(try XCTUnwrap(Wire.dnsAnswer(reply.payload).address))
        }
        XCTAssertEqual(Set(addresses).count, 1)
        let blocked = Wire.udp(from: 40_002, to: VMNetIPv4(string: "8.8.8.8")!, 53, payload: Wire.dnsQuery("www.blocked.example"))
        guard case .reply(let frame) = blocked.withUnsafeBytes({ responder.handle($0, now: 1, counters: &counters) }) else { return XCTFail("no answer") }
        XCTAssertEqual(Wire.dnsAnswer(try XCTUnwrap(Wire.seenUDP(frame)).payload).code, 3)
        // A malformed query is not counted and not answered — and is not "other UDP" either.
        let garbage = Wire.udp(from: 40_003, to: Wire.gateway, 53, payload: [1, 2, 3])
        if case .ignore = garbage.withUnsafeBytes({ responder.handle($0, now: 1, counters: &counters) }) {} else { XCTFail("answered") }
        XCTAssertEqual(counters.dnsQueries, 4)
        XCTAssertEqual(counters.dnsBlocked, 1)
        XCTAssertEqual(counters.datagramsDropped, 0)
    }
}

final class KnownNamesAndTimeTests: XCTestCase {
    func testAPoolTakesBackTheNamesOfAnEarlierOneByTheSameAddresses() {
        var pool = FakeAddressPool(capacity: 100)
        let a = pool.address(for: "a.example"), b = pool.address(for: "b.example"), c = pool.address(for: "c.example")
        _ = pool.name(for: a)
        // The one unused the longest first.
        XCTAssertEqual(pool.entries.map(\.name), ["b.example", "c.example", "a.example"])

        var restored = FakeAddressPool(capacity: 100, restoring: pool.entries)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.name(for: b), "b.example")
        XCTAssertEqual(restored.address(for: "c.example"), c)
        XCTAssertEqual(restored.address(for: "a.example"), a)
        // A new name: the next address nobody had.
        let d = restored.address(for: "d.example")
        XCTAssertEqual(d.string, "198.18.0.4")
        XCTAssertEqual(restored.entries.map(\.name), ["b.example", "c.example", "a.example", "d.example"])

        // What is no entry of a pool is left out; of too many, the last are kept.
        let odd = [VMNetKnownName(name: "x.example", address: VMNetIPv4(string: "10.0.0.1")!.value),
                   VMNetKnownName(name: "y.example", address: VMNetIPv4(string: "198.18.0.0")!.value),
                   VMNetKnownName(name: "z.example", address: VMNetIPv4(string: "198.18.0.255")!.value),
                   VMNetKnownName(name: "", address: VMNetIPv4(string: "198.18.0.9")!.value),
                   VMNetKnownName(name: "one.example", address: VMNetIPv4(string: "198.18.1.7")!.value),
                   VMNetKnownName(name: "one.example", address: VMNetIPv4(string: "198.18.1.8")!.value),
                   VMNetKnownName(name: "two.example", address: VMNetIPv4(string: "198.18.1.7")!.value)]
        var careful = FakeAddressPool(capacity: 100, restoring: odd)
        XCTAssertEqual(careful.entries, [VMNetKnownName(name: "one.example", address: VMNetIPv4(string: "198.18.1.7")!.value)])
        // Fresh addresses go on after the highest one known.
        XCTAssertEqual(careful.address(for: "new.example").string, "198.18.1.8")
        let many = (0..<10).map { VMNetKnownName(name: "n\($0).example", address: FakeAddressPool.network + UInt32($0) + 1) }
        XCTAssertEqual(FakeAddressPool(capacity: 4, restoring: many).entries.map(\.name), ["n6.example", "n7.example", "n8.example", "n9.example"])

        XCTAssertEqual(FakeAddressPool.index(of: VMNetIPv4(string: "198.18.0.1")!.value), 0)
        XCTAssertEqual(FakeAddressPool.index(of: VMNetIPv4(string: "198.18.1.1")!.value), 254)
        XCTAssertEqual(FakeAddressPool.index(of: VMNetIPv4(string: "198.19.255.254")!.value), FakeAddressPool.usableAddresses - 1)
        XCTAssertNil(FakeAddressPool.index(of: VMNetIPv4(string: "198.20.0.1")!.value))
        XCTAssertNil(FakeAddressPool.index(of: VMNetIPv4(string: "198.17.255.254")!.value))
    }

    func testARestoredPoolGivesOutEveryAddressOfTheRangeBeforeAnyTwice() {
        // The names known sit high in the range: the addresses below them are not lost.
        let known = [VMNetKnownName(name: "high.example", address: FakeAddressPool.network + 256 * 3 + 5)]
        var pool = FakeAddressPool(capacity: 10, restoring: known)
        var seen: Set<UInt32> = [known[0].address]
        for index in 0..<(FakeAddressPool.usableAddresses - 1) {
            let address = pool.address(for: "name\(index).example").value
            XCTAssertTrue(FakeAddressPool.contains(VMNetIPv4(address)))
            XCTAssertTrue(seen.insert(address).inserted || index >= 10, "an address was given twice while its name was still known")
        }
        XCTAssertEqual(seen.count, FakeAddressPool.usableAddresses)
    }

    func testOnlyNamesTheResponderWouldGiveAnAddressAreTakenBack() {
        let known = [VMNetKnownName(name: "fine.example", address: FakeAddressPool.network + 1),
                     VMNetKnownName(name: "Upper.example", address: FakeAddressPool.network + 2),
                     VMNetKnownName(name: "localhost", address: FakeAddressPool.network + 3),
                     VMNetKnownName(name: "192.168.1.1", address: FakeAddressPool.network + 4),
                     VMNetKnownName(name: "a b.example", address: FakeAddressPool.network + 5)]
        var responder = DNSResponder(blockedHostSuffixes: [], knownNames: known)
        XCTAssertEqual(responder.knownNames, [known[0]])
        XCTAssertEqual(responder.name(for: VMNetIPv4(FakeAddressPool.network + 1)), "fine.example")
        XCTAssertNil(responder.name(for: VMNetIPv4(FakeAddressPool.network + 4)))
    }

    func testANameIsBlockedFromNowOnAndTheLastOneAskedForIsSaidOnce() {
        var responder = DNSResponder(blockedHostSuffixes: [])
        func ask(_ name: String) -> DNSResponder.Outcome {
            Wire.dnsQuery(name).withUnsafeBytes { responder.respond(to: $0).outcome }
        }
        XCTAssertEqual(ask("www.ads.example"), .answered)
        XCTAssertNil(responder.takeBlockedName())
        responder.block(".ADS.example.")
        responder.block("ads.example")
        XCTAssertEqual(ask("www.ads.example"), .blocked)
        XCTAssertEqual(ask("ads.example"), .blocked)
        XCTAssertEqual(ask("notads.example"), .answered)
        XCTAssertEqual(responder.takeBlockedName(), "ads.example")
        XCTAssertNil(responder.takeBlockedName())
        responder.block("")
        XCTAssertEqual(ask("anything.example"), .answered)
    }

    func testTheTimeIsToldAsAServerTellsIt() throws {
        var request = [UInt8](repeating: 0, count: 48)
        request[0] = 0x1B  // no warning, version 3, a client
        request[2] = 6
        for index in 0..<8 { request[40 + index] = UInt8(index + 1) }
        let server = VMNetIPv4(string: "17.253.4.125")!
        // 2026-11-14 12:00:00.5 UTC.
        let now = 1_794_657_600.5
        let reply = try XCTUnwrap(request.withUnsafeBytes { TimeResponder.reply(to: $0, now: now, reference: server) })
        XCTAssertEqual(reply.count, 48)
        XCTAssertEqual(reply[0], 0x1C)  // version 3, a server
        XCTAssertEqual(reply[1], 2)
        XCTAssertEqual(reply[2], 6)
        XCTAssertEqual(Array(reply[12..<16]), [17, 253, 4, 125])
        XCTAssertEqual(Array(reply[24..<32]), [1, 2, 3, 4, 5, 6, 7, 8])
        let seconds: UInt32 = 1_794_657_600 + 2_208_988_800
        let stamp = [UInt8(seconds >> 24), UInt8(seconds >> 16 & 0xFF), UInt8(seconds >> 8 & 0xFF), UInt8(seconds & 0xFF), 0x80, 0, 0, 0]
        XCTAssertEqual(Array(reply[16..<24]), stamp)
        XCTAssertEqual(Array(reply[32..<40]), stamp)
        XCTAssertEqual(Array(reply[40..<48]), stamp)

        // Not a client's request: a server's answer, a short one, a version nobody speaks.
        for change in [{ (bytes: inout [UInt8]) in bytes[0] = 0x1C }, { $0 = Array($0.prefix(47)) }, { $0[0] = 0x03 }, { $0[0] = 0x3B }] {
            var other = request
            change(&other)
            XCTAssertNil(other.withUnsafeBytes { TimeResponder.reply(to: $0, now: now, reference: server) })
        }
        XCTAssertNil(request.withUnsafeBytes { TimeResponder.reply(to: $0, now: -1, reference: server) })
    }

    func testAQuestionForTheTimeIsAnsweredFromTheServerAskedAndAnythingElseOnItsPortIsNot() throws {
        var responder = LinkResponder(configuration: Wire.configuration())
        responder.wallClock = { 1_794_657_600 }
        var counters = VMNetCounters()
        var request = [UInt8](repeating: 0, count: 48)
        request[0] = 0x23
        let server = VMNetIPv4(string: "17.253.4.125")!
        let asked = Wire.udp(from: 51_000, to: server, 123, payload: request)
        guard case .reply(let frame) = asked.withUnsafeBytes({ responder.handle($0, now: 1, counters: &counters) }) else { return XCTFail("no answer") }
        let reply = try XCTUnwrap(Wire.seenUDP(frame))
        XCTAssertEqual(reply.source, server)
        XCTAssertEqual(reply.sourcePort, 123)
        XCTAssertEqual(reply.destination, Wire.guest)
        XCTAssertEqual(reply.destinationPort, 51_000)
        XCTAssertTrue(reply.checksumValid)
        XCTAssertEqual(reply.payload.count, 48)
        XCTAssertEqual(counters.timeQueries, 1)
        XCTAssertEqual(counters.datagramsDropped, 0)
        // Nonsense on the same port is other UDP: nothing listens there.
        let nonsense = Wire.udp(from: 51_001, to: server, 123, payload: [1, 2, 3])
        guard case .reply(let refusal) = nonsense.withUnsafeBytes({ responder.handle($0, now: 1, counters: &counters) }) else { return XCTFail("no answer") }
        XCTAssertNil(Wire.seenUDP(refusal))
        XCTAssertEqual(counters.timeQueries, 1)
        XCTAssertEqual(counters.datagramsDropped, 1)
    }
}

final class DestinationPolicyTests: XCTestCase {
    private func decide(_ address: String, port: UInt16 = 443, names: [String: String] = [:]) -> DestinationPolicy.Decision {
        DestinationPolicy.decide(address: VMNetIPv4(string: address)!, port: port, gateway: Wire.gateway, prefixLength: 24) { names[$0.string] }
    }

    func testAFakeAddressIsItsName() {
        XCTAssertEqual(decide("198.18.0.1", names: ["198.18.0.1": "example.com"]), .connect(.name("example.com", port: 443)))
        XCTAssertEqual(decide("198.19.255.254", port: 80, names: ["198.19.255.254": "a.example"]), .connect(.name("a.example", port: 80)))
    }

    func testAFakeAddressWithoutANameIsRefused() {
        XCTAssertEqual(decide("198.18.0.1"), .refuse(.unknownFakeAddress))
        XCTAssertEqual(decide("198.19.200.7", names: ["198.18.0.1": "example.com"]), .refuse(.unknownFakeAddress))
    }

    func testAPublicAddressIsAskedOfTheProxyAsItIs() {
        for address in ["1.1.1.1", "8.8.8.8", "93.184.216.34", "172.15.255.255", "172.32.0.1", "192.167.255.255", "192.169.0.1",
                        "100.63.255.255", "100.128.0.1", "169.253.255.255", "169.255.0.1", "198.17.255.255", "198.20.0.1", "223.255.255.255",
                        "11.0.0.1", "9.255.255.255", "126.255.255.255", "128.0.0.1", "192.0.1.1"] {
            XCTAssertEqual(decide(address), .connect(.address(VMNetIPv4(string: address)!, port: 443)), address)
        }
    }

    func testEveryRangeThatIsNotThePublicInternetIsRefused() {
        let refused = [
            "0.0.0.0", "0.1.2.3", "0.255.255.255",            // "this network"
            "10.0.0.1", "10.255.255.255",                     // private
            "100.64.0.1", "100.127.255.255",                  // carrier-grade NAT
            "127.0.0.1", "127.255.255.255",                   // loopback
            "169.254.0.1", "169.254.169.254",                 // link-local (and a cloud's metadata address)
            "172.16.0.1", "172.31.255.255",                   // private
            "192.0.0.1", "192.0.0.255",                       // protocol assignments
            "192.168.0.1", "192.168.255.255",                 // private
            "224.0.0.1", "224.0.0.251", "239.255.255.250",    // multicast
            "240.0.0.1", "255.255.255.254", "255.255.255.255", // reserved, broadcast
        ]
        for address in refused {
            XCTAssertEqual(decide(address), .refuse(.notPublic), address)
        }
    }

    func testTheGuestsOwnNetworkIsRefused() {
        // The gateway offers no TCP service, and there is nobody else on the network.
        for address in ["192.168.1.1", "192.168.1.23", "192.168.1.50", "192.168.1.255", "192.168.1.0"] {
            XCTAssertEqual(decide(address), .refuse(.ownNetwork), address)
        }
        // A guest network that is not in a private range is refused as its own, too.
        let decision = DestinationPolicy.decide(address: VMNetIPv4(string: "203.0.113.9")!, port: 80,
                                                gateway: VMNetIPv4(string: "203.0.113.1")!, prefixLength: 24) { _ in nil }
        XCTAssertEqual(decision, .refuse(.ownNetwork))
    }

    func testPortZeroIsRefused() {
        XCTAssertEqual(decide("1.1.1.1", port: 0), .refuse(.noPort))
    }

    func testTheProxysTextForATarget() {
        XCTAssertEqual(ProxyTarget.name("example.com", port: 443).hostText, "example.com")
        XCTAssertEqual(ProxyTarget.address(VMNetIPv4(string: "1.2.3.4")!, port: 80).hostText, "1.2.3.4")
        XCTAssertEqual(ProxyTarget.address(VMNetIPv4(string: "1.2.3.4")!, port: 80).port, 80)
    }
}
