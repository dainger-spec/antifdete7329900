#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// A machine without a proxy sends its UDP as this Mac's own (`VMNetDirectConnector`, UDP
/// ASSOCIATE): through the whole network, with the tests' UDP servers on loopback as destinations
/// (named to the connector by the tests' own resolver).
final class DirectConnectorUDPTests: XCTestCase {
    private var connectors: [VMNetDirectConnector] = []
    private var descriptors: [Int32] = []
    private var network: VMNetwork?
    private let logLines = Locked<[String]>([])
    /// The servers' threads end when this is set, and close their own sockets.
    private let serversStopped = Locked(false)
    private let serversRunning = Locked(0)

    override func tearDown() {
        network?.stop()
        network = nil
        for connector in connectors { connector.stop() }
        connectors = []
        serversStopped.value = true
        let deadline = Sys.now + 3
        while serversRunning.value > 0 && Sys.now < deadline { usleep(5_000) }
        for descriptor in descriptors { Sys.close(descriptor) }
        descriptors = []
        super.tearDown()
    }

    private func connector(local: Bool = true, names: [String: [String]] = [:],
                           systemProxy: (@Sendable () -> VMNetSystemProxy?)? = nil) throws -> VMNetDirectConnector {
        let connector = VMNetDirectConnector(allowsLocalDestinations: local, systemProxy: systemProxy,
                                             routesIntoTunnel: { _ in false }) { names[$0] }
        connectors.append(connector)
        XCTAssertGreaterThan(try connector.start(), 0)
        return connector
    }

    /// A network whose way out is `connector`, with UDP on, and the guest at its other end.
    private func start(_ connector: VMNetDirectConnector) -> TestGuest {
        let (stackEnd, guestEnd) = TestSocket.datagramPair()
        descriptors += [stackEnd, guestEnd]
        var configuration = Wire.configuration(upstream: connector.upstream)
        configuration.relaysUDP = true
        let network = VMNetwork(configuration: configuration, frameDescriptor: stackEnd)
        network.descriptorsPerConnection = VMNetDirectConnector.descriptorsPerConnection
        let lines = logLines
        network.log = { line in lines.update { $0.append(line) } }
        network.start()
        self.network = network
        return TestGuest(descriptor: guestEnd)
    }

