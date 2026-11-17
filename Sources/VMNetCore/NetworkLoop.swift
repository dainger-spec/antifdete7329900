#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The guest's wire: a descriptor that carries one Ethernet frame per read and per write.
///
/// A frame the wire does not take at once (its buffer is full) is kept and tried again a moment
/// later, in order, and connections send no new data meanwhile — the wire's limit becomes the
/// proxy's pace. Only when even the kept frames are too many is one lost; TCP's timers recover it.
final class FrameChannel: FrameSink {
    /// Frames kept for a full wire, at most. Past it a frame is lost.
    static let heldLimit = 1 << 20

    let descriptor: Int32
    private let isSocket: Bool
    private var held: [[UInt8]] = []
    private var heldHead = 0
    private var heldBytes = 0
    private var retryInterval = 0.001
    private var emptyReads = 0
    /// When to try the kept frames again; infinity when none is kept.
    private(set) var retryAt = Double.infinity
    private(set) var lost: UInt64 = 0
    /// The loop's clock, set by it at each turn.
    var now = 0.0
    /// For tests: the share of frames dropped on the way to the guest.
    var lossToGuest = 0.0

    init(descriptor: Int32) {
        self.descriptor = descriptor
        isSocket = Sys.isSocket(descriptor)
        if isSocket {
            Sys.setNoSigPipe(descriptor)
            // A socket pair's default buffers hold a handful of frames (on macOS, two): a guest
            // that sends faster than this loop turns would lose most of them.
            Sys.raiseBuffer(descriptor, Sys.receiveBufferOption, to: 4 << 20)
            Sys.raiseBuffer(descriptor, Sys.sendBufferOption, to: 1 << 20)
        } else {
            Sys.setNonBlocking(descriptor)
        }
    }

    var isCongested: Bool { heldHead < held.count }

    func send(_ frame: UnsafeRawBufferPointer) {
        if lossToGuest > 0, Double.random(in: 0..<1) < lossToGuest { return }
        if isCongested {
            hold(frame)
            return
        }
        switch write(frame) {
        case .sent:
            break
        case .full:
            hold(frame)
            retryInterval = 0.001
            retryAt = now + retryInterval
        case .failed:
            lost += 1
        }
    }

    /// Tries the kept frames again, in order. True when none is left.
    func retry() -> Bool {
        while heldHead < held.count {
            let result = held[heldHead].withUnsafeBytes { write($0) }
            if result == .full {
                retryAt = now + retryInterval
                // A wire that stays full (a paused guest) is asked less and less often.
                retryInterval = min(retryInterval * 2, 0.05)
                return false
            }
            if result == .failed { lost += 1 }
            heldBytes -= held[heldHead].count
            held[heldHead] = []
            heldHead += 1
            retryInterval = 0.001
        }
        held.removeAll(keepingCapacity: true)
        heldHead = 0
        heldBytes = 0
        retryAt = .infinity
        return true
    }

    enum Received {
        case frame(Int)
        /// Nothing waits.
        case nothing
        /// The wire is gone.
        case closed
    }

    /// The next frame, if one waits.
    func receive(into buffer: UnsafeMutableRawBufferPointer) -> Received {
        while true {
            let count = isSocket ? Sys.receive(descriptor, buffer) : Sys.read(descriptor, buffer)
            if count > 0 {
                emptyReads = 0
                return .frame(count)
            }
            let code = errno
            if count < 0 && code == EINTR { continue }
            if count < 0 && Sys.wouldBlock(code) { return .nothing }
            // An empty read or an error, over and over, is the other end closed: nothing a guest
            // sends is empty.
            emptyReads += 1
            return emptyReads >= 16 ? .closed : .nothing
        }
    }

    private enum Written { case sent, full, failed }

    private func write(_ frame: UnsafeRawBufferPointer) -> Written {
        while true {
            let count = isSocket ? Sys.send(descriptor, frame) : Sys.write(descriptor, frame)
            if count >= 0 { return .sent }
            let code = errno
            if code == EINTR { continue }
            // ENOBUFS is what macOS answers when the other end's buffer is full.
            return Sys.wouldBlock(code) || code == ENOBUFS ? .full : .failed
        }
    }

    private func hold(_ frame: UnsafeRawBufferPointer) {
        guard heldBytes + frame.count <= Self.heldLimit else {
            lost += 1
            return
        }
        held.append(Array(frame))
        heldBytes += frame.count
    }
}

/// One connection of the guest's and its socket to the proxy.
final class Flow {
    enum Phase {
        /// The proxy's address is being resolved.
        case waiting
        /// The TCP connection to the proxy is being opened.
        case connecting
        /// The proxy is being asked for the destination.
        case handshaking
        /// The tunnel is up.
        case open
        /// No socket any more; kept only while the connection lingers.
        case done
    }

    let key: FlowKey
    let tcp: TCPConnection
    /// The name the guest asked for, or the address it connected to as written.
    let host: String
    var handshake: ProxyHandshake
    var phase = Phase.waiting
    var descriptor: Int32 = -1
    /// When the proxy must have opened the tunnel by.
    var deadline: Double
    /// When this attempt at one of the proxy's addresses is given up for the next.
    var attemptDeadline = Double.infinity
    var attempts = 0
    var addressIndex = 0
    var lastError = "no address"
    var outgoing: [UInt8] = []
    var outgoingSent = 0
    var readEnded = false
    /// The last write to the proxy took no more: wait until it does.
    var wantsWrite = false
    /// Not waited on before this time: the socket reported something that is no use yet.
    var holdUntil = 0.0
    var isDirty = false

    init(key: FlowKey, tcp: TCPConnection, host: String, handshake: ProxyHandshake, deadline: Double) {
        self.key = key
        self.tcp = tcp
        self.host = host
        self.handshake = handshake
        self.deadline = deadline
    }

    var nextDeadline: Double {
        switch phase {
        case .waiting, .handshaking: return deadline
        case .connecting: return min(deadline, attemptDeadline)
        case .open, .done: return tcp.nextDeadline ?? .infinity
        }
    }
}

/// The network of one guest, on its own thread: frames from the guest in, frames to the guest
/// out, and for every connection the guest opens a socket to the proxy. One `poll` waits on all
/// of it; nothing here blocks.
final class NetworkLoop: @unchecked Sendable {
    struct Options {
        var tcp = TCPConnection.Tuning()
        /// How long the proxy has to open a tunnel before the guest's SYN is answered with a reset.
        var connectTimeout = 15.0
        /// How long one of the proxy's addresses is tried while another is left to try.
        var attemptTimeout = 5.0
        /// Connections at once; one more is answered with a reset. Fewer when the process may
        /// not open that many descriptors (`connectionLimit`).
        var maximumConnections = 2048
        /// Descriptors of this process each connection holds: 1, its socket to the proxy — 3 for
        /// a machine without a proxy, whose proxy (`VMNetDirectConnector`) is in this process and
        /// holds two more.
        var descriptorsPerConnection = 1
        var dnsPoolCapacity = 60_000
        var lossToGuest = 0.0
        var lossFromGuest = 0.0
        /// How long a UDP association has to come up; past it, the datagrams that waited for it
        /// are answered "port unreachable".
        var udpSetupTimeout = 10.0
        /// A UDP association on which nothing moved either way for this long is closed (a NAT
        /// keeps a mapping two minutes and more, RFC 4787; WebRTC and QUIC send something every
        /// few seconds while they live).
        var udpIdleTimeout = 120.0
        /// UDP associations at once — each holds two descriptors, its TCP connection to the proxy
        /// and its socket to the relay. Fewer when the process may not open that many (`udpLimit`).
        var maximumUDPAssociations = 128
        /// New associations a second, and at once: a page whose every host is tried over QUIC,
        /// not a flood of connections to the proxy.
        var udpAssociationsPerSecond = 32.0
        var udpAssociationBurst = 64.0
    }

    // Shared with other threads, under `lock`.
    private let lock = NSLock()
    private var published: VMNetCounters
    private var publishedHosts: [String: HostRecord] = [:]
    private var pendingBlocks: [String] = []
    private var finalNames: [VMNetKnownName] = []
    private var stopRequested = false
    private let ended = NSCondition()
    private var hasEnded = false

