import OpenVPNLink
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CLwIP

/// The tunnel's SOCKS5 server: clients on the listening socket the app gave (127.0.0.1, the
/// launch's credentials), each request carried through lwIP and OpenVPN's packet socket — and
/// nowhere else. One thread: `run` polls the sockets and drives lwIP's input and timers; lwIP's
/// callbacks only note what happened, and what they noted is acted on once lwIP has returned.
public final class TunnelServer {
    public struct Tuning {
        /// How long a CONNECT may take, the name's lookup included, before the client is told.
        public var connectTimeout = 25.0
        /// How long a client may take over its greeting, credentials and request.
        public var handshakeTimeout = 15.0
        public var maximumClients = 1024
        /// Packets kept for the packet socket while it takes no more (then dropped: IP is lossy).
        public var packetQueueLimit = 2048
        /// Datagrams of a UDP association waiting for their destination's name.
        public var datagramsAwaitingName = 16
        public var resolver = TunnelResolver.Tuning()
        public init() {}
    }

    /// Why `run` returned.
    public enum Ending: Equatable, CustomStringConvertible {
        case stopped
        case parentGone
        case packetSocketClosed(Int32)
        case listenerFailed(Int32)
        /// The app's end of the lifeline closed: the app is gone.
        case lifelineCut

        public var description: String {
            switch self {
            case .lifelineCut: return "the app is gone"
            case .stopped: return "stopped"
            case .parentGone: return "OpenVPN is gone"
            case .packetSocketClosed(let code): return "OpenVPN's packet socket closed (\(code))"
            case .listenerFailed(let code): return "the listening socket failed (\(code))"
            }
        }
    }

    public struct Counts: Equatable, Sendable {
        public var clients = 0
        public var refusedCredentials = 0
        public var connects = 0
        public var connectFailures = 0
        public var associations = 0
        public var packetsIn = 0
        public var packetsOut = 0
        public var packetsDropped = 0
        public var namesResolved = 0
        public var namesFailed = 0
    }

    let settings: TunnelSettings
    let tuning: Tuning
    private(set) public var counts = Counts()
    private var clients: [Int32: SOCKSClient] = [:]
    private var associations: [Int32: UDPAssociation] = [:]
    private var resolver: TunnelResolver!
    private var deferred: [() -> Void] = []
    private var dirty: Set<Int32> = []
    private var packetQueue: [[UInt8]] = []
    private var packetQueueStart = 0
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var stopRequested = false
    private let parent: pid_t
    private var started = false
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    /// The loop's own pipe: a byte written to it (from a signal handler, from another thread)
    /// stops `run`.
    public var wakeDescriptor: Int32 { wakeWrite }

    public init(settings: TunnelSettings, tuning: Tuning = Tuning(), watchParent: Bool = true) {
        self.settings = settings
        self.tuning = tuning
        self.parent = watchParent ? TunnelSystem.parentProcess : 0
        var ends: [Int32] = [0, 0]
        if pipe(&ends) == 0 {
            wakeRead = ends[0]
            wakeWrite = ends[1]
            TunnelSystem.setNonBlocking(wakeRead)
            TunnelSystem.setNonBlocking(wakeWrite)
            TunnelSystem.setCloseOnExec(wakeRead)
            TunnelSystem.setCloseOnExec(wakeWrite)
        }
    }

    deinit {
        if wakeRead >= 0 { TunnelSystem.close(wakeRead) }
        if wakeWrite >= 0 { TunnelSystem.close(wakeWrite) }
    }

    /// Asks `run` to return: from any thread (a byte on the wake pipe, which the loop reads; a
    /// signal handler writes the same byte to `wakeDescriptor`).
    public func requestStop() {
        if wakeWrite >= 0 { _ = TunnelSystem.write(wakeWrite, [1]) }
    }

    /// The families the tunnel has an address of.
    var families: Set<TunnelAddress.Family> {
        var found: Set<TunnelAddress.Family> = []
        if settings.ipv4 != nil { found.insert(.v4) }
        if settings.ipv6 != nil { found.insert(.v6) }
        return found
    }

