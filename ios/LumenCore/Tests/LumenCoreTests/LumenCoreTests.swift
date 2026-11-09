import XCTest
@testable import LumenCore

/// The core's own checks. Each one that a planted fault (`Fault`) breaks is listed in
/// ios/scripts/faults.tsv and run once with that fault, where it must fail (the red run).
final class CatalogTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testSessionsSurviveARelaunch() {
        let first = SessionCatalog(store: LumenStore(root: root))
        let a = first.create(name: "Работа", notes: "основной", tags: ["ads", "fb"])
        first.create(name: "Личное")
        // A new catalogue on the same folder is what the app sees after a relaunch.
        let again = SessionCatalog(store: LumenStore(root: root))
        XCTAssertEqual(again.sessions.map(\.name), ["Работа", "Личное"])
        XCTAssertEqual(again.session(a.id)?.storeID, a.storeID, "a session keeps its WebKit store across launches")
        XCTAssertEqual(again.session(a.id)?.tags, ["ads", "fb"])
    }

    func testRename() {
        let catalog = SessionCatalog(store: LumenStore(root: root))
        let s = catalog.create(name: "A")
        catalog.rename(s.id, to: "  Б  ")
        XCTAssertEqual(catalog.session(s.id)?.name, "Б")
        catalog.rename(s.id, to: "   ")
        XCTAssertEqual(catalog.session(s.id)?.name, "Б", "an empty name is refused")
    }

    func testNotesAndTags() {
        let catalog = SessionCatalog(store: LumenStore(root: root))
        let s = catalog.create(name: "A")
        catalog.setNotes(s.id, "для рекламы")
        catalog.setTags(s.id, ["ads, FB", "ads", " ", "fb"])
        let again = SessionCatalog(store: LumenStore(root: root))
        XCTAssertEqual(again.session(s.id)?.notes, "для рекламы")
        XCTAssertEqual(again.session(s.id)?.tags, ["ads", "FB"])
    }

    func testSearchByNameNotesTagsAndProxy() {
        let catalog = SessionCatalog(store: LumenStore(root: root))
        let proxy = UUID()
        let a = catalog.create(name: "Магазин", notes: "", tags: ["Фермы"])
        let b = catalog.create(name: "Почта", notes: "Ёжик в тумане")
        let c = catalog.create(name: "Другое")
        catalog.setProxy(c.id, proxyID: proxy)
        let names = { (q: String) in catalog.filter(q, proxyName: { $0 == proxy ? "Berlin SOCKS" : nil }).map(\.id) }
        XCTAssertEqual(names("фермы"), [a.id], "a tag is found, case aside")
        XCTAssertEqual(names("ежик"), [b.id], "the description is found, diacritics aside")
        XCTAssertEqual(names("berlin"), [c.id], "the proxy's name is found")
        XCTAssertEqual(names("маг фермы"), [a.id], "every word must match")
        XCTAssertEqual(names(""), [a.id, b.id, c.id])
    }

    func testDeleteRemovesFilesAndForgetsProxy() {
        let store = LumenStore(root: root)
        let catalog = SessionCatalog(store: store)
        let s = catalog.create(name: "A")
        store.saveTabs(SessionTabs(tabs: [TabRecord(url: "https://example.com")]), of: s.id)
        catalog.delete(s.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFolder(s.id).path))
        XCTAssertTrue(SessionCatalog(store: LumenStore(root: root)).sessions.isEmpty)
        let t = catalog.create(name: "B")
        let p = UUID()
        catalog.setProxy(t.id, proxyID: p)
        catalog.forgetProxy(p)
        XCTAssertNil(catalog.session(t.id)?.proxyID)
    }

    func testDefaultNames() {
        let catalog = SessionCatalog(store: LumenStore(root: root))
        XCTAssertEqual(catalog.create(name: " ").name, "Сессия 1")
        XCTAssertEqual(catalog.create(name: "").name, "Сессия 2")
    }

    func testTabsAndHistorySurviveARelaunch() {
        let store = LumenStore(root: root)
        let id = UUID()
        let tabs = SessionTabs(tabs: [TabRecord(url: "https://a.example/", title: "A", interactionState: Data([1, 2, 3])),
                                      TabRecord(url: "https://b.example/", title: "B")], selected: nil)
        store.saveTabs(tabs, of: id)
        store.saveHistory([HistoryEntry(url: "https://a.example/", title: "A")], of: id)
        let again = LumenStore(root: root)
        XCTAssertEqual(again.loadTabs(of: id).tabs.map(\.title), ["A", "B"])
        XCTAssertEqual(again.loadTabs(of: id).tabs.first?.interactionState, Data([1, 2, 3]))
        XCTAssertEqual(again.loadHistory(of: id).map(\.title), ["A"])
    }

    func testSettingsSurviveARelaunch() {
        let catalog = SessionCatalog(store: LumenStore(root: root))
        let s = catalog.create(name: "A")
        var settings = s.settings
        settings.searchEngine = .duckDuckGo
        settings.userAgent = .preset("ios26")
        settings.locale = .manual(timeZone: "Europe/Berlin", language: "de-DE")
        settings.canvas = .noise
        catalog.setSettings(s.id, settings)
        let again = SessionCatalog(store: LumenStore(root: root)).session(s.id)?.settings
        XCTAssertEqual(again, settings)
        XCTAssertEqual(again?.noiseSeed, s.settings.noiseSeed, "the noise seed stays the session's for good")
    }
}

