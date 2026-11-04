import XCTest
@testable import BrowserCore

/// Sync's merge of a profile's history keeps what the profile's retention keeps. With the profile's
/// settings unreadable it used the default policy (90 days) and cut a history kept for a year, or
/// for ever, to 90 days on every device (the audit's finding).
final class HistoryMergeRetentionTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-histmerge-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ url: String, daysAgo: Double) -> HistoryEntry {
        let at = Date().addingTimeInterval(-daysAgo * 86_400)
        return HistoryEntry(url: url, title: url, firstVisitedAt: at, lastVisitedAt: at, visitCount: 1)
    }

    private func merged(retentionDays: Int?, configReadable: Bool) throws -> Set<String> {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent(UUID().uuidString),
                                                                         password: "pw", iterations: 1_000))
        let id = try repository.create(name: "P", configuration: ProfileConfiguration(historyRetentionDays: retentionDays)).id
        let codec = HistoryStore.file(url: nil, profileID: id, profileKey: try repository.profileKey(for: id))
        let local = try codec.encode(HistoryDocument(entries: [entry("https://old.test/", daysAgo: 200)]))
        let remote = try codec.encode(HistoryDocument(entries: [entry("https://new.test/", daysAgo: 1)]))
        if !configReadable {
            let url = repository.directory(for: id).appendingPathComponent("config.bin")
            var bytes = try Data(contentsOf: url)
            bytes[bytes.count - 1] ^= 0x01
            try bytes.write(to: url)
            XCTAssertThrowsError(try repository.loadConfiguration(id))
        }
        let document = try codec.decode(repository.mergeSyncedFile(.history, profileID: id, local: local, remote: remote))
        return Set(document.entries.map(\.url))
    }

    func testAHistoryKeptForAYearKeepsItsOldEntriesWhenTheSettingsCannotBeRead() throws {
        XCTAssertEqual(try merged(retentionDays: 365, configReadable: false), ["https://old.test/", "https://new.test/"])
        XCTAssertEqual(try merged(retentionDays: nil, configReadable: false), ["https://old.test/", "https://new.test/"])
    }

    func testTheProfilesOwnRetentionStillApplies() throws {
        XCTAssertEqual(try merged(retentionDays: 365, configReadable: true), ["https://old.test/", "https://new.test/"])
        XCTAssertEqual(try merged(retentionDays: 90, configReadable: true), ["https://new.test/"])
    }
}
