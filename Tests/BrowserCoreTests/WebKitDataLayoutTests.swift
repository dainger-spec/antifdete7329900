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
