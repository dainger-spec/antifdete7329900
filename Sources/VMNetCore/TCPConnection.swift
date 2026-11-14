import Foundation

// Sequence numbers wrap around at 2^32: "before" and "after" are read from the difference.
@inline(__always) func sequence(_ a: UInt32, isBefore b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
@inline(__always) func sequence(_ a: UInt32, isAtOrBefore b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }

/// Where the stack's frames go: the guest's wire.
protocol FrameSink: AnyObject {
    /// True while frames are being held back because the wire took no more. A connection sends no
    /// new data meanwhile (it is asked again when the wire has room), so the wire's limit slows
    /// the proxy down instead of losing segments.
    var isCongested: Bool { get }
    func send(_ frame: UnsafeRawBufferPointer)
}

/// Room to write one frame in, shared by everything that sends on one wire.
final class FrameScratch {
    let buffer: UnsafeMutableRawBufferPointer

    init(capacity: Int = 65_536 + 128) {
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 8)
    }

    deinit { buffer.deallocate() }
}

/// A connection as the guest names it: its own address and port, and those it connected to.
struct FlowKey: Hashable {
    var guestAddress: UInt32
    var guestPort: UInt16
    var remoteAddress: UInt32
    var remotePort: UInt16
}

/// One TCP connection the guest opened, ended here: the stack plays the server the guest thinks
/// it reached, and what the guest sends is handed on to the proxy's tunnel as a plain stream.
///
/// This is the protocol only — segments in, segments out, a clock passed in — so it is tested
/// against a scripted guest. The socket to the proxy belongs to `NetworkLoop`, which tells the
/// connection when the tunnel is up, hands it what the proxy sent, and takes what the guest sent.
///
/// What it does not do, on purpose: selective acknowledgements, timestamps, and connections
/// opened towards the guest.
final class TCPConnection {
    struct Tuning {
        /// Bytes from the guest kept for a proxy that is slower than the guest. The window the
        /// guest is told follows what is free here, so a slow proxy slows the guest down.
        var receiveBufferLimit = 256 * 1024
        /// Bytes from the proxy kept until the guest acknowledges them. Nothing more is read from
        /// the proxy while it is full, so a slow guest slows the proxy down.
        var sendBufferLimit = 256 * 1024
        /// The first wait before unacknowledged data is sent again; it doubles each time, up to the maximum.
        var initialRetransmissionTimeout = 0.25
        var maximumRetransmissionTimeout = 30.0
        var handshakeTimeout = 1.0
        var handshakeAttempts = 5
        /// The first wait before asking a guest whose window is shut whether it has opened.
        var persistInterval = 0.5
        var maximumPersistInterval = 5.0
        /// A guest that has answered nothing for this long while data waits for it is gone.
        var silenceLimit = 900.0
        /// How long a finished connection is remembered, to answer the guest's last segments again.
        var linger = 3.0
        /// A connection on which nothing at all moved for this long is closed.
        var idleTimeout = 7200.0
        /// The congestion window at the start, in segments (RFC 6928). Also the least it is cut
        /// to when a loss is noticed from duplicate acknowledgements: the wire is a socket on
        /// this Mac, not a shared path to be careful of, and a window of a few segments could
        /// not show a loss that way at all (three later segments must arrive to give it away).
        var initialWindowSegments = 10
        /// The congestion window after a timeout, in segments: small, but enough for duplicate
        /// acknowledgements to show the next loss.
        var timeoutWindowSegments = 4
        /// The shift of the window the guest is told: 256 KiB does not fit in 16 bits.
        var windowShift: UInt8 = 3
        /// How many segments that arrived ahead of a gap are kept until the gap is filled.
        var earlySegmentLimit = 1024
    }

    enum State: Equatable {
        /// The guest's SYN is here; the proxy is being asked. The guest hears nothing yet.
        case connecting
        /// The tunnel is up and the SYN-ACK is sent.
        case synAckSent
        case established
        case closed
    }

