import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BrowserCore

/// The Lumen sync server as its docs/CONTRACT.md §16 describes it, in this process: the API of
/// SYNC_SERVER_API.md, the device token, refusals in its JSON shape (`{"error": {"code", …}}`), and the
/// server generation of §16.2 — every vault has one from its first write, a list and an accepted
/// write name it in `X-Lumen-Server-Generation`, a vault that is not there is `none`, and a write that
/// names another one than the vault's gets `409 generation_changed` with nothing written.
final class GenerationStubServer: URLProtocol {
    struct Vault {
        var generation: String
        var objects: [String: (revision: Int, blob: Data)]
    }

    struct Request {
        var method: String
        /// The object's id; nil for the list.
        var object: String?
        /// `X-Lumen-Server-Generation` as the request carried it.
        var generation: String?
        var status: Int
    }

    /// What the server holds and was asked, for the whole process (URL loading makes the protocol's
    /// instances itself); read and changed under `lock`.
    final class State: @unchecked Sendable {
        var vaults: [String: Vault] = [:]
        var knowsGenerations = true
        var requests: [Request] = []
        var refused: [String: Int] = [:]
        var holdUntil: Date?
        var beforePut: ((Int) -> Void)?
        var writeCount = 0
        var maxObjectBytes: Int?
    }

    static let host = "gen.test"
    static let token = "lmd_test_device"
    static let lock = NSLock()
    static let state = State()
    static var vaults: [String: Vault] {
        get { state.vaults }
        set { state.vaults = newValue }
    }
    /// False: a server of before generations — no header in its answers, none checked.
    static var knowsGenerations: Bool {
        get { state.knowsGenerations }
        set { state.knowsGenerations = newValue }
    }
    static var requests: [Request] {
        get { state.requests }
        set { state.requests = newValue }
    }
    /// Writes of these objects are refused: 413 (too large) or 507 (no room left in the plan's space).
    static var refused: [String: Int] {
        get { state.refused }
        set { state.refused = newValue }
    }
    /// `403 sync_on_hold` for every request until then.
    static var holdUntil: Date? {
        get { state.holdUntil }
        set { state.holdUntil = newValue }
    }
    /// Called with the lock held before each write is looked at, with its number in the test (1, 2, …).
    static var beforePut: ((Int) -> Void)? {
        get { state.beforePut }
        set { state.beforePut = newValue }
    }
    static var writeCount: Int {
        get { state.writeCount }
        set { state.writeCount = newValue }
    }
    /// Writes of more bytes than this are refused `413 too_large`, as the Lumen server refuses what is
    /// over `LUMEN_SYNC_MAX_OBJECT_MB` (16 MiB). Nil: any size.
    static var maxObjectBytes: Int? {
        get { state.maxObjectBytes }
        set { state.maxObjectBytes = newValue }
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        vaults = [:]
        knowsGenerations = true
        requests = []
        refused = [:]
        holdUntil = nil
        beforePut = nil
        writeCount = 0
        maxObjectBytes = nil
    }

    static func newGeneration() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func snapshot() -> [String: Vault] {
        lock.lock(); defer { lock.unlock() }
        return vaults
    }

    /// The database put back from a copy, and `after-restore` run: the copy's data, a new generation for
    /// every vault.
    static func restore(_ copy: [String: Vault]) {
        lock.lock(); defer { lock.unlock() }
        vaults = copy.mapValues { Vault(generation: newGeneration(), objects: $0.objects) }
    }

    /// A disk snapshot put back without `after-restore`: the copy's data under the generations it had.
    static func rollBack(to copy: [String: Vault]) {
        lock.lock(); defer { lock.unlock() }
        vaults = copy
    }

