import XCTest
@testable import NetworkGuardCore

final class GuardPolicyTests: XCTestCase {
    private let named = GuardRegistration(pid: 4242, proxyHost: "Proxy.Example.", proxyPort: 1080,
                                          proxyAddresses: ["203.0.113.5", "::ffff:203.0.113.6", "2001:db8::5"])
    private let literal = GuardRegistration(pid: 4243, proxyHost: "198.51.100.7", proxyPort: 1080, proxyAddresses: [])

    private func verdict(_ transport: GuardTransport, _ address: String?, _ port: UInt16?, name: String? = nil,
                         _ registration: GuardRegistration? = nil) -> GuardVerdict {
        GuardPolicy.verdict(GuardFlow(transport: transport, remoteAddress: address, remotePort: port, remoteHostname: name),
                            for: registration ?? named)
    }

    func testRegistrationIsNormalized() {
        XCTAssertEqual(named.proxyHost, "proxy.example")
        XCTAssertEqual(named.proxyAddresses, ["203.0.113.5", "203.0.113.6", "2001:db8::5"])
        XCTAssertEqual(literal.proxyAddresses, ["198.51.100.7"], "a literal proxy host is its own address")
        XCTAssertEqual(named.format, GuardRegistration.currentFormat)
    }

    func testLoopbackIsAllowed() {
        // The WebRTC relay on 127.0.0.1, and anything else of this Mac's own on loopback.
        XCTAssertEqual(verdict(.udp, "127.0.0.1", 50000), .allow)
        XCTAssertEqual(verdict(.tcp, "127.9.9.9", 80), .allow)
        XCTAssertEqual(verdict(.udp, "::1", 50000), .allow)
        XCTAssertEqual(verdict(.udp, "::ffff:127.0.0.1", 50000), .allow)
        XCTAssertEqual(verdict(.tcp, nil, 8080, name: "LOCALHOST."), .allow)
    }

    func testTheProxyIsAllowed() {
        XCTAssertEqual(verdict(.tcp, "203.0.113.99", 1080, name: "proxy.example"), .allow, "by the name it was opened by")
        XCTAssertEqual(verdict(.tcp, nil, 1080, name: "PROXY.example."), .allow)
        XCTAssertEqual(verdict(.tcp, "203.0.113.5", 1080), .allow, "by an address the app found")
        XCTAssertEqual(verdict(.tcp, "::ffff:203.0.113.6", 1080), .allow, "an IPv4-mapped form of one")
        XCTAssertEqual(verdict(.tcp, "2001:0db8:0:0::5", 1080), .allow, "another spelling of an IPv6 one")
        XCTAssertEqual(verdict(.udp, "203.0.113.5", 61234), .allow, "the proxy's own UDP relay port")
        XCTAssertEqual(verdict(.tcp, "198.51.100.7", 1080, nil, literal), .allow)
    }

    func testEverythingElseIsDropped() {
        // WebRTC around the proxy: a STUN server, a peer, TURN over TCP, by address or by name.
        XCTAssertEqual(verdict(.udp, "74.125.250.129", 19302), .drop)
        XCTAssertEqual(verdict(.udp, "192.0.2.1", 3478), .drop)
        XCTAssertEqual(verdict(.udp, "2606:4700:49::", 3478), .drop)
        XCTAssertEqual(verdict(.tcp, "74.125.250.129", 443), .drop)
        XCTAssertEqual(verdict(.tcp, "1.2.3.4", 443, name: "stun.example.org"), .drop)
        // The proxy's name on another port is not the proxy; another host's name is not either.
        XCTAssertEqual(verdict(.tcp, "1.2.3.4", 443, name: "proxy.example"), .drop)
        XCTAssertEqual(verdict(.tcp, "1.2.3.4", 1080, name: "proxy.example.evil"), .drop)
        // The local network and multicast (mDNS) are no exception.
        XCTAssertEqual(verdict(.udp, "192.168.1.1", 1900), .drop)
        XCTAssertEqual(verdict(.udp, "224.0.0.251", 5353), .drop)
        XCTAssertEqual(verdict(.udp, "ff02::fb", 5353), .drop)
        // Neither address nor name: nothing to check it against.
        XCTAssertEqual(verdict(.udp, nil, 3478), .drop)
        XCTAssertEqual(verdict(.other, "203.0.113.5", 0), .drop, "another transport, even to the proxy")
    }

