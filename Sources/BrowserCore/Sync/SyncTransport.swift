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
/// | `HTTPSyncTransport`            | client for docs/SYNC_SERVER_API.md: your own server, or the Lumen account's (`AccountSync`) |
public protocol SyncTransport: Sendable {
    func listObjects() async throws -> [RemoteObjectInfo]
    func fetch(objectID: String) async throws -> Data?
    /// Compare-and-swap write. Must fail with `CoreError.syncConflict` unless the current
    /// remote revision equals `expectedRevision` (`nil` = object must not exist yet).
    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws
}

/// A transport whose server keeps a generation of each vault's data — the Lumen server (its
/// docs/CONTRACT.md §16.2, "server generation"): a random value a vault gets when it is made, and anew
/// when the server's database is put back from a copy; `none` while the server has no such vault (its
/// data deleted on the account page). The engine keeps the generation it synced with beside its
/// records, and forgets those records when the server names another one (`SyncEngine.sync`): they
/// describe data the server no longer has. Not the vault's own generation (R3, `VaultHeader.format`).
public protocol ServerGenerationTransport: SyncTransport {
    /// Whose generation it is: the server's address and the vault. A generation kept for another
    /// address is not this one's.
    var generationScope: String { get }
    /// What the server said in this run's list, or in a write it accepted since: 32 lowercase hex
    /// characters, or `none`. Nil: it said nothing — a server that keeps no generations.
    var serverGeneration: String? { get }
}

/// A refusal of the sync server that names its reason in the body, as the Lumen server does
/// (`{"error": {"code": …, …}}`, its docs/CONTRACT.md §3 and §16.1). A refusal without one stays
/// `CoreError.syncServer`, with the start of its body.
public struct SyncServerRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public var status: Int
    public var code: String
    /// `sync_on_hold`: when sync opens on this device.
    public var availableAt: Date?
    /// `rate_limited`: in how many seconds to ask again (the body's, or the `Retry-After` header's).
    public var retryAfter: Int?

    public init(status: Int, code: String, availableAt: Date? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.code = code
        self.availableAt = availableAt
        self.retryAfter = retryAfter
    }

    /// `413 too_large`, `507 quota_exceeded`: about the one object written, not about the run — the
    /// engine defers that object, as after a lost compare-and-swap, and goes on with the rest.
    public var isAboutOneObject: Bool { status == 413 || status == 507 }

    /// `409 generation_changed` (§16.2): the server's data is not the one this run works with. Nothing
    /// was written; the run stops, and the next one starts over from the list.
    public var isGenerationChanged: Bool { status == 409 && code == "generation_changed" }

    public var description: String { "Sync server refused the request (HTTP \(status), \(code))" }
}

extension SyncServerRefusal: LocalizedError {
    public var errorDescription: String? { CoreErrorText.translate?(self) ?? description }
}

/// Object IDs are `vault-header` or 64 lowercase hex characters (HMAC-SHA256 of the logical name).
/// Transports validate them before using them in file names or URL paths.
public enum SyncObjectID {
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
