import XCTest

/// What every end-to-end test shares: a launch from nothing or a relaunch on what is there, the
/// planted faults handed on to the app (the red runs), screenshots of what the person sees.
class LumenUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// `reset`: the app starts with no sessions, proxies or WebKit data at all.
    @discardableResult
    func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = reset ? ["-LumenResetState"] : []
        // xcodebuild hands TEST_RUNNER_LUMEN_FAULTS to this process as LUMEN_FAULTS.
        if let faults = ProcessInfo.processInfo.environment["LUMEN_FAULTS"], !faults.isEmpty {
            app.launchEnvironment["LUMEN_FAULTS"] = faults
        }
        // The proxy check asks the testbed's geolocation service and STUN server (through the proxy).
        app.launchEnvironment["LUMEN_TEST_GEO_URL"] = "http://geo.lumentest:28380/geo.json"
        app.launchEnvironment["LUMEN_TEST_STUN"] = "stun.lumentest:3478"
        app.launch()
        self.app = app
        XCTAssertTrue(app.navigationBars["Сессии"].waitForExistence(timeout: 30), "the sessions list comes up")
        return app
    }

    /// Quit the app the way the system does and start it again on what it saved.
    func relaunch() {
        app.terminate()
        launch(reset: false)
    }

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    func wait(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15,
              file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), what, file: file, line: line)
        return element
    }

    func waitGone(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10,
                  file: StaticString = #filePath, line: UInt = #line) {
        let gone = NSPredicate(format: "exists == false")
        let result = XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, what, file: file, line: line)
    }

    /// Scrolls the open form until `element` can be touched, as a person scrolls to a row: a long
    /// form (a session's settings) keeps rows below the screen out of reach (CI run 5: "DuckDuckGo").
    @discardableResult
    func reveal(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return element }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, what, file: file, line: line)
        return element
    }

    /// The one of the matching buttons a person can touch (iOS 27 shows a dialog's button twice in
    /// the accessibility tree: CI run 5, "confirmDelete").
    func touchable(_ identifier: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let all = app.buttons.matching(identifier: identifier)
        XCTAssertTrue(all.firstMatch.waitForExistence(timeout: 15), what, file: file, line: line)
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    /// Replaces a text field's whole content.
    func replaceText(_ field: XCUIElement, with text: String) {
        // The cursor goes where the field is touched: touch its far end, then delete backwards.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let placeholder = field.placeholderValue ?? ""
        var current = (field.value as? String) ?? ""
        if current == placeholder { current = "" }
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    // MARK: Browser

    /// The testbed's site on this Mac (ios/testbed/testbed.py), reached directly.
    let site = "127.0.0.1:28380"

    func openSession(_ name: String) {
        wait(sessionCard(name), "the session \(name) is in the list").tap()
        wait(app.textFields["addressBar"], "the session \(name) opens in its browser")
    }

    func backToList() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(app.navigationBars["Сессии"], "back on the session list")
    }

    /// Types into the address bar and goes.
    func go(_ text: String) {
        let bar = wait(app.textFields["addressBar"], "the address bar is there")
        replaceText(bar, with: text + "\n")
    }

    /// Goes to a testbed page and waits until the screen shows that page, not the one before it: the
    /// page says which request it answers ("at: /env?changed=1"), so every visit needs its own query.
    func openPage(_ url: String, file: StaticString = #filePath, line: UInt = #line) {
        go(url)
        var rest = url
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        let target = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        let shown = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "at: " + target)).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 20), "the page at \(target) is shown", file: file, line: line)
    }

    /// Text the page shows (a static text of the web view whose label contains `text`).
    @discardableResult
    func page(_ text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "the page shows \"\(text)\"", file: file, line: line)
        return element
    }

    /// A number the page shows after `prefix` ("cache: 3"), once the page's script has put it there.
    func pageNumber(_ prefix: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let element = app.webViews.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\(prefix)[0-9]+")).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "the page shows \(prefix)<number>", file: file, line: line)
        return element.label
    }

    /// The page's line that starts with `prefix` once its script has filled it ("canvas: 1a2b3c4d").
    func pageLine(_ prefix: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let predicate = NSPredicate(format: "label BEGINSWITH %@ AND NOT (label ENDSWITH %@)", prefix, "…")
        let element = app.webViews.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "the page shows \(prefix)…", file: file, line: line)
        return element.label
    }

    /// What the address bar shows.
    var address: String { (app.textFields["addressBar"].value as? String) ?? "" }

    func waitForAddress(containing text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: app.textFields["addressBar"])], timeout: timeout)
        XCTAssertEqual(result, .completed, "the address bar shows \(text) (it shows \(address))", file: file, line: line)
    }

    /// The address bar's value ends with `text` (an exact end: "/page/beta" is not "/page/beta-next").
    func waitForAddress(endingWith text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value ENDSWITH %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: app.textFields["addressBar"])], timeout: timeout)
        XCTAssertEqual(result, .completed, "the address bar ends with \(text) (it shows \(address))", file: file, line: line)
    }

    func openTabs() {
        app.buttons["tabsButton"].tap()
        wait(app.buttons["newTab"], "the tabs open as cards")
    }

    func historyLabels() -> [String] {
        app.buttons["historyButton"].tap()
        wait(app.navigationBars["История"], "the history opens")
        let labels = app.buttons.matching(identifier: "historyRow").allElementsBoundByIndex.map(\.label)
        return labels
    }

    // MARK: Proxies

    func proxyRow(_ name: String) -> XCUIElement { app.descendants(matching: .any)["proxy-\(name)"] }

    func addProxy(name: String, kind: String, host: String = "127.0.0.1", port: String, user: String, password: String) {
        app.buttons["newProxy"].tap()
        let field = wait(app.textFields["proxyName"], "the new proxy form opens")
        field.tap()
        field.typeText(name)
        app.segmentedControls["proxyKind"].buttons[kind].tap()
        app.textFields["proxyHost"].tap()
        app.textFields["proxyHost"].typeText(host)
        app.textFields["proxyPort"].tap()
        app.textFields["proxyPort"].typeText(port)
        app.textFields["proxyUser"].tap()
        app.textFields["proxyUser"].typeText(user)
        app.secureTextFields["proxyPassword"].tap()
        app.secureTextFields["proxyPassword"].typeText(password)
        app.buttons["saveProxy"].tap()
        wait(proxyRow(name), "the proxy \(name) is in the list")
    }

    /// Waits until a proxy's row says `text` (its check is done).
    func waitRow(_ name: String, says text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: proxyRow(name))], timeout: timeout)
        XCTAssertEqual(result, .completed, "the row of \(name) says \(text): \(proxyRow(name).label)", file: file, line: line)
    }

    func chooseProxy(_ name: String) {
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        reveal(app.buttons[name], "the settings list the proxy \(name)").tap()
        app.buttons["settingsDone"].tap()
    }

    // MARK: Sessions

    func sessionCard(_ name: String) -> XCUIElement { app.buttons["session-\(name)"] }

    func createSession(name: String, notes: String = "", tags: String = "") {
        app.buttons["newSession"].tap()
        let nameField = wait(app.textFields["sessionName"], "the new session form opens")
        nameField.tap()
        nameField.typeText(name)
        if !notes.isEmpty {
            app.textFields["sessionNotes"].tap()
            app.textFields["sessionNotes"].typeText(notes)
        }
        if !tags.isEmpty {
            app.textFields["sessionTags"].tap()
            app.textFields["sessionTags"].typeText(tags)
        }
        app.buttons["saveSession"].tap()
        wait(sessionCard(name), "the card of \(name) is in the list")
    }

    func openEditor(of name: String) {
        sessionCard(name).press(forDuration: 1.2)
        wait(app.buttons["Изменить"], "the card's menu offers to edit").tap()
        wait(app.textFields["sessionName"], "the editor opens")
    }

    func search(_ text: String) {
        let field = app.searchFields.firstMatch
        wait(field, "the list has a search field")
        replaceText(field, with: text)
    }

    func clearSearch() {
        let field = app.searchFields.firstMatch
        if let clear = field.buttons.allElementsBoundByIndex.first(where: { $0.label.contains("Clear") || $0.label.contains("Очистить") }) {
            clear.tap()
        } else {
            replaceText(field, with: "")
        }
    }
}
