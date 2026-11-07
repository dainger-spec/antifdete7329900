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

        // Rename through the editor.
        openEditor(of: "Работа")
        replaceText(app.textFields["sessionName"], with: "Реклама")
        app.buttons["saveSession"].tap()
        wait(sessionCard("Реклама"), "the renamed card is shown")
        XCTAssertFalse(sessionCard("Работа").exists, "the old name is gone")

        // Opening a session is what "last opened" shows.
        sessionCard("Реклама").tap()
        wait(app.staticTexts["browserPlaceholder"], "the session opens")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(sessionCard("Реклама"), "back to the list")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Открывали"), "the card says it was opened: \(sessionCard("Реклама").label)")
        shot("04 renamed and opened")

        // Quit and start again: everything as it was left.
        relaunch()
        wait(sessionCard("Реклама"), "after a relaunch the renamed session is there")
        wait(sessionCard("Почта"), "after a relaunch the other session is there")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Рекламный кабинет"), "the description survives a relaunch: \(sessionCard("Реклама").label)")
        XCTAssertTrue(sessionCard("Реклама").label.contains("Открывали"), "when it was opened survives a relaunch")
        search("ads")
        wait(sessionCard("Реклама"), "after a relaunch the tag still finds it")
        clearSearch()
        shot("05 after relaunch")

        // Delete, and it stays deleted.
        openEditor(of: "Почта")
        app.buttons["deleteSession"].tap()
        wait(app.buttons["confirmDelete"], "deleting asks first").tap()
        waitGone(sessionCard("Почта"), "the deleted session leaves the list")
        relaunch()
        wait(sessionCard("Реклама"), "the other session is still there")
        XCTAssertFalse(sessionCard("Почта").exists, "the deleted session does not come back")
        shot("06 after delete and relaunch")
    }
}