    func testDNS() {
        XCTAssertEqual(verdict(.udp, "192.168.1.1", 53), .inspectDNS)
        XCTAssertEqual(verdict(.udp, "8.8.8.8", 53), .inspectDNS)
        XCTAssertEqual(verdict(.tcp, "8.8.8.8", 53), .drop, "DNS over TCP is not looked into")
        XCTAssertEqual(GuardPolicy.dnsVerdict(Self.query(["proxy.example"]), for: named), .allow)
        XCTAssertEqual(GuardPolicy.dnsVerdict(Self.query(["PROXY.Example"]), for: named), .allow)
        XCTAssertEqual(GuardPolicy.dnsVerdict(Self.query(["stun-run123.leak.example.com"]), for: named), .drop)
        XCTAssertEqual(GuardPolicy.dnsVerdict(Self.query(["proxy.example", "other.example"]), for: named), .drop)
        XCTAssertEqual(GuardPolicy.dnsVerdict(Self.query(["proxy.example.evil"]), for: named), .drop)
        // A proxy given by address needs no name looked up at all.
        XCTAssertEqual(GuardPolicy.dnsVerdict(Self.query(["198.51.100.7"]), for: literal), .drop)
        // Not a query: a response, too short, a compressed name.
        var response = Self.query(["proxy.example"])
        response[2] |= 0x80
        XCTAssertEqual(GuardPolicy.dnsVerdict(response, for: named), .drop)
        XCTAssertEqual(GuardPolicy.dnsVerdict([0, 1, 0], for: named), .drop)
        XCTAssertEqual(GuardPolicy.dnsVerdict([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 0x0c, 0, 1, 0, 1], for: named), .drop)
    }

    func testDNSQuestionNames() {
        XCTAssertEqual(DNSQuestion.names(in: Self.query(["a.B.c"])), ["a.b.c"])
        XCTAssertEqual(DNSQuestion.names(in: Self.query(["x.example", "y.example"])), ["x.example", "y.example"])
        XCTAssertNil(DNSQuestion.names(in: Array(Self.query(["proxy.example"]).dropLast(3))), "cut short")
        let long = String(repeating: "a", count: 64)
        XCTAssertNil(DNSQuestion.names(in: Self.query([long])), "a label longer than 63")
    }

    func testAuditToken() {
        var token = [UInt8](repeating: 0, count: 32)
        // val[5] = pid 4242, val[7] = pidversion 7, little-endian words.
        token[20] = 0x92; token[21] = 0x10
        token[28] = 7
        XCTAssertEqual(AuditToken.pid(of: token), 4242)
        XCTAssertEqual(AuditToken.pidVersion(of: token), 7)
        XCTAssertNil(AuditToken.pid(of: Array(token.prefix(31))))
    }

    func testLedger() {
        let ledger = GuardLedger()
        XCTAssertNil(ledger.registration(for: 4242))
        ledger.hold(named)
        XCTAssertEqual(ledger.registration(for: 4242), named)
        let stun = GuardFlow(transport: .udp, remoteAddress: "192.0.2.1", remotePort: 3478)
        ledger.note(.drop, pid: 4242, flow: stun, by: "com.apple.WebKit.Networking", onBehalf: true)
        ledger.note(.allow, pid: 4242, flow: GuardFlow(transport: .tcp, remoteAddress: "203.0.113.5", remotePort: 1080),
                    by: "com.apple.WebKit.Networking", onBehalf: true)
        ledger.note(.drop, pid: 4242, flow: GuardFlow(transport: .tcp, remoteAddress: "2001:db8::9", remotePort: 443),
                    by: "Lumen", onBehalf: false)
        let report = ledger.report(for: 4242)
        XCTAssertEqual(report.allowed, 1)
        XCTAssertEqual(report.dropped, 2)
        XCTAssertEqual(report.seenOnItsBehalf, 2)
        XCTAssertEqual(report.recentDrops.map(\.remote), ["192.0.2.1:3478", "[2001:db8::9]:443"])
        XCTAssertEqual(report.recentDrops.first?.by, "com.apple.WebKit.Networking")
        for port in 0..<100 {
            ledger.note(.drop, pid: 4242, flow: GuardFlow(transport: .udp, remoteAddress: "192.0.2.1", remotePort: UInt16(port)),
                        by: "x", onBehalf: true)
        }
        XCTAssertEqual(ledger.report(for: 4242).recentDrops.count, GuardLedger.recentDropLimit, "only the last ones are kept")
        ledger.release(4242)
        XCTAssertNil(ledger.registration(for: 4242))
        XCTAssertFalse(ledger.report(for: 4242).held)
        // A process never held has nothing noted.
        ledger.note(.drop, pid: 1, flow: stun, by: "x", onBehalf: false)
        XCTAssertEqual(ledger.report(for: 1).dropped, 0)
    }

    func testRegistrationCodable() throws {
        let data = try JSONEncoder().encode(named)
        XCTAssertEqual(try JSONDecoder().decode(GuardRegistration.self, from: data), named)
        let report = GuardReport(pid: 1, held: true, allowed: 2, dropped: 3, seenOnItsBehalf: 4,
                                 recentDrops: [.init(transport: .udp, remote: "192.0.2.1:3478", by: "x")])
        XCTAssertEqual(try JSONDecoder().decode(GuardReport.self, from: JSONEncoder().encode(report)), report)
    }

    /// A DNS query for `names` (type A, class IN), as mDNSResponder sends one.
    static func query(_ names: [String]) -> [UInt8] {
        var message: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, UInt8(names.count), 0, 0, 0, 0, 0, 0]
        for name in names {
            for label in name.split(separator: ".") {
                message.append(UInt8(label.utf8.count))
                message.append(contentsOf: Array(label.utf8))
            }
            message += [0, 0, 1, 0, 1]
        }
        return message
    }
}
