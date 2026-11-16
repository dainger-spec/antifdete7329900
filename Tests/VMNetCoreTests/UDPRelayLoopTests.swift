#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// A SOCKS5 proxy with a UDP relay, for the tests: UDP ASSOCIATE on loopback (with or without a
/// sign-in), a relay socket per association, and what each datagram asked for noted. Its relay
/// answers as `answer` says — by default as an echo from the destination, a name answered from
/// `nameAddress` as a real proxy that resolved it would. It can refuse UDP, stay silent, name a
/// relay of its own choosing, answer from another socket, and end an association.
final class FakeUDPProxy: @unchecked Sendable {
    enum Behaviour {
        case relay
        /// UDP ASSOCIATE answered with this REP code.
        case refuse(UInt8)
        /// The connection is taken and never answered.
        case silent
        /// The association is ended (its TCP connection closed) this long after it came up.
        case closeAfter(Double)
    }

    /// One datagram the relay received from the client.
    struct Datagram: Equatable {
        var type: UInt8
        var host: String
        var port: UInt16
        var payload: [UInt8]
    }

    let port: Int
    private let listener: Int32
    private let behaviour: Behaviour
    private let credentials: (String, String)?
    /// BND.ADDR as the proxy names it (ATYP and address); nil: 127.0.0.1, the relay's own.
    private let boundAddress: [UInt8]?
    /// Where a name's answers come from: an IPv4 address (as a resolving proxy answers), or nil
    /// for the name itself (ATYP 3).
    private let nameAddress: UInt32?
    /// Answers come from another socket than the relay the proxy named.
    private let answerFromElsewhere: Bool
    /// The raw datagrams to send back for one received; nil: the echo.
    private let answer: (@Sendable (Datagram) -> [[UInt8]])?
    private let stopped = Locked(false)
    private let running = Locked(0)
    private let open = Locked<[Int32]>([])
    let associations = Locked(0)
    let datagrams = Locked<[Datagram]>([])
    let usernames = Locked<[String]>([])

    init(behaviour: Behaviour = .relay, credentials: (String, String)? = nil, boundAddress: [UInt8]? = nil,
         nameAddress: UInt32? = 0x5DB8_D822, answerFromElsewhere: Bool = false,
         answer: (@Sendable (Datagram) -> [[UInt8]])? = nil) {
        self.behaviour = behaviour
        self.credentials = credentials
        self.boundAddress = boundAddress
        self.nameAddress = nameAddress
        self.answerFromElsewhere = answerFromElsewhere
        self.answer = answer
        let (descriptor, port) = TestSocket.listen()
        listener = descriptor
        self.port = port
        running.update { $0 += 1 }
        let thread = Thread { [self] in
            while !stopped.value {
                let connection = TestSocket.accept(listener, timeout: 0.05)
                guard connection >= 0 else { continue }
                open.update { $0.append(connection) }
                running.update { $0 += 1 }
                let handler = Thread { [self] in
                    serve(connection)
                    open.update { list in list.removeAll { $0 == connection } }
                    Sys.close(connection)
                    running.update { $0 -= 1 }
                }
                handler.stackSize = 1 << 20
                handler.start()
            }
            running.update { $0 -= 1 }
        }
        thread.start()
    }

    func upstream(username: String? = nil, password: String? = nil) -> VMNetUpstream {
        .socks5(host: "127.0.0.1", port: port, username: username, password: password)
    }

    func stop() {
        stopped.value = true
        for connection in open.value { _ = shutdown(connection, Int32(SHUT_RDWR)) }
        let deadline = Sys.now + 10
        while running.value > 0 && Sys.now < deadline { usleep(2_000) }
        Sys.close(listener)
    }

