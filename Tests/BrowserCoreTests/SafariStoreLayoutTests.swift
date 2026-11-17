import Foundation
import XCTest
@testable import BrowserCore

/// Safari's stores in a profile's home (`SafariStoreLayout`): the folders made, what is set aside,
/// what is left alone — and that nothing is ever written as a store's content.
final class SafariStoreLayoutTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pb-stores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func url(_ path: String) -> URL { home.appendingPathComponent(path) }

    private func exists(_ path: String, folder: Bool? = nil) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url(path).path, isDirectory: &isFolder) else { return false }
        return folder.map { $0 == isFolder.boolValue } ?? true
    }

    private func write(_ path: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url(path))
    }

    private var sqlite: Data { Data("SQLite format 3\u{0}".utf8) + Data(repeating: 0, count: 496) }

    func testANewHomeGetsEveryFolderAndNoStore() {
        let report = SafariStoreLayout.prepare(home: home)
        XCTAssertTrue(report.failed.isEmpty, "\(report.failed)")
        for folder in SafariStoreLayout.folders { XCTAssertTrue(exists(folder, folder: true), folder) }
        for path in ["Library/Safari/Favicon Cache", "Library/Caches/com.apple.Safari/TabSnapshots", "Library/Safari/Metadata Cache",
                     "Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles",
                     "Library/Safari/Template Icons", "Library/Safari/Favicon Cache/favicons", "Library/Caches", "Library/Preferences"] {
            XCTAssertTrue(exists(path, folder: true), path)
        }
        // Safari's own code makes its databases and property lists: none is written here.
        for store in SafariStoreLayout.stores where store.kind != .folder { XCTAssertFalse(exists(store.path), store.path) }
        XCTAssertTrue(report.setAside.isEmpty)
        // Parents come before their children.
        let folders = SafariStoreLayout.folders
        for (index, folder) in folders.enumerated() {
            let parent = (folder as NSString).deletingLastPathComponent
            if let at = folders.firstIndex(of: parent) { XCTAssertLessThan(at, index, folder) }
        }
    }

    func testASecondLaunchChangesNothing() {
        _ = SafariStoreLayout.prepare(home: home)
        XCTAssertTrue(SafariStoreLayout.prepare(home: home).isEmpty)
    }

    func testGoodStoresAreLeftAsTheyAre() throws {
        try write("Library/Safari/History.db", sqlite)
        try write("Library/Safari/History.db-wal", Data([1, 2, 3]))
        try write("Library/Safari/Embeddings.db", Data())
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Children": []], format: .binary, options: 0)
        try write("Library/Safari/Bookmarks.plist", plist)
        let report = SafariStoreLayout.prepare(home: home)
        XCTAssertTrue(report.setAside.isEmpty, "\(report.setAside)")
        XCTAssertEqual(try Data(contentsOf: url("Library/Safari/History.db")), sqlite)
        XCTAssertEqual(try Data(contentsOf: url("Library/Safari/Bookmarks.plist")), plist)
        let assessed = SafariStoreLayout.assess(home: home)
        let history = try XCTUnwrap(assessed.first { $0.path == "Library/Safari/History.db" })
        XCTAssertTrue(history.exists && history.wellFormed && history.writable)
        XCTAssertEqual(history.bytes, 512)
        // An empty database file is a new database to SQLite.
        XCTAssertTrue(try XCTUnwrap(assessed.first { $0.path == "Library/Safari/Embeddings.db" }).wellFormed)
        XCTAssertFalse(try XCTUnwrap(assessed.first { $0.path == "Library/Safari/TopSites.plist" }).exists)
    }

    func testAStoreThatIsNotOneIsSetAsideWithItsJournal() throws {
        try write("Library/Safari/PerSitePreferences.db", Data("not a database at all".utf8))
        try write("Library/Safari/PerSitePreferences.db-wal", Data([9]))
        try write("Library/Safari/TopSites.plist", Data())
        try write("Library/Safari/Template Icons/CacheSettings.plist", Data("<plist".utf8))
        let report = SafariStoreLayout.prepare(home: home)
        XCTAssertEqual(Set(report.setAside), ["Library/Safari/PerSitePreferences.db", "Library/Safari/PerSitePreferences.db-wal",
                                              "Library/Safari/TopSites.plist", "Library/Safari/Template Icons/CacheSettings.plist"])
        XCTAssertFalse(exists("Library/Safari/PerSitePreferences.db"))
        XCTAssertEqual(try Data(contentsOf: url("Library/Safari/PerSitePreferences.db.unreadable")), Data("not a database at all".utf8))
        XCTAssertTrue(exists("Library/Safari/PerSitePreferences.db-wal.unreadable"))
        // Set aside again later: the older one is replaced, never a pile of them.
        try write("Library/Safari/PerSitePreferences.db", Data("again".utf8))
        _ = SafariStoreLayout.prepare(home: home)
        XCTAssertEqual(try Data(contentsOf: url("Library/Safari/PerSitePreferences.db.unreadable")), Data("again".utf8))
    }

    func testADatabaseThatDoesNotOpenIsSetAsideAndOneThatCannotBeToldIsKept() throws {
        try write("Library/Safari/NotifyMeWhen.db", sqlite)
        try write("Library/Safari/History.db", sqlite)
        let report = SafariStoreLayout.prepare(home: home) { url in
            url.lastPathComponent == "NotifyMeWhen.db" ? false : nil
        }
        XCTAssertEqual(report.setAside, ["Library/Safari/NotifyMeWhen.db"])
        XCTAssertTrue(exists("Library/Safari/History.db"))
    }

    func testAFileWhereAFolderBelongsIsSetAsideAndTheFolderMade() throws {
        try write("Library/Safari/Favicon Cache", Data("a file".utf8))
        let report = SafariStoreLayout.prepare(home: home)
        XCTAssertTrue(report.setAside.contains("Library/Safari/Favicon Cache"))
        XCTAssertTrue(exists("Library/Safari/Favicon Cache", folder: true))
        XCTAssertTrue(exists("Library/Safari/Favicon Cache.unreadable", folder: false))
    }

    func testWhatTheOwnerCannotWriteIsMadeWritable() throws {
        try write("Library/Safari/History.db", sqlite)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url("Library/Safari/History.db").path)
        try FileManager.default.createDirectory(at: url("Library/Safari/Metadata Cache"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url("Library/Safari/Metadata Cache").path)
        // Root may write anything: the check means nothing there.
        try XCTSkipIf(getuid() == 0, "running as root")
        let report = SafariStoreLayout.prepare(home: home)
        XCTAssertTrue(report.madeWritable.contains("Library/Safari/History.db"), "\(report.madeWritable)")
        XCTAssertTrue(report.madeWritable.contains("Library/Safari/Metadata Cache"), "\(report.madeWritable)")
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: url("Library/Safari/History.db").path))
    }

    func testTheLinesSayWhatIsWrong() {
        var missing = SafariStoreLayout.Assessment(path: "Library/Safari/Embeddings.db", kind: .database)
        XCTAssertEqual(missing.line, "Library/Safari/Embeddings.db database: missing")
        missing.exists = true
        missing.bytes = 4
        missing.wellFormed = false
        XCTAssertEqual(missing.line, "Library/Safari/Embeddings.db database: present 4 B, NOT WRITABLE, NOT A DATABASE")
    }

    func testTheListHoldsTheStoresAnAddressBarSearchesThrough() {
        let paths = SafariStoreLayout.stores.map(\.path)
        for name in ["History.db", "Embeddings.db", "TopSites.plist", "Bookmarks.plist", "PerSitePreferences.db", "Favicon Cache/favicons.db"] {
            XCTAssertTrue(paths.contains("Library/Safari/" + name), name)
        }
        XCTAssertEqual(Set(paths).count, paths.count)
    }
}

