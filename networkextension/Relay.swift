import Foundation
import Network
import NetworkExtension
import os

/// The packet datapath of the tunnel: reads captured IPv4 packets from the `NEPacketTunnelFlow`,
/// terminates the app's TCP connections in a small userspace TCP endpoint, and forwards every flow
/// to the exit. The datapath now FORWARDS real traffic:
///
/// - TCP: each 5-tuple gets its own upstream connection — SOCKS5 CONNECT or HTTP CONNECT through
///   the profile's proxy (optionally TLS to the proxy), or a direct TCP connection for the
///   `directInterface` exit — and bytes are relayed both ways.
/// - UDP: SOCKS5 (no TLS) → SOCKS5 UDP ASSOCIATE per app socket; `directInterface` → a direct UDP
///   `NWConnection` per flow; HTTP CONNECT / SOCKS over TLS / `udp=dropped` → dropped.
/// - DNS: the tunnel's resolver address (10.111.0.1, set by PacketTunnelProvider) is answered here.
///   Queries are forwarded as DNS-over-TCP to `Relay.dnsResolver` *through the exit*, so DNS works
///   for every exit kind (HTTP CONNECT too) and no plaintext DNS leaves through the real interface.
///
/// Fail-closed is unchanged: a flow whose upstream did not come up is reset (TCP) or dropped (UDP);
/// nothing is ever re-sent in the clear. IPv6, fragments, ICMP, multicast and anything that is not
/// carried by the exit are dropped.
///
/// It cannot run in CI (no Network Extension entitlement there). Before trusting it on real
/// traffic, run the manual checklist in ../docs/NETWORK.md on a Mac with an `NE=1` build.
/// It has no dependency on BrowserCore.
final class Relay {
    enum Exit {
        case proxy(host: String, port: Int, socks: Bool, tls: Bool, username: String?, password: String?)
        case directInterface
    }

    /// The tunnel's DNS server address configured by PacketTunnelProvider (`NEDNSSettings`).
    static let gatewayAddress: UInt32 = 0x0A6F_0001 // 10.111.0.1
    /// The app side of the point-to-point link.
    static let localAddress: UInt32 = 0x0A6F_0002 // 10.111.0.2
    /// Where DNS queries are sent, always through the exit (DNS-over-TCP): 1.1.1.1:53.
    static let dnsResolver: (address: UInt32, port: UInt16) = (0x0101_0101, 53)
    /// Must match `NEPacketTunnelNetworkSettings.mtu` in PacketTunnelProvider.
    static let mtu = 1400
    static let mss = mtu - 40
    static let maxUDPPayload = mtu - 28

    private static let maxTCPFlows = 1024
    private static let maxUDPFlows = 512
    private static let maxDNSInFlight = 128

    let log: Logger
    let queue = DispatchQueue(label: "PrivacyBrowser.PacketTunnel.relay")
    let exit: Exit
    private let forwardUDP: Bool
    private let packetFlow: NEPacketTunnelFlow
    private var running = false
    private var timer: DispatchSourceTimer?
    private var outbox: [Data] = []

    private var tcpFlows: [FlowKey: TCPFlow] = [:]
    private var directUDP: [FlowKey: DirectUDPFlow] = [:]
    private var socksUDP: [Endpoint: SocksUDPSession] = [:]
    private var dnsInFlight = 0
    private var stats = Stats()

