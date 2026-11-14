import XCTest
@testable import VMNetCore

/// The two proxy protocols as bytes in and bytes out. The same conversations over real sockets,
/// against proxies that refuse, stall or talk nonsense, are in NetworkLoopTests.
final class ProxyHandshakeTests: XCTestCase {
    private let host = ProxyTarget.name("example.com", port: 443)
    private let literal = ProxyTarget.address(VMNetIPv4(string: "93.184.216.34")!, port: 8080)

    // MARK: - SOCKS5

    func testSOCKS5WithoutCredentialsAsksForAName() {
        var handshake = SOCKS5Handshake(target: host, credentials: nil)
        XCTAssertEqual(handshake.begin(), .send([5, 1, 0]))
        // The proxy picks "no authentication"; the request names the host (type 3) and the port.
        XCTAssertEqual(handshake.receive([5, 0]), .send([5, 1, 0, 3, 11] + Array("example.com".utf8) + [0x01, 0xBB]))
        XCTAssertEqual(handshake.receive([5, 0, 0, 1, 10, 0, 0, 1, 0x1F, 0x90]), .established(leftover: []))
    }

    func testSOCKS5AsksForALiteralAddressAsAnAddress() {
        var handshake = SOCKS5Handshake(target: literal, credentials: nil)
        _ = handshake.begin()
        XCTAssertEqual(handshake.receive([5, 0]), .send([5, 1, 0, 1, 93, 184, 216, 34, 0x1F, 0x90]))
    }

    func testSOCKS5WithCredentials() {
        let credentials = ProxyCredentials(username: "user", password: "pass")
        var handshake = SOCKS5Handshake(target: host, credentials: credentials)
        XCTAssertEqual(handshake.begin(), .send([5, 2, 0, 2]))
        XCTAssertEqual(handshake.receive([5, 2]), .send([1, 4] + Array("user".utf8) + [4] + Array("pass".utf8)))
        XCTAssertEqual(handshake.receive([1, 0]), .send([5, 1, 0, 3, 11] + Array("example.com".utf8) + [0x01, 0xBB]))
        XCTAssertEqual(handshake.receive([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), .established(leftover: []))
    }

    func testSOCKS5ProxyThatWantsNoSignInAlthoughOneIsOffered() {
        var handshake = SOCKS5Handshake(target: host, credentials: ProxyCredentials(username: "user", password: "pass"))
        _ = handshake.begin()
        guard case .send(let request) = handshake.receive([5, 0]) else { return XCTFail("no request") }
        XCTAssertEqual(Array(request.prefix(4)), [5, 1, 0, 3])
    }

    func testSOCKS5RepliesInPiecesAndWithEveryAddressType() {
        // One byte at a time, a bound address that is a name.
        var handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        XCTAssertEqual(handshake.receive([5]), .needMore)
        guard case .send = handshake.receive([0]) else { return XCTFail("no request") }
        let reply: [UInt8] = [5, 0, 0, 3, 4] + Array("host".utf8) + [0, 80]
        for byte in reply.dropLast() { XCTAssertEqual(handshake.receive([byte]), .needMore) }
        XCTAssertEqual(handshake.receive([reply.last!]), .established(leftover: []))

        // An IPv6 bound address, and bytes of the tunnel right behind the reply.
        handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        _ = handshake.receive([5, 0])
        let v6: [UInt8] = [5, 0, 0, 4] + [UInt8](repeating: 0, count: 16) + [0, 80]
        XCTAssertEqual(handshake.receive(v6 + [0x16, 0x03, 0x01]), .established(leftover: [0x16, 0x03, 0x01]))
    }

    func testSOCKS5Refusals() {
        // The request is refused: the reply's code is the reason (5: connection refused).
        var handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        _ = handshake.receive([5, 0])
        XCTAssertEqual(handshake.receive([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]), .failed(.refused(5)))
        // Nothing follows a failure.
        XCTAssertEqual(handshake.receive([5, 0]), .failed(.malformedReply))

        // The proxy takes none of the offered methods.
        handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        XCTAssertEqual(handshake.receive([5, 0xFF]), .failed(.noAcceptableMethod))

        // The password is wrong.
        handshake = SOCKS5Handshake(target: host, credentials: ProxyCredentials(username: "user", password: "wrong"))
        _ = handshake.begin()
        _ = handshake.receive([5, 2])
        XCTAssertEqual(handshake.receive([1, 1]), .failed(.authenticationRejected))

        // The proxy asks for a sign-in the profile does not have.
        handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        XCTAssertEqual(handshake.receive([5, 2]), .failed(.malformedReply))
    }

    func testSOCKS5Garbage() {
        var handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        XCTAssertEqual(handshake.receive(Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)), .failed(.malformedReply))

        handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        _ = handshake.receive([5, 0])
        XCTAssertEqual(handshake.receive([4, 0, 0, 1, 0, 0, 0, 0, 0, 0]), .failed(.malformedReply))

        handshake = SOCKS5Handshake(target: host, credentials: nil)
        _ = handshake.begin()
        _ = handshake.receive([5, 0])
        XCTAssertEqual(handshake.receive([5, 0, 0, 9, 0, 0, 0, 0, 0, 0]), .failed(.malformedReply))
    }

