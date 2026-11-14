#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// A profile exported from one vault and imported into another (`ProfileTransfer`).
final class ProfileTransferTests: XCTestCase {
    var root: URL!
    var source: ProfileRepository!
    var target: ProfileRepository!
    /// Fast key derivation for the file; the app uses Argon2id.
    let fastKDF = KDFParameters.generate(iterations: 1_000)
    let bundleID = "dev.local.PrivacyBrowser"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-transfer-\(UUID().uuidString)")
        source = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent("a"), password: "a", iterations: 1_000))
        target = try ProfileRepository(vault: MasterVault.create(in: root.appendingPathComponent("b"), password: "b", iterations: 1_000))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A profile with something in every part: settings with a proxy, a password, history,
    /// a bookmark, a warm-up plan, sealed website data and Safari's sealed state.
    private func makeProfile() throws -> (id: UUID, cookies: Data) {
        let configuration = ProfileConfiguration(
            startURL: URL(string: "https://example.org/"),
            proxy: ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080, username: "u", password: "p"))
        let id = try source.create(name: "Warmed DE", configuration: configuration).id
        let key = try source.profileKey(for: id)
        try source.passwordVault(for: id).upsert(PasswordEntry(origin: "https://shop.example", username: "me", password: "s3cret"))
        let history = try source.historyStore(for: id, key: key)
        XCTAssertTrue(history.recordVisit(url: URL(string: "https://news.example/a")!, title: "A"))
        try history.save()
        _ = try source.bookmarkStore(for: id, key: key).add(title: "Shop", url: URL(string: "https://shop.example/")!)
        try source.saveWarmUpPlan(WarmUpPlan(addresses: "https://news.example/"), for: id)

        // Website data as WebDataStoreVault seals it: one root per directory WebKit made, named
        // after the store's identifier.
        let staging = root.appendingPathComponent("staging-\(id.uuidString)")
        let store = staging.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let cookies = Data("binary cookies of \(id)".utf8)
        try cookies.write(to: store.appendingPathComponent("Cookies.binarycookies"))
        try EncryptedDirectoryArchive.seal(roots: ["WebKit|\(bundleID)|WebsiteDataStore|\(id.uuidString.lowercased())": store],
                                           to: source.webDataArchiveURL(for: id), key: key)
        let home = staging.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        try Data("safari history".utf8).write(to: home.appendingPathComponent("Library/Safari/History.db"))
        try EncryptedDirectoryArchive.seal(roots: [ProfileTransfer.safariHomeLabel: home],
                                           to: source.safariHomeArchiveURL(for: id), key: key)
        try FileManager.default.removeItem(at: staging)
        return (id, cookies)
    }

    func testAProfileMovesWholeToAnotherVault() throws {
        let (id, cookies) = try makeProfile()
        let file = root.appendingPathComponent("export.\(ProfileTransfer.fileExtension)")
        let exported = try ProfileTransfer.export(id, from: source, to: file, password: "transfer pw", kdf: fastKDF)
        XCTAssertEqual(exported.name, "Warmed DE")
        XCTAssertEqual([exported.passwordCount, exported.historyCount, exported.bookmarkCount], [1, 1, 1])
        XCTAssertTrue(exported.hasWebsiteData && exported.hasSafariState)

        // Nothing of the profile is readable in the file.
        let bytes = try Data(contentsOf: file)
        for secret in ["s3cret", "Warmed DE", "203.0.113.5", "binary cookies", "safari history", "news.example"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(secret) is readable in the export")
        }
        // Read back as written (dates to the second: JSON keeps no more).
        let read = try ProfileTransfer.manifest(of: file, password: "transfer pw")
        XCTAssertEqual(read.name, exported.name)
        XCTAssertEqual(read.configuration, exported.configuration)
        XCTAssertEqual([read.passwordCount, read.historyCount, read.bookmarkCount], [1, 1, 1])
        XCTAssertEqual(read.exportedAt.timeIntervalSince1970, exported.exportedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertThrowsError(try ProfileTransfer.manifest(of: file, password: "wrong"))

        let imported = try ProfileTransfer.importProfile(from: file, password: "transfer pw", into: target)
        XCTAssertNotEqual(imported.id, id, "an imported profile is a new profile")
        XCTAssertEqual(imported.name, "Warmed DE")
        let key = try target.profileKey(for: imported.id)
        let configuration = try target.loadConfiguration(imported.id, key: key)
        XCTAssertEqual(configuration.proxy?.host, "203.0.113.5")
        XCTAssertEqual(configuration.proxy?.password, "p")
        XCTAssertEqual(try target.passwordVault(for: imported.id).allEntries().map(\.password), ["s3cret"])
        XCTAssertEqual(try target.historyStore(for: imported.id, key: key).entries().map(\.url), ["https://news.example/a"])
        XCTAssertEqual(try target.bookmarkStore(for: imported.id, key: key).all().map(\.title), ["Shop"])
        XCTAssertEqual(try target.warmUpPlan(for: imported.id)?.addresses, "https://news.example/")

        // The website data, under the new profile's key and named after it.
        let restored = root.appendingPathComponent("restored")
        var labels: [String] = []
        try EncryptedDirectoryArchive.unseal(from: target.webDataArchiveURL(for: imported.id), key: key) { label in
            labels.append(label)
            return restored.appendingPathComponent(label)
        }
        XCTAssertEqual(labels, ["WebKit|\(bundleID)|WebsiteDataStore|\(imported.id.uuidString.lowercased())"])
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent(labels[0]).appendingPathComponent("Cookies.binarycookies")), cookies)
        let home = root.appendingPathComponent("home")
        try EncryptedDirectoryArchive.unseal(from: target.safariHomeArchiveURL(for: imported.id), key: key,
                                             destinations: [ProfileTransfer.safariHomeLabel: home])
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("Library/Safari/History.db"), encoding: .utf8), "safari history")
    }

    /// APP-08 of the security audit (12 November 2026): a file's settings that send a profile's
    /// loads around its proxy, or let its pages reach this Mac and its network, are not taken — the
    /// import window says which (`LeftOut`) — while the proxy itself and everything else are.
    func testAnImportLeavesOutWhatWouldGoAroundTheProxy() throws {
        let configuration = ProfileConfiguration(
            startURL: URL(string: "https://example.org/"),
            proxy: ProxySettings(kind: .socks5, host: "203.0.113.5", port: 1080, username: "u", password: "p",
                                 excludedDomains: ["t.attacker.example", " ", "cdn.attacker.example"]),
            safeBrowsingEnabled: true, localRequests: .allowed)
        let id = try source.create(name: "Bought", configuration: configuration).id
        let file = root.appendingPathComponent("bought.\(ProfileTransfer.fileExtension)")
        try ProfileTransfer.export(id, from: source, to: file, password: "pw", kdf: fastKDF)

        let manifest = try ProfileTransfer.manifest(of: file, password: "pw")
        let leftOut = ProfileTransfer.LeftOut(of: manifest.configuration)
        XCTAssertEqual(leftOut.directDomains, ["t.attacker.example", "cdn.attacker.example"])
        XCTAssertTrue(leftOut.safeBrowsing && leftOut.localRequests && !leftOut.isEmpty)

        let imported = try ProfileTransfer.importProfile(from: file, password: "pw", into: target)
        let taken = try target.loadConfiguration(imported.id, key: target.profileKey(for: imported.id))
        XCTAssertEqual(taken.proxy?.excludedDomains, [], "nothing of the file goes around the proxy")
        XCTAssertFalse(taken.safeBrowsingEnabled, "Safe Browsing's lookups go around the proxy")
        XCTAssertEqual(taken.localRequests, .protected)
        XCTAssertTrue(ProfileTransfer.LeftOut(of: taken).isEmpty)
        // The rest is the file's.
        XCTAssertEqual(taken.proxy?.host, "203.0.113.5")
        XCTAssertEqual(taken.proxy?.password, "p")
        XCTAssertEqual(taken.startURL, URL(string: "https://example.org/"))

        // A file with none of them: nothing to say.
        XCTAssertTrue(ProfileTransfer.LeftOut(of: ProfileConfiguration()).isEmpty)
    }

    func testTheSameFileImportsTwiceIntoTheVaultItCameFrom() throws {
        let (id, _) = try makeProfile()
        let file = root.appendingPathComponent("again.\(ProfileTransfer.fileExtension)")
        try ProfileTransfer.export(id, from: source, to: file, password: "pw", kdf: fastKDF)
        let first = try ProfileTransfer.importProfile(from: file, password: "pw", into: source, name: "Copy 1")
        let second = try ProfileTransfer.importProfile(from: file, password: "pw", into: source, name: "Copy 2")
        XCTAssertEqual(Set([id, first.id, second.id]).count, 3)
        XCTAssertEqual(source.list().map(\.name).sorted(), ["Copy 1", "Copy 2", "Warmed DE"])
    }

    func testADamagedFileImportsNothing() throws {
        let (id, _) = try makeProfile()
        let file = root.appendingPathComponent("damaged.\(ProfileTransfer.fileExtension)")
        try ProfileTransfer.export(id, from: source, to: file, password: "pw", kdf: fastKDF)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 40] ^= 0xFF // inside the archive's last chunk
        try bytes.write(to: file)
        XCTAssertThrowsError(try ProfileTransfer.importProfile(from: file, password: "pw", into: target))
        XCTAssertTrue(target.list().isEmpty, "a failed import leaves no profile behind")
        XCTAssertThrowsError(try ProfileTransfer.importProfile(from: file, password: "wrong", into: target))
        try Data("not an export".utf8).write(to: file)
        XCTAssertThrowsError(try ProfileTransfer.manifest(of: file, password: "pw"))
    }

    /// A file is read only with a key derivation this app writes: Argon2id within its bounds, or
    /// PBKDF2 up to the iterations the app ever used; anything else is refused as the file is
    /// opened, before a key is derived (APP2-1).
    func testAFileIsReadOnlyWithAKeyDerivationLumenWrites() throws {
        XCTAssertNoThrow(try ProfileTransfer.checkReadable(.recommended()))
        XCTAssertNoThrow(try ProfileTransfer.checkReadable(fastKDF))
        XCTAssertNoThrow(try ProfileTransfer.checkReadable(.generate()))
        let salt = Data(repeating: 3, count: 16)
        for refused in [KDFParameters(algorithm: KDFParameters.pbkdf2SHA256, iterations: KDFParameters.recommendedIterations + 1, salt: salt),
                        KDFParameters(algorithm: KDFParameters.pbkdf2SHA256, iterations: Int.max, salt: salt),
                        KDFParameters(algorithm: KDFParameters.pbkdf2SHA256, iterations: 0, salt: salt),
                        KDFParameters(algorithm: KDFParameters.pbkdf2SHA256, iterations: 1_000, salt: Data(count: 8)),
                        KDFParameters(algorithm: "scrypt", iterations: 1, salt: salt),
                        KDFParameters.argon2idParameters(memoryKiB: 4 * 1024 * 1024, passes: 1, lanes: 1),
                        KDFParameters.argon2idParameters(memoryKiB: 64, passes: 11, lanes: 1)] {
            XCTAssertThrowsError(try ProfileTransfer.checkReadable(refused), "\(refused.algorithm) \(refused.iterations)")
        }

        // A file whose header asks for 50 million PBKDF2 iterations: refused at once, nothing made.
        var header = ProfileTransfer.Header(format: 2, kdf: KDFParameters(algorithm: KDFParameters.pbkdf2SHA256,
                                                                          iterations: 50_000_000, salt: salt), manifest: Data())
        func write(_ header: ProfileTransfer.Header, to file: URL) throws {
            let json = try JSONCoding.encoder.encode(header)
            var bytes = ProfileTransfer.magic
            withUnsafeBytes(of: UInt32(json.count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(json)
            bytes.append(contentsOf: [0, 0, 0, 0])
            try bytes.write(to: file)
        }
        let file = root.appendingPathComponent("costly.\(ProfileTransfer.fileExtension)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(header, to: file)
        XCTAssertThrowsError(try ProfileTransfer.manifest(of: file, password: "pw")) { error in
            XCTAssertEqual(error as? CoreError, .invalidConfiguration("the file's key derivation is not one Lumen writes"))
        }
        XCTAssertThrowsError(try ProfileTransfer.importProfile(from: file, password: "pw", into: target))
        XCTAssertTrue(target.list().isEmpty)
        header.kdf = KDFParameters(algorithm: "scrypt", iterations: 1, salt: salt)
        try write(header, to: file)
        XCTAssertThrowsError(try ProfileTransfer.manifest(of: file, password: "pw")) { error in
            guard case .unsupportedFormat(_)? = error as? CoreError else { return XCTFail("\(error)") }
        }
    }

    func testAProfileWithoutWebsiteDataExportsToo() throws {
        let id = try source.create(name: "Fresh", configuration: ProfileConfiguration()).id
        let file = root.appendingPathComponent("fresh.\(ProfileTransfer.fileExtension)")
        let manifest = try ProfileTransfer.export(id, from: source, to: file, password: "pw", kdf: fastKDF)
        XCTAssertFalse(manifest.hasWebsiteData)
        let imported = try ProfileTransfer.importProfile(from: file, password: "pw", into: target)
        XCTAssertEqual(imported.name, "Fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.webDataArchiveURL(for: imported.id).path))
    }
}
