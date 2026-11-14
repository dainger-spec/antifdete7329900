#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// The whole network over a real socket pair: the test plays a small guest at one end, and a
/// proxy on loopback at the other side of the stack. Real sockets, real threads, real time.
final class NetworkLoopTests: XCTestCase {
    private var network: VMNetwork?
    private var guestEnd: Int32 = -1
    private var stackEnd: Int32 = -1
    private var proxies: [FakeProxy] = []
    private let logLines = Locked<[String]>([])

    override class func setUp() {
        super.setUp()
        // What an app that runs a virtual machine does too: macOS lets a process open 256
        // descriptors unless it asks for more, and these tests hold hundreds of sockets.
        TestSocket.raiseDescriptorLimit(to: 4096)
    }

    override func tearDown() {
        network?.stop()
        network = nil
        for proxy in proxies { proxy.stop() }
        proxies = []
        if guestEnd >= 0 { Sys.close(guestEnd) }
        if stackEnd >= 0 { Sys.close(stackEnd) }
        guestEnd = -1
        stackEnd = -1
        super.tearDown()
    }

    private func proxy(_ kind: FakeProxy.Kind, credentials: (String, String)? = nil, behaviour: FakeProxy.Behaviour = .tunnel,
                       afterHeaders: [UInt8] = [], origin: @escaping @Sendable (Int32) -> Void = { _ in }) -> FakeProxy {
        let proxy = FakeProxy(kind: kind, credentials: credentials, behaviour: behaviour, afterHeaders: afterHeaders, origin: origin)
        proxies.append(proxy)
        return proxy
    }

    /// Starts a network with `upstream` and returns the guest at the other end of its wire.
    @discardableResult
    private func start(_ upstream: VMNetUpstream, blocked: [String] = [], configure: (inout NetworkLoop.Options) -> Void = { _ in }) -> TestGuest {
        let (first, second) = TestSocket.datagramPair()
        stackEnd = first
        guestEnd = second
        let network = VMNetwork(configuration: Wire.configuration(upstream: upstream, blocked: blocked), frameDescriptor: first)
        var options = network.options
        configure(&options)
        network.options = options
        let lines = logLines
        network.log = { line in lines.update { $0.append(line) } }
        network.start()
        self.network = network
        return TestGuest(descriptor: second)
    }

    private func bytes(_ count: Int, seed: UInt64 = 11) -> [UInt8] {
        var random = TestRandom(seed: seed)
        return random.bytes(count)
    }

    /// Waits until the counters say what `condition` wants (they are published once per turn of the loop).
    private func waitForCounters(timeout: Double = 3, _ condition: (VMNetCounters) -> Bool) -> VMNetCounters {
        let deadline = Sys.now + timeout
        while true {
            let counters = network!.counters()
            if condition(counters) || Sys.now >= deadline { return counters }
            usleep(2_000)
        }
    }

    private func open(_ guest: TestGuest, _ address: VMNetIPv4, port: UInt16 = 80, timeout: Double = 5,
                      file: StaticString = #filePath, line: UInt = #line) -> GuestConnection? {
        guard case .open(let connection) = GuestConnection.open(guest, to: address, port: port, timeout: timeout) else {
            XCTFail("the connection did not open", file: file, line: line)
            return nil
        }
        return connection
    }

    private func assertRefused(_ guest: TestGuest, _ address: VMNetIPv4, port: UInt16 = 80, within limit: Double = 3,
                               file: StaticString = #filePath, line: UInt = #line) {
        switch GuestConnection.open(guest, to: address, port: port, timeout: limit + 3) {
        case .refused(let seconds): XCTAssertLessThan(seconds, limit, "refused, but late", file: file, line: line)
        case .open: XCTFail("the connection opened", file: file, line: line)
        case .timedOut: XCTFail("no answer at all", file: file, line: line)
        }
    }

    // MARK: - A guest's first minutes

    /// The whole way: DHCP, ARP, DNS, a TCP connection, an HTTP request through a SOCKS5 proxy
    /// to an origin, and the answer back, byte for byte.
    func testAGuestGetsAnAddressResolvesANameAndLoadsAPage() throws {
        let body = bytes(200_000)
        let socks = proxy(.socks5, origin: FakeProxy.httpOrigin(body: body))
        let guest = start(socks.upstream())

        let lease = try XCTUnwrap(guest.dhcp())
        XCTAssertEqual(lease.address, Wire.guest)
        XCTAssertEqual(lease.options[3], [192, 168, 1, 1])
        XCTAssertEqual(lease.options[6], [192, 168, 1, 1])
        XCTAssertEqual(lease.options[1], [255, 255, 255, 0])
        XCTAssertEqual(guest.arpForGateway(), Wire.gatewayMAC)

        let answer = try XCTUnwrap(guest.resolve("www.example.com"))
        XCTAssertEqual(answer.code, 0)
        let address = try XCTUnwrap(answer.address)
        XCTAssertTrue(FakeAddressPool.contains(address))
        XCTAssertEqual(guest.resolve("www.example.com", type: 28)?.address, nil)

        let connection = try XCTUnwrap(open(guest, address))
        let request = Array("GET /index.html HTTP/1.1\r\nHost: www.example.com\r\n\r\n".utf8)
        XCTAssertTrue(connection.write(request))
        connection.readToEnd()
        XCTAssertTrue(connection.peerFinished)
        let response = connection.takeReceived()
        let head = Array("HTTP/1.1 200 OK\r\nContent-Length: 200000\r\nConnection: close\r\n\r\n".utf8)
        XCTAssertEqual(response.count, head.count + body.count)
        XCTAssertTrue(Array(response.prefix(head.count)) == head)
        XCTAssertTrue(Array(response.dropFirst(head.count)) == body, "the page's bytes differ")
        XCTAssertEqual(connection.largestSegment, 1460)
        XCTAssertTrue(connection.close())

        // The proxy was asked for the name — never for the fake address.
        XCTAssertEqual(socks.requests.value, [FakeProxy.Request(host: "www.example.com", port: 80, byName: true)])
        let counters = waitForCounters { $0.connectionsActive == 0 && $0.bytesToGuest == UInt64(response.count) }
        XCTAssertEqual(counters.connectionsOpened, 1)
        XCTAssertEqual(counters.connectionsFailed, 0)
        XCTAssertEqual(counters.connectionsActive, 0)
        XCTAssertEqual(counters.bytesFromGuest, UInt64(request.count))
        XCTAssertEqual(counters.bytesToGuest, UInt64(response.count))
        XCTAssertEqual(counters.dnsQueries, 2)
        XCTAssertEqual(counters.dnsBlocked, 0)
        XCTAssertEqual(counters.datagramsDropped, 0)
    }

