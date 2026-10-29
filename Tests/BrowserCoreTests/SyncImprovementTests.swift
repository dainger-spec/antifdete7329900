import XCTest
@testable import BrowserCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SyncMergeTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-syncmerge-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testBookmarksAndHistoryMergeAcrossDevices() async throws {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let repoA = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let profile = try repoA.create(name: "Shared", configuration: ProfileConfiguration())
        let keyA = try repoA.profileKey(for: profile.id)
        let bookmarksA = try repoA.bookmarkStore(for: profile.id, key: keyA)
        let shared = try bookmarksA.add(title: "Shared", url: URL(string: "https://shared.test/")!)
        let historyA = try repoA.historyStore(for: profile.id, key: keyA)
        historyA.recordVisit(url: URL(string: "https://seen-on-a.test/")!, title: "A")
        try historyA.save()
        let engineA = try SyncEngine(repository: repoA, transport: transport)
        let first = try await engineA.sync()
        XCTAssertTrue(first.pushed.contains("profile/\(profile.id.uuidString)/bookmarks"))
        XCTAssertTrue(first.pushed.contains("profile/\(profile.id.uuidString)/history"))

        let repoB = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: base.appendingPathComponent("B"), password: "pw"))
        let engineB = try SyncEngine(repository: repoB, transport: transport)
        _ = try await engineB.sync()
        let keyB = try repoB.profileKey(for: profile.id)
        XCTAssertEqual(try repoB.bookmarkStore(for: profile.id, key: keyB).all().map(\.title), ["Shared"])

        // Concurrent edits on both devices.
        try repoA.bookmarkStore(for: profile.id, key: keyA).add(title: "Only A", url: URL(string: "https://a.test/")!)
        let historyA2 = try repoA.historyStore(for: profile.id, key: keyA)
        historyA2.recordVisit(url: URL(string: "https://a2.test/")!, title: "A2")
        try historyA2.save()

        let bookmarksB = try repoB.bookmarkStore(for: profile.id, key: keyB)
        try bookmarksB.add(title: "Only B", url: URL(string: "https://b.test/")!)
        try bookmarksB.remove(id: shared.id)
        let historyB = try repoB.historyStore(for: profile.id, key: keyB)
        historyB.recordVisit(url: URL(string: "https://b.test/")!, title: "B")
        try historyB.save()

        _ = try await engineA.sync()
        let mergeReport = try await engineB.sync()
        XCTAssertEqual(Set(mergeReport.merged), ["profile/\(profile.id.uuidString)/bookmarks", "profile/\(profile.id.uuidString)/history"])
        XCTAssertTrue(mergeReport.resolvedConflicts.isEmpty)
        _ = try await engineA.sync()

        for (repo, key) in [(repoA, keyA), (repoB, keyB)] {
            XCTAssertEqual(Set(try repo.bookmarkStore(for: profile.id, key: key).all().map(\.title)), ["Only A", "Only B"],
                           "deleted bookmark must not be resurrected; both additions kept")
            XCTAssertEqual(Set(try repo.historyStore(for: profile.id, key: key).entries().map(\.url)),
                           ["https://seen-on-a.test/", "https://a2.test/", "https://b.test/"])
        }
    }
}

// MARK: - HTTP transport against an in-process stub of docs/SYNC_SERVER_API.md

final class StubSyncServer: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var objects: [String: (revision: Int, blob: Data)] = [:]
    nonisolated(unsafe) static var requiredToken = "secret-token"
    nonisolated(unsafe) static var requests: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        objects = [:]
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, headers, body) = Self.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        requests.append("\(method) \(path)")
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(requiredToken)" else {
            return (401, [:], Data("unauthorized".utf8))
        }
        // [<base path>…] v1 vaults <id> objects [<object>]
        let all = path.split(separator: "/").map(String.init)
        let parts = Array(all.drop { $0 != "v1" })
        guard parts.count >= 4, parts[0] == "v1", parts[1] == "vaults", parts[3] == "objects" else { return (404, [:], Data()) }
        let key = parts[2] + "/" + (parts.count > 4 ? parts[4] : "")
        switch (method, parts.count) {
        case ("GET", 4):
            let list = objects.filter { $0.key.hasPrefix(parts[2] + "/") }
                .map { ["id": String($0.key.split(separator: "/")[1]), "revision": $0.value.revision] as [String: Any] }
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: ["objects": list]))
        case ("GET", 5):
            guard let object = objects[key] else { return (404, [:], Data()) }
            return (200, ["ETag": "\"\(object.revision)\""], object.blob)
        case ("PUT", 5):
            let current = objects[key]?.revision
            if let ifMatch = request.value(forHTTPHeaderField: "If-Match") {
                guard current.map({ "\"\($0)\"" }) == ifMatch else {
                    return (412, current.map { ["ETag": "\"\($0)\""] } ?? [:], Data())
                }
            } else if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                guard current == nil else { return (412, ["ETag": "\"\(current!)\""], Data()) }
            } else {
                return (428, [:], Data("precondition required".utf8))
            }
            guard let revision = request.value(forHTTPHeaderField: HTTPSyncTransport.revisionHeader).flatMap(Int.init),
                  revision > (current ?? 0) else { return (400, [:], Data("bad revision".utf8)) }
            objects[key] = (revision, body(of: request))
            return (current == nil ? 201 : 204, ["ETag": "\"\(revision)\""], Data())
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

