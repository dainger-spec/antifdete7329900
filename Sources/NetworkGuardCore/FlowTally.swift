import Foundation
import TunnelCore

/// Every new flow the filter is given, counted — held or not — so that "no flow came" and "flows
/// came, none of them a held process's" read differently, in the guard's own log and in what the app
/// asks of it (`NetworkGuardControl.diagnostics`). On the owner's Mac, 3 November, the check failed
/// with no line about any flow at all: a flow of a process the guard does not hold was let through
/// without a word, and so was one without the app's audit token, or with one that did not read.
///
/// Names and counts only, never an address — but for flows to the documentation network 203.0.113.0/24
/// (TEST-NET-3, never routed on the Internet), where the guard's check sends its probe and the
/// diagnosis its own control: those are kept one by one, with whom macOS counts each for.
public final class FlowTally: @unchecked Sendable {
    /// Why a flow was let through untouched, or that it was a held process's.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The source application is a process the guard holds.
        case held
        /// The source application is another process (anything else on this Mac).
        case notHeld
        /// The system gave no source application's audit token.
        case noAppToken
        /// A token that does not read as an audit token (not 32 bytes).
        case unreadableToken
        /// Not a socket flow.
        case notSocket
    }

    /// A name and how many flows it had.
    public struct Count: Codable, Equatable, Sendable {
        public var name: String
        public var flows: Int
    }

    /// A flow to TEST-NET-3: where it went, whom macOS counts it for, who opened it, what was done.
    public struct CheckFlow: Codable, Equatable, Sendable, CustomStringConvertible {
        public var at: Date
        public var transport: GuardTransport
        public var remote: String
        public var kind: Kind
        /// The source application, as its audit token says (nil without one), and its name.
        public var appPID: Int32?
        public var appName: String
        /// The source application's signing identifier, as the system gives it (`sourceAppIdentifier`).
        public var appIdentifier: String?
        /// The process that opened the socket (`sourceProcessAuditToken`), and its name.
        public var openerPID: Int32?
        public var openerName: String
        /// "allow", "drop", "inspectDNS".
        public var verdict: String

        public init(at: Date, transport: GuardTransport, remote: String, kind: Kind, appPID: Int32?, appName: String,
                    appIdentifier: String?, openerPID: Int32?, openerName: String, verdict: String) {
            self.at = at
            self.transport = transport
            self.remote = remote
            self.kind = kind
            self.appPID = appPID
            self.appName = appName
            self.appIdentifier = appIdentifier
            self.openerPID = openerPID
            self.openerName = openerName
            self.verdict = verdict
        }

        /// The guard's log line for it: "udp 203.0.113.1:3478, counted for com.apple.WebKit.Networking
        /// (pid 321), opened by com.apple.WebKit.Networking (pid 321): notHeld, allow". Only flows to the
        /// documentation network are ever kept, so nothing in it is an address of anyone's.
        public var description: String {
            func who(_ name: String, _ pid: Int32?) -> String { "\(name) (pid \(pid.map(String.init) ?? "none"))" }
            return "\(transport.rawValue) \(remote), counted for \(who(appName, appPID))"
                + (appIdentifier.map { ", signed as \($0)" } ?? "")
                + ", opened by \(who(openerName, openerPID)): \(kind.rawValue), \(verdict)"
        }
    }

    /// What the guard's log says of one window's flows: the counts, and apart from them the names of
    /// the processes whose flows were let through — which are this Mac's apps, so the log keeps them
    /// private (the diagnosis reads them over XPC instead).
    public struct WindowSummary: Equatable, Sendable {
        /// "flows in the last 5 s: 4 — 2 let through as another process's; 1 of held processes; …"
        public var counts: String
        /// " — let through, by name: com.apple.WebKit.Networking 2", or empty when none was.
        public var names: String
    }

    /// Everything counted since the guard started (its extension's process: `since`).
    public struct Snapshot: Codable, Equatable, Sendable {
        public var since: Date
        public var total: Int
        public var byKind: [String: Int]
        /// Flows let through as another process's, by the source application's name — the most first.
        public var notHeldByApp: [Count]
        /// Every flow by the process that opened it — the most first.
        public var byOpener: [Count]
        public var firstFlowAt: Date?
        public var lastFlowAt: Date?
        /// The last flows to TEST-NET-3, oldest first.
        public var checkFlows: [CheckFlow]

        public func count(_ kind: Kind) -> Int { byKind[kind.rawValue] ?? 0 }
    }

    public static let checkFlowLimit = 64
    public static let namesKept = 16

    private let lock = NSLock()
    private let since: Date
    private var total = 0
    private var byKind: [Kind: Int] = [:]
    private var notHeldByApp: [String: Int] = [:]
    private var byOpener: [String: Int] = [:]
    private var firstFlowAt: Date?
    private var lastFlowAt: Date?
    private var checkFlows: [CheckFlow] = []
    // The window since the last summary line.
    private var windowTotal = 0
    private var windowByKind: [Kind: Int] = [:]
    private var windowNotHeldByApp: [String: Int] = [:]
    private var windowStart: Date

    public init(since: Date = Date()) {
        self.since = since
        windowStart = since
    }

    /// Whether `address` is in TEST-NET-3 (RFC 5737), where the check and the diagnosis send.
    public static func isCheckAddress(_ address: String?) -> Bool {
        guard let address, let ip = IPAddr(address), ip.family == .v4 else { return false }
        return ip.bytes[0] == 203 && ip.bytes[1] == 0 && ip.bytes[2] == 113
    }

    /// One flow. `remoteAddress` is looked at only to tell a flow to TEST-NET-3, which is kept and
    /// returned (for the guard's log); nil for any other.
    @discardableResult
    public func record(_ kind: Kind, at: Date = Date(), appPID: Int32?, appName: String, appIdentifier: String?,
                       openerPID: Int32?, openerName: String, transport: GuardTransport, remoteAddress: String?,
                       remotePort: UInt16?, verdict: String) -> CheckFlow? {
        lock.lock()
        defer { lock.unlock() }
        total += 1
        byKind[kind, default: 0] += 1
        byOpener[openerName, default: 0] += 1
        if kind == .notHeld { notHeldByApp[appName, default: 0] += 1 }
        if firstFlowAt == nil { firstFlowAt = at }
        lastFlowAt = at
        windowTotal += 1
        windowByKind[kind, default: 0] += 1
        if kind == .notHeld { windowNotHeldByApp[appName, default: 0] += 1 }
        // The names' tables are kept small: a long-running Mac sees many processes.
        if byOpener.count > 256 { byOpener = Self.top(byOpener, 128) }
        if notHeldByApp.count > 256 { notHeldByApp = Self.top(notHeldByApp, 128) }
        guard Self.isCheckAddress(remoteAddress), let remoteAddress else { return nil }
        let check = CheckFlow(at: at, transport: transport, remote: remotePort.map { "\(remoteAddress):\($0)" } ?? remoteAddress,
                              kind: kind, appPID: appPID, appName: appName, appIdentifier: appIdentifier,
                              openerPID: openerPID, openerName: openerName, verdict: verdict)
        checkFlows.append(check)
        if checkFlows.count > Self.checkFlowLimit { checkFlows.removeFirst(checkFlows.count - Self.checkFlowLimit) }
        return check
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(since: since, total: total,
                        byKind: Dictionary(uniqueKeysWithValues: byKind.map { ($0.key.rawValue, $0.value) }),
                        notHeldByApp: Self.ranked(notHeldByApp), byOpener: Self.ranked(byOpener),
                        firstFlowAt: firstFlowAt, lastFlowAt: lastFlowAt, checkFlows: checkFlows)
    }

    /// The guard's log line for the flows since the last one, and a new window; nil when none came.
    public func windowSummary(now: Date = Date()) -> WindowSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard windowTotal > 0 else {
            windowStart = now
            return nil
        }
        let seconds = max(1, Int(now.timeIntervalSince(windowStart).rounded()))
        let names = Self.ranked(windowNotHeldByApp).prefix(6).map { "\($0.name) \($0.flows)" }.joined(separator: ", ")
        var parts = ["\(windowByKind[.notHeld] ?? 0) let through as another process's", "\(windowByKind[.held] ?? 0) of held processes"]
        if let none = windowByKind[.noAppToken] { parts.append("\(none) without the app's audit token") }
        if let unreadable = windowByKind[.unreadableToken] { parts.append("\(unreadable) with a token that does not read") }
        if let other = windowByKind[.notSocket] { parts.append("\(other) not socket flows") }
        let summary = WindowSummary(counts: "flows in the last \(seconds) s: \(windowTotal) — " + parts.joined(separator: "; "),
                                    names: names.isEmpty ? "" : " — let through, by name: \(names)")
        windowTotal = 0
        windowByKind = [:]
        windowNotHeldByApp = [:]
        windowStart = now
        return summary
    }

    private static func ranked(_ counts: [String: Int]) -> [Count] {
        counts.map { Count(name: $0.key, flows: $0.value) }
            .sorted { $0.flows != $1.flows ? $0.flows > $1.flows : $0.name < $1.name }
            .prefix(namesKept).map { $0 }
    }

    private static func top(_ counts: [String: Int], _ keep: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(keep).map { ($0.key, $0.value) })
    }
}

/// What the guard answers to `NetworkGuardControl.diagnostics`: its version, whether its filter
/// runs, the processes it holds, and every flow it was given, counted (`FlowTally`).
public struct GuardDiagnostics: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public var format: Int
    public var version: String
    public var filterRunning: Bool
    public var heldPIDs: [Int32]
    public var flows: FlowTally.Snapshot

    public init(version: String, filterRunning: Bool, heldPIDs: [Int32], flows: FlowTally.Snapshot) {
        format = Self.currentFormat
        self.version = version
        self.filterRunning = filterRunning
        self.heldPIDs = heldPIDs
        self.flows = flows
    }
}
