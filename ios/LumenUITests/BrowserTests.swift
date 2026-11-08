import XCTest

/// A person's path through a session's browser, judged by what the screen shows.
final class BrowserTests: LumenUITestCase {
    /// Open a site, a second tab, follow a link, back and forward, change the search engine and
    /// search, set a cookie; quit the app and start it again: the tabs, the pages, the history, the
    /// cookie and the search engine are all there.
    func testBrowserPersonPath() {
        launch(reset: true)
        createSession(name: "Магазин")
        openSession("Магазин")
        wait(app.descendants(matching: .any)["startPage"], "a new session starts on an empty tab")
        shot("10 empty tab")

        go("\(site)/page/alpha")
        page("Страница alpha")
        waitForAddress(containing: "/page/alpha")

        // A second tab, from the tab cards.
        openTabs()
        app.buttons["newTab"].tap()
        wait(app.descendants(matching: .any)["startPage"], "the new tab is empty")
        XCTAssertEqual(app.buttons["tabsButton"].label, "Вкладки: 2", "the bar counts two tabs")
        go("\(site)/page/beta")
        page("Страница beta")

        // Follow a link on the page, then back and forward.
        // Exact ends: "/page/beta" is also how "/page/beta-next" begins.
        app.webViews.links["Дальше"].tap()
        page("Страница beta-next")
        waitForAddress(endingWith: "/page/beta-next")
        app.buttons["back"].tap()
        waitForAddress(endingWith: "/page/beta")
        app.buttons["forward"].tap()
        waitForAddress(endingWith: "/page/beta-next")
        page("Страница beta-next")
        shot("11 second tab after a link")

        // The tab cards show both tabs by their titles.
        openTabs()
        XCTAssertTrue(app.buttons["tab-0"].label.contains("alpha"), "the first card is alpha: \(app.buttons["tab-0"].label)")
        XCTAssertTrue(app.buttons["tab-1"].label.contains("beta-next"), "the second card is beta-next: \(app.buttons["tab-1"].label)")
        shot("12 tab cards")
        app.buttons["tabsDone"].tap()

        // The session's search engine: DuckDuckGo, and the address bar searches with it.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["DuckDuckGo"], "the settings list the search engines").tap()
        app.buttons["settingsDone"].tap()
        go("lumen browser")
        waitForAddress(containing: "duckduckgo.com")
        shot("13 searched with DuckDuckGo")

        // A cookie, local storage and IndexedDB, then another page in this tab (so that a restored
        // tab cannot set them again by itself).
        go("\(site)/state?set=shop")
        page("cookie: shop")
        page("idb: shop")
        go("\(site)/page/gamma")
        page("Страница gamma")

        // The history lists what was visited.
        let history = historyLabels()
        for name in ["alpha", "beta-next", "gamma"] {
            XCTAssertTrue(history.contains { $0.contains(name) }, "the history lists \(name): \(history)")
        }
        shot("14 history")
        app.buttons["historyDone"].tap()
        sleep(2) // let WebKit's network process write the cookie

        // Quit and start again.
        relaunch()
        openSession("Магазин")
        wait(app.buttons["tabsButton"], "the bar is there")
        XCTAssertEqual(app.buttons["tabsButton"].label, "Вкладки: 2", "both tabs came back")
        page("Страница gamma")
        waitForAddress(containing: "/page/gamma")
        // The cookie first, before any page could set it again.
        go("\(site)/state")
        page("cookie: shop")
        page("local: shop")
        page("idb: shop")
        page("server cookie: lumen=shop")
        shot("15 after relaunch: the cookie")
        // The tab's back list came back too.
        app.buttons["back"].tap()
        waitForAddress(containing: "/page/gamma")
        app.buttons["back"].tap()
        waitForAddress(containing: "set=shop")
        openTabs()
        XCTAssertTrue(app.buttons["tab-0"].label.contains("alpha"), "the first tab came back as alpha: \(app.buttons["tab-0"].label)")
        app.buttons["tab-0"].tap()
        page("Страница alpha")
        let after = historyLabels()
        for name in ["alpha", "beta-next", "gamma"] {
            XCTAssertTrue(after.contains { $0.contains(name) }, "after a relaunch the history lists \(name): \(after)")
        }
        app.buttons["historyDone"].tap()
        // The search engine came back: the address bar still searches with DuckDuckGo.
        go("lumen after relaunch")
        waitForAddress(containing: "duckduckgo.com")
        shot("16 after relaunch: search")

        // Closing a tab from its card.
        openTabs()
        app.buttons["closeTab-1"].tap()
        waitGone(app.buttons["tab-1"], "the closed tab's card is gone")
        app.buttons["tabsDone"].tap()
        XCTAssertEqual(app.buttons["tabsButton"].label, "Вкладки: 1")

        // Reload brings the page again from the server, which counts the times it sent it.
        go("\(site)/served")
        let served = pageNumber("served: ")
        app.buttons["reload"].tap()
        let again = app.webViews.staticTexts.matching(NSPredicate(format: "label MATCHES %@ AND label != %@", "served: [0-9]+", served)).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 20), "reload brought the page again (it said \(served))")
        shot("17 reloaded")
    }

    /// Two sessions on the same site: cookies, local storage, IndexedDB, the cache and the history of
    /// one are not seen by the other.
    func testSessionsAreIsolated() {
        launch(reset: true)
        createSession(name: "A")
        createSession(name: "B")

        openSession("A")
        go("\(site)/state?set=A")
        page("cookie: A")
        page("idb: A")
        go("\(site)/cache")
        let cachedA = pageNumber("cache: ")
        backToList()

        openSession("B")
        go("\(site)/state")
        page("cookie: none")
        page("local: none")
        page("idb: none")
        page("server cookie: none")
        go("\(site)/cache")
        let cachedB = pageNumber("cache: ")
        XCTAssertNotEqual(cachedA, cachedB, "B fetched the script itself, not from A's cache (A: \(cachedA), B: \(cachedB))")
        let history = historyLabels()
        XCTAssertFalse(history.contains { $0.contains("set=A") }, "B's history does not list A's pages: \(history)")
        shot("20 session B sees nothing of A")
        app.buttons["historyDone"].tap()
        backToList()

        // A still has its own.
        openSession("A")
        go("\(site)/state")
        page("cookie: A")
    }
}
