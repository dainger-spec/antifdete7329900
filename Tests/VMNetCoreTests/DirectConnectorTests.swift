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
    /// The connector's port each connection of the test's was made to: whose sign-in it gives.
    private var dialed: [Int32: Int] = [:]
    private var network: VMNetwork?

    override func tearDown() {
        network?.stop()
        network = nil
        for connector in connectors { connector.stop() }
        connectors = []
        for descriptor in descriptors { Sys.close(descriptor) }
        descriptors = []
        dialed = [:]
        super.tearDown()
    }

    /// A connector that may reach this machine (the tests' servers are on loopback), and knows
    /// `names` without asking a resolver.
    private func connector(local: Bool = true, names: [String: [String]] = [:]) throws -> VMNetDirectConnector {
        // A private address's route is not asked of the system here (no address of the tests' is
        // sent into a tunnel): the system's own answer has a test of its own, and on a Mac the
        // question, asked of an address near enough, is a use of the local network.
        let connector = VMNetDirectConnector(allowsLocalDestinations: local, routesIntoTunnel: { _ in false }) { names[$0] }
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
        dialed[descriptor] = port
        return descriptor
    }

    /// SOCKS5's greeting and sign-in with the user name and password the connector gives the
    /// machine's network (`upstream`), as that network sends them: whether they were taken.
    private func signIn(_ client: Int32) -> Bool {
        guard let connector = connectors.first(where: { $0.port == dialed[client] }),
              case .socks5(_, _, let username?, let password?) = connector.upstream else { return false }
        TestSocket.write(client, [5, 2, 0, 2])
        guard TestSocket.read(client, exactly: 2) == [5, 2] else { return false }
        let user = Array(username.utf8), secret = Array(password.utf8)
        TestSocket.write(client, [1, UInt8(user.count)] + user + [UInt8(secret.count)] + secret)
        return TestSocket.read(client, exactly: 2) == [1, 0]
    }

    /// SOCKS5's greeting, the sign-in and a CONNECT, as the machine's network sends them; the
    /// reply's code.
    private func ask(_ client: Int32, address: [UInt8]? = nil, name: String? = nil, port: Int, timeout: Double = 5) -> UInt8? {
        guard signIn(client) else { return nil }
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
        // BIND (2) is not CONNECT.
        let binder = try dial(connector.port)
        XCTAssertTrue(signIn(binder))
        TestSocket.write(binder, [5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
        XCTAssertEqual(TestSocket.read(binder, exactly: 10)?[1], 7)
    }

    /// Any process on this Mac reaches a port on loopback: the connector takes a connection only
    /// from whoever has its sign-in — made up for this run and given to the machine's network
    /// alone. Without one (method 0), or with another, nothing is connected.
    func testOnlyTheMachinesNetworkWithItsSignInIsTaken() throws {
        let origin = listener()
        let connector = try connector()
        guard case .socks5(let host, let port, let username?, let password?) = connector.upstream else {
            return XCTFail("the connector gives no sign-in: \(connector.upstream)")
        }
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual(port, connector.port)
        XCTAssertEqual(username.count, 32)
        XCTAssertEqual(password.count, 32)
        XCTAssertNotEqual(username, password)
        // Another connector, another sign-in.
        let other = try self.connector()
        XCTAssertNotEqual(other.upstream, connector.upstream)

        // No sign-in offered: refused, as RFC 1928 has it.
        let anonymous = try dial(connector.port)
        TestSocket.write(anonymous, [5, 1, 0])
        XCTAssertEqual(TestSocket.read(anonymous, exactly: 2), [5, 0xFF])
        XCTAssertEqual(TestSocket.readToEnd(anonymous, timeout: 3), [])
        // A sign-in that is not this connector's: refused (RFC 1929), and closed.
        for (user, secret) in [(username, "wrong"), ("wrong", password), (username, ""), (password, username),
                               (username + "x", password)] {
            let guesser = try dial(connector.port)
            TestSocket.write(guesser, [5, 2, 0, 2])
            XCTAssertEqual(TestSocket.read(guesser, exactly: 2), [5, 2])
            let userBytes = Array(user.utf8), secretBytes = Array(secret.utf8)
            TestSocket.write(guesser, [1, UInt8(userBytes.count)] + userBytes + [UInt8(secretBytes.count)] + secretBytes)
            XCTAssertEqual(TestSocket.read(guesser, exactly: 2), [1, 1], user)
            TestSocket.write(guesser, [5, 1, 0, 1, 127, 0, 0, 1, UInt8(origin.port >> 8), UInt8(origin.port & 0xFF)])
            XCTAssertEqual(TestSocket.readToEnd(guesser, timeout: 3), [], user)
        }
        XCTAssertEqual(TestSocket.accept(origin.descriptor, timeout: 0.3), -1, "a connection without the sign-in was made")
        // Another connector's sign-in is not this one's.
        let stranger = try dial(connector.port)
        dialed[stranger] = other.port
        XCTAssertFalse(signIn(stranger))
        // With it: connected.
        XCTAssertEqual(ask(try dial(connector.port), address: [127, 0, 0, 1], port: origin.port), 0)
        XCTAssertGreaterThanOrEqual(TestSocket.accept(origin.descriptor, timeout: 3), 0)
    }

    /// A connection holds three descriptors of the helper without a proxy: the connector takes
    /// as many at once as the descriptors allow, counted so.
    func testConnectionsAreCountedByTheirThreeDescriptors() {
        XCTAssertEqual(VMNetDirectConnector.descriptorsPerConnection, 3)
        XCTAssertEqual(VMNetDirectConnector.connectionsAllowed(descriptorLimit: 8192), VMNetDirectConnector.maximumConnections)
        XCTAssertEqual(VMNetDirectConnector.connectionsAllowed(descriptorLimit: 1024), 170)
        XCTAssertEqual(VMNetDirectConnector.connectionsAllowed(descriptorLimit: 256), 42)
        XCTAssertEqual(VMNetDirectConnector.connectionsAllowed(descriptorLimit: 64), 16)
        for limit in [256, 1024, 4096, 8192] {
            // The network's connections and the connector's sockets for them, together: what
            // the process may open, with room left for the rest of it.
            let connections = NetworkLoop.connectionLimit(wanted: 2048, descriptorLimit: limit,
                                                          descriptorsPerConnection: VMNetDirectConnector.descriptorsPerConnection)
            XCTAssertLessThanOrEqual(connections + 2 * VMNetDirectConnector.connectionsAllowed(descriptorLimit: limit), limit / 2 + 16, "\(limit)")
        }
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
                     "::ffff:192.168.1.1", "::ffff:10.0.0.1", "::8.8.8.8",
                     // Site-local (deprecated, and local all the same).
                     "fec0::1", "feff:ffff::1",
                     // NAT64's well-known prefix: the IPv4 address inside is what is reached.
                     "64:ff9b::7f00:1", "64:ff9b::c0a8:101", "64:ff9b::a9fe:a9fe", "64:ff9b::a00:1"] {
            XCTAssertFalse(VMNetDirectConnector.isPublicIPv6(address(text)), text)
        }
        XCTAssertTrue(VMNetDirectConnector.isPublicIPv6(address("64:ff9b::808:808")))
        XCTAssertFalse(VMNetDirectConnector.isPublicIPv6([1, 2, 3]))
    }

    // MARK: - A VPN's own addresses

    /// An address of a private range this machine has itself (on its network), if it has one.
    private func ownPrivateAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  Int(entry.pointee.ifa_flags) & Int(IFF_UP) != 0 else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if VMNetDirectConnector.isPrivateIPv4(VMNetIPv4(value)) { return VMNetIPv4(value).string }
        }
        return nil
    }

    /// Every address this machine's interfaces that are up have, as text (IPv6 link-local ones,
    /// which need their interface to mean anything, left out).
    private func ownAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        var next = list
        while let entry = next {
            next = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr, Int(entry.pointee.ifa_flags) & Int(IFF_UP) != 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            var buffer = [CChar](repeating: 0, count: 64)
            if family == AF_INET {
                var inner = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET, &inner, &buffer, socklen_t(buffer.count)) != nil else { continue }
            } else if family == AF_INET6 {
                var inner = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let first = withUnsafeBytes(of: inner) { Array($0.prefix(2)) }
                if first[0] == 0xFE && first[1] & 0xC0 == 0x80 { continue }
                guard inet_ntop(AF_INET6, &inner, &buffer, socklen_t(buffer.count)) != nil else { continue }
            } else {
                continue
            }
            found.append(String(cString: buffer))
        }
        return found
    }

    /// Many VPN tools answer every name with an address of their own from a private range and take
    /// the connection in their tunnel. Such an address is taken; a local network's, this machine
    /// itself and an address the guest wrote are not.
    func testAPrivateAddressIsTakenOnlyWhereItGoesIntoATunnel() throws {
        // The connection that is made (below) goes to an address of the network this machine is
        // on, standing in for a VPN's. On a Mac that is a use of the local network, which macOS
        // asks the person about in a window of its own — on a CI Mac, over whatever a later check
        // takes a picture of (the full pipeline, 14 November). So it is made on Linux only; the
        // rule itself is the same code on both.
        #if os(Linux)
        let own = ownPrivateAddress()
        #else
        let own: String? = nil
        #endif
        let asked = Locked<[String]>([])
        let names = ["lan.example": ["192.168.1.10"], "self.example": ["127.0.0.1"], "link.example": ["169.254.169.254"],
                     "vpn.example": [own ?? "100.64.0.7"]]
        let connector = VMNetDirectConnector(allowsLocalDestinations: false, routesIntoTunnel: { address in
            asked.update { $0.append(address) }
            return address == "100.64.0.7" || address == own
        }) { names[$0] }
        connectors.append(connector)
        try connector.start()

        // A local network's address: asked about, and not a tunnel's.
        XCTAssertEqual(ask(try dial(connector.port), name: "lan.example", port: 80), 5)
        XCTAssertEqual(connector.report().trouble, .notPublic)
        let detail = try XCTUnwrap(connector.report().detail)
        XCTAssertTrue(detail.contains("192.168.0.0/16"), detail)
        XCTAssertTrue(detail.contains("does not send them into a tunnel"), detail)
        XCTAssertFalse(detail.contains("192.168.1.10"), detail)
        XCTAssertEqual(asked.value, ["192.168.1.10"])
        // This machine itself and a link's own addresses: never, whatever the routes say.
        for name in ["self.example", "link.example"] {
            XCTAssertEqual(ask(try dial(connector.port), name: name, port: 80), 5, name)
            XCTAssertEqual(connector.report().trouble, .notPublic, name)
        }
        XCTAssertEqual(asked.value, ["192.168.1.10"])
        // An address the guest wrote itself is not a resolver's answer: public ones only.
        XCTAssertEqual(ask(try dial(connector.port), address: [100, 64, 0, 7], port: 80), 5)
        XCTAssertEqual(asked.value, ["192.168.1.10"])

        // The VPN's: the connection is made. Shown where this machine has a private address to
        // stand for one (a server of the test on it).
        guard let own else { return }
        let origin = TestSocket.listen(on: own)
        descriptors.append(origin.descriptor)
        let client = try dial(connector.port)
        XCTAssertEqual(ask(client, name: "vpn.example", port: origin.port), 0)
        let served = TestSocket.accept(origin.descriptor, timeout: 3)
        XCTAssertGreaterThanOrEqual(served, 0)
        descriptors.append(served)
        TestSocket.write(client, Array("into the tunnel".utf8))
        XCTAssertEqual(TestSocket.read(served, exactly: 15), Array("into the tunnel".utf8))
        XCTAssertNil(connector.report().trouble)
        XCTAssertNil(connector.report().detail)
        XCTAssertTrue(asked.value.contains(own))
    }

    func testWhichAddressesAreAPrivateRanges() {
        for text in ["10.0.0.1", "10.255.255.254", "100.64.0.1", "100.127.255.254", "172.16.0.1", "172.31.255.254",
                     "192.168.0.1", "192.0.0.8", "240.0.0.1", "255.255.255.254"] {
            XCTAssertTrue(VMNetDirectConnector.isPrivateIPv4(try XCTUnwrap(VMNetIPv4(string: text))), text)
        }
        // This machine, a link's own addresses, groups, nobody — and the public internet.
        for text in ["0.0.0.0", "0.1.2.3", "127.0.0.1", "127.8.0.1", "169.254.169.254", "224.0.0.251", "239.255.255.250",
                     "255.255.255.255", "8.8.8.8", "100.63.255.255", "100.128.0.1", "172.32.0.1", "198.18.0.1"] {
            XCTAssertFalse(VMNetDirectConnector.isPrivateIPv4(try XCTUnwrap(VMNetIPv4(string: text))), text)
        }
    }

    /// The system's own answer about a route. What every machine has: itself, which is no tunnel.
    /// And, where the test is given a tunnel (VMNET_TUNNEL_PEER: the far end of a point-to-point
    /// interface that is up), an address this machine does send into one.
    func testTheSystemsRoutesSayWhatGoesIntoATunnel() throws {
        XCTAssertFalse(VMNetDirectConnector.goesIntoATunnel(numeric: "127.0.0.1"))
        XCTAssertFalse(VMNetDirectConnector.goesIntoATunnel(numeric: "::1"))
        XCTAssertFalse(VMNetDirectConnector.goesIntoATunnel(numeric: "not an address"))
        if let own = ownPrivateAddress() {
            // Its own address, and the network it is on: known from the interfaces, with no socket.
            XCTAssertTrue(VMNetDirectConnector.isOnOwnNetwork(numeric: own))
            XCTAssertFalse(VMNetDirectConnector.goesIntoATunnel(numeric: own), "this machine's own address is not a tunnel's far end")
        }
        XCTAssertTrue(VMNetDirectConnector.isOnOwnNetwork(numeric: "127.0.0.1"))
        // The same address inside an IPv6 one — mapped, or behind NAT64's prefix — is the same.
        XCTAssertTrue(VMNetDirectConnector.isOnOwnNetwork(numeric: "::ffff:127.0.0.1"))
        XCTAssertTrue(VMNetDirectConnector.isOnOwnNetwork(numeric: "64:ff9b::7f00:1"))
        XCTAssertFalse(VMNetDirectConnector.isOnOwnNetwork(numeric: "203.0.113.7"), "a public address is on no network of this machine's")
        XCTAssertFalse(VMNetDirectConnector.isOnOwnNetwork(numeric: "64:ff9b::cb00:7107"))
        // Every address this machine has, public ones (a public IPv4, a global IPv6) among them,
        // is its own — and a connection to it is refused like one to a private address.
        for own in ownAddresses() {
            XCTAssertTrue(VMNetDirectConnector.isOnOwnNetwork(numeric: own), own)
        }
        XCTAssertFalse(VMNetDirectConnector.isOnOwnNetwork(numeric: "not an address"))
        guard let peer = ProcessInfo.processInfo.environment["VMNET_TUNNEL_PEER"], !peer.isEmpty else { return }
        XCTAssertTrue(VMNetDirectConnector.goesIntoATunnel(numeric: peer), "\(peer) is not sent into a tunnel")
        XCTAssertFalse(VMNetDirectConnector.isOnOwnNetwork(numeric: peer), "a tunnel's far end is not a network this machine is on")
        if let local = ProcessInfo.processInfo.environment["VMNET_TUNNEL_LOCAL"], !local.isEmpty {
            XCTAssertTrue(VMNetDirectConnector.isOnOwnNetwork(numeric: local))
            XCTAssertFalse(VMNetDirectConnector.goesIntoATunnel(numeric: local), "the tunnel's near end is this machine")
        }
    }

    // MARK: - Why a connection was not made

    /// What the person is told when a machine has no internet: a kind and a count — never a name
    /// or an address the guest asked for.
    func testAFailureSaysItsKindAndNothingOfWhereItWent() throws {
        let gone = TestSocket.listen()
        Sys.close(gone.descriptor)
        let origin = listener()
        let connector = try connector(names: ["nowhere.example": []])
        XCTAssertEqual(connector.report(), VMNetDirectConnector.Report())
        XCTAssertNil(connector.takeNotes())

        XCTAssertEqual(ask(try dial(connector.port), name: "nowhere.example", port: 80), 5)
        XCTAssertEqual(connector.report().trouble, .nameNotFound)
        XCTAssertEqual(ask(try dial(connector.port), address: [127, 0, 0, 1], port: gone.port), 5)
        var report = connector.report()
        XCTAssertEqual(report.trouble, .unreachable)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.failedInARow, 2)
        XCTAssertEqual(report.connected, 0)

        XCTAssertEqual(ask(try dial(connector.port), address: [127, 0, 0, 1], port: origin.port), 0)
        report = connector.report()
        XCTAssertNil(report.trouble)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.failedInARow, 0)
        XCTAssertEqual(report.connected, 1)
        XCTAssertFalse(report.usesSystemProxy)

        let notes = try XCTUnwrap(connector.takeNotes())
        XCTAssertTrue(notes.contains("1 × connected"), notes)
        XCTAssertTrue(notes.contains("1 × no address for the name"), notes)
        XCTAssertTrue(notes.contains("connection refused"), notes)
        XCTAssertFalse(notes.contains("nowhere.example"), notes)
        XCTAssertFalse(notes.contains("127.0.0.1"), notes)
        XCTAssertNil(connector.takeNotes(), "the notes are taken once")
    }

    func testALocalAddressIsToldApartFromOneThatDoesNotAnswer() throws {
        let connector = try connector(local: false, names: ["lan.example": ["192.168.1.10"]])
        XCTAssertEqual(ask(try dial(connector.port), name: "lan.example", port: 80), 5)
        XCTAssertEqual(connector.report().trouble, .notPublic)
        let notes = try XCTUnwrap(connector.takeNotes())
        XCTAssertTrue(notes.contains("192.168.0.0/16"), notes)
        XCTAssertFalse(notes.contains("192.168.1.10"), notes)
        XCTAssertFalse(notes.contains("lan.example"), notes)
    }

    // MARK: - The proxy of this Mac's network settings

    /// A connector on a Mac whose network settings name `proxy`.
    private func connector(through proxy: FakeProxy, exceptions: [String] = [], local: Bool = true,
                           names: [String: [String]] = [:]) throws -> VMNetDirectConnector {
        let settings = VMNetSystemProxy(upstream: proxy.upstream(), exceptions: exceptions)
        let connector = VMNetDirectConnector(allowsLocalDestinations: local, systemProxy: { settings }) { names[$0] }
        connectors.append(connector)
        XCTAssertGreaterThan(try connector.start(), 0)
        return connector
    }

    /// A VPN or proxy tool in its "system proxy" mode takes no packets: Safari on the Mac asks
    /// the proxy, and so does a machine — for the name itself, which the proxy resolves.
    func testWhereTheMacsSettingsNameAProxyItIsAskedForTheNameItself() throws {
        for kind in [FakeProxy.Kind.socks5, .http] {
            let proxy = FakeProxy(kind: kind, origin: FakeProxy.httpOrigin(body: Array("through the proxy".utf8)))
            defer { proxy.stop() }
            let connector = try connector(through: proxy)
            let client = try dial(connector.port)
            XCTAssertEqual(ask(client, name: "site.example", port: 443), 0)
            TestSocket.write(client, Array("GET / HTTP/1.1\r\nHost: site.example\r\n\r\n".utf8))
            let answer = String(decoding: TestSocket.readToEnd(client, timeout: 5), as: UTF8.self)
            XCTAssertTrue(answer.hasSuffix("through the proxy"), answer)
            let request = try XCTUnwrap(proxy.requests.value.first)
            XCTAssertEqual(request.host, "site.example")
            XCTAssertEqual(request.port, 443)
            XCTAssertTrue(request.byName)
            let report = connector.report()
            XCTAssertEqual(report.connected, 1)
            XCTAssertTrue(report.usesSystemProxy)
            XCTAssertEqual(connector.takeNotes(), "1 × connected through this Mac's proxy")
        }
    }

    /// Bytes a proxy sends in the same breath as its answer are the connection's first.
    func testWhatAProxySendsRightBehindItsAnswerIsNotLost() throws {
        let proxy = FakeProxy(kind: .http, afterHeaders: Array("early".utf8))
        defer { proxy.stop() }
        let connector = try connector(through: proxy)
        let client = try dial(connector.port)
        XCTAssertEqual(ask(client, name: "site.example", port: 443), 0)
        XCTAssertEqual(TestSocket.read(client, exactly: 5), Array("early".utf8))
    }

    func testAProxyThatRefusesOrIsNotThereIsSaidSo() throws {
        let refusing = FakeProxy(kind: .socks5, behaviour: .refuse(2))
        defer { refusing.stop() }
        let first = try connector(through: refusing)
        XCTAssertEqual(ask(try dial(first.port), name: "site.example", port: 443), 5)
        XCTAssertEqual(first.report().trouble, .proxyRefused)
        XCTAssertEqual(first.takeNotes(), "1 × this Mac's proxy: the proxy refused (code 2)")

        // The settings name a port nobody listens on (a tool that was quit and left its setting).
        let gone = TestSocket.listen()
        Sys.close(gone.descriptor)
        let settings = VMNetSystemProxy(upstream: .socks5(host: "127.0.0.1", port: gone.port, username: nil, password: nil))
        let second = VMNetDirectConnector(allowsLocalDestinations: true, systemProxy: { settings })
        connectors.append(second)
        try second.start()
        XCTAssertEqual(ask(try dial(second.port), name: "site.example", port: 443), 5)
        XCTAssertEqual(second.report().trouble, .proxyUnreachable)
        XCTAssertFalse(try XCTUnwrap(second.takeNotes()).contains("site.example"))
    }

    /// The settings' own exceptions go without the proxy, as they do for the Mac's apps.
    func testHostsTheSettingsExceptGoWithoutTheProxy() throws {
        let origin = listener()
        let proxy = FakeProxy(kind: .socks5)
        defer { proxy.stop() }
        let connector = try connector(through: proxy, exceptions: ["*.direct.example", "Plain.example"],
                                      names: ["a.direct.example": ["127.0.0.1"], "plain.example": ["127.0.0.1"]])
        for name in ["a.direct.example", "plain.example"] {
            XCTAssertEqual(ask(try dial(connector.port), name: name, port: origin.port), 0)
            let served = TestSocket.accept(origin.descriptor, timeout: 3)
            XCTAssertGreaterThanOrEqual(served, 0, name)
            descriptors.append(served)
        }
        XCTAssertEqual(proxy.accepted.value, 0)
        XCTAssertFalse(connector.report().usesSystemProxy)
    }

    /// A name that is this machine's or the local network's by the way it is written is not asked
    /// of a proxy on this Mac. Any other is — and is not looked up here first: the Mac's own
    /// Safari tells its resolver nothing of what it asks the proxy for, and a resolver that
    /// answers a blocked name with a local address would have refused what the proxy opens.
    func testOnlyANameWrittenAsLocalIsKeptFromTheProxy() throws {
        let proxy = FakeProxy(kind: .socks5)
        defer { proxy.stop() }
        let looked = Locked<[String]>([])
        let settings = VMNetSystemProxy(upstream: proxy.upstream())
        let connector = VMNetDirectConnector(allowsLocalDestinations: false, systemProxy: { settings }) { name in
            looked.update { $0.append(name) }
            return ["192.168.1.10"]
        }
        connectors.append(connector)
        try connector.start()
        for name in ["localhost", "printer.local", "nas"] {
            XCTAssertEqual(ask(try dial(connector.port), name: name, port: 80), 5, name)
            XCTAssertEqual(connector.report().trouble, .notPublic, name)
        }
        XCTAssertEqual(proxy.accepted.value, 0)
        // A name the Mac's resolver would have answered with a local network's address.
        XCTAssertEqual(ask(try dial(connector.port), name: "blocked-here.example", port: 443), 0)
        XCTAssertEqual(proxy.requests.value.first?.host, "blocked-here.example")
        XCTAssertEqual(looked.value, [], "the name was looked up on this side")
        for name in ["example.com", "a.b.example.org", "xn--80ak6aa92e.com"] { XCTAssertFalse(VMNetDirectConnector.isLocalName(name), name) }
        for name in ["localhost", "x.localhost", "printer.local", "nas", "", "a..b", "a b.example"] {
            XCTAssertTrue(VMNetDirectConnector.isLocalName(name), name)
        }
    }

    /// "No internet in this machine" is said only when a connection cannot be made at all: asked
    /// by the same way a guest's are, and not counted as one of them.
    func testWhetherAConnectionCanBeMadeAtAll() throws {
        let origin = listener()
        let gone = TestSocket.listen()
        Sys.close(gone.descriptor)
        let connector = try connector(names: ["there.example": ["127.0.0.1"], "nowhere.example": []])
        XCTAssertTrue(connector.canConnect(to: "there.example", port: UInt16(origin.port)))
        XCTAssertGreaterThanOrEqual(TestSocket.accept(origin.descriptor, timeout: 3), 0)
        XCTAssertFalse(connector.canConnect(to: "there.example", port: UInt16(gone.port)))
        XCTAssertFalse(connector.canConnect(to: "nowhere.example", port: 80))
        XCTAssertEqual(connector.report(), VMNetDirectConnector.Report(), "the question is not one of the guest's connections")
        XCTAssertNil(connector.takeNotes())
        connector.stop()
        XCTAssertFalse(connector.canConnect(to: "there.example", port: UInt16(origin.port)))
    }

    func testTheSystemsSettingsAsAProxy() {
        // A SOCKS proxy first: it carries a connection to any port.
        let both = VMNetSystemProxy(settings: ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7890,
                                               "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7891,
                                               "ExceptionsList": ["*.local", "169.254/16", "Localhost"]])
        XCTAssertEqual(both?.upstream, .socks5(host: "127.0.0.1", port: 7890, username: nil, password: nil))
        XCTAssertEqual(both?.exceptions, ["*.local", "169.254/16", "localhost"])
        XCTAssertEqual(both?.applies(to: "printer.local"), false)
        XCTAssertEqual(both?.applies(to: "LOCALHOST"), false)
        XCTAssertEqual(both?.applies(to: "example.com"), true)
        XCTAssertEqual(both?.applies(to: "notlocal"), true)

        let https = VMNetSystemProxy(settings: ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8080,
                                                "HTTPSEnable": true, "HTTPSProxy": " proxy.example ", "HTTPSPort": "8443"])
        XCTAssertEqual(https?.upstream, .httpConnect(host: "proxy.example", port: 8443, username: nil, password: nil))
        XCTAssertEqual(https?.exceptions, [])

        // Nothing switched on, a proxy for plain HTTP alone, and settings that do not read: no proxy.
        for settings: [String: Any] in [[:], ["SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7890],
                                        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8080],
                                        ["ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0],
                                        ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 0],
                                        ["SOCKSEnable": 1, "SOCKSProxy": "", "SOCKSPort": 7890],
                                        ["SOCKSEnable": 1, "SOCKSProxy": "a b", "SOCKSPort": 7890],
                                        ["HTTPSEnable": 1, "HTTPSProxy": 5, "HTTPSPort": 70000]] {
            XCTAssertNil(VMNetSystemProxy(settings: settings), "\(settings)")
        }
        // A pattern with a leading dot is every name under it, and the name itself.
        let dotted = VMNetSystemProxy(upstream: .none, exceptions: [".corp.example", ""])
        XCTAssertFalse(dotted.applies(to: "a.corp.example"))
        XCTAssertFalse(dotted.applies(to: "corp.example"))
        XCTAssertTrue(dotted.applies(to: "notcorp.example"))

        // A configuration file (PAC) or discovery on the network (WPAD) is the proxy, as the
        // system takes it — first, whatever else is set beside it — and is not followed.
        for settings: [String: Any] in [["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://example.com/proxy.pac"],
                                        ["ProxyAutoDiscoveryEnable": 1],
                                        ["ProxyAutoConfigEnable": "1", "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7890]] {
            let proxy = VMNetSystemProxy(settings: settings)
            XCTAssertEqual(proxy?.usesConfigurationFile, true, "\(settings)")
            XCTAssertEqual(proxy?.upstream, VMNetUpstream.none, "\(settings)")
        }
        XCTAssertEqual(both?.usesConfigurationFile, false)
    }

    /// The settings' exceptions as macOS writes them for addresses — a range with its prefix
    /// length, leading parts alone, an address — go without the proxy (and so by this Mac's own
    /// rules, which refuse a local address); a name is never taken for one.
    func testTheSettingsExceptAddressesByTheirRanges() {
        let proxy = VMNetSystemProxy(upstream: .none, exceptions: ["192.168.0.0/16", "10.0.0.0/8", "169.254/16", "127.0.0.1",
                                                                   "172.16.*", "100.64.0.0/10", "*.local", "bad/99", "1.2.3.4.5"])
        for host in ["192.168.1.1", "192.168.255.254", "10.1.2.3", "169.254.169.254", "127.0.0.1", "172.16.9.9", "100.100.0.1"] {
            XCTAssertFalse(proxy.applies(to: host), host)
        }
        for host in ["192.169.0.1", "11.0.0.1", "169.253.0.1", "127.0.0.2", "172.17.0.1", "100.128.0.1", "8.8.8.8",
                     "example.com", "192.168.example"] {
            XCTAssertTrue(proxy.applies(to: host), host)
        }
        XCTAssertEqual(VMNetSystemProxy.range("169.254/16")?.network, 0xA9FE_0000)
        XCTAssertEqual(VMNetSystemProxy.range("169.254/16")?.prefixLength, 16)
        XCTAssertEqual(VMNetSystemProxy.range("10")?.prefixLength, 8)
        XCTAssertEqual(VMNetSystemProxy.range("192.168.*.*")?.prefixLength, 16)
        XCTAssertEqual(VMNetSystemProxy.range("8.8.8.8")?.prefixLength, 32)
        for entry in ["", "*", "*.local", "localhost", "1.2.3.4.5", "256.0.0.0/8", "10.0.0.0/33", "10.*.0.0", "10.*/8", "a.b.c.d", "10.0.0.0/"] {
            XCTAssertNil(VMNetSystemProxy.range(entry), entry)
        }
    }

    /// Where this Mac's proxy is set by a configuration file, a machine's network stays closed —
    /// as for a proxy that is down — and says why: not a connection without the proxy, which
    /// would go out where the Mac's own apps do not.
    func testAProxyConfigurationFileKeepsTheMachineClosed() throws {
        let origin = listener()
        let settings = VMNetSystemProxy(upstream: .none, usesConfigurationFile: true)
        let connector = VMNetDirectConnector(allowsLocalDestinations: true, systemProxy: { settings }) { name in
            name == "site.example" ? ["127.0.0.1"] : nil
        }
        connectors.append(connector)
        try connector.start()
        XCTAssertEqual(ask(try dial(connector.port), name: "site.example", port: origin.port), 5)
        XCTAssertEqual(ask(try dial(connector.port), address: [127, 0, 0, 1], port: origin.port), 5)
        XCTAssertEqual(TestSocket.accept(origin.descriptor, timeout: 0.3), -1, "a connection went out without the proxy")
        let report = connector.report()
        XCTAssertEqual(report.trouble, .proxyConfigurationFile)
        XCTAssertEqual(report.failed, 2)
        XCTAssertTrue(try XCTUnwrap(report.detail).contains("configuration file"))
        XCTAssertFalse(connector.canConnect(to: "site.example", port: UInt16(origin.port)))
    }

    /// With this Mac's proxy, an address written as a name, a local name, and an address of this
    /// Mac or a local network are not asked of the proxy — and an exception for an address range
    /// does not open the way to it either.
    func testWithTheMacsProxyLocalAddressesAndNumericNamesAreRefused() throws {
        let proxy = FakeProxy(kind: .socks5)
        defer { proxy.stop() }
        let looked = Locked<[String]>([])
        let settings = VMNetSystemProxy(upstream: proxy.upstream(), exceptions: ["192.168.0.0/16", "127.0.0.1", "*.local", "169.254/16"])
        let connector = VMNetDirectConnector(allowsLocalDestinations: false, systemProxy: { settings }) { name in
            looked.update { $0.append(name) }
            return ["192.168.1.10"]
        }
        connectors.append(connector)
        try connector.start()
        for name in ["192.168.1.1", "127.0.0.1", "0x7f.1", "127.1", "169.254.169.254", "printer.local", "nas", "localhost"] {
            XCTAssertEqual(ask(try dial(connector.port), name: name, port: 80), 5, name)
            XCTAssertEqual(connector.report().trouble, .notPublic, name)
        }
        for address: [UInt8] in [[192, 168, 1, 1], [127, 0, 0, 1], [10, 0, 0, 1], [169, 254, 169, 254]] {
            XCTAssertEqual(ask(try dial(connector.port), address: address, port: 80), 5, "\(address)")
            XCTAssertEqual(connector.report().trouble, .notPublic, "\(address)")
        }
        XCTAssertEqual(proxy.accepted.value, 0, "the proxy was asked")
        XCTAssertEqual(looked.value, [], "a name was looked up on this side")
        XCTAssertTrue(VMNetDirectConnector.isLocalName("0x7f.1"))
        XCTAssertTrue(VMNetDirectConnector.isLocalName("192.168.1.1."))
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
