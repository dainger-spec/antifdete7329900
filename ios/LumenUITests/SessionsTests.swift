import XCTest

/// A person's path through the session list, checked by what the screen shows.
final class SessionsTests: LumenUITestCase {
    /// Create two sessions with a description and tags, find one by a tag, rename it, open it, quit
    /// the app, start it again: both are there as they were left; delete one, and it stays deleted.
    func testSessionListPersonPath() {
        launch(reset: true)
        wait(app.staticTexts["Сессий пока нет"], "an empty list says so")
        shot("01 empty list")

        createSession(name: "Работа", notes: "Рекламный кабинет", tags: "ads, fb")
        createSession(name: "Почта", tags: "mail")
        XCTAssertTrue(sessionCard("Работа").label.contains("Рекламный кабинет"), "the card shows the description: \(sessionCard("Работа").label)")
        XCTAssertTrue(sessionCard("Работа").label.contains("#fb"), "the card shows the tags: \(sessionCard("Работа").label)")
        XCTAssertTrue(sessionCard("Почта").label.contains("Без прокси"), "the card says there is no proxy")
        XCTAssertTrue(sessionCard("Почта").label.contains("Ещё не открывали"), "the card says it was never opened")
        shot("02 two sessions")

        // The search finds a session by a tag, and only it.
        search("fb")
        wait(sessionCard("Работа"), "the tag finds its session")
        XCTAssertFalse(sessionCard("Почта").exists, "the other session is not shown")
        shot("03 search by tag")
        clearSearch()
        wait(sessionCard("Почта"), "a cleared search shows everything again")

        // Rename and a new description, through the editor.
        openEditor(of: "Работа")
        replaceText(app.textFields["sessionName"], with: "Реклама")
        replaceText(app.textFields["sessionNotes"], with: "Кабинет и счета")
        app.buttons["saveSession"].tap()
        wait(sessionCard("Реклама"), "the renamed card is shown")
        XCTAssertFalse(sessionCard("Работа").exists, "the old name is gone")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Кабинет и счета"), "the card shows the new description: \(sessionCard("Реклама").label)")

        // Opening a session is what "last opened" shows.
        sessionCard("Реклама").tap()
        wait(app.textFields["addressBar"], "the session opens in its browser")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(sessionCard("Реклама"), "back to the list")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Открывали"), "the card says it was opened: \(sessionCard("Реклама").label)")
        // When, in the app's language, not the simulator's (English): "Открывали now" was on the App Store's screenshots.
        XCTAssertNil(sessionCard("Реклама").label.range(of: #"Открывали [A-Za-z]"#, options: .regularExpression),
                       "the card says when in Russian: \(sessionCard("Реклама").label)")
        shot("04 renamed and opened")

        // Quit and start again: everything as it was left.
        relaunch()
        wait(sessionCard("Реклама"), "after a relaunch the renamed session is there")
        wait(sessionCard("Почта"), "after a relaunch the other session is there")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Кабинет и счета"), "the new description survives a relaunch: \(sessionCard("Реклама").label)")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Открывали"), "when it was opened survives a relaunch")
        search("ads")
        wait(sessionCard("Реклама"), "after a relaunch the tag still finds it")
        clearSearch()
        shot("05 after relaunch")

        // Delete, and it stays deleted.
        openEditor(of: "Почта")
        app.buttons["deleteSession"].tap()
        touchable("confirmDelete", "deleting asks first").tap()
        waitGone(sessionCard("Почта"), "the deleted session leaves the list")
        relaunch()
        wait(sessionCard("Реклама"), "the other session is still there")
        XCTAssertFalse(sessionCard("Почта").exists, "the deleted session does not come back")
        shot("06 after delete and relaunch")
    }

    /// The owner (8 November): a profile that lived behind a proxy never opens directly when its proxy
    /// may not be used — the access lost, its proxy deleted. Not one page, not one request from the
    /// device's own address: judged by the testbed's own count, then by the screen.
    func testLockedProfileNeverOpensDirect() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает")
        leaveProxies()
        createSession(name: "Чистый")   // never had a proxy: it reads the testbed's count
        createSession(name: "Счета")
        openSession("Счета")
        chooseProxy("Берлин", in: "Счета")
        openPage("http://lock-\(run).lumentest:28380/whoami?t=before")
        page("via: прокси A")
        backToList()

        // The access lost: the profile's tab, restored, would load its page again — from where?
        relaunch(access: "none")
        openLockedOrNot("Счета")
        assertNothingDirect(run, "the access lost")
        XCTAssertTrue(sessionCard("Счета").label.contains("Заперт"), "the card says the profile is locked: \(sessionCard("Счета").label)")
        sessionCard("Счета").tap()
        wait(app.descendants(matching: .any)["lockedSession"], "the profile says why it does not open")
        shot("50 a locked profile")
        backToList()

        // The access back, the profile's proxy deleted: still locked, still nothing direct.
        relaunch()
        app.buttons["proxiesButton"].tap()
        wait(proxyRow("Берлин"), "the proxy list opens").swipeLeft()
        wait(app.buttons["Удалить"], "the row offers to delete it").tap()
        waitGone(proxyRow("Берлин"), "the proxy is gone")
        leaveProxies()
        openLockedOrNot("Счета")
        assertNothingDirect(run, "its proxy deleted")
        sessionCard("Счета").tap()
        wait(app.descendants(matching: .any)["lockedSession"], "the profile with its proxy deleted stays locked")
        backToList()
    }

    /// Opens a session's screen whatever it shows, waits as long as its tab would take to load, leaves.
    private func openLockedOrNot(_ name: String) {
        wait(sessionCard(name), "the session \(name) is in the list").tap()
        sleep(10)
        backToList()
    }

    /// The testbed saw the profile's site through proxy A once (the visit before) and never directly.
    private func assertNothingDirect(_ run: String, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        openSession("Чистый")
        openPage("http://127.0.0.1:28380/__seen?token=lock-\(run)&when=\(when.hashValue)")
        let route = pageLine("route lock-\(run): ")
        XCTAssertTrue(route.contains("direct=0 "), "\(when): a locked profile reached the site from the device's address — \(route)",
                      file: file, line: line)
        XCTAssertTrue(route.contains("A=1 "), "\(when): the one visit is the one before, through the proxy — \(route)", file: file, line: line)
        backToList()
    }
}
