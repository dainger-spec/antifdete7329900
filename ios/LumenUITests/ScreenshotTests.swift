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

/// Every state of «Приборная панель» beside its mockup (the handoff's screens/<lang>-<theme>/<name>.png):
/// taken by hand with the suite "ScreenshotTests", each named d-<lang>-<theme>-<mockup's name>, which
/// ci.sh sorts into design/<lang>-<theme>/. A state that cannot be reached is said in the log and
/// skipped; the others go on (continueAfterFailure).
final class DesignShotTests: LumenUITestCase {
    private var language = "ru"
    private var theme = "dark"

    /// A touch that does not stop the shots when its element is missing: the miss is recorded, the
    /// next states are still taken (an interaction's failure ends a test even with continueAfterFailure).
    private func touch(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("not there to touch: \(element)", file: file, line: line)
            return
        }
        element.tap()
    }

    func testEveryState() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_SCREENS"] == "1", "taken by hand (suite ScreenshotTests)")
        continueAfterFailure = true
        for language in ["ru", "en"] {
            self.language = language
            theme = "dark"
            takeAll()
        }
        // Dynamic Type at AX3 on the list and the settings; VoiceOver's own audit on the list and the browser.
        language = "ru"
        theme = "dark"
        start(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        snap("ax3-k-list")
        audit("the session list")
        openSeeded(t("Магазин — Берлин", "Store — Berlin"))
        go("http://check.example/?l=\(language)")
        _ = app.webViews.staticTexts["Europe/Berlin"].waitForExistence(timeout: 30)
        audit("the browser")
        touch(app.buttons["settingsButton"])
        if app.buttons["settingsDone"].waitForExistence(timeout: 10) {
            sleep(1)
            snap("ax3-k-settings")
        }
        app.terminate()

    }

    /// Diagnostic, not a mockup's state: the list's large title with its search placed otherwise
    /// (TitleProbe), alone in a short run (suite "DesignShotTests/testTitleProbe").
    func testTitleProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_SCREENS"] == "1", "taken by hand (suite DesignShotTests)")
        continueAfterFailure = true
        language = "ru"
        theme = "dark"
        for part in ["always", "scrolltop", "late"] {
            start(env: ["LUMEN_DIAG_TITLE": part])
            snap("diag-title-\(part)")
            app.swipeUp()
            sleep(1)
            snap("diag-title-\(part)-up")
            app.swipeDown()
            sleep(1)
            snap("diag-title-\(part)-down")
            app.terminate()
        }
    }

    /// The light theme (behind its flag), every state as in the dark: a run of its own (ci.sh's suite
    /// "DesignShotTests/testEveryLightState"), both would not fit in one job's two hours.
    func testEveryLightState() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_SCREENS"] == "1", "taken by hand (suite DesignShotTests)")
        continueAfterFailure = true
        for language in ["ru", "en"] {
            self.language = language
            theme = "light"
            takeAll()
        }
    }

    private func t(_ ru: String, _ en: String) -> String { language == "en" ? en : ru }

    /// VoiceOver's audit of the screen (iOS 17's XCTest): labels, hit regions, text that grows. The
    /// page's own content is the site's, not the app's: what is inside the web view is let pass.
    private func audit(_ what: String) {
        do {
            let web = app.webViews.firstMatch
            let page = web.exists ? web.frame : .null
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .dynamicType, .textClipped]) { issue in
                let inPage = issue.element.map { $0.elementType == .webView || page.contains($0.frame) } ?? false
                if !inPage { print("LUMEN A11Y \(what): \(issue.auditType) — \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(120) ?? "")") }
                return inPage
            }
        } catch {
            XCTFail("the accessibility audit of \(what): \(error)")
        }
    }

    private func start(access: String = "full", empty: Bool = false, extra: [String] = [], env: [String: String] = [:]) {
        let app = XCUIApplication()
        app.launchArguments = ["-LumenResetState"] + extra
        app.launchEnvironment["LUMEN_TEST_LANGUAGE"] = language
        app.launchEnvironment["LUMEN_TEST_ACCESS"] = access
        app.launchEnvironment["LUMEN_TEST_SEED"] = "appstore"
        app.launchEnvironment["LUMEN_TEST_THEME"] = theme
        if empty { app.launchEnvironment["LUMEN_TEST_SEED_EMPTY"] = "1" }
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launch()
        self.app = app
        _ = app.navigationBars[t("Сессии", "Sessions")].waitForExistence(timeout: 30)
        sleep(1)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "d-\(language)-\(theme)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSeeded(_ name: String) {
        let card = app.buttons["session-\(name)"]
        guard card.waitForExistence(timeout: 15) else { return XCTFail("no session \(name)") }
        card.tap()
        _ = app.textFields["addressBar"].waitForExistence(timeout: 30)
        sleep(1)
    }

    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)
    }

    private func takeAll() {
        // The list, its search, its menu, its dialog, the new session's sheet.
        start()
        snap("k-list")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText(t("Берлин", "Berlin"))
            sleep(1)
            snap("p1-search")
            search.typeText(" #android")
            sleep(1)
            snap("p1-search-none")
        }
        start()
        let row = app.buttons["session-\(t("Магазин — Берлин", "Store — Berlin"))"]
        if row.waitForExistence(timeout: 10) {
            row.press(forDuration: 1.2)
            if app.buttons[t("Изменить", "Edit")].waitForExistence(timeout: 5) {
                snap("k-context")
                touch(app.buttons[t("Удалить", "Delete")])
                if app.buttons["confirmDelete"].waitForExistence(timeout: 5) {
                    snap("k-dialog")
                    // iOS 26 and later show the dialog as a popover with no Cancel: a touch outside closes it.
                    let cancel = app.buttons[t("Отмена", "Cancel")].firstMatch
                    if cancel.exists && cancel.isHittable { cancel.tap() } else {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
                    }
                    waitGone(app.buttons["confirmDelete"], "the dialog closes")
                }
            }
        }
        touch(app.buttons["newSession"])
        let name = app.textFields["sessionName"]
        if name.waitForExistence(timeout: 5) {
            typeInto(name, t("Оплата", "Payments"))
            sleep(1)
            snap("k-keyboard")
            touch(app.buttons[t("Отмена", "Cancel")].firstMatch)
        }

        // The browser: a page through Berlin, a new tab, the tabs, the history, the settings and their parts.
        openSeeded(t("Магазин — Берлин", "Store — Berlin"))
        go("http://check.example/?l=\(language)")
        _ = app.webViews.staticTexts["Europe/Berlin"].waitForExistence(timeout: 30)
        sleep(1)
        snap("k-browser")
        openTabs()
        touch(app.buttons["newTab"])
        sleep(1)
        go("http://check.example/?l=\(language)&tab=2")
        _ = app.webViews.staticTexts["Europe/Berlin"].waitForExistence(timeout: 30)
        openTabs()
        touch(app.buttons["newTab"])
        sleep(1)
        snap("k-newtab")
        openTabs()
        sleep(1)
        snap("k-tabs")
        touch(app.buttons["tabsDone"])
        touch(app.buttons["historyButton"])
        if app.buttons["historyDone"].waitForExistence(timeout: 5) {
            sleep(1)
            snap("p5-history")
            touch(app.buttons["historyDone"])
        }
        touch(app.buttons["settingsButton"])
        if app.buttons["settingsDone"].waitForExistence(timeout: 10) {
            sleep(1)
            snap("k-settings")
            touch(app.buttons["proxyRow"])
            if app.buttons["proxySheetDone"].waitForExistence(timeout: 5) {
                sleep(1)
                snap("k-sheet-mid")
                touch(app.buttons["proxyNone"])
                if app.alerts.firstMatch.waitForExistence(timeout: 5) {
                    snap("k-alert")
                    touch(app.alerts.firstMatch.buttons[t("Оставить прокси", "Keep the proxy")])
                }
                if app.buttons["proxySheetDone"].exists { touch(app.buttons["proxySheetDone"]) }
            }
            touch(reveal(app.buttons["profile-custom"], "the profile's own choice"))
            sleep(1)
            snap("p6-custom")
            touch(app.buttons["profile-full"])
            let browser = app.buttons["userAgentPicker"]
            app.swipeUp()   // the browser's row up on the screen, its menu under it as on the mockup
            if browser.exists {
                touch(reveal(browser, "the browser's menu"))
                sleep(1)
                snap("k-menu")
                dismissMenu()
            }
            touch(app.buttons["settingsDone"])
        }
        // A page on its way (the testbed holds it back 20 seconds): the bar's progress and its stop.
        go("http://check.example/?l=\(language)&wait=20")
        sleep(3)
        snap("k-loading")
        backToList()

        // A proxy that does not answer, and an empty history.
        openSeeded(t("Релиз — Амстердам", "Release — Amsterdam"))
        go("http://check.example/?l=\(language)")
        if app.descendants(matching: .any)["proxyNotAnswering"].waitForExistence(timeout: 40) {
            sleep(1)
            snap("p3-dead")
        }
        touch(app.buttons["historyButton"])
        if app.buttons["historyDone"].waitForExistence(timeout: 5) {
            sleep(1)
            snap("p5-history-empty")
            touch(app.buttons["historyDone"])
        }
        backToList()

        // The proxies: the list, a new one, a line that is not a proxy.
        touch(app.buttons["proxiesButton"])
        if app.navigationBars[t("Прокси", "Proxies")].waitForExistence(timeout: 10) {
            sleep(1)
            snap("p8-list")
            touch(app.buttons["newProxy"])
            let line = app.descendants(matching: .any).matching(identifier: "proxyLine").firstMatch
            if line.waitForExistence(timeout: 5) {
                typeInto(app.textFields["proxyName"], t("Берлин", "Berlin"))
                typeInto(line, "socks5://qa-berlin:secret@de1.proxy.example:1080")
                sleep(1)
                snap("p9-new")
                replaceText(line, with: "socks5://qa-berlin@")
                sleep(1)
                snap("p9-error")
                touch(app.buttons[t("Отмена", "Cancel")].firstMatch)
            }
        }

        // The paid period over: the sessions with proxies locked, one opened.
        start(access: "none")
        sleep(1)
        snap("p1-ended")
        let locked = app.buttons["session-\(t("Магазин — Берлин", "Store — Berlin"))"]
        if locked.waitForExistence(timeout: 10) {
            locked.tap()
            if app.descendants(matching: .any)["lockedSession"].waitForExistence(timeout: 10) {
                sleep(1)
                snap("k-locked")
            }
        }

        // The free level: a session's settings without proxies.
        start(access: "free")
        let free = app.buttons["session-\(t("Личное", "Personal"))"]
        if free.waitForExistence(timeout: 10) {
            free.tap()
            _ = app.textFields["addressBar"].waitForExistence(timeout: 30)
            touch(app.buttons["settingsButton"])
            if app.buttons["settingsDone"].waitForExistence(timeout: 10) {
                sleep(1)
                snap("p6-free")
            }
        }

        // Not signed in: the account, and the sign-in sheet.
        start(access: "account")
        touch(app.buttons["plansButton"])
        if app.buttons["signIn"].waitForExistence(timeout: 10) {
            sleep(1)
            snap("p10-signed-out")
            touch(app.buttons["signIn"])
            let email = app.textFields["signInEmail"]
            if email.waitForExistence(timeout: 5) {
                typeInto(email, "qa@example.com")
                typeInto(app.secureTextFields["signInPassword"], "password12")
                sleep(1)
                snap("p11-login")
            }
        }

        // Nothing yet: no session, no proxy.
        start(empty: true)
        snap("k-empty")
        touch(app.buttons["proxiesButton"])
        if app.navigationBars[t("Прокси", "Proxies")].waitForExistence(timeout: 10) {
            sleep(1)
            snap("p8-empty")
        }
        app.terminate()
    }
}
