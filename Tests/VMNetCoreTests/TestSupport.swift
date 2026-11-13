#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import VMNetCore

/// A wire that keeps what the stack sends, for the test to look at.
final class CollectingSink: FrameSink {
    var isCongested = false
    private(set) var frames: [[UInt8]] = []

    func send(_ frame: UnsafeRawBufferPointer) {
        frames.append(Array(frame))
    }

    func take() -> [[UInt8]] {
        defer { frames = [] }
        return frames
    }
}

/// A TCP segment the stack sent, read back from its frame.
struct SeenTCP {
    var source: VMNetIPv4
    var destination: VMNetIPv4
    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequence: UInt32
    var acknowledgement: UInt32
    var flags: TCPFlags
    var window: UInt16
    var maximumSegmentSize: UInt16?
    var windowScale: UInt8?
    var payload: [UInt8]
    var checksumValid: Bool
    var frameLength: Int
}

struct SeenUDP {
    var sourceMAC: VMNetMAC
    var destinationMAC: VMNetMAC
    var source: VMNetIPv4
    var destination: VMNetIPv4
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]
    var checksumValid: Bool
}

/// The addresses the tests' guest and gateway have, and frames as that guest would send them.
enum Wire {
    static let guestMAC = VMNetMAC(string: "52:54:00:12:34:56")!
    static let gatewayMAC = VMNetMAC(string: "52:54:00:00:00:01")!
    static let guest = VMNetIPv4(string: "192.168.1.23")!
    static let gateway = VMNetIPv4(string: "192.168.1.1")!

    static func configuration(upstream: VMNetUpstream = .none, blocked: [String] = []) -> VMNetConfiguration {
        VMNetConfiguration(guestMAC: guestMAC, gatewayMAC: gatewayMAC, upstream: upstream, blockedHostSuffixes: blocked)
    }

    /// A TCP segment's frame from the guest to `remote`.
    static func tcp(from sourcePort: UInt16, to remote: VMNetIPv4, _ port: UInt16, sequence: UInt32, acknowledgement: UInt32 = 0,
                    flags: TCPFlags, window: UInt16 = 65_535, options: [UInt8] = [], payload: [UInt8] = [],
                    source: VMNetIPv4 = guest, sourceMAC: VMNetMAC = guestMAC, destinationMAC: VMNetMAC = gatewayMAC) -> [UInt8] {
        let scratch = FrameScratch()
        let length = payload.withUnsafeBytes { bytes in
            FrameBuilder.tcp(into: scratch.buffer, destinationMAC: destinationMAC, sourceMAC: sourceMAC, source: source, sourcePort: sourcePort,
                             destination: remote, destinationPort: port, sequence: sequence, acknowledgement: acknowledgement,
                             flags: flags, window: window, options: options, payload: bytes, identification: 7)
        }
        return Array(UnsafeRawBufferPointer(rebasing: scratch.buffer[0..<length]))
    }

    /// The options of a guest's SYN: its largest segment and its window shift.
    static func synOptions(mss: UInt16? = 1460, scale: UInt8? = 7) -> [UInt8] {
        var options: [UInt8] = []
        if let mss { options += [2, 4, UInt8(mss >> 8), UInt8(mss & 0xFF)] }
        if let scale { options += [1, 3, 3, scale] }
        return options
    }

    static func udp(from sourcePort: UInt16, to destination: VMNetIPv4, _ port: UInt16, payload: [UInt8],
                    source: VMNetIPv4 = guest, sourceMAC: VMNetMAC = guestMAC, destinationMAC: VMNetMAC = gatewayMAC) -> [UInt8] {
        FrameBuilder.udp(destinationMAC: destinationMAC, sourceMAC: sourceMAC, source: source, sourcePort: sourcePort,
                         destination: destination, destinationPort: port, payload: payload, identification: 9)
    }

