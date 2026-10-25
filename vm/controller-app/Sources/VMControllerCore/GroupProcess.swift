import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SpawnError: Error, CustomStringConvertible {
    public let executable: String
    public let code: Int32
    public var description: String { "cannot start \(executable): \(String(cString: strerror(code)))" }
}

/// Runs a child in its own process group and streams its combined stdout and
/// stderr line by line (see LineSplitter).
///
/// Why not Foundation's `Process`: cancelling a shell script has to work like
/// Ctrl+C in a terminal, which signals the whole foreground process group. If
/// only bash is signalled, it defers its trap until the command it is waiting
/// on (`sleep`, `ssh`, `curl`…) finishes. `signalGroup` reaches the whole
/// group, so the script's trap runs at once. The child also gets an empty
/// signal mask and default dispositions: threads of the spawning process
/// (GCD, Swift concurrency) may block signals, and a blocked SIGINT would be
/// inherited across exec and silently swallow the cancel.
public final class GroupProcess: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var status: Int32?
    private var waiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]

    public init(executable: String, arguments: [String] = [], environment: [String: String],
                onLine: @escaping @Sendable (String) -> Void) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.onLine = onLine
    }

    public var processIdentifier: pid_t { locked { pid } }
    public var hasExited: Bool { locked { status != nil } }

    public func start() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnError(executable: executable, code: errno) }
        let readFD = fds[0], writeFD = fds[1]

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) // don't leak the app's other descriptors
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0) // new group, id = child pid
        var noBlockedSignals = sigset_t()
        sigemptyset(&noBlockedSignals)
        posix_spawnattr_setsigmask(&attributes, &noBlockedSignals)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGCHLD] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(writeFD)
        guard result == 0 else {
            close(readFD)
            throw SpawnError(executable: executable, code: result)
        }
        let spawned = child
        locked { pid = spawned }

        let drained = DispatchSemaphore(value: 0)
        let onLine = self.onLine
        Thread {
            var splitter = LineSplitter()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
                if count > 0 {
                    splitter.feed(buffer[0..<count]).forEach(onLine)
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            splitter.finish().forEach(onLine)
            close(readFD)
            drained.signal()
        }.start()

        Thread { [self] in
            var raw: Int32 = 0
            while waitpid(spawned, &raw, 0) == -1 && errno == EINTR {}
            // Deliver the last lines before reporting the exit. A background job
            // that outlived the shell may keep the pipe open; don't wait for it.
            _ = drained.wait(timeout: .now() + 2)
            complete(Self.exitCode(fromWaitStatus: raw))
        }.start()
    }

    /// Sends `signal` to the child's whole process group.
    public func signalGroup(_ signal: Int32) {
        let target: pid_t = locked { status == nil ? pid : 0 }
        if target > 0 { kill(-target, signal) }
    }

    /// The exit code (128 + signal number if killed by a signal), or nil if
    /// the child is still running after `timeout` seconds.
    public func waitForExit(timeout: TimeInterval? = nil) async -> Int32? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let finished: Int32? = locked {
                if let status { return status }
                waiters[id] = continuation
                return nil
            }
            if let finished {
                continuation.resume(returning: finished)
                return
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    locked { waiters.removeValue(forKey: id) }?.resume(returning: nil)
                }
            }
        }
    }

    /// Waits for the exit code without a timeout.
    public func exitCode() async -> Int32 {
        await waitForExit(timeout: nil) ?? -1
    }

    /// Runs a command to completion and collects its output lines. On timeout
    /// the group is killed and the code is nil.
    public static func run(_ executable: String, _ arguments: [String] = [], environment: [String: String],
                           timeout: TimeInterval) async throws -> (code: Int32?, lines: [String]) {
        let collected = LineCollector()
        let process = GroupProcess(executable: executable, arguments: arguments, environment: environment) {
            collected.append($0)
        }
        try process.start()
        guard let code = await process.waitForExit(timeout: timeout) else {
            process.signalGroup(SIGKILL)
            _ = await process.waitForExit(timeout: 5)
            return (nil, collected.lines)
        }
        return (code, collected.lines)
    }

    static func exitCode(fromWaitStatus raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }

    private func complete(_ code: Int32) {
        let pending: [CheckedContinuation<Int32?, Never>] = locked {
            status = code
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        pending.forEach { $0.resume(returning: code) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Thread-safe line accumulator for `GroupProcess.run`.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
