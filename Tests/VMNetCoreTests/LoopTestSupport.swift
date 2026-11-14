#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// A proxy for the tests: it listens on loopback, speaks SOCKS5 or HTTP CONNECT as a real one
/// does (or misbehaves as told), notes what it was asked, and is its own destination — once the
/// tunnel is up, `origin` runs on the connection.
final class FakeProxy: @unchecked Sendable {
    enum Kind { case socks5, http }

    enum Behaviour {
        /// Open the tunnel.
        case tunnel
        /// Refuse the request: SOCKS5's reply code, or HTTP's status.
        case refuse(Int)
        /// Answer the first bytes with these, whatever was asked.
        case garbage([UInt8])
        /// Accept the connection and never say a word.
        case silent
        /// Wait this long before opening the tunnel.
        case slow(Double)
    }

    /// What one connection asked for.
    struct Request: Equatable {
        var host = ""
        var port = 0
        /// SOCKS5: the destination came as a name (address type 3), not as an IPv4 address.
        var byName = false
        var username: String?
        var password: String?
        /// HTTP: the request's lines.
        var lines: [String] = []
    }

    let kind: Kind
    let port: Int
    private let listener: Int32
    private let credentials: (String, String)?
    private let behaviour: Behaviour
    /// HTTP only: bytes sent in the same write as the "200" answer.
    private let afterHeaders: [UInt8]
    private let origin: @Sendable (Int32) -> Void
    private let stopped = Locked(false)
    private let running = Locked(0)
    private let open = Locked<[Int32]>([])
    let requests = Locked<[Request]>([])
    let accepted = Locked(0)