    private func serve(_ connection: Int32) {
        guard let greeting = TestSocket.read(connection, exactly: 2), greeting[0] == 5,
              let methods = TestSocket.read(connection, exactly: Int(greeting[1])) else { return }
        if case .silent = behaviour {
            while !stopped.value { usleep(10_000) }
            return
        }
        if let credentials {
            guard methods.contains(2) else {
                TestSocket.write(connection, [5, 0xFF])
                return
            }
            TestSocket.write(connection, [5, 2])
            guard let head = TestSocket.read(connection, exactly: 2), let user = TestSocket.read(connection, exactly: Int(head[1])),
                  let length = TestSocket.read(connection, exactly: 1), let password = TestSocket.read(connection, exactly: Int(length[0])) else { return }
            usernames.update { $0.append(String(decoding: user, as: UTF8.self)) }
            guard String(decoding: user, as: UTF8.self) == credentials.0, String(decoding: password, as: UTF8.self) == credentials.1 else {
                TestSocket.write(connection, [1, 1])
                return
            }
            TestSocket.write(connection, [1, 0])
        } else {
            TestSocket.write(connection, [5, 0])
        }
        // UDP ASSOCIATE with an address of all zeros, nothing else.
        guard let request = TestSocket.read(connection, exactly: 10), request == [5, 3, 0, 1, 0, 0, 0, 0, 0, 0] else {
            TestSocket.write(connection, [5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
            return
        }
        if case .refuse(let code) = behaviour {
            TestSocket.write(connection, [5, code, 0, 1, 0, 0, 0, 0, 0, 0])
            return
        }
        let (relay, relayPort) = UDPTestSocket.bind()
        let elsewhere = answerFromElsewhere ? UDPTestSocket.bind().descriptor : -1
        defer {
            Sys.close(relay)
            if elsewhere >= 0 { Sys.close(elsewhere) }
        }
        associations.update { $0 += 1 }
        let bound = boundAddress ?? [1, 127, 0, 0, 1]
        TestSocket.write(connection, [5, 0, 0] + bound + [UInt8(relayPort >> 8), UInt8(relayPort & 0xFF)])
        let began = Sys.now
        while !stopped.value {
            if case .closeAfter(let seconds) = behaviour, Sys.now - began >= seconds { return }
            // The association ends with its connection.
            if TestSocket.waitFor(connection, Sys.readable, timeout: 0.001), TestSocket.read(connection, timeout: 0.01).isEmpty { return }
            guard let (bytes, client) = UDPTestSocket.receive(relay, timeout: 0.02) else { continue }
            guard let datagram = Self.parse(bytes) else { continue }
            datagrams.update { $0.append(datagram) }
            let replies = answer?(datagram) ?? [echo(datagram)]
            for reply in replies { UDPTestSocket.send(elsewhere >= 0 ? elsewhere : relay, reply, to: client) }
        }
    }

    /// The datagram back, from where it went: a name from `nameAddress` (or as the name).
    private func echo(_ datagram: Datagram) -> [UInt8] {
        let port = [UInt8(datagram.port >> 8), UInt8(datagram.port & 0xFF)]
        if datagram.type == 3 {
            if let nameAddress { return [0, 0, 0, 1] + Wire.quad(nameAddress) + port + datagram.payload }
            return [0, 0, 0, 3, UInt8(datagram.host.utf8.count)] + Array(datagram.host.utf8) + port + datagram.payload
        }
        return [0, 0, 0, 1] + Wire.quad(VMNetIPv4(string: datagram.host)!.value) + port + datagram.payload
    }

    private static func parse(_ bytes: [UInt8]) -> Datagram? {
        guard bytes.count >= 10, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0 else { return nil }
        switch bytes[3] {
        case 1:
            let host = bytes[4..<8].map(String.init).joined(separator: ".")
            return Datagram(type: 1, host: host, port: UInt16(bytes[8]) << 8 | UInt16(bytes[9]), payload: Array(bytes[10...]))
        case 3:
            let length = Int(bytes[4])
            guard bytes.count >= 7 + length else { return nil }
            let host = String(decoding: bytes[5..<(5 + length)], as: UTF8.self)
            return Datagram(type: 3, host: host, port: UInt16(bytes[5 + length]) << 8 | UInt16(bytes[6 + length]),
                            payload: Array(bytes[(7 + length)...]))
        default:
            return nil
        }
    }
}

/// UDP sockets on loopback for the test doubles.
enum UDPTestSocket {
    static func bind() -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, Sys.datagramType, 0)
        precondition(descriptor >= 0, "no socket")
        var address = loopback(port: 0)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(status == 0, "bind failed")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }

