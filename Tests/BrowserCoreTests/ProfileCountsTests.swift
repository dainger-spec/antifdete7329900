import XCTest
@testable import BrowserCore

/// The Profiles window's inspector counts what a profile keeps (`ProfileRepository.counts`) — and
/// only looks: it is called on whatever profile is selected, often while it runs. Counting never
/// writes, moves aside or takes in anything (docs/DESTRUCTIVE_PATHS.md: nothing unreadable is moved
/// or deleted by something that was only meant to read).
final class ProfileCountsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-counts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func repository() throws -> (ProfileRepository, UUID) {
        let repository = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent("v"), password: "pw", iterations: 1_000))
        let id = try repository.create(name: "P", configuration: ProfileConfiguration()).id
        return (repository, id)
    }

    /// Every file of the profile's folder with its bytes: what "nothing changed" is checked against.
    private func contents(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[name] = try Data(contentsOf: url)
        }
        return files
    }

    func testAProfileWithNothingSavedCountsZeroes() throws {
        let (repository, id) = try repository()
        XCTAssertEqual(repository.counts(for: id, cookies: true),
                       ProfileCounts(logins: 0, bookmarks: 0, historyEntries: 0, syncedCookies: 0))
        XCTAssertNil(repository.counts(for: id, cookies: false).syncedCookies, "cookies not asked for: not counted")
    }

    func testCountsWhatTheProfileKeeps() throws {
        let (repository, id) = try repository()
        let key = try repository.profileKey(for: id)
        let vault = try repository.passwordVault(for: id)
        try vault.upsert(PasswordEntry(origin: "https://a.example", username: "me", password: "1"))
        try vault.upsert(PasswordEntry(origin: "https://b.example", username: "me", password: "2"))
        let bookmarks = try repository.bookmarkStore(for: id, key: key)
        _ = try bookmarks.add(title: "A", url: URL(string: "https://a.example/")!)
        let history = try repository.historyStore(for: id, key: key)
        for page in ["https://a.example/1", "https://a.example/2", "https://b.example/"] {
            history.recordVisit(url: URL(string: page)!, title: nil)
        }
        try history.save()
        try repository.saveCookieJar(CookieJarDocument(cookies: [
            .init(cookie: ImportedCookie(name: "s", value: "1", domain: "a.example", hostOnly: true), updatedAt: Date())
        ]), for: id)

        XCTAssertEqual(repository.counts(for: id, cookies: true),
                       ProfileCounts(logins: 2, bookmarks: 1, historyEntries: 3, syncedCookies: 1))
    }

    /// The history the profile would show: its own setting applied, in memory only.
    func testHistoryIsCountedAsTheProfilesSettingKeepsIt() throws {
        let (repository, id) = try repository()
        let history = try repository.historyStore(for: id, key: repository.profileKey(for: id), policy: .init(retentionDays: nil))
        history.recordVisit(url: URL(string: "https://old.example/")!, title: nil, at: Date(timeIntervalSinceNow: -200 * 86_400))
        history.recordVisit(url: URL(string: "https://new.example/")!, title: nil)
        try history.save()
        let before = try contents(repository.directory(for: id))

        XCTAssertEqual(repository.counts(for: id, historyPolicy: .init(retentionDays: nil), cookies: false).historyEntries, 2)
        XCTAssertEqual(repository.counts(for: id, historyPolicy: .init(retentionDays: 90), cookies: false).historyEntries, 1)
        XCTAssertEqual(try contents(repository.directory(for: id)), before, "counting pruned the history on disk")
    }

    /// A login another device changed at the same time is one login with a version kept beside it:
    /// counted once.
    func testVersionsKeptAfterAConflictAreNotCountedAsLogins() throws {
        let (repository, id) = try repository()
        let login = PasswordEntry(origin: "https://site.example", username: "me", password: "main")
        var other = PasswordEntry(origin: "https://site.example", username: "me", password: "other")
        other.conflictOf = login.id
        let sealed = try AEAD.seal(JSONCoding.encoder.encode([login, other]),
                                   key: PasswordVault.fileKey(profileID: id, profileKey: repository.profileKey(for: id)),
                                   aad: PasswordVault.aad(profileID: id))
        try sealed.write(to: repository.passwordsURL(for: id))
        XCTAssertEqual(repository.counts(for: id, cookies: false).logins, 1)
    }

    /// Files that do not open are not counted, and stay exactly as they were: not moved aside as
    /// `.unreadable`, not written over. A copy an earlier sync set beside the passwords is not taken
    /// in (opening a `PasswordVault` would): counting writes nothing.
    func testCountingWritesMovesAndTakesInNothing() throws {
        let (repository, id) = try repository()
        let directory = repository.directory(for: id)
        let damaged = Data(repeating: 7, count: 120)
        try damaged.write(to: repository.passwordsURL(for: id))
        try damaged.write(to: repository.bookmarksURL(for: id))
        try damaged.write(to: repository.historyURL(for: id))
        try damaged.write(to: repository.cookieJarURL(for: id))
        let copy = try AEAD.seal(JSONCoding.encoder.encode([PasswordEntry(origin: "https://a.example", username: "u", password: "p")]),
                                 key: PasswordVault.fileKey(profileID: id, profileKey: repository.profileKey(for: id)),
                                 aad: PasswordVault.aad(profileID: id))
        try copy.write(to: repository.passwordsURL(for: id).appendingPathExtension("conflict"))
        let before = try contents(directory)

        XCTAssertEqual(repository.counts(for: id, cookies: true), ProfileCounts(), "a file that does not open was counted")
        XCTAssertEqual(try contents(directory), before, "counting changed the profile's folder")
        XCTAssertEqual(repository.unreadableFiles(for: id), [], "counting moved an unreadable file aside")

        // A readable passwords file beside the copy: counted, and the copy still not taken in.
        let mine = try AEAD.seal(JSONCoding.encoder.encode([PasswordEntry(origin: "https://b.example", username: "me", password: "q")]),
                                 key: PasswordVault.fileKey(profileID: id, profileKey: repository.profileKey(for: id)),
                                 aad: PasswordVault.aad(profileID: id))
        try mine.write(to: repository.passwordsURL(for: id))
        let withCopy = try contents(directory)
        XCTAssertEqual(repository.counts(for: id, cookies: false).logins, 1)
        XCTAssertEqual(try contents(directory), withCopy, "counting took the copy in")
        // The control: opening the vault, as the password manager does, takes it in — the change
        // the check above would have seen.
        _ = try repository.passwordVault(for: id)
        XCTAssertNotEqual(try contents(directory), withCopy, "the control did not change the folder: the check above proves nothing")
    }

    /// A profile that is not in the index (its key unknown) counts nothing, and nothing is made for it.
    func testAnUnknownProfileCountsNothing() throws {
        let (repository, _) = try repository()
        let stranger = UUID()
        XCTAssertEqual(repository.counts(for: stranger, cookies: true), ProfileCounts())
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: stranger).path))
    }
}
