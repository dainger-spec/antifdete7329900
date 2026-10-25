import XCTest
@testable import BrowserCore

final class HistoryStoreTests: XCTestCase {
    var root: URL!
    var repo: ProfileRepository!
    var profile: ProfileSummary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-history-\(UUID().uuidString)")
        repo = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        profile = try repo.create(name: "P", configuration: ProfileConfiguration())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(policy: HistoryStore.Policy = .init(), persistent: Bool = true) throws -> HistoryStore {
        try repo.historyStore(for: profile.id, key: repo.profileKey(for: profile.id), policy: policy, persistent: persistent)
    }

    func testRecordCoalesceSearchAndPersist() throws {
        let history = try store()
        XCTAssertTrue(history.recordVisit(url: URL(string: "https://user:secret@Example.com/a#section")!, title: "Example A"))
        history.recordVisit(url: URL(string: "https://example.com/a")!, title: nil)
        history.recordVisit(url: URL(string: "https://other.test/")!, title: "Other")
        XCTAssertFalse(history.recordVisit(url: URL(string: "about:blank")!, title: "x"))
        XCTAssertFalse(history.recordVisit(url: URL(string: "file:///etc/hosts")!, title: "x"))
        history.updateTitle(url: URL(string: "https://other.test/")!, title: "Other (renamed)")

        let entries = history.entries()
        XCTAssertEqual(entries.count, 2)
        let a = try XCTUnwrap(entries.first { $0.url == "https://example.com/a" })
        XCTAssertEqual(a.visitCount, 2)
        XCTAssertEqual(a.title, "Example A")
        XCTAssertEqual(history.entries(matching: "RENAMED").map(\.url), ["https://other.test/"])
        XCTAssertEqual(history.entries(matching: "example.com").count, 1)

        XCTAssertTrue(history.hasUnsavedChanges)
        try history.save()
        XCTAssertFalse(history.hasUnsavedChanges)

        let reopened = try store()
        XCTAssertEqual(Set(reopened.entries().map(\.url)), ["https://example.com/a", "https://other.test/"])
        let raw = try Data(contentsOf: repo.historyURL(for: profile.id))
        XCTAssertNil(raw.range(of: Data("example.com".utf8)), "history must be encrypted")
        XCTAssertNil(raw.range(of: Data("secret".utf8)))
    }

    func testMemoryOnlyStoreNeverWrites() throws {
        let history = try store(persistent: false)
        history.recordVisit(url: URL(string: "https://example.com")!, title: "E")
        try history.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.historyURL(for: profile.id).path))
        XCTAssertEqual(history.count, 1)
    }

    func testRetentionAndCap() throws {
        let history = try store(policy: .init(maxEntries: 3, retentionDays: 30))
        let now = Date()
        history.recordVisit(url: URL(string: "https://old.test")!, title: nil, at: now.addingTimeInterval(-40 * 86_400))
        for i in 0..<5 {
            history.recordVisit(url: URL(string: "https://site\(i).test")!, title: nil, at: now.addingTimeInterval(Double(i)))
        }
        try history.save()
        let reopened = try store(policy: .init(maxEntries: 3, retentionDays: 30))
        XCTAssertEqual(reopened.entries().map(\.url), ["https://site4.test", "https://site3.test", "https://site2.test"])
    }

    func testClearAndRemove() throws {
        let history = try store()
        let now = Date()
        history.recordVisit(url: URL(string: "https://a.test")!, title: nil, at: now.addingTimeInterval(-7200))
        history.recordVisit(url: URL(string: "https://b.test")!, title: nil, at: now.addingTimeInterval(-60))
        history.recordVisit(url: URL(string: "https://c.test")!, title: nil, at: now.addingTimeInterval(-30))
        history.clear(since: now.addingTimeInterval(-3600), now: now)
        XCTAssertEqual(history.entries().map(\.url), ["https://a.test"])
        history.remove(url: "https://a.test")
        XCTAssertEqual(history.count, 0)
        history.recordVisit(url: URL(string: "https://d.test")!, title: nil)
        history.clear()
        XCTAssertEqual(history.count, 0)
    }

    func testMergeHonoursTombstonesAndWatermark() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ url: String, _ title: String, last: TimeInterval, count: Int) -> HistoryEntry {
            HistoryEntry(url: url, title: title, firstVisitedAt: t0, lastVisitedAt: t0.addingTimeInterval(last), visitCount: count)
        }
        var a = HistoryDocument()
        a.entries = [entry("https://x.test/", "X old", last: 10, count: 2),
                     entry("https://gone.test/", "Gone", last: 5, count: 1)]
        var b = HistoryDocument()
        b.entries = [entry("https://x.test/", "X new", last: 20, count: 3),
                     entry("https://gone.test/", "Gone", last: 5, count: 1),
                     entry("https://y.test/", "Y", last: 1, count: 1)]
        b.removedURLs = ["https://gone.test/": t0.addingTimeInterval(6)]

        let policy = HistoryStore.Policy(maxEntries: 100, retentionDays: nil)
        let merged = HistoryStore.merge(a, b, policy: policy, now: t0)
        XCTAssertEqual(merged.entries.map(\.url), ["https://x.test/", "https://y.test/"])
        XCTAssertEqual(merged.entries[0].title, "X new")
        XCTAssertEqual(merged.entries[0].visitCount, 3)
        XCTAssertEqual(HistoryStore.merge(merged, merged, policy: policy, now: t0), merged, "merge is idempotent")

        var cleared = HistoryDocument()
        cleared.clearedThrough = t0.addingTimeInterval(15)
        XCTAssertEqual(HistoryStore.merge(merged, cleared, policy: policy, now: t0).entries.map(\.url), ["https://x.test/"])
    }
}

