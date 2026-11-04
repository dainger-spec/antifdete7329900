import AppKit
import Darwin
import Foundation
import NetworkExtension
import NetworkGuardCore

/// `Lumen --guard-diagnose` (the owner, 3 November): the network guard on this Mac, measured and said
/// in words — does the filter get flows at all, did the check's probe send its request, whom did
/// macOS count that request for — so that a failed check is understood without reading logs by hand.
/// On the owner's Mac the check failed four times with not one line of the guard's about any flow.
///
/// In order: the system extension as `systemextensionsctl` lists it; the filter's configuration as
/// `NEFilterManager` has it (this executable holds the provider right that reads it); the guard over
/// XPC — its version, its filter, every flow it was given (`GuardDiagnostics`); a UDP datagram and a
/// TCP connection of this process's own to the documentation network (TEST-NET-3, never routed),
/// which the filter must see as this process's; then the check's own probe (`GuardProbe`), held as
/// the app holds it, with its own account of what it did; the guard's counts again; the guard's own
/// log over the same minutes; and the answers. Nothing of the person's: no profile, no vault, no
/// address but the documentation ones. Exit 0 when the check passes, 1 when it does not.
@MainActor
enum GuardDiagnosis {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await diagnose() ? 0 : 1)
        }
        application.run()
        exit(0)
    }

    private static let ownAddress = "203.0.113.2"
    private static var probeAddress: String { "\(GuardProof.stunAddress):\(GuardProof.stunPort)" }

    private static func say(_ text: String) { print(text) }

    private static func section(_ title: String) {
        print("")
        print("== \(title)")
    }

    private static func time(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter() // l10n: not text (a time in Terminal, en_US_POSIX)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// True when the check passes: the probe's STUN flow seen as the probe's, opened for it, and dropped.
    static func diagnose() async -> Bool {
        let started = Date()
        let info = Bundle.main.infoDictionary ?? [:]
        say("Lumen's network guard on this Mac, \(ISO8601DateFormatter().string(from: started))")
        say("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); Lumen \(info["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info["CFBundleVersion"] as? String ?? "?")) at \(Bundle.main.bundlePath); this process: pid \(getpid())")
        guard let bundled = NetworkGuard.bundledGuard() else {
            section("ANSWERS")
            say("This copy of Lumen has no network guard in it (a build made without NE=1): there is no filter to ask.")
            return false
        }
        say("its guard: \(bundled.identifier), version \(bundled.version ?? "?")")

        section("The system extension (systemextensionsctl list)")
        let listed = await systemExtensionLines(bundled.identifier)
        if listed.isEmpty { say("not listed: the guard was never installed on this Mac") }
        for line in listed { say(line) }

        section("The filter's configuration (NEFilterManager)")
        let configuration = await filterConfiguration(expected: bundled.identifier)
        for line in configuration.lines { say(line) }

        section("The guard, asked over XPC")
        guard let service = bundled.machService, let requirement = bundled.requirement else {
            say(bundled.machService == nil ? "this copy's guard names no Mach service: nothing can ask it"
                                           : "this copy is signed by no team (ad hoc): it talks to no guard, as the app does not")
            section("ANSWERS")
            say("1. Does the filter receive flows? UNKNOWN — this copy cannot ask its guard. \(configuration.hint)")
            say("The check: CANNOT RUN here — it is run with a copy signed by the team (the release's build).")
            return false
        }
        let connection = NSXPCConnection(machServiceName: service, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkGuardControl.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        let hello = await NetworkGuard.ask(connection) { (guardian: NetworkGuardControl, done: @escaping ((String, Bool)) -> Void) in
            guardian.hello { done(($0, $1)) }
        }
        guard let hello else {
            say("the guard does not answer at its Mach service \(service): it is not running, not this team's, or switched off")
            await printGuardLog(since: started)
            section("ANSWERS")
            say("1. Does the filter receive flows? UNKNOWN — the guard does not answer at all. \(configuration.hint)")
            say("The check: CANNOT RUN — the app holds its probe through this same service.")
            return false
        }
        let current = hello.0 == bundled.version
        say("the guard answers: version \(hello.0)"
            + (current ? " (this app's)" : " — NOT this app's \(bundled.version ?? "?"): open this Lumen once, it replaces the guard")
            + "; its filter runs: \(hello.1 ? "yes" : "NO")")
        let before = await diagnostics(connection)
        if let before {
            say("flows since the guard started at \(time(before.flows.since)): \(before.flows.total), the last at \(time(before.flows.lastFlowAt))")
        } else {
            say("the guard does not answer diagnostics: it is an older build's (\(hello.0)), which counts no flow")
        }

        section("This process's own flows (UDP and TCP to \(ownAddress), a documentation address, never routed)")
        let ownFrom = Date()
        for line in sendOwnFlows() { say(line) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        section("The check's probe (LumenProfile --guard-probe), held as the app holds it")
        let probe = await runProbe(connection)
        for line in probe.lines { say(line) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = await diagnostics(connection)

        await printGuardLog(since: started)

        section("ANSWERS")
        if !current {
            say("0. The guard that answered is NOT this app's (\(hello.0), this app's \(bundled.version ?? "?")): what follows is an "
                + "older guard's. Open this Lumen once, wait until `systemextensionsctl list` shows its version activated enabled, run again.")
        }
        return answers(before: before, after: after, ownFrom: ownFrom, probe: probe, configuration: configuration)
    }

    // MARK: The answers

    private static func answers(before: GuardDiagnostics?, after: GuardDiagnostics?, ownFrom: Date, probe: ProbeRun,
                                configuration: Configuration) -> Bool {
        let holds = probe.report.map(GuardProof.holds) ?? false
        guard let after else {
            say("1. Does the filter receive flows? UNKNOWN — this guard does not answer diagnostics (an older build's).")
            say("3. Did the probe make a request? Its own account: \(probe.summary).")
            say("The check: \(holds ? "PASSES" : "FAILS") — the guard's report for the probe: dropped \(probe.report?.dropped ?? 0), "
                + "seen on its behalf \(probe.report?.seenOnItsBehalf ?? 0).")
            return holds
        }
        let flows = after.flows
        // The same guard as before (one that restarted counts from nothing again).
        let sameGuard = before.map { $0.flows.since == flows.since } ?? false
        let base = sameGuard ? before?.flows : nil
        let during = flows.total - (base?.total ?? 0)
        func duringKind(_ kind: FlowTally.Kind) -> Int { flows.count(kind) - (base?.count(kind) ?? 0) }
        if before != nil && !sameGuard {
            say("(The guard restarted during this diagnosis, at \(time(flows.since)): its counts are since then.)")
        }
        // 1. Flows at all.
        if flows.total == 0 {
            say("1. Does the filter receive flows? NO — not one since the guard started at \(time(flows.since)), this diagnosis's own "
                + "included: the system gives this filter no flow. \(configuration.hint)")
        } else {
            say("1. Does the filter receive flows? YES — \(flows.total) since the guard started at \(time(flows.since)), \(during) during "
                + "this diagnosis: \(duringKind(.notHeld)) let through as another process's, \(duringKind(.held)) of held processes, "
                + "\(duringKind(.noAppToken)) without the app's audit token, \(duringKind(.unreadableToken)) with a token that does not "
                + "read, \(duringKind(.notSocket)) not socket flows.")
            let names = flows.notHeldByApp.prefix(8).map { "\($0.name) \($0.flows)" }.joined(separator: ", ")
            if !names.isEmpty { say("   Let through as another process's since the guard started, by whom macOS counts them for: \(names).") }
        }
        let recent = flows.checkFlows.filter { $0.at >= ownFrom.addingTimeInterval(-1) }
        // 2. This process's own flows: what the filter makes of a plain process — the control of the rest.
        let own = recent.filter { $0.remote.hasPrefix(ownAddress + ":") }
        if own.isEmpty {
            say("2. This process's own UDP and TCP to \(ownAddress): NOT SEEN by the filter"
                + (flows.total == 0 ? " — as no flow at all is." : " — though other flows are: what this process opens does not come to it."))
        } else {
            for flow in own {
                let mine = flow.appPID == getpid()
                say("2. This process's own \(flow.transport.rawValue.uppercased()) to \(flow.remote): seen, counted for "
                    + describe(flow.appName, flow.appPID)
                    + (mine ? " — this process, as it must be" : " — NOT this process (pid \(getpid()))")
                    + "; opened by \(describe(flow.openerName, flow.openerPID)); \(flow.kind.rawValue), \(flow.verdict).")
            }
        }
        // 3. The probe's request.
        let probeFlows = recent.filter { $0.remote == probeAddress }
        say("3. Did the probe make a request? Its own account: \(probe.summary).")
        say("   The filter saw \(probeFlows.count) flow(s) to \(probeAddress) while it ran"
            + (!probeFlows.isEmpty ? "."
               : flows.total == 0 ? " (it sees none at all)."
               : " — none: what WebKit sent for the probe, if anything, did not come to this filter as a flow to that address."))
        // 4. Whom it was counted for.
        if probeFlows.isEmpty {
            say("4. Whom was the probe's flow counted for? No such flow came to the filter: nothing to count.")
        } else {
            for flow in probeFlows {
                let forProbe = flow.appPID == probe.pid
                say("4. The probe's \(flow.transport.rawValue.uppercased()) to \(flow.remote): counted for \(describe(flow.appName, flow.appPID))"
                    + (flow.appIdentifier.map { ", signed as \($0)" } ?? "")
                    + (forProbe ? " — the probe itself (pid \(probe.pid)), as the guard needs" : " — NOT the probe (pid \(probe.pid))")
                    + " (the filter's source application); opened by \(describe(flow.openerName, flow.openerPID)); "
                    + "\(flow.kind.rawValue), \(flow.verdict).")
                let cameRecord = kernelWords(flow.kernel, flow.kernelNote, probe.pid)
                say("   The kernel's record of its socket, read by the guard when it came: \(cameRecord)")
                for line in flow.later ?? [] { say("   … read again \(line)") }
                if let look = flow.firstData {
                    let lookWho = describe(look.appName, look.appPID)
                    let lookRecord = kernelWords(look.kernel, look.kernelNote, probe.pid)
                    let lookHeld: String = look.heldBy.map { "held by its \($0)" } ?? "not held"
                    say("   At its first datagram: counted for \(lookWho) (the filter's source application); "
                        + "the kernel's record: \(lookRecord); \(lookHeld): \(look.verdict).")
                    for line in look.changedProperties { say("   … the flow object, changed: \(line)") }
                }
                let heldBy = flow.heldBy.map { "by its \($0), when it came" }
                    ?? flow.firstData?.heldBy.map { "by its \($0), at its first datagram" }
                say("   The guard held it " + (heldBy ?? "by neither answer") + ".")
                for line in flow.properties ?? [] { say("   … the flow object: \(line)") }
            }
        }
        // 4b. The kernel's table, read by this process while the probe ran.
        if probe.kernelLines.isEmpty {
            say("4b. The kernel's table, read by this process while the probe ran: no socket to \(probeAddress) was seen in it.")
        } else {
            say("4b. The kernel's table, read by this process while the probe ran (what a capture shows as proc and eproc):")
            for line in probe.kernelLines { say("   \(line)") }
        }
        // 5. Its life.
        say("5. The probe lived \(String(format: "%.1f", probe.seconds)) s and \(probe.endedBy): its page loads (up to 5 s), then "
            + "gathers for its own six seconds (GuardProbe.gather) and ends — a window of its own, not a timeout of the app's.")
        // The verdict.
        if holds {
            say("The check: PASSES — the guard saw the probe's request as the probe's, opened for it by another process, and dropped it.")
        } else {
            let report = probe.report
            say("The check: FAILS — the guard's report for the probe: dropped \(report?.dropped ?? 0), allowed \(report?.allowed ?? 0), "
                + "seen on its behalf \(report?.seenOnItsBehalf ?? 0)"
                + (probe.refusal.map { "; the guard did not hold the probe: \($0)" } ?? "") + ".")
        }
        return holds
    }

    /// The kernel's record of a socket in words, against the probe's pid.
    private static func kernelWords(_ socket: KernelSocket?, _ note: String?, _ probe: Int32) -> String {
        guard let socket else { return note ?? "not read (a guard older than this app's reads none)" }
        let whose = socket.countedFor == probe ? " — the probe" : " — NOT the probe"
        return "\(socket)\(whose)"
    }

    private static func describe(_ name: String, _ pid: Int32?) -> String {
        pid.map { "\(name) (pid \($0))" } ?? "\(name) (no pid: no audit token)"
    }

    // MARK: Other programs' words

    /// What `executable` prints, read off the main thread, within `seconds`; nil when it did not run.
    private nonisolated static func output(of executable: String, _ arguments: [String], seconds: Double) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private static func systemExtensionLines(_ identifier: String) async -> [String] {
        guard let text = await output(of: "/usr/bin/systemextensionsctl", ["list"], seconds: 20) else {
            return ["systemextensionsctl did not run"]
        }
        return text.split(separator: "\n").map(String.init).filter { $0.contains(identifier) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The guard's own log since `start` (`log show`): its words over the same minutes — the filter
    /// started, the processes held and released, every five seconds the flows it was given.
    private static func printGuardLog(since start: Date) async {
        section("The guard's own log since this diagnosis started (log show, subsystem PrivacyBrowser.NetworkGuard)")
        let formatter = DateFormatter() // l10n: not text (log show --start takes this form)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let arguments = ["show", "--style", "compact", "--info", "--start", formatter.string(from: start.addingTimeInterval(-2)),
                         "--predicate", "subsystem == \"PrivacyBrowser.NetworkGuard\""]
        guard let text = await output(of: "/usr/bin/log", arguments, seconds: 60) else {
            say("not read: /usr/bin/log did not run")
            return
        }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Timestamp") && !$0.isEmpty }
        if lines.isEmpty { say("not one line: the guard said nothing over these minutes (or this user cannot read the log)") }
        if lines.count > 80 { say("(the first \(lines.count - 80) lines left out)") }
        for line in lines.suffix(80) { say(line) }
    }

    // MARK: The filter's configuration

    private struct Configuration {
        var lines: [String]
        /// What the configuration says about a filter that gets no flow.
        var hint: String
    }

    private enum Loaded {
        case read
        case failed(NSError)
        case silent
    }

    private static func filterConfiguration(expected identifier: String) async -> Configuration {
        let manager = NEFilterManager.shared()
        // Ten seconds at most: a diagnosis that hangs answers nothing.
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Loaded, Never>) in
            let first = FirstAnswer(continuation)
            manager.loadFromPreferences { error in first.resume(error.map { Loaded.failed($0 as NSError) } ?? Loaded.read) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { first.resume(.silent) }
        }
        switch loaded {
        case .read:
            break
        case .failed(let error):
            return Configuration(lines: ["could not be read: \(error.domain) \(error.code)"],
                                 hint: "Its configuration could not be read here (\(error.domain) \(error.code)).")
        case .silent:
            return Configuration(lines: ["not given in 10 s"], hint: "Its configuration was not given in 10 s.")
        }
        var lines = ["enabled: \(manager.isEnabled ? "yes" : "NO")"]
        guard let provider = manager.providerConfiguration else {
            lines.append("no provider configuration: the filter was never configured on this Mac")
            return Configuration(lines: lines, hint: "Its configuration has no provider at all.")
        }
        let ours = provider.filterDataProviderBundleIdentifier == identifier
        lines.append("socket flows asked for (filterSockets): \(provider.filterSockets ? "yes" : "NO")")
        lines.append("packets asked for (filterPackets): \(provider.filterPackets ? "yes" : "no")")
        lines.append("data provider: \(provider.filterDataProviderBundleIdentifier ?? "none")"
                     + (ours ? " (this app's guard)" : " — NOT this app's guard, \(identifier)"))
        if let packets = provider.filterPacketProviderBundleIdentifier { lines.append("packet provider: \(packets)") }
        if let name = manager.localizedDescription { lines.append("named: \(name)") }
        lines.append("grade: \(manager.grade == .firewall ? "firewall" : "inspector")")
        var hint = "Its configuration (above) is enabled, asks for socket flows and names this guard: configured as it must be."
        if !manager.isEnabled {
            hint = "Its configuration is not enabled."
        } else if !provider.filterSockets {
            hint = "Its configuration asks for no socket flows (filterSockets is off)."
        } else if !ours {
            hint = "Its configuration names another provider than this guard."
        }
        return Configuration(lines: lines, hint: hint)
    }

    // MARK: The guard over XPC

    private static func diagnostics(_ connection: NSXPCConnection) async -> GuardDiagnostics? {
        let data = await NetworkGuard.ask(connection) { (guardian: NetworkGuardControl, done: @escaping (Data) -> Void) in
            guardian.diagnostics { done($0) }
        }
        return data.flatMap { try? JSONDecoder().decode(GuardDiagnostics.self, from: $0) }
    }

    /// Asks the guard to hold `pid` as the app holds its probe: nil when it did, the reason otherwise.
    private static func hold(_ pid: Int32, on connection: NSXPCConnection) async -> String? {
        let registration = GuardRegistration(pid: pid, proxyHost: "127.0.0.1", proxyPort: 9, proxyAddresses: [])
        guard let data = try? JSONEncoder().encode(registration) else { return "unencodable" }
        let answer = await NetworkGuard.ask(connection) { (guardian: NetworkGuardControl, done: @escaping ((Bool, String?)) -> Void) in
            guardian.hold(data) { done(($0, $1)) }
        }
        guard let answer else { return "no answer" }
        return answer.0 ? nil : (answer.1 ?? "refused")
    }

    // MARK: This process's own flows

    /// A UDP datagram and a TCP connection to `ownAddress`: a process the guard does not hold, as any
    /// on this Mac — the filter must see both, counted for this process, and let them through.
    private static func sendOwnFlows() -> [String] {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ownAddress, &address.sin_addr)
        var lines: [String] = []

        let udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if udp >= 0 {
            address.sin_port = in_port_t(9).bigEndian
            let payload = Array("Lumen's guard diagnosis".utf8)
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udp, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            lines.append(sent >= 0 ? "UDP to \(ownAddress):9: one datagram sent"
                                   : "UDP to \(ownAddress):9: not sent (\(String(cString: strerror(errno))))")
            close(udp)
        } else {
            lines.append("UDP: no socket (\(String(cString: strerror(errno))))")
        }

        let tcp = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if tcp >= 0 {
            address.sin_port = in_port_t(80).bigEndian
            _ = fcntl(tcp, F_SETFL, fcntl(tcp, F_GETFL) | O_NONBLOCK)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let error = errno
            if result == 0 || error == EINPROGRESS {
                var descriptor = pollfd(fd: tcp, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 1_000)
                lines.append("TCP to \(ownAddress):80: connection asked for (no answer is expected: the address is never routed)")
            } else {
                lines.append("TCP to \(ownAddress):80: not asked for (\(String(cString: strerror(error))))")
            }
            close(tcp)
        } else {
            lines.append("TCP: no socket (\(String(cString: strerror(errno))))")
        }
        return lines
    }

    // MARK: The probe

    private struct ProbeRun {
        var pid: Int32 = 0
        var refusal: String?
        var lines: [String] = []
        var report: GuardReport?
        var seconds: Double = 0
        var endedBy = "did not start"
        /// The kernel's table read by this process while the probe ran: each socket to the probe's
        /// STUN address, the first time it was seen (and again if whom it is counted for changed).
        var kernelLines: [String] = []

        /// The probe's own account in one sentence: what its page did, from its lines.
        var summary: String {
            let page = lines.filter { $0.contains(" page ") }
            guard !page.isEmpty else {
                return refusal.map { "none — it was not held (\($0)), so it was told nothing and sent nothing" }
                    ?? "no account of its page (its lines above)"
            }
            let asked = page.contains { $0.contains("gathering asked") } ? "its page asked WebKit to gather" : "its page never asked to gather"
            let candidates = page.filter { $0.contains("candidate ") && !$0.contains("candidates:") }.count
            let errors = page.filter { $0.contains("error from") }
            return "\(asked); \(candidates) candidate(s); "
                + (errors.isEmpty ? "no error from the STUN server's address (WebKit may report none)"
                                  : "\(errors.count) error(s) from the STUN server's address — WebKit tried it: \(errors[0])")
        }
    }

    /// The probe, started as the app's check starts it (LumenProfile), held to a proxy that is not
    /// there, told to go, waited for (25 s at most), its report read, released (NetworkGuard.prove).
    private static func runProbe(_ connection: NSXPCConnection) async -> ProbeRun {
        var run = ProbeRun()
        let executable: URL
        do {
            executable = try ProfileExecutable.url()
        } catch {
            // ProfileExecutable's own words: missing, unreadable, or signed with a keychain.
            run.lines = ["the probe was not started: \(String(describing: error))"]
            return run
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--guard-probe"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let collected = ProbeLines()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collected.end()
            } else {
                collected.append(chunk)
            }
        }
        let launched = Date()
        do {
            try process.run()
        } catch {
            run.lines = ["the probe did not start: \(error.localizedDescription)"]
            return run
        }
        let pid = process.processIdentifier
        run.pid = pid
        if let refusal = await hold(pid, on: connection) {
            // As the app: a probe not held is told nothing and sends nothing.
            run.refusal = refusal
            try? input.fileHandleForWriting.close()
            process.terminate()
            run.endedBy = "was ended: the guard did not hold it"
            run.lines = ["the probe (pid \(pid)) was not held by the guard: \(refusal)"] + collected.lines
            return run
        }
        try? input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
        try? input.fileHandleForWriting.close()
        // While it runs, this process reads the kernel's table itself — what a packet capture shows as
        // proc and eproc — every tenth of a second: the third account beside the filter's and the
        // probe's own.
        var seen: [UInt16: Int32] = [:]
        for _ in 0..<250 where process.isRunning {
            switch SocketTable.read(.udp) {
            case .failure(let error):
                if run.kernelLines.isEmpty { run.kernelLines.append("the kernel's table could not be read here: \(error)") }
            case .success(let sockets):
                for socket in sockets where socket.remoteAddress == GuardProof.stunAddress && socket.remotePort == GuardProof.stunPort
                    && seen[socket.localPort] != socket.countedFor {
                    seen[socket.localPort] = socket.countedFor
                    let whose = socket.countedFor == pid ? " — the probe" : " — NOT the probe (pid \(pid))"
                    let milliseconds = Int(Date().timeIntervalSince(launched) * 1000)
                    run.kernelLines.append("+\(milliseconds) ms \(socket)\(whose)")
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            run.endedBy = "was ended after 25 s by this diagnosis"
        } else {
            run.endedBy = "ended by itself (exit status \(process.terminationStatus))"
        }
        run.seconds = Date().timeIntervalSince(launched)
        let data = await NetworkGuard.ask(connection) { (guardian: NetworkGuardControl, done: @escaping (Data) -> Void) in
            guardian.report(pid) { done($0) }
        }
        run.report = data.flatMap { try? JSONDecoder().decode(GuardReport.self, from: $0) }
        _ = await NetworkGuard.ask(connection) { (guardian: NetworkGuardControl, done: @escaping (Bool) -> Void) in
            guardian.release(pid) { done(true) }
        }
        for _ in 0..<20 where !collected.ended { try? await Task.sleep(nanoseconds: 100_000_000) }
        run.lines = ["the probe: pid \(pid), held by the guard, told to go"] + collected.lines
        if let report = run.report {
            run.lines.append("the guard's report for it: dropped \(report.dropped), allowed \(report.allowed), seen on its behalf "
                             + "\(report.seenOnItsBehalf)" + (report.recentDrops.isEmpty ? "" : "; dropped: "
                                + report.recentDrops.map { "\($0.transport.rawValue) \($0.remote) by \($0.by)" }.joined(separator: ", ")))
        } else {
            run.lines.append("the guard gave no report for it")
        }
        return run
    }
}

/// Resumes a continuation with the first of an answer and a timeout.
private final class FirstAnswer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// The probe's stdout as it comes, filled from the pipe's own queue.
private final class ProbeLines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var sawEnd = false

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    /// The pipe said there is no more.
    func end() {
        lock.lock()
        sawEnd = true
        lock.unlock()
    }

    var ended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawEnd
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