    /// "Delete sync data" on the account page: no vault, so `none`.
    static func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        vaults = [:]
    }

    /// A new generation for every vault, the data kept. With the lock held (from `beforePut`).
    static func regenerateHoldingTheLock() {
        for key in vaults.keys { vaults[key]?.generation = newGeneration() }
    }

    static func removeObject(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        for key in vaults.keys { vaults[key]?.objects[id] = nil }
    }

    static func blob(vault: UUID, object: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return vaults[vault.uuidString.lowercased()]?.objects[object]?.blob
    }

    static func writes(after index: Int) -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return requests.dropFirst(index + 1).filter { $0.method == "PUT" }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, headers, body) = Self.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func refusal(_ status: Int, _ code: String, _ extra: [String: Any] = [:], headers: [String: String] = [:])
        -> (Int, [String: String], Data) {
        var body: [String: Any] = ["code": code, "message": "stub"]
        for (key, value) in extra { body[key] = value }
        var all = headers
        all["Content-Type"] = "application/json"
        return (status, all, try! JSONSerialization.data(withJSONObject: ["error": body]))
    }

    private static func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
        let named = request.value(forHTTPHeaderField: HTTPSyncTransport.generationHeader)
        let object = parts.count > 4 ? parts[4] : nil
        let result = respond(request, method: method, parts: parts, named: named)
        requests.append(Request(method: method, object: object, generation: named, status: result.0))
        return result
    }

    private static func respond(_ request: URLRequest, method: String, parts: [String], named: String?) -> (Int, [String: String], Data) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { return refusal(401, "unauthorized") }
        if let holdUntil {
            return refusal(403, "sync_on_hold", ["availableAt": ISO8601DateFormatter().string(from: holdUntil)])
        }
        guard parts.count >= 4, parts[0] == "v1", parts[1] == "vaults", parts[3] == "objects" else { return (404, [:], Data()) }
        let vaultID = parts[2]
        let vault = vaults[vaultID]
        let before = vault?.generation ?? "none"
        func said(_ generation: String) -> [String: String] {
            knowsGenerations ? [HTTPSyncTransport.generationHeader: generation] : [:]
        }
        switch (method, parts.count) {
        case ("GET", 4):
            let list = (vault?.objects ?? [:]).map { ["id": $0.key, "revision": $0.value.revision] as [String: Any] }
            var headers = said(before)
            headers["Content-Type"] = "application/json"
            return (200, headers, try! JSONSerialization.data(withJSONObject: ["objects": list]))
        case ("GET", 5):
            guard let stored = vault?.objects[parts[4]] else { return (404, said(before), Data()) }
            var headers = said(before)
            headers["ETag"] = "\"\(stored.revision)\""
            return (200, headers, stored.blob)
        case ("PUT", 5):
            writeCount += 1
            beforePut?(writeCount)
            // Read once: a body that came as a stream is not there a second time.
            let sent = body(of: request)
            let now = vaults[vaultID]
            let current = now?.generation ?? "none"
            let id = parts[4]
            if let status = refused[id] {
                return status == 413 ? refusal(413, "too_large") : refusal(507, "quota_exceeded", headers: said(current))
            }
            if let maxObjectBytes, sent.count > maxObjectBytes { return refusal(413, "too_large") }
            if knowsGenerations, let named, named != current {
                return refusal(409, "generation_changed", headers: said(current))
            }
            let existing = now?.objects[id]?.revision
            if let ifMatch = request.value(forHTTPHeaderField: "If-Match") {
                guard existing.map({ "\"\($0)\"" }) == ifMatch else {
                    var headers = said(current)
                    if let existing { headers["ETag"] = "\"\(existing)\"" }
                    return refusal(412, "precondition_failed", headers: headers)
                }
            } else if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                guard existing == nil else { return refusal(412, "precondition_failed", headers: said(current).merging(["ETag": "\"\(existing!)\""]) { $1 }) }
            } else {
                return refusal(428, "precondition_required", headers: said(current))
            }
            guard let revision = request.value(forHTTPHeaderField: HTTPSyncTransport.revisionHeader).flatMap(Int.init),
                  revision > (existing ?? 0) else { return refusal(400, "bad_revision", headers: said(current)) }
            var updated = now ?? Vault(generation: newGeneration(), objects: [:])
            updated.objects[id] = (revision, sent)
            vaults[vaultID] = updated
            var headers = said(updated.generation)
            headers["ETag"] = "\"\(revision)\""
            return (existing == nil ? 201 : 204, headers, Data())
        default:
            return (405, [:], Data())
        }
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A transport that lets the test act between the engine's steps: before a write, as another Mac
/// would, while the run is under way.
final class InterleavingTransport: ServerGenerationTransport, @unchecked Sendable {
    let inner: HTTPSyncTransport
    /// Run once, before the first write.
    var beforeFirstStore: (() async throws -> Void)?

    init(inner: HTTPSyncTransport) { self.inner = inner }

    var generationScope: String { inner.generationScope }
    var serverGeneration: String? { inner.serverGeneration }
    func listObjects() async throws -> [RemoteObjectInfo] { try await inner.listObjects() }
    func fetch(objectID: String) async throws -> Data? { try await inner.fetch(objectID: objectID) }
    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        if let first = beforeFirstStore {
            beforeFirstStore = nil
            try await first()
        }
        try await inner.store(objectID: objectID, revision: revision, data: data, expectedRevision: expectedRevision)
    }
}

/// The server generation of the Lumen account server's CONTRACT §16.2, against `GenerationStubServer`:
/// `HTTPSyncTransport` reads, sends and follows it; the engine passes the seven checks §16.2 asks of a
/// client; and a refusal of one object (`413`, `507`) does not stop the run (§16.1).
final class ServerGenerationTests: XCTestCase {
    var base: URL!
    var session: URLSession!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-servergeneration-\(UUID().uuidString)")
        GenerationStubServer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationStubServer.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        GenerationStubServer.reset()
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Helpers

