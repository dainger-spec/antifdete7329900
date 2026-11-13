import XCTest
@testable import VMNetCore

/// A guest written out by hand: the test sends the segments a guest's TCP would, with the clock
/// in its own hands, and looks at every segment the connection sends back.
private final class Script {
    let sink = CollectingSink()
    let scratch = FrameScratch()
    private(set) var connection: TCPConnection!
    let remote = VMNetIPv4(string: "198.18.0.1")!
    let guestPort: UInt16 = 50_000
    var now = 100.0
    /// The guest's next sequence number, and what it expects from the stack next.
    var guestNext: UInt32
    var stackNext: UInt32 = 0
    let stackStart: UInt32

    init(guestStart: UInt32 = 1_000, stackStart: UInt32 = 5_000) {
        guestNext = guestStart
        self.stackStart = stackStart
    }

    /// The guest's SYN arrives. Nothing is answered yet.
    func open(mss: UInt16? = 1460, scale: UInt8? = 7, window: UInt16 = 65_535, tuning: TCPConnection.Tuning = TCPConnection.Tuning()) {
        let syn = Wire.tcp(from: guestPort, to: remote, 443, sequence: guestNext, flags: [.syn], window: window,
                           options: Wire.synOptions(mss: mss, scale: scale))
        let key = FlowKey(guestAddress: Wire.guest.value, guestPort: guestPort, remoteAddress: remote.value, remotePort: 443)
        Wire.withSegment(syn) { _, segment in
            connection = TCPConnection(key: key, guestMAC: Wire.guestMAC, gatewayMAC: Wire.gatewayMAC, mtu: 1500, syn: segment, now: now,
                                       tuning: tuning, scratch: scratch, sink: sink, initialSequence: stackStart)
        }
        guestNext = guestNext &+ 1
    }

    /// The tunnel comes up and the guest completes the handshake.
    func establish(window: UInt16 = 512) {
        connection.tunnelEstablished(now: now)
        _ = take()
        stackNext = stackStart &+ 1
        send(window: window)
    }

    func openAndEstablish(mss: UInt16? = 1460, scale: UInt8? = 7, window: UInt16 = 512, tuning: TCPConnection.Tuning = TCPConnection.Tuning()) {
        open(mss: mss, scale: scale, tuning: tuning)
        establish(window: window)
    }

    /// A segment from the guest. By default a bare acknowledgement of everything received, with
    /// a window of 512 << 7 = 64 KiB.
    func send(_ flags: TCPFlags = [.ack], sequence: UInt32? = nil, acknowledgement: UInt32? = nil, window: UInt16 = 512, payload: [UInt8] = []) {
        let frame = Wire.tcp(from: guestPort, to: remote, 443, sequence: sequence ?? guestNext, acknowledgement: acknowledgement ?? stackNext,
                             flags: flags, window: window, payload: payload)
        Wire.withSegment(frame) { _, segment in connection.receive(segment, now: now) }
    }

    /// Data from the guest, in order, and the guest's sequence number moved on.
    func sendData(_ payload: [UInt8], fin: Bool = false) {
        send(fin ? [.ack, .psh, .fin] : [.ack, .psh], payload: payload)
        guestNext = guestNext &+ UInt32(payload.count) &+ (fin ? 1 : 0)
    }

    /// What the connection sent since the last look.
    func take() -> [SeenTCP] {
        sink.take().map { Wire.seenTCP($0)! }
    }

    /// Takes the segments sent, checks they carry `expected` in order starting at what the guest
    /// expects next, and acknowledges them.
    @discardableResult
    func receiveInOrder(_ expected: [UInt8], acknowledge: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> [SeenTCP] {
        let segments = take()
        var data: [UInt8] = []
        var next = stackNext
        for segment in segments where !segment.payload.isEmpty {
            XCTAssertEqual(segment.sequence, next, "segment out of place", file: file, line: line)
            XCTAssertTrue(segment.checksumValid, file: file, line: line)
            data += segment.payload
            next = next &+ UInt32(segment.payload.count)
        }
        XCTAssertEqual(data.count, expected.count, file: file, line: line)
        XCTAssertTrue(data == expected, "the bytes differ", file: file, line: line)
        if acknowledge {
            stackNext = next
            send()
        }
        return segments
    }

    func upstream(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { connection.upstreamData($0, now: now) }
    }

    /// What the guest sent that waits for the proxy; taken out as the proxy's socket would.
    func drainToUpstream() -> [UInt8] {
        let bytes = connection.withUpstreamBacklog { Array($0) }
        connection.upstreamConsumed(bytes.count, now: now)
        return bytes
    }

    func advance(_ seconds: Double) {
        now += seconds
        connection.timerFired(now: now)
    }
}

final class TCPConnectionTests: XCTestCase {
    private func bytes(_ count: Int, seed: UInt64 = 42) -> [UInt8] {
        var random = TestRandom(seed: seed)
        return random.bytes(count)
    }

    // MARK: - Opening

    func testTheGuestHearsNothingUntilTheTunnelIsUp() {
        let script = Script()
        script.open()
        XCTAssertEqual(script.connection.state, .connecting)
        XCTAssertTrue(script.take().isEmpty)
        // The guest's SYN again, a second later: still nothing.
        script.now += 1
        script.send([.syn], sequence: 1_000, acknowledgement: 0, window: 65_535)
        XCTAssertTrue(script.take().isEmpty)
        XCTAssertNil(script.connection.nextDeadline)

        script.connection.tunnelEstablished(now: script.now)
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        let synAck = sent[0]
        XCTAssertEqual(synAck.flags, [.syn, .ack])
        XCTAssertEqual(synAck.sequence, 5_000)
        XCTAssertEqual(synAck.acknowledgement, 1_001)
        XCTAssertEqual(synAck.maximumSegmentSize, 1460)
        XCTAssertEqual(synAck.windowScale, 3)
        XCTAssertEqual(synAck.window, 65_535)
        XCTAssertTrue(synAck.checksumValid)
        XCTAssertEqual(synAck.source, script.remote)
        XCTAssertEqual(synAck.sourcePort, 443)
        XCTAssertEqual(synAck.destination, Wire.guest)
        XCTAssertEqual(synAck.destinationPort, 50_000)
        XCTAssertEqual(script.connection.state, .synAckSent)

        script.stackNext = 5_001
        script.send()
        XCTAssertEqual(script.connection.state, .established)
        XCTAssertTrue(script.take().isEmpty)
    }

