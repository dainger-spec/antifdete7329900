import Foundation

public struct RemoteObjectInfo: Equatable, Sendable {
    public var objectID: String
    public var revision: Int

    public init(objectID: String, revision: Int) {
        self.objectID = objectID
        self.revision = revision
    }
}

/// Minimal storage interface a sync backend must provide. Any blob store with
/// conditional writes fits: S3 (If-Match on ETag), WebDAV, CloudKit (record change
/// tags), a small REST service, or a shared folder (`LocalDirectorySyncTransport`).
///
/// The backend only ever handles opaque blobs; it needs no knowledge of the format.
public protocol SyncTransport: Sendable {
    func listObjects() async throws -> [RemoteObjectInfo]
    func fetch(objectID: String) async throws -> Data?
    /// Compare-and-swap write. Must fail with `CoreError.syncConflict` unless the current
    /// remote revision equals `expectedRevision` (`nil` = object must not exist yet).
    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws
}

/// Sync "server" backed by a directory (e.g. a folder on an external disk, a NAS
/// mount, or a cloud-drive folder). Each object is `<objectID>.json` containing
/// `{"revision": n, "blob": base64}`.
///
/// LIMITATION: the compare-and-swap is atomic only within one process (actor
/// isolation). Two devices writing the same object through a file-syncing service
/// (iCloud Drive, Dropbox) at the same moment can still both "win"; those services
/// then produce conflict copies, which this transport ignores. Use a backend with
/// real conditional writes for multi-device production use.
public actor LocalDirectorySyncTransport: SyncTransport {
    private struct StoredObject: Codable {
        var revision: Int
        var blob: Data
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func listObjects() async throws -> [RemoteObjectInfo] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { name in
                let objectID = String(name.dropLast(5))
                guard Self.isValidObjectID(objectID), let stored = try load(objectID) else { return nil }
                return RemoteObjectInfo(objectID: objectID, revision: stored.revision)
            }
    }

    public func fetch(objectID: String) async throws -> Data? {
        try load(objectID)?.blob
    }

    public func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        let current = try load(objectID)
        guard current?.revision == expectedRevision else {
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: current?.revision ?? 0)
        }
        try SecureFile.write(JSONCoding.encoder.encode(StoredObject(revision: revision, blob: data)), to: url(objectID))
    }

    private func load(_ objectID: String) throws -> StoredObject? {
        let url = try url(objectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONCoding.decoder.decode(StoredObject.self, from: SecureFile.read(url))
    }

    private func url(_ objectID: String) throws -> URL {
        guard Self.isValidObjectID(objectID) else { throw CoreError.corruptData("invalid object ID") }
        return directory.appendingPathComponent("\(objectID).json")
    }

    static func isValidObjectID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