    init(kind: Kind, credentials: (String, String)? = nil, behaviour: Behaviour = .tunnel, afterHeaders: [UInt8] = [],
         origin: @escaping @Sendable (Int32) -> Void = { _ in }) {
        self.kind = kind
        self.credentials = credentials
        self.behaviour = behaviour
        self.afterHeaders = afterHeaders
        self.origin = origin
        let (descriptor, port) = TestSocket.listen()
        listener = descriptor
        self.port = port
        running.update { $0 += 1 }
        let thread = Thread { [self] in
            while !stopped.value {
                let connection = TestSocket.accept(listener, timeout: 0.05)
                guard connection >= 0 else { continue }
                accepted.update { $0 += 1 }
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

    /// As `VMNetUpstream` names this proxy.
    func upstream(host: String = "127.0.0.1", username: String? = nil, password: String? = nil) -> VMNetUpstream {
        switch kind {
        case .socks5: return .socks5(host: host, port: port, username: username, password: password)
        case .http: return .httpConnect(host: host, port: port, username: username, password: password)
        }
    }

    /// Ends the proxy: its connections are cut and its threads have ended when this returns.
    func stop() {
        stopped.value = true
        for connection in open.value { _ = shutdown(connection, Int32(SHUT_RDWR)) }
        let deadline = Sys.now + 10
        while running.value > 0 && Sys.now < deadline { usleep(2_000) }
        Sys.close(listener)
    }

    private func serve(_ connection: Int32) {
        switch behaviour {
        case .garbage(let bytes):
            _ = TestSocket.read(connection, timeout: 2)
            TestSocket.write(connection, bytes)
            _ = TestSocket.read(connection, timeout: 1)
            return
        case .silent:
            while !stopped.value, TestSocket.waitFor(connection, Sys.readable, timeout: 0.05) {
                if TestSocket.read(connection, timeout: 0.05).isEmpty { return }
            }
            while !stopped.value { usleep(10_000) }
            return
        default:
            break
        }
        let opened = kind == .socks5 ? socks(connection) : http(connection)
        if opened { origin(connection) }
    }

    private func socks(_ connection: Int32) -> Bool {
        var request = Request()
        guard let greeting = TestSocket.read(connection, exactly: 2), greeting[0] == 5,
              let methods = TestSocket.read(connection, exactly: Int(greeting[1])) else { return false }
        if let credentials {
            guard methods.contains(2) else {
                TestSocket.write(connection, [5, 0xFF])
                return false
            }
            TestSocket.write(connection, [5, 2])
            guard let head = TestSocket.read(connection, exactly: 2), let user = TestSocket.read(connection, exactly: Int(head[1])),
                  let length = TestSocket.read(connection, exactly: 1), let password = TestSocket.read(connection, exactly: Int(length[0])) else { return false }
            request.username = String(decoding: user, as: UTF8.self)
            request.password = String(decoding: password, as: UTF8.self)
            guard request.username == credentials.0, request.password == credentials.1 else {
                requests.update { $0.append(request) }
                TestSocket.write(connection, [1, 1])
                return false
            }
            TestSocket.write(connection, [1, 0])
        } else {
            TestSocket.write(connection, [5, 0])
        }
        guard let head = TestSocket.read(connection, exactly: 4), head[0] == 5, head[1] == 1 else { return false }
        if head[3] == 3 {
            guard let length = TestSocket.read(connection, exactly: 1), let name = TestSocket.read(connection, exactly: Int(length[0])) else { return false }
            request.host = String(decoding: name, as: UTF8.self)
            request.byName = true
        } else if head[3] == 1 {
            guard let address = TestSocket.read(connection, exactly: 4) else { return false }
            request.host = address.map(String.init).joined(separator: ".")
        } else {
            return false
        }
        guard let port = TestSocket.read(connection, exactly: 2) else { return false }
        request.port = Int(port[0]) << 8 | Int(port[1])
        requests.update { $0.append(request) }
        switch behaviour {
        case .refuse(let code):
            TestSocket.write(connection, [5, UInt8(code), 0, 1, 0, 0, 0, 0, 0, 0])
            return false
        case .slow(let seconds):
            Thread.sleep(forTimeInterval: seconds)
        default:
            break
        }
        return TestSocket.write(connection, [5, 0, 0, 1, 127, 0, 0, 1, 0x12, 0x34])
    }

    private func http(_ connection: Int32) -> Bool {
        guard let (head, _) = TestSocket.read(connection, until: [13, 10, 13, 10]) else { return false }
        var request = Request()
        request.lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let first = request.lines.first?.split(separator: " ").map(String.init) ?? []
        if first.count == 3, let colon = first[1].lastIndex(of: ":") {
            request.host = String(first[1][first[1].startIndex..<colon])
            request.port = Int(first[1][first[1].index(after: colon)...]) ?? 0
            request.byName = true
        }
        requests.update { $0.append(request) }
        if let credentials {
            let expected = "Proxy-Authorization: Basic " + Data("\(credentials.0):\(credentials.1)".utf8).base64EncodedString()
            guard request.lines.contains(expected) else {
                TestSocket.write(connection, Array("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\n\r\n".utf8))
                return false
            }
        }
        switch behaviour {
        case .refuse(let status):
            TestSocket.write(connection, Array("HTTP/1.1 \(status) No\r\nContent-Length: 0\r\n\r\n".utf8))
            return false
        case .slow(let seconds):
            Thread.sleep(forTimeInterval: seconds)
        default:
            break
        }
        return TestSocket.write(connection, Array("HTTP/1.1 200 Connection established\r\nVia: 1.1 test\r\n\r\n".utf8) + afterHeaders)
    }

    // MARK: - Destinations

    /// An HTTP server's answer to one request: the request is read to the end of its headers,
    /// `body` is sent, and the connection is closed.
    static func httpOrigin(body: [UInt8]) -> @Sendable (Int32) -> Void {
        { connection in
            guard TestSocket.read(connection, until: [13, 10, 13, 10]) != nil else { return }
            TestSocket.write(connection, Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body, timeout: 20)
        }
    }

    /// Sends back whatever arrives, until the other side closes.
    static let echo: @Sendable (Int32) -> Void = { connection in
        while true {
            let bytes = TestSocket.read(connection, timeout: 10)
            guard !bytes.isEmpty, TestSocket.write(connection, bytes, timeout: 10) else { return }
        }
    }

    /// Reads everything until the other side closes its sending side, hands it to `done`, and
    /// answers with `reply`.
    static func collector(reply: [UInt8] = [], done: @escaping @Sendable ([UInt8]) -> Void) -> @Sendable (Int32) -> Void {
        { connection in
            let all = TestSocket.readToEnd(connection, timeout: 10)
            done(all)
            if !reply.isEmpty { TestSocket.write(connection, reply) }
        }
    }
}

/// A guest for the tests: the other end of the socket pair, sending the frames a guest's network
/// stack would and reading what comes back.
final class TestGuest {
    let descriptor: Int32
    private var nextPort: UInt16 = 40_000

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ frame: [UInt8]) {
        while true {
            let count = frame.withUnsafeBytes { Sys.send(descriptor, $0) }
            if count >= 0 { return }
            guard errno == EINTR || Sys.wouldBlock(errno) || errno == ENOBUFS else { return }
            _ = TestSocket.waitFor(descriptor, Sys.writable, timeout: 1)
        }
    }

    /// The next frame, or nil when none came in time.
    func receive(timeout: Double) -> [UInt8]? {
        guard TestSocket.waitFor(descriptor, Sys.readable, timeout: timeout) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { Sys.receive(descriptor, $0) }
        return count > 0 ? Array(buffer[0..<count]) : nil
    }

    /// Reads frames until `match` makes something of one; other frames are passed over.
    func expect<Value>(timeout: Double = 3, _ match: ([UInt8]) -> Value?) -> Value? {
        let deadline = Sys.now + timeout
        while true {
            let remaining = deadline - Sys.now
            guard remaining > 0, let frame = receive(timeout: remaining) else { return nil }
            if let value = match(frame) { return value }
        }
    }

    /// True when nothing at all arrives for `seconds`.
    func hearsNothing(for seconds: Double) -> Bool {
        receive(timeout: seconds) == nil
    }

    func freshPort() -> UInt16 {
        nextPort += 1
        return nextPort
    }

    /// DISCOVER and REQUEST; the address the server gave and the options of its ACK.
    func dhcp() -> (address: VMNetIPv4, options: [UInt8: [UInt8]])? {
        send(Wire.udp(from: 68, to: .broadcast, 67, payload: Wire.dhcp(type: 1), source: .unspecified, destinationMAC: .broadcast))
        guard let offer = expect({ frame -> [UInt8]? in
            guard let udp = Wire.seenUDP(frame), udp.destinationPort == 68, Wire.dhcpOptions(udp.payload)[53] == [2] else { return nil }
            return udp.payload
        }) else { return nil }
        let offered = VMNetIPv4(UInt32(offer[16]) << 24 | UInt32(offer[17]) << 16 | UInt32(offer[18]) << 8 | UInt32(offer[19]))
        let server = Wire.dhcpOptions(offer)[54].map { VMNetIPv4(UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3])) }
        send(Wire.udp(from: 68, to: .broadcast, 67, payload: Wire.dhcp(type: 3, requested: offered, server: server),
                      source: .unspecified, destinationMAC: .broadcast))
        return expect { frame -> (VMNetIPv4, [UInt8: [UInt8]])? in
            guard let udp = Wire.seenUDP(frame), udp.destinationPort == 68, Wire.dhcpOptions(udp.payload)[53] == [5] else { return nil }
            return (offered, Wire.dhcpOptions(udp.payload))
        }
    }