    private let wake: WakePipe
    private let configuration: VMNetConfiguration
    private let options: Options
    private let log: (@Sendable (String) -> Void)?

    // The loop thread's own.
    private var responder: LinkResponder
    private let channel: FrameChannel
    private let scratch = FrameScratch()
    private let resolver: ProxyResolver?
    private var seenAnswers = 0
    private var flows: [FlowKey: Flow] = [:]
    private var dirty: [Flow] = []
    /// The guest's UDP associations with the proxy, one per address and port it sends from.
    private var associations: [UDPKey: UDPAssociation] = [:]
    /// The proxy refused UDP ASSOCIATE outright (not supported, not allowed): for the rest of the
    /// run UDP is answered "port unreachable", as without a relay.
    private var udpRefusedByProxy = false
    /// Associations that failed one after another, and until when no new one is tried.
    private var udpFailureStreak = 0
    private var udpPausedUntil = -Double.infinity
    private var udpTokens = 0.0
    private var udpTokensRefilled = -Double.infinity
    private let udpLimit: Int
    private var counters: VMNetCounters
    /// What went to and from each host the guest asked for (`VMNetHost`): in memory only.
    private var hosts: [String: HostRecord] = [:]
    private var hostsChanged = false
    private var hostsPublishedAt = -Double.infinity
    private var wireOpen = true
    private var wireHoldUntil = 0.0
    private var nextTimerCheck = Double.infinity
    private var timersRanAt = -Double.infinity
    private var notes: [String: Int] = [:]
    private var notesDue = Double.infinity
    private var notesFlushed = -Double.infinity
    private let streamBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 8)
    private let frameBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 8)

    /// How many connections a network may hold at once: what was asked for, but never more than
    /// half of the descriptors the process may open, nor so many that fewer than 128 are left —
    /// every connection is a socket, and the rest of the app must still be able to open its
    /// files. With macOS's default of 256 descriptors that is 128 connections; the full 2048 need
    /// a limit of 4096 (the app raises it with `setrlimit`). Where each connection holds more
    /// than one descriptor of the process (`descriptorsPerConnection`), that many fewer.
    static func connectionLimit(wanted: Int, descriptorLimit: Int, descriptorsPerConnection: Int = 1) -> Int {
        min(wanted, max(min(descriptorLimit / 2, descriptorLimit - 128) / max(descriptorsPerConnection, 1), 16))
    }

    private let connectionLimit: Int

    /// How many UDP associations a network may hold at once: what was asked for, but no more
    /// than an eighth of its connections (each holds two descriptors), and at least four.
    static func udpLimit(wanted: Int, connectionLimit: Int) -> Int {
        min(wanted, max(connectionLimit / 8, 4))
    }

    /// One host's counts; `seen` is when it was last asked for or carried anything (`Sys.now`).
    struct HostRecord {
        var connections: UInt64 = 0
        var open = 0
        var bytesFromGuest: UInt64 = 0
        var bytesToGuest: UInt64 = 0
        var blocked: UInt64 = 0
        var seen = 0.0
    }

    /// How many hosts are remembered; one more, and the one unseen the longest that has no
    /// connection open is forgotten.
    static let hostLimit = 400
    /// How often the hosts' counts are handed to other threads, at most.
    static let hostInterval = 0.5

    /// How often the reasons connections failed for are written to the log, at most.
    static let noteInterval = 10.0
    /// The proxy's bytes are read when at least this much room is free for them.
    static let readThreshold = 16 * 1024

    init?(configuration: VMNetConfiguration, frameDescriptor: Int32, options: Options, counters: VMNetCounters,
          log: (@Sendable (String) -> Void)?) {
        guard let wake = WakePipe() else { return nil }
        self.wake = wake
        self.configuration = configuration
        self.options = options
        self.log = log
        self.counters = counters
        published = counters
        connectionLimit = Self.connectionLimit(wanted: options.maximumConnections, descriptorLimit: Sys.descriptorLimit,
                                               descriptorsPerConnection: options.descriptorsPerConnection)
        udpLimit = Self.udpLimit(wanted: options.maximumUDPAssociations, connectionLimit: connectionLimit)
        udpTokens = options.udpAssociationBurst
        // UDP is handed to the loop only where the proxy can carry it: SOCKS5. An HTTP CONNECT
        // proxy, or none, keeps "port unreachable".
        var linkConfiguration = configuration
        linkConfiguration.relaysUDP = configuration.relaysUDP && configuration.upstream.carriesUDP
        responder = LinkResponder(configuration: linkConfiguration, dnsPoolCapacity: options.dnsPoolCapacity)
        channel = FrameChannel(descriptor: frameDescriptor)
        channel.lossToGuest = options.lossToGuest
        if let endpoint = configuration.upstream.endpoint {
            resolver = ProxyResolver(host: endpoint.host, port: endpoint.port)
        } else {
            resolver = nil
        }
    }

    deinit {
        streamBuffer.deallocate()
        frameBuffer.deallocate()
    }

    // MARK: - From other threads

    var snapshot: VMNetCounters {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        wake.signal()
    }

    /// What went to and from each host so far, the one seen last first.
    var hostSnapshot: [VMNetHost] {
        lock.lock()
        let records = publishedHosts
        lock.unlock()
        let now = Sys.now
        return records.sorted { $0.value.seen != $1.value.seen ? $0.value.seen > $1.value.seen : $0.key < $1.key }.map { name, record in
            VMNetHost(name: name, connections: record.connections, open: record.open, bytesFromGuest: record.bytesFromGuest,
                      bytesToGuest: record.bytesToGuest, blocked: record.blocked, idle: max(now - record.seen, 0))
        }
    }

    /// Blocks a name and everything under it from now on: its questions are answered "no such
    /// name", its connections refused, and those open are ended.
    func block(_ suffix: String) {
        lock.lock()
        pendingBlocks.append(suffix)
        lock.unlock()
        wake.signal()
    }

    /// Every name the guest was given a fake address for, as the loop left them when it ended.
    var namesAtEnd: [VMNetKnownName] {
        lock.lock()
        defer { lock.unlock() }
        return finalNames
    }

    func waitUntilEnded() {
        ended.lock()
        while !hasEnded { ended.wait() }
        ended.unlock()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    // MARK: - The loop

    func run() {
        say("network started: \(describeUpstream()); \(describeUDP()); blocked host suffixes: \(configuration.blockedHostSuffixes.count); "
            + "connections at once: \(connectionLimit)"
            + (connectionLimit < options.maximumConnections ? " (the process may open only \(Sys.descriptorLimit) descriptors)" : ""))
        let wakeUp: @Sendable () -> Void = { [wake] in wake.signal() }
        resolver?.resolveIfNeeded(now: Sys.now, done: wakeUp)
        var entries: [pollfd] = []
        var polled: [Flow] = []
        var polledUDP: [(association: UDPAssociation, isRelay: Bool)] = []
        while !shouldStop {
            var now = Sys.now
            channel.now = now
            if now >= timerCheckDue { runTimers(now) }
            if now >= notesDue { flushNotes(now) }
            // Whatever the last round of events and the timers touched is dealt with before the
            // loop waits again: a connection's next deadline is known only after this.
            settle(now)
            publish()

            entries.removeAll(keepingCapacity: true)
            polled.removeAll(keepingCapacity: true)
            polledUDP.removeAll(keepingCapacity: true)
            entries.append(pollfd(fd: wake.descriptor, events: Sys.readable, revents: 0))
            let wireWaits = wireOpen && now >= wireHoldUntil
            entries.append(pollfd(fd: wireWaits ? channel.descriptor : -1, events: Sys.readable, revents: 0))
            var wakeAt = min(timerCheckDue, channel.retryAt, notesDue)
            if wireOpen && !wireWaits { wakeAt = min(wakeAt, wireHoldUntil) }
            // Hosts' counts that changed since they were last handed over are handed over when due.
            if hostsChanged { wakeAt = min(wakeAt, hostsPublishedAt + Self.hostInterval) }
            for flow in flows.values where flow.descriptor >= 0 {
                if flow.holdUntil > now {
                    wakeAt = min(wakeAt, flow.holdUntil)
                    continue
                }
                let events = interest(of: flow)
                guard events != 0 else { continue }
                entries.append(pollfd(fd: flow.descriptor, events: events, revents: 0))
                polled.append(flow)
            }
            for association in associations.values {
                if association.control >= 0 {
                    if association.holdUntil > now {
                        wakeAt = min(wakeAt, association.holdUntil)
                    } else {
                        let events = controlInterest(of: association)
                        if events != 0 {
                            entries.append(pollfd(fd: association.control, events: events, revents: 0))
                            polledUDP.append((association, false))
                        }
                    }
                }
                // The relay's datagrams wait in its socket while the guest's wire is full: what does
                // not fit there is lost, as on any congested path, and QUIC slows down.
                if association.relay >= 0 && association.phase == .open && !channel.isCongested {
                    entries.append(pollfd(fd: association.relay, events: Sys.readable, revents: 0))
                    polledUDP.append((association, true))
                }
            }
            let timeout: Int32 = wakeAt == .infinity ? -1 : Int32(min(max((wakeAt - now) * 1000, 0).rounded(.up), 60_000))
            let ready = Sys.wait(&entries, milliseconds: timeout)
            if ready < 0 && errno != EINTR {
                // Nothing a loop can do about a failed poll but not spin on it.
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            now = Sys.now
            channel.now = now
            if entries[0].revents != 0 { wake.drain() }
            if shouldStop { break }
            applyBlocks(now)
            resolverAnswered(now)
            if channel.isCongested && now >= channel.retryAt && channel.retry() {
                // The wire has room again: every connection with something to send may go on.
                for flow in flows.values where flow.phase == .open { markDirty(flow) }
            }
            if ready > 0 {
                if entries[1].revents != 0 { readFrames(entries[1].revents, now) }
                for (index, flow) in polled.enumerated() {
                    let entry = entries[index + 2]
                    if entry.revents != 0 && flow.descriptor == entry.fd { upstreamEvent(flow, entry.revents, now) }
                }
                for (index, item) in polledUDP.enumerated() {
                    let entry = entries[index + 2 + polled.count]
                    guard entry.revents != 0 else { continue }
                    if item.isRelay {
                        if item.association.relay == entry.fd { relayEvent(item.association, entry.revents, now) }
                    } else if item.association.control == entry.fd {
                        controlEvent(item.association, entry.revents, now)
                    }
                }
            }
        }
        tearDown()
    }

    private func tearDown() {
        for flow in flows.values where flow.descriptor >= 0 {
            Sys.close(flow.descriptor)
            flow.descriptor = -1
        }
        flows.removeAll()
        counters.connectionsActive = 0
        closeAllAssociations()
        for name in Array(hosts.keys) { hosts[name]?.open = 0 }
        hostsChanged = true
        hostsPublishedAt = -Double.infinity
        publish()
        let names = responder.knownNames
        lock.lock()
        finalNames = names
        lock.unlock()
        flushNotes(.infinity)
        let lost = channel.lost
        say("network stopped: connections opened \(counters.connectionsOpened), failed \(counters.connectionsFailed); "
            + "bytes from the guest \(counters.bytesFromGuest), to the guest \(counters.bytesToGuest); "
            + "DNS queries \(counters.dnsQueries), blocked \(counters.dnsBlocked); datagrams dropped \(counters.datagramsDropped); "
            + "datagrams relayed \(counters.datagramsRelayed), to the guest \(counters.datagramsToGuest); "
            + "UDP associations opened \(counters.udpAssociationsOpened), failed \(counters.udpAssociationsFailed); "
            + "frames the wire did not take \(lost)")
        wake.close()
        ended.lock()
        hasEnded = true
        ended.broadcast()
        ended.unlock()
    }

    private func publish() {
        var records: [String: HostRecord]?
        if hostsChanged {
            let now = Sys.now
            if now - hostsPublishedAt >= Self.hostInterval {
                hostsChanged = false
                hostsPublishedAt = now
                records = hosts
            }
        }
        lock.lock()
        published = counters
        if let records { publishedHosts = records }
        lock.unlock()
    }

    // MARK: - The hosts

    /// Changes a host's counts, making room for a new one where there is none left.
    private func withHost(_ name: String, _ now: Double, _ change: (inout HostRecord) -> Void) {
        if hosts[name] == nil, hosts.count >= Self.hostLimit,
           let oldest = hosts.filter({ $0.value.open == 0 }).min(by: { $0.value.seen < $1.value.seen })?.key {
            hosts[oldest] = nil
        }
        var record = hosts[name] ?? HostRecord()
        record.seen = now
        change(&record)
        hosts[name] = record
        hostsChanged = true
    }

    /// The names other threads asked to have blocked: from now on, and what is open to them ends.
    private func applyBlocks(_ now: Double) {
        lock.lock()
        let wanted = pendingBlocks
        pendingBlocks.removeAll()
        lock.unlock()
        guard !wanted.isEmpty else { return }
        for suffix in wanted { responder.block(suffix) }
        for flow in flows.values where flow.tcp.state != .closed && responder.isBlocked(flow.host) {
            flow.tcp.upstreamBroke(now: now)
            markDirty(flow)
        }
        // What a blocked name answers over UDP is not shown any more; what the guest sends it is refused.
        for association in associations.values {
            association.forgetDestinations { responder.isBlocked($0) }
        }
    }

    private func interest(of flow: Flow) -> Int16 {
        switch flow.phase {
        case .waiting, .done:
            return 0
        case .connecting:
            return Sys.writable
        case .handshaking:
            return flow.outgoingSent < flow.outgoing.count ? Sys.readable | Sys.writable : Sys.readable
        case .open:
            var events: Int16 = 0
            if wantsRead(flow) { events |= Sys.readable }
            if flow.wantsWrite && flow.tcp.upstreamBacklog > 0 { events |= Sys.writable }
            return events
        }
    }

    private func wantsRead(_ flow: Flow) -> Bool {
        !flow.readEnded && flow.tcp.upstreamRoom >= min(Self.readThreshold, options.tcp.sendBufferLimit / 4)
    }

    private func markDirty(_ flow: Flow) {
        guard !flow.isDirty else { return }
        flow.isDirty = true
        dirty.append(flow)
    }

    private func noteDeadline(_ deadline: Double) {
        if deadline < nextTimerCheck { nextTimerCheck = deadline }
    }

    /// When the timers are looked at next: at the earliest deadline, but not within two
    /// milliseconds of the last look — a deadline that stays in the past must not make the loop spin.
    private var timerCheckDue: Double {
        max(nextTimerCheck, timersRanAt + 0.002)
    }

    // MARK: - Frames from the guest

    private func readFrames(_ revents: Int16, _ now: Double) {
        var count = 0
        while count < 256 {
            switch channel.receive(into: frameBuffer) {
            case .closed:
                wireClosed(now)
                return
            case .nothing:
                // Woken for something that is not a frame (an error state of the descriptor):
                // look again a little later instead of at once.
                if count == 0 && revents & Sys.readable == 0 { wireHoldUntil = now + 0.05 }
                return
            case .frame(let length):
                count += 1
                if options.lossFromGuest > 0, Double.random(in: 0..<1) < options.lossFromGuest { continue }
                let bytes = UnsafeRawBufferPointer(rebasing: frameBuffer[0..<length])
                let verdict = responder.handle(bytes, now: now, counters: &counters)
                if let name = responder.takeBlockedName() { withHost(name, now) { $0.blocked += 1 } }
                switch verdict {
                case .ignore:
                    break
                case .reply(let frame):
                    frame.withUnsafeBytes { channel.send($0) }
                case .tcp(let source, let packet, let segment):
                    handleSegment(segment, in: packet, from: source, now)
                case .udp(let source, let packet, let datagram):
                    handleDatagram(datagram, in: packet, from: source, now)
                }
            }
        }
    }

    /// The other end of the wire is gone (the VM stopped): nothing is left to carry.
    private func wireClosed(_ now: Double) {
        guard wireOpen else { return }
        wireOpen = false
        say("the guest's wire closed; connections dropped: \(flows.count)")
        for flow in Array(flows.values) {
            if flow.descriptor >= 0 {
                Sys.close(flow.descriptor)
                flow.descriptor = -1
            }
            if flow.phase == .open {
                counters.connectionsActive -= 1
                hosts[flow.host]?.open -= 1
                hostsChanged = true
            }
        }
        flows.removeAll()
        dirty.removeAll()
        closeAllAssociations()
    }

    private func handleSegment(_ segment: TCPSegment, in packet: IPv4Packet, from source: VMNetMAC, _ now: Double) {
        let key = FlowKey(guestAddress: packet.source.value, guestPort: segment.sourcePort,
                          remoteAddress: packet.destination.value, remotePort: segment.destinationPort)
        let isOpening = segment.flags.contains(.syn) && !segment.flags.contains(.ack) && !segment.flags.contains(.rst)
            && !segment.flags.contains(.fin)
        if let flow = flows[key] {
            if flow.tcp.state == .closed && isOpening {
                // The guest uses the same port again while the old connection lingers: a new one.
                putAway(flow, now)
                flows[key] = nil
            } else {
                flow.tcp.receive(segment, now: now)
                markDirty(flow)
                return
            }
        }
        guard isOpening else {
            // No such connection (it ended, or never was): say so, unless that is what this says.
            if !segment.flags.contains(.rst) { refuse(segment, in: packet, from: source) }
            return
        }
        let decision = DestinationPolicy.decide(address: packet.destination, port: segment.destinationPort,
                                                gateway: configuration.gatewayAddress, prefixLength: configuration.prefixLength) { address in
            responder.name(forFakeAddress: address)
        }
        let target: ProxyTarget
        switch decision {
        case .refuse(let refusal):
            note("refused, \(refusal.rawValue)", now)
            refuse(segment, in: packet, from: source)
            return
        case .connect(let chosen):
            target = chosen
        }
        if case .name(let name, _) = target, responder.isBlocked(name) {
            // Blocked since the guest was given an address for it: the address leads nowhere now.
            withHost(name, now) { $0.blocked += 1 }
            note("refused, a blocked name", now)
            refuse(segment, in: packet, from: source)
            return
        }
        guard let handshake = configuration.upstream.handshake(for: target) else {
            // No proxy: nothing leaves.
            counters.connectionsFailed += 1
            note("refused, the profile has no usable proxy", now)
            refuse(segment, in: packet, from: source)
            return
        }
        if flows.count >= connectionLimit, !dropLingeringFlow(now) {
            note("refused, too many connections at once", now)
            refuse(segment, in: packet, from: source)
            return
        }
        let tcp = TCPConnection(key: key, guestMAC: source, gatewayMAC: configuration.gatewayMAC, mtu: configuration.effectiveMTU,
                                syn: segment, now: now, tuning: options.tcp, scratch: scratch, sink: channel)
        let flow = Flow(key: key, tcp: tcp, host: target.hostText, handshake: handshake, deadline: now + options.connectTimeout)
        withHost(flow.host, now) { $0.connections += 1 }
        flows[key] = flow
        startConnecting(flow, now)
    }

    private func refuse(_ segment: TCPSegment, in packet: IPv4Packet, from source: VMNetMAC) {
        channel.send(TCPConnection.resetFrame(answering: segment, from: packet.destination, to: packet.source,
                                              guestMAC: source, gatewayMAC: configuration.gatewayMAC, scratch: scratch))
    }

    /// Makes room in a full table by forgetting a connection that has ended and only lingers.
    private func dropLingeringFlow(_ now: Double) -> Bool {
        guard let flow = flows.values.first(where: { $0.tcp.state == .closed }) else { return false }
        putAway(flow, now)
        flows[flow.key] = nil
        return true
    }

    // MARK: - Opening the tunnel

    private func startConnecting(_ flow: Flow, _ now: Double) {
        guard let resolver else { return }
        noteDeadline(flow.deadline)
        if resolver.snapshot.addresses.isEmpty {
            resolver.resolveIfNeeded(now: now, done: { [wake] in wake.signal() })
            // Still none and nobody looking: the proxy's name does not resolve.
            let snapshot = resolver.snapshot
            if snapshot.addresses.isEmpty {
                if snapshot.isResolving {
                    flow.phase = .waiting
                } else {
                    fail(flow, "the proxy's address was not found", proxyUnreachable: false, trouble: .unreachable, now)
                }
                return
            }
        }
        connectNext(flow, now)
    }

    /// The loop was woken: if the resolver has a new answer, the connections waiting for it go on.
    private func resolverAnswered(_ now: Double) {
        guard let resolver else { return }
        let snapshot = resolver.snapshot
        guard snapshot.answerCount != seenAnswers else { return }
        seenAnswers = snapshot.answerCount
        if snapshot.addresses.isEmpty {
            say("the proxy's address was not found (\(snapshot.failure ?? "no address"))")
        } else {
            say("the proxy's address is known (addresses: \(snapshot.addresses.count))")
        }
        for flow in Array(flows.values) where flow.phase == .waiting {
            if snapshot.addresses.isEmpty {
                fail(flow, "the proxy's address was not found", proxyUnreachable: false, trouble: .unreachable, now)
            } else {
                connectNext(flow, now)
            }
        }
        for association in Array(associations.values) where association.phase == .waiting {
            if snapshot.addresses.isEmpty {
                failAssociation(association, "the proxy's address was not found", proxyUnreachable: false, now)
            } else {
                connectAssociation(association, now)
            }
        }
    }

    /// Tries the proxy's next address: the one that worked last first, then the others in turn.
    private func connectNext(_ flow: Flow, _ now: Double) {
        guard let resolver else { return }
        let snapshot = resolver.snapshot
        let count = snapshot.addresses.count
        while flow.attempts < count {
            let index = (snapshot.preferredIndex + flow.attempts) % count
            flow.attempts += 1
            let address = snapshot.addresses[index]
            let descriptor = Sys.streamSocket(family: address.family)
            guard descriptor >= 0 else {
                flow.lastError = Sys.describe(errno)
                continue
            }
            let status = Sys.connect(descriptor, to: address)
            flow.addressIndex = index
            if status == 0 {
                flow.descriptor = descriptor
                connected(flow, now)
                return
            }
            if status == EINPROGRESS || status == EINTR {
                flow.descriptor = descriptor
                flow.phase = .connecting
                flow.attemptDeadline = flow.attempts < count ? min(flow.deadline, now + options.attemptTimeout) : flow.deadline
                noteDeadline(flow.attemptDeadline)
                return
            }
            flow.lastError = Sys.describe(status)
            Sys.close(descriptor)
        }
        fail(flow, "the proxy was not reached (\(flow.lastError))", proxyUnreachable: true, trouble: .unreachable, now)
    }

    private func connected(_ flow: Flow, _ now: Double) {
        resolver?.connectionSucceeded(index: flow.addressIndex)
        flow.phase = .handshaking
        flow.attemptDeadline = .infinity
        apply(flow.handshake.begin(), to: flow, now)
    }

    private func apply(_ step: ProxyHandshakeStep, to flow: Flow, _ now: Double) {
        switch step {
        case .needMore:
            break
        case .send(let bytes):
            flow.outgoing += bytes
            writeHandshake(flow, now)
        case .established(let leftover):
            flow.phase = .open
            flow.outgoing = []
            counters.connectionsOpened += 1
            counters.connectionsActive += 1
            // The proxy carries connections again.
            counters.proxyFailuresInARow = 0
            counters.proxyTrouble = nil
            withHost(flow.host, now) { $0.open += 1 }
            flow.tcp.tunnelEstablished(now: now)
            if !leftover.isEmpty { leftover.withUnsafeBytes { flow.tcp.upstreamData($0, now: now) } }
            markDirty(flow)
        case .failed(let failure):
            fail(flow, failure.reason, proxyUnreachable: false, trouble: failure.proxyTrouble, now)
        }
    }

    /// Sends what is left of the handshake's bytes. True when something was sent, or the
    /// connection failed and was dealt with; false when the socket took nothing.
    @discardableResult
    private func writeHandshake(_ flow: Flow, _ now: Double) -> Bool {
        var progressed = false
        while flow.outgoingSent < flow.outgoing.count {
            let sent = flow.outgoing.withUnsafeBytes { bytes -> (Int, Int32) in
                let count = Sys.send(flow.descriptor, UnsafeRawBufferPointer(rebasing: bytes[flow.outgoingSent...]))
                return (count, errno)
            }
            if sent.0 > 0 {
                flow.outgoingSent += sent.0
                progressed = true
            } else if sent.1 == EINTR {
                continue
            } else if Sys.wouldBlock(sent.1) {
                return progressed
            } else {
                fail(flow, "the proxy closed the connection (\(Sys.describe(sent.1)))", proxyUnreachable: false, trouble: .unreachable, now)
                return true
            }
        }
        flow.outgoing = []
        flow.outgoingSent = 0
        return progressed
    }

    /// Reads the proxy's next bytes of the handshake. False when there was nothing to read.
    private func readHandshake(_ flow: Flow, _ now: Double) -> Bool {
        let count = Sys.receive(flow.descriptor, UnsafeMutableRawBufferPointer(rebasing: streamBuffer[0..<4096]))
        if count > 0 {
            apply(flow.handshake.receive(Array(UnsafeRawBufferPointer(rebasing: streamBuffer[0..<count]))), to: flow, now)
            return true
        }
        if count == 0 {
            fail(flow, "the proxy closed the connection", proxyUnreachable: false, trouble: .unreachable, now)
            return true
        }
        let code = errno
        if code == EINTR || Sys.wouldBlock(code) { return false }
        fail(flow, "the proxy closed the connection (\(Sys.describe(code)))", proxyUnreachable: false, trouble: .unreachable, now)
        return true
    }

    /// The proxy gave no tunnel: the guest's SYN is answered with a reset and the connection forgotten.
    ///
    /// `trouble`: the failure is the proxy's own (not reached, not answering, the sign-in refused,
    /// an answer not understood) — counted one after another until a tunnel comes up
    /// (`VMNetCounters.proxyFailuresInARow`), so that a proxy that goes down while the machine runs
    /// is said, not left to be guessed. Nil: the proxy answered and said it cannot reach the site
    /// (a site that is down, a tracker that is gone) — that says nothing of the proxy.
    private func fail(_ flow: Flow, _ reason: String, proxyUnreachable: Bool, trouble: VMNetProxyTrouble?, _ now: Double) {
        if flow.descriptor >= 0 {
            Sys.close(flow.descriptor)
            flow.descriptor = -1
        }
        flow.phase = .done
        counters.connectionsFailed += 1
        if let trouble {
            counters.proxyFailuresInARow += 1
            counters.proxyTrouble = trouble
        }
        note(reason, now)
        if proxyUnreachable, let resolver {
            resolver.connectionFailed()
            resolver.resolveIfNeeded(now: now, done: { [wake] in wake.signal() })
        }
        flow.tcp.tunnelFailed(now: now)
        if flows[flow.key] === flow { flows[flow.key] = nil }
    }

    // MARK: - The tunnel

    private func upstreamEvent(_ flow: Flow, _ revents: Int16, _ now: Double) {
        switch flow.phase {
        case .waiting, .done:
            break
        case .connecting:
            let error = Sys.pendingError(flow.descriptor)
            if error == 0 && revents & Sys.writable != 0 {
                connected(flow, now)
            } else {
                flow.lastError = Sys.describe(error == 0 ? ECONNREFUSED : error)
                Sys.close(flow.descriptor)
                flow.descriptor = -1
                connectNext(flow, now)
            }
        case .handshaking:
            var progressed = false
            if revents & Sys.writable != 0 { progressed = writeHandshake(flow, now) }
            if flow.phase == .handshaking && revents & (Sys.readable | Sys.hungUp | Sys.failed) != 0 {
                progressed = readHandshake(flow, now) || progressed
            }
            if !progressed && flow.phase == .handshaking { holdOff(flow, revents, now) }
        case .open:
            var progressed = false
            if revents & Sys.writable != 0 {
                flow.wantsWrite = false
                progressed = writeUpstream(flow, now)
            }
            if flow.tcp.state != .closed && revents & (Sys.readable | Sys.hungUp | Sys.failed) != 0 {
                if wantsRead(flow) {
                    progressed = readUpstream(flow, now) || progressed
                } else if revents & Sys.failed != 0, Sys.pendingError(flow.descriptor) != 0 {
                    flow.tcp.upstreamBroke(now: now)
                    progressed = true
                }
            }
            if !progressed { holdOff(flow, revents, now) }
            markDirty(flow)
        }
    }

    /// A socket that reports "hung up" or an error state, and then has nothing to read and takes
    /// nothing, would wake the loop again at once, turn after turn (the report does not go away
    /// by being looked at). Such a socket is left out of the wait for a moment.
    private func holdOff(_ flow: Flow, _ revents: Int16, _ now: Double) {
        if revents & (Sys.hungUp | Sys.failed) != 0 { flow.holdUntil = now + 0.02 }
    }

    /// Reads what the proxy sent, as far as the connection has room for it. False when there
    /// was nothing to read (and no end, and no error).
    private func readUpstream(_ flow: Flow, _ now: Double) -> Bool {
        let tcp = flow.tcp
        var progressed = false
        var rounds = 0
        while tcp.state != .closed && !flow.readEnded && rounds < 16 {
            let wanted = min(tcp.upstreamRoom, streamBuffer.count)
            guard wanted > 0 else { break }
            let count = Sys.receive(flow.descriptor, UnsafeMutableRawBufferPointer(rebasing: streamBuffer[0..<wanted]))
            if count > 0 {
                progressed = true
                tcp.upstreamData(UnsafeRawBufferPointer(rebasing: streamBuffer[0..<count]), now: now)
                if count < wanted { break }
                rounds += 1
            } else if count == 0 {
                progressed = true
                flow.readEnded = true
                tcp.upstreamFinished(now: now)
            } else {
                let code = errno
                if code == EINTR { continue }
                if !Sys.wouldBlock(code) {
                    progressed = true
                    tcp.upstreamBroke(now: now)
                }
                break
            }
        }
        return progressed
    }

    /// Writes what the guest sent to the proxy, as far as the socket takes it. False when it
    /// took nothing (and there was no error).
    @discardableResult
    private func writeUpstream(_ flow: Flow, _ now: Double) -> Bool {
        let tcp = flow.tcp
        var progressed = false
        while tcp.state != .closed && tcp.upstreamBacklog > 0 {
            let sent = tcp.withUpstreamBacklog { bytes -> (Int, Int32) in
                let count = Sys.send(flow.descriptor, bytes)
                return (count, errno)
            }
            if sent.0 > 0 {
                progressed = true
                counters.bytesFromGuest += UInt64(sent.0)
                withHost(flow.host, now) { $0.bytesFromGuest += UInt64(sent.0) }
                tcp.upstreamConsumed(sent.0, now: now)
            } else if sent.1 == EINTR {
                continue
            } else if Sys.wouldBlock(sent.1) {
                flow.wantsWrite = true
                break
            } else {
                progressed = true
                tcp.upstreamBroke(now: now)
                break
            }
        }
        return progressed
    }

    /// After a round of events: for every connection something happened to, what the guest sent
    /// goes to the proxy, what is owed to the guest is sent, and an ended connection is put away.
    private func settle(_ now: Double) {
        var index = 0
        while index < dirty.count {
            let flow = dirty[index]
            index += 1
            flow.isDirty = false
            let tcp = flow.tcp
            if flow.phase == .open && tcp.state != .closed {
                if tcp.upstreamBacklog > 0 && !flow.wantsWrite { writeUpstream(flow, now) }
                if tcp.shouldShutdownUpstream {
                    Sys.shutdownWrite(flow.descriptor)
                    tcp.noteUpstreamShutdown()
                }
                tcp.flush(now: now)
            }
            let delivered = tcp.takeDeliveredBytes()
            counters.bytesToGuest += delivered
            if delivered > 0 { withHost(flow.host, now) { $0.bytesToGuest += delivered } }
            if tcp.state == .closed {
                putAway(flow, now)
            } else {
                noteDeadline(flow.nextDeadline)
            }
        }
        dirty.removeAll(keepingCapacity: true)
    }

    private func putAway(_ flow: Flow, _ now: Double) {
        if flow.descriptor >= 0 {
            Sys.close(flow.descriptor)
            flow.descriptor = -1
        }
        if flow.phase == .open {
            counters.connectionsActive -= 1
            hosts[flow.host]?.open -= 1
            hostsChanged = true
        }
        guard flow.phase != .done else { return }
        flow.phase = .done
        switch flow.tcp.ending {
        case .upstreamBroke: note("ended, the tunnel broke", now)
        case .timedOut: note("ended, the guest stopped answering or nothing moved for too long", now)
        default: break
        }
        if let until = flow.tcp.lingerUntil {
            noteDeadline(until)
        } else if flows[flow.key] === flow {
            flows[flow.key] = nil
        }
    }

    // MARK: - Timers

    private func runTimers(_ now: Double) {
        var due: [Flow] = []
        var next = Double.infinity
        for flow in flows.values {
            let deadline = flow.nextDeadline
            if deadline <= now { due.append(flow) } else if deadline < next { next = deadline }
        }
        var dueAssociations: [UDPAssociation] = []
        for association in associations.values {
            let deadline = association.phase == .open ? association.lastActivity + options.udpIdleTimeout : association.nextDeadline
            if deadline <= now { dueAssociations.append(association) } else if deadline < next { next = deadline }
        }
        nextTimerCheck = next
        timersRanAt = now
        for association in dueAssociations { associationTimerFired(association, now) }
        for flow in due {
            switch flow.phase {
            case .waiting:
                fail(flow, "the proxy's address was not found in time", proxyUnreachable: false, trouble: .unreachable, now)
            case .handshaking:
                fail(flow, "the proxy did not answer in time", proxyUnreachable: false, trouble: .unreachable, now)
            case .connecting:
                Sys.close(flow.descriptor)
                flow.descriptor = -1
                flow.lastError = Sys.describe(ETIMEDOUT)
                if now >= flow.deadline {
                    fail(flow, "the proxy was not reached (\(flow.lastError))", proxyUnreachable: true, trouble: .unreachable, now)
                } else {
                    connectNext(flow, now)
                }
            case .open:
                flow.tcp.timerFired(now: now)
                markDirty(flow)
            case .done:
                // Its linger is over.
                if flows[flow.key] === flow { flows[flow.key] = nil }
            }
        }
    }

    // MARK: - The log

    private func say(_ line: String) {
        log?(line)
    }

    /// Counts a reason; the counts are written out together, at most every `noteInterval`.
    private func note(_ reason: String, _ now: Double) {
        notes[reason, default: 0] += 1
        if notesDue == .infinity { notesDue = max(now, notesFlushed + Self.noteInterval) }
    }

    private func flushNotes(_ now: Double) {
        notesDue = .infinity
        guard !notes.isEmpty else { return }
        notesFlushed = now
        let parts = notes.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }
        notes.removeAll()
        say("connections: " + parts.joined(separator: "; "))
    }

    /// The kind of proxy and whether it asks for a sign-in — never its host, user name or password.
    private func describeUpstream() -> String {
        switch configuration.upstream {
        case .socks5(_, _, let username, _): return "SOCKS5 proxy" + (username?.isEmpty == false ? " with a sign-in" : "")
        case .httpConnect(_, _, let username, _): return "HTTP CONNECT proxy" + (username?.isEmpty == false ? " with a sign-in" : "")
        case .none: return "no proxy (every connection is refused)"
        }
    }

    /// Whether UDP goes anywhere in this run.
    private func describeUDP() -> String {
        guard configuration.relaysUDP else { return "UDP: not carried (answered unreachable)" }
        guard configuration.upstream.carriesUDP else { return "UDP: not carried, the proxy is not SOCKS5" }
        return "UDP: through the proxy's relay (at most \(udpLimit) associations)"
    }
}

