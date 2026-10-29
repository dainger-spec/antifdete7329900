import XCTest
@testable import BrowserCore

final class CookieJarTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// Fixed for the whole test: a cookie made twice must be the same cookie, whenever it is made
    /// (an expiry taken from the clock at each call differs by a second across a second boundary).
    private let nextYear = Date().addingTimeInterval(365 * 86_400).rounded

    private func cookie(_ name: String, _ value: String, domain: String = "site.test", hostOnly: Bool = true,
                        expires: Date?? = .none) -> ImportedCookie {
        ImportedCookie(name: name, value: value, domain: domain, hostOnly: hostOnly, expires: expires ?? nextYear)
    }

    private func entry(_ cookie: ImportedCookie, _ offset: TimeInterval) -> CookieJarDocument.Entry {
        .init(cookie: cookie, updatedAt: t0.addingTimeInterval(offset))
    }

    private func tombstone(_ cookie: ImportedCookie, _ offset: TimeInterval) -> CookieJarDocument.Tombstone {
        .init(key: CookieKey(cookie), deletedAt: t0.addingTimeInterval(offset))
    }

    private func values(_ document: CookieJarDocument) -> [String: String] {
        Dictionary(uniqueKeysWithValues: document.cookies.map { ($0.cookie.name, $0.cookie.value) })
    }

    func testMergeKeepsTheNewerChangePerCookie() {
        let a = CookieJarDocument(cookies: [entry(cookie("x", "a"), 10), entry(cookie("onlyA", "1"), 5)])
        let b = CookieJarDocument(cookies: [entry(cookie("x", "b"), 20), entry(cookie("onlyB", "2"), 5)])
        let merged = CookieJarDocument.merge(a, b, now: t0)
        XCTAssertEqual(values(merged), ["x": "b", "onlyA": "1", "onlyB": "2"])
        XCTAssertEqual(merged, CookieJarDocument.merge(b, a, now: t0), "merge must not depend on which device runs it")
    }

    func testDeletionWinsOnlyWhenNewer() {
        let set = CookieJarDocument(cookies: [entry(cookie("x", "v"), 10)])
        let laterDelete = CookieJarDocument(deleted: [tombstone(cookie("x", "v"), 20)])
        let merged = CookieJarDocument.merge(set, laterDelete, now: t0)
        XCTAssertTrue(merged.cookies.isEmpty)
        XCTAssertEqual(merged.deleted.map(\.key.name), ["x"])

        let setAgain = CookieJarDocument(cookies: [entry(cookie("x", "again"), 30)])
        let revived = CookieJarDocument.merge(merged, setAgain, now: t0)
        XCTAssertEqual(values(revived), ["x": "again"], "a cookie set after its deletion elsewhere comes back")
        XCTAssertTrue(revived.deleted.isEmpty)
    }

    func testSameSecondIsSettledTheSameWayOnBothDevices() {
        let a = CookieJarDocument(cookies: [entry(cookie("x", "aaa"), 10)])
        let b = CookieJarDocument(cookies: [entry(cookie("x", "bbb"), 10)])
        XCTAssertEqual(CookieJarDocument.merge(a, b, now: t0), CookieJarDocument.merge(b, a, now: t0))
        XCTAssertEqual(values(CookieJarDocument.merge(a, b, now: t0)), ["x": "bbb"])

        var secure = cookie("x", "bbb")
        secure.secure = true
        let flags = CookieJarDocument(cookies: [entry(secure, 10)])
        XCTAssertEqual(CookieJarDocument.merge(b, flags, now: t0), CookieJarDocument.merge(flags, b, now: t0),
                       "versions differing only in a flag settle the same way too")

        let deleted = CookieJarDocument(deleted: [tombstone(cookie("x", ""), 10)])
        XCTAssertTrue(CookieJarDocument.merge(a, deleted, now: t0).cookies.isEmpty, "on the same second, the deletion wins")
        XCTAssertEqual(CookieJarDocument.merge(a, deleted, now: t0), CookieJarDocument.merge(deleted, a, now: t0))
    }

    func testHostOnlyAndDomainCookiesAreDifferentCookies() {
        let host = cookie("x", "host", hostOnly: true)
        let domain = cookie("x", "domain", hostOnly: false)
        XCTAssertNotEqual(CookieKey(host), CookieKey(domain))
        let merged = CookieJarDocument.merge(CookieJarDocument(cookies: [entry(host, 1)]),
                                             CookieJarDocument(cookies: [entry(domain, 2)]), now: t0)
        XCTAssertEqual(merged.cookies.count, 2)
    }

    func testPruningDropsExpiredCookiesAndOldTombstones() {
        let now = Date()
        let document = CookieJarDocument(
            cookies: [.init(cookie: cookie("expired", "1", expires: now.addingTimeInterval(-60)), updatedAt: now.addingTimeInterval(-120)),
                      .init(cookie: cookie("live", "1"), updatedAt: now)],
            deleted: [.init(key: CookieKey(name: "old", domain: "site.test", path: "/"),
                            deletedAt: now.addingTimeInterval(-CookieJarDocument.tombstoneLifetime - 60)),
                      .init(key: CookieKey(name: "recent", domain: "site.test", path: "/"), deletedAt: now)])
        let pruned = CookieJarDocument.merge(document, CookieJarDocument(), now: now)
        XCTAssertEqual(pruned.cookies.map(\.cookie.name), ["live"])
        XCTAssertEqual(pruned.deleted.map(\.key.name), ["recent"])
    }

    func testRecordingTakesPersistentChangesSinceTheBaseline() {
        let session = cookie("session", "s", expires: .some(nil))
        let first = CookieJarDocument().recording(store: [cookie("a", "1"), cookie("b", "1"), session], baseline: [],
                                                  at: t0)
        XCTAssertEqual(values(first), ["a": "1", "b": "1"], "session cookies do not sync")
        XCTAssertTrue(first.cookies.allSatisfy { $0.updatedAt == t0 })

        // a changed, b deleted, c added; a store cookie the baseline holds unchanged is no change.
        let baseline = [cookie("a", "1"), cookie("b", "1")]
        let second = first.recording(store: [cookie("a", "2"), cookie("c", "1")], baseline: baseline, at: t0 + 60)
        XCTAssertEqual(values(second), ["a": "2", "c": "1"])
        XCTAssertEqual(second.deleted.map(\.key.name), ["b"])
        XCTAssertEqual(second.deleted.first?.deletedAt, t0 + 60)

        let unchanged = second.recording(store: [cookie("a", "2"), cookie("c", "1")],
                                         baseline: [cookie("a", "2"), cookie("c", "1")], at: t0 + 120)
        XCTAssertEqual(unchanged, second, "nothing changed since the baseline: nothing recorded")
    }

    func testRecordingDoesNotOverwriteANewerChangeFromAnotherDevice() {
        // The document already has the other device's newer value (pulled by sync, not applied yet).
        let document = CookieJarDocument(cookies: [entry(cookie("x", "remote"), 100)],
                                         deleted: [tombstone(cookie("gone", ""), 100)])
        let recorded = document.recording(store: [cookie("x", "local"), cookie("gone", "local")], baseline: [], at: t0 + 50)
        XCTAssertEqual(values(recorded), ["x": "remote"])
        XCTAssertEqual(recorded.deleted.map(\.key.name), ["gone"])

        // A store cookie equal to the document's (it was applied from it) is not this device's change.
        let applied = document.recording(store: [cookie("x", "remote")], baseline: [], at: t0 + 500)
        XCTAssertEqual(applied.cookies.first?.updatedAt, t0 + 100)
    }

    func testAnExpiredCookieLeavingTheStoreIsNoDeletion() {
        let expired = cookie("old", "1", expires: Date().addingTimeInterval(-60))
        let document = CookieJarDocument(cookies: [entry(cookie("live", "1"), 0)])
        let recorded = document.recording(store: [cookie("live", "1")], baseline: [expired, cookie("live", "1")], at: Date())
        XCTAssertTrue(recorded.deleted.isEmpty, "every device's store drops an expired cookie by itself")
    }

    func testChangesSetNewAndDifferentCookiesAndDeleteTombstoned() {
        let document = CookieJarDocument(
            cookies: [entry(cookie("new", "1"), 1), entry(cookie("changed", "2"), 1), entry(cookie("same", "1"), 1),
                      .init(cookie: cookie("expired", "1", expires: Date().addingTimeInterval(-10)), updatedAt: t0)],
            deleted: [tombstone(cookie("gone", ""), 1), tombstone(cookie("notThere", ""), 1)])
        let store = [cookie("changed", "1"), cookie("same", "1"), cookie("gone", "1"), cookie("unknown", "1")]
        let changes = document.changes(over: store)
        XCTAssertEqual(Set(changes.set.map(\.name)), ["new", "changed"])
        XCTAssertEqual(changes.delete.map(\.name), ["gone"], "only cookies the store has; unknown ones are left alone")
    }

    func testCookiesFromBeforeSyncFillInButNeverWin() throws {
        // A store's cookies recorded without a baseline (sync just turned on): as old as can be.
        let synced = CookieJarDocument(cookies: [entry(cookie("x", "synced"), 0)])
        let recorded = synced.recording(store: [cookie("x", "mine"), cookie("y", "mine")], baseline: [], at: CookieBaseline().savedAt)
        XCTAssertEqual(values(recorded), ["x": "synced", "y": "mine"])
        let other = CookieJarDocument(cookies: [entry(cookie("y", "other"), -1_000_000)])
        XCTAssertEqual(values(CookieJarDocument.merge(recorded, other, now: t0)), ["x": "synced", "y": "other"])
        // And it survives the file format (dates as ISO 8601).
        let decoded = try JSONCoding.decoder.decode(CookieJarDocument.self, from: JSONCoding.encoder.encode(recorded))
        XCTAssertEqual(decoded.cookies.first { $0.cookie.name == "y" }?.updatedAt, .distantPast)
        let baseline = try JSONCoding.decoder.decode(CookieBaseline.self, from: JSONCoding.encoder.encode(CookieBaseline()))
        XCTAssertEqual(baseline.savedAt, .distantPast)
    }

    func testExpiryWithinASecondIsTheSameState() {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertTrue(cookie("x", "1", expires: expiry).isSameState(as: cookie("x", "1", expires: expiry.addingTimeInterval(0.4))))
        XCTAssertFalse(cookie("x", "1", expires: expiry).isSameState(as: cookie("x", "1", expires: expiry.addingTimeInterval(5))))
        XCTAssertFalse(cookie("x", "1", expires: expiry).isSameState(as: cookie("x", "1", expires: .some(nil))))
    }
}

