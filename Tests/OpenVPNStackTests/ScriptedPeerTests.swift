#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import OpenVPNStack
import OpenVPNLink

/// The far side of the tunnel played by a script (no root, no TUN: CI's container runs these):
/// IPv4 only; TCP that answers a SYN, echoes what it gets as "echo:<bytes>", answers a FIN with
/// its own, and refuses port 9 with a reset; a DNS server at 10.99.0.1 that knows known.test; a UDP
/// echo on port 7. It records who asked what.
final class ScriptedPeer {
    struct Connection {
        var peerSequence: UInt32
        var ourSequence: UInt32
        var finished = false
    }

    private let descriptor: Int32
    private var stop = false
    private let lock = NSLock()
    private var connections: [UInt32: Connection] = [:]
    private var _questions: [(from: String, name: String)] = []
    private var _udpSources: [String] = []
    private var _syns: [[UInt8]] = []
    private var thread: Thread?

    var questions: [(from: String, name: String)] { lock.lock(); defer { lock.unlock() }; return _questions }
    var udpSources: [String] { lock.lock(); defer { lock.unlock() }; return _udpSources }
    /// Every SYN the stack sent, whole (IP header and all), as it left the tunnel.
    var syns: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _syns }

    init(descriptor: Int32) {
        self.descriptor = descriptor
        let thread = Thread { [unowned self] in run() }
        self.thread = thread
        thread.start()
    }

    func finish() {
        stop = true
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while !stop {
            entry.revents = 0
            guard poll(&entry, 1, 50) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }
            guard count >= 20 else { continue }
            handle(Array(buffer[0..<count]))
        }
    }

    private func send(_ packet: [UInt8]) {
        _ = packet.withUnsafeBytes { Foundation.send(descriptor, $0.baseAddress, $0.count, 0) }
    }

    private func handle(_ packet: [UInt8]) {
        guard packet[0] >> 4 == 4 else { return }
        let headerLength = Int(packet[0] & 0xF) * 4
        let total = Int(UInt16(packet[2]) << 8 | UInt16(packet[3]))
        guard total <= packet.count, headerLength >= 20 else { return }
        let source = Array(packet[12..<16])
        let destination = Array(packet[16..<20])
        let payload = Array(packet[headerLength..<total])
        if packet[9] == 6, payload.count >= 20, payload[13] & 0x12 == 0x02 {
            lock.lock(); _syns.append(Array(packet[0..<total])); lock.unlock()
        }
        switch packet[9] {
        case 6: tcp(payload, from: source, to: destination)
        case 17: udp(payload, from: source, to: destination)
        default: break
        }
    }

    private func udp(_ segment: [UInt8], from source: [UInt8], to destination: [UInt8]) {
        guard segment.count >= 8 else { return }
        let sourcePort = UInt16(segment[0]) << 8 | UInt16(segment[1])
        let destinationPort = UInt16(segment[2]) << 8 | UInt16(segment[3])
        let data = Array(segment[8...])
        let from = TunnelAddress(family: .v4, bytes: source)!.description
        lock.lock()
        _udpSources.append("\(from):\(sourcePort)>\(TunnelAddress(family: .v4, bytes: destination)!.description):\(destinationPort)")
        lock.unlock()
        if destinationPort == 53 {
            let name = FakeDNS.name(data)
            lock.lock()
            _questions.append((from, name))
            lock.unlock()
            let answer = name == "known.test" ? FakeDNS.answer(data, with: [10, 99, 0, 1]) : FakeDNS.noSuchName(data)
            send(Self.udpPacket(from: destination, port: 53, to: source, port: sourcePort, payload: answer))
        } else if destinationPort == 7 {
            send(Self.udpPacket(from: destination, port: 7, to: source, port: sourcePort, payload: Array("echo:".utf8) + data))
        }
    }

    private func tcp(_ segment: [UInt8], from source: [UInt8], to destination: [UInt8]) {
        guard segment.count >= 20 else { return }
        let sourcePort = UInt16(segment[0]) << 8 | UInt16(segment[1])
        let destinationPort = UInt16(segment[2]) << 8 | UInt16(segment[3])
        let sequence = Self.word(segment, 4)
        let flags = segment[13]
        let offset = Int(segment[12] >> 4) * 4
        let data = Array(segment[offset...])
        let key = UInt32(sourcePort) << 16 | UInt32(destinationPort)
        func reply(_ flags: UInt8, sequence: UInt32, acknowledging: UInt32, _ payload: [UInt8] = []) {
            send(Self.tcpPacket(from: destination, port: destinationPort, to: source, port: sourcePort,
                                sequence: sequence, acknowledgement: acknowledging, flags: flags, payload: payload))
        }
        if flags & 0x04 != 0 { // RST
            lock.lock(); connections[key] = nil; lock.unlock()
            return
        }
        if flags & 0x02 != 0 { // SYN
            if destinationPort == 9 {
                reply(0x14, sequence: 0, acknowledging: sequence &+ 1) // RST+ACK
                return
            }
            let ours: UInt32 = 0x1000_0000
            lock.lock(); connections[key] = Connection(peerSequence: sequence &+ 1, ourSequence: ours &+ 1); lock.unlock()
            reply(0x12, sequence: ours, acknowledging: sequence &+ 1) // SYN+ACK
            return
        }
        lock.lock()
        guard var connection = connections[key] else { lock.unlock(); return }
        lock.unlock()
        var answer: [UInt8] = []
        if !data.isEmpty, sequence == connection.peerSequence {
            connection.peerSequence = sequence &+ UInt32(data.count)
            answer = Array("echo:".utf8) + data
        }
        if flags & 0x01 != 0, sequence &+ UInt32(data.count) == connection.peerSequence, !connection.finished { // FIN
            connection.peerSequence &+= 1
            connection.finished = true
            if !answer.isEmpty {
                reply(0x18, sequence: connection.ourSequence, acknowledging: connection.peerSequence, answer)
                connection.ourSequence &+= UInt32(answer.count)
            }
            reply(0x11, sequence: connection.ourSequence, acknowledging: connection.peerSequence) // FIN+ACK
            connection.ourSequence &+= 1
        } else if !answer.isEmpty {
            reply(0x18, sequence: connection.ourSequence, acknowledging: connection.peerSequence, answer) // PSH+ACK
            connection.ourSequence &+= UInt32(answer.count)
        } else if !data.isEmpty {
            reply(0x10, sequence: connection.ourSequence, acknowledging: connection.peerSequence) // a duplicate: ACK again
        }
        lock.lock(); connections[key] = connection; lock.unlock()
    }

    // MARK: Packets

    static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    static func checksum(_ bytes: [UInt8], initial: UInt32 = 0) -> UInt16 {
        var sum = initial
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func ipPacket(from source: [UInt8], to destination: [UInt8], protocolNumber: UInt8, payload: [UInt8]) -> [UInt8] {
        let total = 20 + payload.count
        var header: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xFF), 0, 0, 0x40, 0, 64, protocolNumber, 0, 0]
        header += source
        header += destination
        let sum = checksum(header)
        header[10] = UInt8(sum >> 8)
        header[11] = UInt8(sum & 0xFF)
        return header + payload
    }

    static func pseudoSum(from source: [UInt8], to destination: [UInt8], protocolNumber: UInt8, length: Int) -> UInt32 {
        var pseudo: [UInt8] = source
        pseudo += destination
        pseudo += [0, protocolNumber, UInt8(length >> 8), UInt8(length & 0xFF)]
        var sum: UInt32 = 0
        var index = 0
        while index < pseudo.count {
            sum += UInt32(pseudo[index]) << 8 | UInt32(pseudo[index + 1])
            index += 2
        }
        return sum
    }

    static func udpPacket(from source: [UInt8], port sourcePort: UInt16, to destination: [UInt8], port destinationPort: UInt16,
                          payload: [UInt8]) -> [UInt8] {
        let length = 8 + payload.count
        var segment: [UInt8] = [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF), UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF),
                                UInt8(length >> 8), UInt8(length & 0xFF), 0, 0]
        segment += payload
        let sum = checksum(segment, initial: pseudoSum(from: source, to: destination, protocolNumber: 17, length: length))
        segment[6] = UInt8(sum >> 8)
        segment[7] = UInt8(sum & 0xFF)
        return ipPacket(from: source, to: destination, protocolNumber: 17, payload: segment)
    }

    static func tcpPacket(from source: [UInt8], port sourcePort: UInt16, to destination: [UInt8], port destinationPort: UInt16,
                          sequence: UInt32, acknowledgement: UInt32, flags: UInt8, payload: [UInt8]) -> [UInt8] {
        var segment: [UInt8] = [UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF), UInt8(destinationPort >> 8), UInt8(destinationPort & 0xFF)]
        segment += [UInt8(sequence >> 24), UInt8((sequence >> 16) & 0xFF), UInt8((sequence >> 8) & 0xFF), UInt8(sequence & 0xFF)]
        segment += [UInt8(acknowledgement >> 24), UInt8((acknowledgement >> 16) & 0xFF), UInt8((acknowledgement >> 8) & 0xFF), UInt8(acknowledgement & 0xFF)]
        let synOptions = flags & 0x02 != 0
        segment += [synOptions ? 0x60 : 0x50, flags, 0xFF, 0xFF, 0, 0, 0, 0]
        if synOptions { segment += [2, 4, 0x05, 0x78] } // MSS 1400
        segment += payload
        let sum = checksum(segment, initial: pseudoSum(from: source, to: destination, protocolNumber: 6, length: segment.count))
        segment[16] = UInt8(sum >> 8)
        segment[17] = UInt8(sum & 0xFF)
        return ipPacket(from: source, to: destination, protocolNumber: 6, payload: segment)
    }
}

