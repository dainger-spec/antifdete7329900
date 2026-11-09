import Foundation
import TunnelCore

// The network guard's rules (docs/TUNNEL.md), apart from the system extension that applies them:
// what a profile's process may reach while its WebRTC goes through its proxy. Platform-independent,
// so that every rule is tested on Linux and macOS alike; the extension (NetworkGuardExtension) only
// reads a flow's facts and turns these verdicts into the system's.
//
// A content filter can only let a flow through or drop it: nothing here can carry a byte anywhere.
// The worst a mistake in these rules can do is let through a flow that should have been dropped —
// and the relay-only policy of the page (the user script) still stands in front of that.

/// What the app tells the guard about one profile's process, when it starts with WebRTC through its
/// proxy (`NetworkGuardControl.hold`). Nothing in it is the person's but the proxy's address, which
/// the guard needs and keeps in memory only, for as long as the process lives.
public struct GuardRegistration: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public var format: Int
    /// The profile's own process. What WebKit's processes and the system's services do on its behalf
    /// is attributed to it (the flow's source application).
    public var pid: Int32
    /// The proxy's host as the profile has it — a name or an IP literal — lowercased, no final dot.
    public var proxyHost: String
    public var proxyPort: UInt16
    /// Every address the app found for the proxy's name (and the literal itself), canonical.
    public var proxyAddresses: [String]

    public init(pid: Int32, proxyHost: String, proxyPort: UInt16, proxyAddresses: [String]) {
        format = Self.currentFormat
        self.pid = pid
        self.proxyHost = GuardPolicy.normalizedName(proxyHost)
        self.proxyPort = proxyPort
        self.proxyAddresses = proxyAddresses.compactMap(GuardPolicy.canonicalAddress)
        if let literal = GuardPolicy.canonicalAddress(proxyHost), !self.proxyAddresses.contains(literal) {
            self.proxyAddresses.append(literal)
        }
    }
}

public enum GuardTransport: String, Codable, Sendable {
    case tcp, udp, other
}

/// What the system tells the guard about a new flow of a held process.
public struct GuardFlow: Sendable {
    public var transport: GuardTransport
    /// The remote address as an IP literal, when the flow has one.
    public var remoteAddress: String?
    public var remotePort: UInt16?
    /// The name the flow was opened by (a connection made by name), when the system knows it.
    public var remoteHostname: String?

    public init(transport: GuardTransport, remoteAddress: String?, remotePort: UInt16?, remoteHostname: String? = nil) {
        self.transport = transport
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.remoteHostname = remoteHostname
    }
}

public enum GuardVerdict: String, Codable, Sendable {
    case allow
    case drop
    /// A DNS question: let through only if it asks for the proxy's own name (`dnsVerdict`).
    case inspectDNS
}

public enum GuardPolicy {
    /// What a held process may do with a new flow. Everything not named here is dropped:
    ///   * loopback — the WebRTC relay (on 127.0.0.1, in the app's own process), the profile's own
    ///     local services;
    ///   * its proxy — by the name the flow was opened by and the proxy's port, or by an address the
    ///     app found for the proxy (any port: the proxy's UDP relay port is its own);
    ///   * DNS over UDP — only a question for the proxy's own name (`inspectDNS`); DNS over TCP and
    ///     any other name are dropped: through the proxy every other name is resolved by the proxy.
    /// A flow whose remote end is not known is dropped.
    public static func verdict(_ flow: GuardFlow, for registration: GuardRegistration) -> GuardVerdict {
        let address = flow.remoteAddress.flatMap(IPAddr.init)
        if let address, isLoopback(address) { return .allow }
        if let name = flow.remoteHostname.map(normalizedName), name == "localhost" { return .allow }
        guard flow.transport == .tcp || flow.transport == .udp else { return .drop }
        guard address != nil || flow.remoteHostname != nil else { return .drop }
        if flow.remotePort == 53 { return flow.transport == .udp ? .inspectDNS : .drop }
        if let name = flow.remoteHostname.map(normalizedName), !name.isEmpty,
           name == registration.proxyHost, flow.remotePort == registration.proxyPort {
            return .allow
        }
        if let canonical = flow.remoteAddress.flatMap(canonicalAddress), registration.proxyAddresses.contains(canonical) {
            return .allow
        }
        return .drop
    }

