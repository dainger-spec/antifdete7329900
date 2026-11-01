#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// R8 (docs/DESTRUCTIVE_PATHS.md): an archive is extracted into a hidden staging directory next to
/// where it goes, `.<name>.unseal-<UUID>`, and moved into place once the whole archive has
/// authenticated. A crash or a kill in between leaves part of a profile's plaintext there, which
/// nothing read and nothing removed. Now it is removed — a profile's own before its launch, every
/// profile's at the app's launch and at unlock — and nothing else is.
final class UnsealLeftoversTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-unseal-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func directory(_ path: String, file: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let file { try Data("plaintext".utf8).write(to: url.appendingPathComponent(file)) }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testTheStagingNameIsRecognisedAndNothingElseIs() {
        let destination = URL(fileURLWithPath: "/x/WebsiteDataStore/9F0C2A55-0B3B-4C1E-8C61-3F7A1E5D2B10")
        let staged = EncryptedDirectoryArchive.stagingDirectory(for: destination)
        XCTAssertEqual(staged.deletingLastPathComponent().path, "/x/WebsiteDataStore")
        XCTAssertEqual(EncryptedDirectoryArchive.stagedDestinationName(staged.lastPathComponent),
                       "9F0C2A55-0B3B-4C1E-8C61-3F7A1E5D2B10")
        XCTAssertEqual(EncryptedDirectoryArchive.stagedDestinationName(".home.noindex.unseal-\(UUID().uuidString)"), "home.noindex")
        for name in ["9F0C2A55-0B3B-4C1E-8C61-3F7A1E5D2B10", ".hidden", "home.noindex.unseal-\(UUID().uuidString)",
                     ".home.noindex.unseal-not-a-uuid", "..unseal-\(UUID().uuidString)", ".home.noindex.unseal-"] {
            XCTAssertNil(EncryptedDirectoryArchive.stagedDestinationName(name), name)
        }
    }

    /// What an interrupted unseal left goes — the profile's own when one is named, every one
    /// otherwise — and nothing else: not the profiles' data, not another hidden folder, not what a
    /// symbolic link points to, not a folder inside a store.
    func testOnlyWhatAnUnsealLeftIsRemoved() throws {
        let a = UUID(), b = UUID()
        let data = try directory("WebKit/app/WebsiteDataStore/\(a.uuidString)", file: "localstorage.sqlite3")
        let leftA = try directory("WebKit/app/WebsiteDataStore/.\(a.uuidString).unseal-\(UUID().uuidString)", file: "part")
        let leftACaches = try directory("Caches/app/WebKit/WebsiteDataStore/.\(a.uuidString.lowercased()).unseal-\(UUID().uuidString)", file: "part")
        let leftB = try directory("WebKit/app/WebsiteDataStore/.\(b.uuidString).unseal-\(UUID().uuidString)", file: "part")
        let hidden = try directory("WebKit/app/WebsiteDataStore/.hidden", file: "kept")
        let insideAStore = try directory("WebKit/app/WebsiteDataStore/\(a.uuidString)/.\(b.uuidString).unseal-\(UUID().uuidString)", file: "kept")
        let elsewhere = try directory("elsewhere", file: "kept")
        let link = root.appendingPathComponent("WebKit/app/WebsiteDataStore/.\(b.uuidString).unseal-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let roots = [root.appendingPathComponent("WebKit/app"), root.appendingPathComponent("Caches/app")]

        let first = EncryptedDirectoryArchive.removeStagingLeftovers(below: roots, depth: 4, destinationNamed: a.uuidString)
        XCTAssertEqual(first.removed, 2)
        XCTAssertEqual(first.failed, 0)
        XCTAssertFalse(exists(leftA))
        XCTAssertFalse(exists(leftACaches), "the name is matched whatever its case")
        XCTAssertTrue(exists(leftB), "another profile's is left to its own launch, or to unlock")

        let all = EncryptedDirectoryArchive.removeStagingLeftovers(below: roots, depth: 4)
        XCTAssertEqual(all.removed, 1)
        XCTAssertFalse(exists(leftB))
        for kept in [data.appendingPathComponent("localstorage.sqlite3"), hidden.appendingPathComponent("kept"),
                     insideAStore.appendingPathComponent("kept"), elsewhere.appendingPathComponent("kept")] {
            XCTAssertTrue(exists(kept), kept.path)
        }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "the link is not removed")
        XCTAssertEqual(EncryptedDirectoryArchive.removeStagingLeftovers(below: roots, depth: 4).removed, 0)
    }

    /// The layout's roots, as the app's WebKit data has them: the general storage and the cache.
    func testTheLayoutRemovesWhatAnUnsealOfWebKitDataLeft() throws {
        let profile = UUID()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let layout = WebKitDataLayout(library: library, bundleID: "io.example.app", sandboxed: false)
        let stores = [try layout.destination(forLabel: "WebKit|WebsiteDataStore|\(profile.uuidString)", profileID: profile),
                      try layout.destination(forLabel: "Caches|WebKit|WebsiteDataStore|\(profile.uuidString)", profileID: profile)]
        var left: [URL] = []
        for store in stores {
            let staged = EncryptedDirectoryArchive.stagingDirectory(for: store)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("part".utf8).write(to: staged.appendingPathComponent("part"))
            left.append(staged)
        }
        XCTAssertEqual(layout.removeUnsealLeftovers(of: UUID()).removed, 0, "another profile's launch leaves them")
        XCTAssertEqual(layout.removeUnsealLeftovers(of: profile).removed, 2)
        XCTAssertTrue(left.allSatisfy { !exists($0) })
    }

    /// A finished unseal leaves nothing behind, and one that fails removes what it extracted: the
    /// leftovers are only a crash's or a kill's.
    func testAFinishedOrFailedUnsealLeavesNoStagingDirectory() throws {
        let source = try directory("source/data", file: "file")
        let archive = root.appendingPathComponent("data.pbsa")
        let key = SymmetricKey(size: .bits256)
        try EncryptedDirectoryArchive.seal(roots: ["data": source], to: archive, key: key)
        let destination = root.appendingPathComponent("restore/data", isDirectory: true)
        try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": destination])
        XCTAssertTrue(exists(destination.appendingPathComponent("file")))
        var damaged = try Data(contentsOf: archive)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: archive)
        let again = root.appendingPathComponent("restore/again", isDirectory: true)
        XCTAssertThrowsError(try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": again]))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("restore").path)
        XCTAssertEqual(names, ["data"])
    }
}
