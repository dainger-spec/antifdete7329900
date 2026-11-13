#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The system calls the network loop makes, under one set of names on macOS and Linux. The two C
/// libraries differ in small things — how a write to a closed connection is kept from ending the
/// process, how constants are typed — and every such difference lives here.
enum Sys {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    /// Darwin has no per-call flag against SIGPIPE: `setNoSigPipe` sets it on the socket instead.
    private static let sendFlags = Int32(MSG_DONTWAIT)
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_DONTWAIT) | Int32(MSG_NOSIGNAL)
    #endif

    /// A clock that only goes forward, in seconds.
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }

    /// `read(2)`: for a descriptor that is not a socket (the interop test's TAP device).
    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        #else
        return Glibc.read(descriptor, buffer.baseAddress, buffer.count)
        #endif
    }

    static func write(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        #else
        return Glibc.write(descriptor, bytes.baseAddress, bytes.count)
        #endif
    }

    /// `recv(2)` that never waits, whatever the socket's own mode.
    static func receive(_ descriptor: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
        recv(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT))
    }

    /// `send(2)` that never waits and never raises SIGPIPE (on Darwin: with `setNoSigPipe`).
    static func send(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int {
        #if canImport(Darwin)
        return Darwin.send(descriptor, bytes.baseAddress, bytes.count, sendFlags)
        #else
        return Glibc.send(descriptor, bytes.baseAddress, bytes.count, sendFlags)
        #endif
    }

    static func setNonBlocking(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
    }

    /// Darwin only: a write to a connection the other side closed fails instead of ending the
    /// process with SIGPIPE. On Linux the same is asked for with each `send`.
    static func setNoSigPipe(_ descriptor: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Small writes leave at once: the guest's own stack has already decided what goes together.
    static func setNoDelay(_ descriptor: Int32) {
        var one: Int32 = 1
        _ = setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Whether the descriptor is a socket (and not, say, a TAP device).
    static func isSocket(_ descriptor: Int32) -> Bool {
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0
    }

    /// The error a non-blocking connect ended with; 0 when it succeeded.
    static func pendingError(_ descriptor: Int32) -> Int32 {
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return errno }
        return error
    }

    /// Raises a socket buffer to `bytes` when it is smaller; never lowers it. `option` is
    /// SO_SNDBUF or SO_RCVBUF. When the system refuses the size, half of it is tried, and so on.
    static func raiseBuffer(_ descriptor: Int32, _ option: Int32, to bytes: Int32) {
        var current: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, option, &current, &length) == 0 else { return }
        var wanted = bytes
        while wanted > current {
            var value = wanted
            if setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 { return }
            wanted /= 2
        }
    }

    static let sendBufferOption = SO_SNDBUF
    static let receiveBufferOption = SO_RCVBUF

    static func shutdownWrite(_ descriptor: Int32) {
        _ = shutdown(descriptor, Int32(SHUT_WR))
    }

    /// A pipe whose both ends never wait.
    static func makePipe() -> (read: Int32, write: Int32)? {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        setNonBlocking(ends[0])
        setNonBlocking(ends[1])
        return (ends[0], ends[1])
    }

    /// A stream socket of `family` that never waits, ready for a proxy connection.
    static func streamSocket(family: Int32) -> Int32 {
        let descriptor = socket(family, streamType, 0)
        guard descriptor >= 0 else { return -1 }
        setNonBlocking(descriptor)
        setNoSigPipe(descriptor)
        setNoDelay(descriptor)
        return descriptor
    }

    /// Starts a connection. 0: connected already; EINPROGRESS: on its way; anything else: failed.
    static func connect(_ descriptor: Int32, to address: SocketEndpoint) -> Int32 {
        var storage = address.storage
        let status = withUnsafePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic -> Int32 in
                #if canImport(Darwin)
                return Darwin.connect(descriptor, generic, address.length)
                #else
                return Glibc.connect(descriptor, generic, address.length)
                #endif
            }
        }
        return status == 0 ? 0 : errno
    }

    /// How many descriptors this process may have open at once (its soft limit) — on macOS 256
    /// unless the app has raised it.
    static var descriptorLimit: Int {
        var limit = rlimit()
        #if canImport(Darwin)
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 256 }
        #else
        guard getrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &limit) == 0 else { return 1024 }
        #endif
        return Int(min(limit.rlim_cur, 1 << 20))
    }

    static func wouldBlock(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK
    }

    /// An error number in words, for the log.
    static func describe(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "connection refused"
        case ECONNRESET: return "connection reset"
        case ETIMEDOUT: return "timed out"
        case ENETUNREACH: return "network unreachable"
        case EHOSTUNREACH: return "host unreachable"
        case ENETDOWN: return "network down"
        case EPIPE: return "connection closed"
        case EMFILE, ENFILE: return "too many open files"
        case EADDRNOTAVAIL: return "address not available"
        default: return "error \(code)"
        }
    }

    /// `poll(2)` on `entries`; the number of entries with something to report, or -1.
    static func wait(_ entries: inout [pollfd], milliseconds: Int32) -> Int32 {
        poll(&entries, nfds_t(entries.count), milliseconds)
    }

    static let readable = Int16(truncatingIfNeeded: POLLIN)
    static let writable = Int16(truncatingIfNeeded: POLLOUT)
    static let failed = Int16(truncatingIfNeeded: POLLERR) | Int16(truncatingIfNeeded: POLLNVAL)
    static let hungUp = Int16(truncatingIfNeeded: POLLHUP)
}

