import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BrowserCore

/// A transport the test can stop or fail between two objects: what a lost connection, a quit and the
/// person's Stop are to a restore. It names the place and the generation as the one it reads through.
final class HookedTransport: ServerGenerationTransport, @unchecked Sendable {
    let inner: SyncTransport
    /// Called before each fetch with its number in this transport's life (1, 2, …).
    var beforeFetch: ((Int) throws -> Void)?
    private(set) var fetched: [String] = []

    init(_ inner: SyncTransport) { self.inner = inner }

    var generationScope: String { (inner as? ServerGenerationTransport)?.generationScope ?? "" }
    var serverGeneration: String? { (inner as? ServerGenerationTransport)?.serverGeneration }
    func listObjects() async throws -> [RemoteObjectInfo] { try await inner.listObjects() }
    func fetch(objectID: String) async throws -> Data? {
        try beforeFetch?(fetched.count + 1)
        fetched.append(objectID)
        return try await inner.fetch(objectID: objectID)
    }
    func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        try await inner.store(objectID: objectID, revision: revision, data: data, expectedRevision: expectedRevision)
    }
}

/// `VaultRestore`: a vault kept by the Lumen account (`GenerationStubServer`, the server of CONTRACT
/// §16 in this process), by a folder or by a server of one's own, brought to a Mac that has none —
/// the whole of it, with nothing written at the place, nothing written over here, never half a vault
/// in place, and the next sync going on with that vault.
final class VaultRestoreTests: XCTestCase {
    var base: URL!
    var session: URLSession!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-restore-\(UUID().uuidString)")
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

    private func transport(_ vaultID: UUID) throws -> HTTPSyncTransport {
        try HTTPSyncTransport(configuration: .init(baseURL: URL(string: "https://\(GenerationStubServer.host)")!, vaultID: vaultID,
                                                   bearerToken: GenerationStubServer.token),
                              session: session)
    }

