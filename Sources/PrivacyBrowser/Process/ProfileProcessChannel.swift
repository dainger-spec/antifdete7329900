import BrowserCore
import Darwin
import Foundation
import os
import Security

/// One message between the launcher and a profile process (docs/PROCESS_PER_PROFILE.md). A single
/// flat type: each kind uses a few of the fields.
struct ProcessMessage: Codable {
    enum Kind: String, Codable {
        /// Process → launcher, first: "a launcher started me?"
        case hello
        /// Launcher → process: the launch it belongs to (token, profile, vault location).
        case assign
        /// Either way: refused, with `reason`; the connection is closed after it.
        case reject
        /// Process → launcher: the profile key for the launch `launchToken`.
        case keyRequest
        /// Launcher → process: the profile key (`key`, base64), once per launch.
        case key
        /// Process → launcher: the web data is decrypted.
        case prepared
        /// Launcher → process: the configuration to run with (lookup applied), language, locale.
        case start
        /// Process → launcher: the profile's window is open.
        case started
        /// Launcher → process: seal and exit.
        case stop
        /// Process → launcher: sealed (`ok`), about to exit.
        case sealed
        /// Launcher → process: open another window / come to the front.
        case openWindow, activate
        /// Launcher → process (self-test only): an operation, answered by `testResult`.
        case test, testResult
        /// Process → launcher: launching failed (`reason`).
        case failed
    }

    var kind: Kind
    var reason: String?
    var launchToken: String?
    var profileID: UUID?
    var profileName: String?
    var vaultRoot: String?
    var ephemeral: Bool?
    var selfTest: Bool?
    var key: String?
    var configuration: ProfileConfiguration?
    var language: String?
    var locale: String?
    var testID: Int?
    var operation: String?
    var argument: String?
    var value: String?
    var ok: Bool?

    init(_ kind: Kind) {
        self.kind = kind
    }
}

enum ProcessChannelError: LocalizedError {
    case system(String, Int32)
    case pathTooLong(String)
    case frameTooLarge(Int)
    case closed

    var errorDescription: String? {
        switch self {
        case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
        case .pathTooLong(let path): return "socket path longer than a Unix socket allows: \(path)"
        case .frameTooLarge(let size): return "message of \(size) bytes refused"
        case .closed: return "the other process closed the connection"
        }
    }
}

/// Who is at the other end of a connected Unix socket, as the kernel tells it, and whether its
/// code is this app's.
enum ProcessPeer {
    struct Identity: Equatable, CustomStringConvertible {
        let pid: pid_t
        /// Distinguishes a PID the system reused after its process ended.
        let pidVersion: UInt32
        let uid: uid_t

        var description: String { "pid \(pid) (version \(pidVersion), uid \(uid))" }
    }

    // <sys/un.h>: SOL_LOCAL, LOCAL_PEERTOKEN (the peer's audit token).
    private static let solLocal: Int32 = 0
    private static let localPeerToken: Int32 = 0x006

    static func auditToken(of fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, solLocal, localPeerToken, &token, &length) == 0 else { return nil }
        return token
    }

    /// The audit token's pid, pid version and effective uid (`audit_token_to_pid` and friends).
    static func identity(of token: audit_token_t) -> Identity {
        Identity(pid: pid_t(bitPattern: token.val.5), pidVersion: token.val.7, uid: token.val.1)
    }

    /// This process's designated requirement: an ad-hoc build's names its exact code (cdhash), a
    /// Developer ID build's its identifier and Team ID.
    static let ownRequirement: SecRequirement? = {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    /// `errSecSuccess` when the process behind `token` runs code that satisfies this process's own
    /// designated requirement; otherwise why not. Fails closed: a peer that cannot be checked fails.
    static func codeStatus(of token: audit_token_t) -> OSStatus {
        guard let requirement = ownRequirement else { return errSecCSUnsigned }
        var token = token
        let audit = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: audit] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else { return status }
        return SecCodeCheckValidity(code, [], requirement)
    }

    static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "?"
        return "\(status) \(text)"
    }
}

