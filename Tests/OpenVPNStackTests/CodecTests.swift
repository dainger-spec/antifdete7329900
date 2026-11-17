import XCTest
@testable import OpenVPNStack
import OpenVPNLink

final class SOCKS5ServerCodecTests: XCTestCase {
    func testTheGreetingOffersUserNameAndPasswordOrIsRefused() {
        XCTAssertEqual(SOCKS5Server.readGreeting([5, 2, 0, 2]), .value(true, consumed: 4))
        XCTAssertEqual(SOCKS5Server.readGreeting([5, 1, 0]), .value(false, consumed: 3))
        XCTAssertEqual(SOCKS5Server.readGreeting([5, 2, 0]), .needMore)
        XCTAssertEqual(SOCKS5Server.readGreeting([5]), .needMore)
        XCTAssertEqual(SOCKS5Server.readGreeting([4, 1, 0]), .invalid)
        XCTAssertEqual(SOCKS5Server.readGreeting([5, 0]), .invalid)
        XCTAssertEqual(SOCKS5Server.methodChoice(acceptable: true), [5, 2])
        XCTAssertEqual(SOCKS5Server.methodChoice(acceptable: false), [5, 0xFF])
    }

    func testCredentialsAreReadWhole() {
        var request: [UInt8] = [1, 3]
        request += Array("bob".utf8)
        request.append(2)
        request += Array("pw".utf8)
        XCTAssertEqual(SOCKS5Server.readCredentials(request),
                       .value(.init(username: Array("bob".utf8), password: Array("pw".utf8)), consumed: request.count))
        for cut in 0..<request.count { XCTAssertEqual(SOCKS5Server.readCredentials(Array(request[0..<cut])), .needMore) }
        XCTAssertEqual(SOCKS5Server.readCredentials([2, 1, 0x61, 1, 0x62]), .invalid)
        XCTAssertEqual(SOCKS5Server.readCredentials([1, 0, 1, 0x62]), .invalid)
        XCTAssertEqual(SOCKS5Server.readCredentials([1, 1, 0x61, 0]), .invalid)
    }

    func testRequestsByAddressAndByName() {
        XCTAssertEqual(SOCKS5Server.readRequest([5, 1, 0, 1, 10, 8, 0, 1, 0x1F, 0x90]),
                       .value(.init(command: 1, destination: .address(TunnelAddress("10.8.0.1")!), port: 8080), consumed: 10))
        var six: [UInt8] = [5, 1, 0, 4]
        six += TunnelAddress("2001:db8::1")!.bytes
        six += [0, 80]
        XCTAssertEqual(SOCKS5Server.readRequest(six), .value(.init(command: 1, destination: .address(TunnelAddress("2001:db8::1")!), port: 80), consumed: 22))
        var name: [UInt8] = [5, 1, 0, 3, 12]
        name += Array("Example.COM.".utf8)
        name += [1, 187]
        XCTAssertEqual(SOCKS5Server.readRequest(name), .value(.init(command: 1, destination: .name("example.com"), port: 443), consumed: name.count))
        // An address written as a name is that address.
        var literal: [UInt8] = [5, 1, 0, 3, 9]
        literal += Array("127.0.0.1".utf8)
        literal += [0, 80]
        XCTAssertEqual(SOCKS5Server.readRequest(literal), .value(.init(command: 1, destination: .address(TunnelAddress("127.0.0.1")!), port: 80), consumed: literal.count))
        for cut in 0..<name.count { XCTAssertEqual(SOCKS5Server.readRequest(Array(name[0..<cut])), .needMore, "cut at \(cut)") }
        XCTAssertEqual(SOCKS5Server.readRequest([5, 1, 1, 1, 1, 2, 3, 4, 0, 80]), .invalid, "a reserved byte that is not zero")
        XCTAssertEqual(SOCKS5Server.readRequest([5, 1, 0, 9, 1, 2, 3, 4, 0, 80]), .invalid, "an unknown address type")
        XCTAssertEqual(SOCKS5Server.readRequest([5, 1, 0, 3, 0, 0, 80]), .invalid, "an empty name")
    }

