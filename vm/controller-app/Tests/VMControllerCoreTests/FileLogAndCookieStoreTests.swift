import Foundation
import XCTest
@testable import VMControllerCore

final class FileLogTests: XCTestCase {
    var dir: URL!
    var log: FileLog!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flog-\(UUID().uuidString)")
        log = FileLog(url: dir.appendingPathComponent("launcher.log"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testAppendAndTail() {
        log.append("starting", level: "info")
        log.append("VM IP 192.168.64.5")
        log.append("boom", level: "error")
        let text = log.tail()
        XCTAssertTrue(text.contains("[info] starting"))
        XCTAssertTrue(text.contains("[error] boom"))
        XCTAssertTrue(text.contains("VM IP 192.168.64.5"))
        XCTAssertEqual(text.split(whereSeparator: \.isNewline).count, 3)
    }

    func testEmptyWhenMissing() {
        XCTAssertEqual(log.tail(), "")
    }

    func testClear() {
        log.append("x")
        log.clear()
        XCTAssertEqual(log.tail(), "")
    }

    func testTrimDropsWholeLinesFromFront() {
        let capped = FileLog(url: dir.appendingPathComponent("capped.log"), maxBytes: 8 * 1024)
        for i in 0..<2000 { capped.append("line number \(i) with some padding to take up space") }
        let data = try! Data(contentsOf: capped.url)
        XCTAssertLessThanOrEqual(data.count, 8 * 1024)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.hasPrefix("\n"), "never starts mid-line")
        XCTAssertTrue(text.contains("line number 1999"), "keeps the newest line")
        XCTAssertFalse(text.contains("line number 0 "), "drops the oldest")
    }

    func testTrimmedHelperCutsAtNewline() {
        let data = Data("aaaa\nbbbb\ncccc\n".utf8)
        let out = FileLog.trimmed(data, to: 6)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "cccc\n")
    }
}

final class ProfileCookieStoreTests: XCTestCase {
    var store: ProfileStore!
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pck-\(UUID().uuidString)")
        store = ProfileStore(url: dir.appendingPathComponent("profiles.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testImportCookiesWritesFileAndCount() throws {
        let profile = try store.add(Profile(name: "Work"))
        let cookiesTxt = dir.appendingPathComponent("in.txt")
        try """
        # Netscape HTTP Cookie File
        .example.com\tTRUE\t/\tTRUE\t2147483647\tsid\tabc
        x.com\tFALSE\t/\tFALSE\t0\tt\tv
        """.write(to: cookiesTxt, atomically: true, encoding: .utf8)

        let n = try store.importCookies(for: profile.id, from: cookiesTxt)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try store.get(profile.id)?.cookieCount, 2)

        let saved = store.cookiesURL(for: profile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        let decoded = try JSONDecoder().decode([Cookie].self, from: Data(contentsOf: saved))
        XCTAssertEqual(decoded.map(\.name), ["sid", "t"])
    }

    func testImportJSONCookies() throws {
        let profile = try store.add(Profile(name: "P"))
        let file = dir.appendingPathComponent("in.json")
        try #"[{"domain":"x.com","name":"a","value":"1","secure":true}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.importCookies(for: profile.id, from: file), 1)
    }

    func testClearCookies() throws {
        let profile = try store.add(Profile(name: "P"))
        let file = dir.appendingPathComponent("in.json")
        try #"[{"domain":"x.com","name":"a","value":"1"}]"#.write(to: file, atomically: true, encoding: .utf8)
        _ = try store.importCookies(for: profile.id, from: file)
        try store.clearCookies(for: profile.id)
        XCTAssertEqual(try store.get(profile.id)?.cookieCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cookiesURL(for: profile).path))
    }

    func testImportToMissingProfileThrows() {
        let file = dir.appendingPathComponent("in.json")
        try? "[]".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.importCookies(for: "nope", from: file))
    }
}