final class ScriptedPeerTests: XCTestCase {
    private var stackEnd: Int32 = -1
    private var farEnd: Int32 = -1
    private var listening: Int32 = -1
    private var port: UInt16 = 0
    private var server: ServerThread!
    private var peer: ScriptedPeer!

    override func setUp() {
        (stackEnd, farEnd) = TestSockets.packetPair()
        (listening, port) = TestSockets.listener()
        server = ServerThread(TunnelServer(settings: TestSockets.settings(packet: stackEnd, listening: listening), watchParent: false))
        peer = ScriptedPeer(descriptor: farEnd)
    }

    override func tearDown() {
        server.stop()
        peer.finish()
        close(listening)
        close(stackEnd)
        close(farEnd)
    }

    private func connectClient() -> Int32 { TestSockets.connect(to: "127.0.0.1", port: port) }

    func testAClientWithoutCredentialsIsRefused() {
        let client = connectClient()
        defer { close(client) }
        TestSockets.sendAll(client, [5, 1, 0])
        XCTAssertEqual(TestSockets.receive(client, count: 2), [5, 0xFF])
        XCTAssertTrue(TestSockets.receiveToEnd(client).ended, "and the connection ends")
    }

    func testWrongCredentialsAreRefused() {
        let client = connectClient()
        defer { close(client) }
        let (reply, answer) = TestSockets.socksConnect(client, username: TestSockets.username, password: "wrong",
                                                       request: TestSockets.connectRequest(ipv4: [10, 99, 0, 1], port: 7))
        XCTAssertNil(reply)
        XCTAssertEqual(answer, [1, 1])
        XCTAssertTrue(TestSockets.receiveToEnd(client).ended)
    }

