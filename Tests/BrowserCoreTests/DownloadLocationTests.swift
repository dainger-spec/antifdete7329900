import XCTest
@testable import BrowserCore

final class DownloadLocationTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/pb-downloads/Work", isDirectory: true)

    /// `uniqueFileURL` against a fake folder holding `existing`.
    private func unique(_ suggested: String, existing: Set<String> = []) -> URL {
        DownloadLocation.uniqueFileURL(in: folder, suggestedFilename: suggested) { existing.contains($0.lastPathComponent) }
    }

    private func assertSafeComponent(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(name.isEmpty, file: file, line: line)
        XCTAssertFalse(name.contains("/") || name.contains("\\") || name.contains(":"), name, file: file, line: line)
        XCTAssertFalse(name.hasPrefix("."), name, file: file, line: line)
        XCTAssertFalse(name.hasSuffix(".") || name.hasSuffix(" ") || name.hasPrefix(" "), name, file: file, line: line)
        XCTAssertLessThanOrEqual(name.utf8.count, 255, file: file, line: line)
        XCTAssertFalse(name.unicodeScalars.contains { $0.properties.generalCategory == .control }, name, file: file, line: line)
    }

    // MARK: Folder names

    func testFolderNameSanitizing() {
        let cases: [(String, String)] = [
            ("Work", "Work"),
            ("Клиент: Иванов", "Клиент Иванов"),
            ("a/b\\c:d", "a b c d"),
            ("  .hidden  ", "hidden"),
            ("..", "Profile"),
            ("...", "Profile"),
            ("", "Profile"),
            ("   \t\n ", "Profile"),
            ("name...", "name"),
            ("trailing . . ", "trailing"),
            (". .x. .", "x"),
            ("tab\tand\nnewline", "tab and newline"),
            ("many     spaces\u{00A0}\u{3000}here", "many spaces here"),
            ("bell\u{07}\u{7F}\u{0}char", "bellchar"),
            ("abc\u{202E}gpj.exe", "abcgpj.exe"),
            ("../../etc", "etc"),
        ]
        for (input, expected) in cases {
            let name = DownloadLocation.folderName(forProfileName: input)
            XCTAssertEqual(name, expected, input.debugDescription)
            assertSafeComponent(name)
        }
    }

    func testFolderNameLengthLimitKeepsWholeCharacters() {
        let long = String(repeating: "Проект ", count: 40)
        let name = DownloadLocation.folderName(forProfileName: long)
        XCTAssertLessThanOrEqual(name.count, 80)
        XCTAssertTrue(long.hasPrefix(name))
        assertSafeComponent(name)

        // Family emoji: 18 UTF-8 bytes per grapheme. 80 of them would be 1440 bytes, so the
        // byte limit applies, and no grapheme is split.
        let family = "👨‍👩‍👧"
        let emoji = DownloadLocation.folderName(forProfileName: String(repeating: family, count: 100))
        XCTAssertLessThanOrEqual(emoji.utf8.count, 255)
        XCTAssertGreaterThan(emoji.count, 0)
        XCTAssertTrue(emoji.allSatisfy { $0 == Character(family) })
        XCTAssertEqual(emoji.count, 255 / family.utf8.count)

        let accented = String(repeating: "e\u{301}", count: 100) // decomposed é: one Character, 3 bytes
        let cut = DownloadLocation.folderName(forProfileName: accented)
        XCTAssertEqual(cut.count, 80)
        XCTAssertTrue(cut.unicodeScalars.last == "\u{301}", "combining mark stays with its base")
    }

    func testProfileFolder() {
        let base = URL(fileURLWithPath: "/Users/me/Downloads", isDirectory: true)
        XCTAssertEqual(DownloadLocation.profileFolder(base: base, profileName: "Work/Home").path,
                       "/Users/me/Downloads/PrivacyBrowser/Work Home")
        XCTAssertEqual(DownloadLocation.profileFolder(base: base, appFolderName: "PB Dev", profileName: "").path,
                       "/Users/me/Downloads/PB Dev/Profile")
        XCTAssertEqual(DownloadLocation.profileFolder(base: base, appFolderName: "..", profileName: "x").path,
                       "/Users/me/Downloads/PrivacyBrowser/x")
        let folder = DownloadLocation.profileFolder(base: base, profileName: "../../../etc")
        XCTAssertEqual(folder.deletingLastPathComponent().deletingLastPathComponent().path, base.path, "stays inside base")
    }

    // MARK: Unique file names

    func testNoConflictKeepsTheName() {
        XCTAssertEqual(unique("report.pdf"), folder.appendingPathComponent("report.pdf"))
        XCTAssertEqual(unique("report.pdf").deletingLastPathComponent().path, folder.path)
    }

    func testCounterScheme() {
        XCTAssertEqual(unique("report.pdf", existing: ["report.pdf"]).lastPathComponent, "report (1).pdf")
        XCTAssertEqual(unique("report.pdf", existing: ["report.pdf", "report (1).pdf"]).lastPathComponent, "report (2).pdf")
        XCTAssertEqual(unique("README", existing: ["README"]).lastPathComponent, "README (1)")
        XCTAssertEqual(unique("archive.tar.gz", existing: ["archive.tar.gz"]).lastPathComponent, "archive (1).tar.gz")
        XCTAssertEqual(unique("Backup.TAR.XZ", existing: ["Backup.TAR.XZ"]).lastPathComponent, "Backup (1).TAR.XZ")
        XCTAssertEqual(unique("photo.JPG", existing: ["photo.JPG"]).lastPathComponent, "photo (1).JPG")
        XCTAssertEqual(unique("a.b.c", existing: ["a.b.c"]).lastPathComponent, "a.b (1).c")
        // A dot that is not an extension.
        XCTAssertEqual(unique("Report v1.2 final", existing: ["Report v1.2 final"]).lastPathComponent, "Report v1.2 final (1)")
        // An existing " (n)" suffix continues the sequence instead of nesting.
        XCTAssertEqual(unique("file (1).pdf", existing: ["file (1).pdf"]).lastPathComponent, "file (2).pdf")
        XCTAssertEqual(unique("file (9)", existing: ["file (9)", "file (10)"]).lastPathComponent, "file (11)")
        XCTAssertEqual(unique("(1).txt", existing: ["(1).txt"]).lastPathComponent, "(1) (1).txt")
    }

    func testHostileSuggestedNames() {
        let cases: [(String, String)] = [
            ("../../etc/passwd", "etc passwd"),
            ("..\\..\\boot.ini", "boot.ini"),
            ("C:\\Windows\\evil.exe", "C Windows evil.exe"),
            (".bashrc", "bashrc"),
            ("", "download"),
            ("...", "download"),
            ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
            ("line\nbreak.txt", "line break.txt"),
            ("nul\u{0}byte.bin", "nulbyte.bin"),
            ("trailing.txt. . ", "trailing.txt"),
        ]
        for (input, expected) in cases {
            let url = unique(input)
            XCTAssertEqual(url.lastPathComponent, expected, input.debugDescription)
            XCTAssertEqual(url.deletingLastPathComponent().path, folder.path, "stays in the folder: \(input.debugDescription)")
            assertSafeComponent(url.lastPathComponent)
        }
    }

    func testLongNamesFit255BytesAndKeepTheExtension() {
        let longASCII = String(repeating: "a", count: 300) + ".txt"
        let first = unique(longASCII).lastPathComponent
        XCTAssertEqual(first.utf8.count, 255)
        XCTAssertTrue(first.hasSuffix(".txt"), "a 300-char name loses stem characters, not its extension")

        let second = unique(longASCII, existing: [first]).lastPathComponent
        XCTAssertLessThanOrEqual(second.utf8.count, 255)
        XCTAssertTrue(second.hasSuffix(" (1).txt"), second)

        let cyrillic = String(repeating: "ж", count: 200) + ".pdf" // 2 bytes per letter
        let firstCyrillic = unique(cyrillic).lastPathComponent
        XCTAssertLessThanOrEqual(firstCyrillic.utf8.count, 255)
        XCTAssertTrue(firstCyrillic.hasSuffix("ж.pdf"), firstCyrillic)
        let name = unique(cyrillic, existing: [firstCyrillic]).lastPathComponent
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix(" (1).pdf"), name)
        XCTAssertTrue(name.hasPrefix("жжж"))
        assertSafeComponent(name)
    }

    func testTerminatesWhenEverythingExists() {
        let url = DownloadLocation.uniqueFileURL(in: folder, suggestedFilename: "busy.zip") { _ in true }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("busy ("))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(").zip"))
        XCTAssertEqual(url.deletingLastPathComponent().path, folder.path)
    }

    func testSplitHelpers() {
        XCTAssertEqual(DownloadLocation.splitExtension("archive.tar.gz").stem, "archive")
        XCTAssertEqual(DownloadLocation.splitExtension("archive.tar.gz").ext, "tar.gz")
        XCTAssertEqual(DownloadLocation.splitExtension("x.tar").ext, "tar")
        XCTAssertEqual(DownloadLocation.splitExtension("notes.").ext, "")
        XCTAssertEqual(DownloadLocation.splitExtension("weird.ext with space").ext, "")
        XCTAssertEqual(DownloadLocation.splitExtension("data.verylongextension123").ext, "", "more than 16 characters is not an extension")
        XCTAssertNil(DownloadLocation.splitCounterSuffix("file"))
        XCTAssertNil(DownloadLocation.splitCounterSuffix("file (x)"))
        XCTAssertNil(DownloadLocation.splitCounterSuffix("(3)"))
        XCTAssertEqual(DownloadLocation.splitCounterSuffix("file (3)")?.1, 3)
        XCTAssertEqual(DownloadLocation.splitCounterSuffix("file (3)")?.0, "file")
    }
}
