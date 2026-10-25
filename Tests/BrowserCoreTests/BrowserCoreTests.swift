import XCTest
@testable import BrowserCore

/// Low iteration count keeps tests fast; production uses `KDFParameters.recommendedIterations`.
private let testIterations = 1_000

final class KeyDerivationTests: XCTestCase {
    /// RFC 7914 §11, PBKDF2-HMAC-SHA256 test vector.
    func testPBKDF2MatchesRFC7914Vector() throws {
        let derived = try KeyDerivation.pbkdf2SHA256(password: Data("passwd".utf8), salt: Data("salt".utf8),
                                                     iterations: 1, keyLength: 64)
        XCTAssertEqual(derived.hex, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        let portable = KeyDerivation.portablePBKDF2SHA256(password: Data("passwd".utf8), salt: Data("salt".utf8),
                                                          iterations: 1, keyLength: 64)
        XCTAssertEqual(portable, derived)
    }

    func testPortableMatchesPlatformForManyIterations() throws {
        let salt = Data(repeating: 7, count: 16)
        XCTAssertEqual(KeyDerivation.portablePBKDF2SHA256(password: Data("pw".utf8), salt: salt, iterations: 4096, keyLength: 32),
                       try KeyDerivation.pbkdf2SHA256(password: Data("pw".utf8), salt: salt, iterations: 4096, keyLength: 32))
    }
}

final class VaultTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateUnlockAndWrongPassword() throws {
        let created = try MasterVault.create(in: root, password: "correct horse", iterations: testIterations)
        let unlocked = try MasterVault.unlock(in: root, password: "correct horse")
        XCTAssertEqual(created.vaultID, unlocked.vaultID)
        XCTAssertEqual(created.indexKey.rawBytes, unlocked.indexKey.rawBytes)
        XCTAssertThrowsError(try MasterVault.unlock(in: root, password: "wrong")) {
            XCTAssertEqual($0 as? CoreError, .wrongPassword)
        }
        XCTAssertThrowsError(try MasterVault.create(in: root, password: "x", iterations: testIterations))
    }

    func testChangePasswordKeepsData() throws {
        let vault = try MasterVault.create(in: root, password: "old", iterations: testIterations)
        let repo = try ProfileRepository(vault: vault)
        let profile = try repo.create(name: "Work", configuration: ProfileConfiguration(timeZoneIdentifier: "Europe/Berlin"))

        XCTAssertThrowsError(try vault.changePassword(current: "nope", new: "new", iterations: testIterations))
        try vault.changePassword(current: "old", new: "new", iterations: testIterations)

        XCTAssertThrowsError(try MasterVault.unlock(in: root, password: "old"))
        let reopened = try ProfileRepository(vault: MasterVault.unlock(in: root, password: "new"))
        XCTAssertEqual(try reopened.loadConfiguration(profile.id).timeZoneIdentifier, "Europe/Berlin")
    }
}

final class ProfileRepositoryTests: XCTestCase {
    var root: URL!
    var repo: ProfileRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-test-\(UUID().uuidString)")
        repo = try ProfileRepository(vault: MasterVault.create(in: root, password: "pw", iterations: testIterations))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateListReloadRenameDelete() throws {
        let config = ProfileConfiguration(
            startURL: URL(string: "https://example.com"),
            userAgent: "Mozilla/5.0 Test",
            proxy: ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080, username: "u", password: "p"),
            geolocation: .fixed(latitude: 52.52, longitude: 13.40, accuracyMeters: 50),
            timeZoneIdentifier: "Europe/Berlin",
            webRTCPolicy: .relayOnly)
        let a = try repo.create(name: "  Alpha ", configuration: config)
        let b = try repo.create(name: "Beta", configuration: ProfileConfiguration())
        XCTAssertEqual(a.name, "Alpha")
        XCTAssertEqual(repo.list().map(\.id), [a.id, b.id])

