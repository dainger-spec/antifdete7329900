import BrowserCore
import CryptoKit
import Darwin
import Foundation
import OpenVPNLink
import os

/// A profile's OpenVPN connection (docs/OPENVPN.md): started by the app for one launch, and seen
/// by the profile as a SOCKS5 proxy on 127.0.0.1 with that launch's own user name and password —
/// the same shape as every other proxy, so that everything a proxied profile has (its process held
/// to its proxy, WebRTC through the relay, the location lookup) holds for it unchanged.
///
/// What runs, and how far each part can reach:
/// - `openvpn` (Contents/MacOS/openvpn, OpenVPN 2.7 built from pinned sources, unprivileged),
///   started under `sandbox-exec` with a profile that refuses every network operation but on
///   loopback; its configuration comes on its standard input and names no server: each of its
///   servers is a loopback port of this app's (`LoopbackForwarders`), which carries to that
///   server's one address and nowhere else;
/// - `LumenTunnel` (Contents/MacOS/LumenTunnel), which OpenVPN starts as its tun device (2.7's
///   AF_UNIX tun) inside the same sandbox: the tunnel's packets on one side, the profile's SOCKS5
///   port on the other (the listening socket made here and passed down), names looked up at the
///   pushed DNS servers through the tunnel;
/// - nothing of this Mac's routes, addresses or DNS changes.
///
/// Fail closed: while the tunnel is down there is nothing behind the port — its connections are
/// refused — and a tunnel not back within `reconnectGrace` stops the profile, said.
@MainActor
final class OpenVPNTunnels {
    static let shared = OpenVPNTunnels()
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "OpenVPN")

    /// How long a tunnel that went down may take to come back before its profile is stopped.
    static var reconnectGrace: TimeInterval = 45
    /// How long a tunnel may take to come up at a launch.
    static var startTimeout: TimeInterval = 40

    /// Why a tunnel did not come up, or went away; said in the person's language (`text`).
    enum Failure: Error, Equatable {
        /// This build has no OpenVPN (built without OVPN=1).
        case notInThisBuild
        /// Only for a profile in its own process (the sandboxed development build has none).
        case needsOwnProcess
        case configuration(OpenVPNConfigProblem)
        case credentialsNeeded
        /// The server's name could not be resolved.
        case serverNotFound
        case authenticationFailed
        /// The TLS handshake failed: a certificate refused, or the server's keys not the ones given.
        case certificateRefused
        /// Nothing answered from the server in time.
        case serverNotAnswering
        /// OpenVPN refused its configuration (`Options error`): its own words, for the log.
        case refusedByOpenVPN(String)
        /// OpenVPN or the tunnel's program ended, or could not be started.
        case ended(String)
        /// The confinement could not be applied: OpenVPN is not started without it.
        case notConfined
        /// The tunnel went down and did not come back within the grace period.
        case lost

        var text: String {
            switch self {
            case .notInThisBuild: return L("openvpn.failure.notInThisBuild")
            case .needsOwnProcess: return L("openvpn.failure.needsOwnProcess")
            case .configuration(let problem): return OpenVPNTexts.problem(problem)
            case .credentialsNeeded: return L("openvpn.failure.credentialsNeeded")
            case .serverNotFound: return L("openvpn.failure.serverNotFound")
            case .authenticationFailed: return L("openvpn.failure.authenticationFailed")
            case .certificateRefused: return L("openvpn.failure.certificateRefused")
            case .serverNotAnswering: return L("openvpn.failure.serverNotAnswering")
            case .refusedByOpenVPN: return L("openvpn.failure.refusedByOpenVPN")
            case .ended: return L("openvpn.failure.ended")
            case .notConfined: return L("openvpn.failure.notConfined")
            case .lost: return L("openvpn.failure.lost")
            }
        }
    }

    /// A tunnel went down for good while its profile ran: the profile is stopped (`ProfileManager`).
    var onLost: ((UUID, Failure) -> Void)?

    private var tunnels: [UUID: OpenVPNTunnel] = [:]

    /// The bundled programs, or nil when this build has none. `PB_OPENVPN_DIR` names another
    /// folder holding both (the CI's checks run them from the build).
    static var programs: (openvpn: URL, tunnel: URL)? {
        let folder: URL
        if let override = ProcessInfo.processInfo.environment["PB_OPENVPN_DIR"], !override.isEmpty {
            folder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            folder = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        }
        let openvpn = folder.appendingPathComponent("openvpn")
        let tunnel = folder.appendingPathComponent("LumenTunnel")
        guard FileManager.default.isExecutableFile(atPath: openvpn.path), FileManager.default.isExecutableFile(atPath: tunnel.path) else {
            return nil
        }
        return (openvpn, tunnel)
    }

    var isAvailable: Bool { Self.programs != nil }

    /// Starts `proxy`'s tunnel for profile `id` and returns the proxy the profile is given: SOCKS5
    /// on 127.0.0.1, this launch's credentials, the bypass list of the original. A tunnel already
    /// running for the profile is stopped first.
    func start(profile id: UUID, proxy: ProxySettings) async throws -> ProxySettings {
        stop(profile: id)
        guard let openVPN = proxy.openVPN else { throw Failure.configuration(.missing("configuration")) }
        guard let programs = Self.programs else { throw Failure.notInThisBuild }
        let configuration: OpenVPNConfiguration
        do {
            configuration = try openVPN.parsed()
        } catch let problem as OpenVPNConfigProblem {
            throw Failure.configuration(problem)
        }
        if configuration.needsCredentials, (proxy.username ?? "").isEmpty || (proxy.password ?? "").isEmpty {
            throw Failure.credentialsNeeded
        }
        // The servers' addresses, asked of this Mac's resolver: the VPN server's own name is the
        // one thing the tunnel cannot look up itself. Nothing of the profile's is asked.
        let targets = await Self.resolve(configuration.remotes)
        guard !targets.isEmpty else { throw Failure.serverNotFound }
        let tunnel = try OpenVPNTunnel(profileID: id, configuration: configuration, targets: targets, proxy: proxy,
                                       programs: programs)
        tunnels[id] = tunnel
        tunnel.onLost = { [weak self, weak tunnel] failure in
            guard let self, let tunnel, self.tunnels[id] === tunnel else { return }
            Self.log.error("The OpenVPN tunnel of \(id.uuidString, privacy: .public) is gone: \(String(describing: failure), privacy: .private)")
            self.tunnels[id] = nil
            tunnel.stop()
            self.onLost?(id, failure)
        }
        do {
            try await tunnel.waitUntilUp(timeout: Self.startTimeout)
        } catch {
            tunnels[id] = nil
            tunnel.stop()
            Self.log.error("The OpenVPN tunnel of \(id.uuidString, privacy: .public) did not come up: \(String(describing: error), privacy: .private)")
            throw error
        }
        Self.log.notice("The OpenVPN tunnel of \(id.uuidString, privacy: .public) is up")
        return tunnel.localProxy
    }

    /// Stops the tunnel of profile `id`, if it has one.
    func stop(profile id: UUID) {
        guard let tunnel = tunnels.removeValue(forKey: id) else { return }
        tunnel.stop()
        Self.log.notice("The OpenVPN tunnel of \(id.uuidString, privacy: .public) is stopped")
    }

    func stopAll() {
        for id in Array(tunnels.keys) { stop(profile: id) }
    }

    func isRunning(_ id: UUID) -> Bool { tunnels[id] != nil }

    /// The tunnel's OpenVPN log, last lines (for the diagnosis; never written anywhere by itself).
    func recentLog(of id: UUID) -> [String] { tunnels[id]?.recentLog ?? [] }

    /// Checks an OpenVPN connection as a proxy is checked (`ProxyChecker`): through a tunnel made
    /// for the check alone, stopped after it. A tunnel that does not come up is a dead proxy.
    static func check(_ proxy: ProxySettings, latencySamples: Int, triesUDP: Bool) async -> ProxyCheckResult {
        let time = Date()
        let checkID = UUID()
        let local: ProxySettings
        do {
            local = try await shared.start(profile: checkID, proxy: proxy)
        } catch {
            log.notice("An OpenVPN connection's check: the tunnel did not come up")
            return .dead(error as? Failure == .credentialsNeeded || error as? Failure == .authenticationFailed ? .needsCredentials : .noAnswer,
                         at: time)
        }
        let result = await ProxyChecker.check(local, latencySamples: latencySamples, triesUDP: triesUDP)
        shared.stop(profile: checkID)
        return result
    }

    /// The servers' addresses: for each, its first IPv4 address, else its first IPv6 one, with its
    /// transport. Servers whose name does not resolve are left out.
    nonisolated static func resolve(_ remotes: [OpenVPNConfiguration.Remote]) async -> [Int: LoopbackForwarders.Target] {
        await withTaskGroup(of: (Int, LoopbackForwarders.Target?).self) { group in
            for (index, remote) in remotes.enumerated() {
                group.addTask {
                    let address = await Task.detached { lookUp(remote.host) }.value
                    guard let address, let port = UInt16(exactly: remote.port) else { return (index, nil) }
                    return (index, LoopbackForwarders.Target(address: address, port: port, transport: remote.transport == .udp ? .udp : .tcp))
                }
            }
            var found: [Int: LoopbackForwarders.Target] = [:]
            for await (index, target) in group { if let target { found[index] = target } }
            return found
        }
    }

    nonisolated private static func lookUp(_ host: String) -> TunnelAddress? {
        if let literal = TunnelAddress(host) { return literal }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var four: TunnelAddress?
        var six: TunnelAddress?
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            if let socketAddress = current.pointee.ai_addr {
                var storage = sockaddr_storage()
                memcpy(&storage, socketAddress, Int(current.pointee.ai_addrlen))
                if let endpoint = TunnelSystem.endpoint(of: storage) {
                    // An answer that is this Mac itself would make the forwarder a way back in.
                    if !TunnelSystem.isLoopback(endpoint.address) && !endpoint.address.isAny {
                        if endpoint.address.family == .v4, four == nil { four = endpoint.address }
                        if endpoint.address.family == .v6, six == nil { six = endpoint.address }
                    }
                }
            }
            entry = current.pointee.ai_next
        }
        return four ?? six
    }

    /// OpenVPN processes of this app that an earlier run left (it crashed): ended at the start.
    static func endLeftovers() {
        guard let openvpn = programs?.openvpn.resolvingSymlinksInPath().path else { return }
        let count = proc_listpids(UInt32(PROC_UID_ONLY), uid_t(getuid()), nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_UID_ONLY), uid_t(getuid()), $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(cString: path) == openvpn {
                kill(pid, SIGTERM)
                log.notice("An OpenVPN process an earlier run left (\(Int(pid), privacy: .public)) is ended")
            }
        }
    }
}

