import XCTest
@testable import BrowserCore

final class RestorePointTests: XCTestCase {
    private var base: URL!
    private var repository: ProfileRepository!
    private var id: UUID!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-restore-\(UUID().uuidString)")
        repository = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent("A"), password: "pw", iterations: 1_000))
        id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func file(_ name: String) -> URL { repository.directory(for: id).appendingPathComponent(name) }
    private func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: file(name)) }
    private func read(_ name: String) -> String? { (try? Data(contentsOf: file(name))).map { String(decoding: $0, as: UTF8.self) } }

    func testAPointHoldsTheBrowsingStateAndARestorePutsItBackKeepingWhatItReplaced() throws {
        try write("webdata.pbsa", "site data 1")
        try write("history.bin", "history 1")
        try write("cookies.bin", "cookies 1")
        try write("config.bin.keep", "not part of it") // not one of the point's files
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let point = try repository.createRestorePoint(for: id, name: "  Before sign-up  ", at: start)
        XCTAssertEqual(point.name, "Before sign-up")
        XCTAssertEqual(point.kind, .manual)
        XCTAssertEqual(point.files, ["webdata.pbsa", "history.bin", "cookies.bin"])
        XCTAssertEqual(point.bytes, Int64("site data 1".utf8.count + "history 1".utf8.count + "cookies 1".utf8.count))
        XCTAssertEqual(repository.restorePoints(for: id), [point])

        // The profile goes on: new data, and a file the point did not have.
        try write("webdata.pbsa", "site data 2")
        try write("history.bin", "history 2")
        try write("cookies.bin", "cookies 2")
        try write("tabs.bin", "tabs 2")

        let kept = try repository.restore(point.id, for: id, at: start.addingTimeInterval(60))
        XCTAssertEqual(read("webdata.pbsa"), "site data 1")
        XCTAssertEqual(read("history.bin"), "history 1")
        XCTAssertEqual(read("cookies.bin"), "cookies 1")
        XCTAssertNil(read("tabs.bin"), "the point had no open tabs: none now")
        XCTAssertEqual(read("config.bin.keep"), "not part of it")
        XCTAssertEqual(kept.kind, .beforeRestore)
        XCTAssertEqual(kept.files, ["webdata.pbsa", "history.bin", "cookies.bin", "tabs.bin"])
        XCTAssertEqual(repository.restorePoints(for: id).map(\.id), [kept.id, point.id], "newest first")

        // The restore is undone by restoring what it kept.
        try repository.restore(kept.id, for: id, at: start.addingTimeInterval(120))
        XCTAssertEqual(read("webdata.pbsa"), "site data 2")
        XCTAssertEqual(read("tabs.bin"), "tabs 2")
        XCTAssertEqual(repository.restorePoints(for: id).count, 3)
        // Nothing left behind by the copies.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: id).path).filter { $0.hasSuffix(".restoring") }
        XCTAssertEqual(leftovers, [])
    }

    func testPointsAreBoundedRemovedOnlyByTheirOwnRemovalAndADamagedOneIsNotRestored() throws {
        try write("webdata.pbsa", "data")
        for index in 0..<ProfileRepository.maximumRestorePoints {
            try repository.createRestorePoint(for: id, name: "\(index)", at: Date(timeIntervalSince1970: Double(1_800_000_000 + index)))
        }
        XCTAssertThrowsError(try repository.createRestorePoint(for: id, name: "one more")) { error in
            XCTAssertEqual(error as? RestorePointProblem, .full(ProfileRepository.maximumRestorePoints))
        }
        let newest = try XCTUnwrap(repository.restorePoints(for: id).first)
        XCTAssertEqual(newest.name, "\(ProfileRepository.maximumRestorePoints - 1)")
        // A full list refuses a restore too: the state it would replace could not be kept.
        XCTAssertThrowsError(try repository.restore(newest.id, for: id))
        XCTAssertEqual(read("webdata.pbsa"), "data")

        try repository.removeRestorePoint(newest.id, for: id)
        XCTAssertEqual(repository.restorePoints(for: id).count, ProfileRepository.maximumRestorePoints - 1)
        XCTAssertEqual(read("webdata.pbsa"), "data", "the profile's own files are not touched")
        XCTAssertThrowsError(try repository.removeRestorePoint(newest.id, for: id)) { error in
            XCTAssertEqual(error as? RestorePointProblem, .notFound)
        }

        // A point missing a copy is refused before anything changes.
        let other = try XCTUnwrap(repository.restorePoints(for: id).first)
        try FileManager.default.removeItem(at: repository.restorePointDirectory(other.id, for: id).appendingPathComponent("webdata.pbsa"))
        try write("webdata.pbsa", "now")
        XCTAssertThrowsError(try repository.restore(other.id, for: id)) { error in
            XCTAssertEqual(error as? RestorePointProblem, .damaged)
        }
        XCTAssertEqual(read("webdata.pbsa"), "now")

        // A description that does not open is not listed, and its folder stays.
        try Data("damaged".utf8).write(to: repository.restorePointDirectory(other.id, for: id).appendingPathComponent("point.bin"))
        XCTAssertFalse(repository.restorePoints(for: id).contains { $0.id == other.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.restorePointDirectory(other.id, for: id).path))
    }

    func testPointsAndTheJournalStayOnThisMacEncrypted() async throws {
        // No files of its own: the export below reads the real ones.
        let point = try repository.createRestorePoint(for: id, name: "Secret name")
        try repository.record(.launched, for: id)
        try repository.record(.warmedUp, detail: "14 pages", for: id)
        let description = try Data(contentsOf: repository.restorePointDirectory(point.id, for: id).appendingPathComponent("point.bin"))
        XCTAssertNil(description.range(of: Data("Secret name".utf8)))
        XCTAssertNil(try Data(contentsOf: repository.journalURL(for: id)).range(of: Data("14 pages".utf8)))

        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let report = try await SyncEngine(repository: repository, transport: transport).sync()
        XCTAssertFalse(report.pushed.contains { $0.contains("restore") || $0.contains("journal") }, "\(report.pushed)")

        let exported = base.appendingPathComponent("P.pbprofile")
        try ProfileTransfer.export(id, from: repository, to: exported, password: "transfer", kdf: KDFParameters.generate(iterations: 1_000))
        let imported = try ProfileTransfer.importProfile(from: exported, password: "transfer", into: repository, name: "Copy")
        XCTAssertEqual(repository.restorePoints(for: imported.id), [])
        XCTAssertEqual(try repository.journal(for: imported.id).events, [])

        let counts = repository.counts(for: id, cookies: false)
        XCTAssertEqual(counts.restorePoints, 1)
        XCTAssertEqual(counts.recentEvents.map(\.known), [.warmedUp, .launched], "the newest first")
    }

    func testTheJournalKeepsTheNewestAndKindsItDoesNotKnow() throws {
        var journal = ProfileJournal()
        for index in 0..<(ProfileJournal.maximumEvents + 5) {
            journal.add(ProfileJournal.Event(at: Date(timeIntervalSince1970: Double(index)), kind: .launched, detail: "\(index)"))
        }
        XCTAssertEqual(journal.events.count, ProfileJournal.maximumEvents)
        XCTAssertEqual(journal.events.first?.detail, "5")
        XCTAssertEqual(journal.latest(2).map(\.detail), ["\(ProfileJournal.maximumEvents + 4)", "\(ProfileJournal.maximumEvents + 3)"])
        XCTAssertEqual(ProfileJournal.Event(at: Date(), kind: .proxyChanged, detail: String(repeating: "x", count: 500)).detail.count, 120)

        let later = #"{"events": [{"id": "\#(UUID().uuidString)", "at": "2026-01-01T00:00:00Z", "kind": "somethingNew", "detail": ""}]}"#
        let read = try JSONCoding.decoder.decode(ProfileJournal.self, from: Data(later.utf8))
        XCTAssertNil(read.events.first?.known)
        let written = String(decoding: try JSONCoding.encoder.encode(read), as: UTF8.self)
        XCTAssertTrue(written.contains("somethingNew"), "a later version's event is written back as it was")
    }
}
