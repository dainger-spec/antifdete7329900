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
        let ledger = GuardService.shared.ledger
        let isCheck = FlowTally.isCheckAddress(facts.remoteAddress)
        let token = flow.sourceAppAuditToken
        let appPID = token.flatMap { AuditToken.pid(of: [UInt8]($0)) }
        let anyHeld = !ledger.heldPIDs.isEmpty
        let appHeld = appPID.map { ledger.registration(for: $0) != nil } ?? false
        // The kernel's record of the flow's socket — whom it counts the socket for — read while the
        // guard holds a process and the source application is not one (and for the check's own
        // flows, always): what a packet capture shows as `eproc`.
        var socket: KernelSocket?
        var socketNote: String?
        if isCheck || (anyHeld && !appHeld) {
            (socket, socketNote) = Self.kernelSocket(of: socketFlow, facts: facts, openerPID: openerPID)
        }
        let properties = isCheck ? Self.properties(of: flow) : nil
        if isCheck { laterReadings(of: socketFlow, facts: facts, openerPID: openerPID) }
        let found = GuardAttribution.holder(appPID: appPID, socket: socket, isHeld: { ledger.registration(for: $0) != nil })
        guard let holder = found, let registration = ledger.registration(for: holder.pid) else {
            // Not a held process's, by either answer. WebKit's network process — which opens what a
            // page asks for, on its process's behalf — is looked at again at its first data while
            // the guard holds a process; so is a flow of the check's, to say what changed.
            let lookAgain = isCheck || (anyHeld && Self.isWebKitNetworkProcess(openerPID))
            let kind: FlowTally.Kind = token == nil ? .noAppToken : appPID == nil ? .unreadableToken : .notHeld
            count(kind, flow, appPID: appPID, openerPID: openerPID, openerName: openerName, facts: facts,
                  verdict: lookAgain ? "looked into" : "allow", kernel: socket, kernelNote: socketNote, properties: properties)
            return lookAgain ? .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0, filterOutbound: true, peekOutboundBytes: 1)
                             : .allow()
        }
        let pid = holder.pid
        let opener = Self.opener(of: flow, holder: pid)
        let verdict = GuardPolicy.verdict(facts, for: registration)
        GuardService.shared.ledger.note(verdict, pid: pid, flow: facts, by: opener.name, onBehalf: opener.onBehalf)
        count(.held, flow, appPID: appPID, openerPID: openerPID, openerName: openerName, facts: facts,
              verdict: verdict == .allow ? "allow" : verdict == .drop ? "drop" : "inspectDNS",
              kernel: socket, kernelNote: socketNote, heldBy: holder.source.rawValue, properties: properties)
        switch verdict {
        case .allow:
            return .allow()
        case .drop:
            logger.notice("dropped a flow of held process \(pid, privacy: .public) opened by \(opener.name, privacy: .public), held by its \(holder.source.rawValue, privacy: .public)")
            return .drop()
        case .inspectDNS:
            // The question is in the first datagram; nothing comes back before it is let through.
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0, filterOutbound: true, peekOutboundBytes: 512)
        }
    }

    /// Counts the flow; one to the documentation network is said here, with whom it is counted for.
    private func count(_ kind: FlowTally.Kind, _ flow: NEFilterFlow, appPID: Int32?, openerPID: Int32?, openerName: String,
                       facts: GuardFlow?, verdict: String, kernel: KernelSocket? = nil, kernelNote: String? = nil,
                       heldBy: String? = nil, properties: [String]? = nil) {
        let appName = appPID.map(name) ?? "?"
        // The source app's signing identifier, for a flow to the documentation network only (the
        // check's, the diagnosis's): read from its code by its audit token. NEFilterFlow's own
        // sourceAppIdentifier is iOS's — unavailable in macOS's SDK (CI run 670).
        let identifier = FlowTally.isCheckAddress(facts?.remoteAddress) ? flow.sourceAppAuditToken.flatMap(Self.signingIdentifier) : nil
        let check = GuardService.shared.tally.record(kind, appPID: appPID, appName: appName, appIdentifier: identifier,
                                                     openerPID: openerPID, openerName: openerName,
                                                     transport: facts?.transport ?? .other, remoteAddress: facts?.remoteAddress,
                                                     remotePort: facts?.remotePort, verdict: verdict,
                                                     id: flow.identifier.uuidString, kernel: kernel, kernelNote: kernelNote,
                                                     heldBy: heldBy, properties: properties)
        guard let check else { return }
        // Only a flow to the documentation network, never routed — the check's probe, the diagnosis's
        // own — gets here: said in the clear, with whom it is counted for.
        logger.notice("a flow to the check's network: \(check.description, privacy: .public)")
        for checkFlowProperty in properties ?? [] {
            logger.notice("  the flow object: \(checkFlowProperty, privacy: .public)")
        }
    }

    /// The kernel's record of a flow to the check's network read again 5, 20, 100 and 500 ms after
    /// it came: whether whom it counts the socket for changes (the check's flows only).
    private func laterReadings(of flow: NEFilterSocketFlow, facts: GuardFlow, openerPID: Int32?) {
        let id = flow.identifier.uuidString
        let local = Self.localPort(of: flow)
        for milliseconds in [5, 20, 100, 500] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                let (socket, note) = Self.kernelSocket(localPort: local.port, localSaid: local.said, facts: facts, openerPID: openerPID)
                let line = "+\(milliseconds) ms: " + (socket.map(String.init(describing:)) ?? note ?? "?")
                GuardService.shared.tally.noteLater(of: id, line)
            }
        }
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
        let ledger = GuardService.shared.ledger
        let appPID = flow.sourceAppAuditToken.flatMap { AuditToken.pid(of: [UInt8]($0)) }
        let openerPID = flow.sourceProcessAuditToken.flatMap { AuditToken.pid(of: [UInt8]($0)) }
        let socketFlow = flow as? NEFilterSocketFlow
        let flowFacts = socketFlow.map { Self.facts(of: $0) }
        let appHeld = appPID.map { ledger.registration(for: $0) != nil } ?? false
        let isCheck = FlowTally.isCheckAddress(flowFacts?.remoteAddress)
        // Read again now: a flow looked into at its first data was nobody's held process's when it came.
        var socket: KernelSocket?
        var socketNote: String?
        if let socketFlow, let read = flowFacts, isCheck || !appHeld {
            (socket, socketNote) = Self.kernelSocket(of: socketFlow, facts: read, openerPID: openerPID)
        }
        let found = GuardAttribution.holder(appPID: appPID, socket: socket, isHeld: { ledger.registration(for: $0) != nil })
        guard let holder = found, let registration = ledger.registration(for: holder.pid), let facts = flowFacts else {
            if isCheck { noteFirstData(flow, appPID: appPID, socket: socket, socketNote: socketNote, heldBy: nil, verdict: "allow") }
            return .allow()
        }
        let pid = holder.pid
        let policy = GuardPolicy.verdict(facts, for: registration)
        let verdict = policy == .inspectDNS ? GuardPolicy.dnsVerdict([UInt8](readBytes), for: registration) : policy
        let opener = Self.opener(of: flow, holder: pid)
        var noted = facts
        if policy == .inspectDNS, verdict == .drop {
            // What was asked, not where: the name is what a DNS leak gives away.
            noted.remoteHostname = DNSQuestion.names(in: [UInt8](readBytes))?.first.map { "dns:\($0)" } ?? facts.remoteHostname
        }
        // A DNS flow is noted at each question; any other once, at the first data it was looked into at.
        ledger.note(verdict, pid: pid, flow: noted, by: opener.name, onBehalf: opener.onBehalf)
        if isCheck {
            noteFirstData(flow, appPID: appPID, socket: socket, socketNote: socketNote, heldBy: holder.source.rawValue,
                          verdict: verdict == .drop ? "drop" : "allow")
        }
        switch verdict {
        case .drop:
            logger.notice("dropped a flow of held process \(pid, privacy: .public) at its first data, opened by \(opener.name, privacy: .public), held by its \(holder.source.rawValue, privacy: .public)")
            return .drop()
        case .allow, .inspectDNS:
            // A question for the proxy's name goes through, and the flow stays looked into: a resolver
            // may ask its next question on the same socket.
            return policy == .inspectDNS ? NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: 512) : .allow()
        }
    }

    /// What the guard read of a flow to the check's network at its first outbound data.
    private func noteFirstData(_ flow: NEFilterFlow, appPID: Int32?, socket: KernelSocket?, socketNote: String?, heldBy: String?,
                               verdict: String) {
        let id = flow.identifier.uuidString
        let before = Set(GuardService.shared.tally.snapshot().checkFlows.last { $0.id == id }?.properties ?? [])
        let changed = Self.properties(of: flow).filter { !before.contains($0) }
        let look = FlowTally.CheckFlow.Look(appPID: appPID, appName: appPID.map(name) ?? "?", kernel: socket, kernelNote: socketNote,
                                            heldBy: heldBy, verdict: verdict, changedProperties: changed)
        guard GuardService.shared.tally.noteFirstData(of: id, look) != nil else { return }
        let checkFirstData = "counted for pid \(appPID.map(String.init) ?? "none"); the kernel's record: "
            + (socket.map(String.init(describing:)) ?? socketNote ?? "not read")
            + "; \(heldBy.map { "held by its \($0)" } ?? "not held"): \(verdict)"
        logger.notice("a flow to the check's network, at its first data: \(checkFirstData, privacy: .public)")
        for checkFlowProperty in changed {
            logger.notice("  the flow object, changed: \(checkFlowProperty, privacy: .public)")
        }
    }

    /// The kernel's record of a flow's socket: by its transport, its local port, its remote end and
    /// the process that opened it (SocketTable). Nil, with why, when it cannot be read.
    static func kernelSocket(of flow: NEFilterSocketFlow, facts: GuardFlow, openerPID: Int32?) -> (KernelSocket?, String?) {
        let local = localPort(of: flow)
        return kernelSocket(localPort: local.port, localSaid: local.said, facts: facts, openerPID: openerPID)
    }

    /// The flow's local port as the filter is given it, and its local end in words.
    static func localPort(of flow: NEFilterSocketFlow) -> (port: UInt16?, said: String) {
        guard let local = flow.localEndpoint as? NWHostEndpoint else { return (nil, "no local end") }
        return (UInt16(local.port), "\(local.hostname):\(local.port)")
    }

    static func kernelSocket(localPort: UInt16?, localSaid: String, facts: GuardFlow, openerPID: Int32?) -> (KernelSocket?, String?) {
        guard facts.transport != .other else { return (nil, "neither TCP nor UDP: no table to read") }
        guard let port = localPort, port != 0 else {
            return (nil, "the flow has no local port yet (\(localSaid))")
        }
        switch SocketTable.read(facts.transport) {
        case .failure(let error):
            return (nil, error.description)
        case .success(let sockets):
            guard let socket = SocketTable.socket(of: facts.transport, localPort: port, remoteAddress: facts.remoteAddress,
                                                  remotePort: facts.remotePort, openerPID: openerPID, in: sockets) else {
                return (nil, "no \(facts.transport.rawValue) socket on local port \(port) among the \(sockets.count) in the kernel's table")
            }
            return (socket, nil)
        }
    }

    /// Whether a process is WebKit's network process (its executable inside
    /// com.apple.WebKit.Networking.xpc): what opens a page's connections for the page's process.
    static func isWebKitNetworkProcess(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).contains("/com.apple.WebKit.Networking.xpc/")
    }

    /// Every Objective-C property of a flow object, by the class that declares it, with its value
    /// where it reads as one (an object, a number): what the filter is given about a flow, public or
    /// not. Called for the check's flows only — to TEST-NET-3, nothing of anyone's.
    static func properties(of object: NSObject) -> [String] {
        var lines: [String] = []
        var current: AnyClass? = object_getClass(object)
        while let type = current, type != NSObject.self {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(type, &count) {
                for index in 0..<Int(count) {
                    let property = list[index]
                    let name = String(cString: property_getName(property))
                    let attributes = property_getAttributes(property).map { String(cString: $0) } ?? ""
                    lines.append("\(NSStringFromClass(type)).\(name) = \(value(of: object, name: name, attributes: attributes))")
                }
                free(list)
            }
            current = class_getSuperclass(type)
        }
        return lines
    }

    /// A property's value through its getter, by its type: objects and whole numbers; anything else
    /// by its type code only.
    private static func value(of object: NSObject, name: String, attributes: String) -> String {
        let parts = attributes.split(separator: ",").map(String.init)
        guard let type = parts.first, type.hasPrefix("T") else { return "?" }
        let getterName = parts.first { $0.hasPrefix("G") }.map { String($0.dropFirst()) } ?? name
        let selector = NSSelectorFromString(getterName)
        guard object.responds(to: selector), let method = class_getInstanceMethod(object_getClass(object), selector) else {
            return "(no getter)"
        }
        let implementation = method_getImplementation(method)
        let code = String(type.dropFirst())
        if code.hasPrefix("@") {
            guard let result = object.perform(selector)?.takeUnretainedValue() else { return "nil" }
            return describe(result)
        }
        switch code {
        case "q", "Q", "l", "L":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
            return String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        case "i", "I":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            return String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        case "s", "S":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int16
            return String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        case "c", "C", "B":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int8
            return String(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        default:
            return "(type \(code))"
        }
    }

    private static func describe(_ value: AnyObject) -> String {
        if let data = value as? Data {
            if data.count == 32, let pid = AuditToken.pid(of: [UInt8](data)) {
                return "32 bytes, an audit token of pid \(pid) (\(processName(pid)))"
            }
            return "\(data.count) bytes"
        }
        if let uuid = value as? NSUUID { return uuid.uuidString }
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String { return text.count > 160 ? String(text.prefix(160)) + "…" : text }
        if let endpoint = value as? NWEndpoint { return endpoint.description }
        return "<\(NSStringFromClass(type(of: value)))>"
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
