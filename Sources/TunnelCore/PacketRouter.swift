import Foundation

/// The packet side of the tunnel: IP packets from the tunnel interface go to the TURN server of
/// the route whose virtual address they are sent to; the servers' answers go back as IP packets.
/// One route per running profile, any number at once.
///
/// Not thread-safe: the provider calls it, and the relays call back, on one serial queue.
public final class PacketRouter {
    public typealias Emit = (_ packet: [UInt8]) -> Void

    private let relays: PeerRelayFactory
    private let now: () -> Double
    private let emit: Emit
    private let log: (String) -> Void
    private var servers: [String: TURNServer] = [:]
    private var serverByEndpoint: [SocketAddress: TURNServer] = [:]

    /// Packets dropped because nothing listens at their destination, or because they are not
    /// unfragmented UDP: for diagnostics.
    public private(set) var droppedPackets = 0

    public init(relays: PeerRelayFactory, now: @escaping () -> Double = { Date().timeIntervalSince1970 },
                emit: @escaping Emit, log: @escaping (String) -> Void = { _ in }) {
        self.relays = relays
        self.now = now
        self.emit = emit
        self.log = log
    }

    public var routeIDs: [String] { servers.keys.sorted() }
    public var allocationCount: Int { servers.values.reduce(0) { $0 + $1.allocationCount } }

    /// Adds `route`, replacing one with the same id or the same addresses.
    public func register(_ route: TunnelRoute) {
        // The app registers every route again whenever the tunnel connects: the same route keeps
        // its server and allocations.
        if servers[route.id]?.route == route { return }
        unregister(id: route.id)
        for endpoint in route.endpoints {
            if let other = serverByEndpoint[endpoint] { unregister(id: other.route.id) }
        }
        let server = TURNServer(route: route, relays: relays, now: now, send: { [weak self] payload, client, server in
            guard let self else { return }
            let datagram = UDPDatagram(source: server, destination: client, payload: payload)
            guard let packet = IPPacket.buildUDP(datagram) else { return }
            self.emit(packet)
        }, log: { [log] in log("[\(route.id.prefix(8))] \($0)") })
        servers[route.id] = server
        for endpoint in route.endpoints { serverByEndpoint[endpoint] = server }
        log("route \(route.id.prefix(8)) at \(route.endpoints.map(\.description).joined(separator: ", "))")
    }

    public func unregister(id: String) {
        guard let server = servers.removeValue(forKey: id) else { return }
        server.shutdown()
        for endpoint in server.route.endpoints where serverByEndpoint[endpoint] === server {
            serverByEndpoint[endpoint] = nil
        }
        log("route \(id.prefix(8)) removed")
    }

    public func unregisterAll() {
        for id in servers.keys { unregister(id: id) }
    }

    /// One packet read from the tunnel interface.
    public func handlePacket(_ packet: [UInt8]) {
        guard let datagram = IPPacket.parseUDP(packet), let server = serverByEndpoint[datagram.destination] else {
            droppedPackets += 1
            return
        }
        server.receive(datagram.payload, from: datagram.source, to: datagram.destination)
    }

    /// Call every few seconds.
    public func expire() {
        for server in servers.values { server.expire() }
    }
}