    /// How a connection ended.
    enum Ending: Equatable {
        /// Both sides closed and everything was delivered.
        case finished
        case guestReset
        /// The proxy gave no tunnel: the guest's SYN was answered with a reset.
        case refused
        /// The tunnel broke: the guest was sent a reset.
        case upstreamBroke
        /// The guest stopped answering, or nothing moved for the idle limit.
        case timedOut
    }

    let key: FlowKey
    let tuning: Tuning
    private let guestMAC: VMNetMAC
    private let gatewayMAC: VMNetMAC
    private let scratch: FrameScratch
    private unowned let sink: FrameSink

    private(set) var state = State.connecting
    private(set) var ending: Ending?
    /// Until when a closed connection is kept to answer the guest's stragglers; nil: not at all.
    private(set) var lingerUntil: Double?

    // From the guest.
    private let initialReceiveSequence: UInt32
    private var receiveNext: UInt32
    private var toUpstream = ByteQueue()
    /// The end of the window as the guest was last told.
    private var advertisedEdge: UInt32
    private let receiveShift: UInt8
    /// Segments that arrived ahead of a gap, inside the window: in order of sequence number,
    /// never overlapping. They join `toUpstream` when what is missing before them arrives.
    private var early: [(sequence: UInt32, bytes: [UInt8])] = []
    private(set) var guestFinished = false
    private var upstreamShutdownNoted = false
    private var acknowledgementPending = false

    // To the guest.
    private let initialSendSequence: UInt32
    /// The first byte not acknowledged, the next to send, and the highest ever sent.
    private var sendUnacknowledged: UInt32
    private var sendNext: UInt32
    private var sendMaximum: UInt32
    /// The proxy's bytes from `sendUnacknowledged` on.
    private var sendBuffer = ByteQueue()
    private var sendWindow: Int
    private let sendShift: UInt8
    private var windowUpdateSequence: UInt32
    private var windowUpdateAcknowledgement: UInt32
    let segmentSize: Int
    private var congestionWindow: Int
    private var slowStartThreshold = Int.max
    private var duplicateAcknowledgements = 0
    private var inRecovery = false
    private var recoveryPoint: UInt32
    private var upstreamEnded = false
    private var finSent = false
    private var finAcknowledged = false

    private var retransmissionTimeout: Double
    private var retransmissionDeadline: Double?
    private var persistInterval: Double
    private var persistDeadline: Double?
    private var handshakeDeadline: Double?
    private var handshakeAttempts = 0
    private var lastHeard: Double
    private var lastActivity: Double
    private var identification = UInt16.random(in: 0...UInt16.max)

    /// Payload the guest has acknowledged since this was last read.
    private(set) var deliveredBytes: UInt64 = 0
    private(set) var retransmissions: UInt64 = 0

    /// `syn` is the guest's first segment. Nothing is sent until `tunnelEstablished` or `tunnelFailed`.
    init(key: FlowKey, guestMAC: VMNetMAC, gatewayMAC: VMNetMAC, mtu: Int, syn: TCPSegment, now: Double,
         tuning: Tuning = Tuning(), scratch: FrameScratch, sink: FrameSink, initialSequence: UInt32? = nil) {
        self.key = key
        self.guestMAC = guestMAC
        self.gatewayMAC = gatewayMAC
        self.tuning = tuning
        self.scratch = scratch
        self.sink = sink
        initialReceiveSequence = syn.sequence
        receiveNext = syn.sequence &+ 1
        advertisedEdge = receiveNext
        let start = initialSequence ?? UInt32.random(in: 0...UInt32.max)
        initialSendSequence = start
        sendUnacknowledged = start
        sendNext = start
        sendMaximum = start
        recoveryPoint = start
        // The guest's limit (536 when it names none, RFC 9293) and this wire's.
        segmentSize = max(min(Int(syn.maximumSegmentSize ?? 536), mtu - 40), 64)
        if let shift = syn.windowScale {
            sendShift = min(shift, 14)
            receiveShift = tuning.windowShift
        } else {
            // Scaling is used only when the guest offered it.
            sendShift = 0
            receiveShift = 0
        }
        sendWindow = Int(syn.window)
        windowUpdateSequence = syn.sequence
        windowUpdateAcknowledgement = start
        congestionWindow = tuning.initialWindowSegments * segmentSize
        retransmissionTimeout = tuning.initialRetransmissionTimeout
        persistInterval = tuning.persistInterval
        lastHeard = now
        lastActivity = now
        self.mtu = mtu
    }

