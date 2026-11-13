import XCTest

/// The App Store's screenshots, in Russian and in English — by hand only: the workflow's suite
/// "ScreenshotTests" (ci.sh then takes the 6.9-inch iPhone, sets the status bar, starts the testbed's
/// demo proxy and sorts the pictures into appstore/<language>/). Elsewhere it is skipped.
///
/// What is on them is the app's own: a list a person would have after some weeks (AppStoreSeed.swift,
/// DEBUG builds only), a session's page through its proxy, its settings, the proxies with their checks.
/// Nothing is drawn over a screen. The checks here only make sure each screen is the one meant before
/// it is taken.
final class ScreenshotTests: LumenUITestCase {
    func testTheAppStoresScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_SCREENS"] == "1",
                          "the App Store's screenshots are taken by hand (suite ScreenshotTests)")
        for language in ["ru", "en"] { take(language) }
    }

    private func take(_ language: String) {
        let english = language == "en"
        func t(_ ru: String, _ en: String) -> String { english ? en : ru }
        let app = XCUIApplication()
        app.launchArguments = ["-LumenResetState"]
        app.launchEnvironment["LUMEN_TEST_LANGUAGE"] = language
        app.launchEnvironment["LUMEN_TEST_ACCESS"] = "full"
        app.launchEnvironment["LUMEN_TEST_SEED"] = "appstore"
        app.launch()
        self.app = app
        let list = app.navigationBars[t("Сессии", "Sessions")]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the sessions list comes up (\(language))")
        let store = t("Магазин — Берлин", "Store — Berlin")
        wait(sessionCard(store), "the seeded sessions are there")
        sleep(2)   // the cards' last-opened times and flags settle
        snap("\(language)-01-sessions")

        // A session's page through its proxy: the page reads its time zone and language — Berlin's.
        openSession(store)
        go("http://check.example/?l=\(language)")
        let zone = app.webViews.staticTexts["Europe/Berlin"]
        XCTAssertTrue(zone.waitForExistence(timeout: 30), "the page came through Berlin and reads its time zone")
        XCTAssertTrue(app.webViews.staticTexts[t("Через прокси", "Through the proxy")].exists, "the page says it came through the proxy")
        if app.keyboards.count > 0 { app.webViews.firstMatch.tap() }
        sleep(2)
        snap("\(language)-02-browser")

        // Its settings: the proxy, the device profile, the time zone and language by the proxy's country.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the session's settings open")
        sleep(1)
        snap("\(language)-03-settings")
        app.buttons["settingsDone"].tap()
        waitForBrowser(session: store)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "back on the list")

        // The proxies, each with its check: alive, where it exits, whether it relays UDP.
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars[t("Прокси", "Proxies")], "the proxies open")
        wait(proxyRow(t("Берлин", "Berlin")), "the seeded proxies are there")
        sleep(1)
        snap("\(language)-04-proxies")
        app.terminate()
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