// MARK: - UDP through the proxy's relay

/// The guest's UDP, where the run carries it (`VMNetConfiguration.relaysUDP`, a SOCKS5 proxy): one
/// association (RFC 1928 §7) per address and port the guest sends from, made as a connection is —
/// the proxy's address, a TCP connection to it, the greeting and sign-in, then UDP ASSOCIATE — and
/// a socket to the relay the proxy named, connected to it, so that the system drops a datagram
/// from anywhere else. Where a datagram may go is decided as for a connection
/// (`DestinationPolicy`); a fake address goes to the proxy as its name.
extension NetworkLoop {
    private func handleDatagram(_ datagram: UDPDatagram, in packet: IPv4Packet, from source: VMNetMAC, _ now: Double) {
        guard !udpRefusedByProxy else {
            refuseDatagram(packet, from: source, now)
            return
        }
        let decision = DestinationPolicy.decide(address: packet.destination, port: datagram.destinationPort,
                                                gateway: configuration.gatewayAddress, prefixLength: configuration.prefixLength) { address in
            responder.name(forFakeAddress: address)
        }
        let target: ProxyTarget
        switch decision {
        case .refuse(let refusal):
            note("UDP refused, \(refusal.rawValue)", now)
            refuseDatagram(packet, from: source, now)
            return
        case .connect(let chosen):
            target = chosen
        }
        if case .name(let name, _) = target, responder.isBlocked(name) {
            withHost(name, now) { $0.blocked += 1 }
            note("UDP refused, a blocked name", now)
            refuseDatagram(packet, from: source, now)
            return
        }
        guard let wrapped = SOCKSDatagram.wrap(datagram.payload, to: target) else {
            note("UDP refused, the host name is too long for SOCKS5", now)
            refuseDatagram(packet, from: source, now)
            return
        }
        let key = UDPKey(guestAddress: packet.source.value, guestPort: datagram.sourcePort)
        let association: UDPAssociation
        if let known = associations[key] {
            association = known
        } else {
            guard let made = openAssociation(key, guestMAC: source, now) else {
                refuseDatagram(packet, from: source, now)
                return
            }
            association = made
        }
        let host = target.hostText
        if association.noteDestination(packet.destination, port: datagram.destinationPort, target: target, host: host, now: now,
                                       payload: datagram.payload) {
            withHost(host, now) { $0.connections += 1 }
        }
        association.lastActivity = now
        if association.phase == .open {
            sendToRelay(association, wrapped, payloadLength: datagram.payload.count, host: host, now)
            return
        }
        let waiting = UDPAssociation.Waiting(datagram: wrapped, payloadLength: datagram.payload.count, host: host,
                                             quote: Array(packet.header) + Array(packet.payload.prefix(8)), destination: packet.destination)
        if !association.hold(waiting) {
            counters.datagramsDropped += 1
            note("UDP dropped, too many datagrams waiting for an association", now)
        }
    }

