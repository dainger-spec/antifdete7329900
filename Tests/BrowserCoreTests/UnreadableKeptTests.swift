import XCTest
@testable import BrowserCore

/// The owner's rule of 1 November (docs/DESTRUCTIVE_PATHS.md): nothing unreadable is ever deleted,
/// whatever the circumstances. A file that does not open is moved aside as `<file>.unreadable`
/// (then `-2`, …) — the cookie import queue (question 8), the warm-up plan and schedule (R1b) —
/// and what is in a migration's way is removed only when it is an empty folder at that moment (R7).
final class UnreadableKeptTests: XCTestCase {
    var root: URL!
    var repository: ProfileRepository!
    var id: UUID!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-kept-\(UUID().uuidString)")
        repository = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent("vault"), password: "pw", iterations: 1_000))
        id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let cookie = ImportedCookie(name: "sid", value: "v", domain: "a.example", hostOnly: true)

    private func damage(_ url: URL) throws -> Data {
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: url)
        return bytes
    }

    private func aside(_ url: URL, _ suffix: String = "unreadable") -> URL { url.appendingPathExtension(suffix) }

    // MARK: The cookie import queue (question 8)

    /// The launch used to delete a queue it could not read; now it is moved aside, its bytes as they
    /// were, and the person can import again.
    func testAnUnreadableImportQueueIsMovedAsideNotDeleted() throws {
        try repository.queueImportedCookies([cookie], for: id)
        let queue = repository.importedCookiesURL(for: id)
        let damaged = try damage(queue)
        XCTAssertThrowsError(try repository.importedCookiesForLaunch(id))
        let moved = try repository.moveUnreadableImportedCookiesAside(id)
        XCTAssertEqual(moved?.lastPathComponent, "cookies-import.bin.unreadable")
        XCTAssertEqual(try Data(contentsOf: aside(queue)), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        XCTAssertEqual(try repository.importedCookiesForLaunch(id), [])
    }

    /// An import into a stopped profile whose queue cannot be read moves that queue aside and queues
    /// the new cookies, instead of failing (or writing over it).
    func testImportingOverAnUnreadableQueueKeepsItAside() throws {
        try repository.queueImportedCookies([cookie], for: id)
        let queue = repository.importedCookiesURL(for: id)
        let damaged = try damage(queue)
        let other = ImportedCookie(name: "other", value: "w", domain: "b.example", hostOnly: true)
        XCTAssertEqual(try repository.queueImportedCookies([other], for: id), 1)
        XCTAssertEqual(try repository.importedCookiesForLaunch(id).map(\.name), ["other"])
        XCTAssertEqual(try Data(contentsOf: aside(queue)), damaged)
    }

    /// A queue that reads is not moved: only an unreadable one is.
    func testAReadableQueueIsNotMovedAside() throws {
        try repository.queueImportedCookies([cookie], for: id)
        XCTAssertNil(try repository.moveUnreadableImportedCookiesAside(id))
        XCTAssertEqual(try repository.importedCookiesForLaunch(id), [cookie])
    }

    // MARK: The warm-up plan and schedule (R1b)

    /// The test that confirmed R1b in the audit (appendix B): the warm-up screen shows a new plan
    /// when the saved one cannot be read, and saving it wrote over the file.
    func testAnUnreadableWarmUpPlanIsKeptAsideWhenAPlanIsSaved() throws {
        try repository.saveWarmUpPlan(WarmUpPlan(addresses: "https://a.example/"), for: id)
        let url = repository.warmUpPlanURL(for: id)
        let damaged = try damage(url)
        XCTAssertThrowsError(try repository.warmUpPlan(for: id))
        try repository.saveWarmUpPlan(WarmUpPlan(addresses: "https://b.example/"), for: id)
        XCTAssertEqual(try Data(contentsOf: aside(url)), damaged, "the unreadable warmup.bin was written over")
        XCTAssertEqual(try repository.warmUpPlan(for: id)?.addresses, "https://b.example/")
        // A second unreadable one goes beside the first.
        let again = try damage(url)
        try repository.saveWarmUpPlan(WarmUpPlan(addresses: "https://c.example/"), for: id)
        XCTAssertEqual(try Data(contentsOf: aside(url, "unreadable-2")), again)
        XCTAssertEqual(try Data(contentsOf: aside(url)), damaged)
    }

    func testAnUnreadableWarmUpScheduleIsKeptAsideWhenAScheduleIsSaved() throws {
        try repository.saveWarmUpSchedule(WarmUpSchedule(everyHours: 6), for: id)
        let url = repository.warmUpScheduleURL(for: id)
        let damaged = try damage(url)
        XCTAssertThrowsError(try repository.warmUpSchedule(for: id))
        try repository.saveWarmUpSchedule(WarmUpSchedule(everyHours: 12), for: id)
        XCTAssertEqual(try Data(contentsOf: aside(url)), damaged)
        XCTAssertEqual(try repository.warmUpSchedule(for: id)?.everyHours, 12)
    }

    // MARK: Every encrypted document: the rule in one place

    /// The open tabs a stop keeps, written over an unreadable file or forgotten when "restore tabs"
    /// is turned off: either way the unreadable file is moved aside, not written over or deleted.
    func testUnreadableOpenTabsAreKeptAsideBySaveAndByRemoval() throws {
        let tabs = OpenTabs(windows: [.init(tabs: [URL(string: "https://a.example/")!])])
        try repository.saveOpenTabs(tabs, for: id)
        let url = repository.openTabsURL(for: id)
        let first = try damage(url)
        try repository.saveOpenTabs(tabs, for: id)
        XCTAssertEqual(try Data(contentsOf: aside(url)), first)
        let second = try damage(url)
        try repository.removeOpenTabs(for: id)
        XCTAssertEqual(try Data(contentsOf: aside(url, "unreadable-2")), second, "removed, not kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // A readable one is still removed when asked.
        try repository.saveOpenTabs(tabs, for: id)
        try repository.removeOpenTabs(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside(url, "unreadable-3").path))
    }

    /// Cookie sync turned off empties the synced cookies and drops this Mac's baseline: unreadable
    /// ones are moved aside instead (the audit had these as written over "by design").
    func testTurningCookieSyncOffKeepsUnreadableCookieFilesAside() throws {
        let jar = repository.cookieJarURL(for: id), baseline = repository.cookieBaselineURL(for: id)
        try repository.saveCookieJar(CookieJarDocument(), for: id)
        try repository.saveCookieBaseline(CookieBaseline(), for: id)
        let damagedJar = try damage(jar), damagedBaseline = try damage(baseline)
        try repository.clearSyncedCookies(for: id)
        XCTAssertEqual(try Data(contentsOf: aside(jar)), damagedJar)
        XCTAssertEqual(try Data(contentsOf: aside(baseline)), damagedBaseline)
        XCTAssertEqual(try repository.cookieJar(for: id), CookieJarDocument())
    }

    /// The profile's key copy is written again from the index at unlock; one this vault cannot read
    /// is moved aside first.
    func testAnUnreadableKeyCopyIsKeptAsideWhenWrittenAgain() throws {
        let url = repository.keyCopyURL(for: id)
        let damaged = try damage(url)
        let reopened = try ProfileRepository.openedAtUnlock(vault: repository.vault)
        XCTAssertEqual(try Data(contentsOf: aside(url)), damaged)
        XCTAssertNotNil(reopened.readKeyCopy(id), "a readable copy is written in its place")
    }

    /// A plan saved over a readable one is no move: nothing beside it.
    func testSavingOverAReadablePlanLeavesNothingBeside() throws {
        try repository.saveWarmUpPlan(WarmUpPlan(addresses: "https://a.example/"), for: id)
        try repository.saveWarmUpPlan(WarmUpPlan(addresses: "https://b.example/"), for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside(repository.warmUpPlanURL(for: id)).path))
    }
}