    init(exit: Exit, dropUDP: Bool, packetFlow: NEPacketTunnelFlow, log: Logger) {
        self.exit = exit
        self.packetFlow = packetFlow
        self.log = log
        // Belt and braces: even if the configuration says otherwise, UDP is only forwarded where
        // the exit can actually carry it (SOCKS5 without TLS, or this Mac's interface).
        switch exit {
        case .directInterface:
            forwardUDP = !dropUDP
        case let .proxy(_, _, socks, tls, _, _):
            forwardUDP = !dropUDP && socks && !tls
        }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            log.notice("relay started forwardUDP=\(self.forwardUDP, privacy: .public)")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            readLoop()
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            tcpFlows.values.forEach { $0.abandon() }
            directUDP.values.forEach { $0.abandon() }
            socksUDP.values.forEach { $0.abandon() }
            tcpFlows.removeAll()
            directUDP.removeAll()
            socksUDP.removeAll()
            outbox.removeAll()
            log.notice("relay stopped \(self.stats.summary, privacy: .public)")
        }
    }

    /// Pulls batches of IP packets and dispatches each. `protocols[i]` is the address family of
    /// `packets[i]` (`AF_INET` / `AF_INET6`).
    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                for (packet, family) in zip(packets, protocols) {
                    self.handle(packet, family: family.int32Value)
                }
                self.readLoop() // re-arm
            }
        }
    }

    private func handle(_ packet: Data, family: Int32) {
        // The tunnel is IPv4-only; anything else is dropped, never forwarded.
        guard family == AF_INET, let ip = IPv4Packet(packet) else { stats.dropped += 1; return }
        switch ip.proto {
        case 6: handleTCP(ip)
        case 17: handleUDP(ip)
        default: stats.dropped += 1 // ICMP and the rest: not carried by the exit
        }
    }

    // MARK: TCP

    private func handleTCP(_ ip: IPv4Packet) {
        guard let seg = TCPSegment(ip) else { stats.dropped += 1; return }
        let key = FlowKey(srcIP: ip.src, srcPort: seg.srcPort, dstIP: ip.dst, dstPort: seg.dstPort)
        if let flow = tcpFlows[key] {
            flow.receive(seg)
            return
        }
        if seg.flags & TCPFlag.rst != 0 { return }
        guard seg.flags & TCPFlag.syn != 0, seg.flags & TCPFlag.ack == 0 else {
            refuse(ip, seg) // a segment of a flow we do not know (e.g. from before a restart)
            return
        }
        // DNS-over-TCP to the tunnel resolver (clients fall back to it on a truncated UDP answer)
        // goes to the real resolver through the exit, like UDP DNS.
        var target = (address: ip.dst, port: seg.dstPort)
        if ip.dst == Self.gatewayAddress {
            guard seg.dstPort == 53 else { refuse(ip, seg); return }
            target = Self.dnsResolver
        }
        guard Self.isForwardable(target.address), target.port != 0, tcpFlows.count < Self.maxTCPFlows else {
            stats.dropped += 1
            refuse(ip, seg)
            return
        }
        let upstream = Upstream(exit: exit, command: .connect, address: target.address, port: target.port,
                                queue: queue)
        let flow = TCPFlow(key: key, syn: seg, relay: self, upstream: upstream)
        tcpFlows[key] = flow
        stats.tcpOpened += 1
        flow.open()
    }

    /// RST for a segment we will not accept (RFC 793 "reset generation").
    private func refuse(_ ip: IPv4Packet, _ seg: TCPSegment) {
        if seg.flags & TCPFlag.ack != 0 {
            emit(PacketBuilder.tcp(src: ip.dst, srcPort: seg.dstPort, dst: ip.src, dstPort: seg.srcPort,
                                   seq: seg.ack, ack: 0, flags: TCPFlag.rst, window: 0))
        } else {
            var length = UInt32(seg.payload.count)
            if seg.flags & TCPFlag.syn != 0 { length += 1 }
            if seg.flags & TCPFlag.fin != 0 { length += 1 }
            emit(PacketBuilder.tcp(src: ip.dst, srcPort: seg.dstPort, dst: ip.src, dstPort: seg.srcPort,
                                   seq: 0, ack: seg.seq &+ length, flags: TCPFlag.rst | TCPFlag.ack, window: 0))
        }
    }

    func tcpFlowClosed(_ key: FlowKey, failed: Bool) {
        tcpFlows[key] = nil
        if failed { stats.tcpFailed += 1 }
    }

    // MARK: UDP

    private func handleUDP(_ ip: IPv4Packet) {
        let b = ip.bytes, o = ip.payloadStart
        guard ip.payloadEnd - o >= 8 else { stats.dropped += 1; return }
        let srcPort = be16(b, o), dstPort = be16(b, o + 2)
        let length = Int(be16(b, o + 4))
        guard length >= 8, o + length <= ip.payloadEnd else { stats.dropped += 1; return }
        let payload = Array(b[(o + 8)..<(o + length)])

        if ip.dst == Self.gatewayAddress {
            if dstPort == 53 { handleDNS(src: ip.src, srcPort: srcPort, query: payload) } else { stats.dropped += 1 }
            return
        }
        // Dropped, not leaked — QUIC falls back to TCP, WebRTC gets no candidates.
        guard forwardUDP, Self.isForwardable(ip.dst), dstPort != 0 else { stats.udpDropped += 1; return }

        switch exit {
        case .directInterface:
            let key = FlowKey(srcIP: ip.src, srcPort: srcPort, dstIP: ip.dst, dstPort: dstPort)
            if let flow = directUDP[key] {
                flow.send(payload)
            } else if directUDP.count < Self.maxUDPFlows {
                let flow = DirectUDPFlow(key: key, relay: self)
                directUDP[key] = flow
                flow.start()
                flow.send(payload)
            } else {
                stats.udpDropped += 1
            }
        case let .proxy(host, _, _, _, _, _):
            // One association per app socket, so one socket talking to many peers (WebRTC/ICE)
            // keeps one exit mapping, as it would with a real NAT.
            let endpoint = Endpoint(address: ip.src, port: srcPort)
            if let session = socksUDP[endpoint] {
                session.send(to: ip.dst, port: dstPort, payload: payload)
            } else if socksUDP.count < Self.maxUDPFlows {
                let session = SocksUDPSession(app: endpoint, proxyHost: host, relay: self)
                socksUDP[endpoint] = session
                session.start()
                session.send(to: ip.dst, port: dstPort, payload: payload)
            } else {
                stats.udpDropped += 1
            }
        }
    }

    func directUDPClosed(_ key: FlowKey) { directUDP[key] = nil }
    func socksUDPClosed(_ endpoint: Endpoint) { socksUDP[endpoint] = nil }
    func countUDPDrop() { stats.udpDropped += 1 }

    // MARK: DNS

    /// Answers a query sent to the tunnel's resolver by forwarding it over TCP through the exit.
    private func handleDNS(src: UInt32, srcPort: UInt16, query: [UInt8]) {
        guard let questionEnd = DNS.questionEnd(query) else { stats.dropped += 1; return }
        let reply: ([UInt8]) -> Void = { [weak self] answer in
            self?.emit(PacketBuilder.udp(src: Self.gatewayAddress, srcPort: 53, dst: src, dstPort: srcPort,
                                         payload: answer))
        }
        // The tunnel carries IPv4 only: answer AAAA with "no data" so clients do not try IPv6.
        if DNS.qtype(query, questionEnd) == 28 {
            reply(DNS.response(to: query, questionEnd: questionEnd, rcode: 0, truncated: false))
            return
        }
        guard dnsInFlight < Self.maxDNSInFlight else { stats.dropped += 1; return }
        dnsInFlight += 1
        stats.dnsQueries += 1
        resolve(query) { [weak self] response in
            guard let self, self.running else { return }
            self.dnsInFlight -= 1
            guard let response, response.count >= 12, response[0] == query[0], response[1] == query[1] else {
                self.stats.dnsFailed += 1
                reply(DNS.response(to: query, questionEnd: questionEnd, rcode: 2, truncated: false)) // SERVFAIL
                return
            }
            if response.count <= DNS.udpLimit(query, questionEnd: questionEnd) {
                reply(response)
            } else {
                // Too big for the client's UDP buffer: set TC so it retries over TCP (handled above).
                reply(DNS.response(to: query, questionEnd: questionEnd, rcode: 0, truncated: true))
            }
        }
    }

    private func resolve(_ query: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        let upstream = Upstream(exit: exit, command: .connect, address: Self.dnsResolver.address,
                                port: Self.dnsResolver.port, queue: queue)
        var finished = false
        let finish: ([UInt8]?) -> Void = { response in
            guard !finished else { return }
            finished = true
            upstream.cancel()
            completion(response)
        }
        queue.asyncAfter(deadline: .now() + 10) { finish(nil) }
        upstream.connect { error in
            if error != nil { finish(nil); return }
            upstream.send(Data(bytes16(UInt16(query.count)) + query)) { if $0 != nil { finish(nil) } }
            upstream.readExactly(2) { header in
                guard let header else { finish(nil); return }
                let length = Int(header[0]) << 8 | Int(header[1])
                guard length >= 12 else { finish(nil); return }
                upstream.readExactly(length) { finish($0.map { [UInt8]($0) }) }
            }
        }
    }

    // MARK: Output and housekeeping

    func emit(_ packet: Data) {
        guard running else { return }
        outbox.append(packet)
        if outbox.count == 1 {
            queue.async { [weak self] in self?.flush() } // batch everything written in this turn
        }
    }

    private func flush() {
        guard running, !outbox.isEmpty else { return }
        packetFlow.writePackets(outbox, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: outbox.count))
        outbox.removeAll(keepingCapacity: true)
    }

    private func tick() {
        guard running else { return }
        let now = Clock.now()
        Array(tcpFlows.values).forEach { $0.tick(now) }
        Array(directUDP.values).forEach { $0.tick(now) }
        Array(socksUDP.values).forEach { $0.tick(now) }
    }

    /// Unicast destinations only: never forward to this-network, loopback, link-local multicast,
    /// broadcast or the tunnel's own addresses.
    private static func isForwardable(_ address: UInt32) -> Bool {
        let first = address >> 24
        if first == 0 || first == 127 || first >= 224 { return false }
        return address != localAddress && address != gatewayAddress
    }

    private struct Stats {
        var tcpOpened = 0, tcpFailed = 0, dropped = 0, udpDropped = 0, dnsQueries = 0, dnsFailed = 0
        var summary: String {
            "tcpOpened=\(tcpOpened) tcpFailed=\(tcpFailed) dropped=\(dropped) udpDropped=\(udpDropped) dns=\(dnsQueries) dnsFailed=\(dnsFailed)"
        }
    }
}