    /// "Port unreachable" for a datagram that goes nowhere (rate-limited, as every such answer).
    private func refuseDatagram(_ packet: IPv4Packet, from source: VMNetMAC, _ now: Double) {
        counters.datagramsDropped += 1
        if let reply = responder.portUnreachable(to: source, packet: packet, now: now) {
            reply.withUnsafeBytes { channel.send($0) }
        }
    }

    /// A new association for the guest's `key`, on its way; nil when none may be made now.
    private func openAssociation(_ key: UDPKey, guestMAC: VMNetMAC, _ now: Double) -> UDPAssociation? {
        guard resolver != nil, case .socks5(_, _, let username, let password) = configuration.upstream else { return nil }
        if now < udpPausedUntil {
            note("UDP refused, the proxy's relay failed a moment ago", now)
            return nil
        }
        if associations.count >= udpLimit, !dropIdleAssociation(now) {
            note("UDP refused, too many associations at once", now)
            return nil
        }
        guard takeUDPToken(now) else {
            note("UDP refused, too many new associations at once", now)
            return nil
        }
        let association = UDPAssociation(key: key, guestMAC: guestMAC, credentials: ProxyCredentials(username: username, password: password),
                                         now: now, setupTimeout: options.udpSetupTimeout)
        associations[key] = association
        startAssociation(association, now)
        return association.phase == .done ? nil : association
    }

