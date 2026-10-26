import XCTest
@testable import BrowserCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Low iteration count keeps tests fast; production uses `KDFParameters.recommendedIterations`.
private let testIterations = 1_000

/// A temporary vault, plus helpers to give a profile one file of every kind.
class ProfileFilesFixture: XCTestCase {
    var root: URL!
    var repository: ProfileRepository!
    let tabs = ["https://example.com/inbox", "https://example.com/report"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-backup-\(UUID().uuidString)")
        repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "master", iterations: testIterations))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    var configuration: ProfileConfiguration {
        ProfileConfiguration(userAgent: "Mozilla/5.0 Test",
                             proxy: ProxySettings(kind: .socks5, host: "proxy.test", port: 1080, username: "u", password: "p"),
                             timeZoneIdentifier: "Europe/Berlin", webRTCPolicy: .relayOnly)
    }

    /// Archive root labels as the WebKit layout writes them: they end in the profile UUID
    /// (one lowercase, one uppercase, as WebKit's own directory names vary).
    func webDataLabels(_ id: UUID) -> [String] {
        ["WebKit|WebsiteDataStore|\(id.uuidString.lowercased())", "Caches|WebKit|WebsiteDataStore|\(id.uuidString)"]
    }

    func sessionFile(_ repo: ProfileRepository, _ id: UUID, key: SymmetricKey) -> EncryptedDocumentFile<[String]> {
        ProfileFileBinding.session.document(url: repo.directory(for: id).appendingPathComponent("session.bin"),
                                            profileID: id, profileKey: key)
    }

    /// Config, passwords, history, bookmarks, session and a WebKit data archive.
    func populatedProfile(name: String = "Работа") throws -> ProfileSummary {
        let profile = try repository.create(name: name, configuration: configuration)
        let key = try repository.profileKey(for: profile.id)
        try repository.passwordVault(for: profile.id).upsert(PasswordEntry(origin: "https://example.com", username: "u", password: "p"))
        let history = try repository.historyStore(for: profile.id, key: key)
        history.recordVisit(url: URL(string: "https://example.com/a")!, title: "A")
        try history.save()
        try repository.bookmarkStore(for: profile.id, key: key).add(title: "B", url: URL(string: "https://example.com/b")!)
        try sessionFile(repository, profile.id, key: key).save(tabs)

        var roots: [String: URL] = [:]
        for (index, label) in webDataLabels(profile.id).enumerated() {
            let directory = root.appendingPathComponent("webkit-src-\(index)")
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("LocalStorage"), withIntermediateDirectories: true)
            try Data("cookie-jar-\(index)".utf8).write(to: directory.appendingPathComponent("LocalStorage/db"))
            roots[label] = directory
        }
        try EncryptedDirectoryArchive.seal(roots: roots, to: repository.webDataArchiveURL(for: profile.id), key: key)
        return profile
    }

    /// Every file of `populatedProfile` opens in `repo` for `id`, with the profile's current key.
    func assertProfileContents(_ repo: ProfileRepository, _ id: UUID, session: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let key = try repo.profileKey(for: id)
        XCTAssertEqual(try repo.loadConfiguration(id), configuration, file: file, line: line)
        XCTAssertEqual(try repo.passwordVault(for: id).allEntries().map(\.username), ["u"], file: file, line: line)
        XCTAssertEqual(try repo.historyStore(for: id, key: key).entries(matching: "").map(\.title), ["A"], file: file, line: line)
        XCTAssertEqual(try repo.bookmarkStore(for: id, key: key).all().map(\.title), ["B"], file: file, line: line)
        XCTAssertEqual(try sessionFile(repo, id, key: key).load(), session ? tabs : nil, file: file, line: line)

        // The WebKit data restores through the real layout, which only accepts labels naming `id`.
        let library = root.appendingPathComponent("library-\(UUID().uuidString)")
        let layout = WebKitDataLayout(library: library, bundleID: "dev.local.PrivacyBrowser", sandboxed: true)
        try EncryptedDirectoryArchive.unseal(from: repo.webDataArchiveURL(for: id), key: key) {
            try layout.destination(forLabel: $0, profileID: id)
        }
        let restored = layout.discoverDirectories(for: id)
        XCTAssertEqual(restored.count, 2, file: file, line: line)
        let contents = try restored.map { try String(decoding: Data(contentsOf: $0.appendingPathComponent("LocalStorage/db")), as: UTF8.self) }
        XCTAssertEqual(Set(contents), ["cookie-jar-0", "cookie-jar-1"], file: file, line: line)
    }

    func makeOtherRepository(_ name: String = "other-vault") throws -> ProfileRepository {
        try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent(name), password: "different",
                                                        iterations: testIterations))
    }

    func hiddenEntries(_ repo: ProfileRepository) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: repo.profilesDirectory.path).filter { $0.hasPrefix(".") }
    }
}

