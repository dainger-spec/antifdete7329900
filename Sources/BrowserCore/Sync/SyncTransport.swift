import Foundation

public struct RemoteObjectInfo: Equatable, Sendable {
    public var objectID: String
    public var revision: Int

    public init(objectID: String, revision: Int) {
        self.objectID = objectID
        self.revision = revision
    }
}

/// The contract between the sync client and any backend — the only thing a future server
/// has to implement (over HTTP: docs/SYNC_SERVER_API.md, client: `HTTPSyncTransport`).
///
/// Any blob store with conditional writes fits: a small REST service, S3 (If-Match on ETag),
/// WebDAV, CloudKit (record change tags), or a shared folder (`LocalDirectorySyncTransport`).
/// The backend only ever handles opaque blobs keyed by opaque object IDs; it needs no
/// knowledge of the format and never sees plaintext.
///
/// Transports in this package:
/// | Transport                      | Status                                                        |
/// |--------------------------------|---------------------------------------------------------------|
/// | `LocalDirectorySyncTransport`  | local-only: a folder (NAS, external disk); CAS within one process |
/// | `HTTPSyncTransport`            | server-ready client for docs/SYNC_SERVER_API.md; no server included |
public protocol SyncTransport: Sendable {
    func listObjects() async throws -> [RemoteObjectInfo]
    func fetch(objectID: String) async throws -> Data?
    /// Compare-and-swap write. Must fail with `CoreError.syncConflict` unless the current
    /// remote revision equals `expectedRevision` (`nil` = object must not exist yet).
    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws
}

/// Object IDs are `vault-header` or 64 lowercase hex characters (HMAC-SHA256 of the logical name).
/// Transports validate them before using them in file names or URL paths.
public enum SyncObjectID {
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