    /// Makes room in a full table by closing the association that has been quiet the longest,
    /// if it has been quiet for half a minute: one that is in use is not taken from the guest.
    private func dropIdleAssociation(_ now: Double) -> Bool {
        guard let quietest = associations.values.min(by: { $0.lastActivity < $1.lastActivity }),
              now - quietest.lastActivity >= 30 else { return false }
        endAssociation(quietest, "UDP association closed to make room", now)
        return true
    }

    private func takeUDPToken(_ now: Double) -> Bool {
        if udpTokensRefilled.isFinite {
            udpTokens = min(options.udpAssociationBurst, udpTokens + max(now - udpTokensRefilled, 0) * options.udpAssociationsPerSecond)
        }
        udpTokensRefilled = now
        guard udpTokens >= 1 else { return false }
        udpTokens -= 1
        return true
    }

    // MARK: Setting an association up

    private func startAssociation(_ association: UDPAssociation, _ now: Double) {
        guard let resolver else { return failAssociation(association, "the profile has no usable proxy", proxyUnreachable: false, now) }
        noteDeadline(association.deadline)
        if resolver.snapshot.addresses.isEmpty {
            resolver.resolveIfNeeded(now: now, done: { [wake] in wake.signal() })
            let snapshot = resolver.snapshot
            if snapshot.addresses.isEmpty {
                if snapshot.isResolving {
                    association.phase = .waiting
                } else {
                    failAssociation(association, "the proxy's address was not found", proxyUnreachable: false, now)
                }
                return
            }
        }
        connectAssociation(association, now)
    }