/// The launcher's socket: `pb-launcher-<pid>.sock` in this process's temporary directory, which is
/// the container's under the App Sandbox (shared by every instance of the app) and the per-user
/// `$TMPDIR` otherwise.
enum ProcessSocket {
    static let prefix = "pb-launcher-"

    static var directory: URL { FileManager.default.temporaryDirectory }

    /// Where a launcher of this app may listen, as this process sees it: its temporary directory,
    /// and the per-user one `confstr` names. An instance LaunchServices started and one started
    /// from a shell need not share `TMPDIR`.
    static var directories: [URL] {
        var urls = [directory]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let other = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            if other.resolvingSymlinksInPath().path != directory.resolvingSymlinksInPath().path { urls.append(other) }
        }
        return urls
    }

    static func launcherPath(for pid: pid_t) -> String {
        directory.appendingPathComponent("\(prefix)\(pid).sock").path
    }

    /// Every launcher socket there is, live or left by a launcher that ended.
    static func launcherPaths() -> [String] {
        directories.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".sock") }.sorted()
                .map { folder.appendingPathComponent($0).path }
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ProcessChannelError.pathTooLong(path) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProcessChannelError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// A listening socket at `path`, readable and writable by this user only.
    static func listen(at path: String) throws -> Int32 {
        var address = try address(path)
        unlink(path)
        let fd = try makeSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ProcessChannelError.system("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ProcessChannelError.system("listen", code)
        }
        return fd
    }

    static func connect(to path: String) throws -> Int32 {
        var address = try address(path)
        let fd = try makeSocket()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ProcessChannelError.system("connect", code)
        }
        return fd
    }

    /// Removes sockets of launchers that ended (nobody accepts a connection on them).
    static func removeStaleSockets(except own: String) {
        for path in launcherPaths() where path != own {
            if let fd = try? connect(to: path) {
                Darwin.close(fd)
            } else {
                unlink(path)
            }
        }
    }
}

/// One verified connection: length-prefixed JSON frames (4-byte big-endian length), at most 4 MiB.
/// `close()` shuts the socket down; its descriptor is released only with the object, so a late
/// read or write can never reach another connection that got the same number.
final class ProcessConnection: @unchecked Sendable {
    let fd: Int32
    let peer: ProcessPeer.Identity
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var isClosed = false
    private static let maximumFrame = 4 * 1024 * 1024
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileProcess")

    init(fd: Int32, peer: ProcessPeer.Identity) {
        self.fd = fd
        self.peer = peer
    }

    deinit { Darwin.close(fd) }

    /// Waits at most `seconds` for each read (0: no limit).
    func setReadTimeout(_ seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ message: ProcessMessage) throws {
        let body = try JSONEncoder().encode(message)
        guard body.count <= Self.maximumFrame else { throw ProcessChannelError.frameTooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        writeLock.lock()
        defer { writeLock.unlock() }
        try frame.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ProcessChannelError.system("write", errno)
                }
                offset += written
            }
        }
    }

    /// The next message; nil when the other end closed the connection.
    func receive() throws -> ProcessMessage? {
        guard let header = try read(4) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length <= Self.maximumFrame else { throw ProcessChannelError.frameTooLarge(length) }
        guard let body = try read(length) else { throw ProcessChannelError.closed }
        return try JSONDecoder().decode(ProcessMessage.self, from: body)
    }

    private func read(_ count: Int) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if got == 0 {
                if offset == 0 { return nil }
                throw ProcessChannelError.closed
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw ProcessChannelError.system("read", errno)
            }
            offset += got
        }
        return data
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    /// Reads on a thread of its own until the connection ends; each message, then the end, is
    /// handed to the main actor.
    func startReading(_ handler: @escaping @MainActor (ProcessMessage) -> Void, onClose: @escaping @MainActor () -> Void) {
        setReadTimeout(0)
        let thread = Thread { [self] in
            while true {
                do {
                    guard let message = try self.receive() else { break }
                    DispatchQueue.main.async { MainActor.assumeIsolated { handler(message) } }
                } catch {
                    Self.log.notice("Profile process connection with \(self.peer.description, privacy: .public) ended: \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { onClose() } }
        }
        thread.name = "ProfileProcess connection"
        thread.start()
    }
}
