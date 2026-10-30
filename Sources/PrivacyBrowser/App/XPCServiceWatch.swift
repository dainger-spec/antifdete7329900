import Darwin
import Foundation

/// The XPC services that start while something runs, and the files they hold open in the real
/// Safari's places (`SafariPaths.isRealSafariPlace`) — for the self-test's Safari-chrome check.
///
/// An XPC service bundled in a framework starts for whichever process asks for it, as a process of
/// its own: outside that process's home (`CFFIXED_USER_HOME`), its proxy and its sandbox. The
/// profile's guard sees the services asked for through `NSXPCConnection` only; one asked for through
/// libxpc (Safari's `SafariPlatformSupport` helper, on the owner's Mac) is not seen by it at all.
/// This watches from outside instead, as `lsof` would: every half second, the processes whose
/// executable is inside an `.xpc` bundle and that started after the watch did, which process is
/// responsible for each (the system's own record, when this macOS answers), and the files each holds
/// open. A file opened and closed between two looks is not seen; one kept open (a database) is.
final class XPCServiceWatch: @unchecked Sendable {
    struct Service: Hashable {
        let pid: pid_t
        /// The executable, inside its `.xpc` bundle.
        let path: String
        /// The process the system holds responsible for it; nil when this macOS does not say.
        let responsible: pid_t?

        /// "com.apple.SafariPlatformSupport.Helper.xpc", from the path.
        var bundleName: String {
            path.components(separatedBy: "/").first { $0.hasSuffix(".xpc") } ?? (path as NSString).lastPathComponent
        }
    }

    private let lock = NSLock()
    private var services: [pid_t: Service] = [:]
    private var opened: [pid_t: Set<String>] = [:]
    private var stopped = false
    private let since: Date
    private let realHome: String

    init(realHome: String) {
        self.realHome = realHome
        since = Date().addingTimeInterval(-1)
        let thread = Thread { [self] in
            while !lock.withLock({ stopped }) {
                sample()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.start()
    }

    /// Stops watching: every service seen, and what each held open in the real Safari's places.
    func stop() -> [(service: Service, opened: [String])] {
        sample()
        return lock.withLock {
            stopped = true
            return services.values.sorted { $0.pid < $1.pid }.map { (service: $0, opened: (opened[$0.pid] ?? []).sorted()) }
        }
    }

    private func sample() {
        for pid in Self.allProcesses() {
            let known = lock.withLock { services[pid] != nil }
            if !known {
                guard let path = Self.executable(of: pid), path.contains(".xpc/"),
                      let started = Self.start(of: pid), started >= since else { continue }
                lock.withLock { services[pid] = Service(pid: pid, path: path, responsible: Self.responsible(for: pid)) }
            }
            let places = Self.openFiles(of: pid).filter { SafariPaths.isRealSafariPlace($0, realHome: realHome) }
            if !places.isEmpty {
                lock.withLock { opened[pid, default: []].formUnion(places) }
            }
        }
    }

    // MARK: What the kernel says about a process

    private static func allProcesses() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    private static func executable(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4) // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
    }

    private static func start(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The paths of the files `pid` has open (its vnodes), as `lsof` lists them.
    private static func openFiles(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.size))
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let path = withUnsafeBytes(of: vnode.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// `responsibility_get_pid_responsible_for_pid`, the system's record of which process a helper
    /// works for (what Activity Monitor and the privacy prompts go by); not public API, so looked
    /// up, and nil where this macOS does not have it.
    static func responsible(for pid: pid_t) -> pid_t? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = responsibleSymbol else { return nil }
        let answer = unsafeBitCast(symbol, to: Responsible.self)(pid)
        return answer > 0 ? answer : nil
    }

    private static let responsibleSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
}