    func testAConnectionByAddressCarriesBothWaysAndEnds() {
        let client = connectClient()
        defer { close(client) }
        let (reply, _) = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                                  request: TestSockets.connectRequest(ipv4: [10, 99, 0, 1], port: 7))
        XCTAssertEqual(reply, 0)
        TestSockets.sendAll(client, Array("hello".utf8))
        XCTAssertEqual(TestSockets.receive(client, count: 10), Array("echo:hello".utf8))
        shutdown(client, Int32(SHUT_WR))
        XCTAssertTrue(TestSockets.receiveToEnd(client).ended, "the far side's FIN reached the client")
    }

    /// What leaves the tunnel is a Mac's SYN (lumen_net_shape, docs/OPENVPN.md "A Mac's packets"):
    /// TTL 64 with DF, window 65535, the options in XNU's order with window scale 6, a timestamp
    /// clock and a local port of each connection's own.
    func testASynLeavesTheTunnelInAMacsShape() {
        for _ in 0..<2 {
            let client = connectClient()
            let (reply, _) = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                                      request: TestSockets.connectRequest(ipv4: [10, 99, 0, 1], port: 7))
            XCTAssertEqual(reply, 0)
            TestSockets.sendAll(client, Array("hi".utf8))
            XCTAssertEqual(TestSockets.receive(client, count: 7), Array("echo:hi".utf8), "the connection carries in that shape")
            close(client)
        }
        let syns = peer.syns
        XCTAssertEqual(syns.count, 2)
        guard syns.count == 2 else { return }
        for syn in syns {
            XCTAssertEqual(syn[8], 64, "TTL")
            XCTAssertEqual(syn[6] & 0x40, 0x40, "DF")
            XCTAssertEqual(ScriptedPeer.checksum(Array(syn[0..<20])), 0, "the IP header's checksum")
            let tcp = Array(syn[20...])
            XCTAssertEqual(Int(tcp[12] >> 4) * 4, 44)
            XCTAssertEqual(UInt16(tcp[14]) << 8 | UInt16(tcp[15]), 65535, "window")
            let options = Array(tcp[20..<44])
            XCTAssertEqual(Array(options[0..<2]), [2, 4], "mss first")
            XCTAssertEqual(Array(options[4..<12]), [1, 3, 3, 6, 1, 1, 8, 10], "nop, wscale 6, nop, nop, timestamps")
            XCTAssertEqual(Array(options[16..<24]), [0, 0, 0, 0, 4, 2, 0, 0], "no echo, sackOK, eol")
            let pseudo = ScriptedPeer.pseudoSum(from: Array(syn[12..<16]), to: Array(syn[16..<20]), protocolNumber: 6, length: tcp.count)
            XCTAssertEqual(ScriptedPeer.checksum(tcp, initial: pseudo), 0, "the TCP checksum")
            let port = UInt16(tcp[0]) << 8 | UInt16(tcp[1])
            XCTAssertGreaterThanOrEqual(port, 49152, "macOS's ephemeral range")
        }
        let clocks = syns.map { ScriptedPeer.word(Array($0[20...]), 32) }
        XCTAssertGreaterThan(max(clocks[0], clocks[1]) &- min(clocks[0], clocks[1]), 10_000,
                             "each connection's timestamps start from a number of its own (about one run in 200 000 fails by chance)")
    }

    func testANameIsAskedOfThePushedServerThroughTheTunnel() {
        let client = connectClient()
        defer { close(client) }
        let (reply, _) = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                                  request: TestSockets.connectRequest(name: "Known.Test", port: 7))
        XCTAssertEqual(reply, 0)
        XCTAssertEqual(peer.questions.map(\.name), ["known.test"])
        XCTAssertEqual(peer.questions.map(\.from), ["10.99.0.2"])
        TestSockets.sendAll(client, Array("x".utf8))
        XCTAssertEqual(TestSockets.receive(client, count: 6), Array("echo:x".utf8))
    }

    func testANameThatDoesNotExistIsHostUnreachable() {
        let client = connectClient()
        defer { close(client) }
        let (reply, _) = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                                  request: TestSockets.connectRequest(name: "unknown.test", port: 80))
        XCTAssertEqual(reply, SOCKS5Server.Reply.hostUnreachable.rawValue)
    }

    func testAResetIsConnectionRefused() {
        let client = connectClient()
        defer { close(client) }
        let (reply, _) = TestSockets.socksConnect(client, username: TestSockets.username, password: TestSockets.password,
                                                  request: TestSockets.connectRequest(ipv4: [10, 99, 0, 1], port: 9))
        XCTAssertEqual(reply, SOCKS5Server.Reply.connectionRefused.rawValue)
    }

    func testAFamilyTheTunnelLacksIsNetworkUnreachableAndBindIsRefused() {
        let six = connectClient()
        defer { close(six) }
        var request: [UInt8] = [5, 1, 0, 4]
        request += TunnelAddress("2001:db8::1")!.bytes
        request += [0, 80]
        XCTAssertEqual(TestSockets.socksConnect(six, username: TestSockets.username, password: TestSockets.password, request: request).reply,
                       SOCKS5Server.Reply.networkUnreachable.rawValue)
        let bind = connectClient()
        defer { close(bind) }
        XCTAssertEqual(TestSockets.socksConnect(bind, username: TestSockets.username, password: TestSockets.password,
                                                request: [5, 2, 0, 1, 10, 99, 0, 1, 0, 80]).reply,
                       SOCKS5Server.Reply.commandNotSupported.rawValue)
    }

    func testAUDPAssociationCarriesADatagramThroughTheTunnelAndBack() throws {
        let control = connectClient()
        defer { close(control) }
        TestSockets.sendAll(control, [5, 1, 2])
        XCTAssertEqual(TestSockets.receive(control, count: 2), [5, 2])
        let user = Array(TestSockets.username.utf8), pass = Array(TestSockets.password.utf8)
        var auth: [UInt8] = [1, UInt8(user.count)]
        auth += user
        auth.append(UInt8(pass.count))
        auth += pass
        TestSockets.sendAll(control, auth)
        XCTAssertEqual(TestSockets.receive(control, count: 2), [1, 0])
        TestSockets.sendAll(control, [5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
        let reply = TestSockets.receive(control, count: 10)
        XCTAssertEqual(Array(reply.prefix(4)), [5, 0, 0, 1])
        XCTAssertEqual(Array(reply[4..<8]), [127, 0, 0, 1], "the association's socket is on loopback")
        let relayPort = UInt16(reply[8]) << 8 | UInt16(reply[9])

        let socketDescriptor = socket(AF_INET, TestSockets.datagram, 0)
        defer { close(socketDescriptor) }
        TestSockets.setTimeout(socketDescriptor, seconds: 5)
        var storage = sockaddr_storage()
        let length = TunnelSystem.fill(&storage, address: TunnelAddress("127.0.0.1")!, port: relayPort)
        var datagram: [UInt8] = [0, 0, 0, 1, 10, 99, 0, 1, 0, 7]
        datagram += Array("ping".utf8)
        _ = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketDescriptor, datagram, datagram.count, 0, $0, length) } }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recv(socketDescriptor, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(count, 10)
        let answer = Array(buffer[0..<max(0, count)])
        XCTAssertEqual(Array(answer.prefix(10)), [0, 0, 0, 1, 10, 99, 0, 1, 0, 7], "from the far side's address and port")
        XCTAssertEqual(Array(answer.dropFirst(10)), Array("echo:ping".utf8))
        XCTAssertTrue(peer.udpSources.contains { $0.hasPrefix("10.99.0.2:") && $0.hasSuffix(">10.99.0.1:7") }, "from the tunnel's address")
    }
}