    private let mtu: Int

    // MARK: - The tunnel's side

    /// The proxy's tunnel is up: the guest gets its SYN-ACK.
    func tunnelEstablished(now: Double) {
        guard state == .connecting else { return }
        state = .synAckSent
        lastActivity = now
        handshakeAttempts = 1
        handshakeDeadline = now + tuning.handshakeTimeout
        sendSynAck()
    }

    /// The proxy gave no tunnel: the guest's SYN is answered with a reset, as a closed port is.
    func tunnelFailed(now: Double) {
        guard state == .connecting else { return }
        emit(flags: [.rst, .ack], sequence: 0)
        close(.refused, now: now, linger: false)
    }

    /// How many more of the proxy's bytes the connection takes now.
    var upstreamRoom: Int {
        guard state != .closed, !upstreamEnded else { return 0 }
        return max(tuning.sendBufferLimit - sendBuffer.count, 0)
    }

    /// Bytes the proxy sent, in order. At most `upstreamRoom` of them.
    func upstreamData(_ bytes: UnsafeRawBufferPointer, now: Double) {
        guard state != .closed, !upstreamEnded, !bytes.isEmpty else { return }
        sendBuffer.append(bytes)
        lastActivity = now
        pump()
        updateTimers(now)
    }

    /// The proxy closed its side: the guest gets a FIN after the last byte.
    func upstreamFinished(now: Double) {
        guard state != .closed, !upstreamEnded else { return }
        upstreamEnded = true
        lastActivity = now
        pump()
        finishIfDone(now)
        updateTimers(now)
    }

    /// The tunnel broke (a reset, an error): the guest gets a reset.
    func upstreamBroke(now: Double) {
        switch state {
        case .closed: return
        case .connecting: tunnelFailed(now: now)
        case .synAckSent, .established: reset(.upstreamBroke, now: now)
        }
    }

    /// How much of what the guest sent still waits to be written to the proxy.
    var upstreamBacklog: Int { toUpstream.count }

    func withUpstreamBacklog<Result>(_ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        toUpstream.withBytes(body)
    }

    /// `count` bytes of the backlog were written to the proxy.
    func upstreamConsumed(_ count: Int, now: Double) {
        guard count > 0 else { return }
        toUpstream.removeFirst(count)
        lastActivity = now
        guard state == .established else { return }
        // Tell the guest when the window has opened by a worthwhile amount — not for every byte.
        let opened = Int(Int32(bitPattern: currentEdge() &- advertisedEdge))
        if opened >= min(tuning.receiveBufferLimit / 2, 2 * segmentSize) { acknowledgementPending = true }
        finishIfDone(now)
    }

    /// The guest closed its side and all it sent is written: time to close the tunnel's sending side.
    var shouldShutdownUpstream: Bool { guestFinished && toUpstream.isEmpty && !upstreamShutdownNoted && state != .closed }

    func noteUpstreamShutdown() { upstreamShutdownNoted = true }

    // MARK: - The guest's side

    /// A segment from the guest for this connection.
    func receive(_ segment: TCPSegment, now: Double) {
        lastHeard = now
        switch state {
        case .closed:
            // After a clean end, the guest's last FIN again means the answer to it was lost.
            if ending == .finished, !segment.flags.contains(.rst), segment.flags.contains(.fin) || !segment.payload.isEmpty {
                emit(flags: [.ack], sequence: sendMaximum)
            }
        case .connecting:
            // A repeated SYN gets no answer until the proxy has given one.
            if segment.flags.contains(.rst) { close(.guestReset, now: now, linger: false) }
        case .synAckSent:
            if segment.flags.contains(.rst) {
                close(.guestReset, now: now, linger: false)
            } else if segment.flags.contains(.syn) {
                if segment.sequence == initialReceiveSequence { sendSynAck() }
            } else if segment.flags.contains(.ack) {
                guard segment.acknowledgement == initialSendSequence &+ 1 else {
                    // Not an answer to this SYN-ACK.
                    emitRaw(flags: [.rst], sequence: segment.acknowledgement, acknowledgement: 0, window: 0)
                    return
                }
                state = .established
                handshakeDeadline = nil
                sendUnacknowledged = segment.acknowledgement
                sendWindow = Int(segment.window) << Int(sendShift)
                windowUpdateSequence = segment.sequence
                windowUpdateAcknowledgement = segment.acknowledgement
                lastActivity = now
                established(segment, now: now)
            }
        case .established:
            established(segment, now: now)
        }
    }