        let reopened = try ProfileRepository(vault: MasterVault.unlock(in: root, password: "pw"))
        XCTAssertEqual(reopened.list().map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(try reopened.loadConfiguration(a.id), config)

        try reopened.rename(a.id, to: "Alpha 2")
        XCTAssertEqual(try reopened.summary(for: a.id).name, "Alpha 2")
        XCTAssertEqual(try reopened.summary(for: a.id).revision, 2)

        try reopened.delete(b.id)
        XCTAssertEqual(reopened.list().map(\.id), [a.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.directory(for: b.id).path))
        XCTAssertThrowsError(try reopened.loadConfiguration(b.id))
    }

    func testNothingReadableOnDisk() throws {
        let profile = try repo.create(name: "SecretName", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .httpConnect, host: "proxy.internal", port: 3128, username: "alice", password: "hunter2")))
        try repo.passwordVault(for: profile.id).upsert(PasswordEntry(origin: "https://site.test", username: "bob", password: "s3cret"))
        let enumerator = FileManager.default.enumerator(atPath: root.path)!
        for case let path as String in enumerator where !path.hasSuffix("vault.json") {
            let data = (try? Data(contentsOf: root.appendingPathComponent(path))) ?? Data()
            for needle in ["SecretName", "proxy.internal", "hunter2", "alice", "s3cret", "site.test"] {
                XCTAssertNil(data.range(of: Data(needle.utf8)), "\(needle) found in plaintext in \(path)")
            }
        }
    }

    func testSwappedConfigFilesFailAuthentication() throws {
        let a = try repo.create(name: "A", configuration: ProfileConfiguration(timeZoneIdentifier: "UTC"))
        let b = try repo.create(name: "B", configuration: ProfileConfiguration())
        // Same vault, but a config ciphertext is bound to its profile ID and key.
        try FileManager.default.removeItem(at: repo.configURL(for: b.id))
        try FileManager.default.copyItem(at: repo.configURL(for: a.id), to: repo.configURL(for: b.id))
        XCTAssertThrowsError(try repo.loadConfiguration(b.id)) {
            XCTAssertEqual($0 as? CoreError, .authenticationFailed)
        }
    }

    func testValidation() {
        XCTAssertThrowsError(try repo.create(name: "x", configuration: ProfileConfiguration(timeZoneIdentifier: "Mars/Olympus")))
        XCTAssertThrowsError(try repo.create(name: "x", configuration: ProfileConfiguration(
            proxy: ProxySettings(kind: .socks5, host: "h", port: 70000))))
        XCTAssertThrowsError(try repo.create(name: "x", configuration: ProfileConfiguration(userAgent: "bad\nua")))
        XCTAssertThrowsError(try repo.create(name: "x", configuration: ProfileConfiguration(
            geolocation: .fixed(latitude: 91, longitude: 0, accuracyMeters: 10))))
        XCTAssertThrowsError(try repo.create(name: "x", configuration: ProfileConfiguration(startURL: URL(string: "file:///etc/passwd"))))
        XCTAssertThrowsError(try repo.create(name: "   ", configuration: ProfileConfiguration()))
    }

    func testPasswordVault() throws {
        let profile = try repo.create(name: "P", configuration: ProfileConfiguration())
        let vault = try repo.passwordVault(for: profile.id)
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "a", password: "1"))
        try vault.upsert(PasswordEntry(origin: "https://example.com", username: "a", password: "2"))
        try vault.upsert(PasswordEntry(origin: "https://example.com:8443", username: "a", password: "3"))

        let reopened = try repo.passwordVault(for: profile.id)
        XCTAssertEqual(reopened.entries(for: URL(string: "https://EXAMPLE.com:443/login?x")!).map(\.password), ["2"])
        XCTAssertEqual(reopened.entries(for: URL(string: "https://example.com:8443/")!).map(\.password), ["3"])
        XCTAssertTrue(reopened.entries(for: URL(string: "http://example.com/")!).isEmpty)
        XCTAssertTrue(reopened.entries(for: URL(string: "https://sub.example.com/")!).isEmpty)

        try reopened.remove(id: reopened.allEntries()[0].id)
        XCTAssertEqual(try repo.passwordVault(for: profile.id).allEntries().count, 1)
    }
}