final class BookmarkStoreTests: XCTestCase {
    var root: URL!
    var repo: ProfileRepository!
    var profile: ProfileSummary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-bookmarks-\(UUID().uuidString)")
        repo = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: 1_000))
        profile = try repo.create(name: "P", configuration: ProfileConfiguration())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() throws -> BookmarkStore {
        try repo.bookmarkStore(for: profile.id, key: repo.profileKey(for: profile.id))
    }

    func testAddUpdateMoveRemovePersist() throws {
        let bookmarks = try store()
        let a = try bookmarks.add(title: "A", url: URL(string: "https://a.test/#top")!)
        let b = try bookmarks.add(title: "  ", url: URL(string: "https://b.test/")!)
        let c = try bookmarks.add(title: "C", url: URL(string: "https://c.test/")!, folder: "Work")
        XCTAssertThrowsError(try bookmarks.add(title: "x", url: URL(string: "javascript:alert(1)")!))
        XCTAssertEqual(b.title, "https://b.test/", "empty title falls back to URL")
        XCTAssertEqual(bookmarks.bookmark(for: URL(string: "https://a.test/")!)?.id, a.id)
        XCTAssertEqual(bookmarks.folders(), ["Work"])

        try bookmarks.move(id: b.id, toIndex: 0)
        XCTAssertEqual(bookmarks.all().map(\.id), [b.id, a.id, c.id])

        var edited = c
        edited.title = "C2"
        edited.folder = nil
        try bookmarks.update(edited)
        XCTAssertEqual(bookmarks.all().map(\.title), [b.title, "A", "C2"])

        try bookmarks.remove(id: a.id)
        let reopened = try store()
        XCTAssertEqual(reopened.all().map(\.id), [b.id, c.id])
        XCTAssertNil(try Data(contentsOf: repo.bookmarksURL(for: profile.id)).range(of: Data("c.test".utf8)))
    }

    func testMergeKeepsNewestAndDeletions() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        func bm(_ id: UUID, _ title: String, updated: TimeInterval) -> Bookmark {
            Bookmark(id: id, title: title, url: "https://\(title).test/", folder: nil, position: 1,
                     createdAt: t0, updatedAt: t0.addingTimeInterval(updated))
        }
        var a = BookmarkDocument()
        a.bookmarks = [bm(id1, "one-old", updated: 1), bm(id2, "two", updated: 1)]
        a.deleted = [id3.uuidString: t0.addingTimeInterval(5)]
        var b = BookmarkDocument()
        b.bookmarks = [bm(id1, "one-new", updated: 2), bm(id3, "three", updated: 3)]
        b.deleted = [id2.uuidString: t0.addingTimeInterval(2)]

        let merged = BookmarkStore.merge(a, b)
        XCTAssertEqual(merged.bookmarks.map(\.title), ["one-new"])
        XCTAssertEqual(BookmarkStore.merge(merged, a), merged)
    }
}

final class ConfigurationCompatibilityTests: XCTestCase {
    /// A configuration as written by the first release (no history fields).
    func testDecodesConfigurationWithoutNewFields() throws {
        let legacy = """
        {"ephemeral":false,"geolocation":{"deny":{}},"safeBrowsingEnabled":false,"timeZoneIdentifier":"UTC","webRTCPolicy":"relayOnly"}
        """
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.webRTCPolicy, .relayOnly)
        XCTAssertEqual(decoded.timeZoneIdentifier, "UTC")
        XCTAssertTrue(decoded.historyEnabled)
        XCTAssertEqual(decoded.historyRetentionDays, 90)
    }

    func testKeepForeverRoundTrips() throws {
        var config = ProfileConfiguration()
        config.historyRetentionDays = nil
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(config))
        XCTAssertNil(decoded.historyRetentionDays)
        XCTAssertEqual(decoded, config)
    }

    func testRetentionValidation() {
        XCTAssertThrowsError(try ProfileConfiguration(historyRetentionDays: 0).validate())
        XCTAssertNoThrow(try ProfileConfiguration(historyRetentionDays: nil).validate())
    }
}

