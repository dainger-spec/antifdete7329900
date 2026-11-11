import BrowserCore
import Foundation

/// The iPhone's way to the Lumen sync server (CONTRACT.md §16; ios/SYNC_PLAN.md, decision 12): the
/// Mac's protocol (`SYNC_SERVER_API.md`, as `HTTPSyncTransport` speaks it), plus what the Mac's
/// transport does not do yet:
/// - `413 too_large` and `507 quota_exceeded` are about one object: it is deferred, as after a lost
///   compare-and-swap, and the run goes on (the engine defers a `syncConflict`) — never the whole run
///   stopped. Which objects, `deferredForSpace` says.
/// - the server's generation (§16.2): read from the list, sent on every write; `409
///   generation_changed` stops the run, nothing more written. Resetting the sync state when the
///   generation is not the one kept is `SyncGeneration`'s.
/// - `403 sync_not_in_plan`: the iPhone without a trial or a paid plan — said as a state.
///
/// The requests go through `send`, the app's own (the device token, no profile's proxy: decision 1
/// of the Mac's SYNC_FORMAT.md).
public final class LumenSyncTransport: SyncTransport, @unchecked Sendable {
    public struct Answer: Sendable {
        public var status: Int
        public var data: Data
        /// Header names in lower case.
        public var headers: [String: String]

        public init(status: Int, data: Data, headers: [String: String] = [:]) {
            self.status = status
            self.data = data
            self.headers = headers
        }
    }

    /// One request: method, path (relative to the server), body, headers. Throws when there is no answer.
    public typealias Send = @Sendable (String, String, Data?, [String: String]) async throws -> Answer

    public static let generationHeader = "X-Lumen-Server-Generation"

    public let vaultID: UUID
    private let send: Send
    private let lock = NSLock()
    private var _generation: String?
    private var _deferredForSpace: [String] = []

    public init(vaultID: UUID, send: @escaping Send) {
        self.vaultID = vaultID
        self.send = send
    }

    /// The server's generation of this vault, as the last answer said it ("none": no vault there).
    /// Nil: the server does not speak of generations.
    public var generation: String? { lock.withLock { _generation } }
    /// Objects the server refused for their size or the plan's space in this run (deferred).
    public var deferredForSpace: [String] { lock.withLock { _deferredForSpace } }

    private var base: String { "v1/vaults/\(vaultID.uuidString.lowercased())/objects" }

    private func noteGeneration(_ answer: Answer) {
        if let value = answer.headers[Self.generationHeader.lowercased()] { lock.withLock { _generation = value } }
    }

    private func refused(_ answer: Answer) -> CoreError {
        let code = AccountWire.refusal(answer.data)?.code ?? String(data: answer.data.prefix(200), encoding: .utf8) ?? ""
        return .syncServer(status: answer.status, message: code)
    }

    public func listObjects() async throws -> [RemoteObjectInfo] {
        let answer = try await send("GET", base, nil, ["Accept": "application/json"])
        guard answer.status == 200 else { throw refused(answer) }
        noteGeneration(answer)
        struct List: Decodable {
            struct Object: Decodable { var id: String; var revision: Int }
            var objects: [Object]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: answer.data) else { throw CoreError.corruptData("sync server list response") }
        return list.objects.filter { SyncObjectID.isValid($0.id) }.map { RemoteObjectInfo(objectID: $0.id, revision: $0.revision) }
    }

    public func fetch(objectID: String) async throws -> Data? {
        guard SyncObjectID.isValid(objectID) else { throw CoreError.corruptData("invalid object ID") }
        let answer = try await send("GET", "\(base)/\(objectID)", nil, [:])
        if answer.status == 404 { return nil }
        guard answer.status == 200 else { throw refused(answer) }
        return answer.data
    }

    public func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        guard SyncObjectID.isValid(objectID) else { throw CoreError.corruptData("invalid object ID") }
        var headers = ["Content-Type": "application/octet-stream", "X-PB-Revision": String(revision)]
        if let expectedRevision { headers["If-Match"] = "\"\(expectedRevision)\"" } else { headers["If-None-Match"] = "*" }
        if let generation { headers[Self.generationHeader] = generation }
        let answer = try await send("PUT", "\(base)/\(objectID)", data, headers)
        switch answer.status {
        case 200, 201, 204:
            noteGeneration(answer)
        case 412:
            let etag = answer.headers["etag"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/ "))
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: etag.flatMap(Int.init) ?? 0)
        case 413, 507:
            // The planted fault: the refusal stops the whole run, as the Mac's transport does today.
            if Faults.isActive(.spaceRefusalStopsSync) { throw refused(answer) }
            // One object too large, or the plan's space full: this object waits, the others go on.
            lock.withLock { _deferredForSpace.append(objectID) }
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: expectedRevision ?? 0)
        default:
            noteGeneration(answer)
            throw refused(answer)
        }
    }
}

/// The server's generation kept beside the sync's state (§16.2): when the server's is another one —
/// its data restored from a copy, or deleted in the cabinet — the engine's records of what it last
/// synced describe what the server no longer has, and they go: the next run takes every object as
/// changed here and merges, losing nothing on either side. Local data is not touched.
public enum SyncGeneration {
    /// After the run's list: `listed` is the transport's generation (nil: the server does not speak
    /// of generations — nothing changes), `kept` the one kept. Returns the one to keep.
    public static func reconcile(root: URL, listed: String?, kept: String?) -> String? {
        guard let listed else { return kept }
        if listed != kept {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("sync-state.bin"))
        }
        return listed
    }
}
