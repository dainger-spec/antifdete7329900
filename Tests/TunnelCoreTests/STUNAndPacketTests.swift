import XCTest
@testable import TunnelCore

func hexBytes(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// RFC 5769 test vectors (copied from the RFC text), and packets built independently of this code.
final class STUNCodecTests: XCTestCase {
    static let request = hexBytes("000100582112a442b7e7a701bc34d686fa87dfae802200105354554e207465737420636c69656e74002400046e0001ff80290008932ff9b151263b36000600096576746a3a68367659202020000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a280280004e57a3bcf")
    static let ipv4Response = hexBytes("0101003c2112a442b7e7a701bc34d686fa87dfae8022000b7465737420766563746f7220002000080001a147e112a643000800142b91f599fd9e90c38c7489f92af9ba53f06be7d780280004c07d4c96")
    static let ipv6Response = hexBytes("010100482112a442b7e7a701bc34d686fa87dfae8022000b7465737420766563746f7220002000140002a1470113a9faa5d3f179bc25f4b5bed2b9d900080014a382954e4be67bf11784c97c8292c275bfe3ed4180280004c8fb0b4c")
    static let longTermRequest = hexBytes("000100602112a44278ad3433c6ad72c029da412e00060012e3839ee38388e383aae38383e382afe382b900000015001c662f2f3439396b39353464364f4c33346f4c394653547679363473410014000b6578616d706c652e6f72670000080014f67024656dd64a3e02b8e0712e85c9a28ca89666")
    static let shortTermKey = Array("VOkJxbRl1RmTxUk/WvJxBt".utf8)

    func testRFC5769IntegrityAndFingerprint() {
        for vector in [Self.request, Self.ipv4Response, Self.ipv6Response] {
            XCTAssertNotNil(STUNMessage.parse(vector))
            XCTAssertTrue(STUNMessage.verifyIntegrity(vector, key: Self.shortTermKey))
            XCTAssertTrue(STUNMessage.verifyFingerprint(vector))
            var tampered = vector
            tampered[30] ^= 1
            XCTAssertFalse(STUNMessage.verifyIntegrity(tampered, key: Self.shortTermKey))
            XCTAssertFalse(STUNMessage.verifyFingerprint(tampered))
        }
        XCTAssertFalse(STUNMessage.verifyIntegrity(Self.request, key: Array("wrong".utf8)))
    }

    func testRFC5769LongTermCredentials() {
        let key = STUNMessage.longTermKey(username: "\u{30DE}\u{30C8}\u{30EA}\u{30C3}\u{30AF}\u{30B9}", realm: "example.org", password: "TheMatrIX")
        XCTAssertTrue(STUNMessage.verifyIntegrity(Self.longTermRequest, key: key))
        let message = STUNMessage.parse(Self.longTermRequest)
        XCTAssertEqual(message?.attribute(STUNMessage.Attribute.realm).map { String(decoding: $0, as: UTF8.self) }, "example.org")
        XCTAssertEqual(message?.attribute(STUNMessage.Attribute.nonce).map { String(decoding: $0, as: UTF8.self) }, "f//499k954d6OL34oL9FSTvy64sA")
    }

    func testRFC5769MappedAddresses() throws {
        let v4 = try XCTUnwrap(STUNMessage.parse(Self.ipv4Response))
        XCTAssertEqual(v4.method, STUNMessage.Method.binding.rawValue)
        XCTAssertEqual(v4.messageClass, .success)
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(v4.attribute(STUNMessage.Attribute.xorMappedAddress)), transactionID: v4.transactionID),
                       SocketAddress(ip: IPAddr("192.0.2.1")!, port: 32853))
        let v6 = try XCTUnwrap(STUNMessage.parse(Self.ipv6Response))
        XCTAssertEqual(STUNMessage.decodeXorAddress(try XCTUnwrap(v6.attribute(STUNMessage.Attribute.xorMappedAddress)), transactionID: v6.transactionID),
                       SocketAddress(ip: IPAddr("2001:db8:1234:5678:11:2233:4455:6677")!, port: 32853))
        // Encoding gives the RFC's bytes back.
        XCTAssertEqual(STUNMessage.xorAddress(SocketAddress(ip: IPAddr("192.0.2.1")!, port: 32853), transactionID: v4.transactionID),
                       hexBytes("0001a147e112a643"))
    }

    func testTypeEncoding() {
        let cases: [(STUNMessage.Method, STUNMessage.Class, UInt16)] = [
            (.binding, .request, 0x0001), (.binding, .success, 0x0101), (.binding, .error, 0x0111),
            (.allocate, .request, 0x0003), (.allocate, .success, 0x0103), (.allocate, .error, 0x0113),
            (.refresh, .request, 0x0004), (.send, .indication, 0x0016), (.data, .indication, 0x0017),
            (.createPermission, .request, 0x0008), (.createPermission, .success, 0x0108),
            (.channelBind, .request, 0x0009), (.channelBind, .success, 0x0109), (.channelBind, .error, 0x0119),
        ]
        for (method, messageClass, type) in cases {
            XCTAssertEqual(STUNMessage.encodeType(method: method.rawValue, messageClass: messageClass), type)
            let decoded = STUNMessage.decodeType(type)
            XCTAssertEqual(decoded.method, method.rawValue)
            XCTAssertEqual(decoded.messageClass, messageClass)
        }
    }

    func testEncodeWithIntegrityAndFingerprintRoundTrips() throws {
        let key = STUNMessage.longTermKey(username: "u", realm: "r", password: "p")
        let transaction = [UInt8](0..<12)
        let message = STUNMessage(method: STUNMessage.Method.allocate.rawValue, messageClass: .request, transactionID: transaction,
                                  attributes: [(STUNMessage.Attribute.requestedTransport, [17, 0, 0, 0]),
                                               (STUNMessage.Attribute.username, Array("u".utf8))])
        let bytes = message.encode(integrityKey: key, fingerprint: true)
        XCTAssertEqual(bytes.count % 4, 0)
        XCTAssertTrue(STUNMessage.verifyIntegrity(bytes, key: key))
        XCTAssertTrue(STUNMessage.verifyFingerprint(bytes))
        let parsed = try XCTUnwrap(STUNMessage.parse(bytes))
        XCTAssertEqual(parsed.attribute(STUNMessage.Attribute.username), Array("u".utf8))
        XCTAssertEqual(STUNMessage.decodeErrorCode(STUNMessage.errorCode(438, reason: "Stale Nonce")), 438)
    }

    func testRejectsMalformed() {
        XCTAssertNil(STUNMessage.parse(Array(Self.request.prefix(40))))
        var badCookie = Self.request
        badCookie[4] = 0
        XCTAssertNil(STUNMessage.parse(badCookie))
        var badLength = Self.request
        badLength[3] = 0x5C // longer than the message
        XCTAssertNil(STUNMessage.parse(badLength))
    }
}

