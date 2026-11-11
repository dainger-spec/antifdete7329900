import BrowserCore
@testable import LumenCore
import XCTest

/// The iPhone's sync transport against a server that answers as CONTRACT.md §16 says.
final class SyncTransportTests: XCTestCase {
    /// A server in memory: objects with revisions, a generation, and refusals to plant.
    final class Server: @unchecked Sendable {
        var objects: [String: (revision: Int, data: Data)] = [:]
        var generation: String? = "0123456789abcdef0123456789abcdef"
        var refuseNext: (status: Int, code: String)?
        var requests: [(method: String, path: String, headers: [String: String])] = []
        let lock = NSLock()

        func answer(_ method: String, _ path: String, _ body: Data?, _ headers: [String: String]) -> LumenSyncTransport.Answer {
            lock.lock(); defer { lock.unlock() }
            requests.append((method, path, headers))
            var out: [String: String] = [:]
            if let generation { out["x-lumen-server-generation"] = generation }
            if let refusal = refuseNext {
                refuseNext = nil
                return .init(status: refusal.status, data: Data(#"{"error":{"code":"\#(refusal.code)"}}"#.utf8), headers: out)
            }
            let id = path.components(separatedBy: "/").last ?? ""
            switch method {
            case "GET" where path.hasSuffix("/objects"):
                let list = objects.map { #"{"id":"\#($0.key)","revision":\#($0.value.revision)}"# }.joined(separator: ",")
                return .init(status: 200, data: Data(#"{"objects":[\#(list)]}"#.utf8), headers: out)
            case "GET":
                guard let object = objects[id] else { return .init(status: 404, data: Data(), headers: out) }
                return .init(status: 200, data: object.data, headers: out)
            default:
                if let sent = headers[LumenSyncTransport.generationHeader], sent != (generation ?? "none") {
                    return .init(status: 409, data: Data(#"{"error":{"code":"generation_changed"}}"#.utf8), headers: out)
                }
                let current = objects[id]?.revision
                let expected = headers["If-Match"].map { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) } ?? nil
                guard current == expected else {
                    out["etag"] = "\"\(current ?? 0)\""
                    return .init(status: 412, data: Data(), headers: out)
                }
                objects[id] = (Int(headers["X-PB-Revision"] ?? "0") ?? 0, body ?? Data())
                if generation == nil { generation = "fedcba9876543210fedcba9876543210"; out["x-lumen-server-generation"] = generation }
                return .init(status: 201, data: Data(), headers: out)
            }
        }
    }

    func transport(_ server: Server) -> LumenSyncTransport {
        LumenSyncTransport(vaultID: UUID()) { method, path, body, headers in server.answer(method, path, body, headers) }
    }

    let objectA = String(repeating: "a", count: 64)
    let objectB = String(repeating: "b", count: 64)

    func testTheMacsProtocolWithTheGeneration() async throws {
        let server = Server()
        let transport = transport(server)
        try await transport.store(objectID: objectA, revision: 1, data: Data("one".utf8), expectedRevision: nil)
        XCTAssertEqual(server.requests.last?.headers["If-None-Match"], "*")
        let listed = try await transport.listObjects()
        XCTAssertEqual(listed, [RemoteObjectInfo(objectID: objectA, revision: 1)])
        XCTAssertEqual(transport.generation, server.generation, "the list's generation is kept")
        let fetched = try await transport.fetch(objectID: objectA)
        XCTAssertEqual(fetched, Data("one".utf8))
        let missing = try await transport.fetch(objectID: objectB)
        XCTAssertNil(missing)
        try await transport.store(objectID: objectA, revision: 2, data: Data("two".utf8), expectedRevision: 1)
        XCTAssertEqual(server.requests.last?.headers["If-Match"], "\"1\"")
        XCTAssertEqual(server.requests.last?.headers[LumenSyncTransport.generationHeader], server.generation, "each write says the generation")

        // A lost compare-and-swap: deferred with the server's revision.
        do {
            try await transport.store(objectID: objectA, revision: 2, data: Data("late".utf8), expectedRevision: 1)
            XCTFail("a stale write is refused")
        } catch let CoreError.syncConflict(id, revision) {
            XCTAssertEqual(id, objectA)
            XCTAssertEqual(revision, 2)
        }

        // The server's data restored: another generation — the write is refused and the run stops.
        server.generation = "11111111111111111111111111111111"
        do {
            try await transport.store(objectID: objectA, revision: 3, data: Data("x".utf8), expectedRevision: 2)
            XCTFail("a write under another generation is refused")
        } catch CoreError.syncServer(409, "generation_changed") {}
    }

    func testARefusalForSpaceDefersOneObject() async throws {
        let server = Server()
        let transport = transport(server)
        _ = try await transport.listObjects()
        for (status, code) in [(413, "too_large"), (507, "quota_exceeded")] {
            server.refuseNext = (status, code)
            do {
                try await transport.store(objectID: objectB, revision: 1, data: Data(count: 10), expectedRevision: nil)
                XCTFail("refused")
            } catch CoreError.syncConflict(let id, _) {
                XCTAssertEqual(id, objectB)
            } catch {
                XCTFail("a refusal for space defers the one object, it does not stop the run: \(error)")
            }
        }
        XCTAssertEqual(transport.deferredForSpace, [objectB, objectB])
        // The next object goes on.
        try await transport.store(objectID: objectA, revision: 1, data: Data("a".utf8), expectedRevision: nil)
    }

    func testWithoutAPlanTheSyncSaysSo() async throws {
        let server = Server()
        server.refuseNext = (403, "sync_not_in_plan")
        do {
            _ = try await transport(server).listObjects()
            XCTFail("refused")
        } catch CoreError.syncServer(403, "sync_not_in_plan") {}
    }

    func testAnotherGenerationForgetsTheSyncState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("sync-state.bin")
        try Data("records".utf8).write(to: state)
        XCTAssertEqual(SyncGeneration.reconcile(root: root, listed: nil, kept: "a"), "a", "a server without generations changes nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        XCTAssertEqual(SyncGeneration.reconcile(root: root, listed: "a", kept: "a"), "a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path), "the same generation keeps the records")
        XCTAssertEqual(SyncGeneration.reconcile(root: root, listed: "b", kept: "a"), "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "another generation: the records go")
        try Data("records".utf8).write(to: state)
        XCTAssertEqual(SyncGeneration.reconcile(root: root, listed: "b", kept: nil), "b", "none kept yet: the first run starts afresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }
}
