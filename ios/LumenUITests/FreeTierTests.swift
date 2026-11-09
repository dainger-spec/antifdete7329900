import XCTest

/// The free plan (the owner, 8 November), from Access as a test sets it (LUMEN_TEST_ACCESS=free —
/// signing in to a Lumen account fills it once the account server is there): two profiles, no proxies,
/// each profile a whole one — its own storage, its own device profile. The plan's screen counts the
/// profiles, and the plans' site opens in Safari, never inside the app.
final class FreeTierTests: LumenUITestCase {
    func testFreePlan() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launch(reset: true, access: "free", environment: ["LUMEN_TEST_SITE_URL": "http://127.0.0.1:28380/plans-\(run)"])
        // A proxy may be kept in the list (for a paid plan); no profile goes through it.
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает")
        leaveProxies()
        createSession(name: "Первый")
        createSession(name: "Второй")

        // A third profile is not made: the plan says why, and counts.
        app.buttons["newSession"].tap()
        wait(app.staticTexts["plansBecause"], "the plans open instead of a third profile")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 2 из 2", "the plan counts the profiles")
        shot("60 the free plan: two profiles")
        app.buttons["plansDone"].tap()
        wait(app.navigationBars["Сессии"], "back on the session list")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 2,
                       "two profiles, no third")

        // No proxy for a free profile: a person who tries to give it one gets none, and a page goes
        // without one.
        openSession("Первый")
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        let berlin = app.buttons["Берлин"]
        if berlin.exists { berlin.tap() }
        app.buttons["settingsDone"].tap()
        openPage("http://free-\(run).lumentest:28380/whoami?t=free")
        XCTAssertNotNil(webText("напрямую"), "a free profile goes without a proxy: \(oneLine(webText("via:")))")
        app.buttons["settingsButton"].tap()
        wait(app.staticTexts["proxiesNotOnPlan"], "the settings say why there is no proxy")
        XCTAssertFalse(app.buttons["Берлин"].exists, "no proxy is offered on the free plan")
        shot("61 the free plan: no proxy")
        app.buttons["settingsDone"].tap()

        // Each free profile is a whole one: its own storage, its own device profile (full by default).
        go("\(site)/state?set=free1")
        page("cookie: free1")
        go("\(site)/env?free=1")
        let first = pageLine("canvas: ")
        backToList()
        openSession("Второй")
        go("\(site)/state")
        let none = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "cookie: none")).firstMatch
        XCTAssertTrue(none.waitForExistence(timeout: 20),
                      "free profiles are isolated: the second does not see the first's cookie (\(oneLine(webText("cookie:"))))")
        go("\(site)/env?free=2")
        let second = pageLine("canvas: ")
        XCTAssertNotEqual(first, second, "each free profile has its own device profile (its own canvas noise): \(first) / \(second)")
        backToList()

        // The plan's screen, and its site in Safari.
        app.buttons["plansButton"].tap()
        wait(app.staticTexts["planName"], "the plan opens")
        XCTAssertEqual(app.staticTexts["planName"].label, "Бесплатный")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: нет")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 2 из 2")
        shot("62 the plan")
        app.buttons["upgrade"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let outside = safari.wait(for: .runningForeground, timeout: 20)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "63 the plans' site"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(outside, "the site opens in Safari, outside the app (Safari: \(safari.state.rawValue))")
        app.activate()
    }
}