    private func established(_ segment: TCPSegment, now: Double) {
        if segment.flags.contains(.rst) {
            // Only a reset that fits what the guest was told it may send.
            let offset = Int(Int32(bitPattern: segment.sequence &- receiveNext))
            let window = Int(Int32(bitPattern: advertisedEdge &- receiveNext))
            if offset >= 0 && offset <= max(window, 0) { close(.guestReset, now: now, linger: false) }
            return
        }
        if segment.flags.contains(.syn) {
            // A SYN on a live connection: say where the connection is (RFC 5961). A guest that
            // has forgotten it answers with a reset, and its next SYN starts afresh.
            emit(flags: [.ack], sequence: sendMaximum)
            return
        }
        guard segment.flags.contains(.ack) else { return }
        lastActivity = now
        guard acknowledge(segment, now: now) else { return }
        accept(segment)
        pump()
        finishIfDone(now)
        updateTimers(now)
    }

    /// The acknowledgement and the window in a segment. False when the segment is to be dropped.
    private func acknowledge(_ segment: TCPSegment, now: Double) -> Bool {
        let acknowledgement = segment.acknowledgement
        if sequence(sendMaximum, isBefore: acknowledgement) {
            // It acknowledges what was never sent.
            emit(flags: [.ack], sequence: sendMaximum)
            return false
        }
        // An old acknowledgement says nothing new; the segment's data is still looked at.
        if sequence(acknowledgement, isBefore: sendUnacknowledged) { return true }

        var windowChanged = false
        if sequence(windowUpdateSequence, isBefore: segment.sequence)
            || (windowUpdateSequence == segment.sequence && sequence(windowUpdateAcknowledgement, isAtOrBefore: acknowledgement)) {
            let window = Int(segment.window) << Int(sendShift)
            windowChanged = window != sendWindow
            sendWindow = window
            windowUpdateSequence = segment.sequence
            windowUpdateAcknowledgement = acknowledgement
        }

        let acknowledged = Int(acknowledgement &- sendUnacknowledged)
        if acknowledged > 0 {
            let data = min(acknowledged, sendBuffer.count)
            sendBuffer.removeFirst(data)
            deliveredBytes += UInt64(data)
            if acknowledged > data {
                // One more than the data: the FIN.
                finAcknowledged = true
                finSent = true
            }
            sendUnacknowledged = acknowledgement
            if sequence(sendNext, isBefore: sendUnacknowledged) { sendNext = sendUnacknowledged }
            retransmissionTimeout = tuning.initialRetransmissionTimeout
            retransmissionDeadline = nil
            if inRecovery {
                if sequence(acknowledgement, isBefore: recoveryPoint) {
                    // Part of what was out when the loss was noticed: the next hole is right here.
                    retransmitFirst()
                    retransmissionDeadline = now + retransmissionTimeout
                } else {
                    inRecovery = false
                    duplicateAcknowledgements = 0
                    congestionWindow = max(slowStartThreshold, segmentSize)
                }
            } else {
                duplicateAcknowledgements = 0
                if congestionWindow < slowStartThreshold {
                    congestionWindow += acknowledged
                } else {
                    congestionWindow += max(segmentSize * segmentSize / congestionWindow, 1)
                }
                congestionWindow = min(congestionWindow, max(tuning.sendBufferLimit, segmentSize))
            }
        } else if segment.payload.isEmpty, !segment.flags.contains(.fin), !windowChanged, sendUnacknowledged != sendMaximum {
            // The same acknowledgement again while data is out: the guest got something later
            // than what it waits for. Three of them mean a segment was lost (RFC 5681, RFC 6582).
            duplicateAcknowledgements += 1
            if duplicateAcknowledgements == 3, !inRecovery {
                if sequence(recoveryPoint, isAtOrBefore: acknowledgement) {
                    slowStartThreshold = max(Int(sendMaximum &- sendUnacknowledged) / 2, tuning.initialWindowSegments * segmentSize)
                    congestionWindow = slowStartThreshold
                    inRecovery = true
                    recoveryPoint = sendMaximum
                }
                // Otherwise a timeout came before, and what was out then is being sent again in
                // order: the windows were already cut at the timeout and stay as they are. But
                // three duplicates still say that the first unacknowledged segment is missing
                // over there, so it goes again now — once: if it is lost again, the timer is
                // what is left.
                retransmitFirst()
                retransmissionDeadline = now + retransmissionTimeout
            }
        }
        return true
    }

