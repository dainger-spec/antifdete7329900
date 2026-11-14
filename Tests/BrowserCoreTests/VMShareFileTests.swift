#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import BrowserCore

/// A file of the folder a machine shares with the app is the guest's to make anything of: a link
/// to a file of this Mac's, a pipe that never ends, gigabytes. It is read only when it is a small
/// regular file, and refused by its kind otherwise — at once, never waiting.
final class VMShareFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func refusal<T>(_ result: Result<T, VMShareFile.Refusal>) -> VMShareFile.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    func testASmallTextFileIsRead() throws {
        let status = folder.appendingPathComponent(VMGuestSettings.statusFileName)
        try Data("LUMEN_TOOLS_VERSION=7\nLUMEN_SETUP_DONE=1\n".utf8).write(to: status)
        XCTAssertEqual(try VMShareFile.read(status).get(), "LUMEN_TOOLS_VERSION=7\nLUMEN_SETUP_DONE=1\n")
        let said = try VMGuestStatus.read(from: status).get()
        XCTAssertEqual(said.toolsVersion, 7)
        XCTAssertTrue(said.setupDone)
        XCTAssertTrue(VMShareFile.isRegularFile(status))
        // Exactly the limit is still read; an empty file is empty text.
        let full = folder.appendingPathComponent("full")
        try Data(repeating: 0x41, count: VMShareFile.maximumBytes).write(to: full)
        XCTAssertEqual(try VMShareFile.read(full).get().count, VMShareFile.maximumBytes)
        let empty = folder.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertEqual(try VMShareFile.read(empty).get(), "")
    }

    func testWhatIsNotASmallRegularTextFileIsRefusedByItsKind() throws {
        XCTAssertEqual(refusal(VMShareFile.read(folder.appendingPathComponent("absent"))), .missing)

        // A link — to a file of this Mac's that the guest could never read itself — is not followed.
        let secret = folder.appendingPathComponent("secret")
        try Data("LUMEN_TOOLS_VERSION=9\n".utf8).write(to: secret)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertEqual(refusal(VMShareFile.read(link)), .symbolicLink)
        XCTAssertEqual(refusal(VMGuestStatus.read(from: link)), .symbolicLink)
        XCTAssertFalse(VMShareFile.isRegularFile(link))

        let directory = folder.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(refusal(VMShareFile.read(directory)), .notARegularFile)
        XCTAssertFalse(VMShareFile.isRegularFile(directory))

        // A pipe nobody writes: refused at once, not waited on.
        let pipe = folder.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o644), 0)
        let started = Date()
        XCTAssertEqual(refusal(VMShareFile.read(pipe)), .notARegularFile)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(VMShareFile.isRegularFile(pipe))

        let large = folder.appendingPathComponent("large")
        try Data(repeating: 0x41, count: VMShareFile.maximumBytes + 1).write(to: large)
        XCTAssertEqual(refusal(VMShareFile.read(large)), .tooLarge)
        XCTAssertEqual(refusal(VMShareFile.read(secret, maximumBytes: 4)), .tooLarge)

        let binary = folder.appendingPathComponent("binary")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        XCTAssertEqual(refusal(VMShareFile.read(binary)), .notText)
    }
}