final class AddressTests: XCTestCase {
    func testAddressesAndSearches() {
        let engine = SearchEngine.duckDuckGo
        XCTAssertEqual(AddressInput.resolve("example.com", engine: engine)?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInput.resolve("http://x.lumentest:28380/page", engine: engine)?.absoluteString, "http://x.lumentest:28380/page")
        XCTAssertEqual(AddressInput.resolve("localhost:3000/a", engine: engine)?.absoluteString, "http://localhost:3000/a")
        XCTAssertEqual(AddressInput.resolve("192.168.1.10", engine: engine)?.absoluteString, "http://192.168.1.10")
        XCTAssertEqual(AddressInput.resolve("погода в берлине", engine: engine)?.host, "duckduckgo.com")
        XCTAssertEqual(AddressInput.resolve("swift 6.2", engine: engine)?.host, "duckduckgo.com", "a version number is not a host")
        XCTAssertEqual(AddressInput.resolve("a&b=c", engine: engine)?.query, "q=a%26b%3Dc")
        XCTAssertNil(AddressInput.resolve("   ", engine: engine))
    }

    func testEveryEngineSearchesOnItsOwnHost() {
        for engine in SearchEngine.allCases {
            XCTAssertEqual(engine.searchURL(for: "lumen").host, engine.host, engine.title)
            XCTAssertTrue(engine.searchURL(for: "lumen").absoluteString.contains("lumen"))
        }
    }

    func testLocaleAndFlags() {
        XCTAssertEqual(CountryLocale.language(forCountry: "de"), "de-DE")
        XCTAssertEqual(CountryLocale.language(forCountry: "ZZ"), "en-US")
        XCTAssertEqual(CountryLocale.flag("DE"), "🇩🇪")
        XCTAssertEqual(UserAgentPreset.safariApplicationName(systemVersion: "27.2"), "Version/27.2 Mobile/15E148 Safari/604.1")
        XCTAssertTrue(UserAgentPreset.all.allSatisfy { $0.userAgent.hasSuffix("Safari/604.1") })
    }
}

/// A profile that lived behind a proxy never opens without one it may use (the owner, 8 November).
final class LockTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testLockRule() {
        let proxyID = UUID()
        let bound = Session(name: "Счета", proxyID: proxyID)
        XCTAssertTrue(bound.boundToProxy, "a session given a proxy is bound to proxies")
        XCTAssertEqual(SessionLock.of(bound, proxyExists: true, access: .full), .open, "its proxy usable: it opens")
        let lost = Access(proxies: false, reason: "Доступ к прокси закончился.")
        XCTAssertEqual(SessionLock.of(bound, proxyExists: true, access: lost), .locked(reason: "Доступ к прокси закончился."),
                       "access lost: locked, never direct")
        XCTAssertTrue(SessionLock.of(bound, proxyExists: false, access: .full).isLocked, "its proxy deleted: locked")
        var unset = bound
        unset.proxyID = nil
        XCTAssertTrue(SessionLock.of(unset, proxyExists: false, access: .full).isLocked, "its proxy taken away, still bound: locked")
        let free = Session(name: "Чистый")
        XCTAssertFalse(free.boundToProxy)
        XCTAssertEqual(SessionLock.of(free, proxyExists: false, access: lost), .open, "a session that never had a proxy opens")
    }

    func testBindingLastsAndIsKept() {
        let catalog = SessionCatalog(store: LumenStore(root: root))
        let s = catalog.create(name: "Счета")
        let proxyID = UUID()
        catalog.setProxy(s.id, proxyID: proxyID)
        XCTAssertEqual(catalog.session(s.id)?.boundToProxy, true)
        catalog.forgetProxy(proxyID)
        XCTAssertNil(catalog.session(s.id)?.proxyID)
        XCTAssertEqual(catalog.session(s.id)?.boundToProxy, true, "its proxy deleted, it stays bound (and so locked)")
        XCTAssertEqual(SessionCatalog(store: LumenStore(root: root)).session(s.id)?.boundToProxy, true, "bound across a relaunch")
        catalog.setProxy(s.id, proxyID: nil, unbind: true)
        XCTAssertEqual(catalog.session(s.id)?.boundToProxy, false, "only the person's own choice unbinds it")
    }

    func testASessionSavedBeforeBindingIsBoundIfItHasAProxy() throws {
        let encoder = JSONEncoder()
        var withProxy = try JSONSerialization.jsonObject(with: encoder.encode(Session(name: "A", proxyID: UUID()))) as! [String: Any]
        withProxy.removeValue(forKey: "boundToProxy")
        var without = try JSONSerialization.jsonObject(with: encoder.encode(Session(name: "B"))) as! [String: Any]
        without.removeValue(forKey: "boundToProxy")
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode(Session.self, from: JSONSerialization.data(withJSONObject: withProxy)).boundToProxy)
        XCTAssertFalse(try decoder.decode(Session.self, from: JSONSerialization.data(withJSONObject: without)).boundToProxy)
    }
}
