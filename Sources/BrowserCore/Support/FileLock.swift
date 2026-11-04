import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An advisory lock on a file, shared by every process that takes it (`flock(2)` on
/// `<file>.lock`, created owner-only beside it).
///
/// A profile's files can be open in two processes at once: the manager's (the password window, the
/// profile list) and the profile's own (`--profile-session`), each holding what it read in memory.
/// A read-modify-write done under this lock, after reading the file again, cannot lose the other
/// process's change in between.
public enum FileLock {
    public static func withExclusiveLock<T>(on url: URL, _ body: () throws -> T) throws -> T {
        let lockURL = url.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CoreError.io("cannot open \(lockURL.lastPathComponent): errno \(errno)") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CoreError.io("cannot lock \(lockURL.lastPathComponent): errno \(errno)") }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// What identifies the file's current contents: its inode (an atomic replace makes a new one),
    /// size and modification time. nil when there is no file.
    public static func stamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return "\(inode)-\(size)-\(modified)"
    }
}
