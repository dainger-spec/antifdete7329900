#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// A sync never deletes a profile's data on this Mac (the owner, 3 November, after a person's
/// history, cookies and saved logins were reported gone): an empty sync location, or a new one, is
/// where this Mac's profiles go up, and nothing of them changes here; a location holding another
/// vault is refused before anything is touched. (A profile deleted on another device keeps its folder
/// here: `KeptDeletedProfileTests.testADeletionFromAnotherDeviceKeepsTheFolderHere`.)
final class SyncKeepsLocalDataTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-synckeeps-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Two profiles with history, saved logins, bookmarks, cookies and a sealed archive.
    private func vaultWithData(_ name: String) throws -> (ProfileRepository, [UUID]) {
        let repository = try ProfileRepository(vault: MasterVault.create(in: base.appendingPathComponent(name), password: "pw",
                                                                         iterations: 1_000))
        var ids: [UUID] = []
        for profileName in ["One", "Two"] {
            let profile = try repository.create(name: profileName, configuration: ProfileConfiguration())
            let key = try repository.profileKey(for: profile.id)
            let history = try repository.historyStore(for: profile.id, key: key)
            for number in 0..<5 { history.recordVisit(url: URL(string: "https://visit\(number).test/")!, title: "Visit \(number)") }
            try history.save()
            let passwords = try repository.passwordVault(for: profile.id)
            for number in 0..<2 {
                try passwords.upsert(PasswordEntry(origin: "https://login\(number).test", username: "person\(number)", password: "pw\(number)"))
            }
            let bookmarks = try repository.bookmarkStore(for: profile.id, key: key)
            for number in 0..<3 { _ = try bookmarks.add(title: "Mark \(number)", url: URL(string: "https://mark\(number).test/")!) }
            let cookies = (0..<4).map { number in
                ImportedCookie(name: "c\(number)", value: "v\(number)", domain: "cookie\(number).test", hostOnly: true,
                               expires: Date().addingTimeInterval(30 * 86_400), secure: true)
            }
            try repository.saveCookieJar(CookieJarDocument().recording(store: cookies, baseline: [], at: Date()), for: profile.id)
            // Never synced: the sealed WebKit store and Safari's home stay as they are.
            try Data("sealed webdata \(profileName)".utf8).write(to: repository.webDataArchiveURL(for: profile.id))
            try Data("sealed home \(profileName)".utf8).write(to: repository.safariHomeArchiveURL(for: profile.id))
            ids.append(profile.id)
        }
        return (repository, ids)
    }

    /// Every file in the profiles' folders, by its path there, with its SHA-256.
    private func profileFiles(_ repository: ProfileRepository, _ ids: [UUID]) -> [String: String] {
        var files: [String: String] = [:]
        for id in ids {
            let folder = repository.directory(for: id)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else { continue }
                files["\(id.uuidString)/\(name)"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return files
    }

    private func counts(_ repository: ProfileRepository, _ id: UUID) throws -> [Int] {
        let key = try repository.profileKey(for: id)
        return [try repository.historyStore(for: id, key: key).count,
                try repository.passwordVault(for: id).allEntries().count,
                try repository.bookmarkStore(for: id, key: key).all().count,
                try repository.cookieJar(for: id).cookies.count]
    }

    func testAnEmptyLocationTakesThisMacsProfilesAndNothingHereChanges() async throws {
        let (repository, ids) = try vaultWithData("mac")
        let before = profileFiles(repository, ids)
        for id in ids {
            for name in ["config.bin", "history.bin", "passwords.bin", "bookmarks.bin", "cookies.bin", "webdata.pbsa", "safarihome.pbsa"] {
                XCTAssertNotNil(before["\(id.uuidString)/\(name)"], "\(name) of \(id): \(before.keys.sorted())")
            }
        }
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("empty-location"))
        let there = try await transport.listObjects()
        XCTAssertTrue(there.isEmpty)

        let report = try await SyncEngine(repository: repository, transport: transport).sync()

        XCTAssertEqual(report.deletedProfileIDs, [])
        XCTAssertTrue(report.pulled.filter { $0.hasPrefix("profile/") }.isEmpty, "nothing came down from an empty location: \(report.pulled)")
        for id in ids {
            for file in ["config", "passwords", "bookmarks", "history", "cookies"] {
                XCTAssertTrue(report.pushed.contains("profile/\(id.uuidString)/\(file)"), "\(file) of \(id) went up: \(report.pushed)")
            }
            XCTAssertEqual(try counts(repository, id), [5, 2, 3, 4])
        }
        XCTAssertEqual(profileFiles(repository, ids), before, "every file of every profile here, byte for byte")
        XCTAssertEqual(Set(repository.list().map(\.id)), Set(ids))

        // And synced again: the location now holds what this Mac put there; still nothing changes here.
        let again = try await SyncEngine(repository: repository, transport: transport).sync()
        XCTAssertEqual(again.deletedProfileIDs, [])
        XCTAssertEqual(profileFiles(repository, ids), before)
    }

    func testALocationHoldingAnotherVaultIsRefusedAndNothingHereChanges() async throws {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("someone-elses"))
        let (other, _) = try vaultWithData("other")
        _ = try await SyncEngine(repository: other, transport: transport).sync()

        let (repository, ids) = try vaultWithData("mac")
        let before = profileFiles(repository, ids)
        do {
            _ = try await SyncEngine(repository: repository, transport: transport).sync()
            XCTFail("a location holding another vault must be refused")
        } catch {
            // Refused: "sync location holds a different vault".
        }
        XCTAssertEqual(profileFiles(repository, ids), before, "every file of every profile here, byte for byte")
        XCTAssertEqual(Set(repository.list().map(\.id)), Set(ids))
        for id in ids { XCTAssertEqual(try counts(repository, id), [5, 2, 3, 4]) }
    }
}