    func testNamesThatAreNotHostNamesAreRefused() {
        for bad in ["a b.com", "a\u{0}b", "-\n-", "exa mple", "..", "a..b", "ünïcode.de", String(repeating: "a", count: 64) + ".com", "x/y"] {
            XCTAssertNil(HostName.normalized(Array(bad.utf8)), bad)
        }
        XCTAssertEqual(HostName.normalized(Array("Sub_domain.Example-1.ORG.".utf8)), "sub_domain.example-1.org")
        XCTAssertEqual(HostName.normalized(Array("xn--80ak6aa92e.com".utf8)), "xn--80ak6aa92e.com")
    }

    func testRepliesAndDatagrams() {
        XCTAssertEqual(SOCKS5Server.reply(.connectionRefused), [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(SOCKS5Server.reply(.succeeded, bound: TunnelAddress("10.8.0.2"), port: 0x1234), [5, 0, 0, 1, 10, 8, 0, 2, 0x12, 0x34])
        let datagram = SOCKS5Server.datagram(from: TunnelAddress("1.2.3.4")!, port: 3478, payload: [9, 9])
        XCTAssertEqual(datagram, [0, 0, 0, 1, 1, 2, 3, 4, 0x0D, 0x96, 9, 9])
        XCTAssertEqual(SOCKS5Server.readDatagram(datagram), .init(destination: .address(TunnelAddress("1.2.3.4")!), port: 3478, payload: [9, 9]))
        XCTAssertNil(SOCKS5Server.readDatagram([0, 0, 1, 1, 1, 2, 3, 4, 0, 1, 9]), "a fragment is not reassembled")
        var named: [UInt8] = [0, 0, 0, 3, 8]
        named += Array("stun.foo".utf8)
        named += [0x0D, 0x96, 7]
        XCTAssertEqual(SOCKS5Server.readDatagram(named), .init(destination: .name("stun.foo"), port: 3478, payload: [7]))
    }
}

final class DNSMessageTests: XCTestCase {
    func testTheQuestion() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 0xBEEF, name: "Www.Example.com", type: .a))
        XCTAssertEqual(Array(query[0..<12]), [0xBE, 0xEF, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1])
        var name: [UInt8] = [3]
        name += Array("www".utf8)
        name.append(7)
        name += Array("example".utf8)
        name.append(3)
        name += Array("com".utf8)
        name.append(0)
        XCTAssertEqual(Array(query[12..<29]), name)
        XCTAssertEqual(Array(query[29..<33]), [0, 1, 0, 1])
        XCTAssertEqual(Array(query[33...]), [0, 0, 0x29, 0x04, 0xD0, 0, 0, 0, 0, 0, 0], "EDNS(0), 1232 bytes")
        XCTAssertNil(DNSMessage.query(id: 1, name: "bad name", type: .a))
    }

    func testAnAnswerWithItsCNAMEChainAndCompression() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 7, name: "www.example.com", type: .a))
        let questionEnd = 12 + 17 + 4
        var answer: [UInt8] = [0, 7, 0x81, 0x80, 0, 1, 0, 3, 0, 0, 0, 0]
        answer += Array(query[12..<questionEnd])
        // www.example.com CNAME cdn.example.net (target written out), then two A records for the target, by pointer.
        var cnameTarget: [UInt8] = [3]
        cnameTarget += Array("cdn".utf8)
        cnameTarget.append(7)
        cnameTarget += Array("example".utf8)
        cnameTarget.append(3)
        cnameTarget += Array("net".utf8)
        cnameTarget.append(0)
        let cnameHead: [UInt8] = [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0x0E, 0x10, 0, UInt8(cnameTarget.count)]
        answer += cnameHead
        answer += cnameTarget
        let targetOffset = UInt8(12 + 17 + 4 + 12)
        let first: [UInt8] = [0xC0, targetOffset, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        let second: [UInt8] = [0xC0, targetOffset, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 93, 184, 216, 35]
        answer += first
        answer += second
        let read = try XCTUnwrap(DNSMessage.readAnswer(answer, name: "www.example.com", type: .a))
        XCTAssertEqual(read.outcome, .addresses([TunnelAddress("93.184.216.34")!, TunnelAddress("93.184.216.35")!], ttl: 30))
    }

    func testRecordsForAnotherNameAreNotTaken() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 9, name: "bank.example", type: .a))
        let questionEnd = 12 + 14 + 4
        var answer: [UInt8] = [0, 9, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        answer += Array(query[12..<questionEnd])
        // An A record for a name the question did not ask, and no CNAME leading to it: not taken.
        var other: [UInt8] = [4]
        other += Array("evil".utf8)
        other.append(7)
        other += Array("example".utf8)
        other.append(0)
        let record: [UInt8] = [0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 6, 6, 6, 6]
        answer += other
        answer += record
        XCTAssertEqual(try XCTUnwrap(DNSMessage.readAnswer(answer, name: "bank.example", type: .a)).outcome, .addresses([], ttl: 60))
    }

    func testNotAnAnswerToTheQuestion() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 3, name: "a.example", type: .a))
        XCTAssertNil(DNSMessage.readAnswer(query, name: "a.example", type: .a), "a question is not an answer")
        var answer = query
        answer[2] = 0x81
        XCTAssertNil(DNSMessage.readAnswer(answer, name: "b.example", type: .a), "another name")
        XCTAssertNil(DNSMessage.readAnswer(answer, name: "a.example", type: .aaaa), "another type")
        XCTAssertNil(DNSMessage.readAnswer(Array(answer[0..<14]), name: "a.example", type: .a), "cut short")
    }

    func testNoSuchNameAndServerFailure() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 4, name: "none.example", type: .a))
        let question = Array(query[12..<(12 + 14 + 4)])
        var nx: [UInt8] = [0, 4, 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0]
        nx += question
        XCTAssertEqual(DNSMessage.readAnswer(nx, name: "none.example", type: .a)?.outcome, .noSuchName(ttl: 60))
        var failed: [UInt8] = [0, 4, 0x81, 0x82, 0, 1, 0, 0, 0, 0, 0, 0]
        failed += question
        XCTAssertEqual(DNSMessage.readAnswer(failed, name: "none.example", type: .a)?.outcome, .serverFailure(code: 2))
    }

    func testPointerLoopsAndForwardPointersAreRefused() {
        // A name that points at itself, and one that points forwards.
        XCTAssertNil(DNSMessage.readName([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 12], at: 12))
        XCTAssertNil(DNSMessage.readName([0xC0, 4, 0, 0, 1, 0x61, 0], at: 0))
        XCTAssertEqual(DNSMessage.readName([1, 0x61, 0, 1, 0x62, 0xC0, 0], at: 3)?.0, "b.a")
    }
}

