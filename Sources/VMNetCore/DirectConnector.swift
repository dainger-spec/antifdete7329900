#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The way out for a machine that has no proxy: this Mac's own connection, as any app has it.
///
/// Apple's NAT for virtual machines (`VZNATNetworkDeviceAttachment`) carries a guest's packets
/// through a network of the system's own, beside the apps' — and where the Mac runs a VPN or a
/// proxy tool that takes the apps' traffic, the guest's packets are not taken with it and go
/// nowhere (the first run on a person's Mac, 13 November: a machine "through my network" had no
/// internet at all). Here the guest's connections are instead made by this process, as ordinary
/// sockets: they go wherever the connections of any app on this Mac go — through its VPN, by its
/// routes, under its firewall.
///
/// It is a SOCKS5 server on loopback that the machine's network (`VMNetwork`) uses as its proxy:
/// the two parts already speak that between them, and nothing of the network changes. Only
/// CONNECT, no sign-in (nothing but this process reaches a port on loopback that the system chose
/// a moment ago), names resolved here. Like the network itself, it connects to public addresses
/// only: a name that resolves to this Mac, or to somebody's local network, is refused — a page in
/// a guest must not reach the Mac's own services by naming them.
///
/// One thread per direction of a connection, blocking: a few hundred connections of a browser
/// are a few hundred idle threads, and the code is what can be read.
public final class VMNetDirectConnector: @unchecked Sendable {
    /// Connections carried at once; one more is refused.
    public static let maximumConnections = 1024

    private let allowsLocalDestinations: Bool
    /// The tests' own answer to "what addresses has this name": nil asks the system.
    private let resolve: (@Sendable (String) -> [String]?)?

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var listeningPort = 0
    private var stopped = true
    /// Every socket of the connections under way, to cut them at `stop`.
    private var open: Set<Int32> = []
    private var threads = 0

    public init() {
        allowsLocalDestinations = false
        resolve = nil
    }

    /// For the tests: destinations on this machine, and names given their addresses.
    init(allowsLocalDestinations: Bool, resolve: (@Sendable (String) -> [String]?)? = nil) {
        self.allowsLocalDestinations = allowsLocalDestinations
        self.resolve = resolve
    }

    deinit { stop() }

    public enum Failure: Error, Equatable {
        case noSocket(Int32)
        case alreadyStarted
    }

    /// The connector as `VMNetwork` is told of a proxy. Call after `start()`.
    public var upstream: VMNetUpstream {
        .socks5(host: "127.0.0.1", port: port, username: nil, password: nil)
    }