/// What Return in the address bar asked for (`AddressBarIntent`), done by the profile's process when
/// Safari's code throws in the commit.
final class AddressBarIntentTests: XCTestCase {
    func testAWordIsASearchWithTheProfilesEngine() {
        XCTAssertEqual(AddressBarIntent.destination(typed: "google", engine: .google)?.absoluteString, "https://www.google.com/search?q=google")
        XCTAssertEqual(AddressBarIntent.destination(typed: " weather today ", engine: .bing)?.absoluteString,
                       "https://www.bing.com/search?q=weather%20today")
        XCTAssertEqual(AddressBarIntent.destination(typed: "гугл", engine: .yandex)?.host, "yandex.ru")
    }

    func testAnAddressIsLoadedAsItIs() {
        XCTAssertEqual(AddressBarIntent.destination(typed: "example.com", engine: .google)?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressBarIntent.destination(typed: "http://example.com/a?b", engine: .google)?.absoluteString, "http://example.com/a?b")
        XCTAssertNil(AddressBarIntent.destination(typed: "   ", engine: .google))
    }

    func testTheEnginesHostsAsAProxySeesThem() {
        XCTAssertTrue(AddressBarIntent.isResultsHost("www.google.com:443", of: .google))
        XCTAssertTrue(AddressBarIntent.isResultsHost("www.google.ru:443", of: .google))
        XCTAssertTrue(AddressBarIntent.isResultsHost("www.bing.com:443", of: .bing))
        XCTAssertTrue(AddressBarIntent.isResultsHost("search.yahoo.com:443", of: .yahoo))
        XCTAssertTrue(AddressBarIntent.isResultsHost("duckduckgo.com:443", of: .duckDuckGo))
        XCTAssertTrue(AddressBarIntent.isResultsHost("www.ecosia.org:443", of: .ecosia))
        XCTAssertTrue(AddressBarIntent.isResultsHost("yandex.ru:443", of: .yandex))
        XCTAssertTrue(AddressBarIntent.isResultsHost("ya.ru", of: .yandex))
        // The check's own pages and look-alikes are not.
        XCTAssertFalse(AddressBarIntent.isResultsHost("www.google.selftest.invalid:80", of: .google))
        XCTAssertFalse(AddressBarIntent.isResultsHost("googleusercontent.com:443", of: .google))
        XCTAssertFalse(AddressBarIntent.isResultsHost("notbing.com:443", of: .bing))
        XCTAssertFalse(AddressBarIntent.isResultsHost("www.bing.com:443", of: .google))
        XCTAssertFalse(AddressBarIntent.isResultsHost("", of: .google))
    }
}