final class ArchiveTests: XCTestCase {
    var root: URL!
    let key = SymmetricKeyFactory.make()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTree() throws -> (data: URL, cache: URL, big: Data) {
        let data = root.appendingPathComponent("src-data")
        let cache = root.appendingPathComponent("src-cache")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("IndexedDB/https_example.com_0"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
        let big = secureRandomBytes(300_000)
        try big.write(to: data.appendingPathComponent("IndexedDB/https_example.com_0/db.sqlite3"))
        try Data("cookie=1".utf8).write(to: data.appendingPathComponent("Cookies.binarycookies"))
        try Data().write(to: cache.appendingPathComponent("zero-length"))
        return (data, cache, big)
    }

    func testRoundTrip() throws {
        let (data, cache, big) = try makeTree()
        let archive = root.appendingPathComponent("webdata.pbsa")
        // Small chunk size to exercise multi-chunk streams.
        let sealed = try EncryptedDirectoryArchive.seal(roots: ["data": data, "cache": cache, "missing": root.appendingPathComponent("nope")],
                                                        to: archive, key: key, chunkSize: 4096)
        XCTAssertEqual(sealed.files, 3)

        let outData = root.appendingPathComponent("out-data")
        let outCache = root.appendingPathComponent("out-cache")
        let restored = try EncryptedDirectoryArchive.unseal(from: archive, key: key,
                                                            destinations: ["data": outData, "cache": outCache, "missing": root.appendingPathComponent("out-missing")])
        XCTAssertEqual(restored.files, 3)
        XCTAssertEqual(try Data(contentsOf: outData.appendingPathComponent("IndexedDB/https_example.com_0/db.sqlite3")), big)
        XCTAssertEqual(try Data(contentsOf: outData.appendingPathComponent("Cookies.binarycookies")), Data("cookie=1".utf8))
        XCTAssertEqual(try Data(contentsOf: outCache.appendingPathComponent("zero-length")), Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: outCache.appendingPathComponent("empty-dir").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("out-missing").path))
        // No plaintext in the archive.
        XCTAssertNil(try Data(contentsOf: archive).range(of: Data("cookie=1".utf8)))
    }

    func testTamperingTruncationAndWrongKeyLeaveNoPlaintext() throws {
        let (data, cache, _) = try makeTree()
        let archive = root.appendingPathComponent("webdata.pbsa")
        try EncryptedDirectoryArchive.seal(roots: ["data": data, "cache": cache], to: archive, key: key, chunkSize: 4096)
        let original = try Data(contentsOf: archive)
        let out = root.appendingPathComponent("out")

        var flipped = original
        flipped[original.count / 2] ^= 0x01
        try flipped.write(to: archive)
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": out]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        // Drop the final chunk (a whole record) — must be detected as truncation.
        try original.prefix(original.count - 40).write(to: archive)
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": out]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        try (original + Data([0])).write(to: archive)
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": out]))

        try original.write(to: archive)
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: archive, key: SymmetricKeyFactory.make(), destinations: ["data": out]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        // Unknown root label in archive (no destination given for "cache").
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": out]))
        XCTAssertNoThrow(try EncryptedDirectoryArchive.unseal(from: archive, key: key,
                                                              destinations: ["data": out, "cache": root.appendingPathComponent("oc")]))
    }

    func testSymlinksAreNotFollowed() throws {
        let data = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: data.appendingPathComponent("link").path, withDestinationPath: "/etc")
        let archive = root.appendingPathComponent("a.pbsa")
        let stats = try EncryptedDirectoryArchive.seal(roots: ["data": data], to: archive, key: key)
        XCTAssertEqual(stats.skipped, ["data/link"])
        XCTAssertEqual(stats.files, 0)
    }
}

final class SyncTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pb-sync-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testTwoDevices() async throws {
        let transport = LocalDirectorySyncTransport(directory: base.appendingPathComponent("server"))
        let rootA = base.appendingPathComponent("deviceA")
        let rootB = base.appendingPathComponent("deviceB")