    /// "Who has the gateway's address?" — the hardware address in the answer.
    func arpForGateway() -> VMNetMAC? {
        let request = ARPPacket(operation: ARPPacket.request, senderMAC: Wire.guestMAC, senderAddress: Wire.guest,
                                targetMAC: VMNetMAC(raw: 0), targetAddress: Wire.gateway)
        send(request.frame(destination: .broadcast, source: Wire.guestMAC))
        return expect { frame in
            frame.withUnsafeBytes { bytes -> VMNetMAC? in
                guard let ethernet = EthernetFrame(bytes), ethernet.etherType == EtherType.arp, let reply = ARPPacket(ethernet.payload),
                      reply.operation == ARPPacket.reply else { return nil }
                return reply.senderMAC
            }
        }
    }

    /// An address query; the answer's code and address.
    func resolve(_ name: String, type: UInt16 = 1, server: VMNetIPv4 = Wire.gateway) -> (code: Int, address: VMNetIPv4?)? {
        let port = freshPort()
        send(Wire.udp(from: port, to: server, 53, payload: Wire.dnsQuery(name, type: type, id: port)))
        return expect { frame in
            guard let udp = Wire.seenUDP(frame), udp.sourcePort == 53, udp.destinationPort == port, udp.source == server else { return nil }
            let answer = Wire.dnsAnswer(udp.payload)
            return (answer.code, answer.address)
        }
    }
}

/// A very small TCP for the tests' guest: one segment at a time, each sent again until it is
/// acknowledged; what arrives in order is kept and acknowledged, anything else is answered with
/// what is expected.
final class GuestConnection {
    enum Opening {
        case open(GuestConnection)
        /// The SYN was answered with a reset.
        case refused(after: Double)
        case timedOut
    }

    let guest: TestGuest
    let remote: VMNetIPv4
    let remotePort: UInt16
    let localPort: UInt16
    private(set) var sendNext: UInt32
    private(set) var receiveNext: UInt32 = 0
    private var acknowledged: UInt32
    private(set) var received: [UInt8] = []
    private(set) var peerFinished = false
    private(set) var wasReset = false
    /// The largest payload seen in one segment, and how many segments carried data.
    private(set) var largestSegment = 0
    private(set) var dataSegments = 0

    private init(guest: TestGuest, remote: VMNetIPv4, port: UInt16, localPort: UInt16, start: UInt32) {
        self.guest = guest
        self.remote = remote
        remotePort = port
        self.localPort = localPort
        sendNext = start
        acknowledged = start
    }