    /// The data and the FIN in a segment. What is next in order is taken; what arrives ahead of
    /// a gap is kept until the gap is filled; what was received before is only answered.
    private func accept(_ segment: TCPSegment) {
        var payload = segment.payload
        let fin = segment.flags.contains(.fin)
        guard !payload.isEmpty || fin else {
            // A bare acknowledgement from before what was received is a keepalive probe: answer it.
            if sequence(segment.sequence, isBefore: receiveNext) { emit(flags: [.ack], sequence: sendMaximum) }
            return
        }
        if guestFinished {
            // Nothing new comes after a FIN.
            emit(flags: [.ack], sequence: sendMaximum)
            return
        }
        let behind = Int(Int32(bitPattern: receiveNext &- segment.sequence))
        if behind < 0 {
            // A gap before it. The data is kept (a FIN ahead of a gap is not: the guest sends it
            // again), and the guest is told at once what is still expected. Each such answer
            // says "a segment arrived"; three of them make the guest send the missing one again
            // without waiting for its timer.
            keepEarly(payload, at: -behind)
            emit(flags: [.ack], sequence: sendMaximum)
            return
        }
        if behind > 0 {
            if behind > payload.count || (behind == payload.count && !fin) {
                // All of it was received before (a retransmission, a keepalive probe's one byte).
                emit(flags: [.ack], sequence: sendMaximum)
                return
            }
            payload = payload.part(behind)
        }
        let room = max(tuning.receiveBufferLimit - toUpstream.count, 0)
        let taken = min(payload.count, room)
        if taken > 0 {
            toUpstream.append(payload.part(0, taken))
            receiveNext = receiveNext &+ UInt32(taken)
        }
        if taken < payload.count {
            // More than the window allowed (or a probe of a shut window): the rest is dropped.
            emit(flags: [.ack], sequence: sendMaximum)
            return
        }
        if fin {
            receiveNext = receiveNext &+ 1
            guestFinished = true
            early.removeAll()
        } else if !early.isEmpty {
            joinEarly()
        }
        // One acknowledgement for all that arrives together: `flush` sends it.
        acknowledgementPending = true
    }

    /// Keeps the part of an early segment that is inside the window and not already kept.
    /// `offset` is where it starts, counted from the next byte expected.
    private func keepEarly(_ payload: UnsafeRawBufferPointer, at offset: Int) {
        let room = max(tuning.receiveBufferLimit - toUpstream.count, 0)
        let end = min(offset + payload.count, room)
        guard offset < end else { return }
        func piece(_ from: Int, _ to: Int) -> (sequence: UInt32, bytes: [UInt8]) {
            (receiveNext &+ UInt32(from), Array(payload[(from - offset)..<(to - offset)]))
        }
        // The usual case: it follows everything kept so far.
        if let last = early.last {
            let lastEnd = Int(Int32(bitPattern: last.sequence &- receiveNext)) + last.bytes.count
            if offset >= lastEnd {
                if early.count < tuning.earlySegmentLimit { early.append(piece(offset, end)) }
                return
            }
        }
        // Otherwise: the pieces of it that fall between the segments already kept.
        var index = 0
        var cursor = offset
        while index < early.count && cursor < end {
            let start = Int(Int32(bitPattern: early[index].sequence &- receiveNext))
            let stop = start + early[index].bytes.count
            if stop <= cursor {
                index += 1
                continue
            }
            if start >= end { break }
            if start > cursor {
                guard early.count < tuning.earlySegmentLimit else { return }
                early.insert(piece(cursor, start), at: index)
                index += 1
            }
            cursor = stop
            index += 1
        }
        if cursor < end, early.count < tuning.earlySegmentLimit { early.insert(piece(cursor, end), at: index) }
    }

