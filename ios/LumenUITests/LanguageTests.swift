import XCTest

/// The app in English (the owner, 10 November: Russian and English). On an iPhone whose language is
/// not Russian every screen is English: the list, the account's screen, a session's form and settings,
/// a locked profile's reason — and no Russian letter is left on any of them.
final class LanguageTests: LumenUITestCase {
    /// Every label on the screen now; fails if one has a Russian letter in it.
    func assertEnglish(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let russian = screenLabels().filter { $0.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil }
        XCTAssertTrue(russian.isEmpty, "\(screen): every text is English — \(russian.prefix(5).joined(separator: " | "))", file: file, line: line)
    }

    func testTheAppSpeaksEnglish() {
        launch(reset: true, access: "free", language: "en")
        wait(app.staticTexts["No sessions yet"], "the empty list says so in English")
        assertEnglish("the session list")

        // The account's screen.
        app.buttons["plansButton"].tap()
        wait(app.navigationBars["Account"], "the account's screen is named in English")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Profiles: 0 of 2")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Proxies: no")
        assertEnglish("the account's screen")
        shot("80 the account's screen in English")
        app.buttons["plansDone"].tap()

        // A session: its form, its browser, its settings.
        app.buttons["newSession"].tap()
        let name = wait(app.textFields["sessionName"], "the new session form opens")
        wait(app.navigationBars["New Session"], "the form is named in English")
        assertEnglish("the new session form")
        typeInto(name, "First")
        app.buttons["saveSession"].tap()
        wait(sessionCard("First"), "the card is in the list")
        XCTAssertTrue(sessionCard("First").label.contains("No proxy"), "the card speaks English: \(sessionCard("First").label)")
        sessionCard("First").tap()
        wait(app.textFields["addressBar"], "the session browses", timeout: 30)
        XCTAssertEqual(app.textFields["addressBar"].placeholderValue, "Address or search")
        assertEnglish("the browser")
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        XCTAssertEqual(app.staticTexts["proxiesNotOnPlan"].label, "Proxies are unavailable.")
        assertEnglish("the session's settings")
        shot("81 a session's settings in English")
        app.buttons["settingsDone"].tap()
        backToList()

        // The limit's words, with their number.
        createSession(name: "Second")
        app.buttons["newSession"].tap()
        XCTAssertEqual(wait(app.staticTexts["plansBecause"], "the limit is said").label, "This iPhone can keep no more than 2 profiles.")
        assertEnglish("the limit")
    }
}