    /// Starts lwIP on the packet socket with the pushed addresses. Separate from `run` for tests.
    public func start() {
        guard !started else { return }
        started = true
        TunnelSystem.setNonBlocking(settings.packetSocket)
        TunnelSystem.setNonBlocking(settings.listeningSocket)
        TunnelSystem.setNoSigPipe(settings.packetSocket)
        // Bursts the far side of the pair has not read yet stay here rather than being dropped.
        TunnelSystem.setBuffer(settings.packetSocket, SO_RCVBUF, bytes: 1 << 20)
        TunnelSystem.setBuffer(settings.packetSocket, SO_SNDBUF, bytes: 1 << 20)
        lumen_net_start(packetOutput, Unmanaged.passUnretained(self).toOpaque(), UInt16(clamping: settings.mtu))
        lumen_net_set_ipv4(settings.ipv4?.bytes ?? [0, 0, 0, 0])
        lumen_net_set_ipv6(settings.ipv6?.bytes ?? [UInt8](repeating: 0, count: 16))
        resolver = TunnelResolver(servers: settings.dnsServers, families: families, tuning: tuning.resolver,
                                  later: { [unowned self] work in self.deferred.append(work) })
    }

    /// Serves until stopped, until OpenVPN's packet socket closes, or until OpenVPN (the parent) is gone.
    public func run() -> Ending {
        start()
        defer { shutDown() }
        while true {
            if stopRequested { return .stopped }
            if parent != 0, TunnelSystem.parentProcess != parent { return .parentGone }
            if let ending = step(maximumWait: 1000) { return ending }
        }
    }

