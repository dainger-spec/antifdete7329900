import XCTest
@testable import BrowserCore

final class AppLogTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-applog-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func lines(_ url: URL) throws -> [String] {
        try read(url).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) & 0o777
    }

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z (DEBUG |INFO  |NOTICE|ERROR ) \[[A-Za-z0-9._-]+\] .*$"#)

    private func assertWellFormed(_ line: String, file: StaticString = #filePath, line number: UInt = #line) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        XCTAssertNotNil(Self.linePattern.firstMatch(in: line, range: range), "malformed log line: \(line)", file: file, line: number)
    }

    // MARK: Format

    func testLineFormat() throws {
        let date = Date(timeIntervalSince1970: 1_767_323_045.678) // 2026-01-02T03:04:05.678Z
        XCTAssertEqual(AppLog.formatLine(level: .notice, category: "proxy", message: "check ok", date: date),
                       "2026-01-02T03:04:05.678Z NOTICE [proxy] check ok\n")
        XCTAssertEqual(AppLog.formatLine(level: .info, category: "profile launch/ü", message: "x", date: date),
                       "2026-01-02T03:04:05.678Z INFO   [profile_launch__] x\n")
        XCTAssertEqual(AppLog.formatLine(level: .error, category: "", message: "", date: date),
                       "2026-01-02T03:04:05.678Z ERROR  [-] \n")
        XCTAssertEqual(AppLog.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(AppLog.timestamp(Date(timeIntervalSince1970: -0.5)), "1969-12-31T23:59:59.500Z")

        let log = AppLog(directory: root)
        log.log(.debug, "test", "first", date: date)
        log.log(.error, "test", "second")
        let written = try lines(log.fileURL)
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written[0], "2026-01-02T03:04:05.678Z DEBUG  [test] first")
        written.forEach { assertWellFormed($0) }
        XCTAssertTrue(written[1].hasSuffix("ERROR  [test] second"))
        XCTAssertEqual(log.fileURL.lastPathComponent, "PrivacyBrowser.log")
    }

    func testNewlinesAndControlCharactersAreEscapedAndLengthIsCapped() throws {
        let log = AppLog(directory: root)
        log.log(.info, "t", "line1\nline2\r\n\tend\u{1B}[31m\u{2028}x")
        let written = try lines(log.fileURL)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].hasSuffix(#"line1\nline2\r\n\tend\u{1B}[31m\u{2028}x"#), written[0])

        log.log(.info, "t", String(repeating: "é", count: 5_000))
        let long = try XCTUnwrap(try lines(log.fileURL).last)
        let message = long.components(separatedBy: "[t] ").last ?? ""
        XCTAssertEqual(message.count, AppLog.maxMessageCharacters + 1)
        XCTAssertTrue(message.hasSuffix("é…"))
    }

    func testMinimumLevel() throws {
        let log = AppLog(directory: root)
        log.minimumLevel = .notice
        log.log(.debug, "t", "dropped")
        log.log(.info, "t", "dropped")
        log.log(.notice, "t", "kept")
        log.log(.error, "t", "kept")
        XCTAssertEqual(try lines(log.fileURL).count, 2)
        XCTAssertTrue(AppLog.Level.debug < .info && AppLog.Level.info < .notice && AppLog.Level.notice < .error)
    }

    // MARK: Files

    func testPermissions() throws {
        let directory = root.appendingPathComponent("nested/Logs", isDirectory: true)
        let log = AppLog(directory: directory)
        log.log(.info, "t", "hello")
        XCTAssertEqual(try mode(of: log.fileURL), 0o600)
        XCTAssertEqual(try mode(of: directory), 0o700)

        // A pre-existing world-readable file is tightened on open.
        let other = AppLog(directory: directory, fileName: "Other.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: other.fileURL.path, contents: Data("old\n".utf8),
                                                     attributes: [.posixPermissions: 0o644]))
        other.log(.info, "t", "new")
        XCTAssertEqual(try mode(of: other.fileURL), 0o600)
        XCTAssertEqual(try lines(other.fileURL).first, "old", "existing content is appended to, not replaced")
    }

    func testRotationKeepsConfiguredNumberOfFiles() throws {
        let log = AppLog(directory: root, fileName: "Test.log", maxBytes: 1_000, keepFiles: 3)
        for index in 0..<200 {
            log.log(.info, "rot", String(format: "entry %04ld ", index) + String(repeating: "x", count: 50))
        }
        let current = root.appendingPathComponent("Test.log")
        let first = root.appendingPathComponent("Test.1.log")
        let second = root.appendingPathComponent("Test.2.log")
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: current.path))
        XCTAssertTrue(fileManager.fileExists(atPath: first.path))
        XCTAssertTrue(fileManager.fileExists(atPath: second.path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("Test.3.log").path))
        XCTAssertEqual(log.existingFileURLs.map(\.lastPathComponent), ["Test.log", "Test.1.log", "Test.2.log"])

        func numbers(_ url: URL) throws -> [Int] {
            try lines(url).map { line in
                let range = try XCTUnwrap(line.range(of: "entry "))
                return try XCTUnwrap(Int(line[range.upperBound...].prefix(4)))
            }
        }
        for url in [current, first, second] {
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 1_000)
            XCTAssertEqual(try mode(of: url), 0o600)
        }
        let newest = try numbers(current), previous = try numbers(first), oldest = try numbers(second)
        XCTAssertEqual(newest.last, 199)
        XCTAssertEqual(try XCTUnwrap(previous.last) + 1, newest.first, "files are contiguous")
        XCTAssertEqual(try XCTUnwrap(oldest.last) + 1, previous.first)
    }

    func testRotationWithSingleFileAndOversizedEntry() throws {
        let log = AppLog(directory: root, fileName: "One", maxBytes: 200, keepFiles: 1)
        log.log(.info, "t", "a")
        log.log(.info, "t", String(repeating: "b", count: 500)) // larger than maxBytes: fresh file
        log.log(.info, "t", "c")
        XCTAssertEqual(log.existingFileURLs.map(\.lastPathComponent), ["One"])
        let written = try lines(log.fileURL)
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(written[0].hasSuffix("] c"))
        XCTAssertEqual(log.fileURL(index: 2).lastPathComponent, "One.2")
    }

    func testContinuesExistingFileAcrossInstances() throws {
        AppLog(directory: root, maxBytes: 10_000).log(.info, "t", "from first launch")
        let reopened = AppLog(directory: root, maxBytes: 10_000)
        reopened.log(.info, "t", "from second launch")
        XCTAssertEqual(try lines(reopened.fileURL).count, 2)
    }

    func testRecreatesDeletedFile() throws {
        let log = AppLog(directory: root)
        log.log(.info, "t", "one")
        try FileManager.default.removeItem(at: root)
        log.log(.info, "t", "two")
        XCTAssertEqual(try lines(log.fileURL).count, 1)
        XCTAssertTrue(try read(log.fileURL).contains("two"))
    }

    func testIOFailureIsSwallowed() throws {
        // The "directory" is a regular file: nothing can be created inside it.
        try Data("not a directory".utf8).write(to: root)
        let log = AppLog(directory: root.appendingPathComponent("Logs"))
        log.log(.error, "t", "dropped")
        XCTAssertEqual(log.tail(), "")
        XCTAssertEqual(log.existingFileURLs, [])
    }

    // MARK: Tail

    func testTailCutsAtLineBoundaryAndIncludesPreviousFile() throws {
        let log = AppLog(directory: root, maxBytes: 2_000, keepFiles: 3)
        for index in 0..<100 {
            log.log(.info, "tail", String(format: "line %03ld", index))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.fileURL(index: 1).path))
        let currentCount = try lines(log.fileURL).count

        let all = log.tail(maxBytes: 1_000_000)
        let allLines = all.split(separator: "\n").map(String.init)
        XCTAssertEqual(allLines.last.map { $0.hasSuffix("line 099") }, true, "newest last")
        XCTAssertGreaterThan(allLines.count, currentCount, "previous file included")
        let previous = try lines(log.fileURL(index: 1))
        XCTAssertEqual(Array(allLines.prefix(previous.count)), previous, "previous file comes first")

        let window = 500
        let tail = log.tail(maxBytes: window)
        XCTAssertLessThanOrEqual(tail.utf8.count, window)
        XCTAssertTrue(tail.hasSuffix("line 099\n"))
        let tailLines = tail.split(separator: "\n").map(String.init)
        XCTAssertFalse(tailLines.isEmpty)
        tailLines.forEach { assertWellFormed($0) } // the first line is complete, not cut mid-way

        XCTAssertEqual(log.tail(maxBytes: 10), "", "no complete line fits")
        XCTAssertEqual(log.tail(maxBytes: 0), "")
    }

    func testTailBytesBoundaries() {
        let data = Data("aaa\nbbb\nccc\n".utf8)
        XCTAssertEqual(AppLog.tailBytes(data, maxBytes: 100), data)
        XCTAssertEqual(String(decoding: AppLog.tailBytes(data, maxBytes: 8), as: UTF8.self), "bbb\nccc\n", "window starts at a line start")
        XCTAssertEqual(String(decoding: AppLog.tailBytes(data, maxBytes: 7), as: UTF8.self), "ccc\n")
        XCTAssertEqual(String(decoding: AppLog.tailBytes(data, maxBytes: 3), as: UTF8.self), "")
        XCTAssertEqual(AppLog(directory: root).tail(), "", "nothing logged yet")
    }

    // MARK: Privacy

    func testRedaction() {
        let cases: [(String, String)] = [
            ("proxy socks5h://alice:s3cret@proxy.example:1080 failed", "proxy socks5h://***@proxy.example:1080 failed"),
            ("http://user:p@ss@host.test/path", "http://***@host.test/path"),
            ("https://token@api.test/", "https://***@api.test/"),
            ("upstream bob:hunter2@10.0.0.1:8080", "upstream ***@10.0.0.1:8080"),
            ("https://site.test/login?user=a&password=hunter2&next=/", "https://site.test/login?user=a&password=***&next=/"),
            ("callback?access_token=abc.def&state=1", "callback?access_token=***&state=1"),
            ("token = xyz123 rest", "token = *** rest"),
            ("api_key=K; session_id=S, csrfToken='q w'", "api_key=***; session_id=***, csrfToken=***"),
            ("Authorization: Bearer abcdefghijklmnop", "Authorization: ***"),
            ("Proxy-Authorization: Basic YWxpY2U6czNjcmV0", "Proxy-Authorization: ***"),
            ("Cookie: a=1; b=2\nnext line", "Cookie: ***\nnext line"),
            ("sent Bearer abcdefghijklmnop to server", "sent Bearer *** to server"),
            ("bearer\tabcdefghijklmnop", "bearer ***"),
            (#"{"user":"a","password":"p\"w","authToken": "t"}"#, #"{"user":"a","password":"***","authToken": "***"}"#),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(AppLog.redact(input), expected, input)
            XCTAssertEqual(AppLog.redact(expected), expected, "idempotent: \(expected)")
        }
        // Ordinary operational text is left alone.
        for untouched in ["NSURLErrorDomain -1004 code=-1004", "https://example.com/a/b?q=1", "profile launched in 120 ms",
                          "proxy 127.0.0.1:8080 unreachable", "error: connection refused", ""] {
            XCTAssertEqual(AppLog.redact(untouched), untouched)
        }
    }

    func testLogAppliesRedaction() throws {
        let log = AppLog(directory: root)
        log.log(.error, "proxy", "connect socks5://u:topsecret@h.test:1080 password=hunter2 token=t0k3n")
        let text = try read(log.fileURL)
        for secret in ["topsecret", "hunter2", "t0k3n", "u:"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked: \(text)")
        }
        XCTAssertTrue(text.contains("socks5://***@h.test:1080"))
    }

    func testDescribeURL() {
        let cases: [(String?, String)] = [
            (nil, "-"),
            ("https://user:pass@Example.COM/private/path?q=secret#frag", "https://example.com"),
            ("http://example.com:8080/x", "http://example.com:8080"),
            ("socks5h://alice:pw@127.0.0.1:1080", "socks5h://127.0.0.1:1080"),
            ("http://[::1]:8080/a", "http://[::1]:8080"),
            ("about:blank", "about:"),
            ("file:///Users/alice/Secret.pdf", "file:"),
            ("data:text/plain,hello", "data:"),
            ("example.com/path", "-"),
        ]
        for (string, expected) in cases {
            let url = string.flatMap { URL(string: $0) }
            if string != nil { XCTAssertNotNil(url, "test URL must parse: \(string!)") }
            XCTAssertEqual(AppLog.describe(url: url), expected, string ?? "nil")
        }
    }

    // MARK: Concurrency

    func testConcurrentLoggingProducesWholeLines() throws {
        let log = AppLog(directory: root, maxBytes: 10_000_000)
        let threads = 8, perThread = 250
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for index in 0..<perThread {
                log.log(index % 2 == 0 ? .info : .error, "t\(thread)", "thread \(thread) entry \(index) " + String(repeating: "z", count: 40))
                if index % 50 == 0 { _ = log.tail(maxBytes: 4_096) }
            }
        }
        let written = try lines(log.fileURL)
        XCTAssertEqual(written.count, threads * perThread)
        written.forEach { assertWellFormed($0) }
        for thread in 0..<threads {
            XCTAssertEqual(written.filter { $0.contains("[t\(thread)] thread \(thread) entry") }.count, perThread)
        }
    }

    func testConcurrentLoggingWithRotation() throws {
        let log = AppLog(directory: root, maxBytes: 4_000, keepFiles: 3)
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<200 {
                log.log(.notice, "rot", "t\(thread) #\(index) " + String(repeating: "r", count: 30))
            }
        }
        let files = log.existingFileURLs
        XCTAssertEqual(files.count, 3)
        for url in files {
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 4_000)
            try lines(url).forEach { assertWellFormed($0) }
        }
    }

    func testSharedAccessor() {
        let previous = AppLog.shared
        defer { AppLog.shared = previous }
        let log = AppLog(directory: root)
        AppLog.shared = log
        XCTAssertTrue(AppLog.shared === log)
        AppLog.shared = nil
        XCTAssertNil(AppLog.shared)
    }
}
