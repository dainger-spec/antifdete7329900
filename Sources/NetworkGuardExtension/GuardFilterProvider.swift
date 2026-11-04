import Darwin
import Foundation
import NetworkExtension
import NetworkGuardCore
import os
import Security

/// The network guard: a content filter that holds each process the app registered — a profile
/// whose WebRTC goes through its proxy — to that proxy (docs/TUNNEL.md). Every new flow of the Mac
/// comes here first; a flow of any other process is let through at once, untouched and unread (the
/// app's own traffic — updates, the account, sync — included). A flow of a held process is checked
/// against its registration (`GuardPolicy`): loopback, its proxy, and a DNS question for the proxy's
/// own name go through, everything else is dropped.
///
/// A filter can only let a flow through or drop it: it carries nothing anywhere. WebRTC's packets
/// go to the relay on loopback (the app's own process), which sends them through the proxy.
///
/// Which process a flow is for is the system's answer (`sourceAppAuditToken`): what WebKit's
/// network process or mDNSResponder open on behalf of a profile's process is that process's. The
/// app checks, once per macOS build, that this holds for a profile's WebRTC before it relies on it.
///
/// Every flow is counted, whatever becomes of it (`FlowTally`), and said in this log every five
/// seconds when any came: let through as another process's (by its name), a held process's, without
/// the app's audit token, with one that does not read. A flow to the documentation network
/// 203.0.113.0/24 — the check's probe, the diagnosis's own control — is said one by one, with whom
/// macOS counts it for. On the owner's Mac, 3 November, the log said nothing of any flow, and could
/// not tell "no flow came" from "none was a held process's".
final class GuardFilterProvider: NEFilterDataProvider {
    private let logger = Logger(subsystem: "PrivacyBrowser.NetworkGuard", category: "filter")
    private let summaryQueue = DispatchQueue(label: "PrivacyBrowser.NetworkGuard.summary")
    private var summaryTimer: DispatchSourceTimer?
    /// Summaries in a row with no flow (on `summaryQueue` only).
    private var quietTicks = 0
    /// Process names by pid, for the count — forgotten with each summary (a pid is given again).
    private let namesLock = NSLock()
    private var names: [Int32: String] = [:]

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        logger.notice("startFilter")
        // Every flow comes to handleNewFlow: a rule can name networks and ports, not processes.
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { [weak self] error in
            if let error {
                self?.logger.error("apply: \(error.localizedDescription, privacy: .private)")
            } else {
                self?.logger.notice("startFilter: every new flow is to come here (no rule, the default action filterData)")
                GuardService.shared.filterRunning = true
                self?.startSummaries()
            }
            completionHandler(error)
        }
    }

    /// Every five seconds, the flows since the last line — nothing when none came, and once a minute
    /// that none did.
    private func startSummaries() {
        let timer = DispatchSource.makeTimerSource(queue: summaryQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let summary = GuardService.shared.tally.windowSummary() {
                self.quietTicks = 0
                // The counts in clear; the names of the processes let through are this Mac's apps.
                self.logger.notice("\(summary.counts, privacy: .public)\(summary.names, privacy: .private)")
            } else {
                self.quietTicks += 1
                if self.quietTicks % 12 == 0 {
                    let total = GuardService.shared.tally.snapshot().total
                    self.logger.notice("no flow in the last \(Int(self.quietTicks * 5), privacy: .public) s (\(Int(total), privacy: .public) since the guard started)")
                }
            }
            self.namesLock.lock()
            self.names.removeAll()
            self.namesLock.unlock()
        }
        summaryTimer?.cancel()
        summaryTimer = timer
        timer.resume()
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.notice("stopFilter \(reason.rawValue, privacy: .public)")
        summaryTimer?.cancel()
        summaryTimer = nil
        GuardService.shared.filterRunning = false
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let openerPID = flow.sourceProcessAuditToken.flatMap { AuditToken.pid(of: [UInt8]($0)) }
        let openerName = openerPID.map(name) ?? "?"
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            count(.notSocket, flow, appPID: nil, openerPID: openerPID, openerName: openerName, facts: nil, verdict: "allow")
            return .allow()
        }
        let facts = Self.facts(of: socketFlow)
        guard let token = flow.sourceAppAuditToken else {
            count(.noAppToken, flow, appPID: nil, openerPID: openerPID, openerName: openerName, facts: facts, verdict: "allow")
            return .allow()
        }
        guard let pid = AuditToken.pid(of: [UInt8](token)) else {
            count(.unreadableToken, flow, appPID: nil, openerPID: openerPID, openerName: openerName, facts: facts, verdict: "allow")
            return .allow()
        }
        guard let registration = GuardService.shared.ledger.registration(for: pid) else {
            count(.notHeld, flow, appPID: pid, openerPID: openerPID, openerName: openerName, facts: facts, verdict: "allow")
            return .allow()
        }
        let opener = Self.opener(of: flow, holder: pid)
        let verdict = GuardPolicy.verdict(facts, for: registration)
        GuardService.shared.ledger.note(verdict, pid: pid, flow: facts, by: opener.name, onBehalf: opener.onBehalf)
        count(.held, flow, appPID: pid, openerPID: openerPID, openerName: openerName, facts: facts,
              verdict: verdict == .allow ? "allow" : verdict == .drop ? "drop" : "inspectDNS")
        switch verdict {
        case .allow:
            return .allow()
        case .drop:
            logger.notice("dropped a flow of held process \(pid, privacy: .public) opened by \(opener.name, privacy: .public)")
            return .drop()
        case .inspectDNS:
            // The question is in the first datagram; nothing comes back before it is let through.
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0, filterOutbound: true, peekOutboundBytes: 512)
        }
    }

    /// Counts the flow; one to the documentation network is said here, with whom it is counted for.
    private func count(_ kind: FlowTally.Kind, _ flow: NEFilterFlow, appPID: Int32?, openerPID: Int32?, openerName: String,
                       facts: GuardFlow?, verdict: String) {
        let appName = appPID.map(name) ?? "?"
        // The source app's signing identifier, for a flow to the documentation network only (the
        // check's, the diagnosis's): read from its code by its audit token. NEFilterFlow's own
        // sourceAppIdentifier is iOS's — unavailable in macOS's SDK (CI run 670).
        let identifier = FlowTally.isCheckAddress(facts?.remoteAddress) ? flow.sourceAppAuditToken.flatMap(Self.signingIdentifier) : nil
        let check = GuardService.shared.tally.record(kind, appPID: appPID, appName: appName, appIdentifier: identifier,
                                                     openerPID: openerPID, openerName: openerName,
                                                     transport: facts?.transport ?? .other, remoteAddress: facts?.remoteAddress,
                                                     remotePort: facts?.remotePort, verdict: verdict)
        guard let check else { return }
        // Only a flow to the documentation network, never routed — the check's probe, the diagnosis's
        // own — gets here: said in the clear, with whom it is counted for.
        logger.notice("a flow to the check's network: \(check.description, privacy: .public)")
    }

    /// A process's name, kept until the next summary.
    private func name(_ pid: Int32) -> String {
        namesLock.lock()
        if let known = names[pid] {
            namesLock.unlock()
            return known
        }
        namesLock.unlock()
        let found = Self.processName(pid)
        namesLock.lock()
        names[pid] = found
        namesLock.unlock()
        return found
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        guard let token = flow.sourceAppAuditToken, let pid = AuditToken.pid(of: [UInt8](token)),
              let registration = GuardService.shared.ledger.registration(for: pid) else {
            return .allow()
        }
        let verdict = GuardPolicy.dnsVerdict([UInt8](readBytes), for: registration)
        if let socketFlow = flow as? NEFilterSocketFlow {
            let opener = Self.opener(of: flow, holder: pid)
            var facts = Self.facts(of: socketFlow)
            if verdict == .drop {
                // What was asked, not where: the name is what a DNS leak gives away.
                facts.remoteHostname = DNSQuestion.names(in: [UInt8](readBytes))?.first.map { "dns:\($0)" } ?? facts.remoteHostname
            }
            GuardService.shared.ledger.note(verdict, pid: pid, flow: facts, by: opener.name, onBehalf: opener.onBehalf)
        }
        // A question for the proxy's name goes through, and the flow stays looked into: a resolver
        // may ask its next question on the same socket.
        return verdict == .allow ? NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: 512) : .drop()
    }

    /// The flow's transport, remote address and port, and the name it was opened by.
    static func facts(of flow: NEFilterSocketFlow) -> GuardFlow {
        let transport: GuardTransport
        switch flow.socketProtocol {
        case IPPROTO_TCP: transport = .tcp
        case IPPROTO_UDP: transport = .udp
        default: transport = .other
        }
        var address: String?
        var port: UInt16?
        if let endpoint = flow.remoteEndpoint as? NWHostEndpoint {
            address = GuardPolicy.canonicalAddress(endpoint.hostname)
            port = UInt16(endpoint.port)
        }
        return GuardFlow(transport: transport, remoteAddress: address, remotePort: port, remoteHostname: flow.remoteHostname)
    }

    /// The process that opened the flow, by name, and whether it is another than the held one.
    static func opener(of flow: NEFilterFlow, holder: Int32) -> (name: String, onBehalf: Bool) {
        guard let token = flow.sourceProcessAuditToken, let pid = AuditToken.pid(of: [UInt8](token)) else {
            return ("?", false)
        }
        return (processName(pid), pid != holder)
    }

    /// The signing identifier of the process an audit token names, read from its code; nil when it
    /// cannot be read.
    static func signingIdentifier(of token: Data) -> String? {
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }

    static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