final class TunnelSettingsTests: XCTestCase {
    private var verifierHex: String { String(repeating: "ab", count: 32) }

    func testWhatOpenVPNAndTheAppGive() throws {
        let settings = try TunnelSettings.read([
            "TUNTAP_SOCKET_FD": "7", "TUNTAP_DEV_TYPE": "tun", "TUNTAP_MTU": "1400", "ifconfig_local": "10.8.0.6",
            "ifconfig_ipv6_local": "fd00::1000", "LUMEN_SOCKS_FD": "3", "LUMEN_STATUS_FD": "4", "LUMEN_LIFELINE_FD": "5",
            "LUMEN_SOCKS_VERIFIER": verifierHex,
            "dns_server_0_address_1": "10.8.0.1", "dns_server_0_port_1": "5353", "dns_server_1_address_1": "fd00::53",
            "foreign_option_1": "dhcp-option DNS 10.8.0.1", "foreign_option_2": "dhcp-option DNS 9.9.9.9",
            "foreign_option_3": "dhcp-option DOMAIN corp.example",
        ])
        XCTAssertEqual(settings.packetSocket, 7)
        XCTAssertEqual(settings.listeningSocket, 3)
        XCTAssertEqual(settings.statusSocket, 4)
        XCTAssertEqual(settings.lifeline, 5)
        XCTAssertEqual(settings.mtu, 1400)
        XCTAssertEqual(settings.ipv4, TunnelAddress("10.8.0.6"))
        XCTAssertEqual(settings.ipv6, TunnelAddress("fd00::1000"))
        XCTAssertTrue(settings.dnsPushed)
        XCTAssertEqual(settings.dnsServers.map { "\($0.address):\($0.port)" }, ["10.8.0.1:5353", "fd00::53:53", "10.8.0.1:53", "9.9.9.9:53"])
    }