        let repoA = try ProfileRepository(vault: MasterVault.create(in: rootA, password: "pw", iterations: testIterations))
        let profile = try repoA.create(name: "Shared", configuration: ProfileConfiguration(timeZoneIdentifier: "Asia/Tokyo"))
        try repoA.passwordVault(for: profile.id).upsert(PasswordEntry(origin: "https://a.test", username: "u", password: "p"))
        let engineA = SyncEngine(repository: repoA, transport: transport)
        let first = try await engineA.sync()
        XCTAssertEqual(Set(first.pushed), ["index", "profile/\(profile.id.uuidString)/config", "profile/\(profile.id.uuidString)/passwords"])

        // Server contents reveal neither names nor settings.
        for name in try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("server").path) {
            let blob = try Data(contentsOf: base.appendingPathComponent("server/\(name)"))
            XCTAssertNil(blob.range(of: Data("Shared".utf8)))
            XCTAssertNil(blob.range(of: Data("Asia/Tokyo".utf8)))
            XCTAssertNil(blob.range(of: Data("index".utf8)))
        }

        do {
            _ = try await SyncEngine.bootstrap(transport: transport, root: rootB, password: "bad")
            XCTFail("bootstrap with wrong password must fail")
        } catch {
            XCTAssertEqual(error as? CoreError, .wrongPassword)
        }
        let vaultB = try await SyncEngine.bootstrap(transport: transport, root: rootB, password: "pw")
        let repoB = try ProfileRepository(vault: vaultB)
        let engineB = SyncEngine(repository: repoB, transport: transport)
        _ = try await engineB.sync()
        XCTAssertEqual(repoB.list().map(\.name), ["Shared"])
        XCTAssertEqual(try repoB.loadConfiguration(profile.id).timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(try repoB.passwordVault(for: profile.id).allEntries().map(\.password), ["p"])

        // Nothing changed → nothing pushed.
        let idle = try await engineB.sync()
        XCTAssertTrue(idle.pushed.isEmpty && idle.pulled.isEmpty)

        // Concurrent changes: B renames, A adds a profile; index merge keeps both.
        try repoB.rename(profile.id, to: "Renamed")
        let second = try repoA.create(name: "OnlyA", configuration: ProfileConfiguration())
        _ = try await engineB.sync()
        _ = try await engineA.sync()
        _ = try await engineB.sync()
        XCTAssertEqual(Set(repoA.list().map(\.name)), ["Renamed", "OnlyA"])
        XCTAssertEqual(Set(repoB.list().map(\.name)), ["Renamed", "OnlyA"])

        // Deletion propagates and is not resurrected.
        try repoA.delete(second.id)
        _ = try await engineA.sync()
        let report = try await engineB.sync()
        XCTAssertEqual(report.deletedProfileIDs, [second.id])
        XCTAssertEqual(repoB.list().map(\.name), ["Renamed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoB.directory(for: second.id).path))
    }

    func testEnvelopeRejectsMovedBlob() throws {
        let root = base.appendingPathComponent("v")
        let vault = try MasterVault.create(in: root, password: "pw", iterations: testIterations)
        let codec = SyncCodec(vault: vault)
        let blob = try codec.encode(SyncPayload(logicalName: "index", deleted: false, data: Data("x".utf8)), revision: 3)
        XCTAssertEqual(try codec.decode(blob).payload.data, Data("x".utf8))

        var envelope = try JSONDecoder().decode(SyncEnvelope.self, from: blob)
        envelope.revision = 4
        XCTAssertThrowsError(try codec.decode(JSONEncoder().encode(envelope)))
        envelope.revision = 3
        envelope.objectID = codec.objectID(for: "profile/x/config")
        XCTAssertThrowsError(try codec.decode(JSONEncoder().encode(envelope)))
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum SymmetricKeyFactory {
    static func make() -> SymmetricKey { SymmetricKey(size: .bits256) }
}
