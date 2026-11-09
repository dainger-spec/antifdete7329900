import XCTest
@testable import BrowserCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The owner's and the lead's decision of 9 November (the server's question 13): the objects of a
/// deleted profile are written over on the sync location with a small envelope that says so
/// (`SyncPayload.deleted`, no data). Until then they stayed there whole for good — the index only
/// stopped naming the profile — and took the account's room.
final class SyncDeletedProfileTests: XCTestCase {
    var base: URL!
    var session: URLSession!

    /// An envelope that holds no data is some 350 bytes; nothing of a profile's fits in this.
    private let small = 1024

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-syncdeleted-\(UUID().uuidString)")
        StubSyncServer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSyncServer.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: The stub server

    private func http(_ vaultID: UUID) throws -> HTTPSyncTransport {
        try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "https://sync.test/api")!, vaultID: vaultID, bearerToken: "secret-token"),
                              session: session)
    }

    /// What the stub server holds of a vault, by object.
    private func stored(_ vaultID: UUID) -> [String: (revision: Int, blob: Data)] {
        StubSyncServer.lock.lock(); defer { StubSyncServer.lock.unlock() }
        let prefix = vaultID.uuidString.lowercased() + "/"
        var result: [String: (revision: Int, blob: Data)] = [:]
        for (key, value) in StubSyncServer.objects where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    private func bytes(_ vaultID: UUID) -> Int {
        stored(vaultID).values.reduce(0) { $0 + $1.blob.count }
    }

    private func put(_ vaultID: UUID, _ objectID: String, revision: Int, blob: Data) {
        StubSyncServer.lock.lock(); defer { StubSyncServer.lock.unlock() }
        StubSyncServer.objects[vaultID.uuidString.lowercased() + "/" + objectID] = (revision, blob)
    }

    private func requestCount() -> Int {
        StubSyncServer.lock.lock(); defer { StubSyncServer.lock.unlock() }
        return StubSyncServer.requests.count
    }

    /// The objects asked for with `method` since the request numbered `mark`, in order.
    private func objects(_ method: String, since mark: Int) -> [String] {
        StubSyncServer.lock.lock(); defer { StubSyncServer.lock.unlock() }
        return StubSyncServer.requests.dropFirst(mark).compactMap { request -> String? in
            let parts = request.split(separator: " ").map(String.init)
            guard parts.count == 2, parts[0] == method, let last = parts[1].split(separator: "/").last, last != "objects" else { return nil }
            return String(last)
        }
    }

    // MARK: Profiles

    private func repository(_ name: String) throws -> ProfileRepository {
        try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent(name), password: "pw", iterations: 1_000))
    }

    /// A profile with logins enough for its `passwords` object to be many times an empty envelope.
    private func profileWithLogins(_ name: String, in repository: ProfileRepository) throws -> UUID {
        let id = try repository.create(name: name, configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo")).id
        let vault = try repository.passwordVault(for: id)
        for number in 0..<40 {
            try vault.upsert(PasswordEntry(origin: "https://site\(number).test", username: "user\(number)",
                                           password: String(repeating: "p", count: 64)))
        }
        return id
    }

    private func names(of id: UUID) -> [String] {
        ProfileSyncFile.allCases.map { "profile/\(id.uuidString)/\($0.rawValue)" }
    }

    private func name(_ file: ProfileSyncFile, of id: UUID) -> String {
        "profile/\(id.uuidString)/\(file.rawValue)"
    }

    // MARK: The decision's own test

    /// After a profile is deleted and the vault synced, the server holds less — and what it holds
    /// of that profile is small envelopes that say "deleted".
    func testADeletedProfilesObjectsTakeNoRoomOnTheServer() async throws {
        let a = try repository("A")
        let vaultID = a.vault.vaultID
        let codec = try SyncCodec(vault: a.vault)
        let kept = try a.create(name: "Kept", configuration: ProfileConfiguration()).id
        let gone = try profileWithLogins("Gone", in: a)
        let engine = try SyncEngine(repository: a, transport: http(vaultID))
        _ = try await engine.sync()

        let before = stored(vaultID)
        let bytesBefore = bytes(vaultID)
        let goneNames = names(of: gone).filter { before[codec.objectID(for: $0)] != nil }
        XCTAssertEqual(Set(goneNames), [name(.config, of: gone), name(.passwords, of: gone)])
        let passwordsBefore = try XCTUnwrap(before[codec.objectID(for: name(.passwords, of: gone))]).blob.count
        XCTAssertGreaterThan(passwordsBefore, 4 * small, "the test's profile is not big enough to show anything")

        try a.delete(gone)
        let mark = requestCount()
        let report = try await engine.sync()

        XCTAssertEqual(Set(report.retired), Set(goneNames))
        XCTAssertEqual(report.retired.count, goneNames.count)
        XCTAssertTrue(report.pushed.contains("index"))
        XCTAssertTrue(Set(report.pushed).isDisjoint(with: goneNames), "written over, not uploaded: \(report.pushed)")
        XCTAssertTrue(report.deferred.isEmpty)

        let after = stored(vaultID)
        XCTAssertEqual(Set(after.keys), Set(before.keys), "nothing is removed from the server, nothing new appears")
        for name in goneNames {
            let id = codec.objectID(for: name)
            let was = try XCTUnwrap(before[id]), now = try XCTUnwrap(after[id])
            XCTAssertEqual(now.revision, was.revision + 1, name)
            XCTAssertLessThan(now.blob.count, small, name)
            let decoded = try codec.decode(now.blob)
            XCTAssertEqual(decoded.payload.logicalName, name)
            XCTAssertTrue(decoded.payload.deleted, name)
            XCTAssertTrue(decoded.payload.data.isEmpty, name)
        }
        let bytesAfter = bytes(vaultID)
        XCTAssertLessThan(bytesAfter, bytesBefore, "the server holds as much as before the deletion")
        XCTAssertLessThan(bytesAfter, bytesBefore - passwordsBefore + 2 * small,
                          "the deleted profile's logins still take room: \(bytesBefore) → \(bytesAfter) bytes")

        // The profile that stays is as it was.
        for name in names(of: kept) {
            let id = codec.objectID(for: name)
            XCTAssertEqual(after[id]?.revision, before[id]?.revision, name)
            XCTAssertEqual(after[id]?.blob, before[id]?.blob, name)
        }

        // Written before the index, so that a full server has its room back first.
        let written = objects("PUT", since: mark)
        let indexAt = try XCTUnwrap(written.firstIndex(of: codec.objectID(for: "index")))
        for name in goneNames {
            let at = try XCTUnwrap(written.firstIndex(of: codec.objectID(for: name)), name)
            XCTAssertLessThan(at, indexAt, name)
        }

        // Once: the next sync writes nothing, and does not fetch them either.
        let idleMark = requestCount()
        let idle = try await engine.sync()
        XCTAssertTrue(idle.retired.isEmpty && idle.pushed.isEmpty && idle.pulled.isEmpty && idle.deferred.isEmpty)
        XCTAssertEqual(objects("PUT", since: idleMark), [])
        XCTAssertTrue(Set(objects("GET", since: idleMark)).isDisjoint(with: goneNames.map(codec.objectID(for:))))
        XCTAssertEqual(bytes(vaultID), bytesAfter)
    }

    /// The same on a folder (a disk, a NAS).
    func testADeletedProfilesObjectsTakeNoRoomInASharedFolder() async throws {
        let folder = base.appendingPathComponent("server")
        let transport = LocalDirectorySyncTransport(directory: folder)
        let a = try repository("A")
        let codec = try SyncCodec(vault: a.vault)
        let gone = try profileWithLogins("Gone", in: a)
        let engine = try SyncEngine(repository: a, transport: transport)
        _ = try await engine.sync()
        func size() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).reduce(0) {
                $0 + (try Data(contentsOf: folder.appendingPathComponent($1))).count
            }
        }
        let before = try size()

        try a.delete(gone)
        let report = try await engine.sync()
        XCTAssertEqual(Set(report.retired), [name(.config, of: gone), name(.passwords, of: gone)])
        XCTAssertLessThan(try size(), before / 2, "the folder holds as much as before the deletion")
        let fetched = try await transport.fetch(objectID: codec.objectID(for: name(.passwords, of: gone)))
        let blob = try XCTUnwrap(fetched)
        XCTAssertLessThan(blob.count, small)
        XCTAssertTrue(try codec.decode(blob).payload.deleted)

        let idle = try await engine.sync()
        XCTAssertTrue(idle.retired.isEmpty && idle.pushed.isEmpty && idle.pulled.isEmpty)
    }

    // MARK: The other devices

    /// A device that learns of the deletion finds the objects written over already: it writes
    /// nothing, notes them once, and keeps its own folder of the profile as before (R3). A device
    /// set up afterwards takes nothing of the profile.
    func testTheOtherDevicesWriteNothingAndKeepTheirFolder() async throws {
        let a = try repository("A")
        let vaultID = a.vault.vaultID
        let codec = try SyncCodec(vault: a.vault)
        _ = try a.create(name: "Kept", configuration: ProfileConfiguration())
        let gone = try profileWithLogins("Gone", in: a)
        let engineA = try SyncEngine(repository: a, transport: http(vaultID))
        _ = try await engineA.sync()

        let b = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: http(vaultID), root: base.appendingPathComponent("B"), password: "pw"))
        let engineB = try SyncEngine(repository: b, transport: http(vaultID))
        _ = try await engineB.sync()
        XCTAssertEqual(try b.passwordVault(for: gone).allEntries().count, 40)

        try a.delete(gone)
        let deleted = try await engineA.sync()
        let goneObjects = Set(deleted.retired.map(codec.objectID(for:)))
        XCTAssertEqual(goneObjects.count, 2)
        let bytesAfter = bytes(vaultID)

        var mark = requestCount()
        let learned = try await engineB.sync()
        XCTAssertEqual(learned.deletedProfileIDs, [gone])
        XCTAssertTrue(learned.retired.isEmpty, "written over a second time: \(learned.retired)")
        XCTAssertTrue(Set(objects("PUT", since: mark)).isDisjoint(with: goneObjects))
        XCTAssertEqual(b.list().map(\.name), ["Kept"])
        XCTAssertEqual(b.keptDeletedProfiles().map(\.id), [gone], "the folder here is the person's to bring back or remove")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url(of: .passwords, for: gone).path))

        mark = requestCount()
        let idle = try await engineB.sync()
        XCTAssertTrue(idle.retired.isEmpty && idle.pushed.isEmpty && idle.pulled.isEmpty)
        XCTAssertTrue(Set(objects("GET", since: mark)).isDisjoint(with: goneObjects), "noted once, not fetched at every sync")
        XCTAssertEqual(objects("PUT", since: mark), [])

        mark = requestCount()
        let c = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: http(vaultID), root: base.appendingPathComponent("C"), password: "pw"))
        let fresh = try await SyncEngine(repository: c, transport: http(vaultID)).sync()
        XCTAssertTrue(fresh.retired.isEmpty)
        XCTAssertTrue(Set(objects("PUT", since: mark)).isDisjoint(with: goneObjects))
        XCTAssertEqual(c.list().map(\.name), ["Kept"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory(for: gone).path))
        XCTAssertEqual(bytes(vaultID), bytesAfter)
    }

    /// A profile deleted by a version from before this one left its objects whole. Whichever device
    /// syncs next writes them over: one that had them (no fetch needed), or one set up since (it
    /// looks first).
    func testObjectsLeftWholeByAnEarlierDeletionAreWrittenOverByWhoeverSyncsNext() async throws {
        let a = try repository("A")
        let vaultID = a.vault.vaultID
        let codec = try SyncCodec(vault: a.vault)
        let gone = try profileWithLogins("Gone", in: a)
        let engineA = try SyncEngine(repository: a, transport: http(vaultID))
        _ = try await engineA.sync()
        let b = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: http(vaultID), root: base.appendingPathComponent("B"), password: "pw"))
        let engineB = try SyncEngine(repository: b, transport: http(vaultID))
        _ = try await engineB.sync()

        let goneNames = [name(.config, of: gone), name(.passwords, of: gone)]
        let whole = stored(vaultID)
        try a.delete(gone)
        _ = try await engineA.sync()
        /// What the version from before left: the index says deleted, the objects as they were.
        func leaveWhole() throws {
            for name in goneNames {
                let id = codec.objectID(for: name)
                let was = try XCTUnwrap(whole[id])
                put(vaultID, id, revision: was.revision, blob: was.blob)
            }
        }
        try leaveWhole()
        let bytesWhole = bytes(vaultID)

        // B had them at that revision.
        var mark = requestCount()
        let fromB = try await engineB.sync()
        XCTAssertEqual(fromB.deletedProfileIDs, [gone])
        XCTAssertEqual(Set(fromB.retired), Set(goneNames))
        XCTAssertTrue(Set(objects("GET", since: mark)).isDisjoint(with: goneNames.map(codec.objectID(for:))))
        XCTAssertLessThan(bytes(vaultID), bytesWhole / 2)
        XCTAssertEqual(b.keptDeletedProfiles().map(\.id), [gone])

        // A device set up since knows nothing of them: it looks, then writes.
        try leaveWhole()
        mark = requestCount()
        let c = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: http(vaultID), root: base.appendingPathComponent("C"), password: "pw"))
        let fromC = try await SyncEngine(repository: c, transport: http(vaultID)).sync()
        XCTAssertEqual(Set(fromC.retired), Set(goneNames))
        XCTAssertTrue(Set(objects("GET", since: mark)).isSuperset(of: goneNames.map(codec.objectID(for:))))
        XCTAssertLessThan(bytes(vaultID), bytesWhole / 2)
        for name in goneNames {
            let now = try XCTUnwrap(stored(vaultID)[codec.objectID(for: name)])
            XCTAssertTrue(try codec.decode(now.blob).payload.deleted, name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory(for: gone).path), "nothing of it is taken")
    }

    // MARK: What is not written over

    /// An object of the deleted profile that does not open here — damaged, or a newer version's —
    /// is left as it is, and the sync goes on.
    func testAnObjectThatDoesNotOpenIsLeftAsItIs() async throws {
        let a = try repository("A")
        let vaultID = a.vault.vaultID
        let codec = try SyncCodec(vault: a.vault)
        let gone = try profileWithLogins("Gone", in: a)
        let engine = try SyncEngine(repository: a, transport: http(vaultID))
        _ = try await engine.sync()
        let damaged = Data("not an envelope".utf8)
        put(vaultID, codec.objectID(for: name(.passwords, of: gone)), revision: 5, blob: damaged)

        try a.delete(gone)
        let report = try await engine.sync()
        XCTAssertEqual(report.retired, [name(.config, of: gone)])
        XCTAssertTrue(report.pushed.contains("index"))
        let left = try XCTUnwrap(stored(vaultID)[codec.objectID(for: name(.passwords, of: gone))])
        XCTAssertEqual(left.revision, 5)
        XCTAssertEqual(left.blob, damaged)
    }

    /// A write lost to another device's is left for the next sync, as every write.
    func testAWriteLostToAnotherDeviceIsLeftForTheNextSync() async throws {
        let location = MemorySyncLocation()
        let a = try repository("A")
        let codec = try SyncCodec(vault: a.vault)
        let gone = try profileWithLogins("Gone", in: a)
        let engine = try SyncEngine(repository: a, transport: location)
        _ = try await engine.sync()
        let passwords = codec.objectID(for: name(.passwords, of: gone))
        let whole = await location.size(of: passwords)

        try a.delete(gone)
        await location.loseNextWrite(of: passwords)
        let first = try await engine.sync()
        XCTAssertEqual(first.retired, [name(.config, of: gone)])
        XCTAssertEqual(first.deferred, [name(.passwords, of: gone)])
        let stillWhole = await location.size(of: passwords)
        XCTAssertEqual(stillWhole, whole)

        let second = try await engine.sync()
        XCTAssertEqual(second.retired, [name(.passwords, of: gone)])
        XCTAssertTrue(second.deferred.isEmpty)
        let now = await location.size(of: passwords)
        XCTAssertLessThan(now, small)
    }

    // MARK: A full sync location

    /// A sync location with no room left: deleting a profile gives room back in the same sync, and
    /// what else that sync has to write (a new profile, the index) goes through. The location here
    /// refuses any write that makes it hold more than its limit and takes one that makes an object
    /// smaller — what the server said it does for these envelopes; the status it refuses with is
    /// the server's to say, 507 here stands for it.
    func testAFullSyncLocationGetsItsRoomBackBeforeAnythingElseIsWritten() async throws {
        let location = MemorySyncLocation()
        let a = try repository("A")
        let codec = try SyncCodec(vault: a.vault)
        let gone = try profileWithLogins("Gone", in: a)
        let engine = try SyncEngine(repository: a, transport: location)
        _ = try await engine.sync()
        let full = await location.total
        await location.setLimit(full)
        let writtenBefore = await location.written.count

        try a.delete(gone)
        let new = try a.create(name: "New", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Paris")).id
        let report = try await engine.sync()
        XCTAssertEqual(Set(report.retired), [name(.config, of: gone), name(.passwords, of: gone)])
        XCTAssertTrue(report.pushed.contains("index"))
        XCTAssertTrue(report.pushed.contains(name(.config, of: new)))
        let total = await location.total
        XCTAssertLessThan(total, full)

        // Only what this sync wrote: the first one wrote the index too.
        let everyWrite = await location.written
        let written = Array(everyWrite.dropFirst(writtenBefore))
        let indexAt = try XCTUnwrap(written.firstIndex(of: codec.objectID(for: "index")))
        let lastGone = try XCTUnwrap([name(.config, of: gone), name(.passwords, of: gone)]
            .compactMap { written.lastIndex(of: codec.objectID(for: $0)) }.max())
        XCTAssertLessThan(lastGone, indexAt)
        let refused = await location.refused
        XCTAssertEqual(refused, [], "a write was refused for want of room")
    }
}