    /// After data arrived in order: the early segments that now follow it without a gap join it.
    private func joinEarly() {
        var joined = 0
        while joined < early.count {
            let entry = early[joined]
            let offset = Int(Int32(bitPattern: entry.sequence &- receiveNext))
            if offset > 0 { break }
            joined += 1
            let skip = -offset
            guard skip < entry.bytes.count else { continue }
            let room = max(tuning.receiveBufferLimit - toUpstream.count, 0)
            let taken = min(entry.bytes.count - skip, room)
            guard taken > 0 else { continue }
            entry.bytes.withUnsafeBytes { toUpstream.append($0.part(skip, taken)) }
            receiveNext = receiveNext &+ UInt32(taken)
        }
        if joined > 0 { early.removeSubrange(0..<joined) }
    }

    /// How many early segments are kept. For tests.
    var earlySegmentCount: Int { early.count }

    /// Sends what waits and is allowed: the proxy's bytes, the FIN after them, a pending
    /// acknowledgement. `NetworkLoop` calls it after each round of events and when the wire has room again.
    func flush(now: Double) {
        guard state == .established else { return }
        pump()
        if acknowledgementPending { emit(flags: [.ack], sequence: sendMaximum) }
        finishIfDone(now)
        updateTimers(now)
    }

    /// The earliest time `timerFired` has something to do.
    var nextDeadline: Double? {
        switch state {
        case .closed: return lingerUntil
        case .connecting: return nil
        case .synAckSent: return handshakeDeadline
        case .established:
            var deadline = lastActivity + tuning.idleTimeout
            if let retransmissionDeadline { deadline = min(deadline, retransmissionDeadline) }
            if let persistDeadline { deadline = min(deadline, persistDeadline) }
            return deadline
        }
    }

    func timerFired(now: Double) {
        switch state {
        case .closed, .connecting:
            return
        case .synAckSent:
            guard let deadline = handshakeDeadline, now >= deadline else { return }
            guard handshakeAttempts < tuning.handshakeAttempts else {
                reset(.timedOut, now: now)
                return
            }
            handshakeDeadline = now + tuning.handshakeTimeout * Double(1 << handshakeAttempts)
            handshakeAttempts += 1
            sendSynAck()
        case .established:
            if now - lastActivity >= tuning.idleTimeout {
                reset(.timedOut, now: now)
                return
            }
            if let deadline = retransmissionDeadline, now >= deadline {
                guard now - lastHeard < tuning.silenceLimit else {
                    reset(.timedOut, now: now)
                    return
                }
                // Nothing came back in time: start again from the last acknowledged byte, slowly.
                slowStartThreshold = max(Int(sendMaximum &- sendUnacknowledged) / 2, tuning.initialWindowSegments * segmentSize)
                congestionWindow = tuning.timeoutWindowSegments * segmentSize
                recoveryPoint = sendMaximum
                inRecovery = false
                duplicateAcknowledgements = 0
                sendNext = sendUnacknowledged
                if !finAcknowledged { finSent = false }
                retransmissionTimeout = min(retransmissionTimeout * 2, tuning.maximumRetransmissionTimeout)
                retransmissionDeadline = nil
                retransmissions += 1
                pump()
                updateTimers(now)
            }
            if let deadline = persistDeadline, now >= deadline {
                guard now - lastHeard < tuning.silenceLimit else {
                    reset(.timedOut, now: now)
                    return
                }
                // The guest's window is shut and the segment that opens it may have been lost:
                // a segment from just before what it expects makes it say its window again.
                emit(flags: [.ack], sequence: sendUnacknowledged &- 1)
                persistInterval = min(persistInterval * 2, tuning.maximumPersistInterval)
                persistDeadline = now + persistInterval
            }
        }
    }

