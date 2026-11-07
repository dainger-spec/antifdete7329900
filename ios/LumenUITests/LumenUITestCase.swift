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
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("LUMEN_TEST_") {
            app.launchEnvironment[key] = value
        }
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
