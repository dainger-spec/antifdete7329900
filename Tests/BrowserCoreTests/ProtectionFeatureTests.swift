import XCTest
@testable import BrowserCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private let testIterations = 1_000

/// Shared fixture: a temporary vault with one profile.
class VaultFixture: XCTestCase {
    var root: URL!
    var repository: ProfileRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-test-\(UUID().uuidString)")
        repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "master", iterations: testIterations))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func writePlainFile(_ content: Data, name: String = "file.bin") throws -> URL {
        let url = root.appendingPathComponent("plain-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        return url
    }
}

final class DownloadVaultTests: VaultFixture {
    func testImportEncryptsListsExportsAndRemoves() throws {
        let profile = try repository.create(name: "A", configuration: ProfileConfiguration())
        let key = try repository.profileKey(for: profile.id)
        let vault = try repository.downloadVault(for: profile.id, key: key)
        // Several chunks plus a partial one.
        let content = Data((0..<(2_500_000)).map { UInt8(truncatingIfNeeded: $0 &* 31) }) + Data("SECRET-MARKER".utf8)

        let incoming = try vault.makeIncomingURL(suggestedFilename: "../report:final.pdf")
        XCTAssertEqual(incoming.lastPathComponent, "_report_final.pdf")
        XCTAssertTrue(incoming.path.hasPrefix(vault.incomingDirectory.path))
        try content.write(to: incoming)

        let entry = try vault.importFile(at: incoming, filename: incoming.lastPathComponent,
                                         sourceURL: URL(string: "https://user:pw@files.example.com/r.pdf#x"), mimeType: "application/pdf")
        XCTAssertEqual(entry.size, UInt64(content.count))
        XCTAssertEqual(entry.sourceURL, "https://files.example.com/r.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path), "plaintext must be deleted")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.incomingDirectory.path), [],
                       "staging folder must be removed")

        let stored = try Data(contentsOf: vault.fileURL(for: entry.id))
        XCTAssertNil(stored.range(of: Data("SECRET-MARKER".utf8)))
        let index = try Data(contentsOf: repository.downloadsDirectory(for: profile.id).appendingPathComponent("index.bin"))
        XCTAssertNil(index.range(of: Data("report".utf8)), "file names are encrypted too")

        // Reopened with the key: same list; export round-trips.
        let reopened = try repository.downloadVault(for: profile.id, key: key)
        XCTAssertEqual(reopened.list(), [entry])
        let out = root.appendingPathComponent("export.pdf")
        try reopened.export(entry.id, to: out)
        XCTAssertEqual(try Data(contentsOf: out), content)

        try reopened.remove(entry.id)
        XCTAssertTrue(reopened.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.fileURL(for: entry.id).path))
    }

    func testSwappedOrTamperedFilesFailAndLeaveNoOutput() throws {
        let profile = try repository.create(name: "A", configuration: ProfileConfiguration())
        let vault = try repository.downloadVault(for: profile.id, key: repository.profileKey(for: profile.id))
        let a = try vault.importFile(at: writePlainFile(Data("alpha".utf8)), filename: "a.txt")
        let b = try vault.importFile(at: writePlainFile(Data("bravo".utf8)), filename: "b.txt")

        // Swap the two encrypted files: each is bound to its entry ID.
        let aURL = vault.fileURL(for: a.id), bURL = vault.fileURL(for: b.id)
        let aData = try Data(contentsOf: aURL), bData = try Data(contentsOf: bURL)
        try bData.write(to: aURL)
        try aData.write(to: bURL)
        let out = root.appendingPathComponent("out.txt")
        XCTAssertThrowsError(try vault.export(a.id, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        // Flip a byte.
        var tampered = aData
        tampered[tampered.count - 3] ^= 0x01
        try tampered.write(to: aURL)
        XCTAssertThrowsError(try vault.export(a.id, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        // Another profile's key cannot open the index.
        let other = try repository.create(name: "B", configuration: ProfileConfiguration())
        XCTAssertThrowsError(try DownloadVault(directory: repository.downloadsDirectory(for: profile.id), profileID: profile.id,
                                               profileKey: repository.profileKey(for: other.id)))
    }

    func testPurgeIncomingRemovesPartialDownloads() throws {
        let profile = try repository.create(name: "A", configuration: ProfileConfiguration())
        let vault = try repository.downloadVault(for: profile.id, key: repository.profileKey(for: profile.id))
        let partial = try vault.makeIncomingURL(suggestedFilename: "big.iso")
        try Data("partial".utf8).write(to: partial)
        repository.purgeIncomingDownloads(for: profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.incomingDirectory.path))
    }

    func testSanitizedFilename() {
        XCTAssertEqual(DownloadVault.sanitizedFilename(""), "download")
        XCTAssertEqual(DownloadVault.sanitizedFilename("..."), "download")
        XCTAssertEqual(DownloadVault.sanitizedFilename(".hidden"), "hidden")
        XCTAssertEqual(DownloadVault.sanitizedFilename("a/b\\c:d\u{0}e"), "a_b_c_d_e")
        XCTAssertEqual(DownloadVault.sanitizedFilename("Отчёт.pdf"), "Отчёт.pdf")
        let long = DownloadVault.sanitizedFilename(String(repeating: "x", count: 300) + ".tar.gz")
        XCTAssertEqual(long.count, 200)
        XCTAssertTrue(long.hasSuffix(".gz"))
    }
}

final class TrackerBlockingTests: XCTestCase {
    private func rules(_ settings: TrackerBlockingSettings) throws -> [[String: Any]] {
        let json = try XCTUnwrap(ContentBlockerRules.json(for: settings))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    func testOffProducesNoList() {
        XCTAssertNil(ContentBlockerRules.json(for: TrackerBlockingSettings(level: .off, blockedDomains: ["x.example.com"])))
    }

    func testStandardBlocksThirdPartyTrackersOnly() throws {
        let list = try rules(TrackerBlockingSettings(level: .standard))
        XCTAssertEqual(list.count, Set(TrackerDomains.advertising + TrackerDomains.analytics).count)
        let doubleclick = try XCTUnwrap(list.first { ($0["trigger"] as? [String: Any])?["url-filter"] as? String
            == "^[^:]+://+([^:/]+\\.)?doubleclick\\.net[:/]" })
        XCTAssertEqual((doubleclick["trigger"] as? [String: Any])?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual((doubleclick["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertFalse(list.contains { ($0["action"] as? [String: Any])?["type"] as? String == "block-cookies" })
    }

    func testURLFilterMatchesDomainAndSubdomainsOnly() throws {
        // WebKit's content-blocker regex is a subset of ECMAScript regex; NSRegularExpression agrees on it.
        let regex = try NSRegularExpression(pattern: ContentBlockerRules.urlFilter(forDomain: "doubleclick.net"),
                                            options: [.caseInsensitive])
        func matches(_ url: String) -> Bool {
            regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        XCTAssertTrue(matches("https://doubleclick.net/"))
        XCTAssertTrue(matches("https://ad.doubleclick.net/pixel?x=1"))
        XCTAssertTrue(matches("http://stats.g.doubleclick.net:8080/x"))
        XCTAssertTrue(matches("wss://a.b.doubleclick.net/socket"))
        XCTAssertFalse(matches("https://notdoubleclick.net/"))
        XCTAssertFalse(matches("https://doubleclick.net.example.com/"))
        XCTAssertFalse(matches("https://example.com/?u=https://doubleclick.net/"))
    }

    func testStrictAddsSocialAndThirdPartyCookies() throws {
        let list = try rules(TrackerBlockingSettings(level: .strict))
        XCTAssertTrue(list.contains { ($0["trigger"] as? [String: Any])?["url-filter"] as? String
            == ContentBlockerRules.urlFilter(forDomain: "connect.facebook.net") })
        let cookies = try XCTUnwrap(list.last)
        XCTAssertEqual((cookies["action"] as? [String: Any])?["type"] as? String, "block-cookies")
    }

    func testCustomDomainsAndAllowListComeLast() throws {
        let settings = TrackerBlockingSettings(level: .standard, allowedSites: ["news.example.org", "shop.example.com"],
                                               blockedDomains: ["metrics.example.net", "doubleclick.net"])
        XCTAssertNoThrow(try settings.validate())
        let list = try rules(settings)
        XCTAssertEqual(list.filter { ($0["trigger"] as? [String: Any])?["url-filter"] as? String
            == ContentBlockerRules.urlFilter(forDomain: "doubleclick.net") }.count, 1, "duplicates collapse")
        XCTAssertTrue(list.contains { ($0["trigger"] as? [String: Any])?["url-filter"] as? String
            == ContentBlockerRules.urlFilter(forDomain: "metrics.example.net") })
        let last = try XCTUnwrap(list.last)
        XCTAssertEqual((last["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
        XCTAssertEqual((last["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*news.example.org", "*shop.example.com"])
    }

    func testIdentifierFollowsContent() throws {
        let a = try XCTUnwrap(ContentBlockerRules.json(for: TrackerBlockingSettings(level: .standard)))
        let b = try XCTUnwrap(ContentBlockerRules.json(for: TrackerBlockingSettings(level: .strict)))
        XCTAssertEqual(ContentBlockerRules.identifier(for: a), ContentBlockerRules.identifier(for: a))
        XCTAssertNotEqual(ContentBlockerRules.identifier(for: a), ContentBlockerRules.identifier(for: b))
    }

    func testDomainNormalisationAndValidation() {
        XCTAssertEqual(ContentBlockerRules.normalizedDomain(" https://Ads.Example.com:8443/path?q#f "), "ads.example.com")
        XCTAssertEqual(ContentBlockerRules.normalizedDomain("*.example.com."), "example.com")
        XCTAssertEqual(ContentBlockerRules.normalizedDomain("user@tracker.io"), "tracker.io")
        XCTAssertNil(ContentBlockerRules.normalizedDomain("com"))
        XCTAssertNil(ContentBlockerRules.normalizedDomain("bad_domain.com"))
        XCTAssertNil(ContentBlockerRules.normalizedDomain("-x.com"))
        XCTAssertNil(ContentBlockerRules.normalizedDomain("пример.рф"))
        XCTAssertThrowsError(try TrackerBlockingSettings(blockedDomains: ["Example.com"]).validate())
        XCTAssertThrowsError(try ProfileConfiguration(trackerBlocking: TrackerBlockingSettings(allowedSites: ["a b"])).validate())
        for domain in TrackerDomains.advertising + TrackerDomains.analytics + TrackerDomains.social {
            XCTAssertEqual(ContentBlockerRules.normalizedDomain(domain), domain)
        }
    }

    func testOldConfigurationsDecodeWithDefaults() throws {
        let old = Data(#"{"geolocation":{"deny":{}},"webRTCPolicy":"disabled","ephemeral":false}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: old)
        XCTAssertEqual(decoded.trackerBlocking, TrackerBlockingSettings(level: .standard))
        XCTAssertTrue(decoded.encryptDownloads)

        var configuration = ProfileConfiguration(trackerBlocking: TrackerBlockingSettings(level: .strict, allowedSites: ["example.com"]),
                                                 encryptDownloads: false)
        configuration.startURL = URL(string: "https://example.com")
        let roundTrip = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: JSONCoding.encoder.encode(configuration))
        XCTAssertEqual(roundTrip, configuration)
    }
}

final class QuickUnlockTests: VaultFixture {
    func testEnableUnlockDisable() throws {
        let provider = SoftwareQuickUnlockKeyProvider()
        let profile = try repository.create(name: "A", configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"))
        XCTAssertFalse(QuickUnlock.isEnabled(in: root))
        XCTAssertThrowsError(try QuickUnlock.enable(vault: repository.vault, password: "wrong", provider: provider)) {
            XCTAssertEqual($0 as? CoreError, .wrongPassword)
        }
        try QuickUnlock.enable(vault: repository.vault, password: "master", provider: provider)
        XCTAssertTrue(QuickUnlock.isEnabled(in: root))

        let unlocked = try QuickUnlock.unlock(in: root, provider: provider)
        XCTAssertEqual(unlocked.vaultID, repository.vault.vaultID)
        XCTAssertEqual(try ProfileRepository(vault: unlocked).loadConfiguration(profile.id).timeZoneIdentifier, "Asia/Tokyo")

        // Still valid after a master-password change (the VMK does not change).
        try repository.vault.changePassword(current: "master", new: "new master", iterations: testIterations)
        XCTAssertNoThrow(try QuickUnlock.unlock(in: root, provider: provider))

        QuickUnlock.disable(in: root)
        XCTAssertThrowsError(try QuickUnlock.unlock(in: root, provider: provider)) {
            XCTAssertEqual($0 as? CoreError, .vaultNotFound)
        }
    }

    func testRecordIsBoundToDeviceKeyAndVault() throws {
        let provider = SoftwareQuickUnlockKeyProvider()
        try QuickUnlock.enable(vault: repository.vault, password: "master", provider: provider)
        let url = QuickUnlock.recordURL(in: root)
        var record = try JSONCoding.decoder.decode(QuickUnlockRecord.self, from: Data(contentsOf: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("master"))

        // A different device key (e.g. after Touch ID enrolment changed) cannot unwrap.
        var other = record
        other.deviceKey = try provider.createKey().keyData
        try JSONCoding.encoder.encode(other).write(to: url)
        XCTAssertThrowsError(try QuickUnlock.unlock(in: root, provider: provider)) {
            XCTAssertEqual($0 as? CoreError, .authenticationFailed)
        }

        // A record for another vault is refused.
        record.vaultID = UUID()
        try JSONCoding.encoder.encode(record).write(to: url)
        XCTAssertThrowsError(try QuickUnlock.unlock(in: root, provider: provider)) {
            XCTAssertEqual($0 as? CoreError, .authenticationFailed)
        }
    }
}

final class AutoLockSettingsTests: XCTestCase {
    func testIdlePolicyAndTolerantDecoding() throws {
        XCTAssertFalse(AutoLockSettings(idleMinutes: nil).shouldLock(afterIdleSeconds: 1e9))
        XCTAssertFalse(AutoLockSettings(idleMinutes: 5).shouldLock(afterIdleSeconds: 299))
        XCTAssertTrue(AutoLockSettings(idleMinutes: 5).shouldLock(afterIdleSeconds: 300))

        // settings.bin written before auto-lock existed.
        let old = Data(#"{"lastSync":null}"#.utf8)
        let decoded = try JSONCoding.decoder.decode(DeviceSettings.self, from: old)
        XCTAssertNil(decoded.autoLock)
        XCTAssertEqual(decoded.effectiveAutoLock, AutoLockSettings())

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try MasterVault.create(in: root, password: "pw", iterations: testIterations)
        try DeviceSettings(autoLock: AutoLockSettings(idleMinutes: 30, lockOnSleep: false, lockOnScreenLock: true)).save(to: vault)
        XCTAssertEqual(try DeviceSettings.load(from: vault).effectiveAutoLock,
                       AutoLockSettings(idleMinutes: 30, lockOnSleep: false, lockOnScreenLock: true))
    }
}

final class ProfileBackupTests: VaultFixture {
    /// A profile with every kind of file: config, passwords, history, bookmarks, a WebKit archive, a download.
    private func populatedProfile() throws -> (ProfileSummary, DownloadEntry) {
        let profile = try repository.create(name: "Работа", configuration: ProfileConfiguration(
            timeZoneIdentifier: "Europe/Berlin", trackerBlocking: TrackerBlockingSettings(level: .strict)))
        let key = try repository.profileKey(for: profile.id)
        try repository.passwordVault(for: profile.id).upsert(PasswordEntry(origin: "https://example.com", username: "u", password: "p"))
        let history = try repository.historyStore(for: profile.id, key: key)
        _ = history.recordVisit(url: URL(string: "https://example.com/a")!, title: "A")
        try history.save()
        _ = try repository.bookmarkStore(for: profile.id, key: key).add(title: "B", url: URL(string: "https://example.com/b")!)
        let webData = root.appendingPathComponent("webkit-src")
        try FileManager.default.createDirectory(at: webData.appendingPathComponent("LocalStorage"), withIntermediateDirectories: true)
        try Data("cookie-jar".utf8).write(to: webData.appendingPathComponent("LocalStorage/db"))
        try EncryptedDirectoryArchive.seal(roots: ["store": webData], to: repository.webDataArchiveURL(for: profile.id), key: key)
        let download = try repository.downloadVault(for: profile.id, key: key)
            .importFile(at: writePlainFile(Data("downloaded bytes".utf8)), filename: "doc.txt")
        return (profile, download)
    }

    private func assertProfileContents(_ repo: ProfileRepository, _ id: UUID, download: DownloadEntry,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let key = try repo.profileKey(for: id)
        XCTAssertEqual(try repo.loadConfiguration(id).timeZoneIdentifier, "Europe/Berlin", file: file, line: line)
        XCTAssertEqual(try repo.loadConfiguration(id).trackerBlocking.level, .strict, file: file, line: line)
        XCTAssertEqual(try repo.passwordVault(for: id).allEntries().map(\.username), ["u"], file: file, line: line)
        XCTAssertEqual(try repo.historyStore(for: id, key: key).entries(matching: "").map(\.title), ["A"], file: file, line: line)
        XCTAssertEqual(try repo.bookmarkStore(for: id, key: key).all().map(\.title), ["B"], file: file, line: line)
        let restoredWeb = root.appendingPathComponent("webkit-\(UUID().uuidString)")
        try EncryptedDirectoryArchive.unseal(from: repo.webDataArchiveURL(for: id), key: key, destinations: ["store": restoredWeb])
        XCTAssertEqual(try Data(contentsOf: restoredWeb.appendingPathComponent("LocalStorage/db")), Data("cookie-jar".utf8),
                       file: file, line: line)
        let downloads = try repo.downloadVault(for: id, key: key)
        XCTAssertEqual(downloads.list().map(\.filename), [download.filename], file: file, line: line)
        let out = root.appendingPathComponent("dl-\(UUID().uuidString)")
        try downloads.export(download.id, to: out)
        XCTAssertEqual(try Data(contentsOf: out), Data("downloaded bytes".utf8), file: file, line: line)
    }

    func testRoundTripIntoAnotherVaultKeepsID() throws {
        let (profile, download) = try populatedProfile()
        let backup = root.appendingPathComponent("work.\(ProfileBackup.fileExtension)")
        let info = try ProfileBackup.export(profile: profile.id, from: repository, to: backup, password: "backup pw",
                                            iterations: testIterations)
        XCTAssertEqual(info.name, "Работа")
        XCTAssertGreaterThanOrEqual(info.fileCount, 7)

        let bytes = try Data(contentsOf: backup)
        for marker in ["Работа", "example.com", "cookie-jar", "downloaded bytes", "doc.txt"] {
            XCTAssertNil(bytes.range(of: Data(marker.utf8)), "\(marker) must not appear in plaintext")
        }
        XCTAssertThrowsError(try ProfileBackup.inspect(backup, password: "nope")) {
            XCTAssertEqual($0 as? CoreError, .wrongPassword)
        }
        XCTAssertEqual(try ProfileBackup.inspect(backup, password: "backup pw"), info)

        // Another vault with another master password.
        let otherRoot = root.appendingPathComponent("other-vault")
        let other = try ProfileRepository(vault: MasterVault.create(in: otherRoot, password: "different", iterations: testIterations))
        let restored = try ProfileBackup.restore(from: backup, password: "backup pw", into: other)
        XCTAssertEqual(restored.id, profile.id)
        XCTAssertEqual(restored.name, "Работа")
        try assertProfileContents(other, profile.id, download: download)
        XCTAssertEqual(try ProfileRepository(vault: MasterVault.unlock(in: otherRoot, password: "different")).list().map(\.id), [profile.id])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: other.profilesDirectory.path).contains { $0.hasPrefix(".") },
                       "staging directories are cleaned up")
    }

    func testRestoreAsCopyRebindsAndReplaceOverwrites() throws {
        let (profile, download) = try populatedProfile()
        let backup = root.appendingPathComponent("b.\(ProfileBackup.fileExtension)")
        try ProfileBackup.export(profile: profile.id, from: repository, to: backup, password: "pw", iterations: testIterations)

        // Same vault, profile still present → automatic restore makes a copy with a new ID.
        let copy = try ProfileBackup.restore(from: backup, password: "pw", into: repository, name: "Работа (копия)")
        XCTAssertNotEqual(copy.id, profile.id)
        XCTAssertEqual(copy.name, "Работа (копия)")
        try assertProfileContents(repository, copy.id, download: download)
        XCTAssertEqual(repository.list().count, 2)

        // Change the original, then replace it from the backup.
        try repository.saveConfiguration(ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"), for: profile.id)
        let revisionBefore = try repository.summary(for: profile.id).revision
        let replaced = try ProfileBackup.restore(from: backup, password: "pw", into: repository, mode: .replaceExisting)
        XCTAssertEqual(replaced.id, profile.id)
        XCTAssertGreaterThan(replaced.revision, revisionBefore, "sync sees the replacement as a change")
        try assertProfileContents(repository, profile.id, download: download)

        // A deleted profile's ID is never reused (sync tombstone): it comes back as a copy.
        try repository.delete(profile.id)
        let revived = try ProfileBackup.restore(from: backup, password: "pw", into: repository)
        XCTAssertNotEqual(revived.id, profile.id)
        try assertProfileContents(repository, revived.id, download: download)
        XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "pw", into: repository, mode: .replaceExisting))
    }

    func testTamperedOrTruncatedBackupChangesNothing() throws {
        let (profile, _) = try populatedProfile()
        let backup = root.appendingPathComponent("t.\(ProfileBackup.fileExtension)")
        try ProfileBackup.export(profile: profile.id, from: repository, to: backup, password: "pw", iterations: testIterations)
        let original = try Data(contentsOf: backup)
        let otherRoot = root.appendingPathComponent("v2")
        let other = try ProfileRepository(vault: MasterVault.create(in: otherRoot, password: "x", iterations: testIterations))

        var flipped = original
        flipped[original.count - 40] ^= 0x80
        for broken in [flipped, original.prefix(original.count - 20), original + Data([0])] {
            try Data(broken).write(to: backup)
            XCTAssertThrowsError(try ProfileBackup.restore(from: backup, password: "pw", into: other))
            XCTAssertTrue(other.list().isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.profilesDirectory.path), [])
        }
    }
}