    /// A DNS question of a held process: through only if every name it asks is the proxy's own.
    public static func dnsVerdict(_ message: [UInt8], for registration: GuardRegistration) -> GuardVerdict {
        guard IPAddr(registration.proxyHost) == nil, let names = DNSQuestion.names(in: message), !names.isEmpty else { return .drop }
        return names.allSatisfy { $0 == registration.proxyHost } ? .allow : .drop
    }

    /// Lowercased, without a final dot.
    public static func normalizedName(_ name: String) -> String {
        var lowered = name.lowercased()
        while lowered.hasSuffix(".") { lowered.removeLast() }
        return lowered
    }

    /// An IP literal in one form only: IPv4 dotted (an IPv4-mapped IPv6 address as its IPv4), IPv6
    /// shortest, no brackets. Nil for a name.
    public static func canonicalAddress(_ text: String) -> String? {
        guard let address = IPAddr(text) else { return nil }
        if address.family == .v6, address.bytes[0..<10].allSatisfy({ $0 == 0 }), address.bytes[10] == 0xff, address.bytes[11] == 0xff {
            return IPAddr(bytes: Array(address.bytes[12..<16]))?.description
        }
        return address.description
    }

    static func isLoopback(_ address: IPAddr) -> Bool {
        if address.family == .v4 { return address.bytes[0] == 127 }
        if address.bytes[0..<15].allSatisfy({ $0 == 0 }) && address.bytes[15] == 1 { return true }
        // IPv4-mapped loopback.
        if address.bytes[0..<10].allSatisfy({ $0 == 0 }), address.bytes[10] == 0xff, address.bytes[11] == 0xff {
            return address.bytes[12] == 127
        }
        return false
    }
}

/// The questions of a DNS message (RFC 1035 §4.1), as the guard reads a held process's lookup.
public enum DNSQuestion {
    /// The names asked, lowercased, without the final dot; nil when the message is not a query or
    /// cannot be read (a name compressed in a question, a label too long, the message cut short).
    public static func names(in message: [UInt8]) -> [String]? {
        guard message.count >= 12 else { return nil }
        guard message[2] & 0x80 == 0 else { return nil } // QR: a response, not a question
        let count = Int(message[4]) << 8 | Int(message[5])
        guard (1...4).contains(count) else { return nil }
        var offset = 12
        var names: [String] = []
        for _ in 0..<count {
            var labels: [String] = []
            var total = 0
            while true {
                guard offset < message.count else { return nil }
                let length = Int(message[offset])
                offset += 1
                if length == 0 { break }
                guard length < 64, offset + length <= message.count else { return nil }
                total += length + 1
                guard total <= 255, let label = String(bytes: message[offset..<(offset + length)], encoding: .utf8) else { return nil }
                labels.append(label.lowercased())
                offset += length
            }
            guard offset + 4 <= message.count else { return nil }
            offset += 4 // QTYPE, QCLASS
            names.append(labels.joined(separator: "."))
        }
        return names
    }
}

/// An audit token (`audit_token_t`, eight 32-bit words in the host's order) as the system hands it
/// to a filter: the process it names.
public enum AuditToken {
    public static func pid(of token: [UInt8]) -> Int32? {
        word(5, of: token).map { Int32(bitPattern: $0) }
    }

    /// The process's generation: a pid the system gave again to a new process has another one.
    public static func pidVersion(of token: [UInt8]) -> Int32? {
        word(7, of: token).map { Int32(bitPattern: $0) }
    }

    private static func word(_ index: Int, of token: [UInt8]) -> UInt32? {
        guard token.count == 32 else { return nil }
        let start = index * 4
        return UInt32(token[start]) | UInt32(token[start + 1]) << 8 | UInt32(token[start + 2]) << 16 | UInt32(token[start + 3]) << 24
    }
}

/// What the guard did for one held process, for the app to read back (`NetworkGuardControl.report`):
/// counts, and the last flows it dropped — by whom and to where, never what they carried.
public struct GuardReport: Codable, Equatable, Sendable {
    public struct Drop: Codable, Equatable, Sendable {
        public var transport: GuardTransport
        public var remote: String
        /// The process that opened the flow (the profile's own, or WebKit's or a service acting for it).
        public var by: String
        /// Opened by another process than the held one, for it (WebKit's network process, mDNSResponder).
        public var onBehalf: Bool