    /// The loopback port it listens on; 0 before `start()`.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return listeningPort
    }

    /// Starts listening on a loopback port of the system's choosing and returns it.
    @discardableResult
    public func start() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard stopped, listener < 0 else { throw Failure.alreadyStarted }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | AI_PASSIVE
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", "0", &hints, &list) == 0, let first = list else { throw Failure.noSocket(errno) }
        defer { freeaddrinfo(list) }
        let descriptor = socket(AF_INET, Sys.streamType, 0)
        guard descriptor >= 0 else { throw Failure.noSocket(errno) }
        guard bind(descriptor, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0, Self.systemListen(descriptor) == 0 else {
            let code = errno
            Sys.close(descriptor)
            throw Failure.noSocket(code)
        }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            Sys.close(descriptor)
            throw Failure.noSocket(code)
        }
        listener = descriptor
        listeningPort = Int(UInt16(bigEndian: address.sin_port))
        stopped = false
        threads += 1
        let thread = Thread { [self] in
            acceptLoop(descriptor)
            finished()
        }
        thread.name = "VMNet direct connector"
        thread.start()
        return listeningPort
    }

    /// Ends the connector: its connections are cut, and its threads have ended when this returns
    /// (or a few seconds have passed).
    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        for descriptor in open { _ = shutdown(descriptor, Int32(SHUT_RDWR)) }
        lock.unlock()
        let deadline = Sys.now + 5
        while Sys.now < deadline {
            lock.lock()
            let left = threads
            lock.unlock()
            if left == 0 { break }
            usleep(2_000)
        }
        lock.lock()
        if listener >= 0 { Sys.close(listener) }
        listener = -1
        listeningPort = 0
        lock.unlock()
    }

    // MARK: - Bookkeeping

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func finished() {
        lock.lock()
        threads -= 1
        lock.unlock()
    }

    /// Takes a socket into the connector's care; false when it has stopped (the socket is then
    /// the caller's to close) or carries all it may.
    private func register(_ descriptor: Int32, countsAsConnection: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        if countsAsConnection {
            guard open.count < Self.maximumConnections * 2 else { return false }
            threads += 1
        }
        open.insert(descriptor)
        return true
    }

    private func release(_ descriptor: Int32) {
        lock.lock()
        open.remove(descriptor)
        lock.unlock()
        Sys.close(descriptor)
    }

    // MARK: - Accepting

    private func acceptLoop(_ descriptor: Int32) {
        while !isStopped {
            var entries = [pollfd(fd: descriptor, events: Sys.readable, revents: 0)]
            guard Sys.wait(&entries, milliseconds: 200) > 0 else { continue }
            #if canImport(Darwin)
            let client = Darwin.accept(descriptor, nil, nil)
            #else
            let client = Glibc.accept(descriptor, nil, nil)
            #endif
            guard client >= 0 else { continue }
            Sys.setNoSigPipe(client)
            Sys.setNoDelay(client)
            guard register(client, countsAsConnection: true) else {
                Sys.close(client)
                continue
            }
            let thread = Thread { [self] in
                serve(client)
                release(client)
                finished()
            }
            thread.stackSize = 256 << 10
            thread.start()
        }
    }

    private static func systemListen(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(descriptor, 256)
        #else
        return Glibc.listen(descriptor, 256)
        #endif
    }

    // MARK: - One connection

    private enum Target {
        case name(String)
        case address(VMNetIPv4)
    }

    private func serve(_ client: Int32) {
        // The network at the other end is this process: a request that does not come at once is
        // not coming.
        Self.setTimeout(client, seconds: 15)
        guard let (target, port) = request(from: client) else { return }
        guard let remote = connect(to: target, port: port) else {
            // 5: connection refused — what a guest's TCP is then told.
            _ = Self.sendAll(client, [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
            return
        }
        guard register(remote, countsAsConnection: false) else {
            Sys.close(remote)
            return
        }
        defer { release(remote) }
        guard Self.sendAll(client, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]) else { return }
        Self.setTimeout(client, seconds: 0)

        // The answer's way back on a thread of its own; the request's way here.
        let back = DispatchSemaphore(value: 0)
        let thread = Thread {
            Self.carry(from: remote, to: client)
            back.signal()
        }
        thread.stackSize = 256 << 10
        thread.start()
        Self.carry(from: client, to: remote)
        back.wait()
    }

    /// Reads SOCKS5's greeting and its one request; nil for anything but a CONNECT.
    private func request(from client: Int32) -> (Target, UInt16)? {
        guard let greeting = Self.read(client, exactly: 2), greeting[0] == 5,
              let methods = Self.read(client, exactly: Int(greeting[1])) else { return nil }
        guard methods.contains(0) else {
            _ = Self.sendAll(client, [5, 0xFF])
            return nil
        }
        guard Self.sendAll(client, [5, 0]) else { return nil }
        guard let head = Self.read(client, exactly: 4), head[0] == 5 else { return nil }
        let target: Target
        switch head[3] {
        case 1:
            guard let bytes = Self.read(client, exactly: 4) else { return nil }
            target = .address(VMNetIPv4(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])))
        case 3:
            guard let length = Self.read(client, exactly: 1), length[0] > 0,
                  let bytes = Self.read(client, exactly: Int(length[0])) else { return nil }
            let name = String(decoding: bytes, as: UTF8.self)
            // A name as names are written: nothing a resolver could take for anything else.
            guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
            target = .name(name)
        default:
            // An IPv6 address, or nothing known: the machine's network asks for neither.
            _ = Self.sendAll(client, [5, 8, 0, 1, 0, 0, 0, 0, 0, 0])
            return nil
        }
        guard let portBytes = Self.read(client, exactly: 2) else { return nil }
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        guard head[1] == 1, port != 0 else {
            // 7: command not supported.
            _ = Self.sendAll(client, [5, 7, 0, 1, 0, 0, 0, 0, 0, 0])
            return nil
        }
        return (target, port)
    }

    // MARK: - Connecting

    /// A connected socket to the target, or nil. An address is connected to as given; a name's
    /// addresses are tried one after another, IPv4 first (a Mac whose IPv6 goes nowhere then
    /// costs no wait).
    private func connect(to target: Target, port: UInt16) -> Int32? {
        let hosts: [String]
        switch target {
        case .address(let address):
            hosts = [address.string]
        case .name(let name):
            if let resolve, let given = resolve(name) {
                hosts = given
            } else {
                hosts = [name]
            }
        }
        let deadline = Sys.now + 20
        for host in hosts {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = Sys.streamType
            hints.ai_flags = AI_NUMERICSERV
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &list) == 0 else { continue }
            defer { freeaddrinfo(list) }
            var candidates: [UnsafeMutablePointer<addrinfo>] = []
            var next = list
            while let entry = next {
                candidates.append(entry)
                next = entry.pointee.ai_next
            }
            let ordered = candidates.filter { $0.pointee.ai_family == AF_INET } + candidates.filter { $0.pointee.ai_family == AF_INET6 }
            for entry in ordered {
                guard !isStopped, Sys.now < deadline else { return nil }
                guard let address = entry.pointee.ai_addr, allowsLocalDestinations || Self.isPublic(address, family: entry.pointee.ai_family) else { continue }
                let descriptor = socket(entry.pointee.ai_family, Sys.streamType, 0)
                guard descriptor >= 0 else { continue }
                Sys.setNoSigPipe(descriptor)
                Sys.setNoDelay(descriptor)
                if Self.connect(descriptor, address, entry.pointee.ai_addrlen, seconds: min(8, deadline - Sys.now)) {
                    return descriptor
                }
                Sys.close(descriptor)
            }
        }
        return nil
    }

    /// Connects within `seconds`, and leaves the socket waiting on its reads and writes again.
    private static func connect(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: socklen_t, seconds: Double) -> Bool {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        #if canImport(Darwin)
        let status = Darwin.connect(descriptor, address, length)
        #else
        let status = Glibc.connect(descriptor, address, length)
        #endif
        if status != 0 {
            guard errno == EINPROGRESS else { return false }
            var entries = [pollfd(fd: descriptor, events: Sys.writable, revents: 0)]
            guard Sys.wait(&entries, milliseconds: Int32(max(1, seconds * 1000))) > 0, Sys.pendingError(descriptor) == 0 else { return false }
        }
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        return true
    }

    /// The address is one of the public internet: not this machine, not a local network.
    static func isPublic(_ address: UnsafeMutablePointer<sockaddr>, family: Int32) -> Bool {
        if family == AF_INET {
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return !DestinationPolicy.isRefusedRange(VMNetIPv4(value))
        }
        guard family == AF_INET6 else { return false }
        let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
        }
        return isPublicIPv6(bytes)
    }

    /// An IPv6 address of the public internet: not unspecified or loopback, not link-local or
    /// unique-local, not multicast; one that carries an IPv4 address is judged by that.
    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            // ::, ::1, IPv4-compatible and IPv4-mapped (::ffff:a.b.c.d).
            let mapped = bytes[10] == 0xFF && bytes[11] == 0xFF
            let compatible = bytes[10] == 0 && bytes[11] == 0
            guard mapped || compatible else { return false }
            let value = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return mapped && !DestinationPolicy.isRefusedRange(VMNetIPv4(value))
        }
        if bytes[0] == 0xFF { return false }                       // ff00::/8, multicast
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10, link-local
        if bytes[0] & 0xFE == 0xFC { return false }                // fc00::/7, unique local
        return true
    }

    // MARK: - Bytes

    /// A limit on how long a read or a write may wait; 0: none.
    private static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var limit = timeval()
        limit.tv_sec = type(of: limit.tv_sec).init(seconds)
        limit.tv_usec = 0
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func read(_ descriptor: Int32, exactly count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var have = 0
        while have < count {
            let got = bytes.withUnsafeMutableBytes { buffer in
                recv(descriptor, buffer.baseAddress! + have, count - have, 0)
            }
            if got > 0 {
                have += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return bytes
    }

    private static func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { sendAll(descriptor, $0) }
    }

    private static func sendAll(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var sent = 0
        while sent < bytes.count {
            #if canImport(Darwin)
            let wrote = Darwin.send(descriptor, bytes.baseAddress! + sent, bytes.count - sent, 0)
            #else
            let wrote = Glibc.send(descriptor, bytes.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
            #endif
            if wrote > 0 {
                sent += wrote
            } else if wrote < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Carries bytes one way until that way ends. A side that has finished sending is told so at
    /// the other (its answers may still come); a side that broke ends both ways.
    private static func carry(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let got = buffer.withUnsafeMutableBytes { recv(source, $0.baseAddress, $0.count, 0) }
            if got > 0 {
                let delivered = buffer.withUnsafeBytes { sendAll(destination, UnsafeRawBufferPointer(rebasing: $0[0..<got])) }
                if !delivered {
                    _ = shutdown(source, Int32(SHUT_RDWR))
                    _ = shutdown(destination, Int32(SHUT_RDWR))
                    return
                }
            } else if got == 0 {
                _ = shutdown(destination, Int32(SHUT_WR))
                return
            } else if errno == EINTR {
                continue
            } else {
                _ = shutdown(source, Int32(SHUT_RDWR))
                _ = shutdown(destination, Int32(SHUT_RDWR))
                return
            }
        }
    }
}