    private func newVault(_ name: String, password: String = "pw") throws -> ProfileRepository {
        try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent(name), password: password, iterations: 1_000))
    }

    private func addBookmark(_ repository: ProfileRepository, _ id: UUID, _ title: String) throws {
        _ = try repository.bookmarkStore(for: id, key: repository.profileKey(for: id)).add(title: title, url: URL(string: "https://\(title).example/")!)
    }

    private func bookmarks(_ repository: ProfileRepository, _ id: UUID) throws -> [String] {
        try repository.bookmarkStore(for: id, key: repository.profileKey(for: id)).all().map(\.title).sorted()
    }

    /// A Mac with two profiles, a bookmark in each, synced to the account's server.
    private func macWithTwoProfiles(_ name: String = "A", password: String = "pw") async throws -> (ProfileRepository, [ProfileSummary]) {
        let mac = try newVault(name, password: password)
        var work = ProfileConfiguration()
        work.timeZoneIdentifier = "Europe/Paris"
        // Made a while apart: the list is in that order, on every Mac of the vault.
        let first = try mac.create(name: "Work", configuration: work, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let second = try mac.create(name: "Shop", configuration: ProfileConfiguration(), createdAt: Date(timeIntervalSince1970: 1_790_000_600))
        try addBookmark(mac, first.id, "one")
        try addBookmark(mac, second.id, "two")
        _ = try await SyncEngine(repository: mac, transport: transport(mac.vault.vaultID)).sync()
        return (mac, [first, second])
    }

    /// When the vault was made, as its header on disk says it (whole seconds, as every copy of it does).
    private func madeAt(_ repository: ProfileRepository) throws -> Date {
        try MasterVault.readHeader(in: repository.root).createdAt
    }

    private func writes() -> Int {
        GenerationStubServer.lock.lock(); defer { GenerationStubServer.lock.unlock() }
        return GenerationStubServer.requests.filter { $0.method == "PUT" }.count
    }

    private func problem(_ work: () async throws -> Void) async -> VaultRestore.Problem? {
        do {
            try await work()
            return nil
        } catch {
            return error as? VaultRestore.Problem
        }
    }

    /// Everything at and below `folder`, by its path from it, with each file's bytes.
    private func contents(of folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let prefix = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return found }
        for case let file as URL in walker {
            guard let data = try? Data(contentsOf: file) else { continue }
            found[String(file.standardizedFileURL.path.dropFirst(prefix.count))] = data
        }
        return found
    }

    // MARK: From the account

    /// A new Mac: the account's vault is opened with its master password, comes down whole, and is
    /// this Mac's vault from then on — the same vault, not another one beside it. Nothing was written
    /// to the server, and the next sync goes on from the restore's records with no start-over.
    func testAVaultComesBackFromTheAccountAndThisMacGoesOnWithIt() async throws {
        let (mac, profiles) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let written = writes()
        let generation = try XCTUnwrap(GenerationStubServer.snapshot()[vaultID.uuidString.lowercased()]?.generation)

        let root = base.appendingPathComponent("New Mac")
        let header = try await VaultRestore.header(at: transport(vaultID), expecting: vaultID)
        XCTAssertEqual(header.createdAt, try madeAt(mac), "what the person is shown of a vault before its password")
        let staged = try VaultRestore.open(header, password: "pw", root: root)
        XCTAssertFalse(staged.continued)
        XCTAssertFalse(MasterVault.exists(in: root), "no vault in place before all of it is here")
        let listed = try await VaultRestore.profiles(of: staged.vault, at: transport(vaultID))
        XCTAssertEqual(listed.map(\.name), ["Work", "Shop"], "the names, before anything is brought")

        let seen = ProgressLog()
        let outcome = try await VaultRestore.download(into: staged.vault, from: transport(vaultID), target: .account) { seen.add($0) }
        XCTAssertEqual(outcome.profiles.map(\.id), profiles.map(\.id))
        XCTAssertTrue(outcome.withoutSettings.isEmpty)
        XCTAssertGreaterThan(outcome.bytes, 0)
        XCTAssertEqual(seen.last?.fraction, 1)
        XCTAssertFalse(MasterVault.exists(in: root), "still none in place: it is moved once all of it is here")

        let vault = try VaultRestore.moveIntoPlace(staged.vault, root: root)
        XCTAssertEqual(vault.root, root)
        XCTAssertTrue(MasterVault.exists(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultRestore.stagingRoot(in: root).path), "the staging went with the move")
        XCTAssertTrue(VaultRestore.unfinished(in: root).isEmpty)
        XCTAssertEqual(writes(), written, "a restore writes nothing to the server")

        // The vault as the app opens it: the same vault, with the profiles and what is in them.
        let reopened = try MasterVault.unlock(in: root, password: "pw")
        XCTAssertEqual(reopened.vaultID, vaultID)
        let here = try ProfileRepository.openedAtUnlock(vault: vault)
        XCTAssertEqual(here.indexState, .read)
        XCTAssertEqual(here.list().map(\.name), ["Work", "Shop"])
        XCTAssertEqual(try here.loadConfiguration(profiles[0].id).timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(try bookmarks(here, profiles[0].id), ["one"])
        XCTAssertEqual(try bookmarks(here, profiles[1].id), ["two"])

        // This Mac goes on with that vault: the place is its sync target, the records are of the
        // server's generation, and the profiles count as synced ones (CONTRACT §6.2).
        let settings = try DeviceSettings.load(from: vault)
        XCTAssertEqual(settings.syncTarget, .account)
        XCTAssertEqual(settings.lastSync?.deferred, 0)
        XCTAssertNil(settings.lastSync?.error)
        let engine = try SyncEngine(repository: here, transport: transport(vaultID))
        XCTAssertEqual(try engine.keptServerGeneration()?.value, generation)
        XCTAssertEqual(try engine.keptPlace(), SyncEngine.serverPlace(try transport(vaultID).generationScope))
        XCTAssertEqual(Set(SyncEngine.syncedProfileIDs(in: here)), Set(profiles.map(\.id)))
        XCTAssertEqual(Set(SyncProfileToken.tokens(in: here)), Set(SyncProfileToken.tokens(in: mac)), "one place of the license's each, on both Macs")

        let next = try await engine.sync()
        XCTAssertFalse(next.startedOver)
        XCTAssertTrue(next.resolvedConflicts.isEmpty)
        XCTAssertTrue(next.merged.isEmpty)
        XCTAssertEqual(GenerationStubServer.snapshot().count, 1, "one vault on the account, not a second beside it")

        // And the two Macs go on together: a change here reaches the first Mac, and its change this one.
        try addBookmark(here, profiles[0].id, "three")
        _ = try await SyncEngine(repository: here, transport: transport(vaultID)).sync()
        try addBookmark(mac, profiles[0].id, "four")
        _ = try await SyncEngine(repository: mac, transport: transport(vaultID)).sync()
        _ = try await SyncEngine(repository: here, transport: transport(vaultID)).sync()
        XCTAssertEqual(try bookmarks(mac, profiles[0].id), ["four", "one", "three"])
        XCTAssertEqual(try bookmarks(here, profiles[0].id), ["four", "one", "three"])
    }

    func testAWrongMasterPasswordLeavesNothingBehind() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let root = base.appendingPathComponent("New Mac")
        let header = try await VaultRestore.header(at: transport(mac.vault.vaultID), expecting: mac.vault.vaultID)
        let written = writes()
        XCTAssertThrowsError(try VaultRestore.open(header, password: "not it", root: root)) { error in
            XCTAssertEqual(error as? VaultRestore.Problem, .wrongPassword)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "nothing was made on this Mac")
        XCTAssertEqual(writes(), written)
        XCTAssertNoThrow(try VaultRestore.open(header, password: "pw", root: root), "and the right one opens it after")
    }

    /// Two vaults on one account: each is told by its own header, opens with its own password, and a
    /// header given under another vault's ID is not believed.
    func testOfTwoVaultsEachComesByItsOwnHeaderAndPassword() async throws {
        let (first, _) = try await macWithTwoProfiles("A", password: "first password")
        let other = try newVault("B", password: "second password")
        let only = try other.create(name: "Other", configuration: ProfileConfiguration())
        _ = try await SyncEngine(repository: other, transport: transport(other.vault.vaultID)).sync()
        XCTAssertEqual(GenerationStubServer.snapshot().count, 2)

        let firstHeader = try await VaultRestore.header(at: transport(first.vault.vaultID), expecting: first.vault.vaultID)
        let otherHeader = try await VaultRestore.header(at: transport(other.vault.vaultID), expecting: other.vault.vaultID)
        XCTAssertEqual(firstHeader.vaultID, first.vault.vaultID)
        XCTAssertEqual(otherHeader.createdAt, try madeAt(other))

        let root = base.appendingPathComponent("New Mac")
        XCTAssertThrowsError(try VaultRestore.open(otherHeader, password: "first password", root: root)) { error in
            XCTAssertEqual(error as? VaultRestore.Problem, .wrongPassword, "the other vault's password does not open this one")
        }
        let staged = try VaultRestore.open(otherHeader, password: "second password", root: root)
        let outcome = try await VaultRestore.download(into: staged.vault, from: transport(other.vault.vaultID), target: .account)
        XCTAssertEqual(outcome.profiles.map(\.id), [only.id])
        let vault = try VaultRestore.moveIntoPlace(staged.vault, root: root)
        XCTAssertEqual(vault.vaultID, other.vault.vaultID)
        XCTAssertEqual(try ProfileRepository(vault: vault).list().map(\.name), ["Other"])

        // The first vault's header served under the other's ID.
        let stolen = try XCTUnwrap(GenerationStubServer.blob(vault: first.vault.vaultID, object: SyncEngine.vaultHeaderObjectID))
        GenerationStubServer.lock.lock()
        GenerationStubServer.vaults[other.vault.vaultID.uuidString.lowercased()]?.objects[SyncEngine.vaultHeaderObjectID] = (9, stolen)
        GenerationStubServer.lock.unlock()
        let refused = await problem { _ = try await VaultRestore.header(at: self.transport(other.vault.vaultID), expecting: other.vault.vaultID) }
        XCTAssertEqual(refused, .notThisVault)
    }

    // MARK: Interrupted, resumed, stopped

    /// The connection lost part-way: no vault is in place, what came is kept, and the same restore
    /// asked again fetches only what is not here yet.
    func testAnInterruptedRestoreLeavesNoVaultAndIsGoneOnWithNotBegunAgain() async throws {
        let (mac, profiles) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        let header = try await VaultRestore.header(at: transport(vaultID), expecting: vaultID)
        let staged = try VaultRestore.open(header, password: "pw", root: root)

        let cut = HookedTransport(try transport(vaultID))
        // The header, the index and the first profile's two files come; the fifth object does not.
        cut.beforeFetch = { number in
            if number > 4 { throw CoreError.io("sync request failed: the network connection was lost") }
        }
        do {
            _ = try await VaultRestore.download(into: staged.vault, from: cut, target: .account)
            XCTFail("the run was cut")
        } catch {
            XCTAssertEqual(error as? CoreError, .io("sync request failed: the network connection was lost"), "said as it came")
        }
        XCTAssertFalse(MasterVault.exists(in: root), "no half vault in place")
        let unfinished = VaultRestore.unfinished(in: root)
        XCTAssertEqual(unfinished.map(\.vaultID), [vaultID])
        XCTAssertEqual(unfinished.first?.createdAt, try madeAt(mac))
        XCTAssertGreaterThan(unfinished.first?.bytes ?? 0, 0)
        // What the first run brought, by object: the header and the index are read by every run.
        let codec = try SyncCodec(vault: mac.vault)
        let everyRun: Set<String> = [SyncEngine.vaultHeaderObjectID, codec.objectID(for: "index")]
        let brought = Set(cut.fetched).subtracting(everyRun)
        XCTAssertFalse(brought.isEmpty)

        // Asked again — as after the app was quit: the vault opened anew, by its header and password.
        let again = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID), expecting: vaultID), password: "pw", root: root)
        XCTAssertTrue(again.continued)
        let resumed = HookedTransport(try transport(vaultID))
        let seen = ProgressLog()
        let outcome = try await VaultRestore.download(into: again.vault, from: resumed, target: .account) { seen.add($0) }
        XCTAssertTrue(brought.isDisjoint(with: resumed.fetched), "what was here is not fetched again: \(brought.intersection(resumed.fetched))")
        XCTAssertGreaterThan(seen.last?.alreadyHere ?? 0, 0)
        XCTAssertEqual(outcome.profiles.map(\.id), profiles.map(\.id))
        let here = try ProfileRepository(vault: VaultRestore.moveIntoPlace(again.vault, root: root))
        XCTAssertEqual(try bookmarks(here, profiles[0].id), ["one"])
        XCTAssertEqual(try bookmarks(here, profiles[1].id), ["two"])
        XCTAssertTrue(VaultRestore.unfinished(in: root).isEmpty)
    }

    func testStoppedByThePersonKeepsWhatCameAndSaysSo() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID)), password: "pw", root: root)
        let hooked = HookedTransport(try transport(vaultID))
        // Stop, as the person presses it: the run's own task is cancelled while its third object comes.
        hooked.beforeFetch = { number in
            if number == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let vault = staged.vault
        let run = Task { try await VaultRestore.download(into: vault, from: hooked, target: .account) }
        let ended = await run.result
        switch ended {
        case .success: XCTFail("the run was stopped")
        case .failure(let error): XCTAssertEqual(error as? VaultRestore.Problem, .stopped)
        }
        XCTAssertLessThan(hooked.fetched.count, 6, "it stopped between two objects, not at the end")
        XCTAssertFalse(MasterVault.exists(in: root))
        XCTAssertEqual(VaultRestore.unfinished(in: root).count, 1)
    }

    /// The master password changed on the other Mac between the two halves of a restore: the second
    /// half opens with the new one, and the vault in place does too.
    func testAPasswordChangedMeanwhileIsTheOneTheVaultOpensWith() async throws {
        let (mac, profiles) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID)), password: "pw", root: root)
        let cut = HookedTransport(try transport(vaultID))
        cut.beforeFetch = { if $0 > 5 { throw CoreError.io("cut") } }
        _ = try? await VaultRestore.download(into: staged.vault, from: cut, target: .account)

        try mac.vault.changePassword(current: "pw", new: "a new one", iterations: 1_000)
        _ = try await SyncEngine(repository: mac, transport: transport(vaultID)).sync()

        let header = try await VaultRestore.header(at: transport(vaultID), expecting: vaultID)
        XCTAssertThrowsError(try VaultRestore.open(header, password: "pw", root: root)) { error in
            XCTAssertEqual(error as? VaultRestore.Problem, .wrongPassword)
        }
        let again = try VaultRestore.open(header, password: "a new one", root: root)
        XCTAssertTrue(again.continued)
        _ = try await VaultRestore.download(into: again.vault, from: transport(vaultID), target: .account)
        _ = try VaultRestore.moveIntoPlace(again.vault, root: root)
        XCTAssertThrowsError(try MasterVault.unlock(in: root, password: "pw"))
        let here = try ProfileRepository(vault: MasterVault.unlock(in: root, password: "a new one"))
        XCTAssertEqual(here.list().map(\.id), profiles.map(\.id))
    }

    /// The move into place cut between two renames — the app quit, the power lost: the next start
    /// finishes it before it looks for a vault, and nothing is moved twice or lost.
    func testAMoveCutShortIsFinishedAtTheNextStart() async throws {
        let (mac, profiles) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID)), password: "pw", root: root)
        _ = try await VaultRestore.download(into: staged.vault, from: transport(vaultID), target: .account)
        XCTAssertFalse(VaultRestore.finishInterruptedMoves(in: root), "a staging without a journal is not moved by itself")
        XCTAssertFalse(MasterVault.exists(in: root))

        // The move as `moveIntoPlace` begins it: the journal, then the first rename — and no more.
        let staging = staged.vault.root
        var names = try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { !$0.hasPrefix(".") && $0 != "vault.json" }.sorted()
        names.append("vault.json")
        XCTAssertTrue(names.contains("index.bin") && names.contains("profiles") && names.contains("settings.bin") && names.contains("sync-state.bin"), "\(names)")
        try SecureFile.write(JSONEncoder().encode(VaultRestore.Journal(names: names)), to: staging.appendingPathComponent(VaultRestore.journalName))
        try FileManager.default.moveItem(at: staging.appendingPathComponent(names[0]), to: root.appendingPathComponent(names[0]))
        XCTAssertFalse(MasterVault.exists(in: root), "cut here, this Mac has no vault: the header moves last")

        XCTAssertTrue(VaultRestore.finishInterruptedMoves(in: root))
        XCTAssertTrue(MasterVault.exists(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultRestore.stagingRoot(in: root).path))
        let here = try ProfileRepository.openedAtUnlock(vault: MasterVault.unlock(in: root, password: "pw"))
        XCTAssertEqual(here.list().map(\.id), profiles.map(\.id))
        XCTAssertEqual(try bookmarks(here, profiles[1].id), ["two"])
        XCTAssertEqual(try DeviceSettings.load(from: here.vault).syncTarget, .account)
        XCTAssertFalse(VaultRestore.finishInterruptedMoves(in: root), "nothing left to finish")
    }

    // MARK: Nothing written over

    func testNothingOfAVaultOnThisMacIsWrittenOver() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let header = try await VaultRestore.header(at: transport(vaultID), expecting: vaultID)

        // A Mac that has a vault.
        let own = try newVault("Has a vault")
        XCTAssertThrowsError(try VaultRestore.open(header, password: "pw", root: own.root)) { error in
            XCTAssertEqual(error as? VaultRestore.Problem, .vaultHere)
        }
        // A vault's files left without their header: named, and kept as they are.
        let leftovers = base.appendingPathComponent("Leftovers")
        try SecureFile.write(Data("an index".utf8), to: leftovers.appendingPathComponent("index.bin"))
        try SecureFile.write(Data("a profile's file".utf8), to: leftovers.appendingPathComponent("profiles/x/config.bin"))
        XCTAssertThrowsError(try VaultRestore.open(header, password: "pw", root: leftovers)) { error in
            XCTAssertEqual(error as? VaultRestore.Problem, .filesInTheWay(["index.bin", "profiles"]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultRestore.stagingRoot(in: leftovers).path))

        // Files that appear while the vault is brought: the move is refused before anything is moved,
        // the staging stays whole, and it goes into place once the way is clear.
        let root = base.appendingPathComponent("New Mac")
        try SecureFile.write(Data("{}".utf8), to: root.appendingPathComponent("account.json"))
        try SecureFile.ensureDirectory(root.appendingPathComponent("profiles"))
        let staged = try VaultRestore.open(header, password: "pw", root: root)
        _ = try await VaultRestore.download(into: staged.vault, from: transport(vaultID), target: .account)
        let stray = root.appendingPathComponent("settings.bin")
        try SecureFile.write(Data("someone's".utf8), to: stray)
        XCTAssertThrowsError(try VaultRestore.moveIntoPlace(staged.vault, root: root)) { error in
            XCTAssertEqual(error as? VaultRestore.Problem, .filesInTheWay(["settings.bin"]))
        }
        XCTAssertEqual(try Data(contentsOf: stray), Data("someone's".utf8))
        XCTAssertFalse(MasterVault.exists(in: root))
        XCTAssertTrue(MasterVault.exists(in: staged.vault.root), "the staging is whole")
        XCTAssertFalse(VaultRestore.finishInterruptedMoves(in: root), "and no move was begun")
        try FileManager.default.moveItem(at: stray, to: base.appendingPathComponent("moved away"))
        let vault = try VaultRestore.moveIntoPlace(staged.vault, root: root)
        XCTAssertEqual(try ProfileRepository(vault: vault).list().count, 2, "an empty profiles folder was in no one's way")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("account.json")), Data("{}".utf8), "what else the folder held is as it was")
    }

    /// The person's Discard: the staging goes, and nothing else — not the place's copy, not what else
    /// the vault's folder holds. One whose move has begun is finished, never discarded.
    func testDiscardTakesTheUnfinishedRestoreAndNothingElse() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        try SecureFile.write(Data("{}".utf8), to: root.appendingPathComponent("account.json"))
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID)), password: "pw", root: root)
        _ = try await VaultRestore.download(into: staged.vault, from: transport(vaultID), target: .account)
        let there = GenerationStubServer.snapshot()[vaultID.uuidString.lowercased()]?.objects.mapValues { $0.blob }

        try SecureFile.write(JSONEncoder().encode(VaultRestore.Journal(names: ["vault.json"])), to: staged.vault.root.appendingPathComponent(VaultRestore.journalName))
        XCTAssertThrowsError(try VaultRestore.discardStagingBecauseThePersonAsked(vaultID, in: root))
        try FileManager.default.removeItem(at: staged.vault.root.appendingPathComponent(VaultRestore.journalName))

        try VaultRestore.discardStagingBecauseThePersonAsked(vaultID, in: root)
        XCTAssertTrue(VaultRestore.unfinished(in: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultRestore.stagingRoot(in: root).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("account.json")), Data("{}".utf8))
        XCTAssertEqual(GenerationStubServer.snapshot()[vaultID.uuidString.lowercased()]?.objects.mapValues { $0.blob }, there)
        XCTAssertNoThrow(try VaultRestore.discardStagingBecauseThePersonAsked(vaultID, in: root), "none there: nothing to do")
    }

    // MARK: What the place does not have, or this version does not read

    func testAVaultWrittenByANewerVersionIsRefusedBeforeAndDuring() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID)), password: "pw", root: root)

        // An index a newer version wrote: met while the vault is brought.
        let codec = try SyncCodec(vault: mac.vault)
        let indexID = codec.objectID(for: "index")
        let revision = try XCTUnwrap(GenerationStubServer.snapshot()[vaultID.uuidString.lowercased()]?.objects[indexID]?.revision)
        let newer = try codec.encode(SyncPayload(logicalName: "index", deleted: false,
                                                 data: Data(#"{"format":2,"entries":[],"deletedProfileIDs":[],"more":true}"#.utf8)),
                                     revision: revision + 1)
        GenerationStubServer.lock.lock()
        GenerationStubServer.vaults[vaultID.uuidString.lowercased()]?.objects[indexID] = (revision + 1, newer)
        GenerationStubServer.lock.unlock()
        let during = await problem { _ = try await VaultRestore.download(into: staged.vault, from: self.transport(vaultID), target: .account) }
        XCTAssertEqual(during, .newerApp(what: "index.bin"))
        let listing = await problem { _ = try await VaultRestore.profiles(of: staged.vault, at: self.transport(vaultID)) }
        XCTAssertEqual(listing, .newerApp(what: "index.bin"))
        XCTAssertFalse(MasterVault.exists(in: root))

        // A header a newer version wrote: refused before the password is asked for.
        var raised = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(mac.vault.header)) as? [String: Any])
        raised["format"] = VaultHeader.currentFormat + 1
        let raisedHeader = try JSONSerialization.data(withJSONObject: raised)
        GenerationStubServer.lock.lock()
        GenerationStubServer.vaults[vaultID.uuidString.lowercased()]?.objects[SyncEngine.vaultHeaderObjectID] = (5, raisedHeader)
        GenerationStubServer.lock.unlock()
        let before = await problem { _ = try await VaultRestore.header(at: self.transport(vaultID), expecting: vaultID) }
        XCTAssertEqual(before, .newerApp(what: "vault.json"))
    }

    func testAPlaceWithNoVaultAndOneThatRefusesAreSaidAsWhatTheyAre() async throws {
        let none = await problem { _ = try await VaultRestore.header(at: self.transport(UUID())) }
        XCTAssertEqual(none, .noVaultThere)

        // The account's refusals come as they are, and read as the states the vault list has.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        GenerationStubServer.holdUntil = date
        do {
            _ = try await VaultRestore.header(at: transport(UUID()))
            XCTFail("a device on hold is refused")
        } catch {
            XCTAssertEqual(AccountVaults.state(of: error), .onHold(until: date))
        }
        GenerationStubServer.holdUntil = nil
        XCTAssertEqual(AccountVaults.state(of: SyncServerRefusal(status: 403, code: "sync_not_in_plan")), .notInPlan)
        XCTAssertEqual(AccountVaults.state(of: SyncServerRefusal(status: 401, code: "unauthorized")), .signedOut)
        XCTAssertEqual(AccountVaults.state(of: SyncServerRefusal(status: 403, code: "account_disabled")), .accountDisabled)
        XCTAssertEqual(AccountVaults.state(of: SyncServerRefusal(status: 429, code: "rate_limited", retryAfter: 15)), .rateLimited(retryAfter: 15))
        XCTAssertEqual(AccountVaults.state(of: SyncServerRefusal(status: 403, code: "forbidden")), .refused(status: 403, code: "forbidden"))
        XCTAssertEqual(AccountVaults.state(of: CoreError.syncServer(status: 401, message: "")), .signedOut)
        XCTAssertNil(AccountVaults.state(of: CoreError.io("offline")))
    }

    /// A profile whose settings never reached the place (the server refused them as too large) is in
    /// the vault's list and has no settings to start with: named, not passed over in silence.
    func testProfilesWhoseSettingsNeverReachedThePlaceAreNamed() async throws {
        let mac = try newVault("A")
        let whole = try mac.create(name: "Whole", configuration: ProfileConfiguration(), createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let large = try mac.create(name: "Large", configuration: ProfileConfiguration(), createdAt: Date(timeIntervalSince1970: 1_790_000_600))
        let codec = try SyncCodec(vault: mac.vault)
        GenerationStubServer.refused[codec.objectID(for: "profile/\(large.id.uuidString)/config")] = 413
        let sent = try await SyncEngine(repository: mac, transport: transport(mac.vault.vaultID)).sync()
        XCTAssertEqual(sent.deferredTooLarge, ["profile/\(large.id.uuidString)/config"])

        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(mac.vault.vaultID)), password: "pw", root: root)
        let outcome = try await VaultRestore.download(into: staged.vault, from: transport(mac.vault.vaultID), target: .account)
        XCTAssertEqual(outcome.profiles.map(\.id), [whole.id, large.id])
        XCTAssertEqual(outcome.withoutSettings.map(\.name), ["Large"])
        let here = try ProfileRepository(vault: VaultRestore.moveIntoPlace(staged.vault, root: root))
        XCTAssertNoThrow(try here.loadConfiguration(whole.id))
        XCTAssertThrowsError(try here.loadConfiguration(large.id))
    }

    /// The account's sync data deleted while the vault is brought: said, with what came kept.
    func testAVaultThatGoesFromThePlaceMeanwhileIsSaid() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID)), password: "pw", root: root)
        GenerationStubServer.deleteAll()
        let written = writes()
        let gone = await problem { _ = try await VaultRestore.download(into: staged.vault, from: self.transport(vaultID), target: .account) }
        XCTAssertEqual(gone, .changedMeanwhile)
        XCTAssertEqual(writes(), written, "and the header was not put back there by the restore")
        XCTAssertTrue(GenerationStubServer.snapshot().isEmpty)
        XCTAssertFalse(MasterVault.exists(in: root))
    }

    // MARK: From a folder, from a server of one's own

    func testAVaultComesBackFromASyncFolderWhichIsLeftAsItWas() async throws {
        let mac = try newVault("A")
        let profile = try mac.create(name: "Folder profile", configuration: ProfileConfiguration())
        try addBookmark(mac, profile.id, "kept")
        let folder = base.appendingPathComponent("NAS/lumen")
        _ = try await SyncEngine(repository: mac, transport: LocalDirectorySyncTransport(directory: folder)).sync()
        let before = contents(of: folder)
        XCTAssertFalse(before.isEmpty)

        let root = base.appendingPathComponent("New Mac")
        let place = LocalDirectorySyncTransport(directory: folder)
        let header = try await VaultRestore.header(at: place)
        XCTAssertEqual(header.vaultID, mac.vault.vaultID, "a folder holds one vault: its header says which")
        XCTAssertNil(VaultRestore.spaceProblem(free: VaultRestore.freeBytes(at: root), known: VaultRestore.bytes(in: folder)))
        let staged = try VaultRestore.open(header, password: "pw", root: root)
        let target = DeviceSettings.SyncTarget.folder(bookmark: Data([1, 2, 3]), path: folder.path)
        let outcome = try await VaultRestore.download(into: staged.vault, from: place, target: target)
        XCTAssertEqual(outcome.profiles.map(\.name), ["Folder profile"])
        let vault = try VaultRestore.moveIntoPlace(staged.vault, root: root)
        XCTAssertEqual(contents(of: folder), before, "the folder is as it was, byte for byte")

        let here = try ProfileRepository.openedAtUnlock(vault: vault)
        XCTAssertEqual(try bookmarks(here, profile.id), ["kept"])
        XCTAssertEqual(try DeviceSettings.load(from: vault).syncTarget, target)
        // The records are the folder's: the next sync with it goes on, and does not start over.
        let engine = try SyncEngine(repository: here, transport: LocalDirectorySyncTransport(directory: folder))
        XCTAssertEqual(try engine.keptPlace(), "folder|" + folder.standardizedFileURL.path)
        XCTAssertNil(try engine.keptServerGeneration())
        let next = try await engine.sync()
        XCTAssertFalse(next.startedOver)
        XCTAssertTrue(next.merged.isEmpty)
        XCTAssertTrue(next.resolvedConflicts.isEmpty)

        // An empty folder holds no vault.
        let empty = base.appendingPathComponent("NAS/empty")
        try SecureFile.ensureDirectory(empty)
        let none = await problem { _ = try await VaultRestore.header(at: LocalDirectorySyncTransport(directory: empty)) }
        XCTAssertEqual(none, .noVaultThere)
    }

    /// A server of one's own keeps no generation and lists no vaults: the vault's ID is typed, and a
    /// wrong one finds nothing.
    func testAVaultComesBackFromAServerOfOnesOwnByItsID() async throws {
        GenerationStubServer.knowsGenerations = false
        let (mac, profiles) = try await macWithTwoProfiles()
        let vaultID = mac.vault.vaultID
        let wrong = await problem { _ = try await VaultRestore.header(at: self.transport(UUID())) }
        XCTAssertEqual(wrong, .noVaultThere)

        let root = base.appendingPathComponent("New Mac")
        let staged = try VaultRestore.open(try await VaultRestore.header(at: transport(vaultID), expecting: vaultID), password: "pw", root: root)
        let target = DeviceSettings.SyncTarget.server(baseURL: URL(string: "https://\(GenerationStubServer.host)")!, token: GenerationStubServer.token)
        _ = try await VaultRestore.download(into: staged.vault, from: transport(vaultID), target: target)
        let vault = try VaultRestore.moveIntoPlace(staged.vault, root: root)
        let here = try ProfileRepository(vault: vault)
        XCTAssertEqual(here.list().map(\.id), profiles.map(\.id))
        XCTAssertEqual(try DeviceSettings.load(from: vault).syncTarget, target)
        let engine = try SyncEngine(repository: here, transport: transport(vaultID))
        XCTAssertNil(try engine.keptServerGeneration(), "a server that names none")
        let next = try await engine.sync()
        XCTAssertFalse(next.startedOver)
    }

    // MARK: Room on the disk, and the transport that writes nothing

    func testRoomOnTheDiskIsAskedForBeforeAndAFullDiskIsSaid() throws {
        let mebibyte: Int64 = 1024 * 1024
        XCTAssertNil(VaultRestore.spaceProblem(free: nil, known: nil), "the system does not say: not refused for it")
        XCTAssertNil(VaultRestore.spaceProblem(free: 1024 * mebibyte, known: 100 * mebibyte))
        XCTAssertEqual(VaultRestore.spaceProblem(free: 10 * mebibyte, known: nil),
                       .notEnoughSpace(free: 10 * mebibyte, needed: VaultRestore.spareBytes))
        XCTAssertEqual(VaultRestore.spaceProblem(free: 120 * mebibyte, known: 100 * mebibyte),
                       .notEnoughSpace(free: 120 * mebibyte, needed: 100 * mebibyte + VaultRestore.spareBytes))
        XCTAssertNil(VaultRestore.spaceProblem(free: 100 * mebibyte + VaultRestore.spareBytes, known: 100 * mebibyte))

        let folder = base.appendingPathComponent("sized")
        try SecureFile.write(Data(count: 1_000), to: folder.appendingPathComponent("a"))
        try SecureFile.write(Data(count: 234), to: folder.appendingPathComponent("deep/b"))
        XCTAssertEqual(VaultRestore.bytes(in: folder), 1_234)
        XCTAssertGreaterThan(try XCTUnwrap(VaultRestore.freeBytes(at: folder.appendingPathComponent("not/made/yet"))), 0)

        // A write that failed with room left is the error it is; what a run knows by name is a state.
        let io = CoreError.io("write config.bin: failed")
        XCTAssertEqual(VaultRestore.translate(io, at: folder) as? CoreError, io)
        XCTAssertEqual(VaultRestore.translate(CancellationError(), at: folder) as? VaultRestore.Problem, .stopped)
        XCTAssertEqual(VaultRestore.translate(CoreError.newerFormat(what: "passwords.bin", found: 9, supported: 3), at: folder) as? VaultRestore.Problem,
                       .newerApp(what: "passwords.bin"))
        XCTAssertEqual(VaultRestore.translate(CoreError.unsupportedFormat("pbsync-3"), at: folder) as? VaultRestore.Problem, .newerApp(what: "pbsync-3"))
        XCTAssertEqual(VaultRestore.translate(VaultRestore.Problem.diskFull, at: folder) as? VaultRestore.Problem, .diskFull)
    }

    /// The transport a restore reads through: every read, no write, the place and the generation of
    /// the one behind it.
    func testTheReadOnlyTransportReadsAndWithholdsEveryWrite() async throws {
        let (mac, _) = try await macWithTwoProfiles()
        let http = try transport(mac.vault.vaultID)
        let readOnly = ReadOnlySyncTransport(http)
        XCTAssertEqual(SyncEngine.place(of: readOnly), SyncEngine.place(of: http))
        let listed = try await readOnly.listObjects()
        XCTAssertEqual(readOnly.counts.listed, listed.count)
        XCTAssertEqual(readOnly.serverGeneration, http.serverGeneration)
        XCTAssertNotNil(readOnly.serverGeneration)
        let header = try await readOnly.fetch(objectID: SyncEngine.vaultHeaderObjectID)
        XCTAssertEqual(readOnly.counts.fetched, 1)
        XCTAssertEqual(readOnly.counts.bytes, Int64(header?.count ?? 0))

        let written = writes()
        let object = String(repeating: "ab", count: 32)
        do {
            try await readOnly.store(objectID: object, revision: 1, data: Data("x".utf8), expectedRevision: nil)
            XCTFail("no write goes through")
        } catch {
            XCTAssertEqual(error as? CoreError, .syncConflict(objectID: object, remoteRevision: 0), "deferred by the engine, as a lost compare-and-swap")
        }
        do {
            try await readOnly.store(objectID: SyncEngine.vaultHeaderObjectID, revision: 2, data: Data("x".utf8), expectedRevision: 1)
            XCTFail("no write goes through")
        } catch {
            XCTAssertEqual(error as? VaultRestore.Problem, .changedMeanwhile)
        }
        XCTAssertEqual(readOnly.withheld, [object, SyncEngine.vaultHeaderObjectID])
        XCTAssertEqual(writes(), written)

        let folder = ReadOnlySyncTransport(LocalDirectorySyncTransport(directory: base.appendingPathComponent("f")))
        XCTAssertEqual(SyncEngine.place(of: folder), "folder|" + base.appendingPathComponent("f").standardizedFileURL.path)
        XCTAssertNil(folder.serverGeneration)
    }
}

/// What a run said of its progress, kept for the test (the callback comes on the run's thread).
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [VaultRestore.Progress] = []

    func add(_ progress: VaultRestore.Progress) {
        lock.lock(); defer { lock.unlock() }
        all.append(progress)
    }

    var last: VaultRestore.Progress? {
        lock.lock(); defer { lock.unlock() }
        return all.last
    }
}