// MARK: - Flow identifiers and time

struct FlowKey: Hashable {
    let srcIP: UInt32, srcPort: UInt16, dstIP: UInt32, dstPort: UInt16
}

struct Endpoint: Hashable {
    let address: UInt32, port: UInt16
}

enum RelayError: Error {
    case timeout, closed, proxy(String)
}

enum Clock {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static let millisecond: UInt64 = 1_000_000
    static let second: UInt64 = 1_000_000_000
    static func elapsed(_ now: UInt64, since then: UInt64) -> UInt64 { now > then ? now - then : 0 }
}

// MARK: - Upstream: one TCP byte stream to a target through the exit

/// Opens a TCP stream to `address:port` through the exit: SOCKS5 (CONNECT or UDP ASSOCIATE) or HTTP
/// CONNECT through the proxy, optionally TLS-wrapped to the proxy, or a direct connection. The
/// provider's own connections are not routed into its tunnel, so this is the only way out.
final class Upstream {
    enum Command { case connect, udpAssociate }

    private let connection: NWConnection
    private let exit: Relay.Exit
    private let command: Command
    private let address: UInt32
    private let port: UInt16
    private let queue: DispatchQueue
    /// Bytes read past the end of the proxy handshake; delivered first by `receive`.
    private var pending = Data()
    private var completion: ((Error?) -> Void)?
    private var deadline: DispatchWorkItem?
    /// For `.udpAssociate`: the proxy's UDP relay endpoint from the SOCKS5 reply.
    private(set) var boundEndpoint: NWEndpoint?

