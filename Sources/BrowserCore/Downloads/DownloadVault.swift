#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One downloaded file kept in a profile's encrypted download store.
public struct DownloadEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Sanitised file name (`DownloadVault.sanitizedFilename`), used when the file is opened or exported.
    public var filename: String
    /// Where the file came from, credentials and fragment stripped. `nil` if unknown.
    public var sourceURL: String?
    public var mimeType: String?
    /// Plaintext size in bytes.
    public var size: UInt64
    public var createdAt: Date
}

/// Per-profile encrypted download store.
///
/// Layout inside the profile directory:
/// ```
/// downloads/index.bin        AEAD(HKDF(profileKey, "downloads-index"), [DownloadEntry] JSON)
/// downloads/<entry-id>.pbdl  EncryptedChunkStream, key = HKDF(profileKey, salt, "download-file:<entry-id>")
/// downloads/.incoming/       WebKit writes an active download here (plaintext, see below)
/// ```
/// The per-file key names the entry ID, so swapping two `.pbdl` files makes both fail to open
/// instead of serving one file under the other's name.
///
/// PLATFORM LIMITATION: `WKDownload` can only write to a file URL; it has no streaming API.
/// A download is therefore plaintext in `.incoming` while it is in progress. When it finishes it
/// is encrypted into the store and the plaintext is deleted. A crash leaves the partial file,
/// which `purgeIncoming` deletes at the next unlock. Deleting is not secure erasure: on APFS
/// (copy-on-write, SSD wear levelling) the old blocks may survive until reused; FileVault is
/// what protects them.
public final class DownloadVault: @unchecked Sendable {
    public let directory: URL
    private let profileID: UUID
    private let profileKey: SymmetricKey
    private let indexFile: EncryptedDocumentFile<[DownloadEntry]>
    private let lock = NSLock()
    private var entries: [DownloadEntry]

    static let fileExtension = "pbdl"

    init(directory: URL, profileID: UUID, profileKey: SymmetricKey) throws {
        self.directory = directory
        self.profileID = profileID
        self.profileKey = profileKey
        self.indexFile = Self.indexFile(url: directory.appendingPathComponent("index.bin"), profileID: profileID,
                                        profileKey: profileKey)
        self.entries = try indexFile.load() ?? []
    }

    static func indexFile(url: URL?, profileID: UUID, profileKey: SymmetricKey) -> EncryptedDocumentFile<[DownloadEntry]> {
        EncryptedDocumentFile(url: url, key: profileKey.derive(info: "downloads-index", salt: profileID.rawBytes),
                              aad: "downloads-index:v1:\(profileID.uuidString)")
    }

    static func fileInfo(_ entryID: UUID) -> String { "download-file:\(entryID.uuidString)" }

    public var incomingDirectory: URL { Self.incomingDirectory(in: directory) }