/// A sync location in memory, for what neither the stub server nor a folder can be made to do:
/// lose one write to "another device", and have no room left.
private actor MemorySyncLocation: SyncTransport {
    private var objects: [String: (revision: Int, blob: Data)] = [:]
    private var losing: Set<String> = []
    private var limit: Int?
    /// The objects written, in order.
    private(set) var written: [String] = []
    /// The objects whose write was refused for want of room.
    private(set) var refused: [String] = []

    var total: Int { objects.values.reduce(0) { $0 + $1.blob.count } }

    func size(of objectID: String) -> Int { objects[objectID]?.blob.count ?? 0 }
    func setLimit(_ limit: Int?) { self.limit = limit }
    func loseNextWrite(of objectID: String) { losing.insert(objectID) }

    func listObjects() async throws -> [RemoteObjectInfo] {
        objects.map { RemoteObjectInfo(objectID: $0.key, revision: $0.value.revision) }
    }

    func fetch(objectID: String) async throws -> Data? { objects[objectID]?.blob }

    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        let current = objects[objectID]
        if losing.remove(objectID) != nil {
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: (current?.revision ?? 0) + 1)
        }
        guard current?.revision == expectedRevision else {
            throw CoreError.syncConflict(objectID: objectID, remoteRevision: current?.revision ?? 0)
        }
        let was = current?.blob.count ?? 0
        if let limit, data.count > was, total - was + data.count > limit {
            refused.append(objectID)
            throw CoreError.syncServer(status: 507, message: "no room")
        }
        objects[objectID] = (revision, data)
        written.append(objectID)
    }
}