    /// Reads and clears the count of payload the guest acknowledged.
    func takeDeliveredBytes() -> UInt64 {
        defer { deliveredBytes = 0 }
        return deliveredBytes
    }

    // MARK: - Sending

    private func pump() {
        guard state == .established else { return }
        let limit = min(sendWindow, congestionWindow)
        while !sink.isCongested {
            let offset = Int(sendNext &- sendUnacknowledged)
            let unsent = sendBuffer.count - offset
            guard unsent > 0 else { break }
            let room = limit - offset
            guard room > 0 else { break }
            let length = min(unsent, segmentSize, room)
            // A short segment while others are out waits for their acknowledgements, which open
            // the window: the guest is not fed crumbs.
            if length < segmentSize && length < unsent && offset > 0 { break }
            emit(flags: length == unsent ? [.ack, .psh] : [.ack], sequence: sendNext, payloadOffset: offset, payloadLength: length)
            sendNext = sendNext &+ UInt32(length)
            if sequence(sendMaximum, isBefore: sendNext) { sendMaximum = sendNext }
        }
        if upstreamEnded, !finSent, Int(sendNext &- sendUnacknowledged) == sendBuffer.count, !sink.isCongested {
            emit(flags: [.fin, .ack], sequence: sendNext)
            sendNext = sendNext &+ 1
            finSent = true
            if sequence(sendMaximum, isBefore: sendNext) { sendMaximum = sendNext }
        }
    }

    /// Sends the first unacknowledged segment again, whatever the windows say.
    private func retransmitFirst() {
        retransmissions += 1
        if sendBuffer.count > 0 {
            let length = min(segmentSize, sendBuffer.count)
            emit(flags: length == sendBuffer.count ? [.ack, .psh] : [.ack], sequence: sendUnacknowledged, payloadOffset: 0, payloadLength: length)
        } else if finSent && !finAcknowledged {
            emit(flags: [.fin, .ack], sequence: sendUnacknowledged)
        }
    }

    private func sendSynAck() {
        let size = UInt16(mtu - 40)
        var options: [UInt8] = [2, 4, UInt8(size >> 8), UInt8(size & 0xFF)]
        if receiveShift > 0 || sendShift > 0 { options += [1, 3, 3, receiveShift] }
        emit(flags: [.syn, .ack], sequence: initialSendSequence, options: options)
        sendNext = initialSendSequence &+ 1
        if sequence(sendMaximum, isBefore: sendNext) { sendMaximum = sendNext }
    }

    private func updateTimers(_ now: Double) {
        guard state == .established else { return }
        if sendNext != sendUnacknowledged {
            if retransmissionDeadline == nil { retransmissionDeadline = now + retransmissionTimeout }
            persistDeadline = nil
            persistInterval = tuning.persistInterval
        } else {
            retransmissionDeadline = nil
            if sendWindow == 0 && sendBuffer.count > 0 {
                if persistDeadline == nil { persistDeadline = now + persistInterval }
            } else {
                persistDeadline = nil
                persistInterval = tuning.persistInterval
            }
        }
    }

    /// Both sides have closed, the guest has everything and so has the proxy: a clean end.
    private func finishIfDone(_ now: Double) {
        guard state == .established, guestFinished, finAcknowledged, toUpstream.isEmpty else { return }
        if acknowledgementPending { emit(flags: [.ack], sequence: sendMaximum) }
        close(.finished, now: now, linger: true)
    }

    private func reset(_ ending: Ending, now: Double) {
        emit(flags: [.rst, .ack], sequence: sendMaximum)
        close(ending, now: now, linger: false)
    }

