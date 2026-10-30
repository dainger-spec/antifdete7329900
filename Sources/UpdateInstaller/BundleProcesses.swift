import Darwin
import Foundation

/// A process running an executable from inside an app bundle: the app itself, its profiles' own
/// processes, another copy started from it.
public struct BundleProcess: Equatable, Sendable {
    public var pid: pid_t
    public var startedAt: Date

    public init(pid: pid_t, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }

    /// Every process whose executable is inside `bundle`, but this one.
    public static func running(inside bundle: URL) -> [BundleProcess] {
        // The kernel names an executable by its canonical path (/private/var/…, not /var/…);
        // `resolvingSymlinksInPath` would strip that /private again, realpath(3) does not.
        var prefixes = [bundle.standardizedFileURL.path + "/"]
        if let canonical = realpath(bundle.path, nil) {
            prefixes.append(String(cString: canonical) + "/")
            free(canonical)
        }
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let own = getpid()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4) // PROC_PIDPATHINFO_MAXSIZE
        var found: [BundleProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != own {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(cString: path)
            guard prefixes.contains(where: { executable.hasPrefix($0) }) else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // A process whose start cannot be read counts as one that started just now.
            let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
                ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
                : Date()
            found.append(BundleProcess(pid: pid, startedAt: started))
        }
        return found
    }
}
