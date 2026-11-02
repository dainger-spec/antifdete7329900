import Darwin
import Foundation
import NetworkExtension
import NetworkGuardCore
import os

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
final class GuardFilterProvider: NEFilterDataProvider {
    private let logger = Logger(subsystem: "PrivacyBrowser.NetworkGuard", category: "filter")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        logger.notice("startFilter")
        // Every flow comes to handleNewFlow: a rule can name networks and ports, not processes.
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { [weak self] error in
            if let error {
                self?.logger.error("apply: \(error.localizedDescription, privacy: .private)")
            } else {
                GuardService.shared.filterRunning = true
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.notice("stopFilter \(reason.rawValue, privacy: .public)")
        GuardService.shared.filterRunning = false
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow,
              let token = flow.sourceAppAuditToken, let pid = AuditToken.pid(of: [UInt8](token)),
              let registration = GuardService.shared.ledger.registration(for: pid) else {
            return .allow()
        }
        let facts = Self.facts(of: socketFlow)
        let opener = Self.opener(of: flow, holder: pid)
        let verdict = GuardPolicy.verdict(facts, for: registration)
        GuardService.shared.ledger.note(verdict, pid: pid, flow: facts, by: opener.name, onBehalf: opener.onBehalf)
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

    static func processName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