    init(exit: Relay.Exit, command: Command, address: UInt32, port: UInt16, queue: DispatchQueue) {
        self.exit = exit
        self.command = command
        self.address = address
        self.port = port
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        switch exit {
        case let .proxy(host, proxyPort, _, tls, _, _):
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                               port: NWEndpoint.Port(rawValue: UInt16(clamping: proxyPort)) ?? .any)
            connection = NWConnection(to: endpoint, using: NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: tcp))
        case .directInterface:
            let endpoint = NWEndpoint.hostPort(host: .ipv4(IPv4Address(Data(bytes32(address)))!),
                                               port: NWEndpoint.Port(rawValue: port) ?? .any)
            connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        }
    }

    /// Connects and runs the proxy handshake; `completion(nil)` once bytes can flow. Any failure,
    /// including the path being unavailable (`.waiting`), fails the connection — never a fallback.
    func connect(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
        let deadline = DispatchWorkItem { [weak self] in self?.finish(RelayError.timeout) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.handshake()
            case .waiting(let error), .failed(let error): self.finish(error)
            case .cancelled: self.finish(RelayError.closed)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    /// Half-closes the stream (TCP FIN to the target).
    func sendEOF() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func receive(_ handler: @escaping (Data?, Bool, Error?) -> Void) {
        if !pending.isEmpty {
            let data = pending
            pending = Data()
            queue.async { handler(data, false, nil) }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            handler(data, isComplete, error)
        }
    }

    func readExactly(_ count: Int, _ handler: @escaping (Data?) -> Void) {
        read(count, onFailure: { _ in handler(nil) }) { handler(Data($0)) }
    }

    func cancel() {
        completion = nil
        deadline?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func finish(_ error: Error?) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel()
        if error != nil { connection.cancel() }
        completion(error)
    }

    private func fail(_ message: String) { finish(RelayError.proxy(message)) }

    // MARK: Handshakes

    private func handshake() {
        switch exit {
        case .directInterface:
            if command == .connect { finish(nil) } else { fail("UDP ASSOCIATE needs a SOCKS5 exit") }
        case let .proxy(_, _, socks, _, username, password):
            if socks {
                socksGreeting(username: username, password: password)
            } else if command == .connect {
                httpConnect(username: username, password: password)
            } else {
                fail("UDP ASSOCIATE needs a SOCKS5 exit")
            }
        }
    }

    private func socksGreeting(username: String?, password: String?) {
        let auth = !(username ?? "").isEmpty
        write(auth ? [5, 2, 0x00, 0x02] : [5, 1, 0x00])
        readHandshake(2) { [self] reply in
            guard reply[0] == 5 else { return fail("not a SOCKS5 proxy") }
            switch reply[1] {
            case 0x00: socksRequest()
            case 0x02 where auth: socksAuthenticate(username: username ?? "", password: password ?? "")
            default: fail("SOCKS5 proxy accepted no offered auth method")
            }
        }
    }

    private func socksAuthenticate(username: String, password: String) {
        let user = Array(username.utf8.prefix(255)), pass = Array(password.utf8.prefix(255))
        write([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)
        readHandshake(2) { [self] reply in
            reply[1] == 0 ? socksRequest() : fail("SOCKS5 authentication rejected")
        }
    }

    private func socksRequest() {
        // CONNECT carries the target; UDP ASSOCIATE sends 0.0.0.0:0 ("from any address").
        let (cmd, address, port): (UInt8, UInt32, UInt16) = command == .connect ? (1, self.address, self.port) : (3, 0, 0)
        write([5, cmd, 0, 1] + bytes32(address) + bytes16(port))
        readHandshake(4) { [self] header in
            guard header[0] == 5 else { return fail("bad SOCKS5 reply") }
            guard header[1] == 0 else { return fail("SOCKS5 request failed, reply \(header[1])") }
            switch header[3] {
            case 1: readHandshake(6) { [self] a in bound(.ipv4(IPv4Address(Data(a[0..<4]))!), port: be16(a, 4)) }
            case 4: readHandshake(18) { [self] a in bound(.ipv6(IPv6Address(Data(a[0..<16]))!), port: be16(a, 16)) }
            case 3:
                readHandshake(1) { [self] length in
                    readHandshake(Int(length[0]) + 2) { [self] a in
                        let name = String(decoding: a[0..<(a.count - 2)], as: UTF8.self)
                        bound(NWEndpoint.Host(name), port: be16(a, a.count - 2))
                    }
                }
            default: fail("bad SOCKS5 address type")
            }
        }
    }

    private func bound(_ host: NWEndpoint.Host, port: UInt16) {
        var host = host
        // "0.0.0.0" means "the address you already talk to": the proxy itself.
        if case .ipv4(let v4) = host, v4.rawValue == Data([0, 0, 0, 0]), case let .proxy(proxyHost, _, _, _, _, _) = exit {
            host = NWEndpoint.Host(proxyHost)
        }
        if let port = NWEndpoint.Port(rawValue: port) {
            boundEndpoint = .hostPort(host: host, port: port)
        }
        finish(nil)
    }

    private func httpConnect(username: String?, password: String?) {
        let target = "\(bytes32(address).map(String.init).joined(separator: ".")):\(port)"
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let username, !username.isEmpty {
            let credentials = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(credentials)\r\n"
        }
        request += "\r\n"
        write(Array(request.utf8))
        readResponseHead { [self] head in
            let statusLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = statusLine.split(separator: " ")
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].hasPrefix("2") else {
                return fail("HTTP CONNECT refused: \(parts.count >= 2 ? String(parts[1]) : "malformed")")
            }
            finish(nil)
        }
    }

    private func readResponseHead(_ then: @escaping (String) -> Void) {
        if let end = pending.range(of: Data("\r\n\r\n".utf8)) {
            let head = String(decoding: pending[pending.startIndex..<end.upperBound], as: UTF8.self)
            pending = Data(pending[end.upperBound...])
            then(head)
            return
        }
        guard pending.count < 16384 else { return fail("HTTP CONNECT response too large") }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self, self.completion != nil else { return }
            if let data { self.pending.append(data) }
            if let error { return self.finish(error) }
            if isComplete && self.pending.range(of: Data("\r\n\r\n".utf8)) == nil { return self.finish(RelayError.closed) }
            self.readResponseHead(then)
        }
    }

    private func write(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    private func readHandshake(_ count: Int, _ then: @escaping ([UInt8]) -> Void) {
        read(count, onFailure: { [weak self] in self?.finish($0) }, then)
    }

    private func read(_ count: Int, onFailure: @escaping (Error) -> Void, _ then: @escaping ([UInt8]) -> Void) {
        if pending.count >= count {
            let out = [UInt8](pending.prefix(count))
            pending = Data(pending.dropFirst(count))
            then(out)
            return
        }
        connection.receive(minimumIncompleteLength: count - pending.count, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.pending.append(data) }
            if let error { return onFailure(error) }
            if self.pending.count < count && isComplete { return onFailure(RelayError.closed) }
            self.read(count, onFailure: onFailure, then)
        }
    }
}

// MARK: - TCP: a minimal endpoint terminating the app's connection

/// Terminates one app TCP connection and relays its bytes to an `Upstream`. Deliberately small:
/// no window scaling, SACK or timestamps are offered (so the app's stack does not use them),
/// in-order delivery only (out-of-order segments are dropped and re-ACKed — the link is a local
/// in-memory queue, so loss is rare), go-back-N retransmission on timeout.
final class TCPFlow {
    private enum State { case connecting, synAckSent, established, closed }