final class IPPacketTests: XCTestCase {
    // Built with an independent implementation (Python struct/socket, RFC 768/791/8200 checksums).
    static let ipv4 = hexBytes("45000026000040004011b2eec612000ac0a801140d96d43100126b5368656c6c6f207475726e")
    static let ipv6 = hexBytes("60000000000b1140fd6b3a1c94e20001000000000000000afd6b3a1c94e2000100000000000000010d96c350000bc2aa6f6464")

    func testBuildsTheSameBytesAsAnIndependentImplementation() {
        let v4 = UDPDatagram(source: SocketAddress(ip: IPAddr("198.18.0.10")!, port: 3478),
                             destination: SocketAddress(ip: IPAddr("192.168.1.20")!, port: 54321), payload: Array("hello turn".utf8))
        XCTAssertEqual(IPPacket.buildUDP(v4).map(hexString), hexString(Self.ipv4))
        let v6 = UDPDatagram(source: SocketAddress(ip: IPAddr("fd6b:3a1c:94e2:1::a")!, port: 3478),
                             destination: SocketAddress(ip: IPAddr("fd6b:3a1c:94e2:1::1")!, port: 50000), payload: Array("odd".utf8))
        XCTAssertEqual(IPPacket.buildUDP(v6).map(hexString), hexString(Self.ipv6))
        XCTAssertEqual(IPPacket.parseUDP(Self.ipv4), v4)
        XCTAssertEqual(IPPacket.parseUDP(Self.ipv6), v6)
    }

