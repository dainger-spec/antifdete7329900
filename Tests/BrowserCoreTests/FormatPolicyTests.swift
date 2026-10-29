#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// The format rules of the vault's files (docs/UPDATES.md §4): R1, the new reads the old; R2, the
/// old refuses the new and never writes it; R3, no downgrade of the vault; R4, why a tolerant
/// reader needs the format.
///
/// A "newer" file is what a later version would write: the same file under the same key, its JSON
/// declaring `"format": 2` and a field this version does not know.
final class FormatPolicyTests: XCTestCase {
    var root: URL!
    var vault: UnlockedVault!
    var repository: ProfileRepository!
    var id: UUID!
    var key: SymmetricKey!

    let newer = Data(#"{"format": 2, "somethingNew": true}"#.utf8)
    let cookie = ImportedCookie(name: "sid", value: "v", domain: "a.example", hostOnly: true)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-format-\(UUID().uuidString)")
        vault = try MasterVault.create(in: root.appendingPathComponent("vault"), password: "pw", iterations: 1_000)
        repository = try ProfileRepository(vault: vault)
        id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
        key = try repository.profileKey(for: id)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// Writes `json` where `file` keeps its document, sealed as `file` seals it, past every check.
    private func plant<Document: Codable>(_ json: Data, in file: EncryptedDocumentFile<Document>) throws {
        try SecureFile.write(AEAD.seal(json, key: file.key, aad: file.aad), to: XCTUnwrap(file.url))
    }

    /// `body` is refused as a newer version's `what`, and the file at `url` is left as it was.
    private func assertRefused(_ what: String, keeps url: URL, line: UInt = #line, _ body: () throws -> Void) throws {
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try body(), line: line) { error in
            XCTAssertEqual(error as? CoreError, .newerFormat(what: what, found: 2, supported: 1), line: line)
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "\(what) was written over", line: line)
    }