    /// One turn of the loop: waits at most `maximumWait` ms for something to do, does it.
    /// Returns an ending when the server cannot go on.
    @discardableResult
    public func step(maximumWait: Int32) -> Ending? {
        let now = TunnelSystem.now
        var entries: [pollfd] = []
        entries.append(pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0))
        entries.append(pollfd(fd: settings.packetSocket, events: Int16(POLLIN), revents: 0))
        entries.append(pollfd(fd: settings.listeningSocket, events: clients.count < tuning.maximumClients ? Int16(POLLIN) : 0, revents: 0))
        entries.append(pollfd(fd: settings.lifeline ?? -1, events: Int16(POLLIN), revents: 0))
        let fixed = entries.count
        var order: [Int32] = []
        for (descriptor, client) in clients {
            var events: Int16 = 0
            if client.wantsRead { events |= Int16(POLLIN) }
            if client.hasOutput { events |= Int16(POLLOUT) }
            entries.append(pollfd(fd: descriptor, events: events, revents: 0))
            order.append(descriptor)
        }
        for descriptor in associations.keys {
            entries.append(pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0))
            order.append(descriptor)
        }
        var wait = min(Int32(lumen_net_timer_wait()), maximumWait)
        if let deadline = nextDeadline(now: now) { wait = min(wait, Int32(max(0, (deadline - now) * 1000).rounded(.up))) }
        if packetQueueStart < packetQueue.count { wait = min(wait, 2) }
        if !deferred.isEmpty || !dirty.isEmpty { wait = 0 }
        let ready = TunnelSystem.wait(&entries, milliseconds: max(0, wait))
        if ready < 0, !TunnelSystem.wouldBlock(TunnelSystem.lastError) { return .stopped }

        if entries[0].revents != 0 { drainWake() }
        if stopRequested { return .stopped }
        if entries[3].revents != 0, let lifeline = settings.lifeline {
            var byte: UInt8 = 0
            if read(lifeline, &byte, 1) <= 0 { return .lifelineCut }
        }
        let packetEvents = entries[1].revents
        if packetEvents & Int16(POLLIN) != 0 {
            if let ending = readPackets() { return ending }
        } else if packetEvents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            return .packetSocketClosed(0)
        }
        lumen_net_poll_timers()
        runDeferred()
        resolver.tick(now: TunnelSystem.now)
        runDeferred()
        if entries[2].revents & Int16(POLLIN) != 0 {
            if let ending = acceptClients() { return ending }
        } else if entries[2].revents & Int16(POLLNVAL) != 0 {
            return .listenerFailed(EBADF)
        }
        for index in fixed..<entries.count where entries[index].revents != 0 {
            let descriptor = order[index - fixed]
            if let client = clients[descriptor] {
                handle(client, events: entries[index].revents)
            } else if let association = associations[descriptor] {
                association.readFromClient(server: self)
            }
            runDeferred()
        }
        checkDeadlines(now: TunnelSystem.now)
        pumpDirty()
        flushPackets()
        return nil
    }

    // MARK: Packets

    private func readPackets() -> Ending? {
        for _ in 0..<512 {
            let count = buffer.withUnsafeMutableBytes { TunnelSystem.receive(settings.packetSocket, $0) }
            if count > 0 {
                counts.packetsIn += 1
                buffer.withUnsafeBufferPointer { lumen_net_input($0.baseAddress, count) }
                runDeferred()
                continue
            }
            if count == 0 { return .packetSocketClosed(0) }
            let code = TunnelSystem.lastError
            if TunnelSystem.wouldBlock(code) { return nil }
            if code == ECONNRESET || code == ENOTCONN || code == ECONNREFUSED || code == EBADF { return .packetSocketClosed(code) }
            return nil
        }
        return nil
    }

    /// lwIP's output: one packet into OpenVPN's socket, or the queue while that takes no more.
    fileprivate func sendPacket(_ packet: UnsafeRawBufferPointer) {
        if packetQueueStart < packetQueue.count {
            enqueue(Array(packet))
            return
        }
        let sent = TunnelSystem.send(settings.packetSocket, packet)
        if sent == packet.count {
            counts.packetsOut += 1
            return
        }
        let code = TunnelSystem.lastError
        if TunnelSystem.wouldBlock(code) || code == ENOBUFS {
            enqueue(Array(packet))
        } else {
            counts.packetsDropped += 1
        }
    }

    private func enqueue(_ packet: [UInt8]) {
        if packetQueue.count - packetQueueStart >= tuning.packetQueueLimit {
            counts.packetsDropped += 1
            return
        }
        packetQueue.append(packet)
    }

    private func flushPackets() {
        while packetQueueStart < packetQueue.count {
            let sent = packetQueue[packetQueueStart].withUnsafeBytes { TunnelSystem.send(settings.packetSocket, $0) }
            if sent < 0 {
                let code = TunnelSystem.lastError
                if TunnelSystem.wouldBlock(code) || code == ENOBUFS { break }
                counts.packetsDropped += 1
            } else {
                counts.packetsOut += 1
            }
            packetQueueStart += 1
        }
        if packetQueueStart == packetQueue.count {
            packetQueue.removeAll(keepingCapacity: true)
            packetQueueStart = 0
        } else if packetQueueStart > 1024 {
            packetQueue.removeFirst(packetQueueStart)
            packetQueueStart = 0
        }
    }

    // MARK: The loop's own work

    /// A byte on the wake pipe is a request to stop (`requestStop`, a signal).
    private func drainWake() {
        var scratch = [UInt8](repeating: 0, count: 64)
        while scratch.withUnsafeMutableBytes({ read(wakeRead, $0.baseAddress, $0.count) }) > 0 { stopRequested = true }
    }

    /// Work lwIP's callbacks and the resolver left for after they returned.
    func later(_ work: @escaping () -> Void) { deferred.append(work) }

    private func runDeferred() {
        var rounds = 0
        while !deferred.isEmpty && rounds < 64 {
            let work = deferred
            deferred.removeAll()
            for item in work { item() }
            rounds += 1
        }
    }

    func markDirty(_ client: SOCKSClient) { dirty.insert(client.descriptor) }

    private func pumpDirty() {
        var rounds = 0
        while !dirty.isEmpty && rounds < 8 {
            let descriptors = dirty
            dirty.removeAll()
            for descriptor in descriptors {
                if let client = clients[descriptor] { pump(client) }
            }
            runDeferred()
            rounds += 1
        }
    }

    private func nextDeadline(now: Double) -> Double? {
        var soonest = resolver?.nextDeadline
        for client in clients.values {
            if let deadline = client.deadline { soonest = min(soonest ?? deadline, deadline) }
        }
        return soonest
    }

    private func checkDeadlines(now: Double) {
        for client in Array(clients.values) {
            guard let deadline = client.deadline, deadline <= now else { continue }
            client.deadline = nil
            switch client.phase {
            case .greeting, .credentials, .request:
                close(client)
            case .resolving, .connecting:
                counts.connectFailures += 1
                fail(client, .ttlExpired)
            default:
                break
            }
        }
    }

    private func shutDown() {
        for client in Array(clients.values) { close(client, reset: true) }
        resolver?.close()
        runDeferred()
        flushPackets()
    }

    // MARK: Clients

    private func acceptClients() -> Ending? {
        while clients.count < tuning.maximumClients {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let descriptor = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(settings.listeningSocket, $0, &length) }
            }
            if descriptor < 0 {
                let code = TunnelSystem.lastError
                if TunnelSystem.wouldBlock(code) || code == ECONNABORTED { return nil }
                if code == EMFILE || code == ENFILE || code == ENOBUFS || code == ENOMEM { return nil }
                return .listenerFailed(code)
            }
            // Only this Mac: the listener is on 127.0.0.1, and a peer elsewhere is closed unread.
            guard let peer = TunnelSystem.endpoint(of: storage), TunnelSystem.isLoopback(peer.address) else {
                TunnelSystem.close(descriptor)
                continue
            }
            TunnelSystem.setNonBlocking(descriptor)
            TunnelSystem.setCloseOnExec(descriptor)
            TunnelSystem.setNoSigPipe(descriptor)
            var one: Int32 = 1
            _ = setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let client = SOCKSClient(descriptor: descriptor)
            client.deadline = TunnelSystem.now + tuning.handshakeTimeout
            clients[descriptor] = client
            counts.clients += 1
        }
        return nil
    }

    private func handle(_ client: SOCKSClient, events: Int16) {
        if events & Int16(POLLERR | POLLNVAL) != 0 {
            close(client, reset: true)
            return
        }
        if events & Int16(POLLOUT) != 0 { writeOut(client) }
        guard clients[client.descriptor] != nil else { return }
        if events & Int16(POLLIN | POLLHUP) != 0 { readIn(client) }
        guard clients[client.descriptor] != nil else { return }
        pump(client)
    }

    private func readIn(_ client: SOCKSClient) {
        switch client.phase {
        case .relaying:
            relayFromClient(client)
        case .associated:
            // The association lives as long as this connection: anything sent on it is read and
            // dropped, its end ends the association.
            let count = buffer.withUnsafeMutableBytes { TunnelSystem.receive(client.descriptor, $0) }
            if count == 0 || (count < 0 && !TunnelSystem.wouldBlock(TunnelSystem.lastError)) { close(client) }
        case .greeting, .credentials, .request:
            let count = buffer.withUnsafeMutableBytes { TunnelSystem.receive(client.descriptor, UnsafeMutableRawBufferPointer(rebasing: $0[0..<4096])) }
            if count == 0 || (count < 0 && !TunnelSystem.wouldBlock(TunnelSystem.lastError)) {
                close(client)
                return
            }
            if count > 0 {
                client.input += buffer[0..<count]
                handshake(client)
                // A handshake is a few hundred bytes at most: more, still in it, is not a client's.
                // (Bytes after a complete request are its optimistic data, kept for the connection.)
                if [.greeting, .credentials, .request].contains(client.phase), client.input.count > 1024 { close(client) }
            }
        case .resolving, .connecting:
            // Only a hang-up comes here (nothing is asked to be read until the connection is up).
            var probe: UInt8 = 0
            let count = recv(client.descriptor, &probe, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
            if count == 0 || (count < 0 && !TunnelSystem.wouldBlock(TunnelSystem.lastError)) { close(client, reset: true) }
        case .closing:
            break
        }
    }

    private func handshake(_ client: SOCKSClient) {
        while true {
            switch client.phase {
            case .greeting:
                switch SOCKS5Server.readGreeting(client.input) {
                case .needMore: return
                case .invalid: close(client); return
                case .value(let offersPassword, let consumed):
                    client.input.removeFirst(consumed)
                    client.queueControl(SOCKS5Server.methodChoice(acceptable: offersPassword))
                    guard offersPassword else { client.phase = .closing; client.closeAfterOutput = true; return }
                    client.phase = .credentials
                }
            case .credentials:
                switch SOCKS5Server.readCredentials(client.input) {
                case .needMore: return
                case .invalid: close(client); return
                case .value(let credentials, let consumed):
                    client.input.removeFirst(consumed)
                    let accepted = CredentialCheck.matches(username: credentials.username, password: credentials.password, verifier: settings.verifier)
                    client.queueControl(SOCKS5Server.credentialsAnswer(accepted: accepted))
                    guard accepted else {
                        counts.refusedCredentials += 1
                        client.phase = .closing
                        client.closeAfterOutput = true
                        return
                    }
                    client.phase = .request
                }
            case .request:
                switch SOCKS5Server.readRequest(client.input) {
                case .needMore: return
                case .invalid:
                    client.queueControl(SOCKS5Server.reply(.generalFailure))
                    client.phase = .closing
                    client.closeAfterOutput = true
                    return
                case .value(let request, let consumed):
                    client.input.removeFirst(consumed)
                    begin(request, for: client)
                    return
                }
            default:
                return
            }
        }
    }

    private func begin(_ request: SOCKS5Server.Request, for client: SOCKSClient) {
        switch request.command {
        case SOCKS5Server.Command.connect.rawValue:
            client.deadline = TunnelSystem.now + tuning.connectTimeout
            counts.connects += 1
            switch request.destination {
            case .address(let address):
                connect(client, to: address, port: request.port)
            case .name(let name):
                client.phase = .resolving
                resolver.resolve(name, now: TunnelSystem.now) { [weak self, weak client] result in
                    guard let self, let client, self.clients[client.descriptor] === client, client.phase == .resolving else { return }
                    switch result {
                    case .success(let addresses):
                        self.counts.namesResolved += 1
                        guard let address = self.pick(addresses) else {
                            self.counts.connectFailures += 1
                            self.fail(client, .hostUnreachable)
                            return
                        }
                        self.connect(client, to: address, port: request.port)
                    case .failure:
                        self.counts.namesFailed += 1
                        self.counts.connectFailures += 1
                        self.fail(client, .hostUnreachable)
                    }
                }
            }
        case SOCKS5Server.Command.udpAssociate.rawValue:
            var sender: (address: TunnelAddress, port: UInt16)?
            if case .address(let address) = request.destination, address.isAny || TunnelSystem.isLoopback(address) {
                sender = (address, request.port)
            } else if case .address = request.destination {
                // A sender elsewhere than this Mac could never send to a socket on 127.0.0.1.
                fail(client, .notAllowed)
                return
            }
            guard let association = UDPAssociation(control: client, server: self, sender: sender) else {
                fail(client, .generalFailure)
                return
            }
            associations[association.socket] = association
            client.association = association
            client.phase = .associated
            client.deadline = nil
            counts.associations += 1
            client.queueControl(SOCKS5Server.reply(.succeeded, bound: TunnelAddress("127.0.0.1"), port: association.port))
            markDirty(client)
        default:
            fail(client, .commandNotSupported)
        }
    }

    /// The address to connect to: an IPv4 one when the tunnel has IPv4, else an IPv6 one.
    private func pick(_ addresses: [TunnelAddress]) -> TunnelAddress? {
        if settings.ipv4 != nil, let four = addresses.first(where: { $0.family == .v4 }) { return four }
        if settings.ipv6 != nil, let six = addresses.first(where: { $0.family == .v6 }) { return six }
        return nil
    }

    private func connect(_ client: SOCKSClient, to address: TunnelAddress, port: UInt16) {
        guard families.contains(address.family) else {
            counts.connectFailures += 1
            fail(client, .networkUnreachable)
            return
        }
        var error: Int32 = 0
        let context = Unmanaged.passUnretained(client).toOpaque()
        let events = lumen_tcp_events(connected: tcpConnected, received: tcpReceived, acknowledged: tcpAcknowledged, failed: tcpFailed)
        let connection = address.bytes.withUnsafeBufferPointer {
            lumen_tcp_connect(address.family.rawValue, $0.baseAddress, port, events, context, &error)
        }
        guard let connection else {
            counts.connectFailures += 1
            fail(client, error == Int32(LUMEN_NET_ERR_ROUTE) ? .networkUnreachable : .generalFailure)
            return
        }
        client.server = self
        client.connection = connection
        client.phase = .connecting
    }

    /// Answers a request with an error and closes once the answer is out.
    private func fail(_ client: SOCKSClient, _ reply: SOCKS5Server.Reply) {
        if let connection = client.connection {
            lumen_tcp_free(connection, 1)
            client.connection = nil
        }
        client.deadline = nil
        client.queueControl(SOCKS5Server.reply(reply))
        client.phase = .closing
        client.closeAfterOutput = true
        markDirty(client)
    }

    /// Acts on what lwIP's callbacks noted, and moves data both ways as far as it can.
    private func pump(_ client: SOCKSClient) {
        guard clients[client.descriptor] === client else { return }
        if client.connectedNoted {
            client.connectedNoted = false
            if client.phase == .connecting, let connection = client.connection {
                var family: Int32 = 0
                var port: UInt16 = 0
                var bytes = [UInt8](repeating: 0, count: 16)
                lumen_tcp_local(connection, &family, &bytes, &port)
                let bound = family == 4 ? TunnelAddress(family: .v4, bytes: Array(bytes[0..<4])) : TunnelAddress(family: .v6, bytes: bytes)
                client.queueControl(SOCKS5Server.reply(.succeeded, bound: bound, port: port))
                client.phase = .relaying
                client.deadline = nil
                // Bytes that came in the same read as the request (optimistic data) are the first
                // the connection carries.
                if !client.input.isEmpty {
                    client.pendingToTunnel = client.input
                    client.input = []
                    sendPendingToTunnel(client)
                }
            }
        }
        if let error = client.failedNoted {
            client.failedNoted = nil
            if let connection = client.connection {
                lumen_tcp_free(connection, 1)
                client.connection = nil
            }
            if client.phase == .connecting {
                counts.connectFailures += 1
                fail(client, error == Int32(LUMEN_NET_ERR_RESET) ? .connectionRefused
                     : error == Int32(LUMEN_NET_ERR_TIMEOUT) ? .ttlExpired : .hostUnreachable)
            } else if client.phase == .relaying {
                // What came before the reset is delivered, then the client's connection ends.
                client.phase = .closing
                client.closeAfterOutput = true
                client.resetAfterOutput = true
            }
        }
        if client.hasOutput { writeOut(client) }
        guard clients[client.descriptor] === client else { return }
        if client.phase == .relaying {
            if client.acknowledgedNoted {
                client.acknowledgedNoted = false
                if !client.pendingToTunnel.isEmpty { sendPendingToTunnel(client) }
            }
            if client.tunnelFinished && !client.hasOutput && !client.clientShutDown {
                TunnelSystem.shutdownWrite(client.descriptor)
                client.clientShutDown = true
            }
            if client.clientFinished && client.pendingToTunnel.isEmpty && !client.finishSent, let connection = client.connection {
                lumen_tcp_finish(connection)
                client.finishSent = true
            }
            if client.clientShutDown && client.finishSent { close(client) }
        } else if client.phase == .closing, client.closeAfterOutput, !client.hasOutput {
            close(client, reset: client.resetAfterOutput)
        }
    }

    private func relayFromClient(_ client: SOCKSClient) {
        guard client.pendingToTunnel.isEmpty, !client.clientFinished, let connection = client.connection else { return }
        let room = lumen_tcp_room(connection)
        guard room > 0 else { return }
        let limit = min(room, buffer.count)
        let count = buffer.withUnsafeMutableBytes { TunnelSystem.receive(client.descriptor, UnsafeMutableRawBufferPointer(rebasing: $0[0..<limit])) }
        if count == 0 {
            client.clientFinished = true
            return
        }
        if count < 0 {
            if !TunnelSystem.wouldBlock(TunnelSystem.lastError) { close(client, reset: true) }
            return
        }
        let taken = buffer.withUnsafeBufferPointer { lumen_tcp_write(connection, $0.baseAddress, count) }
        if taken < count { client.pendingToTunnel = Array(buffer[taken..<count]) }
    }

    private func sendPendingToTunnel(_ client: SOCKSClient) {
        guard let connection = client.connection else { return }
        let taken = client.pendingToTunnel.withUnsafeBufferPointer { lumen_tcp_write(connection, $0.baseAddress, $0.count) }
        client.pendingToTunnel.removeFirst(taken)
    }

    private func writeOut(_ client: SOCKSClient) {
        while client.hasOutput {
            let sent = client.output.withUnsafeBytes { bytes in
                TunnelSystem.send(client.descriptor, UnsafeRawBufferPointer(rebasing: bytes[client.outputStart...]))
            }
            if sent < 0 {
                if TunnelSystem.wouldBlock(TunnelSystem.lastError) { return }
                close(client, reset: true)
                return
            }
            let data = client.wrote(sent)
            if data > 0, let connection = client.connection { lumen_tcp_consumed(connection, data) }
        }
    }

    func close(_ client: SOCKSClient, reset: Bool = false) {
        guard clients[client.descriptor] === client else { return }
        clients[client.descriptor] = nil
        dirty.remove(client.descriptor)
        if let connection = client.connection {
            lumen_tcp_free(connection, reset ? 1 : 0)
            client.connection = nil
        }
        if let association = client.association {
            associations[association.socket] = nil
            association.close()
            client.association = nil
        }
        if reset {
            var linger = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(client.descriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        }
        TunnelSystem.close(client.descriptor)
        client.phase = .closing
    }

    // MARK: Names for UDP associations

    func resolveForAssociation(_ name: String, completion: @escaping (TunnelAddress?) -> Void) {
        resolver.resolve(name, now: TunnelSystem.now) { [weak self] result in
            guard let self else { return }
            if case .success(let addresses) = result { completion(self.pick(addresses)) } else { completion(nil) }
        }
    }

    // MARK: For tests

    public var openClients: Int { clients.count }
    public var openAssociations: Int { associations.count }
}

// MARK: - lwIP's callbacks: they note, the loop acts.

private let packetOutput: lumen_net_output = { context, packet, length in
    guard let context, let packet else { return }
    let server = Unmanaged<TunnelServer>.fromOpaque(context).takeUnretainedValue()
    server.sendPacket(UnsafeRawBufferPointer(start: packet, count: length))
}

private func client(_ context: UnsafeMutableRawPointer?) -> SOCKSClient? {
    guard let context else { return nil }
    return Unmanaged<SOCKSClient>.fromOpaque(context).takeUnretainedValue()
}

private let tcpConnected: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let client = client(context) else { return }
    client.connectedNoted = true
    client.server?.markDirty(client)
}

