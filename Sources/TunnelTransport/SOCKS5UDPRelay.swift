import Foundation
import Network
import TunnelCore

/// Opens one SOCKS5 UDP association per TURN allocation, on the profile's proxy.
/// All callbacks run on `queue`, the queue the TURN server and packet router run on.
public final class SOCKS5RelayFactory: PeerRelayFactory {
    private let queue: DispatchQueue
    private let log: (String) -> Void
    /// How long the proxy handshake plus the STUN probe may take before the allocation fails.
    public var setupTimeout: TimeInterval = 12

    public init(queue: DispatchQueue, log: @escaping (String) -> Void = { _ in }) {
        self.queue = queue
        self.log = log
    }

    public func openRelay(for route: TunnelRoute, family: IPAddr.Family,
                          onReady: @escaping (Result<SocketAddress, Error>) -> Void,
                          onReceive: @escaping (SocketAddress, [UInt8]) -> Void,
                          onClosed: @escaping () -> Void) -> PeerRelay {
        let relay = SOCKS5UDPRelay(proxy: route.proxy, family: family,
                                   stunServers: family == .v4 ? route.stunServers : route.stunServersIPv6,
                                   queue: queue, timeout: setupTimeout, log: log,
                                   onReady: onReady, onReceive: onReceive, onClosed: onClosed)
        relay.start()
        return relay
    }
}

/// One UDP association (RFC 1928 UDP ASSOCIATE): a TCP control connection that keeps the
/// association alive, and a UDP flow to the proxy's relay port carrying every datagram with
/// its SOCKS header. Nothing is ever sent around the proxy: if any step fails, the relay
/// fails and the TURN allocation is refused.
final class SOCKS5UDPRelay: PeerRelay {
    enum RelayError: Error, CustomStringConvertible {
        case proxy(String)
        case noEgress
        case timedOut

        var description: String {
            switch self {
            case let .proxy(text): return "proxy: \(text)"
            case .noEgress: return "no STUN answer through the proxy for this address family"
            case .timedOut: return "the proxy did not set up the association in time"
            }
        }
    }

    private enum State { case connecting, probing, ready, closed }

    private let proxy: SOCKSProxy
    private let family: IPAddr.Family
    private let stunServers: [String]
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let log: (String) -> Void
    private var onReady: ((Result<SocketAddress, Error>) -> Void)?
    private let onReceive: (SocketAddress, [UInt8]) -> Void
    private var onClosed: (() -> Void)?
    private var state = State.connecting
    private var control: NWConnection?
    private var udp: NWConnection?
    private var probes: [EgressProbe] = []