    func testPingAndBlockedNamesAndStrayUDP() throws {
        let guest = start(.none, blocked: ["updates.example"])
        let payload = Array("ping".utf8)
        let ping = payload.withUnsafeBytes { bytes in
            FrameBuilder.icmp(destinationMAC: Wire.gatewayMAC, sourceMAC: Wire.guestMAC, source: Wire.guest, destination: Wire.gateway,
                              type: ICMPMessage.echoRequest, code: 0, rest: 0x0001_0001, payload: bytes, identification: 1)
        }
        guest.send(ping)
        let echoed = guest.expect { frame -> Bool? in
            frame.withUnsafeBytes { bytes -> Bool? in
                guard let packet = IPv4Packet(EthernetFrame(bytes)!.payload), packet.proto == IPProtocol.icmp,
                      let message = ICMPMessage(packet.payload) else { return nil }
                return message.type == ICMPMessage.echoReply && Array(message.payload) == payload
            }
        }
        XCTAssertEqual(echoed, true)

        XCTAssertEqual(guest.resolve("swscan.updates.example")?.code, 3)
        XCTAssertEqual(guest.resolve("fine.example", server: VMNetIPv4(string: "8.8.8.8")!)?.code, 0)

        guest.send(Wire.udp(from: 50_123, to: VMNetIPv4(string: "8.8.4.4")!, 443, payload: [1, 2, 3]))
        let unreachable = guest.expect { frame -> Bool? in
            frame.withUnsafeBytes { bytes -> Bool? in
                guard let packet = IPv4Packet(EthernetFrame(bytes)!.payload), packet.proto == IPProtocol.icmp,
                      let message = ICMPMessage(packet.payload) else { return nil }
                return message.type == ICMPMessage.destinationUnreachable && message.code == ICMPMessage.portUnreachable
                    && packet.source.string == "8.8.4.4"
            }
        }
        XCTAssertEqual(unreachable, true)
        let counters = waitForCounters { $0.datagramsDropped == 1 }
        XCTAssertEqual(counters.dnsQueries, 2)
        XCTAssertEqual(counters.dnsBlocked, 1)
        XCTAssertEqual(counters.datagramsDropped, 1)
    }

    // MARK: - SOCKS5

    func testSOCKS5WithAUserNameAndPassword() throws {
        let socks = proxy(.socks5, credentials: ("alice", "s3cret"), origin: FakeProxy.echo)
        let guest = start(socks.upstream(username: "alice", password: "s3cret"))
        let address = try XCTUnwrap(guest.resolve("signed-in.example")?.address)
        let connection = try XCTUnwrap(open(guest, address, port: 443))
        XCTAssertTrue(connection.write(Array("hello".utf8)))
        connection.read(atLeast: 5)
        XCTAssertEqual(connection.takeReceived(), Array("hello".utf8))
        XCTAssertEqual(socks.requests.value, [FakeProxy.Request(host: "signed-in.example", port: 443, byName: true, username: "alice", password: "s3cret")])
    }

    func testSOCKS5WithAWrongPasswordIsRefused() throws {
        let socks = proxy(.socks5, credentials: ("alice", "s3cret"))
        let guest = start(socks.upstream(username: "alice", password: "wrong"))
        let address = try XCTUnwrap(guest.resolve("signed-in.example")?.address)
        assertRefused(guest, address)
        XCTAssertEqual(waitForCounters { $0.connectionsFailed == 1 }.connectionsFailed, 1)
    }