    func testDropsWhatItDoesNotHandle() {
        var fragment = Self.ipv4
        fragment[6] = 0x20 // more fragments
        XCTAssertNil(IPPacket.parseUDP(fragment))
        var badChecksum = Self.ipv4
        badChecksum[badChecksum.count - 1] ^= 0xFF
        XCTAssertNil(IPPacket.parseUDP(badChecksum))
        var tcp = Self.ipv4
        tcp[9] = 6
        XCTAssertNil(IPPacket.parseUDP(tcp))
        XCTAssertNil(IPPacket.parseUDP(Array(Self.ipv6.prefix(30))))
        var zeroChecksum6 = Self.ipv6
        zeroChecksum6[46] = 0
        zeroChecksum6[47] = 0
        XCTAssertNil(IPPacket.parseUDP(zeroChecksum6), "IPv6 UDP must carry a checksum")
        XCTAssertNil(IPPacket.buildUDP(UDPDatagram(source: SocketAddress(ip: IPAddr("1.2.3.4")!, port: 1),
                                                   destination: SocketAddress(ip: IPAddr("::1")!, port: 1), payload: [])))
    }

    func testIPv6ExtensionHeadersAreSkipped() {
        // The same datagram behind an 8-byte hop-by-hop header (next header 17, length 0, PadN).
        var packet = Array(Self.ipv6[0..<40])
        packet[6] = 0 // hop-by-hop
        packet[5] = 0x13 // payload length 11 + 8
        packet += [17, 0, 1, 4, 0, 0, 0, 0]
        packet += Array(Self.ipv6[40...])
        XCTAssertEqual(IPPacket.parseUDP(packet)?.payload, Array("odd".utf8))
        packet[46] = 44 // a fragment header instead: dropped
        packet[40] = 44
        XCTAssertNil(IPPacket.parseUDP(packet))
    }

    func testIPAddressText() {
        XCTAssertEqual(IPAddr("2001:0db8:0000:0000:0000:0000:0000:0001")?.description, "2001:db8::1")
        XCTAssertEqual(IPAddr("[::1]")?.description, "::1")
        XCTAssertNil(IPAddr("example.com"))
        XCTAssertEqual(SocketAddress(ip: IPAddr("::1")!, port: 3478).description, "[::1]:3478")
    }
}

final class SOCKS5Tests: XCTestCase {
    func testHandshakeBytes() throws {
        XCTAssertEqual(SOCKS5.greeting(withCredentials: false), [5, 1, 0])
        XCTAssertEqual(SOCKS5.greeting(withCredentials: true), [5, 2, 0, 2])
        XCTAssertEqual(try SOCKS5.parseMethodSelection([5, 2]), 2)
        XCTAssertThrowsError(try SOCKS5.parseMethodSelection([5, 0xFF]))
        XCTAssertEqual(try SOCKS5.authenticationRequest(.init(username: "ab", password: "c")), [1, 2, 97, 98, 1, 99])
        XCTAssertNoThrow(try SOCKS5.parseAuthenticationReply([1, 0]))
        XCTAssertThrowsError(try SOCKS5.parseAuthenticationReply([1, 1]))
        XCTAssertEqual(SOCKS5.udpAssociateRequest(), [5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(try SOCKS5.parseReplyHead([5, 0, 0, 1]), 1)
        XCTAssertThrowsError(try SOCKS5.parseReplyHead([5, 7, 0, 1])) { error in
            XCTAssertEqual(error as? SOCKS5.Failure, .requestRefused(7))
        }
        XCTAssertEqual(try SOCKS5.parseBoundAddress(atyp: 1, [10, 0, 0, 1, 0x1F, 0x90]),
                       .address(SocketAddress(ip: IPAddr("10.0.0.1")!, port: 8080)))
        XCTAssertEqual(try SOCKS5.parseBoundAddress(atyp: 3, [3, 97, 98, 99, 0, 80]), .name("abc", port: 80))
    }

    func testDatagramFraming() throws {
        let v6Peer = SocketAddress(ip: IPAddr("2001:db8::7")!, port: 3478)
        let wrapped = SOCKS5.wrapDatagram([1, 2, 3], to: .address(v6Peer))
        XCTAssertEqual(Array(wrapped[0..<4]), [0, 0, 0, 4])
        let unwrapped = try XCTUnwrap(SOCKS5.unwrapDatagram(wrapped))
        XCTAssertEqual(unwrapped.source, .address(v6Peer))
        XCTAssertEqual(unwrapped.payload, [1, 2, 3])
        let named = SOCKS5.wrapDatagram([9], to: .name("stun.example", port: 3478))
        XCTAssertEqual(Array(named[0..<5]), [0, 0, 0, 3, 12])
        var fragment = wrapped
        fragment[2] = 1
        XCTAssertNil(SOCKS5.unwrapDatagram(fragment), "fragments are dropped")
        XCTAssertNil(SOCKS5.unwrapDatagram([0, 0, 0, 1, 1, 2]))
    }
}
