import BrowserCore
import Darwin
import Foundation
import os

/// The relays of profiles whose proxy is a VLESS, VMess, Trojan or Shadowsocks link
/// (`ProxySettings.Kind.xray`; docs/TUNNEL.md, "Links"): one Xray process per running profile (and
/// per check of such a proxy, and per virtual machine on one), started by this process — the
/// manager — never by the profile's.
///
/// - **In.** SOCKS5 on 127.0.0.1 at a port free when it starts, with a user name and password made
///   for this run (`XrayConfig.Inbound.random`): a profile is held to that port by its proxy
///   configuration, and no other process of this Mac can use the relay without the login. The
///   login travels to the profile's process on its standard input with its grant (`ProxyRoutes`),
///   never in argv or the environment; the configuration reaches Xray the same way (`-c stdin:`).
/// - **Out.** The link's server and nothing else: the configuration has no other outbound
///   (`XrayConfig`), and the relay runs in a sandbox the kernel holds it to before Xray's code is
///   loaded (`XrayRelayLauncher`): no connection but to the server's port, UDP to this Mac's loopback and
///   to the system's resolver (the server's own name is the one it resolves), no file written.
/// - **Fail closed.** A relay that ends while its profile runs is started again on the same port with
///   the same login (twice in a minute at most); until it answers, the profile's loads fail — its
///   data store has no other proxy and failover is off. One that cannot be started again stops its
///   profile with a message (`onDied`). A link with no relay running is never reached any other way
///   (`ProxyRoutes.connectable` is nil, and the profile gets a proxy that does not exist).
@MainActor
final class XrayRelays {
    static let shared = XrayRelays()
    private let log = Logger(subsystem: "PrivacyBrowser", category: "XrayRelays")

    enum StartError: Error, Equatable {
        /// This build has no relay (`XRAY=1 scripts/build-app.sh` puts it in), or is sandboxed.
        case notInBuild
        /// The link does not read (`ShareLinkError`'s description, which holds no secret).
        case invalidLink(String)
        /// Xray ended, or did not answer with its login, in time; its own words are in the log.
        case didNotStart
    }

    private final class Relay {
        let id = UUID()
        let owner: UUID
        let link: String
        let serverPort: Int
        let inbound: XrayConfig.Inbound
        var process: Process?
        var stopping = false
        var restarts: [Date] = []
        let onDied: (@MainActor (String) -> Void)?
        let output = OutputTail()

        init(owner: UUID, link: String, serverPort: Int, inbound: XrayConfig.Inbound, onDied: (@MainActor (String) -> Void)?) {
            self.owner = owner
            self.link = link
            self.serverPort = serverPort
            self.inbound = inbound
            self.onDied = onDied
        }
    }

