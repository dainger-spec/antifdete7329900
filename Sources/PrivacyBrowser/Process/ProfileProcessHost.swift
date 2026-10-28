import AppKit
import BrowserCore
import CryptoKit
import Foundation
import os

/// The launcher's side of the profile processes (docs/PROCESS_PER_PROFILE.md): it starts a
/// profile's process through LaunchServices, checks who connects (the kernel's audit token, this
/// app's code, a PID it launched), hands over that profile's key once per launch, and follows the
/// process until it has sealed and exited.
@MainActor
final class ProfileProcessHost {
    static let shared = ProfileProcessHost()
    /// Profile processes at once (stage 1; a setting in stage 2).
    static let maximumProcesses = 12

    enum HostError: LocalizedError {
        case cannotListen(String)
        case cannotLaunch(String)
        case tooMany
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cannotListen(let reason): return String(format: L("process.error.cannotListen"), reason)
            case .cannotLaunch(let reason): return String(format: L("process.error.cannotLaunch"), reason)
            case .tooMany: return String(format: L("process.error.tooMany"), ProfileProcessHost.maximumProcesses)
            case .failed(let reason): return String(format: L("process.error.failed"), reason)
            }
        }
    }

    /// One launch, from LaunchServices' answer until its process has the key.
    final class Launch {
        let token: String
        let profileID: UUID
        let profileName: String
        let vaultRoot: URL
        let ephemeral: Bool
        let key: SymmetricKey
        var runningApplication: NSRunningApplication?
        /// The PID LaunchServices reported for this launch.
        var boundPID: pid_t?
        /// The process that said hello with that PID, as the kernel identified it.
        var peer: ProcessPeer.Identity?
        var keyHandedOver = false
        var process: ProfileProcess?
        var failure: String?

        init(token: String, profileID: UUID, profileName: String, vaultRoot: URL, ephemeral: Bool, key: SymmetricKey) {
            self.token = token
            self.profileID = profileID
            self.profileName = profileName
            self.vaultRoot = vaultRoot
            self.ephemeral = ephemeral
            self.key = key
        }
    }

    /// The listening socket's path, once listening.
    private(set) var socketPath: String?
    private var listener: Int32 = -1
    /// By launch token.
    private var launches: [String: Launch] = [:]
    /// A launch whose process LaunchServices has not reported yet: launches go one at a time
    /// until then, so a hello that comes first can only be that launch's.
    private var launchAwaitingPID = false
    /// Each open connection, and the profile process it belongs to once it has its key.
    private var connections: [ObjectIdentifier: ProcessConnection] = [:]
    private var owners: [ObjectIdentifier: ProfileProcess] = [:]
    /// Why connections were refused, newest last (self-test).
    private(set) var refusals: [String] = []
    /// The self-test lets its profile processes take test operations.
    var selfTest = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileProcessHost")

    var runningCount: Int { launches.values.filter { $0.process.map { !$0.hasExited } ?? ($0.failure == nil) }.count }

    // MARK: Listening

    /// Listens on this launcher's socket (once).
    func listen() throws {
        guard socketPath == nil else { return }
        let path = ProcessSocket.launcherPath(for: getpid())
        ProcessSocket.removeStaleSockets(except: path)
        let fd: Int32
        do {
            fd = try ProcessSocket.listen(at: path)
        } catch {
            throw HostError.cannotListen(error.localizedDescription)
        }
        listener = fd
        socketPath = path
        let thread = Thread {
            while true {
                let connection = Darwin.accept(fd, nil, nil)
                if connection < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // Checked here, off the main thread: the code check reads the peer's signature.
                let token = ProcessPeer.auditToken(of: connection)
                let status = token.map(ProcessPeer.codeStatus(of:)) ?? errSecCSUnsigned
                let peer = token.map(ProcessPeer.identity(of:)) ?? ProcessPeer.Identity(pid: -1, pidVersion: 0, uid: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        ProfileProcessHost.shared.accepted(ProcessConnection(fd: connection, peer: peer), codeStatus: status)
                    }
                }
            }
        }
        thread.name = "ProfileProcess listener"
        thread.start()
        log.info("Listening for profile processes at \(path, privacy: .public)")
    }

    private func accepted(_ connection: ProcessConnection, codeStatus: OSStatus) {
        guard codeStatus == errSecSuccess else {
            refuse(connection, "its code is not this app's (\(ProcessPeer.describe(codeStatus)))")
            return
        }
        guard connection.peer.uid == getuid() else {
            refuse(connection, "another user's process")
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.startReading({ [weak self] message in
            self?.received(message, on: connection)
        }, onClose: { [weak self] in
            self?.closed(connection)
        })
    }

    // MARK: Launching

    /// Starts `profileID`'s process and hands it the profile's key; returns once that process holds
    /// the key (it then decrypts the web data: `ProfileProcess.waitUntilPrepared`).
    func launch(profileID: UUID, profileName: String, key: SymmetricKey, vaultRoot: URL, ephemeral: Bool) async throws -> ProfileProcess {
        try listen()
        guard runningCount < Self.maximumProcesses else { throw HostError.tooMany }
        _ = await Self.poll(timeout: 60) { !self.launchAwaitingPID }
        guard !launchAwaitingPID else { throw HostError.cannotLaunch("another launch is still starting") }
        launchAwaitingPID = true
        let launch = Launch(token: Self.randomToken(), profileID: profileID, profileName: profileName, vaultRoot: vaultRoot,
                            ephemeral: ephemeral, key: key)
        launches[launch.token] = launch
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
                    if let application {
                        continuation.resume(returning: application)
                    } else {
                        continuation.resume(throwing: error ?? HostError.cannotLaunch("LaunchServices gave no application"))
                    }
                }
            }
            launch.runningApplication = application
            launch.boundPID = application.processIdentifier
            launchAwaitingPID = false
        } catch {
            launchAwaitingPID = false
            launches[launch.token] = nil
            throw HostError.cannotLaunch(error.localizedDescription)
        }
        let ready = await Self.poll(timeout: 30) {
            launch.process != nil || launch.failure != nil || launch.runningApplication?.isTerminated == true
        }
        guard ready, let process = launch.process else {
            let reason = launch.failure ?? (launch.runningApplication?.isTerminated == true ? "the process ended" : "no connection from the process")
            launch.runningApplication?.forceTerminate()
            launches[launch.token] = nil
            throw HostError.cannotLaunch(reason)
        }
        return process
    }

    // MARK: Messages

    private func received(_ message: ProcessMessage, on connection: ProcessConnection) {
        if let owner = owners[ObjectIdentifier(connection)] {
            owner.handle(message)
            return
        }
        switch message.kind {
        case .hello:
            Task { await assign(connection) }
        case .keyRequest:
            Task { await handOverKey(message.launchToken, on: connection) }
        default:
            refuse(connection, "unexpected \(message.kind.rawValue)")
        }
    }

    /// Binds the connection to the launch whose process it is: the one LaunchServices reported
    /// with the peer's PID, or — when the hello comes before LaunchServices has answered — the one
    /// launch still waiting for its PID (launches go one at a time until then); `handOverKey`
    /// then checks the PID before the key leaves.
    private func assign(_ connection: ProcessConnection) async {
        let deadline = Date().addingTimeInterval(15)
        while true {
            let pending = launches.values.filter { $0.peer == nil && !$0.keyHandedOver && $0.failure == nil }
            let launch = pending.first { $0.boundPID == connection.peer.pid }
                ?? (pending.count == 1 && pending[0].boundPID == nil ? pending[0] : nil)
            if let launch {
                launch.peer = connection.peer
                var message = ProcessMessage(.assign)
                message.launchToken = launch.token
                message.profileID = launch.profileID
                message.profileName = launch.profileName
                message.vaultRoot = launch.vaultRoot.path
                message.ephemeral = launch.ephemeral
                message.selfTest = selfTest
                do {
                    try connection.send(message)
                } catch {
                    launch.failure = error.localizedDescription
                }
                return
            }
            let waiting = launches.values.contains { $0.boundPID == nil && $0.failure == nil && $0.peer == nil }
            if !waiting || Date() > deadline {
                refuse(connection, "not a process this launcher started (\(connection.peer.description))")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The key, once per launch, to the very process the launch is bound to: the one that said
    /// hello for it, and the one LaunchServices started for it (same PID).
    private func handOverKey(_ token: String?, on connection: ProcessConnection) async {
        guard let token, let launch = launches[token] else {
            refuse(connection, "no launch with that token")
            return
        }
        guard !launch.keyHandedOver else {
            refuse(connection, "the key of that launch was already handed over")
            return
        }
        guard let peer = launch.peer, peer == connection.peer else {
            refuse(connection, "that launch belongs to another process (\(connection.peer.description))")
            return
        }
        _ = await Self.poll(timeout: 30) { launch.boundPID != nil || launch.failure != nil }
        guard launch.boundPID == peer.pid, !launch.keyHandedOver else {
            launch.failure = "a process LaunchServices did not start for this launch asked for its key"
            refuse(connection, "not the process LaunchServices started for that launch (\(connection.peer.description))")
            return
        }
        var message = ProcessMessage(.key)
        message.key = launch.key.withUnsafeBytes { Data($0) }.base64EncodedString()
        do {
            try connection.send(message)
        } catch {
            launch.failure = error.localizedDescription
            return
        }
        launch.keyHandedOver = true
        let process = ProfileProcess(profileID: launch.profileID, launchToken: launch.token, connection: connection,
                                     runningApplication: launch.runningApplication)
        launch.process = process
        owners[ObjectIdentifier(connection)] = process
        log.notice("Handed the key of \(launch.profileID.uuidString, privacy: .public) to its process, \(connection.peer.description, privacy: .public)")
    }

    private func refuse(_ connection: ProcessConnection, _ reason: String) {
        var message = ProcessMessage(.reject)
        message.reason = reason
        try? connection.send(message)
        refusals.append(reason)
        log.notice("Refused a connection: \(reason, privacy: .public)")
        connections[ObjectIdentifier(connection)] = nil
        connection.close()
    }

    private func closed(_ connection: ProcessConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = nil
        if let owner = owners.removeValue(forKey: id) {
            launches[owner.launchToken] = nil
            owner.connectionClosed()
        } else if let launch = launches.values.first(where: { $0.peer == connection.peer && !$0.keyHandedOver }) {
            launch.failure = "the process closed the connection"
        }
    }

    // MARK: Self-test

    /// A launch bound to `process`, with a throwaway key: what another process would have to steal.
    func issueTestLaunch(boundTo process: ProfileProcess) -> String? {
        guard let launch = launches[process.launchToken], let peer = launch.peer else { return nil }
        let test = Launch(token: Self.randomToken(), profileID: launch.profileID, profileName: launch.profileName,
                          vaultRoot: launch.vaultRoot, ephemeral: launch.ephemeral, key: SymmetricKey(size: .bits256))
        test.boundPID = peer.pid
        test.peer = peer
        launches[test.token] = test
        return test.token
    }

    /// Removes a launch `issueTestLaunch` made.
    func withdrawTestLaunch(_ token: String) {
        launches[token] = nil
    }

    /// Connects to this launcher's own socket as another process of this app would, and returns
    /// what the launcher answered to its hello.
    func answerToOwnHello() async -> String {
        guard let path = socketPath else { return "not listening" }
        return await Task.detached { () -> String in
            do {
                let fd = try ProcessSocket.connect(to: path)
                guard let token = ProcessPeer.auditToken(of: fd) else { Darwin.close(fd); return "no peer token" }
                let connection = ProcessConnection(fd: fd, peer: ProcessPeer.identity(of: token))
                connection.setReadTimeout(20)
                try connection.send(ProcessMessage(.hello))
                guard let reply = try connection.receive() else { return "closed" }
                return reply.kind == .reject ? "reject: \(reply.reason ?? "")" : reply.kind.rawValue
            } catch {
                return "error: \(error.localizedDescription)"
            }
        }.value
    }

    // MARK: Helpers

    static func randomToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    static func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

/// A running profile process, as the launcher follows it.
@MainActor
final class ProfileProcess {
    enum Exit: Equatable {
        /// It sealed its data and exited.
        case sealed
        /// It reported that sealing failed, then exited.
        case sealFailed(String)
        /// It ended without reporting a seal (crash, `kill -9`, forced quit).
        case crashed
    }

    let profileID: UUID
    let launchToken: String
    let runningApplication: NSRunningApplication?
    private let connection: ProcessConnection
    private(set) var isPrepared = false
    private(set) var isStarted = false
    private(set) var sealReport: (ok: Bool, reason: String?)?
    private(set) var failure: String?
    private(set) var isClosed = false
    private(set) var exit: Exit?
    /// Called once, after the process ended.
    var onExit: ((Exit) -> Void)?
    private var testResults: [Int: ProcessMessage] = [:]
    private var nextTestID = 1

    init(profileID: UUID, launchToken: String, connection: ProcessConnection, runningApplication: NSRunningApplication?) {
        self.profileID = profileID
        self.launchToken = launchToken
        self.connection = connection
        self.runningApplication = runningApplication
    }

    var processIdentifier: pid_t { connection.peer.pid }

    var hasExited: Bool { exit != nil }

    func handle(_ message: ProcessMessage) {
        switch message.kind {
        case .prepared: isPrepared = true
        case .started: isStarted = true
        case .sealed: sealReport = (message.ok ?? false, message.reason)
        case .failed: failure = message.reason ?? "?"
        case .testResult: testResults[message.testID ?? 0] = message
        default: break
        }
    }

    func connectionClosed() {
        isClosed = true
        Task { @MainActor in
            // The process is going: wait for it to be gone before anyone touches its data.
            _ = await ProfileProcessHost.poll(timeout: 5) { self.runningApplication?.isTerminated ?? true }
            let exit: Exit = sealReport.map { $0.ok ? .sealed : .sealFailed($0.reason ?? "?") } ?? .crashed
            self.exit = exit
            onExit?(exit)
        }
    }

    /// Returns once the process has decrypted the profile's web data.
    func waitUntilPrepared(timeout: TimeInterval = 120) async throws {
        _ = await ProfileProcessHost.poll(timeout: timeout) { self.isPrepared || self.failure != nil || self.isClosed }
        guard isPrepared else { throw ProfileProcessHost.HostError.failed(failure ?? (isClosed ? "the process ended" : "no answer")) }
    }

    /// The process sets its language and locale, makes its pool, data store and window.
    func start(configuration: ProfileConfiguration, language: String?, locale: String?) async throws {
        var message = ProcessMessage(.start)
        message.configuration = configuration
        message.language = language
        message.locale = locale
        try connection.send(message)
        _ = await ProfileProcessHost.poll(timeout: 60) { self.isStarted || self.failure != nil || self.isClosed }
        guard isStarted else { throw ProfileProcessHost.HostError.failed(failure ?? (isClosed ? "the process ended" : "no answer")) }
    }

    /// Asks the process to seal and exit, and waits for both (a process that does not answer is
    /// force-terminated). True when it reported a successful seal.
    func stop(timeout: TimeInterval = 90) async -> Bool {
        if !isClosed { try? connection.send(ProcessMessage(.stop)) }
        let ended = await ProfileProcessHost.poll(timeout: timeout) { self.exit != nil }
        if !ended {
            runningApplication?.forceTerminate()
            connection.close()
            _ = await ProfileProcessHost.poll(timeout: 10) { self.exit != nil }
        }
        return sealReport?.ok == true
    }

    func openWindow() {
        try? connection.send(ProcessMessage(.openWindow))
    }

    func activate() {
        try? connection.send(ProcessMessage(.activate))
    }

    /// A self-test operation in the process (only a self-test launcher's processes take them).
    func test(_ operation: String, _ argument: String? = nil, timeout: TimeInterval = 45) async throws -> String {
        let id = nextTestID
        nextTestID += 1
        var message = ProcessMessage(.test)
        message.testID = id
        message.operation = operation
        message.argument = argument
        try connection.send(message)
        _ = await ProfileProcessHost.poll(timeout: timeout) { self.testResults[id] != nil || self.isClosed }
        guard let result = testResults.removeValue(forKey: id) else {
            throw ProfileProcessHost.HostError.failed("no answer to \(operation)\(isClosed ? " (the process ended)" : "")")
        }
        guard result.ok == true else { throw ProfileProcessHost.HostError.failed(result.reason ?? "?") }
        return result.value ?? ""
    }
}