final class HTTPSyncTransportTests: XCTestCase {
    var base: URL!
    var session: URLSession!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-httpsync-\(UUID().uuidString)")
        StubSyncServer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSyncServer.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func transport(vaultID: UUID, token: String = "secret-token") throws -> HTTPSyncTransport {
        try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "https://sync.test/api")!, vaultID: vaultID, bearerToken: token),
                              session: session)
    }

    func testRequiresHTTPS() {
        let id = UUID()
        XCTAssertThrowsError(try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "http://sync.test")!, vaultID: id)))
        XCTAssertThrowsError(try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "http://localhost:8080")!, vaultID: id)))
        XCTAssertNoThrow(try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "http://localhost:8080")!, vaultID: id,
                                                                    allowInsecureLocalhost: true)))
        XCTAssertThrowsError(try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "https://u:p@sync.test")!, vaultID: id)))
    }

    func testCompareAndSwapSemantics() async throws {
        let http = try transport(vaultID: UUID())
        let id = String(repeating: "ab", count: 32)
        try await http.store(objectID: id, revision: 1, data: Data("one".utf8), expectedRevision: nil)
        do {
            try await http.store(objectID: id, revision: 1, data: Data("again".utf8), expectedRevision: nil)
            XCTFail("create over existing object must conflict")
        } catch CoreError.syncConflict(_, let remote) {
            XCTAssertEqual(remote, 1)
        }
        try await http.store(objectID: id, revision: 2, data: Data("two".utf8), expectedRevision: 1)
        do {
            try await http.store(objectID: id, revision: 3, data: Data("stale".utf8), expectedRevision: 1)
            XCTFail("stale write must conflict")
        } catch CoreError.syncConflict(_, let remote) {
            XCTAssertEqual(remote, 2)
        }
        let fetched = try await http.fetch(objectID: id)
        XCTAssertEqual(fetched, Data("two".utf8))
        let missing = try await http.fetch(objectID: String(repeating: "cd", count: 32))
        XCTAssertNil(missing)
        let listed = try await http.listObjects()
        XCTAssertEqual(listed, [RemoteObjectInfo(objectID: id, revision: 2)])
    }

    func testBadTokenIsReported() async throws {
        let http = try transport(vaultID: UUID(), token: "wrong")
        do {
            _ = try await http.listObjects()
            XCTFail("expected 401")
        } catch CoreError.syncServer(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    /// The full engine over HTTP: device A publishes, device B bootstraps from the server.
    func testTwoDevicesOverHTTP() async throws {
        let repoA = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let profile = try repoA.create(name: "Over HTTP", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris"))
        let transportA = try transport(vaultID: repoA.vault.vaultID)
        _ = try await SyncEngine(repository: repoA, transport: transportA).sync()
        XCTAssertTrue(StubSyncServer.requests.allSatisfy { $0.contains("/v1/vaults/\(repoA.vault.vaultID.uuidString.lowercased())/objects") })

        let transportB = try transport(vaultID: repoA.vault.vaultID)
        let vaultB = try await SyncEngine.bootstrap(transport: transportB, root: base.appendingPathComponent("B"), password: "pw")
        let repoB = try ProfileRepository(vault: vaultB)
        _ = try await SyncEngine(repository: repoB, transport: transportB).sync()
        XCTAssertEqual(repoB.list().map(\.name), ["Over HTTP"])
        XCTAssertEqual(try repoB.loadConfiguration(profile.id).timeZoneIdentifier, "Europe/Paris")
    }
}

final class DeviceSettingsTests: XCTestCase {
    func testRoundTripEncrypted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertNil(try DeviceSettings.load(from: vault).syncTarget)
        var settings = DeviceSettings()
        settings.syncTarget = .server(baseURL: URL(string: "https://sync.example")!, token: "tok-123")
        // Whole seconds: dates are stored as ISO 8601 without fractional seconds.
        settings.lastSync = .init(date: Date(timeIntervalSince1970: 1_700_000_000), report: SyncReport(pushed: ["index"]))
        try settings.save(to: vault)
        XCTAssertEqual(try DeviceSettings.load(from: MasterVault.unlock(in: root, password: "pw")), settings)
        let raw = try Data(contentsOf: root.appendingPathComponent("settings.bin"))
        XCTAssertNil(raw.range(of: Data("tok-123".utf8)))
        XCTAssertNil(raw.range(of: Data("sync.example".utf8)))
    }
}
