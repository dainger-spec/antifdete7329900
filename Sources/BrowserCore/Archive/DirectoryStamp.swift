#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What tells one state of directory trees from another without reading a file: of every
/// directory and file beneath the roots, its place, its kind and permissions, the file's volume
/// and number, its size, and when its bytes and when its attributes were last changed — digested
/// in the order an archive goes through them (`EncryptedDirectoryArchive.seal`).
///
/// An archive's pass makes one of what it reads (`EncryptedDirectoryArchive.Stats.stamp`): each
/// entry is looked at before anything of it is read, so whatever changes an entry after the pass
/// looked at it — while the pass reads it, or later — gives it another time, size or number. A
/// stamp taken afterwards (`DirectoryStamp.of`) that equals the pass's therefore says that the
/// archive holds every entry as it is now. A profile's stop archived its website data again before
/// each try to have WebKit remove the store, and once more to force the seal — four times, a
/// second or two apart — whether or not anything had changed; now it archives again only what
/// has (`WebDataStoreVault`).
///
/// A file written through a memory mapping gets its size, and its times, when it is made, and
/// its bytes a moment later: looked at and read in between, it would be archived unfinished and
/// look unchanged afterwards. `quietSeconds` is for that: a pass that met an entry changed only
/// just before is not taken for a picture of settled data.
public struct DirectoryStamp: Equatable, Sendable {
    let digest: Data
    /// The directories and files it is of.
    public let entries: Int
    /// How long before the stamp was begun the newest of its entries last changed — its bytes or
    /// its attributes — in seconds. Not part of what makes two stamps equal.
    public let quietSeconds: Double

    public static func == (first: DirectoryStamp, second: DirectoryStamp) -> Bool {
        first.digest == second.digest && first.entries == second.entries
    }

    /// The stamp of `roots` (label → directory) as they are now, gone through as
    /// `EncryptedDirectoryArchive.seal` goes through them: the roots by label, a root that is not
    /// there left out, each directory's entries by name, symbolic links looked at and not followed.
    /// Nil when something beneath them could not be looked at (it went while they were gone
    /// through): such a state equals no other.
    public static func of(roots: [String: URL]) -> DirectoryStamp? {
        let builder = DirectoryStampBuilder()
        for label in roots.keys.sorted() {
            guard let root = roots[label] else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            builder.add(label, at: root.path)
            walk(root.path, as: label, into: builder)
        }
        return builder.stamp
    }

    private static func walk(_ directory: String, as archivePath: String, into builder: DirectoryStampBuilder) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            builder.fail()
            return
        }
        for name in names.sorted() {
            // As the archive: a name it leaves out is not looked at.
            guard (try? EncryptedDirectoryArchive.validateComponent(name)) != nil else { continue }
            let fullPath = (directory as NSString).appendingPathComponent(name)
            let childPath = archivePath + "/" + name
            if builder.add(childPath, at: fullPath) == .directory {
                walk(fullPath, as: childPath, into: builder)
            }
        }
    }
}

/// Makes a `DirectoryStamp` entry by entry, in the order the entries are given.
final class DirectoryStampBuilder {
    enum Kind { case directory, file, other }

    private var hasher = SHA256()
    private var entries = 0
    private var failed = false
    /// When this was begun, and the latest change of any entry taken in, as the file system
    /// counts time (seconds since 1970).
    private let began = Date().timeIntervalSince1970
    private var newest = -Double.infinity

    /// Takes in the entry at `path` as it is now, under the name `archivePath`: what `lstat` says
    /// of it (a symbolic link is looked at itself). Returns its kind; nil — and this builder then
    /// gives no stamp — when it cannot be looked at.
    @discardableResult
    func add(_ archivePath: String, at path: String) -> Kind? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            failed = true
            return nil
        }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        #else
        let modified = info.st_mtim
        let changed = info.st_ctim
        #endif
        let facts: [UInt64] = [
            UInt64(truncatingIfNeeded: info.st_mode), UInt64(truncatingIfNeeded: info.st_dev),
            UInt64(truncatingIfNeeded: info.st_ino), UInt64(truncatingIfNeeded: info.st_size),
            UInt64(truncatingIfNeeded: modified.tv_sec), UInt64(truncatingIfNeeded: modified.tv_nsec),
            UInt64(truncatingIfNeeded: changed.tv_sec), UInt64(truncatingIfNeeded: changed.tv_nsec),
        ]
        // The name, a zero byte (no name holds one), then the facts at a fixed length: no two
        // lists of entries give the same bytes.
        var record = Data(archivePath.utf8)
        record.append(0)
        for fact in facts {
            withUnsafeBytes(of: fact.littleEndian) { record.append(contentsOf: $0) }
        }
        hasher.update(data: record)
        entries += 1
        newest = max(newest, Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000,
                     Double(changed.tv_sec) + Double(changed.tv_nsec) / 1_000_000_000)
        switch UInt32(truncatingIfNeeded: info.st_mode) & 0o170000 {
        case 0o040000: return .directory
        case 0o100000: return .file
        default: return .other
        }
    }

    /// Something could not be gone through: no stamp comes of this builder.
    func fail() {
        failed = true
    }

    /// The stamp of the entries given so far; nil when one of them could not be looked at.
    var stamp: DirectoryStamp? {
        guard !failed else { return nil }
        return DirectoryStamp(digest: Data(hasher.finalize()), entries: entries, quietSeconds: began - newest)
    }
}