    private static let initialRTO = 1 * Clock.second
    private static let maxRTO = 8 * Clock.second
    private static let maxRetries = 8
    private static let idleTimeout = 600 * Clock.second
    /// Bytes from upstream buffered and not yet sent before we stop reading upstream.
    private static let readAheadLimit = 64 * 1024
    /// The receive window we advertise; shrinks while upstream writes are pending.
    private static let receiveWindow = 65535

    let key: FlowKey
    private weak var relay: Relay?
    private let upstream: Upstream
    private var state = State.connecting

    private let iss: UInt32
    private var sndUna: UInt32
    private var sndNxt: UInt32
    private var sndMax: UInt32
    private var rcvNxt: UInt32
    private var peerWindow: Int
    private let peerMSS: Int
    /// Bytes from upstream, starting at `sndUna` from index `bufferHead`.
    private var sendBuffer: [UInt8] = []
    private var bufferHead = 0

    private var upstreamEOF = false
    private var finSeq: UInt32?
    private var finSent = false
    private var finAcked = false
    private var appFIN = false
    private var receiving = false
    private var upstreamQueued = 0

    private var rto = TCPFlow.initialRTO
    private var retries = 0
    private var rtoDeadline: UInt64?
    private var lastTransmit: UInt64 = 0
    private var lastActivity = Clock.now()

    init(key: FlowKey, syn: TCPSegment, relay: Relay, upstream: Upstream) {
        self.key = key
        self.relay = relay
        self.upstream = upstream
        rcvNxt = syn.seq &+ 1
        let iss = UInt32.random(in: .min ... .max)
        self.iss = iss
        sndUna = iss
        sndNxt = iss
        sndMax = iss
        peerWindow = Int(syn.window)
        peerMSS = min(syn.mss ?? 536, Relay.mss)
    }

    func open() {
        upstream.connect { [weak self] error in
            guard let self, self.state == .connecting else { return }
            if let error {
                // Fail-closed: the app's connection is refused; nothing is sent anywhere else.
                self.relay?.log.error("tcp upstream failed: \(String(describing: error), privacy: .public)")
                self.reset(failed: true)
                return
            }
            self.state = .synAckSent
            self.sendSynAck()
        }
    }

    /// Drops the flow without telling the app (the tunnel is going away).
    func abandon() {
        state = .closed
        upstream.cancel()
    }

    // MARK: Segments from the app

    func receive(_ seg: TCPSegment) {
        lastActivity = Clock.now()
        if seg.flags & TCPFlag.rst != 0 {
            close(failed: false)
            return
        }
        switch state {
        case .connecting, .closed:
            return // retransmitted SYN while upstream connects: answered once it is up
        case .synAckSent:
            if seg.flags & TCPFlag.syn != 0 && seg.flags & TCPFlag.ack == 0 {
                sendSynAck()
                return
            }
            guard seg.flags & TCPFlag.ack != 0, seg.ack == iss &+ 1 else { return }
            sndUna = seg.ack
            state = .established
            retries = 0
            rto = Self.initialRTO
            rtoDeadline = nil
            processEstablished(seg)
            startReceiving()
        case .established:
            processEstablished(seg)
        }
    }

    private func processEstablished(_ seg: TCPSegment) {
        if seg.flags & TCPFlag.syn != 0 {
            sendAck()
            return
        }
        if seg.flags & TCPFlag.ack != 0 { handleAck(seg.ack, window: Int(seg.window)) }
        guard state == .established else { return }

        let fin = seg.flags & TCPFlag.fin != 0
        let carriesSequence = !seg.payload.isEmpty || fin
        let offset = Int(Int32(bitPattern: rcvNxt &- seg.seq))
        if offset < 0 {
            if carriesSequence { sendAck() } // a gap: re-ACK so the app retransmits in order
            return
        }
        if offset < seg.payload.count && !appFIN {
            let data = seg.payload.dropFirst(offset)
            rcvNxt &+= UInt32(data.count)
            forwardUpstream(Data(data))
        }
        if fin, !appFIN, seg.seq &+ UInt32(seg.payload.count) == rcvNxt {
            appFIN = true
            rcvNxt &+= 1
            upstream.sendEOF()
        }
        if carriesSequence { sendAck() }
        closeIfDone()
    }

    private func handleAck(_ ack: UInt32, window: Int) {
        peerWindow = window
        let acked = Int(Int32(bitPattern: ack &- sndUna))
        let outstanding = Int(Int32(bitPattern: sndMax &- sndUna))
        guard acked > 0, acked <= outstanding else {
            trySend()
            return
        }
        var dataAcked = acked
        if let finSeq, Int32(bitPattern: ack &- finSeq) > 0 {
            finAcked = true
            dataAcked -= 1
        }
        bufferHead += min(dataAcked, sendBuffer.count - bufferHead)
        sndUna = ack
        if Int32(bitPattern: sndNxt &- ack) < 0 { sndNxt = ack }
        retries = 0
        rto = Self.initialRTO
        rtoDeadline = sndUna == sndNxt ? nil : Clock.now() + rto
        trySend()
    }

    // MARK: Data to the app

    private func trySend() {
        guard state == .established else { return }
        let buffered = sendBuffer.count - bufferHead
        if !finSent {
            while true {
                let inFlight = Int(sndNxt &- sndUna)
                let available = buffered - inFlight
                let window = peerWindow - inFlight
                guard available > 0, window > 0 else { break }
                let length = min(available, peerMSS, window)
                let start = bufferHead + inFlight
                transmit(seq: sndNxt, payload: sendBuffer[start..<(start + length)])
                sndNxt &+= UInt32(length)
            }
            if upstreamEOF, !finAcked, Int(sndNxt &- sndUna) == buffered {
                finSeq = sndNxt
                finSent = true
                transmit(seq: sndNxt, flags: TCPFlag.fin | TCPFlag.ack)
                sndNxt &+= 1
            }
        }
        if Int32(bitPattern: sndNxt &- sndMax) > 0 { sndMax = sndNxt }

        if bufferHead > 65536 && bufferHead * 2 > sendBuffer.count {
            sendBuffer.removeFirst(bufferHead)
            bufferHead = 0
        }
        let unsent = sendBuffer.count - bufferHead - Int(sndNxt &- sndUna)
        if !receiving, !upstreamEOF, unsent < Self.readAheadLimit { startReceiving() }
        closeIfDone()
    }