final class ProfileBackupTests: ProfileFilesFixture {
    private func exportBackup(_ id: UUID, password: String = "backup pw") throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).\(ProfileBackup.fileExtension)")
        try ProfileBackup.export(profile: id, from: repository, to: url, password: password, iterations: testIterations)
        return url
    }

    func testRoundTripIntoAnotherVaultKeepsIDAndKey() throws {
        let profile = try populatedProfile()
        try repository.markLaunched(profile.id)
        let backup = root.appendingPathComponent("work.\(ProfileBackup.fileExtension)")
        let info = try ProfileBackup.export(profile: profile.id, from: repository, to: backup, password: "backup pw",
                                            iterations: testIterations)
        XCTAssertEqual(info.profileID, profile.id)
        XCTAssertEqual(info.name, "Работа")
        XCTAssertEqual(info.fileCount, 6, "config, passwords, history, bookmarks, session, webdata")

        let bytes = try Data(contentsOf: backup)
        XCTAssertEqual(bytes.prefix(4), Data("PBBK".utf8))
        for marker in ["Работа", "example.com", "cookie-jar", "proxy.test", profile.id.uuidString,
                       profile.id.uuidString.lowercased()] {
            XCTAssertNil(bytes.range(of: Data(marker.utf8)), "\(marker) must not appear in plaintext")
        }
        XCTAssertEqual(try ProfileBackup.inspect(backup, password: "backup pw"), info)

        let other = try makeOtherRepository()
        let restored = try ProfileBackup.restore(from: backup, password: "backup pw", into: other)
        XCTAssertEqual(restored.id, profile.id)
        XCTAssertEqual(restored.name, "Работа")
        XCTAssertEqual(restored.revision, 1)
        XCTAssertNotNil(restored.lastLaunchedAt)
        XCTAssertEqual(try other.profileKey(for: profile.id).rawBytes, try repository.profileKey(for: profile.id).rawBytes,
                       "the same profile keeps its key")
        try assertProfileContents(other, profile.id)
        XCTAssertEqual(try ProfileRepository(vault: MasterVault.unlock(in: other.root, password: "different")).list().map(\.id),
                       [profile.id], "the restored profile survives a restart")
        XCTAssertEqual(try hiddenEntries(other), [], "staging directories are cleaned up")
    }

    func testRestoreAsCopyGetsNewIDAndNewKey() throws {
        let profile = try populatedProfile()
        let backup = try exportBackup(profile.id)

        // Same vault, profile still present → automatic restore makes a copy.
        let copy = try ProfileBackup.restore(from: backup, password: "backup pw", into: repository, name: " Работа (копия) ")
        XCTAssertNotEqual(copy.id, profile.id)
        XCTAssertEqual(copy.name, "Работа (копия)")
        XCTAssertNil(copy.lastLaunchedAt)
        XCTAssertEqual(repository.list().map(\.id), [profile.id, copy.id])
        let originalKey = try repository.profileKey(for: profile.id)
        XCTAssertNotEqual(try repository.profileKey(for: copy.id).rawBytes, originalKey.rawBytes, "a copy shares no key")
        try assertProfileContents(repository, copy.id)
        try assertProfileContents(repository, profile.id)

        // Nothing of the copy opens with the original's key.
        XCTAssertThrowsError(try repository.loadConfiguration(copy.id, key: originalKey))
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: repository.webDataArchiveURL(for: copy.id), key: originalKey,
                                                                  resolveDestination: { _ in self.root.appendingPathComponent("x") }))

        // Explicit copy into a vault that does not have the profile.
        let other = try makeOtherRepository()
        let otherCopy = try ProfileBackup.restore(from: backup, password: "backup pw", into: other, mode: .copy)
        XCTAssertNotEqual(otherCopy.id, profile.id)
        try assertProfileContents(other, otherCopy.id)
        XCTAssertEqual(try hiddenEntries(repository), [])
    }

    func testReplaceExistingOverwritesAndDeletedIDComesBackAsCopy() throws {
        let profile = try populatedProfile()
        let backup = try exportBackup(profile.id)

        // Change the original, then replace it from the backup.
        try repository.saveConfiguration(ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"), for: profile.id)
        try repository.passwordVault(for: profile.id).upsert(PasswordEntry(origin: "https://later.test", username: "x", password: "y"))
        try repository.rename(profile.id, to: "Renamed")
        let revisionBefore = try repository.summary(for: profile.id).revision
        let replaced = try ProfileBackup.restore(from: backup, password: "backup pw", into: repository, mode: .replaceExisting)
        XCTAssertEqual(replaced.id, profile.id)
        XCTAssertEqual(replaced.name, "Работа")
        XCTAssertGreaterThan(replaced.revision, revisionBefore, "sync sees the replacement as a change")
        XCTAssertEqual(repository.list().count, 1)
        try assertProfileContents(repository, profile.id)
        XCTAssertEqual(try hiddenEntries(repository), [], "the replaced directory is removed")

        // A deleted profile's ID is never reused (sync tombstone): it comes back as a copy.
        try repository.delete(profile.id)
        XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "backup pw", into: repository, mode: .replaceExisting)) {
            XCTAssertEqual($0 as? CoreError, .profileNotFound(profile.id))
        }
        let revived = try ProfileBackup.restore(from: backup, password: "backup pw", into: repository)
        XCTAssertNotEqual(revived.id, profile.id)
        try assertProfileContents(repository, revived.id)
    }

    func testTamperedOrTruncatedBackupChangesNothing() throws {
        let profile = try populatedProfile()
        let backup = try exportBackup(profile.id)
        let original = try Data(contentsOf: backup)
        let other = try makeOtherRepository()
        let configBefore = try Data(contentsOf: repository.configURL(for: profile.id))

        var flipped = original
        flipped[original.count - 40] ^= 0x80
        var flippedEarly = original
        flippedEarly[original.count / 2] ^= 0x01
        for broken in [flipped, flippedEarly, original.prefix(original.count - 20), original + Data([0]), original.prefix(30)] {
            try Data(broken).write(to: backup)
            XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "backup pw", into: other))
            XCTAssertTrue(other.list().isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.profilesDirectory.path), [])
            // Replacing an existing profile from a broken backup leaves it untouched.
            XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "backup pw", into: repository, mode: .replaceExisting))
            XCTAssertEqual(try Data(contentsOf: repository.configURL(for: profile.id)), configBefore)
            XCTAssertEqual(repository.list().map(\.id), [profile.id])
            XCTAssertEqual(try hiddenEntries(repository), [])
        }
        try assertProfileContents(repository, profile.id)
    }

    func testWrongPasswordAndBadInputsFailCleanly() throws {
        let profile = try populatedProfile()
        let backup = try exportBackup(profile.id)
        let other = try makeOtherRepository()

        XCTAssertThrowsError(try ProfileBackup.inspect(backup, password: "nope")) {
            XCTAssertEqual($0 as? CoreError, .wrongPassword)
        }
        XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "nope", into: other)) {
            XCTAssertEqual($0 as? CoreError, .wrongPassword)
        }
        XCTAssertTrue(other.list().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.profilesDirectory.path), [])

        // Not a backup at all.
        let notBackup = root.appendingPathComponent("plain.\(ProfileBackup.fileExtension)")
        try Data("PBSA but not really a backup".utf8).write(to: notBackup)
        XCTAssertThrowsError(try ProfileBackup.inspect(notBackup, password: "backup pw")) {
            XCTAssertEqual($0 as? CoreError, .unsupportedFormat("not a profile backup"))
        }
        XCTAssertThrowsError(try ProfileBackup.inspect(root.appendingPathComponent("missing"), password: "x")) {
            guard case .io? = $0 as? CoreError else { return XCTFail("\($0)") }
        }

        // Export: empty password, unknown profile — no file is left behind.
        let target = root.appendingPathComponent("never.\(ProfileBackup.fileExtension)")
        XCTAssertThrowsError(try ProfileBackup.export(profile: profile.id, from: repository, to: target, password: "",
                                                      iterations: testIterations)) {
            guard case .invalidConfiguration? = $0 as? CoreError else { return XCTFail("\($0)") }
        }
        let unknown = UUID()
        XCTAssertThrowsError(try ProfileBackup.export(profile: unknown, from: repository, to: target, password: "pw",
                                                      iterations: testIterations)) {
            XCTAssertEqual($0 as? CoreError, .profileNotFound(unknown))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // A name that would be rejected by `create` is rejected before anything is unpacked.
        XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "backup pw", into: other, name: "   "))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.profilesDirectory.path), [])
    }

    /// A backup written by a build with more per-profile data (e.g. an encrypted `downloads/`
    /// directory) restores what this build knows; hostile entry names are refused.
    func testUnknownEntriesAreSkippedAndUnsafeNamesRejected() throws {
        let profile = try repository.create(name: "P", configuration: configuration)
        let key = try repository.profileKey(for: profile.id)
        let configURL = repository.configURL(for: profile.id)
        let extra = root.appendingPathComponent("extra.bin")
        try Data("opaque newer-build data".utf8).write(to: extra)

        func craft(extraName: String) throws -> URL {
            let configSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: configURL.path)[.size] as? NSNumber).uint64Value
            let files = [ProfileBackup.Manifest.File(name: "config.bin", size: configSize),
                         ProfileBackup.Manifest.File(name: extraName, size: 23)]
            let info = ProfileBackupInfo(profileID: profile.id, name: "P", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                         exportedAt: Date(timeIntervalSince1970: 1_700_000_000), fileCount: 2, totalBytes: configSize + 23)
            let manifest = ProfileBackup.Manifest(format: 1, info: info, lastLaunchedAt: nil, profileKey: key.rawBytes, files: files)
            let handles = try [FileHandle(forReadingFrom: configURL), FileHandle(forReadingFrom: extra)]
            defer { handles.forEach { try? $0.close() } }
            let url = root.appendingPathComponent("crafted-\(UUID().uuidString).\(ProfileBackup.fileExtension)")
            try ProfileBackup.write(manifest, sources: handles, to: url, password: "pw", iterations: testIterations)
            return url
        }

        let other = try makeOtherRepository()
        let restored = try ProfileBackup.restore(from: craft(extraName: "downloads/index.bin"), password: "pw", into: other)
        XCTAssertEqual(restored.id, profile.id)
        XCTAssertEqual(try other.loadConfiguration(profile.id), configuration)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.directory(for: profile.id).path), ["config.bin"])

        let third = try makeOtherRepository("third-vault")
        for hostile in ["../escape.bin", "/abs.bin", "downloads/../../x", "a//b"] {
            XCTAssertThrowsError(try ProfileBackup.restore(from: craft(extraName: hostile), password: "pw", into: third)) {
                XCTAssertEqual($0 as? CoreError, .unsafeArchivePath("backup entry"))
            }
        }
        XCTAssertTrue(third.list().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: third.profilesDirectory.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.root.deletingLastPathComponent().appendingPathComponent("escape.bin").path))
    }

    /// A session file that is not written under `ProfileFileBinding.session` (another build's
    /// format) is kept when the profile keeps its ID, and dropped — not fatal — from a copy.
    func testForeignSessionFileIsKeptForSameProfileAndDroppedFromCopy() throws {
        let profile = try repository.create(name: "P", configuration: configuration)
        let foreign = try AEAD.seal(Data("tabs".utf8), key: SymmetricKey(size: .bits256), aad: "other-format")
        try SecureFile.write(foreign, to: repository.directory(for: profile.id).appendingPathComponent("session.bin"))
        let backup = try exportBackup(profile.id)

        let other = try makeOtherRepository()
        try ProfileBackup.restore(from: backup, password: "backup pw", into: other)
        XCTAssertEqual(try Data(contentsOf: other.directory(for: profile.id).appendingPathComponent("session.bin")), foreign)

        let copy = try ProfileBackup.restore(from: backup, password: "backup pw", into: repository, mode: .copy)
        XCTAssertEqual(try repository.loadConfiguration(copy.id), configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: copy.id).appendingPathComponent("session.bin").path))
    }

    func testInterruptedRestoreIsCleanedUpOnNextStart() throws {
        let profile = try populatedProfile()
        let profiles = repository.profilesDirectory
        // Crash after the old directory was moved aside, before the new one arrived.
        let aside = profiles.appendingPathComponent(".replaced-\(profile.id.uuidString)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: repository.directory(for: profile.id), to: aside)
        // Crash while unpacking.
        let staging = profiles.appendingPathComponent(".restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Crash after the replacement arrived, before the old directory was removed.
        let second = try repository.create(name: "Second", configuration: ProfileConfiguration())
        let staleAside = profiles.appendingPathComponent(".replaced-\(second.id.uuidString)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staleAside, withIntermediateDirectories: true)

        repository.removeOrphanedDirectories()
        XCTAssertEqual(try hiddenEntries(repository), [])
        try assertProfileContents(repository, profile.id)
        XCTAssertNoThrow(try repository.loadConfiguration(second.id))
    }
}

final class ProfileDuplicateTests: ProfileFilesFixture {
    func testDuplicateCopiesSettingsAndBookmarksOnly() throws {
        let source = try populatedProfile()
        let sourceKey = try repository.profileKey(for: source.id)
        let bookmarks = try repository.bookmarkStore(for: source.id, key: sourceKey)
        let removed = try bookmarks.add(title: "Gone", url: URL(string: "https://example.com/gone")!)
        try bookmarks.remove(id: removed.id)

        let duplicate = try repository.duplicate(source.id, name: "  Работа 2 ")
        XCTAssertEqual(duplicate.name, "Работа 2")
        XCTAssertNotEqual(duplicate.id, source.id)
        XCTAssertEqual(duplicate.revision, 1)
        XCTAssertNil(duplicate.lastLaunchedAt)
        let key = try repository.profileKey(for: duplicate.id)
        XCTAssertNotEqual(key.rawBytes, sourceKey.rawBytes)

        XCTAssertEqual(try repository.loadConfiguration(duplicate.id), configuration)
        XCTAssertEqual(try repository.bookmarkStore(for: duplicate.id, key: key).all().map(\.title), ["B"])
        let document = try XCTUnwrap(BookmarkStore.file(url: repository.bookmarksURL(for: duplicate.id), profileID: duplicate.id,
                                                         profileKey: key).load())
        XCTAssertTrue(document.deleted.isEmpty, "the source's tombstones are not carried over")

        // Fresh, isolated data: nothing else exists for the duplicate.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: duplicate.id).path)),
                       ["config.bin", "bookmarks.bin"])
        XCTAssertTrue(try repository.passwordVault(for: duplicate.id).allEntries().isEmpty)
        XCTAssertTrue(try repository.historyStore(for: duplicate.id, key: key).entries().isEmpty)
        XCTAssertNil(try sessionFile(repository, duplicate.id, key: key).load())

        // The copies are bound to the duplicate: they do not open as the source's files.
        XCTAssertThrowsError(try repository.loadConfiguration(duplicate.id, key: sourceKey))

        // The source is untouched, and both survive a restart.
        try assertProfileContents(repository, source.id)
        let reopened = try ProfileRepository(vault: MasterVault.unlock(in: root, password: "master"))
        XCTAssertEqual(Set(reopened.list().map(\.id)), [source.id, duplicate.id])
        XCTAssertEqual(try reopened.loadConfiguration(duplicate.id), configuration)
    }

    func testDuplicateWithoutBookmarksAndValidation() throws {
        let source = try populatedProfile()
        let duplicate = try repository.duplicate(source.id, name: "Clean", copyBookmarks: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: duplicate.id).path), ["config.bin"])
        XCTAssertTrue(try repository.bookmarkStore(for: duplicate.id, key: repository.profileKey(for: duplicate.id)).all().isEmpty)
        XCTAssertEqual(try repository.loadConfiguration(duplicate.id), configuration)

        // A source without bookmarks duplicates fine with copyBookmarks: true.
        let bare = try repository.create(name: "Bare", configuration: ProfileConfiguration())
        let bareCopy = try repository.duplicate(bare.id, name: "Bare 2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.directory(for: bareCopy.id).path), ["config.bin"])

        // Invalid name or unknown source: nothing is created.
        let before = repository.list()
        let directoriesBefore = try FileManager.default.contentsOfDirectory(atPath: repository.profilesDirectory.path).sorted()
        XCTAssertThrowsError(try repository.duplicate(source.id, name: "   ")) {
            guard case .invalidConfiguration? = $0 as? CoreError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try repository.duplicate(source.id, name: String(repeating: "x", count: 129)))
        let unknown = UUID()
        XCTAssertThrowsError(try repository.duplicate(unknown, name: "X")) {
            XCTAssertEqual($0 as? CoreError, .profileNotFound(unknown))
        }
        XCTAssertEqual(repository.list(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.profilesDirectory.path).sorted(), directoriesBefore)
    }
}

