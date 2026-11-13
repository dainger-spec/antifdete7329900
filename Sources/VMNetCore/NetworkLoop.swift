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

    init(key: FlowKey, tcp: TCPConnection, handshake: ProxyHandshake, deadline: Double) {
        self.key = key
        self.tcp = tcp
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
        /// Connections at once; one more is answered with a reset.
        var maximumConnections = 2048
        var dnsPoolCapacity = 60_000
        var lossToGuest = 0.0
        var lossFromGuest = 0.0
    }

    // Shared with other threads, under `lock`.
    private let lock = NSLock()
    private var published: VMNetCounters
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
    private var counters: VMNetCounters
    private var wireOpen = true
    private var wireHoldUntil = 0.0
    private var nextTimerCheck = Double.infinity
    private var timersRanAt = -Double.infinity
    private var notes: [String: Int] = [:]
    private var notesDue = Double.infinity
    private var notesFlushed = -Double.infinity
    private let streamBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 8)
    private let frameBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 8)

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
        responder = LinkResponder(configuration: configuration, dnsPoolCapacity: options.dnsPoolCapacity)
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
        say("network started: \(describeUpstream()), \(configuration.blockedHostSuffixes.count) blocked host suffixes")
        let wakeUp: @Sendable () -> Void = { [wake] in wake.signal() }
        resolver?.resolveIfNeeded(now: Sys.now, done: wakeUp)
        var entries: [pollfd] = []
        var polled: [Flow] = []
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
            entries.append(pollfd(fd: wake.descriptor, events: Sys.readable, revents: 0))
            let wireWaits = wireOpen && now >= wireHoldUntil
            entries.append(pollfd(fd: wireWaits ? channel.descriptor : -1, events: Sys.readable, revents: 0))
            var wakeAt = min(timerCheckDue, channel.retryAt, notesDue)
            if wireOpen && !wireWaits { wakeAt = min(wakeAt, wireHoldUntil) }
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
        publish()
        flushNotes(.infinity)
        let lost = channel.lost
        say("network stopped: \(counters.connectionsOpened) connections opened, \(counters.connectionsFailed) failed, "
            + "\(counters.bytesFromGuest) bytes from the guest, \(counters.bytesToGuest) bytes to the guest, "
            + "\(counters.dnsQueries) DNS queries (\(counters.dnsBlocked) blocked), \(counters.datagramsDropped) datagrams dropped, "
            + "\(lost) frames lost on a full wire")
        wake.close()
        ended.lock()
        hasEnded = true
        ended.broadcast()
        ended.unlock()
    }

    private func publish() {
        lock.lock()
        published = counters
        lock.unlock()
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
                switch responder.handle(bytes, now: now, counters: &counters) {
                case .ignore:
                    break
                case .reply(let frame):
                    frame.withUnsafeBytes { channel.send($0) }
                case .tcp(let source, let packet, let segment):
                    handleSegment(segment, in: packet, from: source, now)
                }
            }
        }
    }

    /// The other end of the wire is gone (the VM stopped): nothing is left to carry.
    private func wireClosed(_ now: Double) {
        guard wireOpen else { return }
        wireOpen = false
        say("the guest's wire closed: \(flows.count) connections dropped")
        for flow in Array(flows.values) {
            if flow.descriptor >= 0 {
                Sys.close(flow.descriptor)
                flow.descriptor = -1
            }
            if flow.phase == .open { counters.connectionsActive -= 1 }
        }
        flows.removeAll()
        dirty.removeAll()
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
        guard let handshake = configuration.upstream.handshake(for: target) else {
            // No proxy: nothing leaves.
            counters.connectionsFailed += 1
            note("refused, the profile has no usable proxy", now)
            refuse(segment, in: packet, from: source)
            return
        }
        if flows.count >= options.maximumConnections, !dropLingeringFlow(now) {
            note("refused, too many connections at once", now)
            refuse(segment, in: packet, from: source)
            return
        }
        let tcp = TCPConnection(key: key, guestMAC: source, gatewayMAC: configuration.gatewayMAC, mtu: configuration.effectiveMTU,
                                syn: segment, now: now, tuning: options.tcp, scratch: scratch, sink: channel)
        let flow = Flow(key: key, tcp: tcp, handshake: handshake, deadline: now + options.connectTimeout)
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
                    fail(flow, "the proxy's address was not found", proxyUnreachable: false, now)
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
            say("the proxy's address is known (\(snapshot.addresses.count) addresses)")
        }
        for flow in Array(flows.values) where flow.phase == .waiting {
            if snapshot.addresses.isEmpty {
                fail(flow, "the proxy's address was not found", proxyUnreachable: false, now)
            } else {
                connectNext(flow, now)
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
        fail(flow, "the proxy was not reached (\(flow.lastError))", proxyUnreachable: true, now)
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
            flow.tcp.tunnelEstablished(now: now)
            if !leftover.isEmpty { leftover.withUnsafeBytes { flow.tcp.upstreamData($0, now: now) } }
            markDirty(flow)
        case .failed(let failure):
            fail(flow, failure.reason, proxyUnreachable: false, now)
        }
    }

    private func writeHandshake(_ flow: Flow, _ now: Double) {
        while flow.outgoingSent < flow.outgoing.count {
            let sent = flow.outgoing.withUnsafeBytes { bytes -> (Int, Int32) in
                let count = Sys.send(flow.descriptor, UnsafeRawBufferPointer(rebasing: bytes[flow.outgoingSent...]))
                return (count, errno)
            }
            if sent.0 > 0 {
                flow.outgoingSent += sent.0
            } else if sent.1 == EINTR {
                continue
            } else if Sys.wouldBlock(sent.1) {
                return
            } else {
                fail(flow, "the proxy closed the connection (\(Sys.describe(sent.1)))", proxyUnreachable: false, now)
                return
            }
        }
        flow.outgoing = []
        flow.outgoingSent = 0
    }

    private func readHandshake(_ flow: Flow, _ now: Double) {
        let count = Sys.receive(flow.descriptor, UnsafeMutableRawBufferPointer(rebasing: streamBuffer[0..<4096]))
        if count > 0 {
            apply(flow.handshake.receive(Array(UnsafeRawBufferPointer(rebasing: streamBuffer[0..<count]))), to: flow, now)
        } else if count == 0 {
            fail(flow, "the proxy closed the connection", proxyUnreachable: false, now)
        } else {
            let code = errno
            if code != EINTR && !Sys.wouldBlock(code) {
                fail(flow, "the proxy closed the connection (\(Sys.describe(code)))", proxyUnreachable: false, now)
            }
        }
    }

    /// The proxy gave no tunnel: the guest's SYN is answered with a reset and the connection forgotten.
    private func fail(_ flow: Flow, _ reason: String, proxyUnreachable: Bool, _ now: Double) {
        if flow.descriptor >= 0 {
            Sys.close(flow.descriptor)
            flow.descriptor = -1
        }
        flow.phase = .done
        counters.connectionsFailed += 1
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
            if revents & Sys.writable != 0 { writeHandshake(flow, now) }
            if flow.phase == .handshaking && revents & (Sys.readable | Sys.hungUp | Sys.failed) != 0 { readHandshake(flow, now) }
        case .open:
            var useful = false
            if revents & Sys.writable != 0 {
                flow.wantsWrite = false
                writeUpstream(flow, now)
                useful = true
            }
            if flow.tcp.state != .closed && revents & (Sys.readable | Sys.hungUp | Sys.failed) != 0 {
                if wantsRead(flow) {
                    readUpstream(flow, now)
                    useful = true
                } else if revents & Sys.failed != 0, Sys.pendingError(flow.descriptor) != 0 {
                    flow.tcp.upstreamBroke(now: now)
                    useful = true
                }
            }
            // "Hung up" with nothing to read or write yet would wake the loop at every turn.
            if !useful { flow.holdUntil = now + 0.02 }
            markDirty(flow)
        }
    }

    private func readUpstream(_ flow: Flow, _ now: Double) {
        let tcp = flow.tcp
        var rounds = 0
        while tcp.state != .closed && !flow.readEnded && rounds < 16 {
            let wanted = min(tcp.upstreamRoom, streamBuffer.count)
            guard wanted > 0 else { break }
            let count = Sys.receive(flow.descriptor, UnsafeMutableRawBufferPointer(rebasing: streamBuffer[0..<wanted]))
            if count > 0 {
                tcp.upstreamData(UnsafeRawBufferPointer(rebasing: streamBuffer[0..<count]), now: now)
                if count < wanted { break }
                rounds += 1
            } else if count == 0 {
                flow.readEnded = true
                tcp.upstreamFinished(now: now)
            } else {
                let code = errno
                if code == EINTR { continue }
                if !Sys.wouldBlock(code) { tcp.upstreamBroke(now: now) }
                break
            }
        }
    }

    private func writeUpstream(_ flow: Flow, _ now: Double) {
        let tcp = flow.tcp
        while tcp.state != .closed && tcp.upstreamBacklog > 0 {
            let sent = tcp.withUpstreamBacklog { bytes -> (Int, Int32) in
                let count = Sys.send(flow.descriptor, bytes)
                return (count, errno)
            }
            if sent.0 > 0 {
                counters.bytesFromGuest += UInt64(sent.0)
                tcp.upstreamConsumed(sent.0, now: now)
            } else if sent.1 == EINTR {
                continue
            } else if Sys.wouldBlock(sent.1) {
                flow.wantsWrite = true
                break
            } else {
                tcp.upstreamBroke(now: now)
                break
            }
        }
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
            counters.bytesToGuest += tcp.takeDeliveredBytes()
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
        if flow.phase == .open { counters.connectionsActive -= 1 }
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
        nextTimerCheck = next
        timersRanAt = now
        for flow in due {
            switch flow.phase {
            case .waiting:
                fail(flow, "the proxy's address was not found in time", proxyUnreachable: false, now)
            case .handshaking:
                fail(flow, "the proxy did not answer in time", proxyUnreachable: false, now)
            case .connecting:
                Sys.close(flow.descriptor)
                flow.descriptor = -1
                flow.lastError = Sys.describe(ETIMEDOUT)
                if now >= flow.deadline {
                    fail(flow, "the proxy was not reached (\(flow.lastError))", proxyUnreachable: true, now)
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
}