    private func transmit(seq: UInt32, flags: UInt8 = TCPFlag.ack | TCPFlag.psh, payload: ArraySlice<UInt8> = []) {
        if rtoDeadline == nil { rtoDeadline = Clock.now() + rto }
        lastTransmit = Clock.now()
        emit(flags: flags, seq: seq, payload: payload)
    }

    private func startReceiving() {
        guard state == .established, !receiving, !upstreamEOF else { return }
        receiving = true
        upstream.receive { [weak self] data, isComplete, error in
            guard let self, self.state != .closed else { return }
            self.receiving = false
            if error != nil {
                self.reset(failed: true)
                return
            }
            if let data, !data.isEmpty {
                self.lastActivity = Clock.now()
                self.sendBuffer.append(contentsOf: data)
            }
            if isComplete { self.upstreamEOF = true }
            self.trySend()
        }
    }

    // MARK: Data from the app

    private var advertisedWindow: Int { max(0, Self.receiveWindow - upstreamQueued) }

    private func forwardUpstream(_ data: Data) {
        upstreamQueued += data.count
        upstream.send(data) { [weak self] error in
            guard let self, self.state != .closed else { return }
            let before = self.advertisedWindow
            self.upstreamQueued -= data.count
            if error != nil {
                self.reset(failed: true)
                return
            }
            if before < Relay.mss && self.advertisedWindow >= Relay.mss { self.sendAck() } // window update
        }
    }

    // MARK: Timers and teardown

    func tick(_ now: UInt64) {
        switch state {
        case .connecting, .closed:
            return
        case .synAckSent:
            if Clock.elapsed(now, since: lastTransmit) >= rto {
                retries += 1
                guard retries <= Self.maxRetries else { return reset(failed: true) }
                rto = min(rto * 2, Self.maxRTO)
                sendSynAck()
            }
        case .established:
            if Clock.elapsed(now, since: lastActivity) >= Self.idleTimeout { return reset(failed: false) }
            if let deadline = rtoDeadline, now >= deadline {
                retries += 1
                guard retries <= Self.maxRetries else { return reset(failed: true) }
                rto = min(rto * 2, Self.maxRTO)
                rtoDeadline = nil
                sndNxt = sndUna // go back N
                if finSent && !finAcked { finSent = false }
                trySend()
            } else if peerWindow == 0, sndNxt == sndUna, sendBuffer.count > bufferHead, Clock.elapsed(now, since: lastTransmit) >= rto {
                // Zero-window probe: one byte past the window so the app reports when it opens.
                transmit(seq: sndNxt, payload: sendBuffer[bufferHead..<(bufferHead + 1)])
                sndNxt &+= 1
                if Int32(bitPattern: sndNxt &- sndMax) > 0 { sndMax = sndNxt }
            }
        }
    }

    private func closeIfDone() {
        if appFIN && finAcked { close(failed: false) }
    }

    private func reset(failed: Bool) {
        if state != .closed {
            emit(flags: TCPFlag.rst | TCPFlag.ack, seq: sndNxt, payload: [])
        }
        close(failed: failed)
    }

    private func close(failed: Bool) {
        guard state != .closed else { return }
        state = .closed
        upstream.cancel()
        relay?.tcpFlowClosed(key, failed: failed)
    }

    private func sendSynAck() {
        lastTransmit = Clock.now()
        let mss = UInt16(Relay.mss)
        emit(flags: TCPFlag.syn | TCPFlag.ack, seq: iss, options: [2, 4, UInt8(mss >> 8), UInt8(mss & 0xff)], payload: [])
        sndNxt = iss &+ 1
        sndMax = sndNxt
    }

    private func sendAck() {
        emit(flags: TCPFlag.ack, seq: sndNxt, payload: [])
    }

    private func emit(flags: UInt8, seq: UInt32, options: [UInt8] = [], payload: ArraySlice<UInt8>) {
        relay?.emit(PacketBuilder.tcp(src: key.dstIP, srcPort: key.dstPort, dst: key.srcIP, dstPort: key.srcPort,
                                      seq: seq, ack: rcvNxt, flags: flags, window: UInt16(min(advertisedWindow, 65535)),
                                      options: options, payload: payload))
    }
}

// MARK: - UDP

/// `directInterface` exit: one connected UDP socket per 5-tuple.
final class DirectUDPFlow {
    private static let idleTimeout = 120 * Clock.second

    let key: FlowKey
    private weak var relay: Relay?
    private let connection: NWConnection
    private var ready = false
    private var closed = false
    private var queued: [Data] = []
    private var lastActivity = Clock.now()

    init(key: FlowKey, relay: Relay) {
        self.key = key
        self.relay = relay
        connection = NWConnection(host: .ipv4(IPv4Address(Data(bytes32(key.dstIP)))!),
                                  port: NWEndpoint.Port(rawValue: key.dstPort) ?? .any, using: .udp)
    }

    func start() {
        guard let relay else { return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.queued.forEach { self.connection.send(content: $0, completion: .idempotent) }
                self.queued.removeAll()
                self.receiveLoop()
            case .waiting, .failed, .cancelled:
                self.close()
            default: break
            }
        }
        connection.start(queue: relay.queue)
    }

    func send(_ payload: [UInt8]) {
        guard !closed else { relay?.countUDPDrop(); return }
        lastActivity = Clock.now()
        if ready {
            connection.send(content: Data(payload), completion: .idempotent)
        } else if queued.count < 16 {
            queued.append(Data(payload))
        } else {
            relay?.countUDPDrop()
        }
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty, data.count <= Relay.maxUDPPayload {
                self.lastActivity = Clock.now()
                self.relay?.emit(PacketBuilder.udp(src: self.key.dstIP, srcPort: self.key.dstPort,
                                                   dst: self.key.srcIP, dstPort: self.key.srcPort, payload: [UInt8](data)))
            }
            if error == nil { self.receiveLoop() } else { self.close() }
        }
    }

    func tick(_ now: UInt64) {
        if Clock.elapsed(now, since: lastActivity) >= Self.idleTimeout { close() }
    }

    func abandon() {
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func close() {
        guard !closed else { return }
        abandon()
        relay?.directUDPClosed(key)
    }
}