    private func close(_ ending: Ending, now: Double, linger: Bool) {
        state = .closed
        self.ending = ending
        lingerUntil = linger ? now + tuning.linger : nil
        retransmissionDeadline = nil
        persistDeadline = nil
        handshakeDeadline = nil
        sendBuffer.removeAll()
        toUpstream.removeAll()
        early.removeAll()
    }

    /// The end of the window on offer now: what is free in the buffer, in the window field's units.
    private func currentEdge() -> UInt32 {
        receiveNext &+ UInt32(windowField(scaled: true)) << UInt32(receiveShift)
    }

    private func windowField(scaled: Bool) -> UInt16 {
        let room = max(tuning.receiveBufferLimit - toUpstream.count, 0)
        return UInt16(min(scaled ? room >> Int(receiveShift) : room, 65_535))
    }

    /// A segment that says where the connection is: its acknowledgement and window are the current ones.
    private func emit(flags: TCPFlags, sequence: UInt32, options: [UInt8] = [], payloadOffset: Int = 0, payloadLength: Int = 0) {
        // A SYN's window is never scaled (RFC 7323).
        let window = windowField(scaled: !flags.contains(.syn))
        if !flags.contains(.rst) {
            advertisedEdge = receiveNext &+ UInt32(window) << UInt32(flags.contains(.syn) ? 0 : receiveShift)
            acknowledgementPending = false
        }
        sendBuffer.withBytes(from: payloadOffset, length: payloadLength) { payload in
            write(flags: flags, sequence: sequence, acknowledgement: receiveNext, window: flags.contains(.rst) ? 0 : window,
                  options: options, payload: payload)
        }
    }

    private func emitRaw(flags: TCPFlags, sequence: UInt32, acknowledgement: UInt32, window: UInt16) {
        write(flags: flags, sequence: sequence, acknowledgement: acknowledgement, window: window, options: [],
              payload: UnsafeRawBufferPointer(start: nil, count: 0))
    }

    private func write(flags: TCPFlags, sequence: UInt32, acknowledgement: UInt32, window: UInt16, options: [UInt8],
                       payload: UnsafeRawBufferPointer) {
        identification = identification &+ 1
        let length = FrameBuilder.tcp(into: scratch.buffer, destinationMAC: guestMAC, sourceMAC: gatewayMAC,
                                      source: VMNetIPv4(key.remoteAddress), sourcePort: key.remotePort,
                                      destination: VMNetIPv4(key.guestAddress), destinationPort: key.guestPort,
                                      sequence: sequence, acknowledgement: acknowledgement, flags: flags, window: window,
                                      options: options, payload: payload, identification: identification)
        sink.send(UnsafeRawBufferPointer(rebasing: scratch.buffer[0..<length]))
    }

    /// The reset that answers a segment for which there is no connection (RFC 9293 §3.10.7.1),
    /// written into `scratch`: the bytes of the frame to send.
    static func resetFrame(answering segment: TCPSegment, from remote: VMNetIPv4, to guest: VMNetIPv4,
                           guestMAC: VMNetMAC, gatewayMAC: VMNetMAC, scratch: FrameScratch) -> UnsafeRawBufferPointer {
        let flags: TCPFlags
        let sequence: UInt32, acknowledgement: UInt32
        if segment.flags.contains(.ack) {
            flags = [.rst]
            sequence = segment.acknowledgement
            acknowledgement = 0
        } else {
            flags = [.rst, .ack]
            sequence = 0
            var length = UInt32(segment.payload.count)
            if segment.flags.contains(.syn) { length += 1 }
            if segment.flags.contains(.fin) { length += 1 }
            acknowledgement = segment.sequence &+ length
        }
        let length = FrameBuilder.tcp(into: scratch.buffer, destinationMAC: guestMAC, sourceMAC: gatewayMAC,
                                      source: remote, sourcePort: segment.destinationPort,
                                      destination: guest, destinationPort: segment.sourcePort,
                                      sequence: sequence, acknowledgement: acknowledgement, flags: flags, window: 0,
                                      payload: UnsafeRawBufferPointer(start: nil, count: 0), identification: 0)
        return UnsafeRawBufferPointer(rebasing: scratch.buffer[0..<length])
    }
}