final class StreamRekeyTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChunkStreamPurposeSeparationAndReadAvailable() throws {
        let key = SymmetricKey(size: .bits256)
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let url = root.appendingPathComponent("stream.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let writer = try EncryptedChunkWriter(handle: handle, key: key, chunkSize: 4096, info: "profile-backup")
            try writer.write(payload)
            try writer.finish()
        }

        // Same key, other purpose (the WebKit archive default): does not open.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let reader = try EncryptedChunkReader(handle: handle, key: key)
            XCTAssertThrowsError(try reader.read(1)) { XCTAssertEqual($0 as? CoreError, .authenticationFailed) }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let reader = try EncryptedChunkReader(handle: handle, key: key, info: "profile-backup")
        XCTAssertEqual(try reader.read(10), payload.prefix(10))
        var pieces: [Data] = []
        while let piece = try reader.readAvailable() { pieces.append(piece) }
        XCTAssertEqual(pieces.first?.count, 4096 - 10, "the rest of the first chunk")
        XCTAssertEqual(payload.prefix(10) + pieces.reduce(Data(), +), payload)
        XCTAssertNil(try reader.readAvailable())
        XCTAssertNoThrow(try reader.finish())
    }

    func testResealRekeysAndRelabelsWithoutPlaintextOnFailure() throws {
        let oldID = UUID(), newID = UUID()
        let oldKey = SymmetricKey(size: .bits256), newKey = SymmetricKey(size: .bits256)
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("IndexedDB/origin"), withIntermediateDirectories: true)
        let big = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try big.write(to: source.appendingPathComponent("IndexedDB/origin/db.sqlite3"))
        try Data("c".utf8).write(to: source.appendingPathComponent("Cookies.binarycookies"))
        let oldLabel = "WebKit|WebsiteDataStore|\(oldID.uuidString.lowercased())"
        let archive = root.appendingPathComponent("webdata.pbsa")
        try EncryptedDirectoryArchive.seal(roots: [oldLabel: source], to: archive, key: oldKey, chunkSize: 64 * 1024)

        let resealed = root.appendingPathComponent("copy.pbsa")
        let stats = try EncryptedDirectoryArchive.reseal(from: archive, key: oldKey, to: resealed, newKey: newKey) {
            try WebKitDataLayout.relabel($0, from: oldID, to: newID)
        }
        XCTAssertEqual(stats.files, 2)
        XCTAssertEqual(stats.bytes, UInt64(big.count + 1))
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: resealed, key: oldKey, resolveDestination: { _ in self.root }))

        var labels: [String] = []
        let out = root.appendingPathComponent("out")
        try EncryptedDirectoryArchive.unseal(from: resealed, key: newKey) { labels.append($0); return out }
        XCTAssertEqual(labels, ["WebKit|WebsiteDataStore|\(newID.uuidString.lowercased())"])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("IndexedDB/origin/db.sqlite3")), big)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Cookies.binarycookies")), Data("c".utf8))

        // Tampered source: no output, and an existing destination is left as it was.
        var tampered = try Data(contentsOf: archive)
        tampered[tampered.count - 30] ^= 0x01
        try tampered.write(to: archive)
        let before = try Data(contentsOf: resealed)
        XCTAssertThrowsError(try EncryptedDirectoryArchive.reseal(from: archive, key: oldKey, to: resealed, newKey: newKey) {
            try WebKitDataLayout.relabel($0, from: oldID, to: newID)
        })
        XCTAssertEqual(try Data(contentsOf: resealed), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])
    }

    func testRelabelKeepsCaseAndRejectsOtherProfiles() throws {
        let oldID = UUID(), newID = UUID()
        XCTAssertEqual(try WebKitDataLayout.relabel("Caches|WebKit|WebsiteDataStore|\(oldID.uuidString)", from: oldID, to: newID),
                       "Caches|WebKit|WebsiteDataStore|\(newID.uuidString)")
        XCTAssertEqual(try WebKitDataLayout.relabel("WebKit|b.id|WebsiteDataStore|\(oldID.uuidString.lowercased())", from: oldID, to: newID),
                       "WebKit|b.id|WebsiteDataStore|\(newID.uuidString.lowercased())")
        XCTAssertThrowsError(try WebKitDataLayout.relabel("WebKit|WebsiteDataStore|\(UUID().uuidString)", from: oldID, to: newID))
        XCTAssertThrowsError(try WebKitDataLayout.relabel(oldID.uuidString, from: oldID, to: newID))
    }
}