/// SOCKS5 exit without TLS: one UDP ASSOCIATE per app socket. The TCP control connection must stay
/// open for the association to live; when it ends, the session ends and its packets are dropped.
final class SocksUDPSession {
    private enum State { case connecting, ready, failed }
    private static let idleTimeout = 120 * Clock.second
    /// How long a failed association keeps dropping (rather than re-dialling the proxy per packet).
    private static let failureHold = 5 * Clock.second

    let app: Endpoint
    private weak var relay: Relay?
    private let proxyHost: String
    private var control: Upstream?
    private var relayConnection: NWConnection?
    private var state = State.connecting
    private var queued: [Data] = []
    private var lastActivity = Clock.now()
    private var failedAt: UInt64 = 0

    init(app: Endpoint, proxyHost: String, relay: Relay) {
        self.app = app
        self.proxyHost = proxyHost
        self.relay = relay
    }

    func start() {
        guard let relay else { return }
        let control = Upstream(exit: relay.exit, command: .udpAssociate, address: 0, port: 0, queue: relay.queue)
        self.control = control
        control.connect { [weak self] error in
            guard let self, self.state == .connecting else { return }
            guard error == nil, let endpoint = control.boundEndpoint else {
                self.relay?.log.error("socks udp associate failed: \(String(describing: error), privacy: .public)")
                return self.fail()
            }
            self.watchControl()
            let connection = NWConnection(to: endpoint, using: .udp)
            self.relayConnection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard self.state == .connecting else { return }
                    self.state = .ready
                    self.queued.forEach { connection.send(content: $0, completion: .idempotent) }
                    self.queued.removeAll()
                    self.receiveLoop()
                case .waiting, .failed:
                    self.fail()
                default: break
                }
            }
            connection.start(queue: relay.queue)
        }
    }

    func send(to address: UInt32, port: UInt16, payload: [UInt8]) {
        // RSV RSV FRAG=0 ATYP=IPv4 DST.ADDR DST.PORT DATA
        let datagram = Data([0, 0, 0, 1] + bytes32(address) + bytes16(port) + payload)
        lastActivity = Clock.now()
        switch state {
        case .ready: relayConnection?.send(content: datagram, completion: .idempotent)
        case .connecting where queued.count < 16: queued.append(datagram)
        default: relay?.countUDPDrop()
        }
    }

    private func receiveLoop() {
        relayConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.state == .ready else { return }
            if let data { self.deliver([UInt8](data)) }
            if error == nil { self.receiveLoop() } else { self.fail() }
        }
    }

    private func deliver(_ d: [UInt8]) {
        // Replies carry the peer's address; only unfragmented IPv4 sources can be mapped back.
        guard d.count >= 10, d[2] == 0, d[3] == 1 else { relay?.countUDPDrop(); return }
        let payload = Array(d[10...])
        guard payload.count <= Relay.maxUDPPayload else { relay?.countUDPDrop(); return }
        lastActivity = Clock.now()
        relay?.emit(PacketBuilder.udp(src: be32(d, 4), srcPort: be16(d, 8), dst: app.address, dstPort: app.port,
                                      payload: payload))
    }

    private func watchControl() {
        control?.receive { [weak self] _, isComplete, error in
            guard let self, self.state != .failed else { return }
            if isComplete || error != nil { return self.fail() } // association ended
            self.watchControl()
        }
    }

    func tick(_ now: UInt64) {
        switch state {
        case .failed: if Clock.elapsed(now, since: failedAt) >= Self.failureHold { relay?.socksUDPClosed(app) }
        default: if Clock.elapsed(now, since: lastActivity) >= Self.idleTimeout { abandon(); relay?.socksUDPClosed(app) }
        }
    }

    func abandon() {
        state = .failed
        queued.removeAll()
        control?.cancel()
        control = nil
        relayConnection?.stateUpdateHandler = nil
        relayConnection?.cancel()
        relayConnection = nil
    }

    private func fail() {
        guard state != .failed else { return }
        abandon()
        failedAt = Clock.now()
    }
}

// MARK: - Packets

enum TCPFlag {
    static let fin: UInt8 = 0x01, syn: UInt8 = 0x02, rst: UInt8 = 0x04, psh: UInt8 = 0x08, ack: UInt8 = 0x10
}

struct IPv4Packet {
    let bytes: [UInt8]
    let src: UInt32, dst: UInt32
    let proto: UInt8
    let payloadStart: Int, payloadEnd: Int

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] >> 4 == 4 else { return nil }
        let headerLength = Int(b[0] & 0x0f) * 4
        let totalLength = Int(be16(b, 2))
        guard headerLength >= 20, totalLength >= headerLength, totalLength <= b.count else { return nil }
        // Fragments are not reassembled; the app's stack fits TCP into the MTU by MSS.
        guard be16(b, 6) & 0x3fff == 0 else { return nil }
        bytes = b
        proto = b[9]
        src = be32(b, 12)
        dst = be32(b, 16)
        payloadStart = headerLength
        payloadEnd = totalLength
    }
}

struct TCPSegment {
    let srcPort: UInt16, dstPort: UInt16
    let seq: UInt32, ack: UInt32
    let flags: UInt8
    let window: UInt16
    let mss: Int?
    let payload: ArraySlice<UInt8>