/// One address of the proxy, as the resolver gave it.
struct SocketEndpoint: Sendable {
    var storage: sockaddr_storage
    var length: socklen_t
    var family: Int32
}

/// Finds the proxy's addresses without making the network loop wait: an IP address written out
/// is taken as it is, a host name is resolved on a thread of its own. The name is resolved once,
/// and again after a connection to the proxy failed (the proxy may have moved); until the new
/// answer is there the old one stays in use.
final class ProxyResolver: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let lock = NSLock()
    private var current: [SocketEndpoint] = []
    private var resolving = false
    private var stale = true
    private var lastFailure: String?
    private var lastAttempt = -Double.infinity
    /// The index of the address that worked last: tried first next time.
    private var preferredIndex = 0
    /// Counts the answers so far: the loop sees a new one by the number changing.
    private var answerCount = 0

    /// A failed lookup is not repeated more often than this.
    static let retryInterval = 2.0

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        if let literal = Self.lookUp(host, port: port, numericOnly: true).addresses, !literal.isEmpty {
            current = literal
            stale = false
            answerCount = 1
        }
    }

    struct Snapshot {
        var addresses: [SocketEndpoint]
        var preferredIndex: Int
        var isResolving: Bool
        var failure: String?
        var answerCount: Int
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(addresses: current, preferredIndex: preferredIndex, isResolving: resolving, failure: lastFailure, answerCount: answerCount)
    }

    /// Looks the name up on its own thread, unless an answer is at hand and still good, a lookup
    /// is on its way, or the last one failed a moment ago. `done` runs on that thread.
    func resolveIfNeeded(now: Double, done: @escaping @Sendable () -> Void) {
        lock.lock()
        guard stale, !resolving, now - lastAttempt >= Self.retryInterval else {
            lock.unlock()
            return
        }
        resolving = true
        lastAttempt = now
        lock.unlock()
        let host = self.host, port = self.port
        let thread = Thread { [weak self] in
            let result = Self.lookUp(host, port: port, numericOnly: false)
            if let self {
                self.lock.lock()
                self.resolving = false
                if let addresses = result.addresses, !addresses.isEmpty {
                    self.current = addresses
                    self.preferredIndex = 0
                    self.stale = false
                    self.lastFailure = nil
                } else {
                    self.lastFailure = result.failure ?? "no address"
                }
                self.answerCount += 1
                self.lock.unlock()
            }
            done()
        }
        thread.name = "VMNetwork resolver"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// A connection to the proxy failed: its addresses are looked up again at the next chance.
    /// An address that was written out as numbers stays what it is.
    func connectionFailed() {
        lock.lock()
        if !Self.isNumeric(host) { stale = true }
        lock.unlock()
    }

    func connectionSucceeded(index: Int) {
        lock.lock()
        preferredIndex = index
        lock.unlock()
    }

    private static func isNumeric(_ host: String) -> Bool {
        lookUp(host, port: 0, numericOnly: true).addresses?.isEmpty == false
    }

    private static func lookUp(_ host: String, port: Int, numericOnly: Bool) -> (addresses: [SocketEndpoint]?, failure: String?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Sys.streamType
        hints.ai_flags = AI_NUMERICSERV | (numericOnly ? AI_NUMERICHOST : 0)
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        guard status == 0 else { return (nil, "the resolver answered \(status)") }
        var addresses: [SocketEndpoint] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let pointer = entry.pointee.ai_addr else { continue }
            let length = entry.pointee.ai_addrlen
            guard Int(length) <= MemoryLayout<sockaddr_storage>.size else { continue }
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { target in
                target.copyMemory(from: UnsafeRawBufferPointer(start: pointer, count: Int(length)))
            }
            addresses.append(SocketEndpoint(storage: storage, length: length, family: Int32(entry.pointee.ai_family)))
        }
        return (addresses, nil)
    }
}

/// What wakes the network loop from another thread: a byte in a pipe the loop waits on.
final class WakePipe: @unchecked Sendable {
    private let lock = NSLock()
    private var readEnd: Int32
    private var writeEnd: Int32

    init?() {
        guard let ends = Sys.makePipe() else { return nil }
        readEnd = ends.read
        writeEnd = ends.write
    }

    deinit { close() }

    /// The end the loop waits on. Only the loop's thread uses it, and only before `close`.
    var descriptor: Int32 { readEnd }

    func signal() {
        lock.lock()
        defer { lock.unlock() }
        guard writeEnd >= 0 else { return }
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { Sys.write(writeEnd, $0) }
    }

    /// Empties the pipe. On the loop's thread.
    func drain() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 1)
        defer { buffer.deallocate() }
        while readEnd >= 0, Sys.read(readEnd, buffer) > 0 {}
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if readEnd >= 0 { Sys.close(readEnd) }
        if writeEnd >= 0 { Sys.close(writeEnd) }
        readEnd = -1
        writeEnd = -1
    }
}