    /// Tries the proxy's next address, as a connection does: the one that worked last first.
    private func connectAssociation(_ association: UDPAssociation, _ now: Double) {
        guard let resolver else { return }
        let snapshot = resolver.snapshot
        let count = snapshot.addresses.count
        while association.attempts < count {
            let index = (snapshot.preferredIndex + association.attempts) % count
            association.attempts += 1
            let address = snapshot.addresses[index]
            let descriptor = Sys.streamSocket(family: address.family)
            guard descriptor >= 0 else {
                association.lastError = Sys.describe(errno)
                continue
            }
            let status = Sys.connect(descriptor, to: address)
            association.addressIndex = index
            if status == 0 {
                association.control = descriptor
                associationConnected(association, now)
                return
            }
            if status == EINPROGRESS || status == EINTR {
                association.control = descriptor
                association.phase = .connecting
                association.attemptDeadline = association.attempts < count
                    ? min(association.deadline, now + options.attemptTimeout) : association.deadline
                noteDeadline(association.attemptDeadline)
                return
            }
            association.lastError = Sys.describe(status)
            Sys.close(descriptor)
        }
        failAssociation(association, "the proxy was not reached (\(association.lastError))", proxyUnreachable: true, now)
    }

    private func associationConnected(_ association: UDPAssociation, _ now: Double) {
        resolver?.connectionSucceeded(index: association.addressIndex)
        association.phase = .handshaking
        association.attemptDeadline = .infinity
        applyAssociation(association.handshake.begin(), to: association, now)
    }

