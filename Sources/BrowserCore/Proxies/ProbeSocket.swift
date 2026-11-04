#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The few socket calls `ProxyProbe` needs, with timeouts, on macOS and Linux alike: name
/// resolution, a TCP connection, sending and receiving. Plain BSD sockets, so that the probe sees
/// what each step did (the resolver's answer, the connection's error number, the first bytes that
/// came back) — which is what tells a refused connection from a silent proxy — and so that it is
/// tested on Linux as on macOS. Every connection goes to the proxy's own address and nowhere else.
enum ProbeSocket {
    /// One address the resolver gave for the proxy's host.
    struct Address: Sendable {
        fileprivate var storage: sockaddr_storage
        fileprivate var length: socklen_t
        var family: Int32
        /// "203.0.113.5", "2001:db8::5".
        var text: String
    }

    enum Resolution: Sendable {
        case addresses([Address])
        /// The name does not exist.
        case notFound
        /// The resolver failed or did not answer; `reason` says how.
        case failed(String)
    }

    /// The addresses of `host`, for TCP to `port`. An IP literal is taken as it is, without asking
    /// a resolver. Stops waiting after `timeout` (the resolver itself cannot be interrupted, and
    /// finishes on its own thread).
    static func resolve(_ host: String, port: Int, timeout: TimeInterval) -> Resolution {
        let box = ResultBox<Resolution>()
        let thread = Thread {
            box.set(resolveNow(host, port: port))
        }
        thread.stackSize = 1 << 20
        thread.start()
        return box.wait(timeout: timeout) ?? .failed("the resolver did not answer within \(Int(timeout)) s")
    }