/// One profile's tunnel: its forwarders, its local port, OpenVPN and what it says.
@MainActor
final class OpenVPNTunnel {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "OpenVPN")

    enum State: Equatable {
        case starting
        case up
        case down(since: Date)
        case stopped
    }

    let profileID: UUID
    let localProxy: ProxySettings
    private(set) var state = State.starting
    private(set) var recentLog: [String] = []
    var onLost: ((OpenVPNTunnels.Failure) -> Void)?

    private let forwarders: LoopbackForwarders
    /// The profile's port, until it is handed to OpenVPN (then OpenVPN and its tun program hold it
    /// alone: with them gone, the port is closed and refuses).
    private var listener: Int32
    private var pid: pid_t = 0
    private var processSource: DispatchSourceProcess?
    private var logReader: LineReader?
    private var statusReader: LineReader?
    private var lifelineWrite: Int32 = -1
    private var waiters: [CheckedContinuation<Void, Error>] = []
    /// What the log said went wrong last, for the failure given when the tunnel does not come up.
    private var lastProblem: OpenVPNTunnels.Failure?
    private var graceTask: Task<Void, Never>?

    init(profileID: UUID, configuration: OpenVPNConfiguration, targets: [Int: LoopbackForwarders.Target], proxy: ProxySettings,
         programs: (openvpn: URL, tunnel: URL)) throws {
        self.profileID = profileID
        // The servers, each behind its forwarder; the configuration names their loopback ports only.
        let order = targets.keys.sorted()
        do {
            forwarders = try LoopbackForwarders(targets: order.map { targets[$0]! })
        } catch {
            throw OpenVPNTunnels.Failure.ended("forwarders: \(error)")
        }
        var ports: [Int: UInt16] = [:]
        for (position, index) in order.enumerated() { ports[index] = forwarders.ports[position] }
        // The profile's port, and this launch's credentials. The tunnel's program gets only their SHA-256.
        guard let (listening, port) = TunnelSystem.loopbackListener(backlog: 128) else {
            forwarders.stop()
            throw OpenVPNTunnels.Failure.ended("listener")
        }
        listener = listening
        let username = "lumen-" + Self.randomHex(4)
        let password = Self.randomHex(16)
        localProxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: Int(port), username: username, password: password,
                                   excludedDomains: proxy.excludedDomains)
        let verifier = CredentialCheck.verifier(username: Array(username.utf8), password: Array(password.utf8))
        let text: String
        do {
            text = try configuration.runtime(forwarders: ports, tunnelProgram: programs.tunnel.path,
                                             username: proxy.username, password: proxy.password,
                                             listeningDescriptor: 3, statusDescriptor: 4, verifierHex: CredentialCheck.hex(verifier))
                + "setenv LUMEN_LIFELINE_FD 5\n"
        } catch let problem as OpenVPNConfigProblem {
            close(listening)
            forwarders.stop()
            throw OpenVPNTunnels.Failure.configuration(problem)
        }
        try launch(openvpn: programs.openvpn, configuration: text)
    }

    /// The sandbox OpenVPN and its tun program run in: every network operation refused but on
    /// loopback (the forwarders, the profile's port, the UDP associations' sockets). Not this Mac's
    /// resolver either: its socket is not on loopback, and its Mach service is refused.
    static let confinement = """
        (version 1)
        (allow default)
        (deny network*)
        (allow network-outbound (remote ip "localhost:*"))
        (allow network-inbound (local ip "localhost:*"))
        (allow network-bind (local ip "localhost:*"))
        (deny mach-lookup (global-name "com.apple.dnssd.service") (global-name "com.apple.mDNSResponder"))
        """

    private func launch(openvpn: URL, configuration: String) throws {
        // The descriptors the child gets: 0 its configuration, 1 and 2 its log, 3 the profile's
        // port, 4 the tunnel program's status, 5 a lifeline only this app holds the other end of.
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], status: [Int32] = [0, 0], lifeline: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&status) == 0, pipe(&lifeline) == 0 else {
            throw OpenVPNTunnels.Failure.ended("pipes")
        }
        for descriptor in [input[1], output[0], status[0], lifeline[1]] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        // Each source moved above the numbers it is given at first: a source that already had one
        // of them (or another's) would be closed or kept by the wrong dup2.
        func high(_ descriptor: Int32) -> Int32 {
            let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, 16)
            close(descriptor)
            return moved
        }
        input[0] = high(input[0]); output[1] = high(output[1]); status[1] = high(status[1]); lifeline[0] = high(lifeline[0])
        listener = high(listener)
        guard [input[0], output[1], status[1], lifeline[0], listener].allSatisfy({ $0 >= 16 }) else {
            throw OpenVPNTunnels.Failure.ended("descriptors")
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, output[1], 2)
        posix_spawn_file_actions_adddup2(&actions, listener, 3)
        posix_spawn_file_actions_adddup2(&actions, status[1], 4)
        posix_spawn_file_actions_adddup2(&actions, lifeline[0], 5)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing else of this process is inherited; a group of its own, so that a stop ends
        // OpenVPN and its tun program together; signals as a new process has them.
        var defaults = sigset_t()
        sigfillset(&defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let arguments = ["/usr/bin/sandbox-exec", "-p", Self.confinement, openvpn.path, "--config", "stdin"]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var child: pid_t = 0
        let result = posix_spawn(&child, arguments[0], &actions, &attributes, &argv, &envp)
        // The child's ends are the child's alone now, the profile's port included.
        close(input[0]); close(output[1]); close(status[1]); close(lifeline[0])
        close(listener)
        listener = -1
        guard result == 0 else {
            close(input[1]); close(output[0]); close(status[0]); close(lifeline[1])
            forwarders.stop()
            throw OpenVPNTunnels.Failure.ended("spawn \(result)")
        }
        pid = child
        lifelineWrite = lifeline[1]
        Self.log.notice("OpenVPN for \(self.profileID.uuidString, privacy: .public) runs as pid \(Int(child), privacy: .public)")

        // The configuration, then the end of standard input: written from a queue of its own, so
        // that a child that does not read cannot hold the main thread.
        let data = Data(configuration.utf8)
        let writeEnd = input[1]
        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(writeEnd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(writeEnd)
        }
        logReader = LineReader(descriptor: output[0]) { [weak self] line in self?.heard(line) }
        statusReader = LineReader(descriptor: status[0]) { [weak self] line in self?.status(line) }
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.exited() }
        }
        source.resume()
        processSource = source
    }

    func waitUntilUp(timeout: TimeInterval) async throws {
        if state == .up { return }
        if state == .stopped { throw lastProblem ?? OpenVPNTunnels.Failure.ended("stopped") }
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.resumeWaiters(with: self?.lastProblem ?? .serverNotAnswering)
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { continuation in waiters.append(continuation) }
    }

    private func resumeWaiters(with failure: OpenVPNTunnels.Failure?) {
        let pending = waiters
        waiters = []
        for waiter in pending {
            if let failure { waiter.resume(throwing: failure) } else { waiter.resume() }
        }
    }

    /// A line of OpenVPN's log (kept in memory, the last 200, never written anywhere else here).
    private func heard(_ line: String) {
        recentLog.append(line)
        if recentLog.count > 200 { recentLog.removeFirst(recentLog.count - 200) }
        if let problem = Self.problem(in: line) { lastProblem = problem }
        if line.contains("SIGUSR1[") || line.contains("Restart pause") || line.contains("Connection reset, restarting") {
            wentDown()
        }
    }

    /// What a line of OpenVPN's log says went wrong, if anything a person can act on.
    static func problem(in line: String) -> OpenVPNTunnels.Failure? {
        if line.contains("AUTH_FAILED") { return .authenticationFailed }
        if line.contains("VERIFY ERROR") || line.contains("certificate verify failed") || line.contains("TLS_ERROR: BIO read tls_read_plaintext error")
            || line.contains("X509_V_ERR") || line.contains("VERIFY EKU ERROR") || line.contains("VERIFY KU ERROR") {
            return .certificateRefused
        }
        if line.contains("TLS key negotiation failed to occur") || line.contains("TLS handshake failed") { return .serverNotAnswering }
        if line.contains("Options error") { return .refusedByOpenVPN(line) }
        if line.contains("Cannot load") || line.contains("Cannot open") { return .refusedByOpenVPN(line) }
        return nil
    }

    /// A line from the tunnel's program: up (its port serves), down (it ended).
    private func status(_ line: String) {
        guard let data = line.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let event = fields["event"] else { return }
        switch event {
        case "up":
            Self.log.notice("The tunnel of \(self.profileID.uuidString, privacy: .public) is up")
            state = .up
            graceTask?.cancel()
            graceTask = nil
            resumeWaiters(with: nil)
        case "down":
            wentDown()
        case "error":
            lastProblem = .ended(fields["reason"] ?? "error")
        default:
            break
        }
    }

    /// Down: nothing is behind the profile's port until OpenVPN is back; past the grace period the
    /// profile is stopped.
    private func wentDown() {
        guard state == .up else { return }
        state = .down(since: Date())
        Self.log.notice("The tunnel of \(self.profileID.uuidString, privacy: .public) is down; OpenVPN reconnects")
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(OpenVPNTunnels.reconnectGrace * 1_000_000_000))
            guard !Task.isCancelled, let self, case .down = self.state else { return }
            self.onLost?(.lost)
        }
    }

    private func exited() {
        guard state != .stopped else { return }
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        processSource?.cancel()
        processSource = nil
        let failure = lastProblem ?? .ended("exit \(status)")
        Self.log.notice("OpenVPN of \(self.profileID.uuidString, privacy: .public) ended (status \(Int(status), privacy: .public))")
        state = .stopped
        // The forwarders and the port go with it: nothing is left listening for no one.
        lifelineCut()
        forwarders.stop()
        resumeWaiters(with: failure)
        onLost?(failure)
    }

    /// Ends OpenVPN and its tun program, the forwarders and the port.
    func stop() {
        let previous = state
        state = .stopped
        graceTask?.cancel()
        graceTask = nil
        if pid > 0, previous != .stopped {
            // The process group: OpenVPN and LumenTunnel together. SIGTERM, then SIGKILL; reaped
            // here, whatever becomes of this object.
            kill(-pid, SIGTERM)
            let group = pid
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(-group, SIGKILL) }
            DispatchQueue.global().async {
                var status: Int32 = 0
                waitpid(group, &status, 0)
            }
        }
        processSource?.cancel()
        processSource = nil
        lifelineCut()
        logReader?.close()
        statusReader?.close()
        forwarders.stop()
        if listener >= 0 { close(listener); listener = -1 }
        resumeWaiters(with: lastProblem ?? .ended("stopped"))
    }

    private func lifelineCut() {
        if lifelineWrite >= 0 { close(lifelineWrite); lifelineWrite = -1 }
    }

    private static func randomHex(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return CredentialCheck.hex((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// Lines from a pipe, handed to the main actor.
private final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var pending = Data()

    init(descriptor: Int32, onLine: @escaping @MainActor (String) -> Void) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.pending.append(data)
            var lines: [String] = []
            while let newline = self.pending.firstIndex(of: 0x0A) {
                let line = self.pending[self.pending.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                self.pending.removeSubrange(self.pending.startIndex...newline)
            }
            if self.pending.count > 65_536 { self.pending.removeAll() }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for line in lines { onLine(line) } }
            }
        }
    }

    func close() {
        handle.readabilityHandler = nil
    }
}