    func testWithoutPushedDNSThePublicResolversAreAskedThroughTheTunnel() throws {
        let settings = try TunnelSettings.read(["TUNTAP_SOCKET_FD": "7", "ifconfig_local": "10.8.0.6", "LUMEN_SOCKS_FD": "3",
                                                "LUMEN_SOCKS_VERIFIER": verifierHex])
        XCTAssertFalse(settings.dnsPushed)
        XCTAssertEqual(settings.dnsServers, TunnelSettings.fallbackDNS)
    }

    func testWhatIsRefused() {
        let base = ["TUNTAP_SOCKET_FD": "7", "ifconfig_local": "10.8.0.6", "LUMEN_SOCKS_FD": "3", "LUMEN_SOCKS_VERIFIER": verifierHex]
        func refuses(_ change: [String: String?], _ problem: TunnelSettings.Problem) {
            var environment = base
            for (key, value) in change { environment[key] = value }
            XCTAssertThrowsError(try TunnelSettings.read(environment)) { XCTAssertEqual($0 as? TunnelSettings.Problem, problem) }
        }
        refuses(["TUNTAP_DEV_TYPE": "tap"], .tap)
        refuses(["TUNTAP_SOCKET_FD": nil], .missing("TUNTAP_SOCKET_FD"))
        refuses(["TUNTAP_SOCKET_FD": "1"], .invalid("TUNTAP_SOCKET_FD"))
        refuses(["LUMEN_SOCKS_VERIFIER": "abc"], .invalid("LUMEN_SOCKS_VERIFIER"))
        refuses(["LUMEN_SOCKS_VERIFIER": nil], .missing("LUMEN_SOCKS_VERIFIER"))
        refuses(["ifconfig_local": nil], .noAddress)
        refuses(["ifconfig_local": "0.0.0.0"], .noAddress)
        refuses(["TUNTAP_MTU": "100"], .invalid("TUNTAP_MTU"))
    }

    func testTheCredentialCheck() {
        let verifier = CredentialCheck.verifier(username: Array("lumen".utf8), password: Array("secret".utf8))
        XCTAssertTrue(CredentialCheck.matches(username: Array("lumen".utf8), password: Array("secret".utf8), verifier: verifier))
        XCTAssertFalse(CredentialCheck.matches(username: Array("lumen".utf8), password: Array("secreT".utf8), verifier: verifier))
        XCTAssertFalse(CredentialCheck.matches(username: Array("lumen\u{0}secret".utf8), password: [], verifier: verifier))
        XCTAssertEqual(CredentialCheck.hex([0, 0xAB, 0xFF]), "00abff")
        XCTAssertEqual(TunnelSettings.hexBytes("00abFF"), [0, 0xAB, 0xFF])
    }

    func testTheStatusLineIsOneEscapedJSONObject() {
        XCTAssertEqual(TunnelStatus.line(["event": "up", "reason": "a \"b\"\n"]), "{\"event\":\"up\",\"reason\":\"a \\\"b\\\"\\n\"}\n")
    }
}