    private static func systemBind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(descriptor, address, length)
        #else
        return Glibc.bind(descriptor, address, length)
        #endif
    }

    static func receive(_ descriptor: Int32, timeout: Double) -> ([UInt8], sockaddr_in)? {
        guard TestSocket.waitFor(descriptor, Sys.readable, timeout: timeout) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, bytes.baseAddress, bytes.count, Int32(MSG_DONTWAIT), $0, &length)
                }
            }
        }
        guard count >= 0 else { return nil }
        return (Array(buffer[0..<count]), from)
    }

    static func send(_ descriptor: Int32, _ bytes: [UInt8], to address: sockaddr_in) {
        var target = address
        _ = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// The guest's UDP through a proxy's relay over real sockets: the test as a small guest at one
/// end of the wire, a SOCKS5 proxy with a UDP relay on loopback at the other side of the stack.
final class UDPRelayLoopTests: XCTestCase {
    private var network: VMNetwork?
    private var guestEnd: Int32 = -1
    private var stackEnd: Int32 = -1
    private var proxies: [FakeUDPProxy] = []
    private var tcpProxies: [FakeProxy] = []
    private let logLines = Locked<[String]>([])
    private let literal = VMNetIPv4(string: "203.0.113.9")!

    override class func setUp() {
        super.setUp()
        TestSocket.raiseDescriptorLimit(to: 4096)
    }

    override func tearDown() {
        network?.stop()
        network = nil
        for proxy in proxies { proxy.stop() }
        for proxy in tcpProxies { proxy.stop() }
        proxies = []
        tcpProxies = []
        if guestEnd >= 0 { Sys.close(guestEnd) }
        if stackEnd >= 0 { Sys.close(stackEnd) }
        guestEnd = -1
        stackEnd = -1
        super.tearDown()
    }

    private func proxy(_ behaviour: FakeUDPProxy.Behaviour = .relay, credentials: (String, String)? = nil, boundAddress: [UInt8]? = nil,
                       nameAddress: UInt32? = 0x5DB8_D822, answerFromElsewhere: Bool = false,
                       answer: (@Sendable (FakeUDPProxy.Datagram) -> [[UInt8]])? = nil) -> FakeUDPProxy {
        let proxy = FakeUDPProxy(behaviour: behaviour, credentials: credentials, boundAddress: boundAddress, nameAddress: nameAddress,
                                 answerFromElsewhere: answerFromElsewhere, answer: answer)
        proxies.append(proxy)
        return proxy
    }

    @discardableResult
    private func start(_ upstream: VMNetUpstream, relaysUDP: Bool = true, blocked: [String] = [],
                       configure: (inout NetworkLoop.Options) -> Void = { _ in }) -> TestGuest {
        let (first, second) = TestSocket.datagramPair()
        stackEnd = first
        guestEnd = second
        var configuration = Wire.configuration(upstream: upstream, blocked: blocked)
        configuration.relaysUDP = relaysUDP
        let network = VMNetwork(configuration: configuration, frameDescriptor: first)
        var options = network.options
        configure(&options)
        network.options = options
        let lines = logLines
        network.log = { line in lines.update { $0.append(line) } }
        network.start()
        self.network = network
        return TestGuest(descriptor: second)
    }

    private func waitForCounters(timeout: Double = 3, _ condition: (VMNetCounters) -> Bool) -> VMNetCounters {
        let deadline = Sys.now + timeout
        while true {
            let counters = network!.counters()
            if condition(counters) || Sys.now >= deadline { return counters }
            usleep(2_000)
        }
    }

    /// The datagram the guest gets back on `port`, from `remote`:`remotePort`.
    private func answer(_ guest: TestGuest, port: UInt16, from remote: VMNetIPv4, _ remotePort: UInt16, timeout: Double = 3) -> [UInt8]? {
        guest.expect(timeout: timeout) { frame -> [UInt8]? in
            guard let udp = Wire.seenUDP(frame), udp.destinationPort == port, udp.destination == Wire.guest else { return nil }
            XCTAssertTrue(udp.checksumValid)
            XCTAssertEqual(udp.sourceMAC, Wire.gatewayMAC)
            XCTAssertEqual(udp.destinationMAC, Wire.guestMAC)
            XCTAssertEqual(udp.source, remote, "the answer is not from where the guest sent")
            XCTAssertEqual(udp.sourcePort, remotePort)
            return udp.payload
        }
    }

    /// Whether the guest is told "port unreachable" for a datagram to `remote` (in time).
    private func toldUnreachable(_ guest: TestGuest, from remote: VMNetIPv4, timeout: Double = 3) -> Bool {
        guest.expect(timeout: timeout) { frame -> Bool? in
            frame.withUnsafeBytes { bytes -> Bool? in
                guard let ethernet = EthernetFrame(bytes), let packet = IPv4Packet(ethernet.payload), packet.proto == IPProtocol.icmp,
                      let message = ICMPMessage(packet.payload), message.type == ICMPMessage.destinationUnreachable,
                      message.code == ICMPMessage.portUnreachable, packet.source == remote else { return nil }
                return true
            }
        } ?? false
    }

    // MARK: - The way through

    func testUDPToANameGoesToTheProxyAsTheNameAndComesBackFromTheFakeAddress() throws {
        let relay = proxy()
        let guest = start(relay.upstream())
        let fake = try XCTUnwrap(guest.resolve("quic.example")?.address)
        let payload = Array("a QUIC initial packet".utf8)
        guest.send(Wire.udp(from: 50_000, to: fake, 443, payload: payload))
        XCTAssertEqual(answer(guest, port: 50_000, from: fake, 443), payload)
        XCTAssertEqual(relay.datagrams.value, [FakeUDPProxy.Datagram(type: 3, host: "quic.example", port: 443, payload: payload)])
        // Again from the same port: the same association, and the answer from the same address.
        guest.send(Wire.udp(from: 50_000, to: fake, 443, payload: [9, 9]))
        XCTAssertEqual(answer(guest, port: 50_000, from: fake, 443), [9, 9])
        let counters = waitForCounters { $0.datagramsToGuest == 2 }
        XCTAssertEqual(counters.udpAssociationsOpened, 1)
        XCTAssertEqual(counters.udpAssociationsActive, 1)
        XCTAssertEqual(counters.udpAssociationsFailed, 0)
        XCTAssertEqual(counters.datagramsRelayed, 2)
        XCTAssertEqual(counters.datagramsToGuest, 2)
        XCTAssertEqual(counters.udpBytesFromGuest, UInt64(payload.count + 2))
        XCTAssertEqual(counters.udpBytesToGuest, UInt64(payload.count + 2))
        XCTAssertEqual(counters.datagramsDropped, 0)
        XCTAssertEqual(relay.associations.value, 1)
        // The host is in the machine's list with what went each way.
        let deadline = Sys.now + 3
        var host: VMNetHost?
        while Sys.now < deadline {
            host = network?.hosts().first { $0.name == "quic.example" }
            if host?.bytesToGuest == UInt64(payload.count + 2) { break }
            usleep(10_000)
        }
        XCTAssertEqual(host?.connections, 1)
        XCTAssertEqual(host?.bytesFromGuest, UInt64(payload.count + 2))
    }

    func testANameAnsweredAsANameAndALiteralAddressAsAnAddress() throws {
        let relay = proxy(nameAddress: nil)
        let guest = start(relay.upstream())
        let fake = try XCTUnwrap(guest.resolve("stun.example")?.address)
        guest.send(Wire.udp(from: 50_001, to: fake, 3478, payload: [1]))
        XCTAssertEqual(answer(guest, port: 50_001, from: fake, 3478), [1])
        // A peer's address as written: to the proxy as an address, back from it.
        guest.send(Wire.udp(from: 50_001, to: literal, 19_302, payload: [2]))
        XCTAssertEqual(answer(guest, port: 50_001, from: literal, 19_302), [2])
        XCTAssertEqual(relay.datagrams.value.map(\.type), [3, 1])
        XCTAssertEqual(relay.datagrams.value.last?.host, "203.0.113.9")
        // Both from one guest port: one association, one relay port at the proxy — what a peer
        // that learned it (a server-reflexive candidate) reaches.
        XCTAssertEqual(relay.associations.value, 1)
        // Another port of the guest's: an association of its own.
        guest.send(Wire.udp(from: 50_002, to: literal, 19_302, payload: [3]))
        XCTAssertEqual(answer(guest, port: 50_002, from: literal, 19_302), [3])
        XCTAssertEqual(waitForCounters { $0.udpAssociationsOpened == 2 }.udpAssociationsActive, 2)
    }

    func testUDPAssociateWithASignIn() throws {
        let relay = proxy(credentials: ("the-user", "the-pass"))
        let guest = start(relay.upstream(username: "the-user", password: "the-pass"))
        guest.send(Wire.udp(from: 50_003, to: literal, 443, payload: [7]))
        XCTAssertEqual(answer(guest, port: 50_003, from: literal, 443), [7])
        XCTAssertEqual(relay.usernames.value, ["the-user"])
    }

    func testARelayNamedAtAPrivateAddressIsTheProxysOwn() throws {
        // A proxy behind NAT names its address inside its own network: the datagrams go to the
        // proxy's own address, with the port it named.
        let relay = proxy(boundAddress: [1, 10, 9, 9, 9])
        let guest = start(relay.upstream())
        guest.send(Wire.udp(from: 50_004, to: literal, 443, payload: [4]))
        XCTAssertEqual(answer(guest, port: 50_004, from: literal, 443), [4])
        let unspecified = proxy(boundAddress: [1, 0, 0, 0, 0])
        network?.stop()
        Sys.close(guestEnd)
        Sys.close(stackEnd)
        let again = start(unspecified.upstream())
        again.send(Wire.udp(from: 50_005, to: literal, 443, payload: [5]))
        XCTAssertEqual(answer(again, port: 50_005, from: literal, 443), [5])
    }

    // MARK: - What is never relayed

    func testDNSAndTheTimeStayHereAndPrivateDestinationsNeverReachTheProxy() throws {
        let relay = proxy()
        let guest = start(relay.upstream())
        // DNS to any resolver and the time from any server: answered by the stack.
        XCTAssertEqual(guest.resolve("fine.example", server: VMNetIPv4(string: "8.8.8.8")!)?.code, 0)
        var ntp = [UInt8](repeating: 0, count: 48)
        ntp[0] = 0x23
        guest.send(Wire.udp(from: 50_010, to: VMNetIPv4(string: "17.253.52.125")!, 123, payload: ntp))
        XCTAssertNotNil(guest.expect { frame -> Bool? in
            guard let udp = Wire.seenUDP(frame), udp.sourcePort == 123, udp.destinationPort == 50_010 else { return nil }
            return true
        })
        // Somebody's local network, this machine, the guest's own network, a fake address nobody
        // was given, the never-relayed ports: "port unreachable", and the proxy hears nothing.
        let refused = ["10.1.2.3", "172.16.5.5", "192.168.0.10", "127.0.0.1", "169.254.169.254", "100.64.0.1",
                       "192.168.1.1", "198.19.200.200", "0.1.2.3", "240.0.0.1"]
        for (index, text) in refused.enumerated() {
            let address = VMNetIPv4(string: text)!
            guest.send(Wire.udp(from: UInt16(50_100 + index), to: address, 443, payload: [1]))
            XCTAssertTrue(toldUnreachable(guest, from: address), text)
        }
        for port: UInt16 in [5353, 5355, 1900, 137] {
            guest.send(Wire.udp(from: 50_200, to: literal, port, payload: [1]))
            XCTAssertTrue(toldUnreachable(guest, from: literal), "port \(port)")
        }
        // Broadcast and multicast: nothing at all.
        guest.send(Wire.udp(from: 5353, to: VMNetIPv4(0xE000_00FB), 5353, payload: [1], destinationMAC: VMNetMAC(string: "01:00:5e:00:00:fb")!))
        guest.send(Wire.udp(from: 50_300, to: .broadcast, 443, payload: [1], destinationMAC: .broadcast))
        XCTAssertTrue(guest.hearsNothing(for: 0.3))
        let counters = waitForCounters { $0.datagramsDropped >= UInt64(refused.count + 6) }
        XCTAssertEqual(counters.udpAssociationsOpened, 0)
        XCTAssertEqual(counters.datagramsRelayed, 0)
        XCTAssertEqual(relay.associations.value, 0)
        XCTAssertTrue(relay.datagrams.value.isEmpty)
        XCTAssertEqual(counters.dnsQueries, 1)
        XCTAssertEqual(counters.timeQueries, 1)
    }

    func testABlockedNameIsRefusedOverUDPAndItsAnswersAreNotShownOnceBlocked() throws {
        let relay = proxy()
        let guest = start(relay.upstream(), blocked: ["updates.example"])
        XCTAssertEqual(guest.resolve("swscan.updates.example")?.code, 3)
        let fake = try XCTUnwrap(guest.resolve("ads.example")?.address)
        guest.send(Wire.udp(from: 50_020, to: fake, 443, payload: [1]))
        XCTAssertEqual(answer(guest, port: 50_020, from: fake, 443), [1])
        network?.block(host: "ads.example")
        usleep(100_000)
        guest.send(Wire.udp(from: 50_020, to: fake, 443, payload: [2]))
        XCTAssertTrue(toldUnreachable(guest, from: fake))
        XCTAssertEqual(relay.datagrams.value.count, 1)
    }

    func testWithoutTheRelayOrWithAnHTTPProxyUDPIsUnreachableAsBefore() throws {
        let relay = proxy()
        var guest = start(relay.upstream(), relaysUDP: false)
        guest.send(Wire.udp(from: 50_030, to: literal, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: literal))
        XCTAssertEqual(relay.associations.value, 0)
        network?.stop()
        Sys.close(guestEnd)
        Sys.close(stackEnd)

        // An HTTP CONNECT proxy carries no UDP, whatever the configuration says: never a direct path.
        let http = FakeProxy(kind: .http)
        tcpProxies.append(http)
        guest = start(http.upstream(), relaysUDP: true)
        guest.send(Wire.udp(from: 50_031, to: literal, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: literal))
        XCTAssertEqual(http.accepted.value, 0)
        XCTAssertTrue(logLines.value.contains { $0.contains("UDP: not carried, the proxy is not SOCKS5") })
        network?.stop()
        Sys.close(guestEnd)
        Sys.close(stackEnd)

        // No proxy at all.
        guest = start(.none, relaysUDP: true)
        guest.send(Wire.udp(from: 50_032, to: literal, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: literal))
    }

    // MARK: - A proxy that does not carry UDP

    func testAProxyThatRefusesUDPIsNotAskedAgainAndTheGuestIsToldAtOnce() throws {
        let relay = proxy(.refuse(7))
        let guest = start(relay.upstream())
        let began = Sys.now
        guest.send(Wire.udp(from: 50_040, to: literal, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: literal))
        XCTAssertLessThan(Sys.now - began, 2)
        // Later datagrams, from any port: unreachable at once, and the proxy is not asked again.
        for port: UInt16 in 50_041...50_045 {
            guest.send(Wire.udp(from: port, to: literal, 443, payload: [1]))
            XCTAssertTrue(toldUnreachable(guest, from: literal))
        }
        let counters = waitForCounters { $0.udpAssociationsFailed == 1 }
        XCTAssertEqual(counters.udpAssociationsFailed, 1)
        XCTAssertEqual(counters.udpAssociationsOpened, 0)
        XCTAssertEqual(counters.datagramsDropped, 6)
        XCTAssertTrue(logLines.value.contains { $0.contains("the proxy does not carry UDP (UDP ASSOCIATE refused, code 7)") })
        // TCP through the same proxy is another matter: nothing of it changes.
    }

    func testAProxyThatNeverAnswersIsGivenUpOnAndWhatWaitedIsToldUnreachable() throws {
        let relay = proxy(.silent)
        let guest = start(relay.upstream()) { $0.udpSetupTimeout = 0.5 }
        for index in 0..<3 { guest.send(Wire.udp(from: 50_050, to: literal, 443, payload: [UInt8(index)])) }
        let began = Sys.now
        XCTAssertTrue(toldUnreachable(guest, from: literal, timeout: 3))
        XCTAssertGreaterThan(Sys.now - began, 0.3)
        let counters = waitForCounters { $0.udpAssociationsFailed == 1 && $0.datagramsDropped == 3 }
        XCTAssertEqual(counters.udpAssociationsFailed, 1)
        XCTAssertEqual(counters.datagramsDropped, 3)
        XCTAssertEqual(counters.udpAssociationsActive, 0)
    }

    func testAProxyThatIsNotThereFailsTheAssociation() throws {
        let (listener, port) = TestSocket.listen()
        Sys.close(listener)
        let guest = start(.socks5(host: "127.0.0.1", port: port, username: nil, password: nil))
        guest.send(Wire.udp(from: 50_060, to: literal, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: literal))
        XCTAssertEqual(waitForCounters { $0.udpAssociationsFailed == 1 }.udpAssociationsFailed, 1)
    }

    // MARK: - The relay as an adversary

    func testAnswersFromAnotherSocketThanTheRelayAreDropped() throws {
        let relay = proxy(answerFromElsewhere: true)
        let guest = start(relay.upstream())
        guest.send(Wire.udp(from: 50_070, to: literal, 443, payload: [1]))
        XCTAssertNil(answer(guest, port: 50_070, from: literal, 443, timeout: 1))
        XCTAssertEqual(relay.datagrams.value.count, 1)
        XCTAssertEqual(network?.counters().datagramsToGuest, 0)
    }

    func testFragmentsMalformedAnswersAndAnswersFromWhereTheGuestSentNothingAreDropped() throws {
        let stranger = VMNetIPv4(string: "198.51.100.200")!
        let relay = proxy(answer: { datagram in
            let port = [UInt8(datagram.port >> 8), UInt8(datagram.port & 0xFF)]
            let from = Wire.quad(VMNetIPv4(string: datagram.host)!.value)
            return [
                [0, 0, 1, 1] + from + port + [0xF1],                 // FRAG 1
                [0, 0, 0x80, 1] + from + port + [0xF2],              // the last fragment of something
                [1, 0, 0, 1] + from + port + [0xF3],                 // RSV not zero
                [0, 0, 0, 9] + from + port + [0xF4],                 // no such address type
                [0, 0, 0, 1, 1, 2],                                  // cut short
                [],                                                  // empty
                [0, 0, 0, 1] + Wire.quad(stranger.value) + port + [0xF5],   // from where the guest sent nothing
                [0, 0, 0, 1] + from + [0, 1] + [0xF6],               // from another port of the host
                [0, 0, 0, 3, 7] + Array("any.org".utf8) + port + [0xF7],    // a name the guest never sent to
                [0, 0, 0, 1] + from + port + datagram.payload,      // and the real answer, last
            ]
        })
        let guest = start(relay.upstream())
        guest.send(Wire.udp(from: 50_080, to: literal, 443, payload: [0x42]))
        XCTAssertEqual(answer(guest, port: 50_080, from: literal, 443), [0x42])
        XCTAssertTrue(guest.hearsNothing(for: 0.3))
        let counters = waitForCounters { $0.datagramsToGuest == 1 }
        XCTAssertEqual(counters.datagramsToGuest, 1)
        XCTAssertEqual(counters.udpAssociationsActive, 1, "noise from the relay does not end the association")
    }

    func testAnAnswerLargerThanTheGuestsNetworkIsDropped() throws {
        let relay = proxy(answer: { datagram in
            let port = [UInt8(datagram.port >> 8), UInt8(datagram.port & 0xFF)]
            let from = Wire.quad(VMNetIPv4(string: datagram.host)!.value)
            return [[0, 0, 0, 1] + from + port + [UInt8](repeating: 1, count: 1473), [0, 0, 0, 1] + from + port + [UInt8](repeating: 2, count: 1472)]
        })
        let guest = start(relay.upstream())
        guest.send(Wire.udp(from: 50_090, to: literal, 443, payload: [1]))
        XCTAssertEqual(answer(guest, port: 50_090, from: literal, 443)?.count, 1472)
    }

    func testNoiseFromTheGuestOverUDPTrapsNothing() throws {
        let relay = proxy()
        let guest = start(relay.upstream())
        var random = TestRandom(seed: 7)
        for index in 0..<300 {
            var payload = random.bytes(Int(random.next() % 1400))
            if index % 3 == 0 { payload = [] }
            let port = UInt16(1 + random.next() % 65_535)
            let address = VMNetIPv4(UInt32(truncatingIfNeeded: random.next()))
            guest.send(Wire.udp(from: UInt16(40_000 + index % 50), to: address, port, payload: payload))
        }
        // The network still works.
        guest.send(Wire.udp(from: 60_000, to: literal, 443, payload: [0x77]))
        XCTAssertEqual(answer(guest, port: 60_000, from: literal, 443, timeout: 5), [0x77])
        XCTAssertNotNil(guest.resolve("still.example"))
        // Nothing went to an address that is not public.
        for datagram in relay.datagrams.value where datagram.type == 1 {
            XCTAssertFalse(DestinationPolicy.isRefusedRange(VMNetIPv4(string: datagram.host)!), datagram.host)
        }
    }

    // MARK: - Endings and limits

    func testTheProxyEndingAnAssociationEndsItAndTheNextDatagramMakesANewOne() throws {
        let relay = proxy(.closeAfter(0.3))
        let guest = start(relay.upstream())
        guest.send(Wire.udp(from: 50_100, to: literal, 443, payload: [1]))
        XCTAssertEqual(answer(guest, port: 50_100, from: literal, 443), [1])
        let ended = waitForCounters { $0.udpAssociationsOpened == 1 && $0.udpAssociationsActive == 0 }
        XCTAssertEqual(ended.udpAssociationsActive, 0)
        guest.send(Wire.udp(from: 50_100, to: literal, 443, payload: [2]))
        XCTAssertEqual(answer(guest, port: 50_100, from: literal, 443), [2])
        XCTAssertEqual(relay.associations.value, 2)
    }

    func testAQuietAssociationIsClosed() throws {
        let relay = proxy()
        let guest = start(relay.upstream()) { $0.udpIdleTimeout = 0.4 }
        guest.send(Wire.udp(from: 50_110, to: literal, 443, payload: [1]))
        XCTAssertEqual(answer(guest, port: 50_110, from: literal, 443), [1])
        let closed = waitForCounters { $0.udpAssociationsOpened == 1 && $0.udpAssociationsActive == 0 }
        XCTAssertEqual(closed.udpAssociationsActive, 0)
    }

    func testNoMoreAssociationsThanTheLimitAndNoMoreWaitingThanTheQueue() throws {
        let relay = proxy()
        let guest = start(relay.upstream()) { $0.maximumUDPAssociations = 2 }
        for port: UInt16 in [50_120, 50_121] {
            guest.send(Wire.udp(from: port, to: literal, 443, payload: [1]))
            XCTAssertEqual(answer(guest, port: port, from: literal, 443), [1])
        }
        // A third port while both are in use: unreachable, not a third association.
        guest.send(Wire.udp(from: 50_122, to: literal, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: literal))
        XCTAssertEqual(relay.associations.value, 2)
        network?.stop()
        Sys.close(guestEnd)
        Sys.close(stackEnd)

        // A proxy that is slow to answer: at most the queue's worth waits.
        let silent = proxy(.silent)
        let slowGuest = start(silent.upstream()) { $0.udpSetupTimeout = 1 }
        for index in 0..<(UDPAssociation.waitingLimit + 8) {
            slowGuest.send(Wire.udp(from: 50_130, to: literal, 443, payload: [UInt8(index)]))
        }
        let counters = waitForCounters(timeout: 4) { $0.udpAssociationsFailed == 1 && $0.datagramsDropped == UInt64(UDPAssociation.waitingLimit + 8) }
        XCTAssertEqual(counters.datagramsDropped, UInt64(UDPAssociation.waitingLimit + 8))
    }

    func testStopClosesEveryAssociationAndLeaksNoDescriptor() throws {
        let relay = proxy()
        let before = TestSocket.openDescriptorCount()
        let guest = start(relay.upstream())
        for index in 0..<10 {
            let port = UInt16(50_200 + index)
            guest.send(Wire.udp(from: port, to: literal, 443, payload: [1]))
            XCTAssertEqual(answer(guest, port: port, from: literal, 443), [1])
        }
        XCTAssertEqual(network?.counters().udpAssociationsActive, 10)
        network?.stop()
        XCTAssertEqual(network?.counters().udpAssociationsActive, 0)
        network = nil
        Sys.close(guestEnd)
        Sys.close(stackEnd)
        guestEnd = -1
        stackEnd = -1
        // The proxy's side closes as it notices; the network's own are closed already: nothing is
        // left of it, no connection to the proxy, no socket to its relay, no pipe.
        let deadline = Sys.now + 3
        var after = TestSocket.openDescriptorCount()
        while after > before && Sys.now < deadline {
            usleep(10_000)
            after = TestSocket.openDescriptorCount()
        }
        XCTAssertEqual(after, before)
    }

    // MARK: - The log

    func testTheLogSaysUDPInCountsAndNamesNothing() throws {
        let relay = proxy(credentials: ("the-user-name", "the-pass-word"))
        let guest = start(relay.upstream(username: "the-user-name", password: "the-pass-word"))
        let fake = try XCTUnwrap(guest.resolve("secret-site.example")?.address)
        guest.send(Wire.udp(from: 50_300, to: fake, 443, payload: [1]))
        XCTAssertNotNil(answer(guest, port: 50_300, from: fake, 443))
        guest.send(Wire.udp(from: 50_301, to: VMNetIPv4(string: "10.20.30.40")!, 443, payload: [1]))
        XCTAssertTrue(toldUnreachable(guest, from: VMNetIPv4(string: "10.20.30.40")!))
        network?.stop()
        let lines = logLines.value
        XCTAssertTrue(lines.contains { $0.contains("UDP: through the proxy's relay") })
        XCTAssertTrue(lines.contains { $0.contains("UDP refused, not a public address") })
        XCTAssertTrue(lines.contains { $0.contains("datagrams relayed 1, to the guest 1; UDP associations opened 1, failed 0") })
        let forbidden = ["secret-site", "example", fake.string, "198.18.", "10.20.30.40", "93.184", "the-user-name", "the-pass-word",
                         "127.0.0.1", "\(relay.port)"]
        for line in lines {
            for word in forbidden { XCTAssertFalse(line.contains(word), "the log line \"\(line)\" holds \"\(word)\"") }
        }
    }
}
