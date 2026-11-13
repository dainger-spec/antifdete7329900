#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// The way out of a machine without a proxy (`VMNetDirectConnector`): a SOCKS5 server on loopback
/// that makes the guest's connections as this process's own. Real sockets on loopback; the
/// destinations are servers of the tests.
final class DirectConnectorTests: XCTestCase {
    private var connectors: [VMNetDirectConnector] = []
    private var descriptors: [Int32] = []
    private var network: VMNetwork?

    override func tearDown() {
        network?.stop()
        network = nil
        for connector in connectors { connector.stop() }
        connectors = []
        for descriptor in descriptors { Sys.close(descriptor) }
        descriptors = []
        super.tearDown()
    }

    /// A connector that may reach this machine (the tests' servers are on loopback), and knows
    /// `names` without asking a resolver.
    private func connector(local: Bool = true, names: [String: [String]] = [:]) throws -> VMNetDirectConnector {
        let connector = VMNetDirectConnector(allowsLocalDestinations: local) { names[$0] }
        connectors.append(connector)
        XCTAssertGreaterThan(try connector.start(), 0)
        return connector
    }

    private func listener() -> (descriptor: Int32, port: Int) {
        let made = TestSocket.listen()
        descriptors.append(made.descriptor)
        return made
    }

    /// A connection to a port of this machine.
    private func dial(_ port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        XCTAssertEqual(getaddrinfo("127.0.0.1", String(port), &hints, &list), 0)
        defer { freeaddrinfo(list) }
        let entry = try XCTUnwrap(list)
        let descriptor = socket(AF_INET, Sys.streamType, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        descriptors.append(descriptor)
        Sys.setNoSigPipe(descriptor)
        #if canImport(Darwin)
        let status = Darwin.connect(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen)
        #else
        let status = Glibc.connect(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen)
        #endif
        XCTAssertEqual(status, 0, "no connection to port \(port)")
        return descriptor
    }

    /// SOCKS5's greeting and a CONNECT, as the machine's network sends them; the reply's code.
    private func ask(_ client: Int32, address: [UInt8]? = nil, name: String? = nil, port: Int, timeout: Double = 5) -> UInt8? {
        TestSocket.write(client, [5, 1, 0])
        guard TestSocket.read(client, exactly: 2) == [5, 0] else { return nil }
        var request: [UInt8] = [5, 1, 0]
        if let address {
            request += [1] + address
        } else if let name {
            request += [3, UInt8(name.utf8.count)] + Array(name.utf8)
        }
        request += [UInt8(port >> 8), UInt8(port & 0xFF)]
        TestSocket.write(client, request)
        guard let reply = TestSocket.read(client, exactly: 10, timeout: timeout), reply[0] == 5 else { return nil }
        return reply[1]
    }

    // MARK: - A connection

    func testAConnectionIsCarriedBothWaysAndHalfClosed() throws {
        let origin = listener()
        let connector = try connector()
        let client = try dial(connector.port)
        XCTAssertEqual(ask(client, address: [127, 0, 0, 1], port: origin.port), 0)
        let served = TestSocket.accept(origin.descriptor, timeout: 3)
        XCTAssertGreaterThanOrEqual(served, 0)
        descriptors.append(served)

        TestSocket.write(client, Array("ping".utf8))
        XCTAssertEqual(TestSocket.read(served, exactly: 4), Array("ping".utf8))
        TestSocket.write(served, Array("pong".utf8))
        XCTAssertEqual(TestSocket.read(client, exactly: 4), Array("pong".utf8))

        // Megabytes each way, byte for byte.
        var random = TestRandom(seed: 5)
        let up = random.bytes(600_000), down = random.bytes(900_000)
        let sender = Thread { TestSocket.write(client, up, timeout: 20) }
        sender.start()
        XCTAssertTrue(TestSocket.read(served, exactly: up.count, timeout: 20) == up)
        let answerer = Thread { TestSocket.write(served, down, timeout: 20) }
        answerer.start()
        XCTAssertTrue(TestSocket.read(client, exactly: down.count, timeout: 20) == down)

        // The guest has said all it had: the origin hears the end, and its answer still arrives.
        XCTAssertEqual(shutdown(client, Int32(SHUT_WR)), 0)
        XCTAssertEqual(TestSocket.readToEnd(served, timeout: 5), [])
        TestSocket.write(served, Array("bye".utf8))
        XCTAssertEqual(shutdown(served, Int32(SHUT_WR)), 0)
        XCTAssertEqual(TestSocket.readToEnd(client, timeout: 5), Array("bye".utf8))
    }

    func testANameIsResolvedOnThisSide() throws {
        let origin = listener()
        let connector = try connector(names: ["origin.example": ["127.0.0.1"]])
        let client = try dial(connector.port)
        XCTAssertEqual(ask(client, name: "origin.example", port: origin.port), 0)
        let served = TestSocket.accept(origin.descriptor, timeout: 3)
        XCTAssertGreaterThanOrEqual(served, 0)
        descriptors.append(served)
        TestSocket.write(client, Array("hello".utf8))
        XCTAssertEqual(TestSocket.read(served, exactly: 5), Array("hello".utf8))
    }

    // MARK: - What is refused

    /// A guest must not reach this Mac's own services, or its local network, by naming them.
    func testThisMachineAndLocalNetworksAreRefused() throws {
        let origin = listener()
        let connector = try connector(local: false, names: ["inside.example": ["127.0.0.1"], "lan.example": ["192.168.1.10"]])
        for (address, name) in [([127, 0, 0, 1] as [UInt8]?, nil as String?), (nil, "inside.example"), (nil, "lan.example"),
                                ([10, 0, 0, 5], nil), ([169, 254, 169, 254], nil), (nil, "localhost")] {
            let client = try dial(connector.port)
            let started = Sys.now
            let code = ask(client, address: address, name: name, port: origin.port)
            XCTAssertEqual(code, 5, "\(address.map { "\($0)" } ?? name ?? "") was not refused")
            XCTAssertLessThan(Sys.now - started, 3, "refused, but late")
        }
        XCTAssertEqual(TestSocket.accept(origin.descriptor, timeout: 0.3), -1, "the origin on this machine was reached")
    }

    func testADestinationThatIsNotThereIsRefusedAtOnce() throws {
        // A port nobody listens on: one that was just closed.
        let gone = TestSocket.listen()
        Sys.close(gone.descriptor)
        let connector = try connector()
        let client = try dial(connector.port)
        let started = Sys.now
        XCTAssertEqual(ask(client, address: [127, 0, 0, 1], port: gone.port), 5)
        XCTAssertLessThan(Sys.now - started, 3)
        // And a name with no address at all.
        let second = try dial(connector.port)
        XCTAssertEqual(ask(second, name: "nowhere.example", port: 80, timeout: 25), 5)
    }

    func testOnlyAConnectIsTaken() throws {
        let connector = try connector()
        // Not SOCKS5 at all: no answer, and the connection is closed.
        let stranger = try dial(connector.port)
        TestSocket.write(stranger, Array("GET / HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(TestSocket.readToEnd(stranger, timeout: 3), [])
        // A sign-in is not offered: a client that has only that is told so.
        let signer = try dial(connector.port)
        TestSocket.write(signer, [5, 1, 2])
        XCTAssertEqual(TestSocket.read(signer, exactly: 2), [5, 0xFF])
        // BIND (2) is not CONNECT.
        let binder = try dial(connector.port)
        TestSocket.write(binder, [5, 1, 0])
        XCTAssertEqual(TestSocket.read(binder, exactly: 2), [5, 0])
        TestSocket.write(binder, [5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
        XCTAssertEqual(TestSocket.read(binder, exactly: 10)?[1], 7)
    }

    func testWhichIPv6AddressesArePublic() {
        func address(_ text: String) -> [UInt8] {
            var storage = in6_addr()
            XCTAssertEqual(inet_pton(AF_INET6, text, &storage), 1, text)
            return withUnsafeBytes(of: storage) { Array($0) }
        }
        for text in ["2606:4700:4700::1111", "2a00:1450:4001:81b::200e", "::ffff:8.8.8.8"] {
            XCTAssertTrue(VMNetDirectConnector.isPublicIPv6(address(text)), text)
        }
        for text in ["::", "::1", "fe80::1", "febf::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1",
                     "::ffff:192.168.1.1", "::ffff:10.0.0.1", "::8.8.8.8"] {
            XCTAssertFalse(VMNetDirectConnector.isPublicIPv6(address(text)), text)
        }
        XCTAssertFalse(VMNetDirectConnector.isPublicIPv6([1, 2, 3]))
    }

    // MARK: - Its life

    func testStopCutsWhatIsUnderWayAndItStartsAgain() throws {
        let origin = listener()
        let connector = try connector()
        let port = connector.port
        let client = try dial(port)
        XCTAssertEqual(ask(client, address: [127, 0, 0, 1], port: origin.port), 0)
        let served = TestSocket.accept(origin.descriptor, timeout: 3)
        descriptors.append(served)
        XCTAssertThrowsError(try connector.start(), "started twice")

        connector.stop()
        XCTAssertEqual(connector.port, 0)
        XCTAssertEqual(TestSocket.readToEnd(client, timeout: 3), [], "the guest's side was not closed")
        XCTAssertEqual(TestSocket.readToEnd(served, timeout: 3), [], "the origin's side was not closed")
        connector.stop()

        XCTAssertGreaterThan(try connector.start(), 0)
        let again = try dial(connector.port)
        XCTAssertEqual(ask(again, address: [127, 0, 0, 1], port: origin.port), 0)
    }

    // MARK: - With the machine's network

    /// The whole way of a machine without a proxy: the guest gets its address, resolves a name
    /// (a fake address stands for it), connects — and the network asks the connector for that
    /// name, which this side resolves and connects to. A page comes back byte for byte.
    func testAGuestWithoutAProxyLoadsAPageThroughTheConnector() throws {
        var random = TestRandom(seed: 9)
        let body = random.bytes(300_000)
        let origin = listener()
        let handler = FakeProxy.httpOrigin(body: body)
        let server = Thread {
            let connection = TestSocket.accept(origin.descriptor, timeout: 10)
            guard connection >= 0 else { return }
            handler(connection)
            Sys.close(connection)
        }
        server.start()

        let connector = try connector(names: ["www.example.com": ["127.0.0.1"]])
        let (stackEnd, guestEnd) = TestSocket.datagramPair()
        descriptors += [stackEnd, guestEnd]
        let network = VMNetwork(configuration: Wire.configuration(upstream: connector.upstream), frameDescriptor: stackEnd)
        network.start()
        self.network = network
        let guest = TestGuest(descriptor: guestEnd)

        XCTAssertEqual(try XCTUnwrap(guest.dhcp()).address, Wire.guest)
        XCTAssertEqual(guest.arpForGateway(), Wire.gatewayMAC)
        let address = try XCTUnwrap(try XCTUnwrap(guest.resolve("www.example.com")).address)
        XCTAssertTrue(FakeAddressPool.contains(address))

        guard case .open(let connection) = GuestConnection.open(guest, to: address, port: UInt16(origin.port)) else {
            return XCTFail("the connection did not open")
        }
        XCTAssertTrue(connection.write(Array("GET / HTTP/1.1\r\nHost: www.example.com\r\n\r\n".utf8)))
        connection.readToEnd(timeout: 20)
        let response = connection.takeReceived()
        let head = Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        XCTAssertEqual(response.count, head.count + body.count)
        XCTAssertTrue(Array(response.dropFirst(head.count)) == body, "the page's bytes differ")
        XCTAssertTrue(connection.close())

        // A name the connector has no public address for: the guest's connection is refused.
        let hidden = try XCTUnwrap(try XCTUnwrap(guest.resolve("nowhere.example")).address)
        guard case .refused = GuestConnection.open(guest, to: hidden, port: 80, timeout: 30) else {
            return XCTFail("a name with no address was not refused")
        }
    }
}
