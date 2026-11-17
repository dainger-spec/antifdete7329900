#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The system calls of the tunnel's program, under one set of names on macOS and Linux.
enum TunnelSystem {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    static let datagramType = SOCK_DGRAM
    private static let sendFlags = Int32(MSG_DONTWAIT)
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let datagramType = Int32(SOCK_DGRAM.rawValue)
    private static let sendFlags = Int32(MSG_DONTWAIT) | Int32(MSG_NOSIGNAL)
    #endif

    /// A clock that only goes forward, in seconds.
    static var now: Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }

    static func receive(_ descriptor: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
        recv(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT))
    }

    static func send(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int {
        #if canImport(Darwin)
        return Darwin.send(descriptor, bytes.baseAddress, bytes.count, sendFlags)
        #else
        return Glibc.send(descriptor, bytes.baseAddress, bytes.count, sendFlags)
        #endif
    }

    static func write(_ descriptor: Int32, _ bytes: [UInt8]) -> Int {
        bytes.withUnsafeBytes { buffer in
            #if canImport(Darwin)
            return Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            #else
            return Glibc.write(descriptor, buffer.baseAddress, buffer.count)
            #endif
        }
    }

    static func setNonBlocking(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
    }

    static func setCloseOnExec(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD, 0) | FD_CLOEXEC)
    }

    static func setNoSigPipe(_ descriptor: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func setBuffer(_ descriptor: Int32, _ option: Int32, bytes: Int32) {
        var value = bytes
        _ = setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    static func shutdownWrite(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = shutdown(descriptor, SHUT_WR)
        #else
        _ = shutdown(descriptor, Int32(SHUT_WR))
        #endif
    }

    static var lastError: Int32 { errno }

    static func wouldBlock(_ code: Int32) -> Bool { code == EAGAIN || code == EWOULDBLOCK || code == EINTR }

    /// The address a socket listens on or is bound to, when it is an IPv4 or IPv6 one.
    static func localAddress(_ descriptor: Int32) -> (address: TunnelAddress, port: UInt16)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { return nil }
        return endpoint(of: storage)
    }

    static func endpoint(of storage: sockaddr_storage) -> (address: TunnelAddress, port: UInt16)? {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { four in
                    var raw = four.pointee.sin_addr
                    let bytes = withUnsafeBytes(of: &raw) { Array($0) }
                    return (TunnelAddress(family: .v4, bytes: bytes)!, UInt16(bigEndian: four.pointee.sin_port))
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { six in
                    var raw = six.pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: &raw) { Array($0) }
                    return (TunnelAddress(family: .v6, bytes: bytes)!, UInt16(bigEndian: six.pointee.sin6_port))
                }
            }
        default:
            return nil
        }
    }

    /// Whether the address is this Mac's own (127.0.0.0/8, ::1, or ::ffff:127.x).
    static func isLoopback(_ address: TunnelAddress) -> Bool {
        switch address.family {
        case .v4: return address.bytes[0] == 127
        case .v6:
            if address.bytes[0..<15].allSatisfy({ $0 == 0 }) && address.bytes[15] == 1 { return true }
            let mapped = address.bytes[0..<10].allSatisfy { $0 == 0 } && address.bytes[10] == 0xFF && address.bytes[11] == 0xFF
            return mapped && address.bytes[12] == 127
        }
    }

    /// A UDP socket on 127.0.0.1, at a port the system picks; non-blocking, closed on exec.
    static func loopbackDatagramSocket() -> (descriptor: Int32, port: UInt16)? {
        let descriptor = socket(AF_INET, datagramType, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, let local = localAddress(descriptor) else {
            close(descriptor)
            return nil
        }
        setNonBlocking(descriptor)
        setCloseOnExec(descriptor)
        return (descriptor, local.port)
    }

    /// Receives one datagram with its sender.
    static func receiveFrom(_ descriptor: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> (Int, sockaddr_storage) {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(descriptor, buffer.baseAddress, buffer.count, Int32(MSG_DONTWAIT), $0, &length)
            }
        }
        return (count, storage)
    }

    static func sendTo(_ descriptor: Int32, _ bytes: [UInt8], _ destination: sockaddr_storage) -> Int {
        var destination = destination
        let length: socklen_t = Int32(destination.ss_family) == AF_INET6
            ? socklen_t(MemoryLayout<sockaddr_in6>.size) : socklen_t(MemoryLayout<sockaddr_in>.size)
        return bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, sendFlags, $0, length)
                }
            }
        }
    }

    static func sameEndpoint(_ a: sockaddr_storage, _ b: sockaddr_storage) -> Bool {
        guard let first = endpoint(of: a), let second = endpoint(of: b) else { return false }
        return first.address == second.address && first.port == second.port
    }

    static func wait(_ entries: inout [pollfd], milliseconds: Int32) -> Int32 {
        entries.withUnsafeMutableBufferPointer { buffer in
            #if canImport(Darwin)
            return poll(buffer.baseAddress, nfds_t(buffer.count), milliseconds)
            #else
            return poll(buffer.baseAddress, nfds_t(buffer.count), milliseconds)
            #endif
        }
    }

    static func isSocket(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    static var parentProcess: pid_t { getppid() }
}