final class DeviceGenerationTests: XCTestCase {
    func testCatalogAndEngineConsistency() {
        XCTAssertFalse(DeviceGenerations.all.isEmpty)
        // The default generation is the macOS one and is the only engine-consistent family.
        let def = DeviceGenerations.resolved(id: nil)
        XCTAssertEqual(def.id, DeviceGenerations.defaultID)
        XCTAssertEqual(def.platform, .macOS)
        XCTAssertTrue(def.matchesEngine)
        XCTAssertTrue(def.userAgent.contains("Macintosh"))
        // iOS/iPadOS generations are honestly marked as not matching the engine.
        for id in ["ios-26", "ios-27", "ipados-26"] {
            let gen = DeviceGenerations.generation(id: id)
            XCTAssertNotNil(gen, id)
            XCTAssertEqual(gen?.matchesEngine, false, id)
        }
        // Unknown ids fall back to the default rather than crashing.
        XCTAssertEqual(DeviceGenerations.resolved(id: "nope").id, DeviceGenerations.defaultID)
        XCTAssertNil(DeviceGenerations.generation(id: "nope"))
    }

    func testEffectiveUserAgentPrecedence() {
        // Generation supplies the UA when there is no explicit override.
        let ios = ProfileConfiguration(deviceGenerationID: "ios-26")
        XCTAssertEqual(ios.effectiveUserAgent, DeviceGenerations.generation(id: "ios-26")?.userAgent)
        XCTAssertTrue(ios.effectiveUserAgent?.contains("iPhone OS 26") == true)
        // An explicit user agent overrides the generation.
        let custom = ProfileConfiguration(userAgent: "Custom/1.0", deviceGenerationID: "ios-26")
        XCTAssertEqual(custom.effectiveUserAgent, "Custom/1.0")
        // No generation and no override → WebKit default (nil).
        XCTAssertNil(ProfileConfiguration(deviceGenerationID: nil).effectiveUserAgent)
        // An empty override string is treated as "no override" too.
        XCTAssertNil(ProfileConfiguration(userAgent: "", deviceGenerationID: nil).effectiveUserAgent)
    }

    func testGenerationIDRoundTripsAndToleratesOldConfigs() throws {
        var config = ProfileConfiguration.forGeneration(DeviceGenerations.resolved(id: "ios-27"))
        XCTAssertEqual(config.deviceGenerationID, "ios-27")
        config.startURL = URL(string: "https://example.com")
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(config))
        XCTAssertEqual(decoded.deviceGenerationID, "ios-27")
        // A config written before this field existed decodes with deviceGenerationID == nil
        // (→ default generation), without error.
        let legacy = """
        {"ephemeral":false,"geolocation":{"deny":{}},"historyEnabled":true,"safeBrowsingEnabled":false,"webRTCPolicy":"disabled"}
        """
        let old = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(legacy.utf8))
        XCTAssertNil(old.deviceGenerationID)
        XCTAssertEqual(old.deviceGeneration.id, DeviceGenerations.defaultID)
    }
}

final class DeviceModelTests: XCTestCase {
    func testCatalogIsPerPlatformAndMacHasNone() {
        XCTAssertFalse(DeviceModels.forPlatform(.iOS).isEmpty)
        XCTAssertFalse(DeviceModels.forPlatform(.iPadOS).isEmpty)
        XCTAssertTrue(DeviceModels.forPlatform(.macOS).isEmpty, "macOS profiles report the real machine")
        XCTAssertEqual(Set(DeviceModels.all.map(\.id)).count, DeviceModels.all.count, "ids are unique")
        for platform in [DeviceGeneration.Platform.iOS, .iPadOS] {
            XCTAssertEqual(DeviceModels.defaultModel(for: platform).platform, platform)
        }
    }

    func testModelLookupIsPlatformChecked() {
        XCTAssertEqual(DeviceModels.model(id: "ipad-air", platform: .iPadOS)?.id, "ipad-air")
        XCTAssertNil(DeviceModels.model(id: "ipad-air", platform: .iOS), "an iPad model must not apply to an iPhone profile")
        XCTAssertNil(DeviceModels.model(id: "nope", platform: .iOS))
        XCTAssertNil(DeviceModels.model(id: nil, platform: .iOS))
    }

    func testConfigurationResolvesModelAgainstItsGeneration() throws {
        var config = ProfileConfiguration.forGeneration(DeviceGenerations.resolved(id: "ipados-26"))
        config.deviceModelID = "ipad-air"
        XCTAssertEqual(config.deviceModel?.id, "ipad-air")
        // Switching the generation to iPhone leaves a stale iPad id behind: it must resolve to nil.
        config.deviceGenerationID = "ios-26"
        XCTAssertNil(config.deviceModel)
        // A macOS generation never has a model, whatever is stored.
        config.deviceGenerationID = DeviceGenerations.defaultID
        XCTAssertNil(config.deviceModel)
        // The id round-trips and old configs decode without it.
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(config))
        XCTAssertEqual(decoded.deviceModelID, "ipad-air")
        let legacy = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(#"{"ephemeral":false}"#.utf8))
        XCTAssertNil(legacy.deviceModelID)
    }
}
