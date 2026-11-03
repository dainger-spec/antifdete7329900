import Foundation
import XCTest
@testable import NetworkGuardCore

/// The filter's count of every flow it is given (FlowTally): what tells "no flow came" from "flows
/// came, none a held process's" — the owner's Mac, 3 November, where the log said neither.
final class FlowTallyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_700_000)

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @discardableResult
    private func flow(_ tally: FlowTally, _ kind: FlowTally.Kind, app: String, appPID: Int32? = 100, opener: String? = nil,
                      to address: String? = "17.253.144.10", port: UInt16? = 443, transport: GuardTransport = .tcp,
                      verdict: String = "allow", at seconds: Double = 1) -> FlowTally.CheckFlow? {
        tally.record(kind, at: at(seconds), appPID: appPID, appName: app, appIdentifier: nil, openerPID: appPID,
                     openerName: opener ?? app, transport: transport, remoteAddress: address, remotePort: port, verdict: verdict)
    }

    func testEveryFlowIsCountedByKindAndTheProcessesNamedWithoutAnAddress() throws {
        let tally = FlowTally(since: start)
        for _ in 0..<3 { flow(tally, .notHeld, app: "com.apple.WebKit.Networking") }
        flow(tally, .notHeld, app: "mDNSResponder", at: 2)
        flow(tally, .held, app: "LumenProfile", opener: "com.apple.WebKit.Networking", verdict: "drop", at: 3)
        flow(tally, .noAppToken, app: "?", appPID: nil, opener: "nsurlsessiond", at: 4)
        flow(tally, .unreadableToken, app: "?", appPID: nil, at: 5)
        let snapshot = tally.snapshot()
        XCTAssertEqual(snapshot.total, 7)
        XCTAssertEqual(snapshot.count(.notHeld), 4)
        XCTAssertEqual(snapshot.count(.held), 1)
        XCTAssertEqual(snapshot.count(.noAppToken), 1)
        XCTAssertEqual(snapshot.count(.unreadableToken), 1)
        XCTAssertEqual(snapshot.count(.notSocket), 0)
        XCTAssertEqual(snapshot.notHeldByApp, [.init(name: "com.apple.WebKit.Networking", flows: 3), .init(name: "mDNSResponder", flows: 1)])
        XCTAssertEqual(snapshot.byOpener.first, .init(name: "com.apple.WebKit.Networking", flows: 4))
        XCTAssertEqual(snapshot.firstFlowAt, at(1))
        XCTAssertEqual(snapshot.lastFlowAt, at(5))
        XCTAssertTrue(snapshot.checkFlows.isEmpty, "no flow went to the documentation network")
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("17.253.144.10"), "no address of any other flow is kept")
    }

    func testAFlowToTheCheckNetworkIsKeptWithWhomItIsCountedFor() {
        let tally = FlowTally(since: start)
        XCTAssertNil(flow(tally, .notHeld, app: "Safari", to: "198.51.100.1"), "TEST-NET-2 is not the check's")
        XCTAssertNil(flow(tally, .notHeld, app: "Safari", to: "2001:db8::1"))
        XCTAssertNil(flow(tally, .notHeld, app: "Safari", to: nil))
        let check = flow(tally, .notHeld, app: "com.apple.WebKit.Networking", appPID: 321, opener: "com.apple.WebKit.Networking",
                         to: GuardProof.stunAddress, port: GuardProof.stunPort, transport: .udp, at: 6)
        XCTAssertEqual(check?.remote, "203.0.113.1:3478")
        XCTAssertEqual(check?.description, "udp 203.0.113.1:3478, counted for com.apple.WebKit.Networking (pid 321), "
                       + "opened by com.apple.WebKit.Networking (pid 321): notHeld, allow")
        XCTAssertEqual(check?.kind, .notHeld)
        XCTAssertEqual(check?.appPID, 321)
        XCTAssertEqual(check?.transport, .udp)
        XCTAssertEqual(tally.snapshot().checkFlows, [check].compactMap { $0 })
        XCTAssertTrue(FlowTally.isCheckAddress("203.0.113.2"))
        XCTAssertFalse(FlowTally.isCheckAddress("203.0.114.1"))
        XCTAssertFalse(FlowTally.isCheckAddress("not an address"))
    }

    func testTheCheckFlowsKeptAreTheLastOnes() {
        let tally = FlowTally(since: start)
        for index in 0..<(FlowTally.checkFlowLimit + 10) {
            flow(tally, .notHeld, app: "probe \(index)", to: "203.0.113.9", port: 9, transport: .udp, at: Double(index))
        }
        let kept = tally.snapshot().checkFlows
        XCTAssertEqual(kept.count, FlowTally.checkFlowLimit)
        XCTAssertEqual(kept.first?.appName, "probe 10")
        XCTAssertEqual(kept.last?.appName, "probe \(FlowTally.checkFlowLimit + 9)")
    }

    func testTheLogLineSaysWhatCameInItsWindowAndNothingWhenNothingDid() {
        let tally = FlowTally(since: start)
        XCTAssertNil(tally.windowSummary(now: at(5)), "no flow, no line")
        for _ in 0..<2 { flow(tally, .notHeld, app: "com.apple.WebKit.Networking", at: 6) }
        flow(tally, .held, app: "LumenProfile", verdict: "drop", at: 7)
        flow(tally, .noAppToken, app: "?", appPID: nil, at: 8)
        let line = tally.windowSummary(now: at(10))
        XCTAssertEqual(line?.counts, "flows in the last 5 s: 4 — 2 let through as another process's; 1 of held processes; "
                       + "1 without the app's audit token")
        XCTAssertEqual(line?.names, " — let through, by name: com.apple.WebKit.Networking 2")
        XCTAssertFalse(line?.counts.contains("WebKit") ?? true, "no name among the counts the log keeps in clear")
        XCTAssertNil(tally.windowSummary(now: at(15)), "the window starts again empty")
        flow(tally, .notSocket, app: "?", appPID: nil, at: 16)
        XCTAssertEqual(tally.windowSummary(now: at(20)),
                       .init(counts: "flows in the last 5 s: 1 — 0 let through as another process's; 0 of held processes; 1 not socket flows",
                             names: ""))
        XCTAssertEqual(tally.snapshot().total, 5, "the windows do not take from the whole")
    }

    func testTheDiagnosticsReadBackAsTheyWereWritten() throws {
        let tally = FlowTally(since: start)
        flow(tally, .held, app: "LumenProfile", appPID: 77, to: "203.0.113.1", port: 3478, transport: .udp, verdict: "drop")
        let diagnostics = GuardDiagnostics(version: "20261103.132616", filterRunning: true, heldPIDs: [77], flows: tally.snapshot())
        let decoded = try JSONDecoder().decode(GuardDiagnostics.self, from: JSONEncoder().encode(diagnostics))
        XCTAssertEqual(decoded, diagnostics)
        XCTAssertEqual(decoded.format, GuardDiagnostics.currentFormat)
        XCTAssertEqual(decoded.flows.checkFlows.first?.verdict, "drop")
    }
}