    static func seenTCP(_ frame: [UInt8]) -> SeenTCP? {
        frame.withUnsafeBytes { bytes -> SeenTCP? in
            guard let ethernet = EthernetFrame(bytes), ethernet.etherType == EtherType.ipv4, let packet = IPv4Packet(ethernet.payload),
                  packet.proto == IPProtocol.tcp, let segment = TCPSegment(packet.payload) else { return nil }
            let sum = InternetChecksum.add(packet.payload, to: InternetChecksum.pseudoHeader(
                source: packet.source, destination: packet.destination, proto: IPProtocol.tcp, length: packet.payload.count))
            return SeenTCP(source: packet.source, destination: packet.destination, sourcePort: segment.sourcePort,
                           destinationPort: segment.destinationPort, sequence: segment.sequence, acknowledgement: segment.acknowledgement,
                           flags: segment.flags, window: segment.window, maximumSegmentSize: segment.maximumSegmentSize,
                           windowScale: segment.windowScale, payload: Array(segment.payload),
                           checksumValid: InternetChecksum.finish(sum) == 0, frameLength: frame.count)
        }
    }

    static func seenUDP(_ frame: [UInt8]) -> SeenUDP? {
        frame.withUnsafeBytes { bytes -> SeenUDP? in
            guard let ethernet = EthernetFrame(bytes), ethernet.etherType == EtherType.ipv4, let packet = IPv4Packet(ethernet.payload),
                  packet.proto == IPProtocol.udp, let datagram = UDPDatagram(packet.payload) else { return nil }
            let sum = InternetChecksum.add(packet.payload, to: InternetChecksum.pseudoHeader(
                source: packet.source, destination: packet.destination, proto: IPProtocol.udp, length: packet.payload.count))
            return SeenUDP(sourceMAC: ethernet.source, destinationMAC: ethernet.destination, source: packet.source,
                           destination: packet.destination, sourcePort: datagram.sourcePort, destinationPort: datagram.destinationPort,
                           payload: Array(datagram.payload), checksumValid: InternetChecksum.finish(sum) == 0)
        }
    }

    /// Runs `body` with a frame's IPv4 packet and TCP segment, as the stack's parser sees them.
    static func withSegment<Result>(_ frame: [UInt8], _ body: (IPv4Packet, TCPSegment) -> Result) -> Result {
        frame.withUnsafeBytes { bytes in
            let ethernet = EthernetFrame(bytes)!
            let packet = IPv4Packet(ethernet.payload)!
            return body(packet, TCPSegment(packet.payload)!)
        }
    }

