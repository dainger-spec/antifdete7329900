import Darwin
import Foundation
import TunnelCore

/// One route's TURN server on a UDP socket of this Mac: the relay that carries a proxied profile's
/// WebRTC (`WebRTCRelays`, bound to 127.0.0.1), sending each allocation through the profile's
/// SOCKS5 proxy (`SOCKS5RelayFactory`).
public final class TURNUDPHost {
    public enum HostError: Error { case socket(String) }

    /// The route as served here: `relayIPv4` and `port` are this socket's address.
    public let route: TunnelRoute
    public let address: SocketAddress
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let timer: DispatchSourceTimer
    private var server: TURNServer!

    /// The TURN URL pages are given for this host (IPv4 only).
    public var turnURL: String { "turn:\(address.ip):\(address.port)?transport=udp" }

    public init(route template: TunnelRoute, bindTo ip: IPAddr, queue: DispatchQueue, relays: PeerRelayFactory,
                log: @escaping (String) -> Void = { _ in }) throws {
        guard ip.family == .v4 else { throw HostError.socket("IPv4 only") }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw HostError.socket("socket: \(errno)") }
        var bound = sockaddr_in()
        bound.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bound.sin_family = sa_family_t(AF_INET)
        bound.sin_port = 0
        bound.sin_addr = in_addr(s_addr: ip.bytes.withUnsafeBytes { $0.load(as: UInt32.self) })
        let bindResult = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw HostError.socket("bind: \(errno)")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        descriptor = fd
        address = SocketAddress(ip: ip, port: UInt16(bigEndian: actual.sin_port))
        var route = template
        route.relayIPv4 = ip
        route.port = address.port
        self.route = route
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        timer = DispatchSource.makeTimerSource(queue: queue)

        server = TURNServer(route: route, relays: relays, send: { payload, client, _ in
            guard var destination = Self.socketAddress(client) else { return }
            _ = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }, log: log)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.server.expire() }
        timer.resume()
    }

    deinit { stop() }

    public func stop() {
        server?.shutdown()
        timer.cancel()
        source.cancel()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length) }
            }
        }
        guard count > 0, from.sin_family == sa_family_t(AF_INET) else { return }
        let ip = withUnsafeBytes(of: from.sin_addr.s_addr) { IPAddr(bytes: Array($0)) }
        guard let ip else { return }
        server.receive(Array(buffer[0..<count]), from: SocketAddress(ip: ip, port: UInt16(bigEndian: from.sin_port)), to: address)
    }

    private static func socketAddress(_ address: SocketAddress) -> sockaddr_in? {
        guard address.family == .v4 else { return nil }
        var result = sockaddr_in()
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        result.sin_family = sa_family_t(AF_INET)
        result.sin_port = address.port.bigEndian
        result.sin_addr = in_addr(s_addr: address.ip.bytes.withUnsafeBytes { $0.load(as: UInt32.self) })
        return result
    }
}