    /// The last lines Xray wrote (errors only: its log level is "error"), for the log when it ends.
    private final class OutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ text: String) {
            lock.withLock {
                lines.append(contentsOf: text.split(whereSeparator: \.isNewline).map { String($0.prefix(300)) })
                if lines.count > 20 { lines.removeFirst(lines.count - 20) }
            }
        }
        var text: String { lock.withLock { lines.joined(separator: " | ") } }
    }

    private var relays: [UUID: Relay] = [:]

    /// What the last relay that did not start wrote (Xray's errors, the launcher's), for the check of
    /// links to print (`XrayCheck`); the app's log has it as private data.
    private(set) var lastStartFailure: String?

    /// How many times a minute a relay that ended is started again before its owner is told
    /// (`onDied`). The check of links (`XrayCheck`) sets 0, to see what a relay that stays dead does.
    var restartLimit = 2

    /// `owner`'s own relay's route — not another profile's on the same link (`ProxyRoutes` keeps the
    /// newest of a link's relays for whoever asks by the link).
    func route(owner: UUID) -> ProxyRoutes.Route? {
        relays.values.first { $0.owner == owner && $0.process?.isRunning == true }?.inbound.route
    }

    /// The process of `owner`'s relay (`XrayCheck`: the capture's and the fail-closed check's).
    func processIdentifier(owner: UUID) -> pid_t? {
        relays.values.first { $0.owner == owner && $0.process?.isRunning == true }?.process?.processIdentifier
    }

    /// Xray as this build carries it: `Contents/MacOS/LumenXray`.
    nonisolated static var executable: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LumenXray")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Whether this build can run a link's relay: it carries Xray, and is not sandboxed (a sandboxed
    /// app's child would inherit the App Sandbox, with no way to hold it to one server).
    nonisolated static var isAvailable: Bool { executable != nil && !AppEnvironment.isSandboxed }

    /// Whether a relay of `owner`'s runs now.
    func isRunning(owner: UUID) -> Bool { relays.values.contains { $0.owner == owner && $0.process?.isRunning == true } }

    /// Starts `owner`'s relay for `proxy`'s link and returns when it answers with its login; it is
    /// then the link's route (`ProxyRoutes`). A relay `owner` already has is stopped first.
    @discardableResult
    func start(for proxy: ProxySettings, owner: UUID, onDied: (@MainActor (String) -> Void)? = nil) async throws -> ProxyRoutes.Route {
        stop(owner: owner)
        guard Self.isAvailable, let executable = Self.executable else { throw StartError.notInBuild }
        guard proxy.kind == .xray, let text = proxy.link else { throw StartError.invalidLink("not a link") }
        let link: ShareLink
        do { link = try ShareLink.parse(text) } catch { throw StartError.invalidLink(String(describing: error)) }
        // A port taken between finding it free and Xray binding it ends Xray at once: another one.
        for attempt in 1...3 {
            guard let port = Self.freePort() else { break }
            let relay = Relay(owner: owner, link: text, serverPort: link.port, inbound: XrayConfig.Inbound.random(port: port), onDied: onDied)
            relays[relay.id] = relay
            if await launch(relay, link: link, executable: executable) {
                ProxyRoutes.shared.add(relay.inbound.route, for: text, id: relay.id)
                let pid = relay.process?.processIdentifier ?? 0
                log.notice("The relay of \(owner.uuidString, privacy: .public) runs (\(link.scheme.rawValue, privacy: .public), pid \(pid, privacy: .public))")
                return relay.inbound.route
            }
            relays[relay.id] = nil
            lastStartFailure = relay.output.text
            log.error("The relay of \(owner.uuidString, privacy: .public) did not start, attempt \(Int(attempt), privacy: .public): \(relay.output.text, privacy: .private)")
            if Task.isCancelled { break }
        }
        throw StartError.didNotStart
    }

    /// Stops `owner`'s relay, if it has one: its route goes first, so nothing is sent to its port
    /// while it ends.
    func stop(owner: UUID) {
        for relay in relays.values where relay.owner == owner {
            relay.stopping = true
            ProxyRoutes.shared.remove(id: relay.id)
            relays[relay.id] = nil
            if let process = relay.process, process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    /// Every relay (the app quits).
    func stopAll() {
        for owner in Set(relays.values.map(\.owner)) { stop(owner: owner) }
    }

    /// The relay's process: the app's own executable, which puts itself in the relay's sandbox and
    /// becomes Xray (`XrayRelayLauncher`), its configuration on standard input. True once it answers
    /// a SOCKS5 login with the launch's credentials.
    private func launch(_ relay: Relay, link: ShareLink, executable: URL) async -> Bool {
        guard let launcher = Bundle.main.executableURL, var config = try? XrayConfig.json(for: link, inbound: relay.inbound) else {
            return false
        }
        defer { config.resetBytes(in: 0..<config.count) }
        let process = Process()
        process.executableURL = launcher
        process.arguments = [XrayRelayLauncher.argument, executable.path, String(relay.serverPort)]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let tail = relay.output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            tail.append(String(decoding: data, as: UTF8.self))
        }
        let id = relay.id
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { XrayRelays.shared.ended(id, process: finished, status: status) } }
        }
        do {
            try process.run()
        } catch {
            log.error("The relay's process could not be started: \(error.logKind, privacy: .public)")
            return false
        }
        relay.process = process
        try? input.fileHandleForWriting.write(contentsOf: config)
        try? input.fileHandleForWriting.close()
        return await Self.answers(port: relay.inbound.port, username: relay.inbound.username, password: relay.inbound.password,
                                  while: process, within: 10)
    }

    /// A relay's process ended. One that was not stopped is started again on its port with its login,
    /// at most twice a minute; one that cannot be is its owner's to stop (`onDied`).
    private func ended(_ id: UUID, process: Process, status: Int32) {
        guard let relay = relays[id], relay.process === process, !relay.stopping else { return }
        ProxyRoutes.shared.remove(id: id)
        log.error("The relay of \(relay.owner.uuidString, privacy: .public) ended (status \(status, privacy: .public)): \(relay.output.text, privacy: .private)")
        let now = Date()
        relay.restarts = relay.restarts.filter { now.timeIntervalSince($0) < 60 }
        guard relay.restarts.count < restartLimit, let executable = Self.executable, let link = try? ShareLink.parse(relay.link) else {
            die(relay)
            return
        }
        relay.restarts.append(now)
        Task { @MainActor in
            if await self.launch(relay, link: link, executable: executable), self.relays[id] === relay, !relay.stopping {
                ProxyRoutes.shared.add(relay.inbound.route, for: relay.link, id: id)
                self.log.notice("The relay of \(relay.owner.uuidString, privacy: .public) runs again")
            } else if self.relays[id] === relay, !relay.stopping {
                self.die(relay)
            }
        }
    }

    private func die(_ relay: Relay) {
        relays[relay.id] = nil
        relay.stopping = true
        ProxyRoutes.shared.remove(id: relay.id)
        relay.process?.terminate()
        relay.onDied?(relay.output.text)
    }

    // MARK: Sockets

    /// A TCP port on 127.0.0.1 nothing listens on now.
    nonisolated static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Whether the relay on `port` takes the launch's SOCKS5 login, asked until `seconds` pass or
    /// `process` ends. Off the main thread.
    static func answers(port: Int, username: String, password: String, while process: Process, within seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline, process.isRunning {
                    if socksLogin(port: port, username: username, password: password) {
                        continuation.resume(returning: process.isRunning)
                        return
                    }
                    usleep(100_000)
                }
                continuation.resume(returning: false)
            }
        }
    }

    /// One SOCKS5 greeting and login on 127.0.0.1:`port`: true when the login is taken.
    nonisolated static func socksLogin(port: Int, username: String, password: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        func send(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) } == bytes.count }
        func receive(_ count: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
                if n <= 0 { return nil }
                got += n
            }
            return buffer
        }
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count < 256, pass.count < 256, send([5, 1, 2]), receive(2) == [5, 2] else { return false }
        guard send([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass) else { return false }
        return receive(2) == [1, 0]
    }

    // MARK: Leftovers

    /// Relays an app that crashed left running (their parent is gone): ended at the start. Nobody
    /// knows their login, so nothing could use them; they are ended all the same.
    nonisolated static func endLeftovers() {
        guard let executable else { return }
        let path = executable.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        guard found > 0 else { return }
        for pid in pids.prefix(Int(found)) where pid > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == path else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1, info.pbi_uid == getuid() else { continue }
            kill(pid, SIGTERM)
            Logger(subsystem: "PrivacyBrowser", category: "XrayRelays").notice("Ended a relay an earlier run left (pid \(pid, privacy: .public))")
        }
    }
}

