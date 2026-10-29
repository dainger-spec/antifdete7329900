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
        XCTAssertEqual(try ProfileTransfer.manifest(of: file, password: "transfer pw"), exported)
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
