#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import OpenVPNStack

/// Sockets for the tests: the packet socket pair OpenVPN would make, a listener on 127.0.0.1, and
/// a blocking SOCKS5 client with time limits.
enum TestSockets {
    #if canImport(Darwin)
    static let stream = SOCK_STREAM
    static let datagram = SOCK_DGRAM
    #else
    static let stream = Int32(SOCK_STREAM.rawValue)
    static let datagram = Int32(SOCK_DGRAM.rawValue)
    #endif

    static func packetPair() -> (stack: Int32, far: Int32) {
        var ends: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, datagram, 0, &ends) == 0)
        for end in ends {
            var size: Int32 = 1 << 20
            setsockopt(end, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(4))
            setsockopt(end, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(4))
        }
        return (ends[0], ends[1])
    }

    static func listener(address: String = "127.0.0.1") -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, stream, 0)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(4))
        var socketAddress = sockaddr_in()
        #if canImport(Darwin)
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        socketAddress.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, address, &socketAddress.sin_addr)
        let bound = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0, "bind \(address): \(errno)")
        precondition(listen(descriptor, 64) == 0)
        return (descriptor, TunnelSystem.localAddress(descriptor)!.port)
    }

    static func connect(to address: String, port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, stream, 0)
        var socketAddress = sockaddr_in()
        #if canImport(Darwin)
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &socketAddress.sin_addr)
        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(result == 0, "connect: \(errno)")
        setTimeout(descriptor, seconds: 20)
        return descriptor
    }

    static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    static func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { buffer in
                send(descriptor, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            precondition(sent > 0, "send: \(errno)")
            offset += sent
        }
    }

    /// Reads exactly `count` bytes, or what came before the end, the timeout or an error.
    static func receive(_ descriptor: Int32, count: Int) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count < count {
            let wanted = min(buffer.count, count - result.count)
            let received = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, wanted, 0) }
            if received <= 0 { break }
            result += buffer[0..<received]
        }
        return result
    }

    /// Reads until the end of the stream (or the timeout).
    static func receiveToEnd(_ descriptor: Int32, limit: Int = 64 << 20) -> (bytes: [UInt8], ended: Bool) {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count < limit {
            let received = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if received == 0 { return (result, true) }
            if received < 0 { return (result, false) }
            result += buffer[0..<received]
        }
        return (result, false)
    }

    /// The SOCKS5 handshake with user name and password; returns the reply code (nil: refused
    /// before a request could be made) and the reply's bound address bytes.
    static func socksConnect(_ descriptor: Int32, username: String, password: String,
                             request: [UInt8]) -> (reply: UInt8?, authAnswer: [UInt8]) {
        sendAll(descriptor, [5, 1, 2])
        let method = receive(descriptor, count: 2)
        guard method == [5, 2] else { return (nil, method) }
        let user = Array(username.utf8), pass = Array(password.utf8)
        sendAll(descriptor, [1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)
        let auth = receive(descriptor, count: 2)
        guard auth == [1, 0] else { return (nil, auth) }
        sendAll(descriptor, request)
        let head = receive(descriptor, count: 4)
        guard head.count == 4 else { return (nil, auth) }
        let rest = head[3] == 1 ? 6 : head[3] == 4 ? 18 : 0
        _ = receive(descriptor, count: rest)
        return (head[1], auth)
    }

    static func connectRequest(ipv4: [UInt8], port: UInt16) -> [UInt8] {
        [5, 1, 0, 1] + ipv4 + [UInt8(port >> 8), UInt8(port & 0xFF)]
    }

    static func connectRequest(name: String, port: UInt16) -> [UInt8] {
        let raw = Array(name.utf8)
        return [5, 1, 0, 3, UInt8(raw.count)] + raw + [UInt8(port >> 8), UInt8(port & 0xFF)]
    }

    static let username = "lumen"
    static let password = "0123456789abcdef0123456789abcdef"
    static var verifier: [UInt8] { CredentialCheck.verifier(username: Array(username.utf8), password: Array(password.utf8)) }

    static func settings(packet: Int32, listening: Int32, ipv4: String = "10.99.0.2", dns: [String] = ["10.99.0.1"]) -> TunnelSettings {
        TunnelSettings(packetSocket: packet, listeningSocket: listening, statusSocket: nil, verifier: verifier, mtu: 1500,
                       ipv4: TunnelAddress(ipv4), ipv6: nil,
                       dnsServers: dns.map { TunnelSettings.DNSServer(address: TunnelAddress($0)!, port: 53) }, dnsPushed: true)
    }

    static func random(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}

#if canImport(Darwin)
@inline(__always) func Glibc_connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Darwin.connect(socket, address, length)
}
#else
@inline(__always) func Glibc_connect(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    Glibc.connect(socket, address, length)
}
#endif

/// Runs a server's loop on a thread of its own until stopped.
final class ServerThread {
    let server: TunnelServer
    private let done = DispatchSemaphore(value: 0)
    private(set) var ending: TunnelServer.Ending?

    init(_ server: TunnelServer) {
        self.server = server
        server.start()
        let thread = Thread { [self] in
            ending = server.run()
            done.signal()
        }
        thread.start()
    }

    @discardableResult
    func stop() -> TunnelServer.Ending? {
        server.requestStop()
        _ = done.wait(timeout: .now() + 10)
        return ending
    }
}