    /// Sends a SYN (again every `resend` seconds) and waits for the answer.
    static func open(_ guest: TestGuest, to remote: VMNetIPv4, port: UInt16 = 80, timeout: Double = 5, resend: Double = 1) -> Opening {
        let localPort = guest.freshPort()
        let start = UInt32(localPort) &* 1_000
        let connection = GuestConnection(guest: guest, remote: remote, port: port, localPort: localPort, start: start)
        let began = Sys.now
        let syn = Wire.tcp(from: localPort, to: remote, port, sequence: start, flags: [.syn], options: Wire.synOptions())
        while Sys.now - began < timeout {
            guest.send(syn)
            let answer = guest.expect(timeout: min(resend, timeout - (Sys.now - began))) { frame -> SeenTCP? in
                guard let seen = Wire.seenTCP(frame), seen.destinationPort == localPort, seen.sourcePort == port, seen.source == remote else { return nil }
                return seen
            }
            guard let answer else { continue }
            if answer.flags.contains(.rst) { return .refused(after: Sys.now - began) }
            guard answer.flags == [.syn, .ack], answer.acknowledgement == start &+ 1 else { continue }
            connection.sendNext = start &+ 1
            connection.acknowledged = start &+ 1
            connection.receiveNext = answer.sequence &+ 1
            connection.acknowledge()
            return .open(connection)
        }
        return .timedOut
    }

    private func segment(_ flags: TCPFlags, payload: [UInt8] = []) -> [UInt8] {
        // A window of 4096 << 7: far more than any test sends.
        Wire.tcp(from: localPort, to: remote, remotePort, sequence: sendNext, acknowledgement: receiveNext, flags: flags,
                 window: 4_096, payload: payload)
    }

    private func acknowledge() {
        guest.send(segment([.ack]))
    }

    /// Handles the next frame, if one comes in time. False when none did.
    @discardableResult
    func pump(timeout: Double) -> Bool {
        guard let frame = guest.receive(timeout: timeout) else { return false }
        guard let seen = Wire.seenTCP(frame), seen.destinationPort == localPort, seen.sourcePort == remotePort, seen.source == remote else { return true }
        XCTAssertTrue(seen.checksumValid, "a segment with a wrong checksum")
        if seen.flags.contains(.rst) {
            wasReset = true
            return true
        }
        if seen.flags.contains(.ack), sequence(acknowledged, isBefore: seen.acknowledgement) { acknowledged = seen.acknowledgement }
        guard !seen.payload.isEmpty || seen.flags.contains(.fin) else { return true }
        if seen.sequence == receiveNext && !peerFinished {
            received += seen.payload
            receiveNext = receiveNext &+ UInt32(seen.payload.count)
            if !seen.payload.isEmpty {
                dataSegments += 1
                largestSegment = max(largestSegment, seen.payload.count)
            }
            if seen.flags.contains(.fin) {
                receiveNext = receiveNext &+ 1
                peerFinished = true
            }
        }
        acknowledge()
        return true
    }

    /// Sends `bytes`, a segment at a time. False when a segment was never acknowledged.
    func write(_ bytes: [UInt8], segmentSize: Int = 1460) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let length = min(segmentSize, bytes.count - offset)
            let frame = segment([.ack, .psh], payload: Array(bytes[offset..<(offset + length)]))
            let target = sendNext &+ UInt32(length)
            guard sendUntilAcknowledged(frame, target) else { return false }
            sendNext = target
            offset += length
        }
        return true
    }

    /// Sends a FIN and waits for its acknowledgement.
    @discardableResult
    func close() -> Bool {
        let target = sendNext &+ 1
        guard sendUntilAcknowledged(segment([.ack, .fin]), target) else { return false }
        sendNext = target
        return true
    }

    func reset() {
        guest.send(segment([.rst, .ack]))
    }

    private func sendUntilAcknowledged(_ frame: [UInt8], _ target: UInt32) -> Bool {
        for _ in 0..<40 {
            guest.send(frame)
            let deadline = Sys.now + 0.3
            while sequence(acknowledged, isBefore: target) && !wasReset && Sys.now < deadline {
                pump(timeout: deadline - Sys.now)
            }
            if wasReset { return false }
            if !sequence(acknowledged, isBefore: target) { return true }
        }
        return false
    }

    /// Reads until `count` bytes have arrived (or the other side closed, or reset, or time ran out).
    func read(atLeast count: Int, timeout: Double = 10) {
        let deadline = Sys.now + timeout
        while received.count < count && !peerFinished && !wasReset && Sys.now < deadline {
            pump(timeout: deadline - Sys.now)
        }
    }

    /// Reads until the other side closes.
    func readToEnd(timeout: Double = 10) {
        let deadline = Sys.now + timeout
        while !peerFinished && !wasReset && Sys.now < deadline {
            pump(timeout: deadline - Sys.now)
        }
    }

    /// Waits for a reset; true when one came.
    func waitForReset(timeout: Double = 5) -> Bool {
        let deadline = Sys.now + timeout
        while !wasReset && Sys.now < deadline {
            pump(timeout: deadline - Sys.now)
        }
        return wasReset
    }

    /// Takes what has arrived so far.
    func takeReceived() -> [UInt8] {
        defer { received = [] }
        return received
    }
}