    static func incomingDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(".incoming", isDirectory: true)
    }

    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }

    // MARK: Queries

    /// Newest first.
    public func list() -> [DownloadEntry] {
        lock.withLock { entries.sorted { $0.createdAt > $1.createdAt } }
    }

    public func entry(_ id: UUID) -> DownloadEntry? {
        lock.withLock { entries.first { $0.id == id } }
    }

    // MARK: Incoming

    /// A fresh, empty staging location for an active download: `.incoming/<uuid>/<name>`.
    /// The per-download directory keeps the suggested name without collisions.
    public func makeIncomingURL(suggestedFilename: String) throws -> URL {
        let folder = incomingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try SecureFile.ensureDirectory(folder)
        return folder.appendingPathComponent(Self.sanitizedFilename(suggestedFilename))
    }

    /// Removes a staged download (cancelled or failed) and its staging folder.
    public func discardIncoming(_ url: URL) {
        Self.removeStaging(url, incoming: incomingDirectory)
    }

    /// Deletes everything left in `.incoming` (partial downloads after a crash or forced quit).
    /// Needs no key: the profile directory alone is enough.
    public static func purgeIncoming(inProfileDirectory profileDirectory: URL) {
        let incoming = incomingDirectory(in: profileDirectory.appendingPathComponent("downloads", isDirectory: true))
        try? FileManager.default.removeItem(at: incoming)
    }

    // MARK: Import / export

    /// Encrypts a finished download into the store, then deletes the plaintext (and, for a file
    /// in `.incoming`, its staging folder). The index is updated only after the encrypted file
    /// is complete, so a crash never produces an entry without its file.
    @discardableResult
    public func importFile(at plaintext: URL, filename: String? = nil, sourceURL: URL? = nil,
                           mimeType: String? = nil) throws -> DownloadEntry {
        let id = UUID()
        let attributes = try FileManager.default.attributesOfItem(atPath: plaintext.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CoreError.io("\(plaintext.lastPathComponent) is not a regular file")
        }
        let destination = fileURL(for: id)
        try SecureFile.ensureDirectory(directory)
        let size = try Self.encrypt(plaintext, to: destination, key: profileKey, info: Self.fileInfo(id))
        let entry = DownloadEntry(id: id, filename: Self.sanitizedFilename(filename ?? plaintext.lastPathComponent),
                                  sourceURL: sourceURL.flatMap(Self.displaySource), mimeType: mimeType,
                                  // Whole seconds, as stored (ISO 8601), so the returned entry equals the reloaded one.
                                  size: size, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        do {
            try lock.withLock {
                let updated = entries + [entry]
                try indexFile.save(updated)
                entries = updated
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        Self.removeStaging(plaintext, incoming: incomingDirectory)
        return entry
    }

    /// Decrypts an entry to `destination` (a file the user chose, or a private temp location).
    public func export(_ id: UUID, to destination: URL) throws {
        guard entry(id) != nil else { throw CoreError.io("download \(id) not found") }
        try Self.decrypt(fileURL(for: id), to: destination, key: profileKey, info: Self.fileInfo(id))
    }

    public func remove(_ id: UUID) throws {
        try lock.withLock {
            let updated = entries.filter { $0.id != id }
            try indexFile.save(updated)
            entries = updated
        }
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    // MARK: Helpers

    /// A name safe to use as a single path component on macOS: no separators, no control
    /// characters, no leading dots (hidden files), at most 200 characters.
    public static func sanitizedFilename(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F {
                return "_"
            }
            return Character(scalar)
        })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "download" }
        if trimmed.count <= 200 { return trimmed }
        let ext = (trimmed as NSString).pathExtension
        let base = String(trimmed.prefix(ext.isEmpty || ext.count > 16 ? 200 : 199 - ext.count))
        return ext.isEmpty || ext.count > 16 ? base : "\(base).\(ext)"
    }

    static func displaySource(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.string
    }

    private static func removeStaging(_ url: URL, incoming: URL) {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.deletingLastPathComponent().path == incoming.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: parent)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Streams `source` into an encrypted chunk stream at `destination` (atomic replace).
    /// Returns the plaintext size.
    static func encrypt(_ source: URL, to destination: URL, key: SymmetricKey, info: String,
                        chunkSize: Int = EncryptedDirectoryArchive.defaultChunkSize) throws -> UInt64 {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.io("cannot create \(temp.lastPathComponent)")
        }
        var total: UInt64 = 0
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            let writer = try EncryptedChunkWriter(handle: output, key: key, chunkSize: chunkSize, info: info)
            while let piece = try input.read(upToCount: chunkSize), !piece.isEmpty {
                try writer.write(piece)
                total += UInt64(piece.count)
            }
            try writer.finish()
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw (error as? CoreError) ?? CoreError.io("encrypt \(source.lastPathComponent): \(error)")
        }
        try SecureFile.replace(destination, with: temp)
        return total
    }

    /// Decrypts a chunk stream to `destination`. Written in place, not via a sibling temp file:
    /// inside the App Sandbox a save panel grants access to the chosen file only. If any chunk
    /// fails to authenticate, or the stream is truncated, the partial output is deleted.
    static func decrypt(_ source: URL, to destination: URL, key: SymmetricKey, info: String) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.io("cannot create \(destination.lastPathComponent)")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let reader = try EncryptedChunkReader(handle: input, key: key, info: info)
            while let piece = try reader.readAvailable() {
                try output.write(contentsOf: piece)
            }
            try reader.finish()
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
