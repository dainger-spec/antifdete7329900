#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Packs one or more directory trees into a single encrypted file and restores them.
/// Used by the app layer to keep WebKit's per-profile data store encrypted while the
/// profile is not running (see `WebDataStoreVault` in the app target).
///
/// Plaintext record stream (inside `EncryptedChunkStream`), integers big-endian:
/// ```
/// record = kind u8 | pathLength u16 | path utf8 | mode u16 | [size u64 | bytes]   (bytes only for files)
/// kind   = 0 end-of-archive, 1 directory, 2 regular file
/// path   = "<rootLabel>/<relative/path>" ('/'-separated, no "." / ".." / empty components)
/// ```
/// Symbolic links and special files are skipped (WebKit data stores contain none;
/// following links could archive data from outside the store).
public enum EncryptedDirectoryArchive {
    public struct Stats: Equatable, Sendable {
        public var directories = 0
        public var files = 0
        public var bytes: UInt64 = 0
        public var skipped: [String] = []

        public init() {}
    }

    public static let defaultChunkSize = 1 << 20

    private enum Kind: UInt8 { case end = 0, directory = 1, file = 2 }

    /// Seals `roots` (label → directory) into `archiveURL`, atomically replacing any
    /// existing archive — except one a newer version wrote, which is refused with
    /// `CoreError.newerFormat` and left as it is. Roots that do not exist are skipped.
    @discardableResult
    public static func seal(roots: [String: URL], to archiveURL: URL, key: SymmetricKey,
                            chunkSize: Int = defaultChunkSize) throws -> Stats {
        for label in roots.keys { try validateComponent(label) }
        try EncryptedChunkStream.guardOverwrite(of: archiveURL)
        let temp = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".\(archiveURL.lastPathComponent).\(UUID().uuidString).tmp")
        try SecureFile.ensureDirectory(archiveURL.deletingLastPathComponent())
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.io("cannot create \(temp.path)")
        }
        var stats = Stats()
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            let writer = try EncryptedChunkWriter(handle: handle, key: key, chunkSize: chunkSize)
            for label in roots.keys.sorted() {
                guard let root = roots[label] else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                try walk(directory: root.path, archivePath: label, writer: writer, stats: &stats)
            }
            try writer.write(Data([Kind.end.rawValue]))
            try writer.finish()
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try SecureFile.replace(archiveURL, with: temp)
        return stats
    }

    /// Restores an archive. Each root is first extracted to a staging directory next to its
    /// destination and moved into place only after the whole archive authenticated, so a
    /// corrupt or tampered archive never leaves partial plaintext in a destination.
    /// Destinations must not exist.
    @discardableResult
    public static func unseal(from archiveURL: URL, key: SymmetricKey, destinations: [String: URL]) throws -> Stats {
        try unseal(from: archiveURL, key: key) { label in
            guard let destination = destinations[label] else {
                throw CoreError.corruptData("archive root '\(label)' has no destination")
            }
            return destination
        }
    }

    /// Variant where the destination of each root is decided when the root is first
    /// encountered in the (already authenticated) chunk stream.
    @discardableResult
    public static func unseal(from archiveURL: URL, key: SymmetricKey,
                              resolveDestination: (String) throws -> URL) throws -> Stats {
        final class Staging {
            var roots: [String: (staged: URL, destination: URL)] = [:]
        }
        let staging = Staging()
        let stagedRoot: (String) throws -> URL = { label in
            if let existing = staging.roots[label] { return existing.staged }
            try validateComponent(label)
            let destination = try resolveDestination(label)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw CoreError.io("unseal destination for '\(label)' already exists: \(destination.path)")
            }
            let parent = destination.deletingLastPathComponent()
            try SecureFile.ensureDirectory(parent)
            let staged = parent.appendingPathComponent(".\(destination.lastPathComponent).unseal-\(UUID().uuidString)")
            staging.roots[label] = (staged, destination)
            return staged
        }
        let cleanupStaging = { for root in staging.roots.values { try? FileManager.default.removeItem(at: root.staged) } }

        var stats = Stats()
        do {
            let handle = try FileHandle(forReadingFrom: archiveURL)
            defer { try? handle.close() }
            let reader = try EncryptedChunkReader(handle: handle, key: key, name: archiveURL.lastPathComponent)
            recordLoop: while true {
                let kindByte = try reader.read(1)[0]
                guard let kind = Kind(rawValue: kindByte) else { throw CoreError.corruptData("record kind \(kindByte)") }
                if kind == .end { break recordLoop }
                let pathLength = Int(try readUInt(reader, bytes: 2))
                guard let path = String(data: try reader.read(pathLength), encoding: .utf8) else {
                    throw CoreError.corruptData("path encoding")
                }
                let mode = Int(try readUInt(reader, bytes: 2)) & 0o777
                let target = try resolve(path: path, stagedRoot: stagedRoot)
                switch kind {
                case .directory:
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: (mode | 0o700)])
                    stats.directories += 1
                case .file:
                    let size = try readUInt(reader, bytes: 8)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    guard FileManager.default.createFile(atPath: target.path, contents: nil,
                                                         attributes: [.posixPermissions: (mode | 0o600)]) else {
                        throw CoreError.io("cannot create \(target.lastPathComponent)")
                    }
                    let output = try FileHandle(forWritingTo: target)
                    defer { try? output.close() }
                    var remaining = size
                    while remaining > 0 {
                        let piece = Int(min(remaining, UInt64(defaultChunkSize)))
                        try output.write(contentsOf: try reader.read(piece))
                        remaining -= UInt64(piece)
                    }
                    stats.files += 1
                    stats.bytes += size
                case .end:
                    break recordLoop
                }
            }
            try reader.finish()
        } catch {
            cleanupStaging()
            throw error
        }

        // Everything authenticated: move staged roots into place.
        for root in staging.roots.values where FileManager.default.fileExists(atPath: root.staged.path) {
            try SecureFile.replace(root.destination, with: root.staged)
        }
        return stats
    }

    // MARK: Re-encrypting without plaintext

    /// An archive to read: where it starts in its file (after whatever the file holds before it)
    /// and its key.
    public struct TranscodeSource {
        public let url: URL
        public let offset: UInt64
        public let key: SymmetricKey
        public init(url: URL, offset: UInt64 = 0, key: SymmetricKey) {
            self.url = url
            self.offset = offset
            self.key = key
        }
    }

    /// An archive to write, after `prefix` (bytes the file starts with), under `key`.
    public struct TranscodeDestination {
        public let url: URL
        public let key: SymmetricKey
        public let prefix: Data
        public init(url: URL, key: SymmetricKey, prefix: Data = Data()) {
            self.url = url
            self.key = key
            self.prefix = prefix
        }
    }

    /// Re-encrypts archives without their plaintext ever touching the disk: every record of each
    /// source is read, authenticated and written again — under another key, into one of
    /// `destinations`, with its root renamed — a chunk at a time, in memory.
    ///
    /// `route(source, label)` names the destination (by index) and the new label of each root,
    /// or nil to leave the root out. A destination is written to a temporary file and moved into
    /// place only once every source has authenticated to its end, so a damaged or tampered source
    /// leaves no destination behind; a destination no root was routed to is not written at all.
    @discardableResult
    public static func transcode(sources: [TranscodeSource], to destinations: [TranscodeDestination],
                                 route: (_ source: Int, _ label: String) throws -> (destination: Int, label: String)?) throws -> Stats {
        final class Output {
            let temp: URL
            let handle: FileHandle
            let writer: EncryptedChunkWriter
            var used = false
            init(temp: URL, handle: FileHandle, writer: EncryptedChunkWriter) {
                self.temp = temp
                self.handle = handle
                self.writer = writer
            }
        }
        var outputs: [Output] = []
        let discard = {
            for output in outputs {
                try? output.handle.close()
                try? FileManager.default.removeItem(at: output.temp)
            }
        }
        var stats = Stats()
        do {
            for destination in destinations {
                try SecureFile.ensureDirectory(destination.url.deletingLastPathComponent())
                let temp = destination.url.deletingLastPathComponent()
                    .appendingPathComponent(".\(destination.url.lastPathComponent).\(UUID().uuidString).tmp")
                guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CoreError.io("cannot create \(temp.path)")
                }
                let handle = try FileHandle(forWritingTo: temp)
                try handle.write(contentsOf: destination.prefix)
                outputs.append(Output(temp: temp, handle: handle,
                                      writer: try EncryptedChunkWriter(handle: handle, key: destination.key, chunkSize: defaultChunkSize)))
            }
            for (index, source) in sources.enumerated() {
                let handle = try FileHandle(forReadingFrom: source.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: source.offset)
                let reader = try EncryptedChunkReader(handle: handle, key: source.key, name: source.url.lastPathComponent)
                var routes: [String: (destination: Int, label: String)?] = [:]
                recordLoop: while true {
                    let kindByte = try reader.read(1)[0]
                    guard let kind = Kind(rawValue: kindByte) else { throw CoreError.corruptData("record kind \(kindByte)") }
                    if kind == .end { break recordLoop }
                    let pathLength = Int(try readUInt(reader, bytes: 2))
                    guard let path = String(data: try reader.read(pathLength), encoding: .utf8) else {
                        throw CoreError.corruptData("path encoding")
                    }
                    let mode = Int(try readUInt(reader, bytes: 2)) & 0o777
                    var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                    for component in components {
                        do { try validateComponent(component) } catch { throw CoreError.unsafeArchivePath(path) }
                    }
                    let label = components[0]
                    if routes[label] == nil {
                        let routed = try route(index, label)
                        if let routed {
                            guard outputs.indices.contains(routed.destination) else { throw CoreError.invalidConfiguration("no destination \(routed.destination)") }
                            try validateComponent(routed.label)
                        }
                        routes[label] = .some(routed)
                    }
                    let target = routes[label] ?? nil
                    if let target {
                        components[0] = target.label
                        let output = outputs[target.destination]
                        output.used = true
                        try writeHeader(kind: kind, path: components.joined(separator: "/"), mode: mode, writer: output.writer)
                    }
                    switch kind {
                    case .directory:
                        if target != nil { stats.directories += 1 }
                    case .file:
                        let size = try readUInt(reader, bytes: 8)
                        if let target { try writeUInt(size, bytes: 8, writer: outputs[target.destination].writer) }
                        var remaining = size
                        while remaining > 0 {
                            let piece = Int(min(remaining, UInt64(defaultChunkSize)))
                            let bytes = try reader.read(piece)
                            if let target { try outputs[target.destination].writer.write(bytes) }
                            remaining -= UInt64(piece)
                        }
                        if target != nil {
                            stats.files += 1
                            stats.bytes += size
                        }
                    case .end:
                        break recordLoop
                    }
                }
                try reader.finish()
            }
            for output in outputs where output.used {
                try output.writer.write(Data([Kind.end.rawValue]))
                try output.writer.finish()
                try output.handle.synchronize()
                try output.handle.close()
            }
        } catch {
            discard()
            throw error
        }
        for (output, destination) in zip(outputs, destinations) {
            if output.used {
                try SecureFile.replace(destination.url, with: output.temp)
            } else {
                try? output.handle.close()
                try? FileManager.default.removeItem(at: output.temp)
            }
        }
        return stats
    }

    /// The root labels an archive holds, read and authenticated to its end (nothing is written).
    public static func labels(in archiveURL: URL, offset: UInt64 = 0, key: SymmetricKey) throws -> [String] {
        var labels: [String] = []
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(".pb-labels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try transcode(sources: [TranscodeSource(url: archiveURL, offset: offset, key: key)],
                          to: [TranscodeDestination(url: scratch, key: SymmetricKey(size: .bits256))]) { _, label in
            labels.append(label)
            return nil
        }
        return labels
    }

    // MARK: Private

    private static func walk(directory: String, archivePath: String, writer: EncryptedChunkWriter, stats: inout Stats) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: directory)
        try writeHeader(kind: .directory, path: archivePath, mode: attributes[.posixPermissions] as? Int ?? 0o700, writer: writer)
        stats.directories += 1

        for name in try fm.contentsOfDirectory(atPath: directory).sorted() {
            let fullPath = (directory as NSString).appendingPathComponent(name)
            let childPath = archivePath + "/" + name
            do { try validateComponent(name) } catch { stats.skipped.append(childPath); continue }
            // attributesOfItem uses lstat(2): symlinks are reported as links, not followed.
            let childAttributes = try fm.attributesOfItem(atPath: fullPath)
            let type = childAttributes[.type] as? FileAttributeType
            let mode = childAttributes[.posixPermissions] as? Int ?? 0o600
            switch type {
            case .typeDirectory?:
                try walk(directory: fullPath, archivePath: childPath, writer: writer, stats: &stats)
            case .typeRegular?:
                let expectedSize = (childAttributes[.size] as? NSNumber)?.uint64Value ?? 0
                try writeHeader(kind: .file, path: childPath, mode: mode, writer: writer)
                try writeUInt(expectedSize, bytes: 8, writer: writer)
                let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: fullPath))
                defer { try? input.close() }
                var remaining = expectedSize
                while remaining > 0 {
                    let piece = try input.read(upToCount: Int(min(remaining, UInt64(defaultChunkSize)))) ?? Data()
                    guard !piece.isEmpty else {
                        // File shrank while being archived → the owner (WebKit) is still writing.
                        throw CoreError.io("\(childPath) changed while archiving")
                    }
                    try writer.write(piece)
                    remaining -= UInt64(piece.count)
                }
                stats.files += 1
                stats.bytes += expectedSize
            default:
                stats.skipped.append(childPath)
            }
        }
    }

    private static func writeHeader(kind: Kind, path: String, mode: Int, writer: EncryptedChunkWriter) throws {
        let pathBytes = Data(path.utf8)
        guard pathBytes.count <= Int(UInt16.max) else { throw CoreError.io("path too long: \(path)") }
        try writer.write(Data([kind.rawValue]))
        try writeUInt(UInt64(pathBytes.count), bytes: 2, writer: writer)
        try writer.write(pathBytes)
        try writeUInt(UInt64(mode & 0o777), bytes: 2, writer: writer)
    }

    private static func writeUInt(_ value: UInt64, bytes: Int, writer: EncryptedChunkWriter) throws {
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(bytes - 1 - i))) }
        try writer.write(data)
    }

    private static func readUInt(_ reader: EncryptedChunkReader, bytes: Int) throws -> UInt64 {
        try reader.read(bytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Maps an archive path onto the staging directory for its root, rejecting traversal.
    private static func resolve(path: String, stagedRoot: (String) throws -> URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let label = components.first else { throw CoreError.unsafeArchivePath(path) }
        for component in components {
            do { try validateComponent(component) } catch { throw CoreError.unsafeArchivePath(path) }
        }
        let base = try stagedRoot(label)
        let target = components.dropFirst().reduce(base) { $0.appendingPathComponent($1) }
        return target
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\0") else {
            throw CoreError.unsafeArchivePath(component)
        }
    }
}