private let tcpReceived: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { context, bytes, length in
    guard let client = client(context) else { return }
    if length == 0 || bytes == nil {
        client.tunnelFinished = true
    } else {
        client.output.append(contentsOf: UnsafeBufferPointer(start: bytes, count: length))
    }
    client.server?.markDirty(client)
}

private let tcpAcknowledged: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Void = { context, _ in
    guard let client = client(context) else { return }
    client.acknowledgedNoted = true
    client.server?.markDirty(client)
}

private let tcpFailed: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { context, error in
    guard let client = client(context) else { return }
    client.failedNoted = error
    client.server?.markDirty(client)
}

/// One client of the local port.
final class SOCKSClient {
    enum Phase: Equatable {
        case greeting, credentials, request, resolving, connecting, relaying, associated, closing
    }

    let descriptor: Int32
    var phase = Phase.greeting
    weak var server: TunnelServer?
    var deadline: Double?
    /// Handshake bytes not read yet.
    var input: [UInt8] = []
    /// Bytes for the client: replies first (`controlBytes` of them), then what the tunnel's
    /// connection received. Received bytes are given back to lwIP's window only once written.
    var output: [UInt8] = []
    var outputStart = 0
    private var controlBytes = 0
    var connection: OpaquePointer?
    var association: UDPAssociation?
    /// Read from the client, not taken by the tunnel's connection yet.
    var pendingToTunnel: [UInt8] = []
    var closeAfterOutput = false
    var resetAfterOutput = false
    var clientFinished = false
    var finishSent = false
    var tunnelFinished = false
    var clientShutDown = false
    // Noted by lwIP's callbacks.
    var connectedNoted = false
    var acknowledgedNoted = false
    var failedNoted: Int32?