    private func transport(_ vaultID: UUID, token: String = GenerationStubServer.token) throws -> HTTPSyncTransport {
        try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "https://\(GenerationStubServer.host)")!, vaultID: vaultID,
                                                   bearerToken: token),
                              session: session)
    }

    /// One run, as the app makes it: a transport of its own.
    @discardableResult
    private func sync(_ repository: ProfileRepository) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: transport(repository.vault.vaultID)).sync()
    }

    private func newVault(_ name: String) throws -> ProfileRepository {
        try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent(name), password: "pw", iterations: 1_000))
    }

    /// A second Mac set up from the server, synced once.
    private func joined(_ name: String, to vaultID: UUID) async throws -> ProfileRepository {
        let vault = try await SyncEngine.bootstrap(transport: transport(vaultID), root: base.appendingPathComponent(name), password: "pw")
        let repository = try ProfileRepository(vault: vault)
        try await sync(repository)
        return repository
    }

    private func addBookmark(_ repository: ProfileRepository, _ id: UUID, _ title: String) throws {
        _ = try repository.bookmarkStore(for: id, key: repository.profileKey(for: id)).add(title: title, url: URL(string: "https://\(title).example/")!)
    }

    private func bookmarks(_ repository: ProfileRepository, _ id: UUID) throws -> [String] {
        try repository.bookmarkStore(for: id, key: repository.profileKey(for: id)).all().map(\.title).sorted()
    }

    /// Settings changed as an older build writes them: without the time of the change.
    private func setTimeZoneWithoutTime(_ repository: ProfileRepository, _ id: UUID, _ zone: String) throws {
        var configuration = try repository.loadConfiguration(id)
        configuration.timeZoneIdentifier = zone
        configuration.settingsModifiedAt = nil
        try repository.saveConfiguration(configuration, for: id)
    }

    private func objectID(_ repository: ProfileRepository, _ name: String) throws -> String {
        try SyncCodec(vault: repository.vault).objectID(for: name)
    }

    // MARK: The transport

    func testTheTransportReadsSendsAndFollowsTheServersGeneration() async throws {
        let vaultID = UUID()
        let http = try transport(vaultID)
        XCTAssertEqual(http.generationScope, "https://\(GenerationStubServer.host)|\(vaultID.uuidString.lowercased())")
        XCTAssertNil(http.serverGeneration, "nothing said before the first list")
        _ = try await http.listObjects()
        XCTAssertEqual(http.serverGeneration, "none", "no vault there")

        let first = String(repeating: "ab", count: 32), second = String(repeating: "cd", count: 32)
        try await http.store(objectID: first, revision: 1, data: Data("one".utf8), expectedRevision: nil)
        let made = try XCTUnwrap(GenerationStubServer.snapshot()[vaultID.uuidString.lowercased()]?.generation)
        XCTAssertEqual(GenerationStubServer.requests.last?.generation, "none", "the write that makes the vault says none")
        XCTAssertEqual(http.serverGeneration, made, "the generation the write made is the run's from then on")
        XCTAssertEqual(made.count, 32)

        try await http.store(objectID: second, revision: 1, data: Data("two".utf8), expectedRevision: nil)
        XCTAssertEqual(GenerationStubServer.requests.last?.generation, made)

        // The server put back from a copy: a write with the old one is refused, nothing is written, and
        // the transport keeps the generation the run began with.
        GenerationStubServer.restore(GenerationStubServer.snapshot())
        do {
            try await http.store(objectID: first, revision: 2, data: Data("changed".utf8), expectedRevision: 1)
            XCTFail("a write naming the old generation must be refused")
        } catch let refusal as SyncServerRefusal {
            XCTAssertTrue(refusal.isGenerationChanged, "\(refusal)")
        }
        XCTAssertEqual(GenerationStubServer.blob(vault: vaultID, object: first), Data("one".utf8))
        XCTAssertEqual(http.serverGeneration, made)
        _ = try await http.listObjects()
        XCTAssertNotEqual(http.serverGeneration, made, "the next list names the new one")
    }

    func testAServerWithoutGenerationsIsWrittenToWithoutTheHeader() async throws {
        GenerationStubServer.knowsGenerations = false
        let http = try transport(UUID())
        _ = try await http.listObjects()
        XCTAssertNil(http.serverGeneration)
        try await http.store(objectID: String(repeating: "ab", count: 32), revision: 1, data: Data("one".utf8), expectedRevision: nil)
        XCTAssertNil(GenerationStubServer.requests.last?.generation)
        XCTAssertEqual(GenerationStubServer.requests.last?.status, 201)
        XCTAssertNil(http.serverGeneration)
    }

    func testRefusalsAreReadByTheirCode() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        GenerationStubServer.holdUntil = date
        do {
            _ = try await transport(UUID()).listObjects()
            XCTFail("a device on hold must be refused")
        } catch let refusal as SyncServerRefusal {
            XCTAssertEqual(refusal.status, 403)
            XCTAssertEqual(refusal.code, "sync_on_hold")
            XCTAssertEqual(refusal.availableAt, date)
        }
        GenerationStubServer.holdUntil = nil
        do {
            _ = try await transport(UUID(), token: "lmd_unlinked").listObjects()
            XCTFail("a device token the server does not know must be refused")
        } catch {
            XCTAssertEqual(error as? SyncServerRefusal, SyncServerRefusal(status: 401, code: "unauthorized"))
        }
    }

    /// What the engine defers as one object's refusal, and what stops the run.
    func testOnlyRefusalsOfOneObjectAreDeferred() {
        XCTAssertEqual(SyncEngine.refusalOfOneObject(CoreError.syncServer(status: 413, message: "too large")), 413)
        XCTAssertEqual(SyncEngine.refusalOfOneObject(SyncServerRefusal(status: 507, code: "quota_exceeded")), 507)
        XCTAssertNil(SyncEngine.refusalOfOneObject(SyncServerRefusal(status: 409, code: "generation_changed")))
        XCTAssertNil(SyncEngine.refusalOfOneObject(SyncServerRefusal(status: 403, code: "forbidden")))
        XCTAssertNil(SyncEngine.refusalOfOneObject(CoreError.syncServer(status: 500, message: "x")))
    }

    // MARK: The engine and the server generation (§16.2, the seven checks)

    /// 1. Restore: the generation changed, the server's revisions are below the recorded ones, this
    /// Mac's data newer. The Mac takes none of the old versions; afterwards the server holds its own.
    func testAServerPutBackFromACopyTakesThisMacsNewerData() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris")).id
        try addBookmark(a, id, "first")
        try await sync(a)
        let copy = GenerationStubServer.snapshot()
        XCTAssertEqual(try SyncEngine(repository: a, transport: transport(a.vault.vaultID)).keptServerGeneration()?.value,
                       copy[a.vault.vaultID.uuidString.lowercased()]?.generation)

        var configuration = try a.loadConfiguration(id)
        configuration.timeZoneIdentifier = "Asia/Tokyo"
        try a.saveConfiguration(configuration.savingEdit(over: a.loadConfiguration(id)), for: id)
        try addBookmark(a, id, "second")
        try await sync(a)

        GenerationStubServer.restore(copy)
        let report = try await sync(a)
        XCTAssertTrue(report.startedOver)
        XCTAssertFalse(report.pulled.contains("profile/\(id.uuidString)/config"), "the old settings are not taken: \(report.pulled)")
        XCTAssertEqual(try a.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(try bookmarks(a, id), ["first", "second"])

        // The server holds this Mac's now: a Mac set up from it gets them.
        let b = try await joined("B", to: a.vault.vaultID)
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(try bookmarks(b, id), ["first", "second"])
    }

    /// 2. Deletion: the list is empty, `none`. The Mac puts all of its own back; a second Mac then
    /// merges its own with them — each ends with what either had.
    func testSyncDataDeletedOnTheAccountPageIsPutBackAndMerged() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try addBookmark(a, id, "shared")
        try await sync(a)
        let b = try await joined("B", to: a.vault.vaultID)
        try addBookmark(a, id, "onlyA")
        try addBookmark(b, id, "onlyB")

        GenerationStubServer.deleteAll()
        let mark = GenerationStubServer.requests.count - 1
        let report = try await sync(a)
        XCTAssertTrue(report.startedOver)
        XCTAssertTrue(report.pushed.contains("index"))
        for file in ["config", "bookmarks"] { XCTAssertTrue(report.pushed.contains("profile/\(id.uuidString)/\(file)"), "\(report.pushed)") }
        let writes = GenerationStubServer.writes(after: mark)
        XCTAssertEqual(writes.first?.generation, "none", "the first write says the vault is made anew")
        XCTAssertTrue(writes.dropFirst().allSatisfy { $0.generation != "none" && $0.generation != nil }, "the rest name the new one")

        let reportB = try await sync(b)
        XCTAssertTrue(reportB.startedOver)
        try await sync(a)
        XCTAssertEqual(try bookmarks(a, id), ["onlyA", "onlyB", "shared"])
        XCTAssertEqual(try bookmarks(b, id), ["onlyA", "onlyB", "shared"])
    }

    /// 3. Two Macs make the vault again at once, both with `none`: one gets 201, the other 409 and
    /// writes nothing more; its next run merges.
    func testTwoMacsMakingTheVaultAgainAtOnceEndWithEverything() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try addBookmark(a, id, "shared")
        try await sync(a)
        let b = try await joined("B", to: a.vault.vaultID)
        try addBookmark(a, id, "onlyA")
        try addBookmark(b, id, "onlyB")
        GenerationStubServer.deleteAll()

        // B has listed (`none`) and is about to write when A makes the vault again.
        let interleaving = InterleavingTransport(inner: try transport(b.vault.vaultID))
        interleaving.beforeFirstStore = { [unowned self] in _ = try await self.sync(a) }
        let before = GenerationStubServer.requests.count
        do {
            _ = try await SyncEngine(repository: b, transport: interleaving).sync()
            XCTFail("B's write with none must meet A's vault")
        } catch let refusal as SyncServerRefusal {
            XCTAssertTrue(refusal.isGenerationChanged)
        }
        let afterA = GenerationStubServer.requests.lastIndex { $0.status == 409 } ?? before
        XCTAssertTrue(GenerationStubServer.writes(after: afterA).isEmpty, "nothing more written after the 409")

        // B's records went at the start of the refused run, and its next run compares everything anew.
        let report = try await sync(b)
        XCTAssertTrue(report.merged.contains("profile/\(id.uuidString)/bookmarks"), "\(report.merged)")
        try await sync(a)
        XCTAssertEqual(try bookmarks(a, id), ["onlyA", "onlyB", "shared"])
        XCTAssertEqual(try bookmarks(b, id), ["onlyA", "onlyB", "shared"])
    }

    /// 4. A server without the header: everything as before, no generation kept; the state names the
    /// place its records are of — the server and the vault — in format 3.
    func testAServerWithoutGenerationsKeepsTheStateAsBefore() async throws {
        GenerationStubServer.knowsGenerations = false
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try await sync(a)
        try addBookmark(a, id, "more")
        let report = try await sync(a)
        XCTAssertFalse(report.startedOver)
        XCTAssertTrue(report.pushed.contains("profile/\(id.uuidString)/bookmarks"), "\(report.pushed)")
        XCTAssertFalse(report.pushed.contains("profile/\(id.uuidString)/config"), "nothing else went up again: \(report.pushed)")
        let engine = try SyncEngine(repository: a, transport: transport(a.vault.vaultID))
        XCTAssertNil(try engine.keptServerGeneration())
        XCTAssertEqual(try engine.keptPlace(), "server|https://\(GenerationStubServer.host)|\(a.vault.vaultID.uuidString.lowercased())")
        let state = try AEAD.open(SecureFile.read(engine.stateURL), key: a.vault.syncEnvelopeKey, aad: engine.stateAAD)
        XCTAssertEqual(DocumentFormat.declared(in: state), 3)
        XCTAssertTrue(GenerationStubServer.requests.allSatisfy { $0.generation == nil })
    }

    /// 5. Starting over without a new generation: the server went back (a disk snapshot put back
    /// without `after-restore`) or lost an object, under the same generation.
    func testAnObjectGoneOrOlderUnderTheSameGenerationStartsOver() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try addBookmark(a, id, "first")
        try await sync(a)
        let copy = GenerationStubServer.snapshot()
        try addBookmark(a, id, "second")
        try await sync(a)

        GenerationStubServer.rollBack(to: copy)
        let report = try await sync(a)
        XCTAssertTrue(report.startedOver)
        XCTAssertEqual(try bookmarks(a, id), ["first", "second"])

        // An object the records name, gone from the server: put back.
        let settings = try objectID(a, "profile/\(id.uuidString)/config")
        GenerationStubServer.removeObject(settings)
        let again = try await sync(a)
        XCTAssertTrue(again.startedOver)
        XCTAssertTrue(again.pushed.contains("profile/\(id.uuidString)/config"), "\(again.pushed)")
        XCTAssertNotNil(GenerationStubServer.blob(vault: a.vault.vaultID, object: settings))

        // And then, nothing to do.
        let quiet = try await sync(a)
        XCTAssertFalse(quiet.startedOver)
        XCTAssertEqual(quiet.pushed, [])
        XCTAssertEqual(quiet.pulled, [])
    }

    /// 6. `409` in the middle of a run: nothing more is written; the next run starts over.
    func testAGenerationChangedMidRunStopsItAndTheNextStartsOver() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try addBookmark(a, id, "first")
        GenerationStubServer.beforePut = { number in
            if number == 3 { GenerationStubServer.regenerateHoldingTheLock() }
        }
        do {
            try await sync(a)
            XCTFail("a write after the generation changed must be refused")
        } catch let refusal as SyncServerRefusal {
            XCTAssertTrue(refusal.isGenerationChanged)
        }
        let refusedAt = try XCTUnwrap(GenerationStubServer.requests.lastIndex { $0.status == 409 })
        XCTAssertTrue(GenerationStubServer.writes(after: refusedAt).isEmpty, "nothing more written after the 409")

        GenerationStubServer.beforePut = nil
        let report = try await sync(a)
        XCTAssertTrue(report.startedOver)
        XCTAssertTrue(report.pushed.contains("profile/\(id.uuidString)/bookmarks"), "\(report.pushed)")
        let b = try await joined("B", to: a.vault.vaultID)
        XCTAssertEqual(try bookmarks(b, id), ["first"])
    }

    /// 7. After starting over, settings without a time on both sides: this Mac's stay, the server's are
    /// kept beside them. After a second such start, the first version kept is intact.
    func testSettingsWithoutTimesAfterStartingOverKeepThisMacsAndEveryOther() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris")).id
        try await sync(a)
        let b = try await joined("B", to: a.vault.vaultID)
        try setTimeZoneWithoutTime(b, id, "Asia/Tokyo")
        try await sync(b)
        try setTimeZoneWithoutTime(a, id, "America/New_York")

        GenerationStubServer.restore(GenerationStubServer.snapshot())
        let report = try await sync(a)
        XCTAssertTrue(report.startedOver)
        XCTAssertEqual(try a.loadConfiguration(id).timeZoneIdentifier, "America/New_York", "this Mac's settings stay")
        let kept = a.keptSettings(for: id)
        XCTAssertEqual(kept.map { $0.configuration?.timeZoneIdentifier }, ["Asia/Tokyo"])
        XCTAssertEqual(kept.first?.origin, .otherDevice)
        let firstName = try XCTUnwrap(kept.first?.file)
        let firstFile = a.directory(for: id).appendingPathComponent(firstName)
        let firstBytes = try Data(contentsOf: firstFile)

        // B starts over too, with yet other settings of its own: they go to the server.
        try setTimeZoneWithoutTime(b, id, "Europe/Berlin")
        GenerationStubServer.restore(GenerationStubServer.snapshot())
        try await sync(b)
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "Europe/Berlin")

        // A's second start: its settings stay again, Berlin kept beside — and Tokyo's file as it was.
        let second = try await sync(a)
        XCTAssertTrue(second.startedOver)
        XCTAssertEqual(try a.loadConfiguration(id).timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(Set(a.keptSettings(for: id).compactMap { $0.configuration?.timeZoneIdentifier }), ["Asia/Tokyo", "Europe/Berlin"])
        XCTAssertEqual(try Data(contentsOf: firstFile), firstBytes, "the first version kept is not written over")
    }

    // MARK: Refusals of one object (§16.1)

    /// `507` and `413` are about one object: it waits, and the rest of the run goes on.
    func testAnObjectRefusedForSpaceOrSizeWaitsAndTheRestSyncs() async throws {
        let a = try newVault("A")
        let one = try a.create(name: "One", configuration: ProfileConfiguration()).id
        let two = try a.create(name: "Two", configuration: ProfileConfiguration()).id
        try addBookmark(a, one, "big")
        try addBookmark(a, two, "fine")
        let history = try a.historyStore(for: one, key: a.profileKey(for: one))
        XCTAssertTrue(history.recordVisit(url: URL(string: "https://visited.example/")!, title: "Visited"))
        try history.save()
        let bookmarksOfOne = try objectID(a, "profile/\(one.uuidString)/bookmarks")
        let historyOfOne = try objectID(a, "profile/\(one.uuidString)/history")
        GenerationStubServer.refused = [bookmarksOfOne: 507, historyOfOne: 413]

        let report = try await sync(a)
        XCTAssertEqual(report.deferredOverQuota, ["profile/\(one.uuidString)/bookmarks"])
        XCTAssertEqual(report.deferredTooLarge, ["profile/\(one.uuidString)/history"])
        XCTAssertEqual(report.tooLargeByProfile.map(\.profileID), [one], "the app names the profile")
        XCTAssertEqual(report.tooLargeByProfile.first?.files, ["history.bin"])
        XCTAssertTrue(report.deferred.contains("profile/\(one.uuidString)/bookmarks"))
        XCTAssertTrue(report.pushed.contains("profile/\(two.uuidString)/bookmarks"), "the rest went on: \(report.pushed)")
        XCTAssertTrue(report.pushed.contains("profile/\(two.uuidString)/config"))

        // Room again: it goes up at the next sync.
        GenerationStubServer.refused = [:]
        let next = try await sync(a)
        XCTAssertTrue(next.pushed.contains("profile/\(one.uuidString)/bookmarks"), "\(next.pushed)")
        XCTAssertTrue(next.pushed.contains("profile/\(one.uuidString)/history"), "\(next.pushed)")
        XCTAssertTrue(next.deferredOverQuota.isEmpty)
    }

    /// The camera's image and video are in the profile's settings, which sync as one object, and the
    /// Lumen server takes 16 MiB an object: media within `CameraSubstitution.maxMediaBytes` keep the
    /// settings under it, as the server gets them; more (a video of up to 12 MiB was taken before)
    /// made settings that were refused at every sync. The report names that profile and its settings,
    /// which stay as they are on this Mac.
    func testCameraMediaWithinTheLimitSyncAndSettingsTooLargeAreNamed() async throws {
        GenerationStubServer.maxObjectBytes = 16 << 20
        func media(_ count: Int) -> Data {
            // Compressed media's bytes look random; so do these.
            var generator = SystemRandomNumberGenerator()
            var data = Data(capacity: count + 8)
            while data.count < count {
                var word = generator.next()
                withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
            }
            return data.prefix(count)
        }
        func camera(video: Int) -> CameraSubstitution {
            CameraSubstitution(mode: .substitute, source: .video, deviceSecret: CameraSubstitution.newDeviceSecret(),
                               videoData: media(video), videoType: "video/mp4")
        }
        let a = try newVault("A")
        let fits = try a.create(name: "Fits", configuration: ProfileConfiguration(cameraSubstitution: camera(video: CameraSubstitution.maxMediaBytes))).id
        let large = try a.create(name: "Large", configuration: ProfileConfiguration(cameraSubstitution: camera(video: 7 << 20))).id
        XCTAssertTrue(try a.loadConfiguration(fits).cameraSubstitution.mediaFitsSync)
        XCTAssertFalse(try a.loadConfiguration(large).cameraSubstitution.mediaFitsSync, "what the editor now refuses")
        // An image and a video are kept together: the two count as one.
        var both = try a.loadConfiguration(fits).cameraSubstitution
        both.imageData = media(1 << 20)
        XCTAssertFalse(both.mediaFitsSync)
        // An uncompressed image with long runs of white takes up to twice its size in the settings.
        XCTAssertFalse(CameraSubstitution(mode: .substitute, source: .image, imageData: Data(repeating: 0xFF, count: 4 << 20),
                                          imageType: "image/bmp").mediaFitsSync)

        let report = try await sync(a)
        XCTAssertTrue(report.pushed.contains("profile/\(fits.uuidString)/config"), "\(report.pushed)")
        XCTAssertEqual(report.deferredTooLarge, ["profile/\(large.uuidString)/config"])
        XCTAssertEqual(report.tooLargeByProfile.map(\.profileID), [large])
        XCTAssertEqual(report.tooLargeByProfile.first?.files, ["config.bin"])
        XCTAssertEqual(try a.loadConfiguration(large).cameraSubstitution.videoData?.count, 7 << 20, "kept here as it was")
        let object = try objectID(a, "profile/\(fits.uuidString)/config")
        let size = try XCTUnwrap(GenerationStubServer.blob(vault: a.vault.vaultID, object: object)).count
        XCTAssertLessThan(size, 16 << 20)
        XCTAssertGreaterThan(size, 14 << 20, "about 2.5 times the media, as computed")
    }

    /// The tokens of the synced profiles are read from the state with a generation kept (format 2).
    func testSyncedProfilesAreKnownFromAStateWithAGeneration() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try await sync(a)
        let engine = try SyncEngine(repository: a, transport: transport(a.vault.vaultID))
        let state = try AEAD.open(SecureFile.read(engine.stateURL), key: a.vault.syncEnvelopeKey, aad: engine.stateAAD)
        XCTAssertEqual(DocumentFormat.declared(in: state), 2)
        XCTAssertEqual(SyncEngine.syncedProfileIDs(in: a), [id])
        XCTAssertEqual(SyncProfileToken.tokens(in: a), [try SyncProfileToken.token(for: id, vault: a.vault)])
    }

    /// Changing the place: a folder after the account drops the generation kept, and the state names
    /// the folder; back to the account, the run starts over.
    func testAnotherPlaceDropsTheGenerationAndComingBackStartsOver() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration()).id
        try await sync(a)
        let folder = LocalDirectorySyncTransport(directory: base.appendingPathComponent("folder"))
        let toFolder = try await SyncEngine(repository: a, transport: folder).sync()
        XCTAssertTrue(toFolder.startedOver, "the records were the server's, not the folder's")
        XCTAssertTrue(toFolder.pushed.contains("profile/\(id.uuidString)/config"), "an empty folder gets everything: \(toFolder.pushed)")
        XCTAssertNil(try SyncEngine(repository: a, transport: folder).keptServerGeneration())
        XCTAssertEqual(try SyncEngine(repository: a, transport: folder).keptPlace(),
                       "folder|" + base.appendingPathComponent("folder").standardizedFileURL.path)

        let back = try await sync(a)
        XCTAssertTrue(back.startedOver)
        XCTAssertNotNil(try SyncEngine(repository: a, transport: transport(a.vault.vaultID)).keptServerGeneration())
        let engine = try SyncEngine(repository: a, transport: transport(a.vault.vaultID))
        let state = try AEAD.open(SecureFile.read(engine.stateURL), key: a.vault.syncEnvelopeKey, aad: engine.stateAAD)
        XCTAssertEqual(DocumentFormat.declared(in: state), 2, "with a generation, as the version before places reads it")
    }

    /// Back to a folder used before the account: its copies are older than this Mac's, at higher
    /// revisions than the account's (months of use against a vault the account made anew). The records
    /// were the account's, so the run starts over: nothing here is taken over by the folder's older
    /// copies — the bookmarks and logins merge, the newer settings stay and the folder's are kept beside
    /// them — and the folder ends with this Mac's.
    func testBackToAFolderUsedBeforeTheAccountTakesNoOlderCopy() async throws {
        let a = try newVault("A")
        let id = try a.create(name: "One", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris")).id
        let folder = LocalDirectorySyncTransport(directory: base.appendingPathComponent("nas"))
        func setTimeZone(_ zone: String, step: Double) throws {
            var configuration = try a.loadConfiguration(id)
            configuration.timeZoneIdentifier = zone
            try a.saveConfiguration(configuration.savingEdit(over: a.loadConfiguration(id), at: Date(timeIntervalSince1970: 1_800_000_000 + step)),
                                    for: id)
        }
        func addLogin(_ name: String) throws {
            try a.passwordVault(for: id).upsert(PasswordEntry(origin: "https://\(name).example", username: name, password: "p"))
        }
        func logins() throws -> [String] { try a.passwordVault(for: id).allEntries().map(\.username).sorted() }

        // Months on the folder: every object there changed again and again.
        for (step, zone) in ["Europe/Rome", "Europe/Madrid", "Europe/Berlin"].enumerated() {
            try setTimeZone(zone, step: Double(step))
            try addBookmark(a, id, "folder\(step)")
            try addLogin("folder\(step)")
            _ = try await SyncEngine(repository: a, transport: folder).sync()
        }

        // Then the account: a vault made anew there, its revisions from 1; a change, synced.
        let toAccount = try await sync(a)
        XCTAssertTrue(toAccount.startedOver)
        try setTimeZone("Asia/Tokyo", step: 10)
        try addBookmark(a, id, "account")
        try addLogin("account")
        try await sync(a)
        // Every object the records name is at a higher revision in the folder than on the account.
        let listed = try await folder.listObjects()
        let folderRevisions = Dictionary(listed.map { ($0.objectID, $0.revision) }, uniquingKeysWith: max)
        for file in ["config", "bookmarks", "passwords"] {
            let object = try objectID(a, "profile/\(id.uuidString)/\(file)")
            let onAccount = try XCTUnwrap(GenerationStubServer.snapshot()[a.vault.vaultID.uuidString.lowercased()]?.objects[object]?.revision)
            XCTAssertGreaterThan(try XCTUnwrap(folderRevisions[object]), onAccount, file)
        }

        // Back to the folder.
        let back = try await SyncEngine(repository: a, transport: folder).sync()
        XCTAssertTrue(back.startedOver, "the records were the account's, not the folder's")
        XCTAssertFalse(back.pulled.contains("profile/\(id.uuidString)/config"), "the folder's older settings are not taken: \(back.pulled)")
        XCTAssertEqual(try a.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(a.keptSettings(for: id).compactMap { $0.configuration?.timeZoneIdentifier }, ["Europe/Berlin"],
                       "the folder's settings are kept beside this Mac's")
        XCTAssertEqual(try bookmarks(a, id), ["account", "folder0", "folder1", "folder2"])
        XCTAssertEqual(try logins(), ["account", "folder0", "folder1", "folder2"])

        // The next run there is a plain one.
        let quiet = try await SyncEngine(repository: a, transport: folder).sync()
        XCTAssertFalse(quiet.startedOver)
        XCTAssertEqual(quiet.pulled, [])
        XCTAssertEqual(quiet.pushed, [])

        // The folder holds this Mac's now: a Mac set up from it gets them.
        let vaultB = try await SyncEngine.bootstrap(transport: folder, root: base.appendingPathComponent("B"), password: "pw")
        let b = try ProfileRepository(vault: vaultB)
        _ = try await SyncEngine(repository: b, transport: folder).sync()
        XCTAssertEqual(try b.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(try bookmarks(b, id), ["account", "folder0", "folder1", "folder2"])
        XCTAssertEqual(try b.passwordVault(for: id).allEntries().map(\.username).sorted(), ["account", "folder0", "folder1", "folder2"])
    }
}