    private static func resolveNow(_ host: String, port: Int) -> Resolution {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        hints.ai_flags = AI_NUMERICSERV | AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        defer { if let list { freeaddrinfo(list) } }
        guard status == 0 else {
            if status == EAI_NONAME || status == Self.noDataStatus { return .notFound }
            return .failed(String(cString: gai_strerror(status)))
        }
        var addresses: [Address] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let pointer = entry.pointee.ai_addr else { continue }
            var storage = sockaddr_storage()
            let length = entry.pointee.ai_addrlen
            withUnsafeMutableBytes(of: &storage) { target in
                target.copyMemory(from: UnsafeRawBufferPointer(start: pointer, count: Int(length)))
            }
            let family = Int32(entry.pointee.ai_family)
            addresses.append(Address(storage: storage, length: length, family: family, text: numericText(pointer, length)))
        }
        return addresses.isEmpty ? .notFound : .addresses(addresses)
    }

    /// Whether `host` is an IP address in a form the resolver takes as it is, without asking anyone
    /// (`AI_NUMERICHOST`): its addresses are what was written, not a resolver's answer.
    static func isNumeric(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        hints.ai_flags = AI_NUMERICHOST
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        if let list { freeaddrinfo(list) }
        return status == 0
    }

    /// `EAI_NODATA` ("no address for this name"), which the C libraries number differently and
    /// Glibc does not always export.
    #if canImport(Darwin)
    private static let noDataStatus: Int32 = 7
    #else
    private static let noDataStatus: Int32 = -5
    #endif

    #if canImport(Darwin)
    private static let streamType = SOCK_STREAM
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    private static func numericText(_ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return "?" }
        return String(cString: buffer)
    }

    enum ConnectFailure: Error, Sendable, Equatable {
        case refused
        case unreachable
        case timedOut
        case other(Int32)
    }

    /// An open, non-blocking TCP connection.
    final class Connection: @unchecked Sendable {
        let descriptor: Int32
        private let lock = NSLock()
        private var isClosed = false
        private var isCancelled = false

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit { close() }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            isClosed = true
            _ = systemClose(descriptor)
        }

        /// Ends what the connection is waiting for, from another thread: its waits return at once.
        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            isCancelled = true
            _ = shutdown(descriptor, Int32(shutdownBoth))
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }

        /// Sends all of `data`; false when the connection broke or `deadline` passed.
        func send(_ data: Data, before deadline: TimeInterval) -> Bool {
            var sent = 0
            while sent < data.count {
                guard wait(for: Int16(truncatingIfNeeded: POLLOUT), until: deadline) == .ready else { return false }
                let count = data.withUnsafeBytes { buffer -> Int in
                    systemSend(descriptor, buffer.baseAddress!.advanced(by: sent), data.count - sent)
                }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    return false
                }
                sent += count
            }
            return true
        }

        enum Received: Equatable {
            /// Some bytes (at most what was asked for).
            case data(Data)
            /// The other side closed the connection.
            case closed
            /// Nothing came before the deadline.
            case timedOut
            case failed(Int32)
        }

        /// Whatever arrives first, up to `maximum` bytes, before `deadline`.
        func receive(atMost maximum: Int, before deadline: TimeInterval) -> Received {
            while true {
                switch wait(for: Int16(truncatingIfNeeded: POLLIN), until: deadline) {
                case .timedOut: return .timedOut
                case .failed(let number): return .failed(number)
                case .ready: break
                }
                var buffer = [UInt8](repeating: 0, count: max(1, maximum))
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 { return .data(Data(buffer[0..<count])) }
                if count == 0 { return .closed }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return errno == ECONNRESET ? .closed : .failed(errno)
            }
        }

        /// Exactly `count` bytes, or what came of trying: `.data` shorter than `count` is never
        /// returned (a close or a timeout part-way is reported as such, with what came in `partial`).
        func receive(exactly count: Int, before deadline: TimeInterval) -> (Received, partial: Data) {
            var collected = Data()
            while collected.count < count {
                switch receive(atMost: count - collected.count, before: deadline) {
                case .data(let data): collected.append(data)
                case let other: return (other, collected)
                }
            }
            return (.data(collected), collected)
        }

        /// Everything up to and including `marker`, at most `limit` bytes.
        func receive(until marker: Data, limit: Int, before deadline: TimeInterval) -> (Received, partial: Data) {
            var collected = Data()
            while collected.range(of: marker) == nil && collected.count < limit {
                switch receive(atMost: limit - collected.count, before: deadline) {
                case .data(let data): collected.append(data)
                case let other: return (other, collected)
                }
            }
            return (.data(collected), collected)
        }

        private enum Wait: Equatable { case ready, timedOut, failed(Int32) }

        private func wait(for events: Int16, until deadline: TimeInterval) -> Wait {
            while true {
                if cancelled { return .failed(ECANCELED) }
                let remaining = deadline - ProbeClock.now
                guard remaining > 0 else { return .timedOut }
                var entry = pollfd(fd: descriptor, events: events, revents: 0)
                let result = poll(&entry, 1, Int32(min(remaining, 3600) * 1000) + 1)
                if result > 0 { return .ready } // readable/writable, or hung up: the read or write says which
                if result == 0 { continue } // the loop's own check ends it at the deadline
                if errno == EINTR { continue }
                return .failed(errno)
            }
        }
    }

    /// A TCP connection to `address`, or why there is none, within `timeout`.
    static func connect(to address: Address, timeout: TimeInterval) -> Result<Connection, ConnectFailure> {
        let descriptor = socket(address.family, streamType, 0)
        guard descriptor >= 0 else { return .failure(.other(errno)) }
        let connection = Connection(descriptor: descriptor)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        #if canImport(Darwin)
        // A write to a connection the proxy closed must fail, not end the app with SIGPIPE.
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var storage = address.storage
        let status = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(descriptor, $0, address.length) }
        }
        if status == 0 { return .success(connection) }
        guard errno == EINPROGRESS else { return .failure(failure(errno)) }
        var entry = pollfd(fd: descriptor, events: Int16(truncatingIfNeeded: POLLOUT), revents: 0)
        let deadline = ProbeClock.now + timeout
        while true {
            let remaining = deadline - ProbeClock.now
            guard remaining > 0 else { return .failure(.timedOut) }
            let result = poll(&entry, 1, Int32(remaining * 1000) + 1)
            if result > 0 { break }
            if result < 0 && errno != EINTR { return .failure(.other(errno)) }
        }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return .failure(.other(errno)) }
        return error == 0 ? .success(connection) : .failure(failure(error))
    }

    private static func failure(_ number: Int32) -> ConnectFailure {
        switch number {
        case ECONNREFUSED: return .refused
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN: return .unreachable
        case ETIMEDOUT: return .timedOut
        default: return .other(number)
        }
    }
}

/// A clock that only goes forward, in seconds.
enum ProbeClock {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// One value handed from a thread to whoever waits for it.
final class ResultBox<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    func set(_ newValue: Value) {
        condition.lock()
        if value == nil { value = newValue }
        condition.broadcast()
        condition.unlock()
    }

    /// The value, or nil when `timeout` passed first.
    func wait(timeout: TimeInterval) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while value == nil {
            guard condition.wait(until: deadline) else { return value }
        }
        return value
    }

    var current: Value? {
        condition.lock()
        defer { condition.unlock() }
        return value
    }
}

// The C calls by names the methods above do not shadow.
#if canImport(Darwin)
private let shutdownBoth = SHUT_RDWR
private func systemClose(_ descriptor: Int32) -> Int32 { Darwin.close(descriptor) }
private func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Darwin.connect(descriptor, address, length)
}
private func systemSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.send(descriptor, bytes, count, 0)
}
#else
private let shutdownBoth = Int32(SHUT_RDWR)
private func systemClose(_ descriptor: Int32) -> Int32 { Glibc.close(descriptor) }
private func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Glibc.connect(descriptor, address, length)
}
private func systemSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    // A write to a connection the proxy closed must fail, not end the process with SIGPIPE.
    Glibc.send(descriptor, bytes, count, Int32(MSG_NOSIGNAL))
}
#endif
