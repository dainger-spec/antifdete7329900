import XCTest
@testable import BrowserCore

/// A profile's store that came up with nothing at a launch — its website data archive gone — is
/// not every cookie deleted (the audit's finding: recorded as deletions, they took the cookies out
/// of the synced document, and through sync off every other device). A store that came up with
/// what an earlier run left still tells of that run's changes, deletions included.
final class CookieLaunchTests: XCTestCase {
    private let expires = Date().addingTimeInterval(86_400 * 30)
    private let then = Date().addingTimeInterval(-3_600)

    private func cookies(_ names: String...) -> [ImportedCookie] {
        names.map { ImportedCookie(name: $0, value: "v", domain: "\($0).test", hostOnly: true, expires: expires) }
    }

    private func document(_ cookies: [ImportedCookie]) -> CookieJarDocument {
        CookieJarDocument(cookies: cookies.map { CookieJarDocument.Entry(cookie: $0, updatedAt: then) })
    }

    func testAStoreThatCameUpWithNothingDeletesNoCookie() {
        let three = cookies("a", "b", "c")
        let loaded = document(three)
        let jar = loaded.atLaunch(store: [], baseline: CookieBaseline(cookies: three, savedAt: then), storeRestored: false)
        XCTAssertEqual(jar, loaded, "the document is applied as it is: the three are put back")
        XCTAssertEqual(jar.changes(over: []).set.map(\.name).sorted(), ["a", "b", "c"])
        // Another device that has the three keeps them when it merges this one's document.
        XCTAssertEqual(CookieJarDocument.merge(loaded, jar).cookies.count, 3)
    }

    func testAStoreAnEarlierRunLeftStillTellsOfItsDeletions() {
        let three = cookies("a", "b", "c")
        let loaded = document(three)
        let jar = loaded.atLaunch(store: cookies("a", "b"), baseline: CookieBaseline(cookies: three, savedAt: then), storeRestored: true)
        XCTAssertEqual(jar.cookies.map(\.cookie.name).sorted(), ["a", "b"])
        XCTAssertEqual(jar.deleted.map(\.key.name), ["c"])
    }

    func testAnEmptyStoreAnEarlierRunLeftIsEveryCookieDeleted() {
        // The person deleted every cookie in a run that ended without a stop: that is still said.
        let three = cookies("a", "b", "c")
        let jar = document(three).atLaunch(store: [], baseline: CookieBaseline(cookies: three, savedAt: then), storeRestored: true)
        XCTAssertEqual(jar.cookies, [])
        XCTAssertEqual(jar.deleted.map(\.key.name).sorted(), ["a", "b", "c"])
    }
}