    init?(_ ip: IPv4Packet) {
        let b = ip.bytes, o = ip.payloadStart, end = ip.payloadEnd
        guard end - o >= 20 else { return nil }
        let dataOffset = Int(b[o + 12] >> 4) * 4
        guard dataOffset >= 20, o + dataOffset <= end else { return nil }
        srcPort = be16(b, o)
        dstPort = be16(b, o + 2)
        seq = be32(b, o + 4)
        ack = be32(b, o + 8)
        flags = b[o + 13]
        window = be16(b, o + 14)
        var mss: Int?
        var i = o + 20
        while i < o + dataOffset {
            let kind = b[i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < o + dataOffset else { break }
            let length = Int(b[i + 1])
            guard length >= 2, i + length <= o + dataOffset else { break }
            if kind == 2 && length == 4 { mss = Int(be16(b, i + 2)) }
            i += length
        }
        self.mss = mss
        payload = b[(o + dataOffset)..<end]
    }
}

enum PacketBuilder {
    static func tcp(src: UInt32, srcPort: UInt16, dst: UInt32, dstPort: UInt16, seq: UInt32, ack: UInt32,
                    flags: UInt8, window: UInt16, options: [UInt8] = [], payload: ArraySlice<UInt8> = []) -> Data {
        let headerLength = 20 + (options.count + 3) / 4 * 4
        var t = [UInt8](repeating: 0, count: headerLength)
        put16(&t, 0, srcPort)
        put16(&t, 2, dstPort)
        put32(&t, 4, seq)
        put32(&t, 8, ack)
        t[12] = UInt8(headerLength / 4) << 4
        t[13] = flags
        put16(&t, 14, window)
        t.replaceSubrange(20..<(20 + options.count), with: options)
        t.append(contentsOf: payload)
        return ipv4(src: src, dst: dst, proto: 6, transport: t, checksumOffset: 16)
    }

    static func udp(src: UInt32, srcPort: UInt16, dst: UInt32, dstPort: UInt16, payload: [UInt8]) -> Data {
        var u = [UInt8](repeating: 0, count: 8)
        put16(&u, 0, srcPort)
        put16(&u, 2, dstPort)
        put16(&u, 4, UInt16(8 + payload.count))
        u.append(contentsOf: payload)
        return ipv4(src: src, dst: dst, proto: 17, transport: u, checksumOffset: 6)
    }

    private static func ipv4(src: UInt32, dst: UInt32, proto: UInt8, transport: [UInt8], checksumOffset: Int) -> Data {
        var t = transport
        var sum = (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + UInt32(proto) + UInt32(t.count)
        add(t, to: &sum)
        var checksum = fold(sum)
        if proto == 17 && checksum == 0 { checksum = 0xffff }
        put16(&t, checksumOffset, checksum)

        var h = [UInt8](repeating: 0, count: 20)
        h[0] = 0x45
        put16(&h, 2, UInt16(20 + t.count))
        h[6] = 0x40 // DF
        h[8] = 64
        h[9] = proto
        put32(&h, 12, src)
        put32(&h, 16, dst)
        var headerSum: UInt32 = 0
        add(h, to: &headerSum)
        put16(&h, 10, fold(headerSum))
        return Data(h + t)
    }

    private static func add(_ b: [UInt8], to sum: inout UInt32) {
        var i = 0
        while i + 1 < b.count {
            sum &+= UInt32(b[i]) << 8 | UInt32(b[i + 1])
            i += 2
        }
        if i < b.count { sum &+= UInt32(b[i]) << 8 }
    }

    private static func fold(_ sum: UInt32) -> UInt16 {
        var s = sum
        while s >> 16 != 0 { s = (s & 0xffff) + (s >> 16) }
        return ~UInt16(s)
    }
}

// MARK: - DNS message helpers

enum DNS {
    /// Offset just past the (single) question, or nil when the message is not a plain query.
    static func questionEnd(_ m: [UInt8]) -> Int? {
        guard m.count >= 12, m[2] & 0x80 == 0, be16(m, 4) == 1 else { return nil }
        var i = 12
        while true {
            guard i < m.count else { return nil }
            let length = Int(m[i])
            if length == 0 { i += 1; break }
            guard length & 0xC0 == 0 else { return nil }
            i += 1 + length
        }
        guard i + 4 <= m.count else { return nil }
        return i + 4
    }

    static func qtype(_ m: [UInt8], _ questionEnd: Int) -> UInt16 { be16(m, questionEnd - 4) }

    /// The largest answer the client accepts over UDP: its EDNS(0) size (capped by our MTU), else 512.
    static func udpLimit(_ m: [UInt8], questionEnd q: Int) -> Int {
        guard be16(m, 10) >= 1, q + 11 <= m.count, m[q] == 0, be16(m, q + 1) == 41 else { return 512 }
        return max(512, min(Int(be16(m, q + 3)), Relay.maxUDPPayload))
    }

    /// A header-and-question answer to `query` (no records): NODATA, SERVFAIL, or truncated.
    static func response(to query: [UInt8], questionEnd: Int, rcode: UInt8, truncated: Bool) -> [UInt8] {
        var r = Array(query[0..<questionEnd])
        r[2] = 0x80 | (query[2] & 0x79) | (truncated ? 0x02 : 0) // QR, keep opcode and RD
        r[3] = 0x80 | rcode // RA
        for i in 6..<12 { r[i] = 0 }
        return r
    }
}

// MARK: - Byte helpers

func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}
func bytes16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func bytes32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
func put16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) { b[i] = UInt8(v >> 8); b[i + 1] = UInt8(v & 0xff) }
func put32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
    b[i] = UInt8(v >> 24); b[i + 1] = UInt8((v >> 16) & 0xff); b[i + 2] = UInt8((v >> 8) & 0xff); b[i + 3] = UInt8(v & 0xff)
}
