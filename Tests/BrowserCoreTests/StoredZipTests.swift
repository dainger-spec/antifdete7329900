import XCTest
@testable import BrowserCore

/// The diagnostics bundle's archive: a ZIP any system opens, read back entry by entry.
final class StoredZipTests: XCTestCase {
    func testCRC32IsTheStandardOne() {
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZip.crc32(Data()), 0)
    }

    func testEntriesReadBackAsWritten() throws {
        let entries = [
            StoredZip.Entry(path: "report.txt", data: Data("PrivacyBrowser 1.0\n✓ checks\n".utf8)),
            StoredZip.Entry(path: "logs/app.txt", data: Data(repeating: 0x41, count: 70_000)),
            StoredZip.Entry(path: "empty.json", data: Data()),
        ]
        let archive = try StoredZip.archive(entries)
        let read = try XCTUnwrap(StoredZip.entries(of: archive))
        XCTAssertEqual(read.map(\.path), entries.map(\.path))
        XCTAssertEqual(read.map(\.data), entries.map(\.data))
    }

    func testAPathThatClimbsOutIsRefused() {
        for path in ["", "/etc/passwd", "../x", "logs/../../x", "a//b", "./a"] {
            XCTAssertThrowsError(try StoredZip.archive([StoredZip.Entry(path: path, data: Data())]), path)
        }
    }

    /// The system's own unzip tests it, where there is one.
    func testUnzipTestsItWithoutAnError() throws {
        let unzip = ["/usr/bin/unzip", "/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let unzip else { throw XCTSkip("no unzip on this system") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pb-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("diagnostics.zip")
        try StoredZip.archive([StoredZip.Entry(path: "report.txt", data: Data("ok\n".utf8)),
                               StoredZip.Entry(path: "logs/ünïcode.txt", data: Data("x".utf8))]).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: unzip)
        process.arguments = ["-t", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip -t")
    }
}