    func testSOCKS5LimitsOfLength() {
        let long = String(repeating: "a", count: 256)
        var handshake = SOCKS5Handshake(target: host, credentials: ProxyCredentials(username: long, password: "x"))
        XCTAssertEqual(handshake.begin(), .failed(.credentialsTooLong))
        handshake = SOCKS5Handshake(target: .name(long, port: 80), credentials: nil)
        XCTAssertEqual(handshake.begin(), .failed(.nameTooLong))
        // 255 bytes of each still go.
        let most = String(repeating: "b", count: 255)
        handshake = SOCKS5Handshake(target: host, credentials: ProxyCredentials(username: most, password: most))
        XCTAssertEqual(handshake.begin(), .send([5, 2, 0, 2]))
        guard case .send(let sign) = handshake.receive([5, 2]) else { return XCTFail("no sign-in") }
        XCTAssertEqual(sign.count, 2 + 255 + 1 + 255)
    }

    func testCredentialsNeedAUserName() {
        XCTAssertNil(ProxyCredentials(username: nil, password: "secret"))
        XCTAssertNil(ProxyCredentials(username: "", password: "secret"))
        XCTAssertEqual(ProxyCredentials(username: "user", password: nil)?.password, "")
    }

    // MARK: - HTTP CONNECT

    func testHTTPConnectRequest() {
        var handshake = HTTPConnectHandshake(target: host, credentials: nil)
        guard case .send(let bytes) = handshake.begin() else { return XCTFail("no request") }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Connection: keep-alive\r\n\r\n")
        XCTAssertEqual(handshake.receive(Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)), .established(leftover: []))
    }

    func testHTTPConnectWithCredentialsAndALiteralAddress() {
        var handshake = HTTPConnectHandshake(target: literal, credentials: ProxyCredentials(username: "Aladdin", password: "open sesame"))
        guard case .send(let bytes) = handshake.begin() else { return XCTFail("no request") }
        // RFC 7617's own example pair.
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       "CONNECT 93.184.216.34:8080 HTTP/1.1\r\nHost: 93.184.216.34:8080\r\n"
                       + "Proxy-Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==\r\nProxy-Connection: keep-alive\r\n\r\n")
    }

    func testHTTPConnectTakesAny2xxAndKeepsWhatFollowsTheHeaders() {
        var handshake = HTTPConnectHandshake(target: host, credentials: nil)
        _ = handshake.begin()
        // The answer in pieces, the end of the headers split across two of them, and the
        // tunnel's first bytes in the same read as the last of the headers.
        XCTAssertEqual(handshake.receive(Array("HTTP/1.0 204 No Con".utf8)), .needMore)
        XCTAssertEqual(handshake.receive(Array("tent\r\nVia: 1.1 proxy\r\n\r".utf8)), .needMore)
        XCTAssertEqual(handshake.receive(Array("\nfirst bytes".utf8)), .established(leftover: Array("first bytes".utf8)))
    }

    func testHTTPConnectRefusals() {
        for (answer, status) in [("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n", 407),
                                 ("HTTP/1.1 403 Forbidden\r\n\r\n", 403), ("HTTP/1.1 502 Bad Gateway\r\n\r\nbody", 502),
                                 ("HTTP/1.1 301 Moved\r\n\r\n", 301), ("HTTP/1.1 100 Continue\r\n\r\n", 100)] {
            var handshake = HTTPConnectHandshake(target: host, credentials: nil)
            _ = handshake.begin()
            XCTAssertEqual(handshake.receive(Array(answer.utf8)), .failed(.refused(status)), answer)
        }
    }

    func testHTTPConnectGarbage() {
        for answer in ["\u{5}\u{0}\u{0}\u{1}rubbish\r\n\r\n", "HTTP/2 200\r\n\r\n", "HTTP/1.1 2x0 OK\r\n\r\n", "HTTP/1.1200 OK\r\n\r\n", "\r\n\r\n"] {
            var handshake = HTTPConnectHandshake(target: host, credentials: nil)
            _ = handshake.begin()
            XCTAssertEqual(handshake.receive(Array(answer.utf8)), .failed(.malformedReply), answer)
        }
        // Headers that never end are not waited for beyond a limit.
        var handshake = HTTPConnectHandshake(target: host, credentials: nil)
        _ = handshake.begin()
        var step = ProxyHandshakeStep.needMore
        var sent = 0
        while step == .needMore && sent < 1 << 20 {
            step = handshake.receive([UInt8](repeating: 0x61, count: 1000))
            sent += 1000
        }
        XCTAssertEqual(step, .failed(.malformedReply))
        XCTAssertLessThanOrEqual(sent, HTTPConnectHandshake.maximumHeaderBytes + 1000)
    }

    // MARK: - What the log may say

    func testFailuresSayAKindAndANumberOnly() {
        let failures: [ProxyFailure] = [.malformedReply, .noAcceptableMethod, .authenticationRejected, .refused(5), .refused(407),
                                        .credentialsTooLong, .nameTooLong]
        for failure in failures {
            XCTAssertFalse(failure.reason.isEmpty)
            XCTAssertFalse(failure.reason.contains("example"))
        }
        XCTAssertTrue(ProxyFailure.refused(407).reason.contains("407"))
    }

    func testUpstreamChoosesItsHandshake() {
        let socks = VMNetUpstream.socks5(host: "proxy.example", port: 1080, username: "u", password: "p")
        XCTAssertTrue(socks.handshake(for: host) is SOCKS5Handshake)
        XCTAssertEqual(socks.endpoint?.host, "proxy.example")
        XCTAssertEqual(socks.endpoint?.port, 1080)
        let http = VMNetUpstream.httpConnect(host: "10.0.0.1", port: 3128, username: nil, password: nil)
        XCTAssertTrue(http.handshake(for: host) is HTTPConnectHandshake)
        XCTAssertNil(VMNetUpstream.none.handshake(for: host))
        XCTAssertNil(VMNetUpstream.none.endpoint)
    }
}
