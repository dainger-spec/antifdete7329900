import XCTest

/// What every end-to-end test shares: a launch from nothing or a relaunch on what is there, the
/// planted faults handed on to the app (the red runs), screenshots of what the person sees.
class LumenUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// `reset`: the app starts with no sessions, proxies or WebKit data at all. `environment`: test
    /// hooks of a DEBUG build, for this launch only.
    @discardableResult
    func launch(reset: Bool, access: String? = nil, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = reset ? ["-LumenResetState"] : []
        // The rights the app starts with, DEBUG builds only: everything, for a test that checks
        // something else; "free" — the free level; "none" — a paid period that ended; "account" —
        // nothing fixed: the Lumen account decides, as in a release build (AccountTests).
        app.launchEnvironment["LUMEN_TEST_ACCESS"] = access ?? "full"
        // xcodebuild hands TEST_RUNNER_LUMEN_FAULTS to this process as LUMEN_FAULTS.
        if let faults = ProcessInfo.processInfo.environment["LUMEN_FAULTS"], !faults.isEmpty {
            app.launchEnvironment["LUMEN_FAULTS"] = faults
        }
        // The proxy check asks the testbed's geolocation service and STUN server (through the proxy).
        app.launchEnvironment["LUMEN_TEST_GEO_URL"] = "http://geo.lumentest:28380/geo.json"
        app.launchEnvironment["LUMEN_TEST_STUN"] = "stun.lumentest:3478"
        // The relay's port on the screen (DEBUG builds only), for the relay's own checks.
        app.launchEnvironment["LUMEN_TEST_HOOKS"] = "1"
        // The network probe's address echo: the testbed's.
        app.launchEnvironment["LUMEN_TEST_ECHO"] = "http://echo.lumentest:28380/ip.json"
        for (name, value) in environment { app.launchEnvironment[name] = value }
        app.launch()
        self.app = app
        XCTAssertTrue(app.navigationBars["Сессии"].waitForExistence(timeout: 30), "the sessions list comes up")
        return app
    }

    /// Quit the app the way the system does and start it again on what it saved.
    func relaunch(access: String? = nil, environment: [String: String] = [:]) {
        app.terminate()
        launch(reset: false, access: access, environment: environment)
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

    /// Replaces a text field's whole content: touch it, then its clear button (CI run 10: deleting
    /// backwards from where the touch put the cursor left the tail of a long address in place).
    /// Then it checks the field holds exactly `text` (CI run 11: after a relaunch the first keyboard was
    /// slow, no clear button came in time, and the new address was spliced into the old one).
    func replaceText(_ field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        let placeholder = field.placeholderValue ?? ""
        var current = (field.value as? String) ?? ""
        if current == placeholder { current = "" }
        if !current.isEmpty {
            let clear = field.buttons["Clear text"]
            if clear.waitForExistence(timeout: 8), clear.isHittable {
                clear.tap()
            } else {
                // No clear button: the cursor to the far end, then delete it all.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            }
        }
        field.typeText(text)
        var now = (field.value as? String) ?? ""
        if now == (field.placeholderValue ?? "") { now = "" }
        XCTAssertEqual(now, text, "the field holds what was typed", file: file, line: line)
    }

    // MARK: Browser

    /// The testbed's site on this Mac (ios/testbed/testbed.py), reached directly.
    let site = "127.0.0.1:28380"

    func openSession(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        wait(sessionCard(name), "the session \(name) is in the list", file: file, line: line).tap()
        waitForBrowser(session: name, file: file, line: line)
    }

    /// Waits until the session's browser is there: its address bar.
    func waitForBrowser(session name: String, file: StaticString = #filePath, line: UInt = #line) {
        wait(app.textFields["addressBar"], "the session \(name) browses", timeout: 30, file: file, line: line)
    }

    /// The selected tab still shows the page at `target`: a proxy change keeps the tabs as they are
    /// (no new web view, no relaunch — the session's relay takes the change).
    func assertTabKept(_ target: String, file: StaticString = #filePath, line: UInt = #line) {
        let shown = app.webViews.staticTexts.matching(atLine(target)).firstMatch
        // 15 s, not 5 (CI run 24: a kept page not yet back in the accessibility tree after the settings
        // closed); a tab the change dropped does not come back in any time.
        XCTAssertTrue(shown.waitForExistence(timeout: 15), "the tab kept its page through the proxy change (at: \(target))",
                      file: file, line: line)
    }

    func backToList() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(app.navigationBars["Сессии"], "back on the session list")
    }

    /// Types into the address bar and goes.
    func go(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let bar = wait(app.textFields["addressBar"], "the address bar is there", file: file, line: line)
        replaceText(bar, with: text, file: file, line: line)
        bar.typeText("\n")
    }

    /// Goes to a testbed page and waits until the screen shows that page, not the one before it: the
    /// page says which request it answers ("at: /env?changed=1"), so every visit needs its own query.
    func openPage(_ url: String, file: StaticString = #filePath, line: UInt = #line) {
        go(url)
        var rest = url
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        let target = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        let shown = app.webViews.staticTexts.matching(atLine(target)).firstMatch
        if shown.waitForExistence(timeout: 20) { return }
        let wanted = "at: " + target
        let found = screenLabels().contains { $0 == wanted || $0.hasPrefix(wanted + " — ") }
        XCTAssertTrue(found, "the page at \(target) is shown", file: file, line: line)
    }

    /// Every label on the screen, from the whole accessibility snapshot of the app. A query of the
    /// web view's texts sometimes finds nothing for its whole wait while the page is there: CI run
    /// 37 (the testbed had served the page 3 s after it was asked for) and run 42 (the snapshot
    /// taken for the failure, a second after the 20 s wait, had the very line the query had looked
    /// for). The page helpers below ask this snapshot before they say a page is not shown.
    func screenLabels() -> [String] {
        let tree = app.debugDescription
        guard let regex = try? NSRegularExpression(pattern: "label: '([^']*)'") else { return [] }
        let matches = regex.matches(in: tree, range: NSRange(tree.startIndex..., in: tree))
        return matches.compactMap { match in Range(match.range(at: 1), in: tree).map { String(tree[$0]) } }
    }

    /// Text the page shows (a static text of the web view whose label contains `text`).
    @discardableResult
    func page(_ text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if element.waitForExistence(timeout: timeout) { return element }
        XCTAssertTrue(screenLabels().contains { $0.contains(text) }, "the page shows \"\(text)\"", file: file, line: line)
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
        if element.waitForExistence(timeout: 20) { return element.label }
        let label = screenLabels().first { $0.hasPrefix(prefix) && !$0.hasSuffix("…") }
        XCTAssertNotNil(label, "the page shows \(prefix)…", file: file, line: line)
        return label ?? ""
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

    /// Nothing of the page `name` is on the screen a while later: not its "at:" line, and no
    /// "via: напрямую" (what a page that went around its proxy shows here).
    func assertNothingLoaded(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        sleep(8)
        // The page's own "at:" line says "напрямую" when it came directly (the testbed): found where the
        // "via:" paragraph sometimes is not (CI runs 20, 21).
        let shown = webText("?t=\(name)")
        let direct = webText("напрямую") ?? (shown?.contains("напрямую") == true ? shown : nil)
        XCTAssertTrue(direct == nil, "\(name): the page did not go direct (\(oneLine(direct)))", file: file, line: line)
        XCTAssertTrue(shown == nil, "\(name): the page did not load (\(oneLine(shown)))", file: file, line: line)
    }

    /// A testbed page's "at:" line for `target`: exactly, or with the testbed's " — напрямую".
    func atLine(_ target: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "at: " + target, "at: " + target + " — ")
    }

    /// One line, for a failure message: the first line of a failure is the one ci.sh reads.
    func oneLine(_ text: String?) -> String { (text ?? "").replacingOccurrences(of: "\n", with: " ") }

    /// The page's text that contains `fragment`, by either query: WebKit puts a paragraph's text on the
    /// element itself or on a child (CI run 20: "via: напрямую" on the screen, and `containing` alone
    /// did not find it, while it found the "at:" line of the same page).
    func webText(_ fragment: String) -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let own = app.webViews.staticTexts.matching(predicate).firstMatch
        if own.exists { return own.label }
        let inner = app.webViews.staticTexts.containing(predicate).firstMatch
        return inner.exists ? inner.label : nil
    }

    /// The /hold page's WebSocket was closed (within 10 s).
    func assertWebSocketClosed(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = webSocketState()
        XCTAssertEqual(state, "ws: closed", "\(what): the page still says \(state)", file: file, line: line)
    }

    /// What a /hold page says of its WebSocket: "ws: closed" once it is (waiting up to 10 s), else what
    /// it says now.
    func webSocketState() -> String {
        let deadline = Date().addingTimeInterval(10)
        while webText("ws: closed") == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        return webText("ws: closed") ?? webText("ws: ") ?? "nothing"
    }

    // MARK: Proxies

    func proxyRow(_ name: String) -> XCUIElement { app.descendants(matching: .any)["proxy-\(name)"] }

    func addProxy(name: String, kind: String, host: String = "127.0.0.1", port: String, user: String, password: String) {
        // An offer that came late, after the previous form (CI run 15), is caught here.
        XCTAssertFalse(passwordOffer.exists, "the password prompt: an offer to save a password is on the screen before adding \(name)")
        // A touch while the previous form is still closing is lost (CI run 10): touch again until it opens.
        let add = wait(app.buttons["newProxy"], "the list offers a new proxy")
        let field = app.textFields["proxyName"]
        for _ in 0..<3 where !field.exists {
            if add.isHittable { add.tap() }
            _ = field.waitForExistence(timeout: 5)
        }
        wait(field, "the new proxy form opens (for \(name))")
        typeInto(field, name)
        app.segmentedControls["proxyKind"].buttons[kind].tap()
        typeInto(app.textFields["proxyHost"], host)
        typeInto(app.textFields["proxyPort"], port)
        typeInto(app.textFields["proxyUser"], user)
        typeInto(app.secureTextFields["proxyPassword"], password)
        // A touch while the keyboard still moves is lost (CI run 29: the form of the second proxy stayed
        // open): if the form is still there after 5 s, its button is touched again.
        let save = app.buttons["saveProxy"]
        save.tap()
        for _ in 0..<2 where !field.waitForNonExistence(timeout: 5) {
            if save.isHittable { save.tap() }
        }
        waitGone(field, "the proxy form closes (\(name))")
        // iOS must not offer to keep the proxy's password among the person's own (CI runs 12, 13: its
        // "Save Password?" came a moment after the form closed, as a remote view app.alerts does
        // not list, and blocked the screen). After a moment the list must still take a touch.
        let offer = passwordOffer
        XCTAssertFalse(offer.waitForExistence(timeout: 10), "the password prompt: nothing offers to save the password of \(name): \(offer.exists ? offer.label : "")")
        XCTAssertTrue(add.isHittable, "the password prompt: the proxy list stays usable after saving \(name) (nothing covers it)")
        wait(proxyRow(name), "the proxy \(name) is in the list")
    }

    /// iOS's offer to keep a password among the person's own (a remote view: by its words).
    var passwordOffer: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS[c] 'Save Password' OR label CONTAINS[c] 'Сохранить пароль' OR label == 'Not Now' OR label == 'Не сейчас'")).firstMatch
    }

    /// Touches a field and types once it has the keyboard (CI run 12: "Neither element nor any
    /// descendant has keyboard focus" when typing right after the touch).
    func typeInto(_ field: XCUIElement, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        reveal(field, "the field is there", file: file, line: line).tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        if XCTWaiter.wait(for: [expectation(for: focused, evaluatedWith: field)], timeout: 5) != .completed {
            field.tap()
            _ = XCTWaiter.wait(for: [expectation(for: focused, evaluatedWith: field)], timeout: 5)
        }
        field.typeText(text)
    }

    /// Waits until a proxy's row says `text` (its check is done).
    func waitRow(_ name: String, says text: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: proxyRow(name))], timeout: timeout)
        XCTAssertEqual(result, .completed, "the row of \(name) says \(text): \(proxyRow(name).label)", file: file, line: line)
    }

    /// From the proxy list back to the sessions (CI run 10: the bar's first button is not always
    /// the back button there — the list's "+" is in the same bar).
    func leaveProxies(file: StaticString = #filePath, line: UInt = #line) {
        let sessions = app.navigationBars["Сессии"]
        let bar = app.navigationBars["Прокси"]
        let back = bar.buttons.matching(NSPredicate(format: "identifier != %@", "newProxy")).firstMatch
        if back.exists, back.isHittable { back.tap() }
        if !sessions.waitForExistence(timeout: 4) {
            // CI run 11: the button did not take it back. A person's other way: swipe from the left edge.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        wait(sessions, "back on the session list", file: file, line: line)
    }

    /// The session's device profile: "Полный" or "Упрощённый", from its settings.
    func chooseProfile(_ level: String, in session: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open", file: file, line: line)
        reveal(app.segmentedControls["profileLevel"], "the device profile's choice is there").buttons[level].tap()
        app.buttons["settingsDone"].tap()
        waitForBrowser(session: session, file: file, line: line)
    }

    func chooseProxy(_ name: String, in session: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        reveal(app.buttons[name], "the settings list the proxy \(name)").tap()
        app.buttons["settingsDone"].tap()
        waitForBrowser(session: session, file: file, line: line)
    }

    // MARK: Sessions

    func sessionCard(_ name: String) -> XCUIElement { app.buttons["session-\(name)"] }

    func createSession(name: String, notes: String = "", tags: String = "") {
        app.buttons["newSession"].tap()
        let nameField = wait(app.textFields["sessionName"], "the new session form opens")
        // Typed once the field has the keyboard (CI run 20: "Neither element nor any descendant has
        // keyboard focus" typing the name right after the touch).
        typeInto(nameField, name)
        if !notes.isEmpty { typeInto(app.textFields["sessionNotes"], notes) }
        if !tags.isEmpty { typeInto(app.textFields["sessionTags"], tags) }
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