        public init(transport: GuardTransport, remote: String, by: String, onBehalf: Bool = false) {
            self.transport = transport
            self.remote = remote
            self.by = by
            self.onBehalf = onBehalf
        }
    }

    public var pid: Int32
    public var held: Bool
    public var allowed: Int
    public var dropped: Int
    /// Flows opened for the process by another one (WebKit's network process, mDNSResponder) that
    /// the guard saw: that it sees them at all is what holds the profile, not only its own process.
    public var seenOnItsBehalf: Int
    public var recentDrops: [Drop]

    public init(pid: Int32, held: Bool, allowed: Int = 0, dropped: Int = 0, seenOnItsBehalf: Int = 0, recentDrops: [Drop] = []) {
        self.pid = pid
        self.held = held
        self.allowed = allowed
        self.dropped = dropped
        self.seenOnItsBehalf = seenOnItsBehalf
        self.recentDrops = recentDrops
    }
}

/// The guard's registrations and what it did for each, safe to use from the filter's threads.
public final class GuardLedger: @unchecked Sendable {
    public static let recentDropLimit = 32
    private let lock = NSLock()
    private var registrations: [Int32: GuardRegistration] = [:]
    private var reports: [Int32: GuardReport] = [:]

    public init() {}

    public func hold(_ registration: GuardRegistration) {
        lock.lock()
        defer { lock.unlock() }
        registrations[registration.pid] = registration
        reports[registration.pid] = GuardReport(pid: registration.pid, held: true)
    }

    public func release(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        registrations[pid] = nil
        reports[pid]?.held = false
    }

    public func registration(for pid: Int32) -> GuardRegistration? {
        lock.lock()
        defer { lock.unlock() }
        return registrations[pid]
    }

    public var heldPIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return Array(registrations.keys)
    }

    /// Notes a verdict for a held process's flow. `by` names the process that opened it, `onBehalf`
    /// whether that is another process than the held one.
    public func note(_ verdict: GuardVerdict, pid: Int32, flow: GuardFlow, by: String, onBehalf: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var report = reports[pid] else { return }
        if onBehalf { report.seenOnItsBehalf += 1 }
        switch verdict {
        case .allow:
            report.allowed += 1
        case .drop:
            report.dropped += 1
            let host = flow.remoteHostname.map(GuardPolicy.normalizedName)
                ?? flow.remoteAddress.map { address -> String in
                    let canonical = GuardPolicy.canonicalAddress(address) ?? address
                    return canonical.contains(":") ? "[\(canonical)]" : canonical
                } ?? "?"
            let remote = flow.remotePort.map { "\(host):\($0)" } ?? host
            report.recentDrops.append(.init(transport: flow.transport, remote: remote, by: by, onBehalf: onBehalf))
            if report.recentDrops.count > Self.recentDropLimit {
                report.recentDrops.removeFirst(report.recentDrops.count - Self.recentDropLimit)
            }
        case .inspectDNS:
            break
        }
        reports[pid] = report
    }

    public func report(for pid: Int32) -> GuardReport {
        lock.lock()
        defer { lock.unlock() }
        return reports[pid] ?? GuardReport(pid: pid, held: false)
    }
}

/// The check that the guard holds what WebKit opens for a profile (docs/TUNNEL.md, "Attribution"):
/// a probe process (`Lumen --guard-probe`), held, asks a STUN server at a documentation address with
/// WebKit's own WebRTC. The guard holds a profile only if it saw that flow as the probe's — opened
/// by another process on its behalf — and dropped it.
public enum GuardProof {
    /// TEST-NET-3 (RFC 5737): never routed on the Internet, so the probe's request reaches no one,
    /// held or not. The relay refuses TEST-NET-1 as a peer, not this one; the probe uses no relay.
    public static let stunAddress = "203.0.113.1"
    public static let stunPort: UInt16 = 3478

    public static func holds(_ report: GuardReport) -> Bool {
        report.recentDrops.contains { $0.transport == .udp && $0.onBehalf && $0.remote == "\(stunAddress):\(stunPort)" }
    }
}