/// R7: what is in a migration's way is looked at again when the move is made, not taken on the
/// plan's word: only an empty folder goes; anything else stops the migration with nothing touched.
final class MigrationInTheWayTests: XCTestCase {
    var home: URL!
    let bundleID = "dev.local.PrivacyBrowser"
    var container: URL { home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true) }
    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pb-migrate-\(UUID().uuidString)")
        let containerVault = UnsandboxedMigration.vaultFolder(in: container)
        try FileManager.default.createDirectory(at: containerVault, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: MasterVault.headerURL(in: containerVault))
        // An empty folder where the vault goes: the plan takes it as free.
        try FileManager.default.createDirectory(at: UnsandboxedMigration.vaultFolder(in: library), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var plan: [UnsandboxedMigration.Move] {
        UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID)
    }

    func testAnEmptyFolderInTheWayGoes() throws {
        let moves = plan
        XCTAssertEqual(moves.count, 1)
        try UnsandboxedMigration.perform(moves)
        XCTAssertTrue(MasterVault.exists(in: UnsandboxedMigration.vaultFolder(in: library)))
    }

    /// The test that confirmed R7 in the audit: something put there between the plan and the move
    /// was deleted with the folder.
    func testWhatAppearedAfterThePlanStopsTheMigration() throws {
        let moves = plan
        XCTAssertEqual(moves.count, 1)
        let note = UnsandboxedMigration.vaultFolder(in: library).appendingPathComponent("note.txt")
        try Data("mine".utf8).write(to: note)
        XCTAssertThrowsError(try UnsandboxedMigration.perform(moves))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "mine")
        XCTAssertTrue(MasterVault.exists(in: UnsandboxedMigration.vaultFolder(in: container)), "the container's vault stays where it was")
    }

    /// A link in the way is neither followed nor removed.
    func testALinkInTheWayStopsTheMigration() throws {
        let moves = plan
        let destination = UnsandboxedMigration.vaultFolder(in: library)
        try FileManager.default.removeItem(at: destination)
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try UnsandboxedMigration.perform(moves))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}
