import Foundation
import XCTest
@testable import BrowserCore

/// A restore image the person already has, taken into the library in the download's place
/// (`VMImageImport`).
final class VMImageImportTests: XCTestCase {
    private var root: URL!
    private var library: VMLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = VMLibrary(root: root.appendingPathComponent("library", isDirectory: true))
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// A file that looks as an `.ipsw` does: a ZIP archive's first record, then `count` bytes.
    private func image(_ count: Int, name: String = "UniversalMac.ipsw") throws -> (url: URL, bytes: [UInt8]) {
        var bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        var state: UInt32 = 2_463_534_242
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            bytes.append(UInt8(truncatingIfNeeded: state))
        }
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return (url, bytes)
    }

    private final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var progress: [VMImageFetch.Progress] = []
        var result: Result<Void, Error>?
    }

    private func take(_ source: URL, clones: Bool = true, seen: Seen = Seen()) -> Result<Void, Error>? {
        let done = expectation(description: "the copy ends")
        let importer = VMImageImport(source: source, library: library, onProgress: { progress in
            seen.lock.lock()
            seen.progress.append(progress)
            seen.lock.unlock()
        }, onFinish: { result in
            seen.result = result
            done.fulfill()
        })
        importer.clones = clones
        importer.start()
        wait(for: [done], timeout: 60)
        return seen.result
    }

    func testWhatIsNoRestoreImageIsSaidBeforeAppleIsAsked() throws {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(VMImageImport.problem(with: folder, minimumLength: 10), .notAFile)
        XCTAssertEqual(VMImageImport.problem(with: root.appendingPathComponent("nothing.ipsw"), minimumLength: 10), .notAFile)
        let small = try image(100)
        XCTAssertEqual(VMImageImport.problem(with: small.url), .tooSmall(104), "no restore image is that small")
        XCTAssertNil(VMImageImport.problem(with: small.url, minimumLength: 10))
        let text = root.appendingPathComponent("notes.ipsw")
        try Data(String(repeating: "not an archive ", count: 20).utf8).write(to: text)
        XCTAssertEqual(VMImageImport.problem(with: text, minimumLength: 10), .notARestoreImage)
    }

    func testTheFileIsCopiedIntoTheImagesPlaceAndThePersonsOwnIsLeft() throws {
        let source = try image(20 << 20)
        let seen = Seen()
        guard case .success = take(source.url, clones: false, seen: seen) else { return XCTFail("\(String(describing: seen.result))") }
        XCTAssertEqual([UInt8](try Data(contentsOf: library.restoreImageURL)), source.bytes)
        XCTAssertEqual([UInt8](try Data(contentsOf: source.url)), source.bytes, "the person's file was changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.downloadsDirectory.appendingPathComponent("restore.ipsw.importing").path))
        XCTAssertEqual(seen.progress.last?.have, Int64(source.bytes.count))
        XCTAssertEqual(seen.progress.last?.total, Int64(source.bytes.count))
        XCTAssertEqual(library.setupState(), .downloaded, "the setup goes on to the installation, as after a download")
    }

    /// Where the volume clones (APFS), the clone; elsewhere a copy — the same file either way.
    func testAClonedOrCopiedFileIsTheSame() throws {
        let source = try image(3 << 20)
        guard case .success = take(source.url, clones: true) else { return XCTFail() }
        XCTAssertEqual([UInt8](try Data(contentsOf: library.restoreImageURL)), source.bytes)
    }

    /// A download of Lumen's own, paused before, is set aside once the person's file is whole.
    func testAPausedDownloadIsSetAsideOnlyWhenTheFileIsWhole() throws {
        try SecureFile.ensureDirectory(library.downloadsDirectory)
        try Data([1, 2, 3]).write(to: library.partialRestoreImageURL)
        try library.saveDownloadState(VMDownloadState(image: VMRestoreImage(url: URL(string: "https://updates.example/a.ipsw")!,
                                                                         version: "26.1", build: "25B78"),
                                                    expectedLength: 1000, validator: "\"x\""))
        let source = try image(1 << 20)
        guard case .success = take(source.url, clones: false) else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.partialRestoreImageURL.path))
        XCTAssertNil(library.downloadState())
        XCTAssertEqual(library.setupState(), .downloaded)

        // A copy called off leaves the download as it was.
        try Data([1, 2, 3]).write(to: library.partialRestoreImageURL)
        let big = try image(64 << 20, name: "Big.ipsw")
        let done = expectation(description: "nothing is said after a cancel")
        done.isInverted = true
        let importer = VMImageImport(source: big.url, library: library, onProgress: { _ in }, onFinish: { _ in done.fulfill() })
        importer.clones = false
        importer.start()
        importer.cancel()
        wait(for: [done], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.partialRestoreImageURL.path))
        XCTAssertEqual([UInt8](try Data(contentsOf: library.restoreImageURL)), source.bytes, "the image there before was replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: importer.staging.path))
    }

    func testAFileThatIsNotThereFails() {
        guard case .failure = take(root.appendingPathComponent("gone.ipsw"), clones: false) else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.restoreImageURL.path))
    }
}
