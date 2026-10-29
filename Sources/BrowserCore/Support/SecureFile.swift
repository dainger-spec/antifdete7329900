import Foundation

/// Small-file persistence helpers: atomic replace, owner-only permissions.
public enum SecureFile {
    /// Writes `data` atomically (temp file + rename) with mode 0600.
    public static func write(_ data: Data, to url: URL) throws {
        try replace(url, with: writeTemporary(data, beside: url))
    }

    /// Writes `data` to `url` only if nothing is there yet, atomically: the file appears complete
    /// or not at all, and an existing file is never replaced — there is no window between
    /// "checked" and "written". Returns false if `url` already exists.
    @discardableResult
    public static func createNew(_ data: Data, at url: URL) throws -> Bool {
        let temp = try writeTemporary(data, beside: url)
        var result: Int32
        #if canImport(Darwin)
        result = renamex_np(temp.path, url.path, UInt32(RENAME_EXCL))
        if result != 0, errno == ENOTSUP || errno == EINVAL { // file system without RENAME_EXCL
            result = linkExclusively(temp, url)
        }
        #else
        result = linkExclusively(temp, url)
        #endif
        let code = errno
        if result != 0 {
            try? FileManager.default.removeItem(at: temp)
            if code == EEXIST { return false }
            throw CoreError.io("create \(url.lastPathComponent) failed: errno \(code)")
        }
        return true
    }

    /// link(2) fails with EEXIST instead of replacing; the temp name is removed afterwards.
    private static func linkExclusively(_ temp: URL, _ url: URL) -> Int32 {
        let result = link(temp.path, url.path)
        if result == 0 { unlink(temp.path) }
        return result
    }

    private static func writeTemporary(_ data: Data, beside url: URL) throws -> URL {
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
        return temp
    }

    /// Writes `data` over the file at `url` in place — no temp file beside it — readable by its
    /// owner alone (0600) from the first byte on, a file that was there before included. For a
    /// file the user chose in a save panel: the App Sandbox lets the app write that one file and
    /// nothing next to it. A symbolic link at `url` is refused, not followed.
    public static func writeOwnerOnly(_ data: Data, over url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CoreError.io("open \(url.lastPathComponent) failed: errno \(errno)") }
        defer { _ = close(descriptor) }
        // A file that was there keeps its mode through O_CREAT: made owner-only before the data.
        guard fchmod(descriptor, 0o600) == 0 else { throw CoreError.io("chmod \(url.lastPathComponent) failed: errno \(errno)") }
        do {
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        } catch {
            throw CoreError.io("write \(url.lastPathComponent): \(error)")
        }
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
