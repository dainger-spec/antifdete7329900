import Foundation

/// Small-file persistence helpers: atomic replace, owner-only permissions.
public enum SecureFile {
    /// Writes `data` atomically (temp file + rename) with mode 0600.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.io("cannot create \(temp.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw CoreError.io("write \(url.lastPathComponent): \(error)")
        }
        try replace(url, with: temp)
    }

    public static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CoreError.io("read \(url.lastPathComponent): \(error)")
        }
    }

    /// Atomically moves `source` over `destination` (rename(2) on the same volume).
    public static func replace(_ destination: URL, with source: URL) throws {
        if rename(source.path, destination.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: source)
            throw CoreError.io("rename to \(destination.lastPathComponent) failed: errno \(code)")
        }
    }

    /// rename(2) that, unlike `replace`, never deletes `source` on failure: for moving a
    /// directory that may be a profile's only copy (backup restore, crash recovery).
    static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            let code = errno
            throw CoreError.io("rename \(source.lastPathComponent) to \(destination.lastPathComponent) failed: errno \(code)")
        }
    }

    /// Creates a directory (and parents) with mode 0700.
    public static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CoreError.io("\(url.path) is not a directory") }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw CoreError.io("mkdir \(url.path): \(error)")
        }
    }
}