    /// A DNS query for `name`.
    static func dnsQuery(_ name: String, type: UInt16 = 1, id: UInt16 = 0x1234, questionClass: UInt16 = 1, withOPT: Bool = false) -> [UInt8] {
        var query: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, withOPT ? 1 : 0]
        for label in name.split(separator: ".") {
            query.append(UInt8(label.utf8.count))
            query += Array(label.utf8)
        }
        query += [0, UInt8(type >> 8), UInt8(type & 0xFF), UInt8(questionClass >> 8), UInt8(questionClass & 0xFF)]
        if withOPT { query += [0, 0, 41, 0x10, 0x00, 0, 0, 0, 0, 0, 0] }
        return query
    }

    /// What a DNS answer says: its code, and the address of its one A record, if it has one.
    static func dnsAnswer(_ reply: [UInt8]) -> (id: UInt16, code: Int, answers: Int, address: VMNetIPv4?, additional: Int) {
        let id = UInt16(reply[0]) << 8 | UInt16(reply[1])
        let answers = Int(reply[6]) << 8 | Int(reply[7])
        let additional = Int(reply[10]) << 8 | Int(reply[11])
        var address: VMNetIPv4?
        if answers == 1 {
            // Skip the question: labels up to the empty one, then type and class.
            var index = 12
            while reply[index] != 0 { index += Int(reply[index]) + 1 }
            index += 5
            // The answer: a pointer, type, class, TTL, length, four bytes.
            let data = index + 12
            address = VMNetIPv4(UInt32(reply[data]) << 24 | UInt32(reply[data + 1]) << 16 | UInt32(reply[data + 2]) << 8 | UInt32(reply[data + 3]))
        }
        return (id, Int(reply[3] & 0x0F), answers, address, additional)
    }

    /// A DHCP client's message.
    static func dhcp(type: UInt8, mac: VMNetMAC = guestMAC, transaction: UInt32 = 0xABCD_0123, clientAddress: VMNetIPv4 = .unspecified,
                     requested: VMNetIPv4? = nil, server: VMNetIPv4? = nil, flags: UInt16 = 0) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: 240)
        message[0] = 1
        message[1] = 1
        message[2] = 6
        message[4] = UInt8(transaction >> 24)
        message[5] = UInt8(transaction >> 16 & 0xFF)
        message[6] = UInt8(transaction >> 8 & 0xFF)
        message[7] = UInt8(transaction & 0xFF)
        message[10] = UInt8(flags >> 8)
        message[11] = UInt8(flags & 0xFF)
        message.replaceSubrange(12..<16, with: quad(clientAddress.value))
        message.replaceSubrange(28..<34, with: mac.bytes)
        message.replaceSubrange(236..<240, with: [0x63, 0x82, 0x53, 0x63])
        message += [53, 1, type]
        if let requested { message += [50, 4] + quad(requested.value) }
        if let server { message += [54, 4] + quad(server.value) }
        message += [55, 4, 1, 3, 6, 15, 255]
        return message
    }

    /// The options of a DHCP reply, by code.
    static func dhcpOptions(_ reply: [UInt8]) -> [UInt8: [UInt8]] {
        var options: [UInt8: [UInt8]] = [:]
        var index = 240
        while index < reply.count, reply[index] != 255 {
            if reply[index] == 0 { index += 1; continue }
            let length = Int(reply[index + 1])
            options[reply[index]] = Array(reply[(index + 2)..<(index + 2 + length)])
            index += 2 + length
        }
        return options
    }

    static func quad(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Bytes that are the same every run: test data, and a test's "random" choices.
struct TestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
    }
}

// MARK: - Sockets for the tests: a listener on loopback, reads and writes with a time limit

