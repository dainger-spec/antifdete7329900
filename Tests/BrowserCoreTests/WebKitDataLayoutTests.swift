import XCTest
@testable import BrowserCore

final class WebKitDataLayoutTests: XCTestCase {
    var library: URL!
    let bundleID = "dev.local.PrivacyBrowser"
    let profileID = UUID()

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("pb-layout-\(UUID().uuidString)/Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    private func mkdir(_ relative: String) throws -> URL {
        let url = library.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var uuid: String { profileID.uuidString.lowercased() }

    func testDiscoveryAndRoundTripNotSandboxed() throws {
        let layout = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: false)
        let data = try mkdir("WebKit/\(bundleID)/WebsiteDataStore/\(uuid)")
        let cache = try mkdir("Caches/\(bundleID)/WebKit/WebsiteDataStore/\(profileID.uuidString)")
        _ = try mkdir("WebKit/other.app/WebsiteDataStore/\(uuid)") // another app's data: must not be found
        _ = try mkdir("WebKit/\(bundleID)/WebsiteDataStore/\(UUID().uuidString)") // another profile

        let found = layout.discoverDirectories(for: profileID)
        XCTAssertEqual(Set(found.map(\.standardizedFileURL.path)), Set([data, cache].map(\.standardizedFileURL.path)))
        for directory in found {
            XCTAssertEqual(try layout.destination(forLabel: layout.label(for: directory), profileID: profileID).standardizedFileURL.path,
                           directory.standardizedFileURL.path)
        }
    }

    func testDiscoveryAndRoundTripSandboxed() throws {
        let layout = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: true)
        let data = try mkdir("WebKit/WebsiteDataStore/\(uuid)")
        let cache = try mkdir("Caches/WebKit/WebsiteDataStore/\(uuid)")
        let found = layout.discoverDirectories(for: profileID)
        XCTAssertEqual(Set(found.map(\.standardizedFileURL.path)), Set([data, cache].map(\.standardizedFileURL.path)))
        for directory in found {
            XCTAssertEqual(try layout.destination(forLabel: layout.label(for: directory), profileID: profileID).standardizedFileURL.path,
                           directory.standardizedFileURL.path)
        }
    }

    /// An archive sealed by the non-sandboxed build restores into the sandboxed layout and back.
    func testTranslationBetweenLayouts() throws {
        let plain = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: false)
        let boxed = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: true)
        let id = profileID.uuidString
        XCTAssertEqual(try boxed.destination(forLabel: "WebKit|\(bundleID)|WebsiteDataStore|\(id)", profileID: profileID).path,
                       library.appendingPathComponent("WebKit/WebsiteDataStore/\(id)").path)
        XCTAssertEqual(try boxed.destination(forLabel: "Caches|\(bundleID)|WebKit|WebsiteDataStore|\(id)", profileID: profileID).path,
                       library.appendingPathComponent("Caches/WebKit/WebsiteDataStore/\(id)").path)
        XCTAssertEqual(try plain.destination(forLabel: "WebKit|WebsiteDataStore|\(id)", profileID: profileID).path,
                       library.appendingPathComponent("WebKit/\(bundleID)/WebsiteDataStore/\(id)").path)
        // Archive from a build with a different bundle ID.
        XCTAssertEqual(try plain.destination(forLabel: "WebKit|org.old.Browser|WebsiteDataStore|\(id)", profileID: profileID).path,
                       library.appendingPathComponent("WebKit/\(bundleID)/WebsiteDataStore/\(id)").path)
    }

    func testRejectsUnsafeLabels() {
        let layout = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: false)
        let id = profileID.uuidString
        for label in ["WebKit|..|WebsiteDataStore|\(id)",
                      "Documents|x|WebsiteDataStore|\(id)",
                      "WebKit|\(bundleID)|WebsiteDataStore|\(UUID().uuidString)",
                      "WebKit|\(id)",
                      "WebKit|a|b|c|\(id)",
                      "WebKit||WebsiteDataStore|\(id)"] {
            XCTAssertThrowsError(try layout.destination(forLabel: label, profileID: profileID), label)
        }
    }

    func testSymlinkedDirectoriesAreIgnored() throws {
        let layout = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: true)
        let elsewhere = library.deletingLastPathComponent().appendingPathComponent("elsewhere/\(uuid)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let parent = try mkdir("WebKit/WebsiteDataStore")
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent(uuid), withDestinationURL: elsewhere)
        XCTAssertTrue(layout.discoverDirectories(for: profileID).isEmpty)
    }
}

/// A sandboxed build's container, moved to where an unsandboxed build of the same app looks.
final class UnsandboxedMigrationTests: XCTestCase {
    var home: URL!
    let bundleID = "dev.local.PrivacyBrowser"
    var container: URL { home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true) }
    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pb-unsandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheVaultAndCrashResidueMoveOutOfTheContainer() throws {
        let profile = UUID()
        let containerVault = UnsandboxedMigration.vaultFolder(in: container)
        try write("{}", at: MasterVault.headerURL(in: containerVault))
        try write("sealed", at: containerVault.appendingPathComponent("profiles/\(profile.uuidString)/webdata.pbsa"))
        // Unsealed data a crash left in the container's layout.
        try write("cookie", at: container.appendingPathComponent("WebKit/WebsiteDataStore/\(profile.uuidString.lowercased())/Cookies.binarycookies"))

        let moves = UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID)
        XCTAssertEqual(moves.count, 2)
        try UnsandboxedMigration.perform(moves)

        let localVault = UnsandboxedMigration.vaultFolder(in: library)
        XCTAssertTrue(MasterVault.exists(in: localVault))
        XCTAssertFalse(MasterVault.exists(in: containerVault))
        XCTAssertEqual(try String(contentsOf: localVault.appendingPathComponent("profiles/\(profile.uuidString)/webdata.pbsa"), encoding: .utf8), "sealed")
        // Where this build's layout looks for it, so that the next unlock seals it.
        let local = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: false)
        let residue = local.discoverDirectories(for: profile)
        XCTAssertEqual(residue.count, 1)
        XCTAssertTrue(residue[0].path.contains("WebKit/\(bundleID)/WebsiteDataStore/"))
        // Once moved there is nothing left to move.
        XCTAssertTrue(UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID).isEmpty)
    }

    func testAVaultOfThisBuildIsNeverReplaced() throws {
        try write("{}", at: MasterVault.headerURL(in: UnsandboxedMigration.vaultFolder(in: container)))
        try write("{\"mine\":1}", at: MasterVault.headerURL(in: UnsandboxedMigration.vaultFolder(in: library)))
        XCTAssertTrue(UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID).isEmpty)
        // Nor is a folder with anything in it, vault or not.
        try FileManager.default.removeItem(at: MasterVault.headerURL(in: UnsandboxedMigration.vaultFolder(in: library)))
        try write("x", at: UnsandboxedMigration.vaultFolder(in: library).appendingPathComponent("note"))
        XCTAssertTrue(UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID).isEmpty)
    }

    func testNothingToMoveWithoutAContainerVault() throws {
        XCTAssertTrue(UnsandboxedMigration.plan(containerLibrary: container, library: library, bundleID: bundleID).isEmpty)
    }
}