    /// A UDP server on loopback that answers every datagram with `answer` and notes who sent it.
    private func server(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]? = { $0 }) -> (port: Int, senders: Locked<[sockaddr_in]>) {
        let (descriptor, port) = UDPTestSocket.bind()
        let senders = Locked<[sockaddr_in]>([])
        let stopped = serversStopped, running = serversRunning
        running.update { $0 += 1 }
        let thread = Thread {
            while !stopped.value {
                guard let (bytes, from) = UDPTestSocket.receive(descriptor, timeout: 0.05) else { continue }
                senders.update { $0.append(from) }
                if let reply = answer(bytes) { UDPTestSocket.send(descriptor, reply, to: from) }
            }
            Sys.close(descriptor)
            running.update { $0 -= 1 }
        }
        thread.start()
        return (port, senders)
    }

    private func answer(_ guest: TestGuest, port: UInt16, from remote: VMNetIPv4, _ remotePort: UInt16, timeout: Double = 3) -> [UInt8]? {
        guest.expect(timeout: timeout) { frame -> [UInt8]? in
            guard let udp = Wire.seenUDP(frame), udp.destinationPort == port else { return nil }
            XCTAssertEqual(udp.source, remote)
            XCTAssertEqual(udp.sourcePort, remotePort)
            XCTAssertTrue(udp.checksumValid)
            return udp.payload
        }
    }

    private func toldUnreachable(_ guest: TestGuest, from remote: VMNetIPv4) -> Bool {
        guest.expect { frame -> Bool? in
            frame.withUnsafeBytes { bytes -> Bool? in
                guard let ethernet = EthernetFrame(bytes), let packet = IPv4Packet(ethernet.payload), packet.proto == IPProtocol.icmp,
                      let message = ICMPMessage(packet.payload), message.type == ICMPMessage.destinationUnreachable,
                      packet.source == remote else { return nil }
                return true
            }
        } ?? false
    }

    func testAMachineWithoutAProxySendsUDPAsThisMacsOwnAndHearsOnlyWhereItSent() throws {
        let echo = server()
        let connector = try connector(names: ["echo.example": ["127.0.0.1"]])
        let guest = start(connector)
        let fake = try XCTUnwrap(guest.resolve("echo.example")?.address)
        guest.send(Wire.udp(from: 50_000, to: fake, UInt16(echo.port), payload: Array("hello over UDP".utf8)))
        XCTAssertEqual(answer(guest, port: 50_000, from: fake, UInt16(echo.port)), Array("hello over UDP".utf8))
        // Again, and from another port of the guest's.
        guest.send(Wire.udp(from: 50_000, to: fake, UInt16(echo.port), payload: [2]))
        XCTAssertEqual(answer(guest, port: 50_000, from: fake, UInt16(echo.port)), [2])
        guest.send(Wire.udp(from: 50_001, to: fake, UInt16(echo.port), payload: [3]))
        XCTAssertEqual(answer(guest, port: 50_001, from: fake, UInt16(echo.port)), [3])
        // One socket of this process per association: the same port for every datagram of one
        // guest port, as a home router's NAT keeps it.
        let senders = echo.senders.value
        XCTAssertEqual(senders.count, 3)
        XCTAssertEqual(senders[0].sin_port, senders[1].sin_port)
        XCTAssertNotEqual(senders[0].sin_port, senders[2].sin_port)

        // A datagram from anywhere the connector did not send to, to the port it sends from: not
        // the guest's.
        let (stranger, _) = UDPTestSocket.bind()
        descriptors.append(stranger)
        UDPTestSocket.send(stranger, [0x66], to: senders[0])
        XCTAssertTrue(guest.hearsNothing(for: 0.4))
        let counters = network!.counters()
        XCTAssertEqual(counters.udpAssociationsOpened, 2)
        XCTAssertEqual(counters.datagramsToGuest, 3)
        XCTAssertEqual(connector.takeNotes()?.contains("UDP association"), true)
    }

    func testNoUDPWhileTheMacsSettingsNameAProxy() throws {
        let echo = server()
        let settings = VMNetSystemProxy(upstream: .socks5(host: "127.0.0.1", port: 9, username: nil, password: nil))
        let connector = try connector(names: ["echo.example": ["127.0.0.1"]], systemProxy: { settings })
        let guest = start(connector)
        let fake = try XCTUnwrap(guest.resolve("echo.example")?.address)
        guest.send(Wire.udp(from: 50_010, to: fake, UInt16(echo.port), payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: fake))
        XCTAssertTrue(echo.senders.value.isEmpty, "UDP went around the Mac's proxy")
        let deadline = Sys.now + 2
        while !logLines.value.contains(where: { $0.contains("the proxy does not carry UDP") }) && Sys.now < deadline { usleep(10_000) }
        XCTAssertTrue(logLines.value.contains { $0.contains("the proxy does not carry UDP (UDP ASSOCIATE refused, code 2)") })
        XCTAssertTrue(connector.takeNotes()?.contains("UDP refused: this Mac's network settings name a proxy") == true)
    }

    func testUDPToThisMacOrALocalNetworkByNameDoesNotLeave() throws {
        let echo = server()
        // The connection's rule, not the tests' leave to reach loopback: a name that resolves to
        // this machine or a local network is not sent to.
        let connector = try connector(local: false, names: ["home.example": ["127.0.0.1"], "lan.example": ["192.168.77.1"]])
        let guest = start(connector)
        for name in ["home.example", "lan.example"] {
            let fake = try XCTUnwrap(guest.resolve(name)?.address)
            guest.send(Wire.udp(from: 50_020, to: fake, UInt16(echo.port), payload: [1]))
            XCTAssertNil(answer(guest, port: 50_020, from: fake, UInt16(echo.port), timeout: 0.5))
        }
        XCTAssertTrue(echo.senders.value.isEmpty)
        XCTAssertTrue(connector.takeNotes()?.contains("UDP refused: no public address for the destination") == true)
    }

    func testAUDPAssociationNeedsTheSignInAndItsDatagramsComeFromTheNetworkAlone() throws {
        let echo = server()
        let connector = try connector(names: ["echo.example": ["127.0.0.1"]])
        // Without the sign-in: refused before anything else.
        let client = socket(AF_INET, Sys.streamType, 0)
        descriptors.append(client)
        var address = UDPTestSocket.loopback(port: UInt16(connector.port))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        TestSocket.write(client, [5, 1, 0])
        XCTAssertEqual(TestSocket.read(client, exactly: 2), [5, 0xFF])

        // With the network's sign-in, by hand: the relay is on loopback; the first datagram's
        // sender is the association's, and a datagram from another socket goes nowhere.
        guard case .socks5(_, _, let username?, let password?) = connector.upstream else { return XCTFail("no sign-in") }
        let control = socket(AF_INET, Sys.streamType, 0)
        descriptors.append(control)
        let ok = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(control, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(ok, 0)
        TestSocket.write(control, [5, 2, 0, 2])
        XCTAssertEqual(TestSocket.read(control, exactly: 2), [5, 2])
        TestSocket.write(control, [1, UInt8(username.utf8.count)] + Array(username.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8))
        XCTAssertEqual(TestSocket.read(control, exactly: 2), [1, 0])
        TestSocket.write(control, [5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
        let reply = try XCTUnwrap(TestSocket.read(control, exactly: 10))
        XCTAssertEqual(Array(reply[0..<8]), [5, 0, 0, 1, 127, 0, 0, 1])
        let relay = UDPTestSocket.loopback(port: UInt16(reply[8]) << 8 | UInt16(reply[9]))
        let (first, _) = UDPTestSocket.bind()
        let (second, _) = UDPTestSocket.bind()
        descriptors += [first, second]
        let header: [UInt8] = [0, 0, 0, 3, 12] + Array("echo.example".utf8) + [UInt8(echo.port >> 8), UInt8(echo.port & 0xFF)]
        UDPTestSocket.send(first, header + [1], to: relay)
        let answered = try XCTUnwrap(UDPTestSocket.receive(first, timeout: 3))
        // From the address it went to, as an address (ATYP 1), with the payload.
        XCTAssertEqual(Array(answered.0.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(Array(answered.0[4..<8]), [127, 0, 0, 1])
        XCTAssertEqual(answered.0.last, 1)
        UDPTestSocket.send(second, header + [2], to: relay)
        XCTAssertNil(UDPTestSocket.receive(second, timeout: 0.4))
        XCTAssertEqual(echo.senders.value.count, 1)
        // A fragment is not sent on.
        UDPTestSocket.send(first, [0, 0, 1] + Array(header.dropFirst(3)) + [3], to: relay)
        XCTAssertNil(UDPTestSocket.receive(first, timeout: 0.4))
        XCTAssertEqual(echo.senders.value.count, 1)
    }
}
