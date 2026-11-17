#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CLwIP

/// A SOCKS5 UDP association (RFC 1928 §7): a UDP socket on 127.0.0.1 for the client's datagrams,
/// and an lwIP endpoint per family for their way through the tunnel. It lives as long as the TCP
/// connection that asked for it.
///
/// The client is whoever sends the first datagram — from this Mac only (the socket is on
/// 127.0.0.1) — and nobody else afterwards. Fragmented datagrams (FRAG ≠ 0) are dropped. A
/// destination named by a host name is looked up through the tunnel first; a few datagrams wait
/// for it, the rest are dropped.
final class UDPAssociation {
    let socket: Int32
    let port: UInt16
    private unowned let control: SOCKSClient
    private weak var server: TunnelServer?
    private var client: sockaddr_storage?
    private var endpoint4: OpaquePointer?
    private var endpoint6: OpaquePointer?
    private var waiting: [String: [(port: UInt16, payload: [UInt8])]] = [:]
    private var waitingCount = 0
    private var closed = false

    init?(control: SOCKSClient, server: TunnelServer) {
        guard let (descriptor, port) = TunnelSystem.loopbackDatagramSocket() else { return nil }
        self.socket = descriptor
        self.port = port
        self.control = control
        self.server = server
        TunnelSystem.setBuffer(descriptor, SO_RCVBUF, bytes: 1 << 20)
        TunnelSystem.setBuffer(descriptor, SO_SNDBUF, bytes: 1 << 20)
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let endpoint4 { lumen_udp_free(endpoint4) }
        if let endpoint6 { lumen_udp_free(endpoint6) }
        endpoint4 = nil
        endpoint6 = nil
        TunnelSystem.close(socket)
    }

    /// Datagrams from the client.
    func readFromClient(server: TunnelServer) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<256 {
            let (count, from) = buffer.withUnsafeMutableBytes { TunnelSystem.receiveFrom(socket, $0) }
            if count < 0 { return }
            guard let sender = TunnelSystem.endpoint(of: from), TunnelSystem.isLoopback(sender.address) else { continue }
            if let client {
                guard TunnelSystem.sameEndpoint(client, from) else { continue }
            } else {
                client = from
            }
            guard let datagram = SOCKS5Server.readDatagram(Array(buffer[0..<count])) else { continue }
            switch datagram.destination {
            case .address(let address):
                send(datagram.payload, to: address, port: datagram.port)
            case .name(let name):
                wait(datagram.payload, for: name, port: datagram.port, server: server)
            }
        }
    }

    private func wait(_ payload: [UInt8], for name: String, port: UInt16, server: TunnelServer) {
        guard waitingCount < server.tuning.datagramsAwaitingName else { return }
        waitingCount += 1
        let first = waiting[name] == nil
        waiting[name, default: []].append((port, payload))
        guard first else { return }
        server.resolveForAssociation(name) { [weak self] address in
            guard let self, !self.closed else { return }
            let datagrams = self.waiting.removeValue(forKey: name) ?? []
            self.waitingCount -= datagrams.count
            guard let address else { return }
            for datagram in datagrams { self.send(datagram.payload, to: address, port: datagram.port) }
        }
    }

    private func send(_ payload: [UInt8], to address: TunnelAddress, port: UInt16) {
        guard !closed, port != 0, !TunnelSystem.isLoopback(address), !address.isAny,
              let endpoint = endpoint(for: address.family) else { return }
        _ = payload.withUnsafeBufferPointer { bytes in
            address.bytes.withUnsafeBufferPointer { raw in
                lumen_udp_send(endpoint, address.family.rawValue, raw.baseAddress, port, bytes.baseAddress, bytes.count)
            }
        }
    }

    private func endpoint(for family: TunnelAddress.Family) -> OpaquePointer? {
        guard let server, server.families.contains(family) else { return nil }
        let context = Unmanaged.passUnretained(self).toOpaque()
        switch family {
        case .v4:
            if endpoint4 == nil { endpoint4 = lumen_udp_open(4, associationReceive, context) }
            return endpoint4
        case .v6:
            if endpoint6 == nil { endpoint6 = lumen_udp_open(6, associationReceive, context) }
            return endpoint6
        }
    }

    /// A datagram from the tunnel for this association: to the client, with its sender (inside
    /// lwIP's input — a plain sendto on the local socket, nothing of lwIP's).
    fileprivate func receivedFromTunnel(_ source: TunnelAddress, port: UInt16, payload: [UInt8]) {
        guard !closed, let client else { return }
        _ = TunnelSystem.sendTo(socket, SOCKS5Server.datagram(from: source, port: port, payload: payload), client)
    }
}

private let associationReceive: lumen_udp_receive = { context, family, address, port, bytes, length in
    guard let context, let address else { return }
    let association = Unmanaged<UDPAssociation>.fromOpaque(context).takeUnretainedValue()
    let raw = Array(UnsafeBufferPointer(start: address, count: family == 4 ? 4 : 16))
    guard let source = TunnelAddress(family: family == 4 ? .v4 : .v6, bytes: raw) else { return }
    let payload = bytes.map { Array(UnsafeBufferPointer(start: $0, count: length)) } ?? []
    association.receivedFromTunnel(source, port: port, payload: payload)
}