    private func applyAssociation(_ step: ProxyHandshakeStep, to association: UDPAssociation, _ now: Double) {
        switch step {
        case .needMore:
            break
        case .send(let bytes):
            association.outgoing += bytes
            writeAssociationHandshake(association, now)
        case .established:
            openRelay(association, now)
        case .failed(let failure):
            if case .refused(let code) = failure, code == 7 || code == 2 {
                // "Command not supported", "not allowed by the rules": this proxy carries no UDP.
                // Not asked again in this run: what waits, and what comes, is answered unreachable.
                refuseUDPForTheRun(code, now)
            }
            failAssociation(association, "UDP " + failure.reason, proxyUnreachable: false, now)
        }
    }

    private func refuseUDPForTheRun(_ code: Int, _ now: Double) {
        guard !udpRefusedByProxy else { return }
        udpRefusedByProxy = true
        say("the proxy does not carry UDP (UDP ASSOCIATE refused, code \(code)): UDP is answered unreachable for the rest of the run")
        for other in Array(associations.values) where other.phase != .open {
            failAssociation(other, "UDP the proxy refused UDP", proxyUnreachable: false, now)
        }
    }

    /// The proxy has said where its relay is: a socket to it, connected, and what waited goes.
    private func openRelay(_ association: UDPAssociation, _ now: Double) {
        guard let bound = association.handshake.bound, let proxy = Sys.peer(of: association.control),
              let endpoint = UDPRelayRules.relayEndpoint(bound: bound.address, port: bound.port, proxy: proxy) else {
            failAssociation(association, "UDP the proxy named a relay that is not an address", proxyUnreachable: false, now)
            return
        }
        let descriptor = Sys.datagramSocket(family: endpoint.family)
        guard descriptor >= 0 else {
            failAssociation(association, "UDP no socket for the relay (\(Sys.describe(errno)))", proxyUnreachable: false, now)
            return
        }
        let status = Sys.connect(descriptor, to: endpoint)
        guard status == 0 else {
            Sys.close(descriptor)
            failAssociation(association, "UDP the relay was not reached (\(Sys.describe(status)))", proxyUnreachable: false, now)
            return
        }
        association.relay = descriptor
        association.phase = .open
        association.outgoing = []
        association.lastActivity = now
        counters.udpAssociationsOpened += 1
        counters.udpAssociationsActive += 1
        udpFailureStreak = 0
        noteDeadline(now + options.udpIdleTimeout)
        for waiting in association.takeWaiting() {
            sendToRelay(association, waiting.datagram, payloadLength: waiting.payloadLength, host: waiting.host, now)
            guard association.phase == .open else { break }
        }
    }

    @discardableResult
    private func writeAssociationHandshake(_ association: UDPAssociation, _ now: Double) -> Bool {
        var progressed = false
        while association.outgoingSent < association.outgoing.count {
            let sent = association.outgoing.withUnsafeBytes { bytes -> (Int, Int32) in
                let count = Sys.send(association.control, UnsafeRawBufferPointer(rebasing: bytes[association.outgoingSent...]))
                return (count, errno)
            }
            if sent.0 > 0 {
                association.outgoingSent += sent.0
                progressed = true
            } else if sent.1 == EINTR {
                continue
            } else if Sys.wouldBlock(sent.1) {
                return progressed
            } else {
                failAssociation(association, "UDP the proxy closed the connection (\(Sys.describe(sent.1)))", proxyUnreachable: false, now)
                return true
            }
        }
        association.outgoing = []
        association.outgoingSent = 0
        return progressed
    }

    private func readAssociationHandshake(_ association: UDPAssociation, _ now: Double) -> Bool {
        let count = Sys.receive(association.control, UnsafeMutableRawBufferPointer(rebasing: streamBuffer[0..<4096]))
        if count > 0 {
            applyAssociation(association.handshake.receive(Array(UnsafeRawBufferPointer(rebasing: streamBuffer[0..<count]))),
                             to: association, now)
            return true
        }
        if count == 0 {
            failAssociation(association, "UDP the proxy closed the connection", proxyUnreachable: false, now)
            return true
        }
        let code = errno
        if code == EINTR || Sys.wouldBlock(code) { return false }
        failAssociation(association, "UDP the proxy closed the connection (\(Sys.describe(code)))", proxyUnreachable: false, now)
        return true
    }

    // MARK: Events

    private func controlInterest(of association: UDPAssociation) -> Int16 {
        switch association.phase {
        case .waiting, .done: return 0
        case .connecting: return Sys.writable
        case .handshaking:
            return association.outgoingSent < association.outgoing.count ? Sys.readable | Sys.writable : Sys.readable
        // Nothing more is said on it; it is watched for its end, which ends the association.
        case .open: return Sys.readable
        }
    }