enum TestSocket {
    /// A listening TCP socket on 127.0.0.1 and the port the system gave it.
    static func listen() -> (descriptor: Int32, port: Int) {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | AI_PASSIVE
        var list: UnsafeMutablePointer<addrinfo>?
        precondition(getaddrinfo("127.0.0.1", "0", &hints, &list) == 0, "no loopback address")
        defer { freeaddrinfo(list) }
        let descriptor = socket(AF_INET, Sys.streamType, 0)
        precondition(descriptor >= 0, "no socket")
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        precondition(bind(descriptor, list!.pointee.ai_addr, list!.pointee.ai_addrlen) == 0, "bind failed")
        precondition(systemListen(descriptor) == 0, "listen failed")
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        precondition(status == 0, "getsockname failed")
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// `listen(2)`, named so that it is not this type's own `listen`.
    private static func systemListen(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(descriptor, 64)
        #else
        return Glibc.listen(descriptor, 64)
        #endif
    }

    /// The next connection, or -1 when none came within `timeout` (or the listener was closed).
    static func accept(_ listener: Int32, timeout: Double) -> Int32 {
        guard waitFor(listener, Sys.readable, timeout: timeout) else { return -1 }
        #if canImport(Darwin)
        let descriptor = Darwin.accept(listener, nil, nil)
        #else
        let descriptor = Glibc.accept(listener, nil, nil)
        #endif
        if descriptor >= 0 { Sys.setNoSigPipe(descriptor) }
        return descriptor
    }

    static func waitFor(_ descriptor: Int32, _ events: Int16, timeout: Double) -> Bool {
        var entries = [pollfd(fd: descriptor, events: events, revents: 0)]
        let deadline = Sys.now + timeout
        while true {
            let remaining = deadline - Sys.now
            guard remaining > 0 else { return false }
            let ready = Sys.wait(&entries, milliseconds: Int32(remaining * 1000) + 1)
            if ready > 0 { return true }
            if ready < 0 && errno != EINTR { return false }
        }
    }

    /// Up to `maximum` bytes; empty when the other side closed or nothing came in time.
    static func read(_ descriptor: Int32, atMost maximum: Int = 65_536, timeout: Double = 5) -> [UInt8] {
        guard waitFor(descriptor, Sys.readable, timeout: timeout) else { return [] }
        var buffer = [UInt8](repeating: 0, count: maximum)
        let count = buffer.withUnsafeMutableBytes { Sys.receive(descriptor, $0) }
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    /// Exactly `count` bytes, or nil.
    static func read(_ descriptor: Int32, exactly count: Int, timeout: Double = 5) -> [UInt8]? {
        var collected: [UInt8] = []
        while collected.count < count {
            let more = read(descriptor, atMost: count - collected.count, timeout: timeout)
            guard !more.isEmpty else { return nil }
            collected += more
        }
        return collected
    }

    /// Everything up to and including `marker`, and what came after it in the same reads.
    static func read(_ descriptor: Int32, until marker: [UInt8], timeout: Double = 5) -> (head: [UInt8], rest: [UInt8])? {
        var collected: [UInt8] = []
        while true {
            if let range = find(marker, in: collected) {
                return (Array(collected[0..<range.upperBound]), Array(collected[range.upperBound...]))
            }
            let more = read(descriptor, timeout: timeout)
            guard !more.isEmpty else { return nil }
            collected += more
        }
    }

    /// Everything until the other side closes.
    static func readToEnd(_ descriptor: Int32, timeout: Double = 5) -> [UInt8] {
        var collected: [UInt8] = []
        while true {
            let more = read(descriptor, timeout: timeout)
            guard !more.isEmpty else { return collected }
            collected += more
        }
    }

    @discardableResult
    static func write(_ descriptor: Int32, _ bytes: [UInt8], timeout: Double = 5) -> Bool {
        var sent = 0
        while sent < bytes.count {
            guard waitFor(descriptor, Sys.writable, timeout: timeout) else { return false }
            let count = bytes.withUnsafeBytes { Sys.send(descriptor, UnsafeRawBufferPointer(rebasing: $0[sent...])) }
            if count > 0 { sent += count } else if errno != EINTR && !Sys.wouldBlock(errno) { return false }
        }
        return true
    }

    static func find(_ marker: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard !marker.isEmpty, bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) where Array(bytes[start..<(start + marker.count)]) == marker {
            return start..<(start + marker.count)
        }
        return nil
    }

    /// A pair of connected datagram sockets: a virtual machine's wire, both ends in this process.
    static func datagramPair() -> (Int32, Int32) {
        var ends: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let type = SOCK_DGRAM
        #else
        let type = Int32(SOCK_DGRAM.rawValue)
        #endif
        precondition(socketpair(AF_UNIX, type, 0, &ends) == 0, "no socket pair")
        // As an app must for a virtual machine's wire: the default buffers hold a frame or two.
        // What one end sends waits in the other end's receive buffer, so both ends need room.
        for end in ends {
            Sys.raiseBuffer(end, Sys.receiveBufferOption, to: 2 << 20)
            Sys.raiseBuffer(end, Sys.sendBufferOption, to: 1 << 20)
        }
        return (ends[0], ends[1])
    }

    /// Lets this process open at least `count` descriptors, if the system allows it.
    static func raiseDescriptorLimit(to count: Int) {
        var limit = rlimit()
        #if canImport(Darwin)
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < rlim_t(count) else { return }
        limit.rlim_cur = min(rlim_t(count), limit.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
        #else
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        guard getrlimit(resource, &limit) == 0, limit.rlim_cur < rlim_t(count) else { return }
        limit.rlim_cur = min(rlim_t(count), limit.rlim_max)
        _ = setrlimit(resource, &limit)
        #endif
    }

    /// How many sockets and pipes this process has open: the two kinds of descriptor a network
    /// opens. (Other kinds come and go under a test's feet — the runtime's own — and are not counted.)
    static func openDescriptorCount() -> Int {
        var count = 0
        for descriptor in Int32(0)..<1024 {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { continue }
            let kind = info.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFSOCK) || kind == mode_t(S_IFIFO) { count += 1 }
        }
        return count
    }
}

/// A value several threads set and read.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}