extension ScriptedPeerTests {
    /// A client that sends its first bytes with the request, before the reply (optimistic data):
    /// they wait in its socket and go out once the connection is up.
    func testBytesSentBeforeTheReplyGoOutOnceTheConnectionIsUp() {
        let client = connectClient()
        defer { close(client) }
        TestSockets.sendAll(client, [5, 1, 2])
        XCTAssertEqual(TestSockets.receive(client, count: 2), [5, 2])
        let user = Array(TestSockets.username.utf8), pass = Array(TestSockets.password.utf8)
        var auth: [UInt8] = [1, UInt8(user.count)]
        auth += user
        auth.append(UInt8(pass.count))
        auth += pass
        TestSockets.sendAll(client, auth)
        XCTAssertEqual(TestSockets.receive(client, count: 2), [1, 0])
        var request = TestSockets.connectRequest(name: "known.test", port: 7)
        request += Array("early".utf8)
        TestSockets.sendAll(client, request)
        let reply = TestSockets.receive(client, count: 10)
        XCTAssertEqual(reply.first.map { _ in reply[1] }, 0)
        XCTAssertEqual(TestSockets.receive(client, count: 10), Array("echo:early".utf8))
    }
}

extension ScriptedPeerTests {
    /// A UDP association whose request names its sender takes that sender only: another socket of
    /// this Mac that sends first is not carried.
    func testAUDPAssociationThatNamesItsSenderTakesNoOther() {
        let socketDescriptor = socket(AF_INET, TestSockets.datagram, 0)
        let intruder = socket(AF_INET, TestSockets.datagram, 0)
        defer { close(socketDescriptor); close(intruder) }
        for descriptor in [socketDescriptor, intruder] {
            var storage = sockaddr_storage()
            let length = TunnelSystem.fill(&storage, address: TunnelAddress("127.0.0.1")!, port: 0)
            _ = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemBind(descriptor, $0, length) } }
            TestSockets.setTimeout(descriptor, seconds: 2)
        }
        let ownPort = TunnelSystem.localAddress(socketDescriptor)!.port
        let control = connectClient()
        defer { close(control) }
        TestSockets.sendAll(control, [5, 1, 2])
        _ = TestSockets.receive(control, count: 2)
        let user = Array(TestSockets.username.utf8), pass = Array(TestSockets.password.utf8)
        var auth: [UInt8] = [1, UInt8(user.count)]
        auth += user
        auth.append(UInt8(pass.count))
        auth += pass
        TestSockets.sendAll(control, auth)
        _ = TestSockets.receive(control, count: 2)
        TestSockets.sendAll(control, [5, 3, 0, 1, 127, 0, 0, 1, UInt8(ownPort >> 8), UInt8(ownPort & 0xFF)])
        let reply = TestSockets.receive(control, count: 10)
        XCTAssertEqual(reply.count, 10)
        let relayPort = UInt16(reply[8]) << 8 | UInt16(reply[9])
        var relay = sockaddr_storage()
        let length = TunnelSystem.fill(&relay, address: TunnelAddress("127.0.0.1")!, port: relayPort)
        var datagram: [UInt8] = [0, 0, 0, 1, 10, 99, 0, 1, 0, 7]
        datagram += Array("x".utf8)
        // The intruder first: nothing comes back to it, and nothing went out for it.
        _ = withUnsafePointer(to: &relay) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(intruder, datagram, datagram.count, 0, $0, length) } }
        var buffer = [UInt8](repeating: 0, count: 2048)
        XCTAssertLessThan(recv(intruder, &buffer, buffer.count, 0), 0, "the intruder gets nothing")
        XCTAssertTrue(peer.udpSources.filter { $0.hasSuffix(">10.99.0.1:7") }.isEmpty, "and nothing went out for it")
        // The named sender is carried.
        _ = withUnsafePointer(to: &relay) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketDescriptor, datagram, datagram.count, 0, $0, length) } }
        XCTAssertGreaterThan(recv(socketDescriptor, &buffer, buffer.count, 0), 10)
    }
}