    init(proxy: SOCKSProxy, family: IPAddr.Family, stunServers: [String], queue: DispatchQueue, timeout: TimeInterval,
         log: @escaping (String) -> Void, onReady: @escaping (Result<SocketAddress, Error>) -> Void,
         onReceive: @escaping (SocketAddress, [UInt8]) -> Void, onClosed: @escaping () -> Void) {
        self.proxy = proxy
        self.family = family
        self.stunServers = stunServers
        self.queue = queue
        self.timeout = timeout
        self.log = log
        self.onReady = onReady
        self.onReceive = onReceive
        self.onClosed = onClosed
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: proxy.port) else {
            finish(.failure(RelayError.proxy("port \(proxy.port)")))
            return
        }
        // Keepalive: a proxy host that vanishes without closing is noticed too.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let control = NWConnection(host: NWEndpoint.Host(proxy.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        self.control = control
        control.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.greet()
            case let .failed(error), let .waiting(error): self.fail(RelayError.proxy("control connection: \(error)"))
            default: break
            }
        }
        control.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.state == .connecting || self.state == .probing else { return }
            self.fail(RelayError.timedOut)
        }
    }

    // MARK: PeerRelay

    func send(_ payload: [UInt8], to peer: SocketAddress) {
        guard state == .ready, let udp else { return }
        udp.send(content: Data(SOCKS5.wrapDatagram(payload, to: .address(peer))), completion: .idempotent)
    }

    func close() {
        state = .closed
        onReady = nil
        onClosed = nil
        control?.cancel()
        udp?.cancel()
        control = nil
        udp = nil
    }

    // MARK: Handshake

    private func greet() {
        writeControl(SOCKS5.greeting(withCredentials: proxy.credentials != nil)) { [weak self] in
            self?.readControl(2) { bytes in
                guard let self else { return }
                do {
                    if try SOCKS5.parseMethodSelection(bytes) == SOCKS5.usernamePassword {
                        guard let credentials = self.proxy.credentials else { throw SOCKS5.Failure.noAcceptableMethod }
                        self.authenticate(credentials)
                    } else {
                        self.associate()
                    }
                } catch {
                    self.fail(RelayError.proxy("\(error)"))
                }
            }
        }
    }

    private func authenticate(_ credentials: SOCKS5.Credentials) {
        let request: [UInt8]
        do { request = try SOCKS5.authenticationRequest(credentials) } catch {
            fail(RelayError.proxy("\(error)"))
            return
        }
        writeControl(request) { [weak self] in
            self?.readControl(2) { bytes in
                guard let self else { return }
                do {
                    try SOCKS5.parseAuthenticationReply(bytes)
                    self.associate()
                } catch {
                    self.fail(RelayError.proxy("\(error)"))
                }
            }
        }
    }

    private func associate() {
        writeControl(SOCKS5.udpAssociateRequest()) { [weak self] in
            self?.readControl(4) { head in
                guard let self else { return }
                let atyp: UInt8
                do { atyp = try SOCKS5.parseReplyHead(head) } catch {
                    self.fail(RelayError.proxy("UDP ASSOCIATE refused: \(error)"))
                    return
                }
                if let length = SOCKS5.addressLength(atyp: atyp) {
                    self.readControl(length + 2) { rest in self.bound(atyp: atyp, rest) }
                } else {
                    self.readControl(1) { length in
                        self.readControl(Int(length[0]) + 2) { rest in self.bound(atyp: atyp, length + rest) }
                    }
                }
            }
        }
    }

    private func bound(atyp: UInt8, _ rest: [UInt8]) {
        let destination: ProxyDestination
        do { destination = try SOCKS5.parseBoundAddress(atyp: atyp, rest) } catch {
            fail(RelayError.proxy("\(error)"))
            return
        }
        let host: NWEndpoint.Host
        let port: UInt16
        switch destination {
        case let .address(address):
            port = address.port
            if address.ip.isUnspecified {
                // 0.0.0.0 / ::: "my own address" — the one the control connection reached.
                guard case let .hostPort(proxyHost, _)? = control?.currentPath?.remoteEndpoint else {
                    fail(RelayError.proxy("unspecified relay address and no proxy address"))
                    return
                }
                host = proxyHost
            } else {
                host = Self.host(address.ip)
            }
        case let .name(name, namePort):
            host = NWEndpoint.Host(name)
            port = namePort
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            fail(RelayError.proxy("relay port 0"))
            return
        }
        let udp = NWConnection(host: host, port: nwPort, using: .udp)
        self.udp = udp
        udp.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Once: a flow that becomes ready again after a path change keeps its loops.
                guard self.state == .connecting else { break }
                self.watchControl()
                self.receive()
                self.probe()
            case let .failed(error), let .waiting(error): self.fail(RelayError.proxy("relay flow: \(error)"))
            default: break
            }
        }
        udp.start(queue: queue)
    }

    /// STUN Binding to each server through the association; the first answer of the right
    /// family is the egress. Retried once in case the first datagrams were lost.
    private func probe() {
        state = .probing
        let destinations = stunServers.compactMap(EgressProbe.destination)
        guard !destinations.isEmpty else {
            fail(RelayError.noEgress)
            return
        }
        for attempt in 0..<2 {
            queue.asyncAfter(deadline: .now() + Double(attempt) * 2) { [weak self] in
                guard let self, self.state == .probing, let udp = self.udp else { return }
                for destination in destinations {
                    let probe = EgressProbe()
                    self.probes.append(probe)
                    udp.send(content: Data(SOCKS5.wrapDatagram(probe.request, to: destination)), completion: .idempotent)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.state == .probing else { return }
            self.fail(RelayError.noEgress)
        }
    }

    private func receive() {
        udp?.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.state != .closed else { return }
            if let data, let datagram = SOCKS5.unwrapDatagram([UInt8](data)), case let .address(peer) = datagram.source {
                self.deliver(datagram.payload, from: peer)
            }
            if let error {
                self.fail(RelayError.proxy("relay flow: \(error)"))
            } else {
                self.receive()
            }
        }
    }

    /// The association lives as long as the control connection (RFC 1928 §7). A proxy that ends it
    /// closes that connection, which only a pending read reports: one is kept posted.
    private func watchControl() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, isComplete, error in
            guard let self, self.state != .closed else { return }
            if isComplete || error != nil || data == nil {
                self.died()
            } else {
                self.watchControl()
            }
        }
    }

    private func deliver(_ payload: [UInt8], from peer: SocketAddress) {
        switch state {
        case .probing:
            for probe in probes {
                if let mapped = probe.mappedAddress(in: payload) {
                    guard mapped.family == family else { continue }
                    probes.removeAll()
                    state = .ready
                    log("SOCKS5 association ready, egress \(mapped)")
                    finish(.success(mapped))
                    return
                }
            }
        case .ready:
            onReceive(peer, payload)
        default:
            break
        }
    }

    // MARK: Control connection I/O

    private func writeControl(_ bytes: [UInt8], then next: @escaping () -> Void) {
        control?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.fail(RelayError.proxy("write: \(error)")) } else { next() }
        })
    }

    private func readControl(_ count: Int, then next: @escaping ([UInt8]) -> Void) {
        control?.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, isComplete, error in
            guard let self, self.state != .closed else { return }
            guard let data, data.count == count else {
                self.fail(RelayError.proxy(error.map { "read: \($0)" } ?? (isComplete ? "closed by the proxy" : "short read")))
                return
            }
            next([UInt8](data))
        }
    }

    // MARK: Outcome

    private func finish(_ result: Result<SocketAddress, Error>) {
        let callback = onReady
        onReady = nil
        callback?(result)
    }

    private func fail(_ error: Error) {
        guard state != .closed else { return }
        let wasReady = state == .ready
        let ready = onReady, closed = onClosed
        log("SOCKS5 association failed: \(error)")
        close()
        if wasReady {
            closed?()
        } else {
            ready?(.failure(error))
        }
    }

    /// The control connection ended: the proxy has dropped the association.
    private func died() {
        guard state != .closed else { return }
        fail(RelayError.proxy("control connection closed"))
    }

    private static func host(_ ip: IPAddr) -> NWEndpoint.Host {
        if ip.family == .v4, let v4 = IPv4Address(Data(ip.bytes)) { return .ipv4(v4) }
        if let v6 = IPv6Address(Data(ip.bytes)) { return .ipv6(v6) }
        return NWEndpoint.Host(ip.description)
    }
}