    /// The same for a body that awaits (sync).
    private func assertRefused(_ what: String, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("\(what) of a newer version was not refused", line: line)
        } catch {
            XCTAssertEqual(error as? CoreError, .newerFormat(what: what, found: 2, supported: 1), line: line)
        }
    }

    /// A newer version's `file` is refused when it is read (`read`), saved over (`write`, and the
    /// file's own save of `sample`) and deleted, and left as it was.
    private func assertNewerRefused<Document: Codable>(_ file: EncryptedDocumentFile<Document>, sample: Document, line: UInt = #line,
                                              read: () throws -> Void, write: () throws -> Void = {}) throws {
        try plant(newer, in: file)
        let url = try XCTUnwrap(file.url)
        let what = url.lastPathComponent
        try assertRefused(what, keeps: url, line: line) { try read() }
        try assertRefused(what, keeps: url, line: line) { try write(); try read() }
        try assertRefused(what, keeps: url, line: line) { try file.save(sample) }
        try assertRefused(what, keeps: url, line: line) { try file.remove() }
    }

    /// The JSON of a sealed file of this version, opened with `open`.
    private func json(at url: URL, _ open: (Data) throws -> Data) throws -> Data {
        try open(SecureFile.read(url))
    }

    // MARK: What a file declares

    func testAFileDeclaresItsFormatOrIsFormatOne() throws {
        func declared(_ json: String) -> Int? { DocumentFormat.declared(in: Data(json.utf8)) }
        XCTAssertEqual(declared(#"{}"#), 1, "no key: format 1, as every file this version writes")
        XCTAssertEqual(declared(#"{"format": 1, "entries": []}"#), 1)
        XCTAssertEqual(declared(#"{"format": 3}"#), 3)
        XCTAssertEqual(declared(#"[{"format": 5}]"#), 1, "an array (passwords, queued cookies) is format 1")
        XCTAssertEqual(declared(#"{"format": null}"#), 1)
        XCTAssertNil(declared(#"{"format": "2"}"#), "a format that is not a whole number is not understood")
        XCTAssertNil(declared(#"{"format": 1.5}"#))
        XCTAssertNoThrow(try DocumentFormat.check(Data(#"{"format": 1}"#.utf8), supported: 1, what: "x"))
        XCTAssertThrowsError(try DocumentFormat.check(Data(#"{"format": "2"}"#.utf8), supported: 1, what: "x")) { error in
            XCTAssertEqual(error as? CoreError, .newerFormat(what: "x", found: nil, supported: 1), "not understood: refused")
        }
    }

    // MARK: R1 — the new reads the old

    /// `vault.json` exactly as released versions write it (with the self-test's PBKDF2): it opens with
    /// its password and with no other. Frozen — a change that cannot read it locks every vault out.
    func testAVaultOfReleasedVersionsOpens() throws {
        let released = root.appendingPathComponent("released")
        try FileManager.default.createDirectory(at: released, withIntermediateDirectories: true)
        try Data(Self.releasedVaultHeader.utf8).write(to: MasterVault.headerURL(in: released))
        XCTAssertEqual(try MasterVault.unlock(in: released, password: "fixture").vaultID,
                       UUID(uuidString: "DA098616-5027-4002-9356-FB3C2C04BC30"))
        XCTAssertThrowsError(try MasterVault.unlock(in: released, password: "other")) { error in
            XCTAssertEqual(error as? CoreError, .wrongPassword)
        }
    }

    /// A profile's settings exactly as released versions write them (no `format`): read, values kept.
    func testSettingsOfReleasedVersionsRead() throws {
        let configuration = try ProfileRepository.decodeConfiguration(Data(Self.releasedConfiguration.utf8))
        XCTAssertEqual(configuration.startURL, URL(string: "https://example.org/"))
        XCTAssertEqual(configuration.proxy?.host, "203.0.113.5")
        XCTAssertEqual(configuration.proxy?.port, 1080)
        XCTAssertEqual(configuration.proxy?.username, "u")
        XCTAssertEqual(configuration.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(configuration.webRTCPolicy, .disabled)
    }

    /// This version writes the files that never had a format marker as before — no `format`, so
    /// nothing changes for the versions before it — and the ones that had one with format 1; all
    /// read back.
    func testThisVersionWritesItsFilesAsBefore() async throws {
        try repository.saveConfiguration(ProfileConfiguration(), for: id)
        try repository.passwordVault(for: id).upsert(PasswordEntry(origin: "https://a.example", username: "u", password: "p"))
        try repository.saveWarmUpPlan(WarmUpPlan(addresses: "https://a.example/"), for: id)
        try repository.saveWarmUpSchedule(WarmUpSchedule(everyHours: 6), for: id)
        try repository.saveCookieBaseline(CookieBaseline(cookies: [cookie]), for: id)
        try repository.queueImportedCookies([cookie], for: id)
        try DeviceSettings().save(to: vault)
        let engine = try SyncEngine(repository: repository, transport: LocalDirectorySyncTransport(directory: root.appendingPathComponent("server")))
        _ = try await engine.sync()

        let unmarked: [(String, Data)] = [
            ("config.bin", try json(at: repository.configURL(for: id)) { try AEAD.open($0, key: key, aad: ProfileRepository.configAAD(id)) }),
            ("passwords.bin", try json(at: repository.passwordsURL(for: id)) { try PasswordVault.open($0, profileID: id, profileKey: key) }),
            ("warmup.bin", try json(at: repository.warmUpPlanURL(for: id)) { try repository.warmUpPlanFile(for: id).open($0) }),
            ("warmup-schedule.bin", try json(at: repository.warmUpScheduleURL(for: id)) { try repository.warmUpScheduleFile(for: id).open($0) }),
            ("cookies-baseline.bin", try json(at: repository.cookieBaselineURL(for: id)) { try repository.cookieBaselineFile(for: id).open($0) }),
            ("cookies-import.bin", try json(at: repository.importedCookiesURL(for: id)) { try repository.importedCookiesFile(for: id).open($0) }),
            ("settings.bin", try json(at: vault.root.appendingPathComponent("settings.bin")) { try DeviceSettings.file(for: vault).open($0) }),
            ("sync-state.bin", try json(at: engine.stateURL) { try AEAD.open($0, key: vault.syncEnvelopeKey, aad: engine.stateAAD) }),
        ]
        for (name, data) in unmarked {
            XCTAssertNil((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"], "\(name) has a format now")
            XCTAssertEqual(DocumentFormat.declared(in: data), 1, name)
        }
        try repository.saveCookieJar(CookieJarDocument(), for: id)
        try ProxyList().save(to: vault)
        let history = try repository.historyStore(for: id, key: key)
        XCTAssertTrue(history.recordVisit(url: URL(string: "https://a.example/")!, title: "A"))
        try history.save()
        _ = try repository.bookmarkStore(for: id, key: key).add(title: "B", url: URL(string: "https://b.example/")!)
        let marked: [(String, Data)] = [
            ("index.bin", try json(at: repository.indexURL) { try AEAD.open($0, key: vault.indexKey, aad: repository.indexAAD) }),
            ("cookies.bin", try json(at: repository.cookieJarURL(for: id)) {
                try ProfileRepository.cookieJarFile(url: nil, profileID: id, profileKey: key).open($0)
            }),
            ("proxies.bin", try json(at: vault.root.appendingPathComponent("proxies.bin")) { try ProxyList.file(for: vault).open($0) }),
            ("history.bin", try json(at: repository.historyURL(for: id)) { try HistoryStore.file(url: nil, profileID: id, profileKey: key).open($0) }),
            ("bookmarks.bin", try json(at: repository.bookmarksURL(for: id)) { try BookmarkStore.file(url: nil, profileID: id, profileKey: key).open($0) }),
        ]
        for (name, data) in marked {
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? Int, 1, name)
        }

        XCTAssertNoThrow(try repository.loadConfiguration(id, key: key))
        XCTAssertEqual(try repository.passwordVault(for: id).allEntries().map(\.username), ["u"])
        XCTAssertEqual(try repository.warmUpPlan(for: id)?.addresses, "https://a.example/")
        XCTAssertEqual(try repository.warmUpSchedule(for: id)?.everyHours, 6)
        XCTAssertEqual(try repository.cookieBaseline(for: id).cookies, [cookie])
        XCTAssertEqual(try repository.importedCookiesForLaunch(id), [cookie])
        XCTAssertNoThrow(try DeviceSettings.load(from: vault))
        XCTAssertEqual(try repository.bookmarkStore(for: id, key: key).all().map(\.title), ["B"])
        XCTAssertNoThrow(try ProfileRepository(vault: vault))
        _ = try await engine.sync()
    }

    // MARK: R2 — the old refuses the new, and never writes it

    /// A newer version's vault: not unlocked, not opened for a profile's process, and its header is
    /// not written over by a password change in a vault that was open before it landed.
    func testAVaultOfANewerVersion() throws {
        let grant = try repository.grant(for: id)
        let header = MasterVault.headerURL(in: vault.root)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: header)) as? [String: Any])
        json["format"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: header)
        try assertRefused("vault.json", keeps: header) { _ = try MasterVault.unlock(in: vault.root, password: "pw") }
        try assertRefused("vault.json", keeps: header) { _ = try MasterVault.readHeader(in: vault.root) }
        try assertRefused("vault.json", keeps: header) { _ = try MasterVault.open(in: vault.root, grant: grant) }
        try assertRefused("vault.json", keeps: header) { try vault.changePassword(current: "pw", new: "new pw", iterations: 1_000) }
    }

    func testTheIndexOfANewerVersion() throws {
        let url = repository.indexURL
        try SecureFile.write(AEAD.seal(newer, key: vault.indexKey, aad: repository.indexAAD), to: url)
        try assertRefused("index.bin", keeps: url) { _ = try ProfileRepository(vault: vault) }
        // A repository open since before: its next change does not write over it.
        try assertRefused("index.bin", keeps: url) { try repository.rename(id, to: "Renamed") }
        var incoming = repository.currentIndex()
        incoming.format = 2
        try assertRefused("index.bin", keeps: url) { try repository.replaceIndex(incoming) }
    }

    func testSettingsOfANewerVersion() throws {
        let url = repository.configURL(for: id)
        try SecureFile.write(AEAD.seal(newer, key: key, aad: ProfileRepository.configAAD(id)), to: url)
        try assertRefused("config.bin", keeps: url) { _ = try repository.loadConfiguration(id, key: key) }
        try assertRefused("config.bin", keeps: url) { _ = try repository.loadConfiguration(id) }
        try assertRefused("config.bin", keeps: url) { try repository.saveConfiguration(ProfileConfiguration(), for: id) }
    }

    /// R4: the settings' decoder takes what it knows from any JSON and defaults the rest, so a newer
    /// version's settings would be read as this version's — and written back without what that
    /// version added. The format is what stops it.
    func testATolerantReaderIsWhyTheFormatIsChecked() {
        XCTAssertNoThrow(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: newer))
        XCTAssertThrowsError(try ProfileRepository.decodeConfiguration(newer))
    }

    func testPasswordsOfANewerVersion() throws {
        let url = repository.passwordsURL(for: id)
        let openBefore = try repository.passwordVault(for: id)
        try SecureFile.write(AEAD.seal(newer, key: PasswordVault.fileKey(profileID: id, profileKey: key),
                                       aad: PasswordVault.aad(profileID: id)), to: url)
        try assertRefused("passwords.bin", keeps: url) { _ = try repository.passwordVault(for: id) }
        try assertRefused("passwords.bin", keeps: url) {
            try openBefore.upsert(PasswordEntry(origin: "https://a.example", username: "u", password: "p"))
        }
    }

    func testHistoryAndBookmarksOfANewerVersion() throws {
        try assertNewerRefused(HistoryStore.file(url: repository.historyURL(for: id), profileID: id, profileKey: key),
                               sample: HistoryDocument(), read: { _ = try repository.historyStore(for: id, key: key) })
        try assertNewerRefused(BookmarkStore.file(url: repository.bookmarksURL(for: id), profileID: id, profileKey: key),
                               sample: BookmarkDocument(), read: { _ = try repository.bookmarkStore(for: id, key: key) })
    }

    func testCookieFilesOfANewerVersion() throws {
        try assertNewerRefused(ProfileRepository.cookieJarFile(url: repository.cookieJarURL(for: id), profileID: id, profileKey: key),
                               sample: CookieJarDocument(), read: { _ = try repository.cookieJar(for: id) },
                               write: { try repository.saveCookieJar(CookieJarDocument(), for: id) })
        // Cookie sync turned off empties the synced jar — not a newer version's.
        try assertRefused("cookies.bin", keeps: repository.cookieJarURL(for: id)) { try repository.clearSyncedCookies(for: id) }

        try assertNewerRefused(repository.cookieBaselineFile(for: id), sample: CookieBaseline(),
                               read: { _ = try repository.cookieBaseline(for: id) },
                               write: { try repository.saveCookieBaseline(CookieBaseline(), for: id) })
        // ... and deletes this device's baseline — not a newer version's either.
        try assertRefused("cookies-baseline.bin", keeps: repository.cookieBaselineURL(for: id)) { try repository.clearSyncedCookies(for: id) }

        try assertNewerRefused(repository.importedCookiesFile(for: id), sample: [cookie],
                               read: { _ = try repository.importedCookiesForLaunch(id) },
                               write: { try repository.queueImportedCookies([cookie], for: id) })
        // The queue is dropped after a launch, or when it cannot be read: not a newer version's.
        let queue = repository.importedCookiesURL(for: id)
        let before = try Data(contentsOf: queue)
        repository.clearImportedCookies(id)
        XCTAssertEqual(try Data(contentsOf: queue), before)
        // A queue of this version still goes.
        try FileManager.default.removeItem(at: queue)
        try repository.queueImportedCookies([cookie], for: id)
        repository.clearImportedCookies(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
    }

    func testWarmUpFilesOfANewerVersion() throws {
        try assertNewerRefused(repository.warmUpPlanFile(for: id), sample: WarmUpPlan(),
                               read: { _ = try repository.warmUpPlan(for: id) },
                               write: { try repository.saveWarmUpPlan(WarmUpPlan(), for: id) })
        try assertNewerRefused(repository.warmUpScheduleFile(for: id), sample: WarmUpSchedule(),
                               read: { _ = try repository.warmUpSchedule(for: id) },
                               write: { try repository.saveWarmUpSchedule(WarmUpSchedule(), for: id) })
    }

    func testProxiesAndDeviceSettingsOfANewerVersion() throws {
        try assertNewerRefused(ProxyList.file(for: vault), sample: ProxyList(),
                               read: { _ = try ProxyList.load(from: vault) }, write: { try ProxyList().save(to: vault) })
        try assertNewerRefused(DeviceSettings.file(for: vault), sample: DeviceSettings(),
                               read: { _ = try DeviceSettings.load(from: vault) }, write: { try DeviceSettings().save(to: vault) })
    }

    /// A newer version's website-data or Safari archive: nothing is restored from it, and nothing is
    /// sealed over it — while an archive of this version is replaced as before.
    func testArchivesOfANewerVersion() throws {
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("cookies".utf8).write(to: data.appendingPathComponent("Cookies.binarycookies"))
        for archive in [repository.webDataArchiveURL(for: id), repository.safariHomeArchiveURL(for: id)] {
            try EncryptedDirectoryArchive.seal(roots: ["store": data], to: archive, key: key)
            var bytes = try Data(contentsOf: archive)
            XCTAssertEqual(bytes.prefix(5), Data("PBSA".utf8) + [1], "magic, then the version")
            bytes[4] = 2
            try bytes.write(to: archive)
            let what = archive.lastPathComponent
            let restored = root.appendingPathComponent("restored-\(what)")
            try assertRefused(what, keeps: archive) {
                try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["store": restored])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
            try assertRefused(what, keeps: archive) { _ = try EncryptedDirectoryArchive.labels(in: archive, key: key) }
            try assertRefused(what, keeps: archive) { try EncryptedDirectoryArchive.seal(roots: ["store": data], to: archive, key: key) }
            bytes[4] = 1
            try bytes.write(to: archive)
            XCTAssertNoThrow(try EncryptedDirectoryArchive.seal(roots: ["store": data], to: archive, key: key))
        }
    }

    func testAProfileExportOfANewerVersion() throws {
        let file = root.appendingPathComponent("Newer.pbprofile")
        try ProfileTransfer.export(id, from: repository, to: file, password: "pw", kdf: KDFParameters.generate(iterations: 1_000))
        // magic | header length u32 | header JSON | the rest
        let bytes = try Data(contentsOf: file)
        let start = ProfileTransfer.magic.count
        let length = bytes[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes[start + 4..<start + 4 + length])) as? [String: Any])
        XCTAssertEqual(header["format"] as? Int, 1)
        header["format"] = 2
        let patched = try JSONSerialization.data(withJSONObject: header)
        var rewritten = Data(bytes.prefix(start))
        withUnsafeBytes(of: UInt32(patched.count).bigEndian) { rewritten.append(contentsOf: $0) }
        rewritten.append(patched)
        rewritten.append(bytes[(start + 4 + length)...])
        try rewritten.write(to: file)

        let profiles = repository.list().count
        try assertRefused("Newer.pbprofile", keeps: file) { _ = try ProfileTransfer.manifest(of: file, password: "pw") }
        try assertRefused("Newer.pbprofile", keeps: file) { _ = try ProfileTransfer.importProfile(from: file, password: "pw", into: repository) }
        XCTAssertEqual(repository.list().count, profiles)
    }

    // MARK: Sync

    /// Two devices on one sync location; `a` stands for the newer version.
    private func twoDevices() async throws -> (a: SyncEngine, b: SyncEngine, repositoryB: ProfileRepository, transport: LocalDirectorySyncTransport) {
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let a = try SyncEngine(repository: repository, transport: transport)
        _ = try await a.sync()
        let repositoryB = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: root.appendingPathComponent("b"),
                                                                                   password: "pw"))
        let b = try SyncEngine(repository: repositoryB, transport: transport)
        _ = try await b.sync()
        return (a, b, repositoryB, transport)
    }

    /// What the sync location holds: each object's revision and bytes.
    private func snapshot(_ transport: LocalDirectorySyncTransport) async throws -> [String: Data] {
        var objects: [String: Data] = [:]
        for object in try await transport.listObjects() {
            objects["\(object.objectID)@\(object.revision)"] = try await transport.fetch(objectID: object.objectID)
        }
        return objects
    }

    /// The vault on the sync location is a newer version's: this version neither syncs with it nor
    /// sets up a new device from it, and writes nothing on either side.
    func testASyncLocationWithANewerVault() async throws {
        let (a, _, _, transport) = try await twoDevices()
        let remote = try await transport.listObjects().first { $0.objectID == SyncEngine.vaultHeaderObjectID }
        let blob = try await transport.fetch(objectID: SyncEngine.vaultHeaderObjectID)
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(blob)) as? [String: Any])
        header["format"] = 2
        try await transport.store(objectID: SyncEngine.vaultHeaderObjectID, revision: XCTUnwrap(remote).revision + 1,
                                  data: JSONSerialization.data(withJSONObject: header), expectedRevision: remote?.revision)
        let server = try await snapshot(transport)
        let index = try Data(contentsOf: repository.indexURL)

        await assertRefused("vault.json") { _ = try await a.sync() }
        await assertRefused("vault.json") { try await a.publishVaultHeader() }
        let third = root.appendingPathComponent("c")
        await assertRefused("vault.json") { _ = try await SyncEngine.bootstrap(transport: transport, root: third, password: "pw") }
        XCTAssertFalse(MasterVault.exists(in: third))
        let after = try await snapshot(transport)
        XCTAssertEqual(after, server)
        XCTAssertEqual(try Data(contentsOf: repository.indexURL), index)
    }

    /// A newer version's file on the sync location: not pulled, not merged, and this device's own
    /// copy is not pushed over it.
    func testANewerFileOnTheSyncLocation() async throws {
        let (a, b, repositoryB, transport) = try await twoDevices()
        let keyB = try repositoryB.profileKey(for: id)
        _ = try repositoryB.bookmarkStore(for: id, key: keyB).add(title: "Only B", url: URL(string: "https://b.example/")!)
        let bookmarksB = repositoryB.bookmarksURL(for: id)
        let mineB = try Data(contentsOf: bookmarksB)

        // The newer version writes its bookmarks on `a`, and syncs them.
        try plant(newer, in: BookmarkStore.file(url: repository.bookmarksURL(for: id), profileID: id, profileKey: key))
        _ = try await a.sync()
        let server = try await snapshot(transport)

        await assertRefused("bookmarks.bin") { _ = try await b.sync() }
        XCTAssertEqual(try Data(contentsOf: bookmarksB), mineB, "merged into this device's bookmarks")
        let after = try await snapshot(transport)
        XCTAssertEqual(after, server, "this device's bookmarks pushed over the newer ones")

        // A device that has none yet does not take them either.
        try FileManager.default.removeItem(at: bookmarksB)
        let stateB = try SyncEngine(repository: repositoryB, transport: transport)
        await assertRefused("bookmarks.bin") { _ = try await stateB.sync() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookmarksB.path))
    }

    /// A newer version's profile list on the sync location is not merged into this device's.
    func testANewerIndexOnTheSyncLocation() async throws {
        let (_, b, repositoryB, transport) = try await twoDevices()
        let codec = try SyncCodec(vault: vault)
        let objectID = codec.objectID(for: "index")
        let objects = try await transport.listObjects()
        let revision = try XCTUnwrap(objects.first { $0.objectID == objectID }).revision
        try await transport.store(objectID: objectID, revision: revision + 1,
                                  data: codec.encode(SyncPayload(logicalName: "index", deleted: false, data: newer), revision: revision + 1),
                                  expectedRevision: revision)
        let indexB = try Data(contentsOf: repositoryB.indexURL)
        await assertRefused("index.bin") { _ = try await b.sync() }
        XCTAssertEqual(try Data(contentsOf: repositoryB.indexURL), indexB)
    }

    /// What sync last saw, written by a newer version: the sync stops before it fetches or pushes
    /// anything (starting over from nothing would push this device's files over newer ones).
    func testSyncStateOfANewerVersion() async throws {
        let transport = LocalDirectorySyncTransport(directory: root.appendingPathComponent("server"))
        let engine = try SyncEngine(repository: repository, transport: transport)
        try SecureFile.write(AEAD.seal(newer, key: vault.syncEnvelopeKey, aad: engine.stateAAD), to: engine.stateURL)
        let state = try Data(contentsOf: engine.stateURL)
        await assertRefused("sync-state.bin") { _ = try await engine.sync() }
        let objects = try await transport.listObjects()
        XCTAssertTrue(objects.isEmpty)
        XCTAssertEqual(try Data(contentsOf: engine.stateURL), state)
    }

    // MARK: Fixtures — exactly as released versions write these files; never regenerate them

    static let releasedVaultHeader = #"""
        {"createdAt":"2026-10-29T23:30:01Z","format":1,"kdf":{"algorithm":"pbkdf2-hmac-sha256","iterations":1000,"salt":"jo1o9O23Hz\/00RNAaFwfRw=="},"vaultID":"DA098616-5027-4002-9356-FB3C2C04BC30","wrappedMasterKey":"GPB5Vczv0d2xJHeRjvbSDLAo9LF3WkVDpzPgNWbtZUficSDONUzjxffhxFOqhuD3n1PIY0Lps2c\/63\/U"}
        """#

    static let releasedConfiguration = #"""
        {"ephemeral":false,"geolocation":{"deny":{}},"historyEnabled":true,"historyRetentionDays":90,"matchProxyLocation":true,"passwordAutoFill":true,"passwordNeverSaveSites":[],"proxy":{"excludedDomains":[],"host":"203.0.113.5","kind":"socks5","password":"p","port":1080,"tlsToProxy":false,"username":"u"},"safeBrowsingEnabled":false,"startURL":"https:\/\/example.org\/","syncCookies":true,"timeZoneIdentifier":"Europe\/Berlin","warnOnProxyIPChange":false,"webRTCPolicy":"disabled"}
        """#
}