    private func controlEvent(_ association: UDPAssociation, _ revents: Int16, _ now: Double) {
        switch association.phase {
        case .waiting, .done:
            break
        case .connecting:
            let error = Sys.pendingError(association.control)
            if error == 0 && revents & Sys.writable != 0 {
                associationConnected(association, now)
            } else {
                association.lastError = Sys.describe(error == 0 ? ECONNREFUSED : error)
                Sys.close(association.control)
                association.control = -1
                connectAssociation(association, now)
            }
        case .handshaking:
            var progressed = false
            if revents & Sys.writable != 0 { progressed = writeAssociationHandshake(association, now) }
            if association.phase == .handshaking && revents & (Sys.readable | Sys.hungUp | Sys.failed) != 0 {
                progressed = readAssociationHandshake(association, now) || progressed
            }
            if !progressed && association.phase == .handshaking && revents & (Sys.hungUp | Sys.failed) != 0 {
                association.holdUntil = now + 0.02
            }
        case .open:
            // The association lives as long as this connection (RFC 1928 §7). Whatever else the
            // proxy says on it is read and let go.
            var rounds = 0
            while rounds < 4 {
                rounds += 1
                let count = Sys.receive(association.control, UnsafeMutableRawBufferPointer(rebasing: streamBuffer[0..<4096]))
                if count > 0 { continue }
                if count == 0 {
                    endAssociation(association, "UDP association ended, the proxy closed it", now)
                    return
                }
                let code = errno
                if code == EINTR { continue }
                if !Sys.wouldBlock(code) {
                    endAssociation(association, "UDP association ended, its connection broke", now)
                    return
                }
                break
            }
            if revents & (Sys.hungUp | Sys.failed) != 0 && Sys.pendingError(association.control) != 0 {
                endAssociation(association, "UDP association ended, its connection broke", now)
            }
        }
    }

    /// Datagrams from the relay: each one shown to the guest "from" the destination it answers.
    private func relayEvent(_ association: UDPAssociation, _ revents: Int16, _ now: Double) {
        var rounds = 0
        while rounds < 64 && association.phase == .open && !channel.isCongested {
            let count = Sys.receive(association.relay, streamBuffer)
            if count >= 0 {
                rounds += 1
                deliverFromRelay(association, UnsafeRawBufferPointer(rebasing: streamBuffer[0..<count]), now)
                continue
            }
            let code = errno
            if code == EINTR { continue }
            if Sys.wouldBlock(code) { break }
            // A connected datagram socket is told of an ICMP error from the relay: it is not there.
            endAssociation(association, "UDP association ended, the relay is not there (\(Sys.describe(code)))", now)
            break
        }
    }

    private func deliverFromRelay(_ association: UDPAssociation, _ bytes: UnsafeRawBufferPointer, _ now: Double) {
        guard let header = SOCKSDatagram.unwrap(bytes) else {
            note("UDP dropped, a datagram from the relay was not understood (or was a fragment)", now)
            return
        }
        let payload = UnsafeRawBufferPointer(rebasing: bytes[header.payloadOffset...])
        guard let destination = association.destination(answering: header.source, port: header.port, now: now, payload: payload) else {
            note("UDP dropped, an answer from where the guest sent nothing", now)
            return
        }
        guard payload.count + IPv4Packet.minimumHeaderLength + UDPDatagram.headerLength <= configuration.effectiveMTU else {
            note("UDP dropped, an answer larger than the guest's network takes", now)
            return
        }
        let frame = responder.datagram(to: association.guestMAC, from: destination.guestAddress, port: destination.port,
                                       to: VMNetIPv4(association.key.guestAddress), port: association.key.guestPort, payload: payload)
        frame.withUnsafeBytes { channel.send($0) }
        association.lastActivity = now
        counters.datagramsToGuest += 1
        counters.udpBytesToGuest += UInt64(payload.count)
        withHost(destination.host, now) { $0.bytesToGuest += UInt64(payload.count) }
    }

    private func sendToRelay(_ association: UDPAssociation, _ datagram: [UInt8], payloadLength: Int, host: String, _ now: Double) {
        while true {
            let sent = datagram.withUnsafeBytes { Sys.send(association.relay, $0) }
            if sent >= 0 {
                counters.datagramsRelayed += 1
                counters.udpBytesFromGuest += UInt64(payloadLength)
                withHost(host, now) { $0.bytesFromGuest += UInt64(payloadLength) }
                return
            }
            let code = errno
            if code == EINTR { continue }
            counters.datagramsDropped += 1
            if Sys.wouldBlock(code) || code == ENOBUFS {
                // A full socket: dropped, as a router drops what it has no room for.
                note("UDP dropped, the relay's socket was full", now)
            } else if code == ECONNREFUSED {
                endAssociation(association, "UDP association ended, the relay is not there (\(Sys.describe(code)))", now)
            } else {
                note("UDP dropped, the relay did not take it (\(Sys.describe(code)))", now)
            }
            return
        }
    }

    // MARK: Timers and endings

    private func associationTimerFired(_ association: UDPAssociation, _ now: Double) {
        switch association.phase {
        case .waiting:
            failAssociation(association, "UDP the proxy's address was not found in time", proxyUnreachable: false, now)
        case .handshaking:
            failAssociation(association, "UDP the proxy did not answer in time", proxyUnreachable: false, now)
        case .connecting:
            Sys.close(association.control)
            association.control = -1
            association.lastError = Sys.describe(ETIMEDOUT)
            if now >= association.deadline {
                failAssociation(association, "the proxy was not reached (\(association.lastError))", proxyUnreachable: true, now)
            } else {
                connectAssociation(association, now)
            }
        case .open:
            endAssociation(association, "UDP association closed, nothing moved for too long", now)
        case .done:
            if associations[association.key] === association { associations[association.key] = nil }
        }
    }

    /// An association that never came up: what waited for it is answered "port unreachable".
    /// Associations that fail one after another make the next wait a little longer.
    private func failAssociation(_ association: UDPAssociation, _ reason: String, proxyUnreachable: Bool, _ now: Double) {
        guard association.phase != .done else { return }
        closeDescriptors(of: association)
        association.phase = .done
        counters.udpAssociationsFailed += 1
        note(reason.hasPrefix("UDP ") ? reason : "UDP " + reason, now)
        if !udpRefusedByProxy {
            udpFailureStreak += 1
            udpPausedUntil = now + min(0.25 * Double(1 << min(udpFailureStreak - 1, 8)), 30)
        }
        if proxyUnreachable, let resolver {
            resolver.connectionFailed()
            resolver.resolveIfNeeded(now: now, done: { [wake] in wake.signal() })
        }
        let key = association.key
        for waiting in association.takeWaiting() {
            counters.datagramsDropped += 1
            if let reply = responder.portUnreachable(to: association.guestMAC, quoting: waiting.quote, from: waiting.destination,
                                                     to: VMNetIPv4(key.guestAddress), now: now) {
                reply.withUnsafeBytes { channel.send($0) }
            }
        }
        if associations[key] === association { associations[key] = nil }
    }

    /// An association that was up ends: its connection and its socket are closed. The guest's
    /// next datagram from that port makes a new one.
    private func endAssociation(_ association: UDPAssociation, _ reason: String, _ now: Double) {
        guard association.phase != .done else { return }
        let wasOpen = association.phase == .open
        closeDescriptors(of: association)
        association.phase = .done
        if wasOpen { counters.udpAssociationsActive -= 1 }
        note(reason, now)
        _ = association.takeWaiting()
        if associations[association.key] === association { associations[association.key] = nil }
    }

    private func closeDescriptors(of association: UDPAssociation) {
        if association.control >= 0 {
            Sys.close(association.control)
            association.control = -1
        }
        if association.relay >= 0 {
            Sys.close(association.relay)
            association.relay = -1
        }
    }

    private func closeAllAssociations() {
        for association in associations.values {
            closeDescriptors(of: association)
            association.phase = .done
        }
        associations.removeAll()
        counters.udpAssociationsActive = 0
    }
}