    func testARefusedTunnelResetsTheGuestsSYN() {
        let script = Script()
        script.open()
        script.connection.tunnelFailed(now: script.now)
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].flags, [.rst, .ack])
        XCTAssertEqual(sent[0].sequence, 0)
        XCTAssertEqual(sent[0].acknowledgement, 1_001)
        XCTAssertTrue(sent[0].checksumValid)
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .refused)
        XCTAssertNil(script.connection.lingerUntil)
        // Whatever comes later gets no answer from a connection that is gone.
        script.send([.syn], sequence: 1_000, acknowledgement: 0)
        script.connection.tunnelEstablished(now: script.now)
        XCTAssertTrue(script.take().isEmpty)
    }

    func testTheSynAckIsSentAgainAndGivenUpOn() {
        let script = Script()
        script.open()
        script.connection.tunnelEstablished(now: script.now)
        XCTAssertEqual(script.take().count, 1)
        // The guest's SYN again (the SYN-ACK was lost): it is answered again.
        script.send([.syn], sequence: 1_000, acknowledgement: 0)
        XCTAssertEqual(script.take().map(\.flags), [[.syn, .ack]])
        // Nothing from the guest: again after 1 s, 2 s, 4 s, 8 s, then a reset.
        script.advance(0.9)
        XCTAssertTrue(script.take().isEmpty)
        var waits: [Double] = []
        var last = script.now
        while script.connection.state == .synAckSent {
            let deadline = script.connection.nextDeadline!
            script.now = deadline
            script.connection.timerFired(now: deadline)
            let sent = script.take()
            XCTAssertEqual(sent.count, 1)
            if sent[0].flags == [.syn, .ack] {
                XCTAssertEqual(sent[0].sequence, 5_000)
                waits.append(deadline - last)
                last = deadline
            } else {
                XCTAssertEqual(sent[0].flags, [.rst, .ack])
            }
        }
        XCTAssertEqual(waits.count, 4)
        XCTAssertEqual(waits[1], 2, accuracy: 0.001)
        XCTAssertEqual(waits[3], 8, accuracy: 0.001)
        XCTAssertEqual(script.connection.ending, .timedOut)
    }

    func testAnAcknowledgementOfSomethingElseDoesNotOpenTheConnection() {
        let script = Script()
        script.open()
        script.connection.tunnelEstablished(now: script.now)
        _ = script.take()
        script.send(acknowledgement: 9_999)
        let sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.rst]])
        XCTAssertEqual(sent[0].sequence, 9_999)
        XCTAssertEqual(script.connection.state, .synAckSent)
    }

    func testWithoutWindowScalingFromTheGuestNoneIsUsed() {
        let script = Script()
        script.open(mss: 1200, scale: nil)
        script.connection.tunnelEstablished(now: script.now)
        let synAck = script.take()[0]
        XCTAssertNil(synAck.windowScale)
        XCTAssertEqual(synAck.maximumSegmentSize, 1460)
        script.stackNext = 5_001
        script.send(window: 4_000)
        // The guest's window is 4000 bytes as written, and segments are the guest's 1200 at most.
        script.upstream(bytes(10_000))
        let sent = script.take()
        XCTAssertEqual(sent.map(\.payload.count), [1200, 1200, 1200])
        // The stack's own window is told unscaled: the most 16 bits can say.
        XCTAssertEqual(sent[0].window, 65_535)
    }

    func testAGuestWithoutASegmentSizeGetsTheDefault() {
        let script = Script()
        script.openAndEstablish(mss: nil)
        script.upstream(bytes(2_000))
        XCTAssertEqual(script.take().map(\.payload.count), [536, 536, 536, 392])
    }

    func testTheGuestsScaledWindowIsHonoured() {
        let script = Script()
        // 16 << 7 = 2048 bytes of window.
        script.openAndEstablish(window: 16)
        script.upstream(bytes(10_000))
        // One whole segment fits. The 588 bytes of window left are not filled with a short
        // segment while the first is still out: its acknowledgement will move the window on.
        XCTAssertEqual(script.take().map(\.payload.count), [1460])
        script.stackNext = script.stackNext &+ 1460
        script.send(window: 16)
        let next = script.take()
        XCTAssertEqual(next.map(\.payload.count), [1460])
        // And the stack's own window is told in units of 8 bytes: 256 KiB is 32768 of them.
        XCTAssertEqual(next.first?.window, 32_768)
        // A window smaller than a segment, with nothing out, is used as far as it goes.
        script.stackNext = script.stackNext &+ 1460
        script.send(window: 4)
        XCTAssertEqual(script.take().map(\.payload.count), [512])
    }

    // MARK: - Data to the guest

    func testProxyDataReachesTheGuestInSegments() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(5_000)
        script.upstream(data)
        let segments = script.receiveInOrder(data)
        XCTAssertEqual(segments.map(\.payload.count), [1460, 1460, 1460, 620])
        // PSH on the last of the burst only; every segment acknowledges the guest.
        XCTAssertEqual(segments.map { $0.flags.contains(.psh) }, [false, false, false, true])
        XCTAssertTrue(segments.allSatisfy { $0.flags.contains(.ack) && $0.acknowledgement == 1_001 })
        XCTAssertEqual(segments.map(\.frameLength).max(), 1514)
        XCTAssertEqual(script.connection.takeDeliveredBytes(), 5_000)
        XCTAssertEqual(script.connection.takeDeliveredBytes(), 0)
        // Everything acknowledged: no timer is left but the idle one.
        XCTAssertEqual(script.connection.nextDeadline!, script.now + 7200, accuracy: 0.001)
    }

    func testTheSendBufferIsBoundedAndReopensAsTheGuestAcknowledges() {
        var tuning = TCPConnection.Tuning()
        tuning.sendBufferLimit = 8_000
        let script = Script()
        script.openAndEstablish(tuning: tuning)
        XCTAssertEqual(script.connection.upstreamRoom, 8_000)
        let data = bytes(8_000)
        script.upstream(data)
        XCTAssertEqual(script.connection.upstreamRoom, 0)
        script.receiveInOrder(data)
        XCTAssertEqual(script.connection.upstreamRoom, 8_000)
    }

    func testTheDefaultBuffersAre256KiB() {
        let script = Script()
        script.openAndEstablish()
        XCTAssertEqual(script.connection.upstreamRoom, 256 * 1024)
        XCTAssertEqual(script.connection.tuning.receiveBufferLimit, 256 * 1024)
    }

    func testALostSegmentIsSentAgainAfterTheTimeout() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(4_000)
        script.upstream(data)
        XCTAssertEqual(script.take().count, 3)
        // Nothing acknowledged. Just before a quarter of a second: nothing; at it: the first
        // segment again, alone.
        script.advance(0.24)
        XCTAssertTrue(script.take().isEmpty)
        script.advance(0.02)
        var sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].sequence, 5_001)
        XCTAssertEqual(sent[0].payload, Array(data[0..<1460]))
        XCTAssertEqual(script.connection.retransmissions, 1)
        // Still nothing: the wait doubles (0.5 s), then again (1 s).
        script.advance(0.49)
        XCTAssertTrue(script.take().isEmpty)
        script.advance(0.02)
        XCTAssertEqual(script.take().map(\.sequence), [5_001])
        script.advance(0.99)
        XCTAssertTrue(script.take().isEmpty)
        script.advance(0.02)
        XCTAssertEqual(script.take().map(\.sequence), [5_001])
        // The guest answers at last: the rest follows from the acknowledged byte on, in order.
        script.stackNext = 5_001 &+ 1460
        script.send()
        sent = script.take()
        XCTAssertEqual(sent.first?.sequence, 5_001 &+ 1460)
        script.sink.take().forEach { _ in }
        var received = Array(data[0..<1460])
        for segment in sent { received += segment.payload }
        script.stackNext = 5_001 &+ UInt32(received.count)
        script.send()
        for segment in script.take() { received += segment.payload }
        XCTAssertEqual(received, data)
    }

    func testTheRetransmissionWaitStopsDoublingAtItsMaximum() {
        let script = Script()
        script.openAndEstablish()
        script.upstream(bytes(100))
        _ = script.take()
        var waits: [Double] = []
        var last = script.now
        for _ in 0..<12 {
            let deadline = script.connection.nextDeadline!
            // The guest still says it is there (a keepalive), so the connection is not given up.
            script.now = deadline - 0.001
            script.send(sequence: script.guestNext &- 1)
            _ = script.take()
            script.now = deadline
            script.connection.timerFired(now: deadline)
            XCTAssertEqual(script.take().count, 1)
            waits.append(deadline - last)
            last = deadline
        }
        XCTAssertEqual(waits[0], 0.25, accuracy: 0.01)
        XCTAssertEqual(waits[1], 0.5, accuracy: 0.01)
        XCTAssertEqual(waits[7], 30, accuracy: 0.01)
        XCTAssertEqual(waits[11], 30, accuracy: 0.01)
        XCTAssertEqual(script.connection.state, .established)
    }

    func testThreeDuplicateAcknowledgementsSendTheMissingSegmentAtOnce() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(1460 * 8)
        script.upstream(data)
        XCTAssertEqual(script.take().count, 8)
        // The guest got the first segment and then the third, fourth and fifth: it acknowledges
        // the first, three more times.
        script.stackNext = 5_001 &+ 1460
        script.send()
        XCTAssertTrue(script.take().isEmpty)
        script.send()
        script.send()
        XCTAssertTrue(script.take().isEmpty)
        script.send()
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].sequence, 5_001 &+ 1460)
        XCTAssertEqual(sent[0].payload, Array(data[1460..<2920]))
        // More duplicates do not send it again.
        script.send()
        script.send()
        XCTAssertTrue(script.take().isEmpty)
        // The guest now has everything up to the sixth segment, which was lost too: that
        // acknowledgement sends the sixth without another wait.
        script.stackNext = 5_001 &+ 1460 * 5
        script.send()
        let next = script.take()
        XCTAssertEqual(next.first?.sequence, 5_001 &+ 1460 * 5)
        // Everything acknowledged: nothing more to send.
        script.stackNext = 5_001 &+ 1460 * 8
        script.send()
        XCTAssertTrue(script.take().isEmpty)
        XCTAssertEqual(script.connection.takeDeliveredBytes(), UInt64(data.count))
    }

    func testAWindowUpdateIsNotADuplicateAcknowledgement() {
        let script = Script()
        script.openAndEstablish(window: 16)
        script.upstream(bytes(20_000))
        XCTAssertEqual(script.take().count, 1)
        // The same acknowledgement three times, each with a larger window: more data, no retransmission.
        for window in [32, 64, 128] as [UInt16] {
            script.send(window: window)
        }
        let sent = script.take()
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0.sequence != 5_001 })
        XCTAssertEqual(script.connection.retransmissions, 0)
    }

    func testAGuestThatShutsItsWindowIsAskedAgainUntilItOpens() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(3_000)
        script.upstream(Array(data[0..<1_000]))
        script.receiveInOrder(Array(data[0..<1_000]), acknowledge: false)
        // The guest takes the bytes and shuts its window.
        script.stackNext = 5_001 &+ 1_000
        script.send(window: 0)
        script.upstream(Array(data[1_000...]))
        XCTAssertTrue(script.take().isEmpty)
        // Half a second later a probe: nothing new in it, from just before what the guest expects.
        script.advance(0.49)
        XCTAssertTrue(script.take().isEmpty)
        script.advance(0.02)
        var sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].payload, [])
        XCTAssertEqual(sent[0].sequence, 5_001 &+ 999)
        // The guest still says zero: the next probe comes after twice as long.
        script.send(window: 0)
        script.advance(0.99)
        XCTAssertTrue(script.take().isEmpty)
        script.advance(0.02)
        XCTAssertEqual(script.take().count, 1)
        // The probes go on, no more than five seconds apart, for as long as the guest answers.
        for _ in 0..<50 {
            script.send(window: 0)
            let deadline = script.connection.nextDeadline!
            XCTAssertLessThanOrEqual(deadline - script.now, 5.001)
            script.now = deadline
            script.connection.timerFired(now: deadline)
            XCTAssertEqual(script.take().count, 1)
        }
        XCTAssertEqual(script.connection.state, .established)
        // The window opens: the data goes.
        script.send(window: 512)
        sent = script.receiveInOrder(Array(data[1_000...]))
        XCTAssertEqual(sent.count, 2)
    }

    func testAFullWireHoldsDataBackWithoutLosingIt() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(6_000)
        script.sink.isCongested = true
        script.upstream(data)
        XCTAssertTrue(script.take().isEmpty)
        // No timer runs for bytes that were never sent.
        XCTAssertEqual(script.connection.nextDeadline!, script.now + 7200, accuracy: 0.001)
        script.sink.isCongested = false
        script.connection.flush(now: script.now)
        script.receiveInOrder(data)
    }

    func testSendingStartsWithTenSegmentsAndGrowsWithAcknowledgements() {
        let script = Script()
        script.openAndEstablish(window: 2_000) // 2000 << 7: a window far larger than the data
        let data = bytes(200_000)
        script.upstream(data)
        var segments = script.take()
        XCTAssertEqual(segments.count, 10)
        var received: [UInt8] = []
        var rounds = 0
        while received.count < data.count && rounds < 50 {
            for segment in segments {
                XCTAssertEqual(segment.sequence, 5_001 &+ UInt32(received.count))
                received += segment.payload
            }
            script.stackNext = 5_001 &+ UInt32(received.count)
            script.send(window: 2_000)
            segments = script.take()
            rounds += 1
        }
        XCTAssertEqual(received, data)
        // Doubling each round: 10, 20, 40, 80 segments — 200 000 bytes in five rounds.
        XCTAssertLessThanOrEqual(rounds, 5)
    }

    // MARK: - Data from the guest

    func testGuestDataIsKeptInOrderForTheProxyAndAcknowledgedOnce() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(4_000)
        script.sendData(Array(data[0..<1460]))
        script.sendData(Array(data[1460..<2920]))
        script.sendData(Array(data[2920...]))
        // Three segments that came together are acknowledged together.
        XCTAssertTrue(script.take().isEmpty)
        script.connection.flush(now: script.now)
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].flags, [.ack])
        XCTAssertEqual(sent[0].acknowledgement, 1_001 &+ 4_000)
        XCTAssertEqual(sent[0].sequence, 5_001)
        XCTAssertEqual(script.connection.upstreamBacklog, 4_000)
        XCTAssertEqual(script.drainToUpstream(), data)
        XCTAssertEqual(script.connection.upstreamBacklog, 0)
    }

    func testDuplicateDataIsAcknowledgedAgainAndDiscarded() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(1_000)
        script.sendData(data)
        script.connection.flush(now: script.now)
        _ = script.take()
        // The same segment again (its acknowledgement was lost): answered at once, not kept twice.
        script.send([.ack, .psh], sequence: 1_001, payload: data)
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].acknowledgement, 2_001)
        XCTAssertEqual(script.connection.upstreamBacklog, 1_000)
        // A segment that overlaps: old bytes and new ones. Only the new ones are taken.
        let more = bytes(500, seed: 7)
        script.send([.ack, .psh], sequence: 1_501, payload: Array(data[500...]) + more)
        script.guestNext = 2_501
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().last?.acknowledgement, 2_501)
        XCTAssertEqual(script.drainToUpstream(), data + more)
    }

    func testDataAheadOfAGapIsKeptAndTheGapNamedAtOnce() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(5_000)
        // The first thousand bytes are lost; the next three segments arrive. Each is answered at
        // once with what is still expected — three such answers are what makes the guest send
        // the missing segment again — and nothing is handed to the proxy yet.
        for start in [1_000, 2_000, 3_000] {
            script.send([.ack], sequence: 1_001 &+ UInt32(start), payload: Array(data[start..<(start + 1_000)]))
            let sent = script.take()
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent[0].flags, [.ack])
            XCTAssertEqual(sent[0].acknowledgement, 1_001)
        }
        XCTAssertEqual(script.connection.upstreamBacklog, 0)
        XCTAssertEqual(script.connection.earlySegmentCount, 3)
        // The missing segment arrives: everything kept follows it, and one acknowledgement says so.
        script.send([.ack], sequence: 1_001, payload: Array(data[0..<1_000]))
        script.connection.flush(now: script.now)
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].acknowledgement, 1_001 &+ 4_000)
        XCTAssertEqual(script.connection.earlySegmentCount, 0)
        script.guestNext = 1_001 &+ 4_000
        script.sendData(Array(data[4_000...]))
        XCTAssertEqual(script.drainToUpstream(), data)
    }

    func testEarlySegmentsThatOverlapOrRepeatAreKeptOnce() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(10_000)
        func early(_ range: Range<Int>) {
            script.send([.ack], sequence: 1_001 &+ UInt32(range.lowerBound), payload: Array(data[range]))
            XCTAssertEqual(script.take().map(\.acknowledgement), [1_001])
        }
        early(4_000..<5_000)
        early(2_000..<3_000)
        early(4_000..<5_000)          // the same again
        early(2_500..<4_500)          // across two kept segments and the gap between them
        early(1_500..<2_200)          // into the front of one
        early(8_000..<9_000)
        early(7_500..<9_500)          // around one
        early(4_100..<4_200)          // inside one
        XCTAssertEqual(script.connection.upstreamBacklog, 0)
        // In order now: the first 1500 bytes. All that follows without a gap goes with them.
        script.send([.ack], sequence: 1_001, payload: Array(data[0..<1_500]))
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().last?.acknowledgement, 1_001 &+ 5_000)
        XCTAssertEqual(script.connection.withUpstreamBacklog { Array($0) }, Array(data[0..<5_000]))
        // The next gap, filled by a segment that also repeats old bytes and runs into kept ones.
        script.send([.ack], sequence: 1_001 &+ 4_900, payload: Array(data[4_900..<7_700]))
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().last?.acknowledgement, 1_001 &+ 9_500)
        XCTAssertEqual(script.connection.earlySegmentCount, 0)
        script.guestNext = 1_001 &+ 9_500
        script.sendData(Array(data[9_500...]))
        XCTAssertEqual(script.drainToUpstream(), data)
    }

    func testEarlyDataBeyondTheWindowIsNotKept() {
        var tuning = TCPConnection.Tuning()
        tuning.receiveBufferLimit = 4_096
        tuning.earlySegmentLimit = 3
        let script = Script()
        script.openAndEstablish(tuning: tuning)
        let data = bytes(8_000)
        // Wholly beyond the window: not kept. Partly: only the part inside.
        script.send([.ack], sequence: 1_001 &+ 5_000, payload: Array(data[5_000..<6_000]))
        XCTAssertEqual(script.connection.earlySegmentCount, 0)
        script.send([.ack], sequence: 1_001 &+ 3_500, payload: Array(data[3_500..<4_500]))
        XCTAssertEqual(script.connection.earlySegmentCount, 1)
        // No more segments are kept than the limit.
        for start in [500, 1_000, 1_500, 2_000] {
            script.send([.ack], sequence: 1_001 &+ UInt32(start), payload: Array(data[start..<(start + 100)]))
        }
        XCTAssertEqual(script.connection.earlySegmentCount, 3)
        _ = script.take()
        script.send([.ack], sequence: 1_001, payload: Array(data[0..<3_500]))
        script.connection.flush(now: script.now)
        // Up to the edge of the window and not a byte further.
        XCTAssertEqual(script.take().last?.acknowledgement, 1_001 &+ 4_096)
        XCTAssertEqual(script.connection.withUpstreamBacklog { Array($0) }, Array(data[0..<4_096]))
    }

    func testAFINAheadOfAGapIsNotTaken() {
        let script = Script()
        script.openAndEstablish()
        script.send([.ack, .fin], sequence: 1_001 &+ 100, payload: [7, 7, 7])
        XCTAssertEqual(script.take().map(\.acknowledgement), [1_001])
        XCTAssertFalse(script.connection.guestFinished)
        script.send([.ack], sequence: 1_001, payload: [UInt8](repeating: 1, count: 100))
        script.connection.flush(now: script.now)
        // The data that came with the early FIN counts; the FIN itself must come again.
        XCTAssertEqual(script.take().last?.acknowledgement, 1_001 &+ 103)
        XCTAssertFalse(script.connection.guestFinished)
        script.send([.ack, .fin], sequence: 1_001 &+ 103)
        XCTAssertTrue(script.connection.guestFinished)
    }

    /// Segments of one stream in any order, repeated, overlapping, of any size, while the proxy
    /// takes bytes at its own pace: what reaches the proxy is the stream, byte for byte.
    func testAnyOrderOfSegmentsGivesTheSameStream() {
        for seed in 1...20 as ClosedRange<UInt64> {
            var random = TestRandom(seed: seed)
            var tuning = TCPConnection.Tuning()
            tuning.receiveBufferLimit = 16_384
            let script = Script(guestStart: seed % 2 == 0 ? 0xFFFF_F000 : 1_000)
            script.openAndEstablish(tuning: tuning)
            let first = script.guestNext
            let data = bytes(60_000, seed: seed &+ 100)
            var delivered: [UInt8] = []
            var acknowledged = 0
            var steps = 0
            while delivered.count < data.count && steps < 200_000 {
                steps += 1
                // A segment from somewhere around what was acknowledged: before it, at it, ahead of it.
                let reach = Int(random.next() % 24_000) - 4_000
                let start = min(max(acknowledged + reach, 0), data.count - 1)
                let length = min(Int(random.next() % 1_460) + 1, data.count - start)
                script.send([.ack], sequence: first &+ UInt32(start), payload: Array(data[start..<(start + length)]))
                if random.next() % 3 == 0 {
                    let backlog = script.connection.upstreamBacklog
                    let amount = backlog == 0 ? 0 : Int(random.next() % UInt64(backlog)) + 1
                    delivered += script.connection.withUpstreamBacklog { Array($0.prefix(amount)) }
                    script.connection.upstreamConsumed(amount, now: script.now)
                }
                script.connection.flush(now: script.now)
                for segment in script.take() {
                    let value = Int(segment.acknowledgement &- first)
                    XCTAssertGreaterThanOrEqual(value, acknowledged, "an acknowledgement went backwards")
                    acknowledged = max(acknowledged, value)
                }
                // What was acknowledged is what was handed on or waits to be: never more, never less.
                XCTAssertEqual(acknowledged, delivered.count + script.connection.upstreamBacklog)
                XCTAssertLessThanOrEqual(script.connection.upstreamBacklog, 16_384)
            }
            XCTAssertEqual(delivered.count, data.count, "seed \(seed)")
            XCTAssertTrue(delivered == data, "the bytes differ with seed \(seed)")
        }
    }

    func testASlowProxyShutsTheGuestsWindowAndDrainingOpensIt() {
        var tuning = TCPConnection.Tuning()
        tuning.receiveBufferLimit = 8_192
        let script = Script()
        script.openAndEstablish(tuning: tuning)
        let data = bytes(10_000)
        // The proxy takes nothing. The guest sends until the window it was told is used up.
        var offset = 0
        var window = 8_192
        while window > 0 {
            let length = min(1024, window)
            script.sendData(Array(data[offset..<(offset + length)]))
            offset += length
            script.connection.flush(now: script.now)
            let ack = script.take().last!
            XCTAssertEqual(ack.acknowledgement, 1_001 &+ UInt32(offset))
            window = Int(ack.window) << 3
            XCTAssertEqual(window, 8_192 - offset)
        }
        XCTAssertEqual(offset, 8_192)
        XCTAssertEqual(script.connection.upstreamBacklog, 8_192)
        // A probe of the shut window: one byte, not taken, answered with "still shut".
        script.send([.ack], payload: [data[offset]])
        var sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].acknowledgement, 1_001 &+ 8_192)
        XCTAssertEqual(sent[0].window, 0)
        XCTAssertEqual(script.connection.upstreamBacklog, 8_192)
        // A segment larger than a window that is partly open: what fits is taken, the rest not.
        _ = script.connection.withUpstreamBacklog { $0.count }
        script.connection.upstreamConsumed(100, now: script.now)
        script.connection.flush(now: script.now)
        XCTAssertTrue(script.take().isEmpty, "a hundred bytes of room are not worth a window update")
        script.send([.ack], payload: Array(data[offset..<(offset + 1_000)]))
        sent = script.take()
        XCTAssertEqual(sent.last?.acknowledgement, 1_001 &+ 8_192 &+ 100)
        XCTAssertEqual(sent.last?.window, 0)
        offset += 100
        script.guestNext = 1_001 &+ UInt32(offset)
        // The proxy takes half: the guest is told the window is open again, unasked.
        script.connection.upstreamConsumed(4_096, now: script.now)
        script.connection.flush(now: script.now)
        sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(Int(sent[0].window) << 3, 4_096)
        XCTAssertEqual(sent[0].acknowledgement, 1_001 &+ UInt32(offset))
        // And the rest goes through.
        script.sendData(Array(data[offset...]))
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().last?.acknowledgement, 1_001 &+ 10_000)
        XCTAssertEqual(script.connection.upstreamBacklog, 10_000 - 4_196)
    }

    func testKeepaliveProbesAreAnswered() {
        let script = Script()
        script.openAndEstablish()
        script.sendData([1, 2, 3])
        script.connection.flush(now: script.now)
        _ = script.take()
        // The two forms a keepalive takes: nothing, or one old byte, from just before what was sent.
        script.send([.ack], sequence: script.guestNext &- 1)
        var sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].flags, [.ack])
        XCTAssertEqual(sent[0].acknowledgement, script.guestNext)
        script.send([.ack], sequence: script.guestNext &- 1, payload: [0])
        sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].acknowledgement, script.guestNext)
        XCTAssertEqual(script.connection.upstreamBacklog, 3)
        // A plain acknowledgement is not answered: two stacks must not thank each other forever.
        script.send()
        XCTAssertTrue(script.take().isEmpty)
    }

    func testAnAcknowledgementOfBytesNeverSentIsAnsweredAndIgnored() {
        let script = Script()
        script.openAndEstablish()
        script.send(acknowledgement: 5_001 &+ 10_000, payload: [1, 2, 3])
        let sent = script.take()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].sequence, 5_001)
        XCTAssertEqual(sent[0].acknowledgement, 1_001)
        XCTAssertEqual(script.connection.upstreamBacklog, 0)
    }

    // MARK: - Closing

    func testTheGuestClosesFirst() {
        let script = Script()
        script.openAndEstablish()
        let request = bytes(700)
        script.sendData(request, fin: true)
        XCTAssertTrue(script.connection.guestFinished)
        // The tunnel's sending side is closed only when all the guest sent is written.
        XCTAssertFalse(script.connection.shouldShutdownUpstream)
        XCTAssertEqual(script.drainToUpstream(), request)
        XCTAssertTrue(script.connection.shouldShutdownUpstream)
        script.connection.noteUpstreamShutdown()
        XCTAssertFalse(script.connection.shouldShutdownUpstream)
        script.connection.flush(now: script.now)
        var sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.ack]])
        XCTAssertEqual(sent[0].acknowledgement, 1_001 &+ 701)
        XCTAssertEqual(script.connection.state, .established)

        // The other direction still carries the answer; then the proxy closes too.
        let answer = bytes(3_000, seed: 9)
        script.upstream(answer)
        script.receiveInOrder(answer)
        script.connection.upstreamFinished(now: script.now)
        sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.fin, .ack]])
        XCTAssertEqual(sent[0].sequence, 5_001 &+ 3_000)
        XCTAssertEqual(script.connection.upstreamRoom, 0)
        script.stackNext = 5_001 &+ 3_001
        script.send()
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .finished)
        XCTAssertEqual(script.connection.lingerUntil!, script.now + 3, accuracy: 0.001)
        XCTAssertEqual(script.connection.nextDeadline, script.connection.lingerUntil)
        XCTAssertTrue(script.take().isEmpty)
    }

    func testTheProxyClosesFirst() {
        let script = Script()
        script.openAndEstablish()
        let answer = bytes(2_000)
        script.upstream(answer)
        script.connection.upstreamFinished(now: script.now)
        // The data, then the FIN after the last byte.
        let sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.ack], [.ack, .psh], [.fin, .ack]])
        XCTAssertEqual(sent[2].sequence, 5_001 &+ 2_000)
        script.stackNext = 5_001 &+ 2_001
        script.send()
        XCTAssertEqual(script.connection.state, .established)
        // The guest may go on sending.
        let more = bytes(500, seed: 3)
        script.sendData(more)
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().last?.acknowledgement, 1_001 &+ 500)
        XCTAssertEqual(script.drainToUpstream(), more)
        // Its FIN ends the connection, and is acknowledged.
        script.sendData([], fin: true)
        let last = script.take()
        XCTAssertEqual(last.map(\.flags), [[.ack]])
        XCTAssertEqual(last[0].acknowledgement, 1_001 &+ 501)
        XCTAssertEqual(last[0].sequence, 5_001 &+ 2_001)
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .finished)

        // The guest's FIN again (the answer to it was lost): answered again while it lingers.
        script.send([.ack, .fin], sequence: 1_001 &+ 500)
        let again = script.take()
        XCTAssertEqual(again.map(\.flags), [[.ack]])
        XCTAssertEqual(again[0].acknowledgement, 1_001 &+ 501)
        // A bare acknowledgement gets nothing.
        script.send(sequence: 1_001 &+ 501)
        XCTAssertTrue(script.take().isEmpty)
    }

    func testALostFINIsSentAgain() {
        let script = Script()
        script.openAndEstablish()
        script.upstream([1, 2, 3])
        script.receiveInOrder([1, 2, 3])
        script.connection.upstreamFinished(now: script.now)
        XCTAssertEqual(script.take().map(\.flags), [[.fin, .ack]])
        script.advance(0.26)
        let sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.fin, .ack]])
        XCTAssertEqual(sent[0].sequence, 5_001 &+ 3)
        script.stackNext = 5_001 &+ 4
        script.send()
        script.advance(10)
        XCTAssertTrue(script.take().isEmpty)
    }

    func testBothCloseAtOnce() {
        let script = Script()
        script.openAndEstablish()
        script.connection.upstreamFinished(now: script.now)
        XCTAssertEqual(script.take().map(\.flags), [[.fin, .ack]])
        // The guest's FIN crosses the stack's: it does not acknowledge it yet.
        script.sendData([], fin: true)
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().map(\.acknowledgement), [1_002])
        XCTAssertEqual(script.connection.state, .established)
        script.stackNext = 5_002
        script.send()
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .finished)
    }

    func testTheGuestResets() {
        let script = Script()
        script.openAndEstablish()
        script.upstream(bytes(100))
        _ = script.take()
        // A reset from outside the window is not believed.
        script.send([.rst], sequence: script.guestNext &- 5_000)
        XCTAssertEqual(script.connection.state, .established)
        script.send([.rst])
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .guestReset)
        XCTAssertNil(script.connection.lingerUntil)
        XCTAssertTrue(script.take().isEmpty)
        XCTAssertEqual(script.connection.upstreamRoom, 0)
    }

    func testTheGuestResetsWhileTheProxyIsStillBeingAsked() {
        let script = Script()
        script.open()
        script.send([.rst], acknowledgement: 0)
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .guestReset)
        script.connection.tunnelEstablished(now: script.now)
        XCTAssertTrue(script.take().isEmpty)
    }

    func testABrokenTunnelResetsTheGuest() {
        let script = Script()
        script.openAndEstablish()
        let data = bytes(2_000)
        script.upstream(data)
        script.receiveInOrder(data)
        script.sendData([9, 9, 9])
        script.connection.upstreamBroke(now: script.now)
        let sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.rst, .ack]])
        XCTAssertEqual(sent[0].sequence, 5_001 &+ 2_000)
        XCTAssertEqual(sent[0].acknowledgement, 1_001 &+ 3)
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .upstreamBroke)
        XCTAssertEqual(script.connection.upstreamBacklog, 0)
    }

    func testASYNOnALiveConnectionIsToldWhereTheConnectionIs() {
        let script = Script()
        script.openAndEstablish()
        script.send([.syn], sequence: 77_777, acknowledgement: 0)
        let sent = script.take()
        XCTAssertEqual(sent.map(\.flags), [[.ack]])
        XCTAssertEqual(sent[0].sequence, 5_001)
        XCTAssertEqual(sent[0].acknowledgement, 1_001)
        XCTAssertEqual(script.connection.state, .established)
    }

    func testAGuestThatGoesSilentIsGivenUpOn() {
        let script = Script()
        script.openAndEstablish()
        script.upstream(bytes(500))
        _ = script.take()
        var last = [SeenTCP]()
        var rounds = 0
        while script.connection.state == .established && rounds < 200 {
            script.now = script.connection.nextDeadline!
            script.connection.timerFired(now: script.now)
            last = script.take()
            rounds += 1
        }
        XCTAssertEqual(script.connection.ending, .timedOut)
        XCTAssertEqual(last.map(\.flags), [[.rst, .ack]])
        // Fifteen minutes of silence, give or take the last wait.
        XCTAssertGreaterThanOrEqual(script.now - 100, 900)
        XCTAssertLessThan(script.now - 100, 960)
    }

    func testAnIdleConnectionLastsTwoHours() {
        let script = Script()
        script.openAndEstablish()
        script.advance(7_199)
        XCTAssertEqual(script.connection.state, .established)
        XCTAssertTrue(script.take().isEmpty)
        // A keepalive from the guest counts as life.
        script.send(sequence: script.guestNext &- 1)
        _ = script.take()
        script.advance(7_199)
        XCTAssertEqual(script.connection.state, .established)
        script.advance(2)
        XCTAssertEqual(script.connection.state, .closed)
        XCTAssertEqual(script.connection.ending, .timedOut)
        XCTAssertEqual(script.take().map(\.flags), [[.rst, .ack]])
    }

    // MARK: - Sequence numbers that wrap

    func testSequenceNumbersWrapAround() {
        let script = Script(guestStart: 0xFFFF_FF00, stackStart: 0xFFFF_FE00)
        script.openAndEstablish()
        let down = bytes(5_000)
        script.upstream(down)
        script.receiveInOrder(down)
        let up = bytes(5_000, seed: 8)
        for start in stride(from: 0, to: 5_000, by: 1_000) {
            script.sendData(Array(up[start..<(start + 1_000)]))
        }
        script.connection.flush(now: script.now)
        XCTAssertEqual(script.take().last?.acknowledgement, 0xFFFF_FF01 &+ 5_000)
        XCTAssertEqual(script.drainToUpstream(), up)
        XCTAssertTrue(sequence(0xFFFF_FFF0, isBefore: 0x0000_0010))
        XCTAssertFalse(sequence(0x0000_0010, isBefore: 0xFFFF_FFF0))
        XCTAssertTrue(sequence(5, isAtOrBefore: 5))
    }

    // MARK: - A whole transfer over a wire that loses frames

    /// A megabyte to a guest over a wire that loses a share of the frames in both directions,
    /// with a guest that keeps what arrives early (as real ones do): every byte arrives, in
    /// order, and the transfer never stops for good.
    func testATransferSurvivesLossInBothDirections() {
        for (seed, loss) in [(1, 0.02), (2, 0.1), (3, 0.3)] as [(UInt64, Double)] {
            var random = TestRandom(seed: seed)
            let script = Script()
            script.openAndEstablish(window: 2_000)
            let data = bytes(1_000_000, seed: seed)
            var fed = 0
            var received: [UInt8] = []
            received.reserveCapacity(data.count)
            var early: [UInt32: [UInt8]] = [:]
            var finished = false
            var steps = 0
            while !(finished && script.connection.state == .closed) && steps < 2_000_000 {
                steps += 1
                // The proxy's bytes, as fast as the connection takes them; then its end.
                let room = min(script.connection.upstreamRoom, data.count - fed)
                if room > 0 {
                    script.upstream(Array(data[fed..<(fed + room)]))
                    fed += room
                } else if fed == data.count && script.connection.upstreamRoom > 0 {
                    script.connection.upstreamFinished(now: script.now)
                }
                let segments = script.take()
                if segments.isEmpty {
                    // Nothing on the wire: time passes until the connection's next timer.
                    guard let deadline = script.connection.nextDeadline else { break }
                    script.now = max(script.now + 0.001, deadline)
                    script.connection.timerFired(now: script.now)
                    continue
                }
                script.now += 0.0005
                var answers = 0
                for segment in segments {
                    if Double(random.next() % 10_000) / 10_000 < loss { continue }
                    XCTAssertTrue(segment.checksumValid)
                    let expected = 5_001 &+ UInt32(received.count) &+ (finished ? 1 : 0)
                    if segment.sequence == expected {
                        received += segment.payload
                        if segment.flags.contains(.fin) { finished = true }
                        // What arrived early and now fits.
                        while let next = early.removeValue(forKey: 5_001 &+ UInt32(received.count)) { received += next }
                    } else if sequence(expected, isBefore: segment.sequence), !segment.payload.isEmpty {
                        early[segment.sequence] = segment.payload
                    }
                    answers += 1
                }
                // One acknowledgement per segment that arrived, each of which may be lost too.
                script.stackNext = 5_001 &+ UInt32(received.count) &+ (finished ? 1 : 0)
                for _ in 0..<answers where Double(random.next() % 10_000) / 10_000 >= loss {
                    script.send(window: 2_000)
                }
                if finished && script.connection.state != .closed && !script.connection.guestFinished {
                    script.sendData([], fin: true)
                }
            }
            XCTAssertEqual(received.count, data.count, "loss \(loss)")
            XCTAssertTrue(received == data, "the bytes differ at loss \(loss)")
            XCTAssertTrue(finished, "loss \(loss)")
            XCTAssertEqual(script.connection.ending, .finished, "loss \(loss)")
            XCTAssertGreaterThan(script.connection.retransmissions, 0)
        }
    }

    /// The other direction: a guest that sends a megabyte and sends again whatever was not
    /// acknowledged, over the same kind of wire, to a proxy that takes bytes at its own pace.
    func testAnUploadSurvivesLossInBothDirections() {
        for (seed, loss) in [(4, 0.02), (5, 0.2)] as [(UInt64, Double)] {
            var random = TestRandom(seed: seed)
            var tuning = TCPConnection.Tuning()
            tuning.receiveBufferLimit = 32 * 1024
            let script = Script()
            script.openAndEstablish(tuning: tuning)
            let data = bytes(1_000_000, seed: seed)
            var delivered: [UInt8] = []
            delivered.reserveCapacity(data.count)
            var acknowledged = 0     // the guest's view: bytes the stack acknowledged
            var window = 32 * 1024   // and the window it was last told
            var next = 0             // the next byte the guest sends
            var steps = 0
            while delivered.count < data.count && steps < 2_000_000 {
                steps += 1
                // The guest sends what its window allows, in segments.
                var sentNow = 0
                while next < data.count && next - acknowledged < window && sentNow < 20 {
                    let length = min(1460, data.count - next, window - (next - acknowledged))
                    if Double(random.next() % 10_000) / 10_000 >= loss {
                        script.send([.ack], sequence: 1_001 &+ UInt32(next), payload: Array(data[next..<(next + length)]))
                    }
                    next += length
                    sentNow += 1
                }
                // The proxy takes some of what waits, not always all.
                let backlog = script.connection.upstreamBacklog
                if backlog > 0 {
                    let amount = max(1, Int(random.next() % UInt64(backlog + 1)))
                    delivered += script.connection.withUpstreamBacklog { Array($0.prefix(amount)) }
                    script.connection.upstreamConsumed(amount, now: script.now)
                }
                script.connection.flush(now: script.now)
                var progressed = false
                for segment in script.take() where Double(random.next() % 10_000) / 10_000 >= loss {
                    let value = Int(segment.acknowledgement &- 1_001)
                    if value > acknowledged {
                        acknowledged = value
                        progressed = true
                    }
                    if value == acknowledged {
                        if Int(segment.window) << 3 != window { progressed = true }
                        window = Int(segment.window) << 3
                    }
                }
                if !progressed && sentNow == 0 {
                    // The guest's own timer: go back to the last acknowledged byte (and, when the
                    // window is shut, probe it with one byte).
                    script.now += 0.2
                    next = acknowledged
                    if window == 0 && acknowledged < data.count {
                        script.send([.ack], sequence: 1_001 &+ UInt32(acknowledged), payload: [data[acknowledged]])
                    }
                }
            }
            XCTAssertEqual(delivered.count, data.count, "loss \(loss)")
            XCTAssertTrue(delivered == data, "the bytes differ at loss \(loss)")
        }
    }

    // MARK: - Resets for connections that are not there

    func testTheResetForASegmentWithoutAConnection() {
        let scratch = FrameScratch()
        // An acknowledgement: the reset takes its sequence number from it.
        var frame = Wire.tcp(from: 50_000, to: VMNetIPv4(string: "1.1.1.1")!, 443, sequence: 100, acknowledgement: 900, flags: [.ack], payload: [1, 2, 3])
        var reset = Wire.withSegment(frame) { packet, segment in
            Array(TCPConnection.resetFrame(answering: segment, from: packet.destination, to: packet.source,
                                           guestMAC: Wire.guestMAC, gatewayMAC: Wire.gatewayMAC, scratch: scratch))
        }
        var seen = Wire.seenTCP(reset)!
        XCTAssertEqual(seen.flags, [.rst])
        XCTAssertEqual(seen.sequence, 900)
        XCTAssertEqual(seen.source.string, "1.1.1.1")
        XCTAssertEqual(seen.sourcePort, 443)
        XCTAssertEqual(seen.destination, Wire.guest)
        XCTAssertEqual(seen.destinationPort, 50_000)
        XCTAssertTrue(seen.checksumValid)
        // A SYN: the reset acknowledges it.
        frame = Wire.tcp(from: 50_000, to: VMNetIPv4(string: "10.0.0.1")!, 80, sequence: 100, flags: [.syn])
        reset = Wire.withSegment(frame) { packet, segment in
            Array(TCPConnection.resetFrame(answering: segment, from: packet.destination, to: packet.source,
                                           guestMAC: Wire.guestMAC, gatewayMAC: Wire.gatewayMAC, scratch: scratch))
        }
        seen = Wire.seenTCP(reset)!
        XCTAssertEqual(seen.flags, [.rst, .ack])
        XCTAssertEqual(seen.sequence, 0)
        XCTAssertEqual(seen.acknowledgement, 101)
    }
}