    func testAProxyThatWantsASignInTheProfileDoesNotHaveIsRefused() throws {
        let socks = proxy(.socks5, credentials: ("alice", "s3cret"))
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("signed-in.example")?.address)
        assertRefused(guest, address)
    }

    func testSOCKS5RefusalBecomesAReset() throws {
        let socks = proxy(.socks5, behaviour: .refuse(5))
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("closed.example")?.address)
        assertRefused(guest, address)
        let counters = waitForCounters { $0.connectionsFailed == 1 }
        XCTAssertEqual(counters.connectionsFailed, 1)
        XCTAssertEqual(counters.connectionsOpened, 0)
        XCTAssertEqual(counters.connectionsActive, 0)
        XCTAssertEqual(socks.requests.value.map(\.host), ["closed.example"])
    }

    func testAProxyThatTalksNonsenseIsRefused() throws {
        let socks = proxy(.socks5, behaviour: .garbage(Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)))
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("any.example")?.address)
        assertRefused(guest, address)
        XCTAssertEqual(waitForCounters { $0.connectionsFailed == 1 }.connectionsFailed, 1)
    }

    func testASlowProxyIsWaitedForAndRepeatedSYNsAreNotAnswered() throws {
        let socks = proxy(.socks5, behaviour: .slow(1.2), origin: FakeProxy.echo)
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("slow.example")?.address)
        // The guest's SYN, and the same SYN twice more while the proxy thinks: no answer to any
        // of them until the tunnel is up, then exactly one SYN-ACK.
        let port = guest.freshPort()
        let syn = Wire.tcp(from: port, to: address, 80, sequence: 7_000, flags: [.syn], options: Wire.synOptions())
        let began = Sys.now
        guest.send(syn)
        XCTAssertTrue(guest.hearsNothing(for: 0.2))
        guest.send(syn)
        XCTAssertTrue(guest.hearsNothing(for: 0.2))
        guest.send(syn)
        let synAck = try XCTUnwrap(guest.expect(timeout: 5) { Wire.seenTCP($0) })
        XCTAssertEqual(synAck.flags, [.syn, .ack])
        XCTAssertEqual(synAck.acknowledgement, 7_001)
        XCTAssertGreaterThanOrEqual(Sys.now - began, 1.1)
        XCTAssertTrue(guest.hearsNothing(for: 0.2))
        XCTAssertEqual(socks.accepted.value, 1)
    }

    func testAProxyThatNeverAnswersIsGivenUpOn() throws {
        let socks = proxy(.socks5, behaviour: .silent)
        let guest = start(socks.upstream()) { $0.connectTimeout = 0.7 }
        let address = try XCTUnwrap(guest.resolve("silent.example")?.address)
        switch GuestConnection.open(guest, to: address, timeout: 5, resend: 5) {
        case .refused(let seconds):
            XCTAssertGreaterThanOrEqual(seconds, 0.65)
            XCTAssertLessThan(seconds, 4)
        default:
            XCTFail("not refused")
        }
        XCTAssertEqual(waitForCounters { $0.connectionsFailed == 1 }.connectionsFailed, 1)
    }

    func testTheDefaultTimeLimitForTheProxyIsFifteenSeconds() {
        XCTAssertEqual(NetworkLoop.Options().connectTimeout, 15)
        XCTAssertEqual(NetworkLoop.Options().maximumConnections, 2048)
    }

    func testConnectionsNeverTakeMoreThanHalfOfTheProcesssDescriptors() {
        // Every connection is a socket, and the app must be left able to open its own files.
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 256), 128)      // macOS's default
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 1024), 512)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 4096), 2048)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 1 << 20), 2048)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 200), 72)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 64), 16)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 3, descriptorLimit: 256), 3)
        XCTAssertGreaterThanOrEqual(Sys.descriptorLimit, 64)
    }

    /// Without a proxy elsewhere each connection holds three of the process's descriptors (the
    /// connector in the same process holds two more): a third as many connections.
    func testConnectionsThatHoldThreeDescriptorsAreAThirdAsMany() {
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 256, descriptorsPerConnection: 3), 42)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 8192, descriptorsPerConnection: 3), 1365)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 64, descriptorsPerConnection: 3), 16)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 4096, descriptorsPerConnection: 1), 2048)
        XCTAssertEqual(NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: 4096, descriptorsPerConnection: 0), 2048)
        XCTAssertEqual(NetworkLoop.Options().descriptorsPerConnection, 1)
        let network = VMNetwork(configuration: Wire.configuration(upstream: .none), frameDescriptor: -1)
        XCTAssertEqual(network.descriptorsPerConnection, 1)
        network.descriptorsPerConnection = 3
        XCTAssertEqual(network.options.descriptorsPerConnection, 3)
        network.descriptorsPerConnection = 0
        XCTAssertEqual(network.descriptorsPerConnection, 1)
    }

    func testAProxyThatIsNotThereIsRefusedAtOnce() throws {
        // A port nobody listens on.
        let (listener, port) = TestSocket.listen()
        Sys.close(listener)
        let guest = start(.socks5(host: "127.0.0.1", port: port, username: nil, password: nil))
        let address = try XCTUnwrap(guest.resolve("any.example")?.address)
        assertRefused(guest, address)
        XCTAssertEqual(waitForCounters { $0.connectionsFailed == 1 }.connectionsFailed, 1)
    }

    func testAProxyNamedByHostNameIsResolved() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream(host: "localhost"))
        let address = try XCTUnwrap(guest.resolve("via-name.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(connection.write([1, 2, 3]))
        connection.read(atLeast: 3)
        XCTAssertEqual(connection.takeReceived(), [1, 2, 3])
    }

    func testAProxyWhoseNameDoesNotResolveIsRefused() throws {
        let guest = start(.socks5(host: "no-such-proxy.invalid", port: 1080, username: nil, password: nil)) { $0.connectTimeout = 3 }
        let address = try XCTUnwrap(guest.resolve("any.example")?.address)
        switch GuestConnection.open(guest, to: address, timeout: 8, resend: 8) {
        case .refused(let seconds): XCTAssertLessThan(seconds, 4)
        default: XCTFail("not refused")
        }
    }

    // MARK: - HTTP CONNECT

    func testHTTPConnectWithoutCredentials() throws {
        let http = proxy(.http, origin: FakeProxy.echo)
        let guest = start(http.upstream())
        let address = try XCTUnwrap(guest.resolve("plain.example")?.address)
        let connection = try XCTUnwrap(open(guest, address, port: 8443))
        XCTAssertTrue(connection.write(Array("through the tunnel".utf8)))
        connection.read(atLeast: 18)
        XCTAssertEqual(connection.takeReceived(), Array("through the tunnel".utf8))
        let request = try XCTUnwrap(http.requests.value.first)
        XCTAssertEqual(request.lines, ["CONNECT plain.example:8443 HTTP/1.1", "Host: plain.example:8443", "Proxy-Connection: keep-alive"])
    }

    func testHTTPConnectWithCredentialsAndBytesRightBehindTheHeaders() throws {
        // The proxy's "200" and the tunnel's first bytes arrive in one read: the bytes are the tunnel's.
        let http = proxy(.http, credentials: ("bob", "pa:ss word"), afterHeaders: Array("early bytes".utf8), origin: FakeProxy.echo)
        let guest = start(http.upstream(username: "bob", password: "pa:ss word"))
        let address = try XCTUnwrap(guest.resolve("signed-in.example")?.address)
        let connection = try XCTUnwrap(open(guest, address, port: 443))
        connection.read(atLeast: 11)
        XCTAssertEqual(connection.takeReceived(), Array("early bytes".utf8))
        XCTAssertTrue(connection.write(Array("and back".utf8)))
        connection.read(atLeast: 8)
        XCTAssertEqual(connection.takeReceived(), Array("and back".utf8))
        let request = try XCTUnwrap(http.requests.value.first)
        XCTAssertEqual(request.lines, ["CONNECT signed-in.example:443 HTTP/1.1", "Host: signed-in.example:443",
                                       "Proxy-Authorization: Basic " + Data("bob:pa:ss word".utf8).base64EncodedString(),
                                       "Proxy-Connection: keep-alive"])
    }

    func testHTTPConnectRefusalsBecomeResets() throws {
        for behaviour in [FakeProxy.Behaviour.refuse(403), .refuse(502), .garbage(Array("\u{5}\u{0}".utf8)), .garbage(Array("SSH-2.0-OpenSSH\r\n\r\n".utf8))] {
            let http = proxy(.http, behaviour: behaviour)
            let guest = start(http.upstream())
            let address = try XCTUnwrap(guest.resolve("refused.example")?.address)
            assertRefused(guest, address)
            XCTAssertEqual(waitForCounters { $0.connectionsFailed == 1 }.connectionsFailed, 1)
            tearDown()
        }
        // A sign-in is asked for and the profile has none; and one that is wrong.
        for password in [nil, "wrong"] as [String?] {
            let http = proxy(.http, credentials: ("bob", "right"))
            let guest = start(http.upstream(username: password == nil ? nil : "bob", password: password))
            let address = try XCTUnwrap(guest.resolve("refused.example")?.address)
            assertRefused(guest, address)
            tearDown()
        }
    }

    // MARK: - Where a connection may go

    func testALiteralPublicAddressIsAskedOfTheProxyAsAnAddress() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        var guest = start(socks.upstream())
        var connection = try XCTUnwrap(open(guest, VMNetIPv4(string: "93.184.216.34")!, port: 8080))
        XCTAssertTrue(connection.write([9]))
        connection.read(atLeast: 1)
        XCTAssertEqual(socks.requests.value, [FakeProxy.Request(host: "93.184.216.34", port: 8080, byName: false)])
        tearDown()

        let http = proxy(.http, origin: FakeProxy.echo)
        guest = start(http.upstream())
        connection = try XCTUnwrap(open(guest, VMNetIPv4(string: "93.184.216.34")!, port: 8080))
        XCTAssertTrue(connection.write([9]))
        connection.read(atLeast: 1)
        XCTAssertEqual(http.requests.value.first?.lines.first, "CONNECT 93.184.216.34:8080 HTTP/1.1")
    }

    func testAddressesThatAreNotThePublicInternetNeverReachTheProxy() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream())
        for address in ["10.0.0.1", "172.16.5.5", "192.168.0.10", "192.168.1.1", "192.168.1.77", "127.0.0.1", "169.254.169.254",
                        "100.64.0.1", "224.0.0.1", "240.0.0.1", "0.0.0.1", "198.18.5.5", "198.19.255.254"] {
            assertRefused(guest, VMNetIPv4(string: address)!)
        }
        // A name that was never resolved has no fake address either; one that was, connects.
        XCTAssertEqual(socks.accepted.value, 0)
        XCTAssertEqual(socks.requests.value, [])
        let counters = waitForCounters { _ in true }
        XCTAssertEqual(counters.connectionsOpened, 0)
        // Refused by the stack's own rules, not by the proxy: not counted as the proxy's failures.
        XCTAssertEqual(counters.connectionsFailed, 0)
    }

    func testWithNoProxyEveryConnectionIsRefusedAtOnce() throws {
        let guest = start(.none)
        let address = try XCTUnwrap(guest.resolve("any.example")?.address)
        assertRefused(guest, address)
        assertRefused(guest, VMNetIPv4(string: "93.184.216.34")!)
        let counters = waitForCounters { $0.connectionsFailed == 2 }
        XCTAssertEqual(counters.connectionsFailed, 2)
        XCTAssertEqual(counters.connectionsOpened, 0)
    }

    func testASegmentForNoConnectionIsAnsweredWithAReset() throws {
        let guest = start(.none)
        let port = guest.freshPort()
        guest.send(Wire.tcp(from: port, to: VMNetIPv4(string: "93.184.216.34")!, 80, sequence: 500, acknowledgement: 900, flags: [.ack], payload: [1]))
        let reset = try XCTUnwrap(guest.expect { Wire.seenTCP($0) })
        XCTAssertEqual(reset.flags, [.rst])
        XCTAssertEqual(reset.sequence, 900)
        // A reset for no connection is not answered: two stacks must not reset each other forever.
        guest.send(Wire.tcp(from: port, to: VMNetIPv4(string: "93.184.216.34")!, 80, sequence: 500, flags: [.rst]))
        XCTAssertTrue(guest.hearsNothing(for: 0.2))
    }

    // MARK: - Data, both ways

    func testTwoMegabytesEachWayThroughAnEcho() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("echo.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        let data = bytes(2_000_000, seed: 21)
        var echoed: [UInt8] = []
        echoed.reserveCapacity(data.count)
        // In pieces, so that what comes back is read while more is sent.
        for start in stride(from: 0, to: data.count, by: 100_000) {
            XCTAssertTrue(connection.write(Array(data[start..<(start + 100_000)])))
            echoed += connection.takeReceived()
        }
        connection.read(atLeast: data.count - echoed.count, timeout: 20)
        echoed += connection.takeReceived()
        XCTAssertEqual(echoed.count, data.count)
        XCTAssertTrue(echoed == data, "the echo differs")
        XCTAssertTrue(connection.close())
        connection.readToEnd()
        let counters = waitForCounters { $0.connectionsActive == 0 && $0.bytesToGuest == 2_000_000 }
        XCTAssertEqual(counters.bytesFromGuest, 2_000_000)
        XCTAssertEqual(counters.bytesToGuest, 2_000_000)
        XCTAssertEqual(counters.connectionsActive, 0)
    }

    func testAGuestThatReadsSlowlyLosesNothing() throws {
        // Three megabytes pushed at a guest that does not read for a while: the wire fills, the
        // stack holds its frames back and reads no more from the proxy than it can keep.
        let body = bytes(3_000_000, seed: 31)
        let socks = proxy(.socks5, origin: FakeProxy.httpOrigin(body: body))
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("big.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(connection.write(Array("GET / HTTP/1.1\r\n\r\n".utf8)))
        Thread.sleep(forTimeInterval: 0.5)
        connection.readToEnd(timeout: 30)
        let response = connection.takeReceived()
        XCTAssertTrue(connection.peerFinished)
        let head = Array("HTTP/1.1 200 OK\r\nContent-Length: 3000000\r\nConnection: close\r\n\r\n".utf8)
        XCTAssertEqual(response.count, head.count + body.count)
        XCTAssertTrue(Array(response.suffix(body.count)) == body, "the bytes differ")
    }

    func testAWireThatLosesFramesStillDeliversEverything() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream()) {
            $0.lossToGuest = 0.03
            $0.lossFromGuest = 0.03
        }
        // DNS is not sent again by the stack: the guest asks until it is answered.
        var resolved: VMNetIPv4?
        for _ in 0..<20 where resolved == nil {
            resolved = guest.expectResolve("lossy.example")
        }
        let address = try XCTUnwrap(resolved)
        var opened: GuestConnection?
        for _ in 0..<5 where opened == nil {
            if case .open(let connection) = GuestConnection.open(guest, to: address, timeout: 10, resend: 0.5) { opened = connection }
        }
        let connection = try XCTUnwrap(opened)
        let data = bytes(150_000, seed: 41)
        XCTAssertTrue(connection.write(data))
        connection.read(atLeast: data.count, timeout: 60)
        let echoed = connection.takeReceived()
        XCTAssertEqual(echoed.count, data.count)
        XCTAssertTrue(echoed == data, "the echo differs")
    }

    // MARK: - Timers, with nothing else going on

    func testUnacknowledgedDataIsSentAgainOnAQuietWire() throws {
        // The guest takes the proxy's bytes and never acknowledges them, and nothing else happens
        // on the wire: only the loop's own timer can send them again — after a quarter of a
        // second, then half a second, then a second.
        let socks = proxy(.socks5, origin: { connection in
            TestSocket.write(connection, Array("is anybody there?".utf8))
            _ = TestSocket.readToEnd(connection, timeout: 10)
        })
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("quiet.example")?.address)
        _ = try XCTUnwrap(open(guest, address))
        var times: [Double] = []
        let began = Sys.now
        while times.count < 4 && Sys.now - began < 5 {
            guard let frame = guest.receive(timeout: 3), let seen = Wire.seenTCP(frame), !seen.payload.isEmpty else { continue }
            XCTAssertEqual(seen.payload, Array("is anybody there?".utf8))
            times.append(Sys.now)
        }
        XCTAssertEqual(times.count, 4)
        guard times.count == 4 else { return }
        // Not before its time, and not much after (a busy machine may be late, never early).
        for (index, wait) in [0.25, 0.5, 1.0].enumerated() {
            let gap = times[index + 1] - times[index]
            XCTAssertGreaterThanOrEqual(gap, wait * 0.8, "retransmission \(index + 1) came early")
            XCTAssertLessThan(gap, wait + 1.0, "retransmission \(index + 1) came late")
        }
    }

    func testAnUnansweredSynAckIsSentAgainOnAQuietWire() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream()) { $0.tcp.handshakeTimeout = 0.2 }
        let address = try XCTUnwrap(guest.resolve("quiet.example")?.address)
        let port = guest.freshPort()
        guest.send(Wire.tcp(from: port, to: address, 80, sequence: 9_000, flags: [.syn], options: Wire.synOptions()))
        var answers: [SeenTCP] = []
        let began = Sys.now
        while answers.count < 3 && Sys.now - began < 5 {
            if let frame = guest.receive(timeout: 3), let seen = Wire.seenTCP(frame) { answers.append(seen) }
        }
        XCTAssertEqual(answers.map(\.flags), [[.syn, .ack], [.syn, .ack], [.syn, .ack]])
        XCTAssertEqual(Set(answers.map(\.sequence)).count, 1)
    }

    func testALingeringConnectionIsForgottenOnAQuietWire() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream()) { $0.tcp.linger = 1.0 }
        let address = try XCTUnwrap(guest.resolve("linger.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(connection.close())
        connection.readToEnd()
        // While it lingers, the guest's FIN again is acknowledged again; afterwards the
        // connection is unknown and the same segment gets a reset.
        let fin = Wire.tcp(from: connection.localPort, to: address, 80, sequence: connection.sendNext &- 1,
                           acknowledgement: connection.receiveNext, flags: [.ack, .fin])
        guest.send(fin)
        XCTAssertEqual(guest.expect(timeout: 1) { Wire.seenTCP($0) }?.flags, [.ack])
        Thread.sleep(forTimeInterval: 1.5)
        guest.send(fin)
        XCTAssertEqual(guest.expect(timeout: 2) { Wire.seenTCP($0) }?.flags, [.rst])
    }

    // MARK: - A guest that sends rubbish

    func testANetworkSurvivesDamagedFramesAndStillWorks() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream())
        // A good connection first, kept open while the rubbish flies.
        let address = try XCTUnwrap(guest.resolve("steady.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(connection.write(Array("before".utf8)))
        connection.read(atLeast: 6)
        XCTAssertEqual(connection.takeReceived(), Array("before".utf8))

        var random = TestRandom(seed: 99)
        let frames = HostileFrames.valid()
        for round in 0..<30_000 {
            guest.send(HostileFrames.next(from: frames, &random))
            // What comes back is read and thrown away, so that the wire does not fill up.
            if round % 64 == 0 { while guest.receive(timeout: 0) != nil {} }
        }
        while guest.receive(timeout: 0.2) != nil {}

        // The network is still there: the thread runs, names resolve, a new connection carries data.
        XCTAssertEqual(guest.arpForGateway(), Wire.gatewayMAC)
        let other = try XCTUnwrap(guest.resolve("after.example")?.address)
        let fresh = try XCTUnwrap(open(guest, other))
        XCTAssertTrue(fresh.write(Array("after".utf8)))
        fresh.read(atLeast: 5)
        XCTAssertEqual(fresh.takeReceived(), Array("after".utf8))
        // Some of the rubbish was good enough to open connections of its own: they are counted,
        // and none of them took the good one's place.
        let counters = network!.counters()
        XCTAssertGreaterThanOrEqual(counters.connectionsOpened, 2)
        XCTAssertLessThanOrEqual(counters.connectionsActive, 2048)
    }

    // MARK: - Closing

    func testTheGuestClosesItsSideAndStillGetsTheAnswer() throws {
        let seen = Locked<[UInt8]>([])
        let reply = Array("the answer, after the question ended".utf8)
        let socks = proxy(.socks5, origin: FakeProxy.collector(reply: reply) { all in seen.value = all })
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("half.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        let question = bytes(50_000, seed: 51)
        XCTAssertTrue(connection.write(question))
        // The guest's FIN: the origin sees the end of the question only now, and answers.
        XCTAssertTrue(connection.close())
        connection.readToEnd()
        XCTAssertTrue(connection.peerFinished)
        XCTAssertEqual(connection.takeReceived(), reply)
        XCTAssertTrue(seen.value == question)
        XCTAssertEqual(waitForCounters { $0.connectionsActive == 0 }.connectionsActive, 0)
    }

    func testTheGuestsResetClosesTheTunnel() throws {
        let ended = Locked(false)
        let socks = proxy(.socks5, origin: { connection in
            _ = TestSocket.readToEnd(connection, timeout: 10)
            ended.value = true
        })
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("reset.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(connection.write([1, 2, 3]))
        connection.reset()
        let deadline = Sys.now + 3
        while !ended.value && Sys.now < deadline { usleep(2_000) }
        XCTAssertTrue(ended.value, "the proxy's connection stayed open")
        XCTAssertEqual(waitForCounters { $0.connectionsActive == 0 }.connectionsActive, 0)
    }

    func testAResetFromTheProxyResetsTheGuest() throws {
        let socks = proxy(.socks5, origin: { connection in
            _ = TestSocket.read(connection, timeout: 5)
            // Closing with unread data pending and no lingering sends a reset, not a FIN.
            var option = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(connection, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
        })
        let guest = start(socks.upstream())
        let address = try XCTUnwrap(guest.resolve("broken.example")?.address)
        let connection = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(connection.write([1, 2, 3]))
        XCTAssertTrue(connection.waitForReset())
        XCTAssertEqual(waitForCounters { $0.connectionsActive == 0 }.connectionsActive, 0)
    }

    func testNoMoreConnectionsThanTheLimit() throws {
        let socks = proxy(.socks5, origin: FakeProxy.echo)
        let guest = start(socks.upstream()) { $0.maximumConnections = 3 }
        let address = try XCTUnwrap(guest.resolve("many.example")?.address)
        var connections: [GuestConnection] = []
        for _ in 0..<3 { connections.append(try XCTUnwrap(open(guest, address))) }
        assertRefused(guest, address)
        XCTAssertEqual(waitForCounters { $0.connectionsActive == 3 }.connectionsActive, 3)
        // One ends (both sides close); its place is free again, though it still lingers.
        XCTAssertTrue(connections[0].close())
        connections[0].readToEnd()
        let again = try XCTUnwrap(open(guest, address))
        XCTAssertTrue(again.write([5]))
        again.read(atLeast: 1)
        XCTAssertEqual(again.takeReceived(), [5])
        XCTAssertEqual(socks.accepted.value, 4)
    }

    // MARK: - Starting and stopping

    func testStopClosesEveryConnectionAndLeaksNoDescriptor() throws {
        let ended = Locked(0)
        let socks = proxy(.socks5, origin: { connection in
            _ = TestSocket.readToEnd(connection, timeout: 10)
            ended.update { $0 += 1 }
        })
        // The descriptors open before the network exists: the test's own, the proxy's listener.
        let (first, second) = TestSocket.datagramPair()
        stackEnd = first
        guestEnd = second
        let before = TestSocket.openDescriptorCount()
        let network = VMNetwork(configuration: Wire.configuration(upstream: socks.upstream()), frameDescriptor: first)
        self.network = network
        network.start()
        let guest = TestGuest(descriptor: second)
        let address = try XCTUnwrap(guest.resolve("held.example")?.address)
        var connections: [GuestConnection] = []
        for _ in 0..<5 { connections.append(try XCTUnwrap(open(guest, address))) }
        XCTAssertEqual(waitForCounters { $0.connectionsActive == 5 }.connectionsActive, 5)

        network.stop()
        // The proxy sees all five end.
        let deadline = Sys.now + 3
        while ended.value < 5 && Sys.now < deadline { usleep(2_000) }
        XCTAssertEqual(ended.value, 5)
        XCTAssertEqual(network.counters().connectionsActive, 0)
        XCTAssertEqual(network.counters().connectionsOpened, 5)
        // The proxy's own ends of those connections close a moment later; then nothing is left
        // of the network: no socket to the proxy, no pipe.
        var after = TestSocket.openDescriptorCount()
        while after > before && Sys.now < deadline + 3 {
            usleep(5_000)
            after = TestSocket.openDescriptorCount()
        }
        XCTAssertEqual(after, before)
        // The wire is the caller's and still open: the guest can still write to it.
        XCTAssertGreaterThanOrEqual(fcntl(first, F_GETFD, 0), 0)
    }

    func testStartAndStopInAnyOrder() throws {
        let (first, second) = TestSocket.datagramPair()
        stackEnd = first
        guestEnd = second
        let network = VMNetwork(configuration: Wire.configuration(), frameDescriptor: first)
        self.network = network
        // Stop before start, and twice: nothing.
        network.stop()
        network.stop()
        XCTAssertEqual(network.counters(), VMNetCounters())
        // Start twice: one network, which answers.
        network.start()
        network.start()
        let guest = TestGuest(descriptor: second)
        XCTAssertEqual(guest.arpForGateway(), Wire.gatewayMAC)
        XCTAssertEqual(guest.resolve("one.example")?.code, 0)
        network.stop()
        network.stop()
        XCTAssertEqual(network.counters().dnsQueries, 1)
        // Stopped, it answers nothing.
        let request = ARPPacket(operation: ARPPacket.request, senderMAC: Wire.guestMAC, senderAddress: Wire.guest,
                                targetMAC: VMNetMAC(raw: 0), targetAddress: Wire.gateway)
        guest.send(request.frame(destination: .broadcast, source: Wire.guestMAC))
        XCTAssertTrue(guest.hearsNothing(for: 0.2))
        // Started again it does — the frame that waited included — and the counters go on.
        network.start()
        XCTAssertNotNil(guest.receive(timeout: 2))
        XCTAssertEqual(guest.resolve("two.example")?.code, 0)
        network.stop()
        XCTAssertEqual(network.counters().dnsQueries, 2)
    }

    func testManyStartsAndStopsFromSeveralThreads() {
        let (first, second) = TestSocket.datagramPair()
        stackEnd = first
        guestEnd = second
        let network = VMNetwork(configuration: Wire.configuration(), frameDescriptor: first)
        self.network = network
        let before = TestSocket.openDescriptorCount()
        let done = Locked(0)
        for index in 0..<4 {
            let thread = Thread {
                for round in 0..<25 {
                    if (index + round) % 2 == 0 { network.start() } else { network.stop() }
                    _ = network.counters()
                }
                done.update { $0 += 1 }
            }
            thread.start()
        }
        let deadline = Sys.now + 20
        while done.value < 4 && Sys.now < deadline { usleep(5_000) }
        XCTAssertEqual(done.value, 4)
        network.stop()
        XCTAssertEqual(TestSocket.openDescriptorCount(), before)
    }

    func testAnObjectThatIsLetGoStopsItsNetwork() {
        let (first, second) = TestSocket.datagramPair()
        stackEnd = first
        guestEnd = second
        let before = TestSocket.openDescriptorCount()
        do {
            let network = VMNetwork(configuration: Wire.configuration(), frameDescriptor: first)
            network.start()
            XCTAssertEqual(TestGuest(descriptor: second).arpForGateway(), Wire.gatewayMAC)
            XCTAssertGreaterThan(TestSocket.openDescriptorCount(), before)
        }
        XCTAssertEqual(TestSocket.openDescriptorCount(), before)
    }

    // MARK: - The proxy's address

    func testAnAddressWrittenOutNeedsNoResolver() {
        let resolver = ProxyResolver(host: "127.0.0.1", port: 1080)
        let snapshot = resolver.snapshot
        XCTAssertEqual(snapshot.addresses.count, 1)
        XCTAssertEqual(snapshot.addresses.first?.family, AF_INET)
        XCTAssertFalse(snapshot.isResolving)
        // A failed connection does not send it looking: the address is what was written.
        resolver.connectionFailed()
        let called = Locked(false)
        resolver.resolveIfNeeded(now: 100) { called.value = true }
        XCTAssertFalse(resolver.snapshot.isResolving)
        XCTAssertEqual(resolver.snapshot.answerCount, snapshot.answerCount)
        XCTAssertEqual(ProxyResolver(host: "::1", port: 1080).snapshot.addresses.first?.family, AF_INET6)
    }

    func testANameIsResolvedOffTheCallersThreadAndAgainAfterAFailure() {
        let resolver = ProxyResolver(host: "localhost", port: 1080)
        XCTAssertTrue(resolver.snapshot.addresses.isEmpty)
        let answers = Locked(0)
        func wait(for count: Int) {
            let deadline = Sys.now + 10
            while answers.value < count && Sys.now < deadline { usleep(2_000) }
        }
        resolver.resolveIfNeeded(now: 100) { answers.update { $0 += 1 } }
        // A second request while the first is on its way starts nothing.
        resolver.resolveIfNeeded(now: 100) { answers.update { $0 += 1 } }
        wait(for: 1)
        XCTAssertEqual(answers.value, 1)
        XCTAssertFalse(resolver.snapshot.addresses.isEmpty)
        XCTAssertEqual(resolver.snapshot.answerCount, 1)
        // The answer is good until a connection fails.
        resolver.resolveIfNeeded(now: 200) { answers.update { $0 += 1 } }
        XCTAssertFalse(resolver.snapshot.isResolving)
        resolver.connectionSucceeded(index: 0)
        resolver.connectionFailed()
        // Then it is looked up again — but not within two seconds of the last lookup — and the
        // old answer stays in use meanwhile.
        resolver.resolveIfNeeded(now: 101) { answers.update { $0 += 1 } }
        XCTAssertFalse(resolver.snapshot.isResolving)
        resolver.resolveIfNeeded(now: 103) { answers.update { $0 += 1 } }
        XCTAssertFalse(resolver.snapshot.addresses.isEmpty)
        wait(for: 2)
        XCTAssertEqual(answers.value, 2)
        XCTAssertEqual(resolver.snapshot.answerCount, 2)
        XCTAssertFalse(resolver.snapshot.addresses.isEmpty)
    }

    // MARK: - The log

    func testTheLogHoldsCountsAndReasonsAndNothingPrivate() throws {
        let socks = proxy(.socks5, credentials: ("the-user-name", "the-pass-word"), behaviour: .refuse(5))
        let guest = start(socks.upstream(username: "the-user-name", password: "the-pass-word"), blocked: ["blocked-host.example"])
        let address = try XCTUnwrap(guest.resolve("secret-site.example")?.address)
        _ = guest.resolve("www.blocked-host.example")
        assertRefused(guest, address)
        assertRefused(guest, VMNetIPv4(string: "10.20.30.40")!)
        assertRefused(guest, VMNetIPv4(string: "93.184.216.34")!)
        _ = waitForCounters { $0.connectionsFailed == 2 }
        network?.stop()
        let lines = logLines.value
        XCTAssertFalse(lines.isEmpty)
        // It says what happened…
        XCTAssertTrue(lines.contains { $0.contains("network started") && $0.contains("SOCKS5 proxy with a sign-in") })
        XCTAssertTrue(lines.contains { $0.contains("the proxy refused (code 5)") })
        XCTAssertTrue(lines.contains { $0.contains("not a public address") })
        XCTAssertTrue(lines.contains { $0.contains("network stopped") && $0.contains("failed 2;") })
        // …and not where the guest was going, nor who signs in to the proxy, nor where the proxy is.
        let forbidden = ["secret-site", "blocked-host", "example", address.string, "198.18.", "10.20.30.40", "93.184.216.34",
                         "the-user-name", "the-pass-word", "127.0.0.1", ":\(socks.port)", "\(socks.port)"]
        for line in lines {
            for word in forbidden {
                XCTAssertFalse(line.contains(word), "the log line \"\(line)\" holds \"\(word)\"")
            }
        }
    }
}

private extension TestGuest {
    /// One try at an address query: nil when no answer came in half a second.
    func expectResolve(_ name: String) -> VMNetIPv4? {
        let port = freshPort()
        send(Wire.udp(from: port, to: Wire.gateway, 53, payload: Wire.dnsQuery(name, id: port)))
        return expect(timeout: 0.5) { frame in
            guard let udp = Wire.seenUDP(frame), udp.sourcePort == 53, udp.destinationPort == port else { return nil }
            return Wire.dnsAnswer(udp.payload).address
        }
    }
}