/// `Lumen --xray-relay <Xray> <server port>`: the first moments of a relay's process
/// (`XrayRelays`). Before any of Xray's code is loaded, the process puts itself in a sandbox the
/// kernel holds it to, and every process it becomes or starts after it — then it becomes Xray,
/// whose configuration is waiting on its standard input.
///
/// The sandbox: no outgoing connection but to the link's server's port (TCP and UDP: the transports
/// and Shadowsocks's UDP), UDP to loopback (the UDP associations answer the profile's relay there),
/// and the system's resolver (`mDNSResponder`, for the server's own name); no file written. The kernel's rules name hosts only as "any" or "loopback", so the
/// server's address is held by the configuration — its one outbound — and the port by the kernel.
/// Should the sandbox not apply, the relay does not run (exit 70): never a relay outside it.
enum XrayRelayLauncher {
    static let argument = "--xray-relay"

    /// The sandbox's rules for a relay whose server listens on `port`. `resolver` names the system
    /// resolver's socket as this macOS spells a Unix socket's path in a rule (two spellings; the
    /// first this macOS takes is used). Binding is not limited: Xray sends UDP from a socket it binds
    /// to any address on a port of the system's choosing (its system dialer), and what it listens on
    /// for others is its configuration's 127.0.0.1.
    static func profile(serverPort port: Int, resolver: String) -> String {
        [
            "(version 1)",
            "(allow default)",
            "(deny network-outbound)",
            // UDP alone to loopback: the answers of a profile's UDP associations. A rule for "ip"
            // there let TCP through to any port of this Mac's own network address (run 44020981433).
            "(allow network-outbound (remote udp \"localhost:*\"))",
            "(allow network-outbound (remote tcp \"*:\(port)\"))",
            "(allow network-outbound (remote udp \"*:\(port)\"))",
            "(allow network-outbound \(resolver))",
            "(deny file-write*)",
            "(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))",
        ].joined(separator: "\n")
    }

    static let resolverRules = [
        "(remote unix-socket (path-literal \"/private/var/run/mDNSResponder\"))",
        "(literal \"/private/var/run/mDNSResponder\")",
    ]

    static func run(arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: argument), arguments.count > index + 2,
              let port = Int(arguments[index + 2]), (1...65535).contains(port) else {
            FileHandle.standardError.write(Data("usage: \(argument) <xray> <server port>\n".utf8))
            exit(64)
        }
        let executable = arguments[index + 1]
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "sandbox_init") else {
            FileHandle.standardError.write(Data("the relay's sandbox is not in this macOS: the relay does not run\n".utf8))
            exit(70)
        }
        let sandboxInit = unsafeBitCast(symbol, to: SandboxInit.self)
        var applied = false
        var reasons: [String] = []
        for resolver in resolverRules {
            var error: UnsafeMutablePointer<CChar>?
            if sandboxInit(profile(serverPort: port, resolver: resolver), 0, &error) == 0 {
                applied = true
                break
            }
            reasons.append(error.map { String(cString: $0) } ?? "unknown")
        }
        guard applied else {
            FileHandle.standardError.write(Data("the relay's sandbox was refused (\(reasons.joined(separator: "; "))): the relay does not run\n".utf8))
            exit(70)
        }
        // Xray reads its configuration from standard input to its end (`-c stdin:`), and nothing from
        // its environment but what is given here.
        let argv: [String] = ["LumenXray", "run", "-c", "stdin:", "-format", "json"]
        let environment: [String] = ["PATH=/usr/bin:/bin"]
        var cArguments = argv.map { strdup($0) } + [nil]
        var cEnvironment = environment.map { strdup($0) } + [nil]
        execve(executable, &cArguments, &cEnvironment)
        FileHandle.standardError.write(Data("the relay could not be started: \(String(cString: strerror(errno)))\n".utf8))
        exit(71)
    }
}