    init(descriptor: Int32) { self.descriptor = descriptor }

    var hasOutput: Bool { outputStart < output.count }

    /// Read from the client only when there is somewhere for it to go.
    var wantsRead: Bool {
        switch phase {
        case .greeting, .credentials, .request: return !closeAfterOutput
        // Bytes a client sends before its reply (optimistic data) wait in its socket until the
        // connection is up: asking for them now would wake the loop for nothing until then. Its
        // end is still seen (POLLHUP).
        case .resolving, .connecting: return false
        case .associated: return true
        case .relaying: return pendingToTunnel.isEmpty && !clientFinished
        case .closing: return false
        }
    }

    /// Queues a reply: after the replies already queued, ahead of any data the tunnel's connection
    /// received (which may have come with its establishment, before the reply was queued).
    func queueControl(_ bytes: [UInt8]) {
        output.insert(contentsOf: bytes, at: outputStart + controlBytes)
        controlBytes += bytes.count
    }

    /// `count` bytes were written to the client: returns how many of them were the tunnel's data.
    func wrote(_ count: Int) -> Int {
        let control = min(count, controlBytes)
        controlBytes -= control
        outputStart += count
        if outputStart == output.count {
            output.removeAll(keepingCapacity: true)
            outputStart = 0
        } else if outputStart > 262_144 {
            output.removeFirst(outputStart)
            outputStart = 0
        }
        return count - control
    }
}
