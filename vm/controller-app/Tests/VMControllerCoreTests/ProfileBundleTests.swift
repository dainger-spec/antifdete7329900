import Foundation
import XCTest
@testable import VMControllerCore

final class ProfileBundleTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testManifestOmitsID() throws {
        let profile = Profile(name: "Work", proxy: "socks5://10.0.0.9:1080", clipboardShared: true, cookieCount: 3)
        let manifest = ProfileManifest(from: profile)
        let json = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        XCTAssertFalse(json.contains(profile.id), "id is host-specific, not exported")
        XCTAssertEqual(manifest.name, "Work")
        XCTAssertEqual(manifest.proxy, "socks5://10.0.0.9:1080")
        XCTAssertTrue(manifest.clipboardShared)
    }

    func testExportThenImportOnAnotherMachine() async throws {
        // Source "machine": a store, a profile with cookies, and a stub VM dir.
        let srcStore = ProfileStore(url: root.appendingPathComponent("src/profiles.json"))
        let srcVMs = root.appendingPathComponent("src/.tart/vms")
        let profile = try srcStore.add(Profile(name: "Work", proxy: "socks5://10.0.0.9:1080", clipboardShared: true))
        let cookieFile = root.appendingPathComponent("c.json")
        try #"[{"domain":"x.com","name":"a","value":"1"}]"#.write(to: cookieFile, atomically: true, encoding: .utf8)
        _ = try srcStore.importCookies(for: profile.id, from: cookieFile)
        let vmDir = srcVMs.appendingPathComponent(profile.vmName)
        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
        try "disk-bytes".write(to: vmDir.appendingPathComponent("disk.img"), atomically: true, encoding: .utf8)
        try "cfg".write(to: vmDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let archive = root.appendingPathComponent("work.tar.gz")
        try await ProfileBundle.export(profile: profile, store: srcStore, vmsDirectory: srcVMs, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // Destination "machine": a fresh store and tart dir.
        let dstStore = ProfileStore(url: root.appendingPathComponent("dst/profiles.json"))
        let dstVMs = root.appendingPathComponent("dst/.tart/vms")
        let imported = try await ProfileBundle.importArchive(archive, store: dstStore, vmsDirectory: dstVMs)

        XCTAssertEqual(imported.name, "Work")
        XCTAssertEqual(imported.proxy, "socks5://10.0.0.9:1080")
        XCTAssertTrue(imported.clipboardShared)
        XCTAssertEqual(imported.cookieCount, 1)
        XCTAssertNotEqual(imported.id, profile.id, "a fresh id on the new machine")

        // Cookies restored.
        let cookies = dstStore.cookiesURL(for: imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookies.path))
        XCTAssertEqual(try JSONDecoder().decode([Cookie].self, from: Data(contentsOf: cookies)).first?.domain, "x.com")

        // VM directory restored under the imported profile's name, contents intact.
        let importedVM = dstVMs.appendingPathComponent(imported.vmName)
        XCTAssertEqual(try String(contentsOf: importedVM.appendingPathComponent("disk.img"), encoding: .utf8), "disk-bytes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedVM.appendingPathComponent("config.json").path))
    }

    func testImportTwiceMakesDistinctNames() async throws {
        let srcStore = ProfileStore(url: root.appendingPathComponent("s/profiles.json"))
        let srcVMs = root.appendingPathComponent("s/.tart/vms")
        let profile = try srcStore.add(Profile(name: "Home"))
        try FileManager.default.createDirectory(at: srcVMs.appendingPathComponent(profile.vmName),
                                                withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("home.tar.gz")
        try await ProfileBundle.export(profile: profile, store: srcStore, vmsDirectory: srcVMs, to: archive)

        let dstStore = ProfileStore(url: root.appendingPathComponent("d/profiles.json"))
        let dstVMs = root.appendingPathComponent("d/.tart/vms")
        let first = try await ProfileBundle.importArchive(archive, store: dstStore, vmsDirectory: dstVMs)
        let second = try await ProfileBundle.importArchive(archive, store: dstStore, vmsDirectory: dstVMs)
        XCTAssertEqual(first.name, "Home")
        XCTAssertEqual(second.name, "Home (импорт 1)")
        XCTAssertEqual(try dstStore.list().count, 2)
    }

    func testImportRejectsNonArchive() async throws {
        let bogus = root.appendingPathComponent("bogus.tar.gz")
        try "not a tar".write(to: bogus, atomically: true, encoding: .utf8)
        let store = ProfileStore(url: root.appendingPathComponent("x/profiles.json"))
        do {
            _ = try await ProfileBundle.importArchive(bogus, store: store, vmsDirectory: root.appendingPathComponent("x/vms"))
            XCTFail("should have thrown")
        } catch {
            // tarFailed or badArchive — either is fine.
        }
    }
}
