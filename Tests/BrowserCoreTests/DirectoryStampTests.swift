#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import BrowserCore

/// A profile's stop archived its website data again at every try, changed or not. It now archives
/// again only when the data is not what the last archive read, which `DirectoryStamp` tells: the
/// stamp an archive's pass makes of what it reads equals the stamp of the same directories taken
/// later for as long as nothing beneath them changed — and any change, of any kind, gives another.
final class DirectoryStampTests: XCTestCase {
    var root: URL!
    let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var data: URL { root.appendingPathComponent("src-data") }
    private var cache: URL { root.appendingPathComponent("src-cache") }
    private var cookies: URL { data.appendingPathComponent("Cookies.binarycookies") }

    /// Two roots that are there — five directories and four files beneath them — and one that is not.
    private func makeTree() throws -> [String: URL] {
        try FileManager.default.createDirectory(at: data.appendingPathComponent("IndexedDB/https_example.com_0"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("Records"), withIntermediateDirectories: true)
        try secureRandomBytes(70_000).write(to: data.appendingPathComponent("IndexedDB/https_example.com_0/db.sqlite3"))
        try Data("cookie=1".utf8).write(to: cookies)
        try Data("resource".utf8).write(to: cache.appendingPathComponent("Records/0001-resource"))
        try Data().write(to: cache.appendingPathComponent("Records/0002-blob"))
        return ["data": data, "cache": cache, "missing": root.appendingPathComponent("not-there")]
    }

    /// File systems keep times in steps (milliseconds on some): a change made at once after
    /// another could carry the same time. WebKit's writes are not that close to the archive's
    /// look at the file followed by its read.
    private func aMomentLater() {
        Thread.sleep(forTimeInterval: 0.03)
    }

    func testAnUntouchedTreeHasTheStampItsArchiveRead() throws {
        let roots = try makeTree()
        let archive = root.appendingPathComponent("webdata.pbsa")
        let sealed = try EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key)
        let read = try XCTUnwrap(sealed.stamp)
        // The two roots, the three directories beneath them, the four files.
        XCTAssertEqual(read.entries, 9)
        XCTAssertEqual(DirectoryStamp.of(roots: roots), read)
        aMomentLater()
        XCTAssertEqual(DirectoryStamp.of(roots: roots), read, "reading the files, and time passing, change nothing of it")
        // Another archive of the same data reads the same.
        XCTAssertEqual(try EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key).stamp, read)
        // The roots are told apart by their labels: the same directories under other names are other data.
        XCTAssertNotEqual(DirectoryStamp.of(roots: ["a": data, "b": cache]), read)
        // What was unsealed, or re-encrypted, read no directory: no stamp.
        let restored = try EncryptedDirectoryArchive.unseal(from: archive, key: key,
                                                            destinations: ["data": root.appendingPathComponent("out-data"),
                                                                           "cache": root.appendingPathComponent("out-cache")])
        XCTAssertNil(restored.stamp)
    }

    func testAChangeAfterTheArchiveLookedGivesAnotherStampUntilItIsArchivedAgain() throws {
        let roots = try makeTree()
        let archive = root.appendingPathComponent("webdata.pbsa")
        let first = try XCTUnwrap(EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key).stamp)
        aMomentLater()
        let handle = try FileHandle(forWritingTo: cookies)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("; late=1".utf8))
        try handle.close()
        XCTAssertNotEqual(DirectoryStamp.of(roots: roots), first)
        let second = try EncryptedDirectoryArchive.seal(roots: roots, to: archive, key: key)
        XCTAssertNotEqual(second.stamp, first)
        XCTAssertEqual(DirectoryStamp.of(roots: roots), second.stamp)
        // And the archive that was made again holds the late bytes.
        let out = root.appendingPathComponent("out")
        try EncryptedDirectoryArchive.unseal(from: archive, key: key, destinations: ["data": out, "cache": root.appendingPathComponent("out-cache")])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Cookies.binarycookies")), Data("cookie=1; late=1".utf8))
    }

    func testEveryKindOfChangeGivesAnotherStamp() throws {
        let roots = try makeTree()
        var last = try XCTUnwrap(DirectoryStamp.of(roots: roots))
        func changed(_ what: String, _ change: () throws -> Void) throws {
            aMomentLater()
            try change()
            let now = try XCTUnwrap(DirectoryStamp.of(roots: roots), what)
            XCTAssertNotEqual(now, last, what)
            XCTAssertEqual(DirectoryStamp.of(roots: roots), now, "\(what): the same again when nothing more changed")
            last = now
        }
        try changed("bytes written in place, the size as it was") {
            let handle = try FileHandle(forWritingTo: self.cookies)
            try handle.write(contentsOf: Data("COOKIE=2".utf8))
            try handle.close()
        }
        try changed("bytes added") {
            let handle = try FileHandle(forWritingTo: self.cookies)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("; b=2".utf8))
            try handle.close()
        }
        try changed("another file with the same bytes put in its place") {
            try Data("COOKIE=2; b=2".utf8).write(to: self.cookies, options: .atomic)
        }
        try changed("a file made") {
            try Data("new".utf8).write(to: self.cache.appendingPathComponent("Records/0003-resource"))
        }
        try changed("an empty directory made") {
            try FileManager.default.createDirectory(at: self.cache.appendingPathComponent("Blobs"), withIntermediateDirectories: false)
        }
        try changed("a file renamed") {
            try FileManager.default.moveItem(at: self.cache.appendingPathComponent("Records/0003-resource"),
                                             to: self.cache.appendingPathComponent("Records/0004-resource"))
        }
        try changed("a file's permissions") {
            let mode = (try FileManager.default.attributesOfItem(atPath: self.cookies.path)[.posixPermissions] as? Int) ?? 0o644
            try FileManager.default.setAttributes([.posixPermissions: mode ^ 0o040], ofItemAtPath: self.cookies.path)
        }
        try changed("a file removed") {
            try FileManager.default.removeItem(at: self.cache.appendingPathComponent("Records/0002-blob"))
        }
        try changed("a root that was not there made") {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent("not-there"), withIntermediateDirectories: false)
        }
        try changed("a root removed") {
            try FileManager.default.removeItem(at: self.cache)
        }
    }

    /// A symbolic link is looked at itself, as the archive does (it leaves links out): what it
    /// points to is not gone through, and a change there is no change here.
    func testSymbolicLinksAreNotFollowed() throws {
        let roots = try makeTree()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: data.appendingPathComponent("link").path, withDestinationPath: outside.path)
        let before = try XCTUnwrap(DirectoryStamp.of(roots: roots))
        // The two roots, three directories, four files and the link — nothing of what it points to.
        XCTAssertEqual(before.entries, 10)
        aMomentLater()
        try Data("elsewhere".utf8).write(to: outside.appendingPathComponent("file"))
        XCTAssertEqual(DirectoryStamp.of(roots: roots), before)
        let sealed = try EncryptedDirectoryArchive.seal(roots: roots, to: root.appendingPathComponent("a.pbsa"), key: key)
        XCTAssertEqual(sealed.skipped, ["data/link"])
        XCTAssertEqual(sealed.stamp, before)
    }

    /// How long the data had been left alone when a stamp was begun: what tells an archive of
    /// settled data from one that met a file only just written. It is no part of what makes two
    /// stamps equal.
    func testAStampSaysHowLongItsNewestEntryHadBeenLeftAlone() throws {
        let roots = try makeTree()
        Thread.sleep(forTimeInterval: 1.0)
        let settled = try XCTUnwrap(DirectoryStamp.of(roots: roots))
        XCTAssertGreaterThanOrEqual(settled.quietSeconds, 0.9)
        XCTAssertLessThan(settled.quietSeconds, 600)
        let archived = try XCTUnwrap(EncryptedDirectoryArchive.seal(roots: roots, to: root.appendingPathComponent("a.pbsa"), key: key).stamp)
        XCTAssertGreaterThanOrEqual(archived.quietSeconds, 0.9)
        XCTAssertEqual(archived, settled)
        // One file written now: the stamp is another, and of data just changed.
        try Data("resource, again".utf8).write(to: cache.appendingPathComponent("Records/0001-resource"))
        let fresh = try XCTUnwrap(DirectoryStamp.of(roots: roots))
        XCTAssertNotEqual(fresh, settled)
        XCTAssertLessThan(fresh.quietSeconds, 0.9)
        // The same data a moment later: the same stamp, left alone for longer.
        Thread.sleep(forTimeInterval: 0.2)
        let later = try XCTUnwrap(DirectoryStamp.of(roots: roots))
        XCTAssertEqual(later, fresh)
        XCTAssertGreaterThan(later.quietSeconds, fresh.quietSeconds)
    }

    func testNothingThereIsAStampOfNothing() throws {
        let nothing = DirectoryStamp.of(roots: ["data": root.appendingPathComponent("no-such"), "cache": root.appendingPathComponent("nor-this")])
        XCTAssertEqual(nothing?.entries, 0)
        XCTAssertEqual(nothing?.quietSeconds, Double.infinity)
        XCTAssertEqual(nothing, DirectoryStamp.of(roots: [:]))
        let roots = try makeTree()
        XCTAssertNotEqual(DirectoryStamp.of(roots: roots), nothing)
    }
}