final class ProfileSyncTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-profilesync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func twoDevices(_ configuration: ProfileConfiguration = ProfileConfiguration())
        async throws -> (a: ProfileRepository, b: ProfileRepository, transport: LocalDirectorySyncTransport, id: UUID) {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let repoA = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        let id = try repoA.create(name: "Shared", configuration: configuration).id
        _ = try await SyncEngine(repository: repoA, transport: transport).sync()
        let repoB = try ProfileRepository(vault: await SyncEngine.bootstrap(transport: transport, root: base.appendingPathComponent("B"), password: "pw"))
        _ = try await SyncEngine(repository: repoB, transport: transport).sync()
        return (repoA, repoB, transport, id)
    }

    private func sync(_ repository: ProfileRepository, _ transport: SyncTransport) async throws -> SyncReport {
        try await SyncEngine(repository: repository, transport: transport).sync()
    }

    /// Fixed for the whole test, as in `CookieJarTests`: computed at each call, the same cookie made
    /// on two devices on either side of a second boundary had expiries a second apart — a change of
    /// its own, which then won the merge (CI run 398).
    private let expires = Date().addingTimeInterval(30 * 86_400).rounded

    private func cookie(_ name: String, _ value: String) -> ImportedCookie {
        ImportedCookie(name: name, value: value, domain: "site.test", hostOnly: false, expires: expires, secure: true)
    }

    private func record(_ repository: ProfileRepository, _ id: UUID, store: [ImportedCookie], at time: Date) throws {
        let baseline = try repository.cookieBaseline(for: id)
        try repository.saveCookieJar(repository.cookieJar(for: id).recording(store: store, baseline: baseline.cookies, at: time), for: id)
        try repository.saveCookieBaseline(CookieBaseline(cookies: store, savedAt: time), for: id)
    }

    func testCookiesSyncAndConcurrentChangesMerge() async throws {
        let (repoA, repoB, transport, id) = try await twoDevices()
        let name = "profile/\(id.uuidString)/cookies"
        let now = Date().rounded
        try record(repoA, id, store: [cookie("sid", "secret-session-A"), cookie("pref", "dark"), cookie("old", "1")], at: now)
        let pushed = try await sync(repoA, transport)
        XCTAssertEqual(pushed.pushed, [name])

        // The server sees neither cookie names nor values.
        for file in try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("server").path) {
            let blob = try Data(contentsOf: base.appendingPathComponent("server/\(file)"))
            for secret in ["secret-session-A", "site.test", "pref", "cookies"] {
                XCTAssertNil(blob.range(of: Data(secret.utf8)), "\(secret) visible on the server")
            }
        }

        _ = try await sync(repoB, transport)
        XCTAssertEqual(try repoB.cookieJar(for: id), try repoA.cookieJar(for: id))
        XCTAssertNil(try? Data(contentsOf: repoB.cookieBaselineURL(for: id)), "the baseline is this device's, never synced")

        // Concurrent: A changes sid, B changes pref and deletes old.
        try record(repoA, id, store: [cookie("sid", "secret-session-A2"), cookie("pref", "dark"), cookie("old", "1")], at: now + 10)
        let baselineB = try repoB.cookieJar(for: id).liveCookies(at: Date())
        try repoB.saveCookieBaseline(CookieBaseline(cookies: baselineB, savedAt: now), for: id)
        try record(repoB, id, store: [cookie("sid", "secret-session-A"), cookie("pref", "light")], at: now + 20)
        _ = try await sync(repoA, transport)
        let merging = try await sync(repoB, transport)
        XCTAssertEqual(merging.merged, [name])
        XCTAssertTrue(merging.resolvedConflicts.isEmpty)
        _ = try await sync(repoA, transport)

        for repo in [repoA, repoB] {
            let jar = try repo.cookieJar(for: id)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: jar.cookies.map { ($0.cookie.name, $0.cookie.value) }),
                           ["sid": "secret-session-A2", "pref": "light"])
            XCTAssertEqual(jar.deleted.map(\.key.name), ["old"])
        }
        let idle = try await sync(repoB, transport)
        XCTAssertTrue(idle.pushed.isEmpty && idle.pulled.isEmpty)
    }

    func testNewerSettingsWinAndTheOtherIsKeptAsAConflictCopy() async throws {
        let (repoA, repoB, transport, id) = try await twoDevices()
        let configURL = { (repo: ProfileRepository) in repo.directory(for: id).appendingPathComponent("config.bin") }
        let conflictURL = { (repo: ProfileRepository) in configURL(repo).appendingPathExtension("conflict") }
        let now = Date().rounded

        // Remote newer: B edits later than A; A syncs first, B pulls nothing yet — then A syncs.
        var a = try repoA.loadConfiguration(id)
        a.timeZoneIdentifier = "Europe/Paris"
        a.settingsModifiedAt = now
        try repoA.saveConfiguration(a, for: id)
        var b = try repoB.loadConfiguration(id)
        b.timeZoneIdentifier = "Asia/Tokyo"
        b.settingsModifiedAt = now + 60
        try repoB.saveConfiguration(b, for: id)

        _ = try await sync(repoB, transport)
        let reportA = try await sync(repoA, transport)
        XCTAssertEqual(reportA.resolvedConflicts, ["profile/\(id.uuidString)/config"])
        XCTAssertEqual(try repoA.loadConfiguration(id).timeZoneIdentifier, "Asia/Tokyo", "the newer settings win")
        let copyOnA = try AEAD.open(SecureFile.read(conflictURL(repoA)), key: repoA.profileKey(for: id),
                                    aad: ProfileRepository.configAAD(id))
        XCTAssertEqual(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: copyOnA).timeZoneIdentifier, "Europe/Paris")

        // Local newer: A edits later than B; B syncs first, then A keeps its own and copies B's.
        try FileManager.default.removeItem(at: conflictURL(repoA))
        _ = try await sync(repoB, transport)
        a = try repoA.loadConfiguration(id)
        a.timeZoneIdentifier = "America/New_York"
        a.settingsModifiedAt = now + 300
        try repoA.saveConfiguration(a, for: id)
        b = try repoB.loadConfiguration(id)
        b.historyEnabled = false
        b.settingsModifiedAt = now + 200
        try repoB.saveConfiguration(b, for: id)

        _ = try await sync(repoB, transport)
        let localWins = try await sync(repoA, transport)
        XCTAssertEqual(localWins.resolvedConflicts, ["profile/\(id.uuidString)/config"])
        XCTAssertTrue(localWins.pushed.contains("profile/\(id.uuidString)/config"))
        XCTAssertEqual(try repoA.loadConfiguration(id).timeZoneIdentifier, "America/New_York")
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictURL(repoA).path))
        _ = try await sync(repoB, transport)
        XCTAssertEqual(try repoB.loadConfiguration(id).timeZoneIdentifier, "America/New_York")
        XCTAssertTrue(try repoB.loadConfiguration(id).historyEnabled, "B's older edit is in A's conflict copy, not merged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflictURL(repoB).path))
    }

    func testOnlyTheBrowsersOwnStateDifferingIsNoConflict() async throws {
        let (repoA, repoB, transport, id) = try await twoDevices()
        for (repo, country) in [(repoA, "FR"), (repoB, "JP")] {
            var configuration = try repo.loadConfiguration(id)
            configuration.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Paris", countryCode: country,
                                                            proxyEndpoint: "socks5://proxy.test:1080")
            try repo.saveConfiguration(configuration, for: id)
        }
        _ = try await sync(repoA, transport)
        let report = try await sync(repoB, transport)
        XCTAssertTrue(report.resolvedConflicts.isEmpty)
        XCTAssertTrue(report.pulled.contains("profile/\(id.uuidString)/config"))
        XCTAssertEqual(try repoB.loadConfiguration(id).lastProxyLocation?.countryCode, "FR")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoB.directory(for: id).appendingPathComponent("config.bin.conflict").path))
    }

    func testSettingsWithoutTimesFallBackToResolveConflict() async throws {
        let (repoA, repoB, transport, id) = try await twoDevices()
        for (repo, zone) in [(repoA, "Europe/Paris"), (repoB, "Asia/Tokyo")] {
            var configuration = try repo.loadConfiguration(id)
            configuration.timeZoneIdentifier = zone
            configuration.settingsModifiedAt = nil // as an older build writes it
            try repo.saveConfiguration(configuration, for: id)
        }
        _ = try await sync(repoA, transport)
        let report = try await sync(repoB, transport)
        XCTAssertEqual(report.resolvedConflicts, ["profile/\(id.uuidString)/config"])
        XCTAssertEqual(try repoB.loadConfiguration(id).timeZoneIdentifier, "Europe/Paris", "default: keep the remote")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoB.directory(for: id).appendingPathComponent("config.bin.conflict").path))
    }

    func testOlderConfigurationDecodesWithSyncDefaults() throws {
        var json = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(ProfileConfiguration())) as! [String: Any]
        json["syncCookies"] = nil
        json["settingsModifiedAt"] = nil
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.syncCookies)
        XCTAssertNil(decoded.settingsModifiedAt)
        XCTAssertFalse(ProfileConfiguration(ephemeral: true).syncsCookies, "an ephemeral profile never syncs cookies")
    }

    func testTurningCookieSyncOffEmptiesTheSyncedCookiesEverywhere() async throws {
        let (repoA, repoB, transport, id) = try await twoDevices()
        try record(repoA, id, store: [cookie("sid", "1")], at: Date().rounded)
        _ = try await sync(repoA, transport)
        _ = try await sync(repoB, transport)
        XCTAssertEqual(try repoB.cookieJar(for: id).cookies.count, 1)

        var configuration = try repoA.loadConfiguration(id)
        configuration.syncCookies = false
        try repoA.saveConfiguration(configuration.savingEdit(over: repoA.loadConfiguration(id)), for: id)
        try repoA.clearSyncedCookies(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoA.cookieBaselineURL(for: id).path))
        // B ran the profile meanwhile: its own change merges with A's empty document — to nothing.
        try record(repoB, id, store: [cookie("sid", "1"), cookie("b", "2")], at: Date().rounded + 5)
        _ = try await sync(repoA, transport)
        _ = try await sync(repoB, transport)
        _ = try await sync(repoA, transport)
        XCTAssertFalse(try repoB.loadConfiguration(id).syncCookies)
        XCTAssertEqual(try repoA.cookieJar(for: id), CookieJarDocument())
        XCTAssertEqual(try repoB.cookieJar(for: id), CookieJarDocument())
    }

    func testSavingAnEditMovesTheSettingsTimeOnlyWhenASettingChanged() {
        let then = Date(timeIntervalSince1970: 1_800_000_000), now = then + 3_600
        var stored = ProfileConfiguration(timeZoneIdentifier: "Europe/Paris", settingsModifiedAt: then)
        stored.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Paris", countryCode: "FR", proxyEndpoint: "socks5://p:1")
        var editor = ProfileConfiguration(timeZoneIdentifier: "Europe/Paris") // the editor builds a new one
        XCTAssertEqual(editor.savingEdit(over: stored, at: now).settingsModifiedAt, then, "saved unchanged: no newer edit")
        var withExitIP = stored
        withExitIP.lastProxyLocation?.exitIP = "203.0.113.7" // dropped on save while the warning is off
        XCTAssertEqual(editor.savingEdit(over: withExitIP, at: now).settingsModifiedAt, then)
        editor.syncCookies = false
        let saved = editor.savingEdit(over: stored, at: now)
        XCTAssertEqual(saved.settingsModifiedAt, now)
        XCTAssertEqual(saved.lastProxyLocation, stored.lastProxyLocation)
    }

    func testAnEditedVersionBeatsOneNeverEdited() async throws {
        // Created on A (no settings time); B edits, A only stores the proxy location.
        let (repoA, repoB, transport, id) = try await twoDevices()
        XCTAssertNil(try repoA.loadConfiguration(id).settingsModifiedAt)
        var a = try repoA.loadConfiguration(id)
        a.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Paris", countryCode: "FR", proxyEndpoint: "socks5://p:1")
        try repoA.saveConfiguration(a, for: id)
        let storedB = try repoB.loadConfiguration(id)
        var b = storedB
        b.historyEnabled = false
        try repoB.saveConfiguration(b.savingEdit(over: storedB), for: id)
        _ = try await sync(repoB, transport)
        _ = try await sync(repoA, transport)
        XCTAssertFalse(try repoA.loadConfiguration(id).historyEnabled, "the edit wins over a version never edited")
    }
}

private extension Date {
    /// Whole seconds, as the synced documents store dates.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
