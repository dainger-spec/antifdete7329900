import XCTest
@testable import BrowserCore

/// A recording: which page loads become steps, what typing leaves, and each step as a line.
final class ScenarioRecordingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_470_400)

    private func lines(_ recording: ScenarioRecording) -> [String] {
        recording.steps.map { ScenarioRecording.line(for: $0, passwordNote: "the password is not recorded") }
    }

    func testASignInBecomesAScenario() {
        var recording = ScenarioRecording()
        XCTAssertEqual(recording.loaded("https://shop.example/login", at: start), [RecordedStep(.goto, value: "https://shop.example/login")])
        _ = recording.acted(RecordedStep(.fill, selector: "#user", value: "al"), at: start.addingTimeInterval(2))
        _ = recording.acted(RecordedStep(.fill, selector: "#user", value: "alice"), at: start.addingTimeInterval(3))
        _ = recording.acted(RecordedStep(.fill, selector: "input[name=\"password\"]", value: "s3cret", secret: true), at: start.addingTimeInterval(5))
        _ = recording.acted(RecordedStep(.click, selector: "text=Sign in"), at: start.addingTimeInterval(6))
        // The page the click led to, and the redirect after it: one wait, not an address.
        XCTAssertEqual(recording.loaded("https://shop.example/check", at: start.addingTimeInterval(7)), [RecordedStep(.load)])
        XCTAssertEqual(recording.loaded("https://shop.example/account", at: start.addingTimeInterval(8)), [])
        // Later, an address typed into the window's field.
        _ = recording.loaded("https://shop.example/orders", at: start.addingTimeInterval(60))
        // The same address again says nothing; a page that is not the web's is not a step.
        XCTAssertEqual(recording.loaded("https://shop.example/orders", at: start.addingTimeInterval(90)), [])
        XCTAssertEqual(recording.loaded("about:blank", at: start.addingTimeInterval(91)), [])

        XCTAssertEqual(lines(recording), [
            "await page.goto('https://shop.example/login');",
            "await page.type('#user', 'alice');",
            "await page.type('input[name=\"password\"]', params.password || ''); // the password is not recorded",
            "await page.click('text=Sign in');",
            "await page.waitForLoadState();",
            "await page.goto('https://shop.example/orders');",
        ])
        XCTAssertFalse(recording.steps.contains { $0.value == "s3cret" }, "a password's text is never kept in a step")
    }

    func testEnterAndWhatCannotBeReplayed() {
        var recording = ScenarioRecording()
        _ = recording.loaded("https://search.example/", at: start)
        _ = recording.acted(RecordedStep(.fill, selector: "#q", value: "lumen"), at: start.addingTimeInterval(1))
        _ = recording.acted(RecordedStep(.press, value: "Enter"), at: start.addingTimeInterval(2))
        _ = recording.loaded("https://search.example/?q=lumen", at: start.addingTimeInterval(3))
        _ = recording.acted(RecordedStep(.note, value: "a choice in a list\nis not replayed"), at: start.addingTimeInterval(9))
        // A field that held text when the person came to it: selected first, so the typing replaces it.
        _ = recording.acted(RecordedStep(.fill, selector: "#q", value: "lumen browser", replaces: true), at: start.addingTimeInterval(12))
        XCTAssertEqual(lines(recording), [
            "await page.goto('https://search.example/');",
            "await page.type('#q', 'lumen');",
            "await page.press('Enter');",
            "await page.waitForLoadState();",
            "// a choice in a list is not replayed",
            "await page.click('#q'); await page.press('Meta+a'); await page.type('#q', 'lumen browser');",
        ])
    }

    /// A choice in a list is a step a replay makes again; the click that opened the list is not
    /// recorded at all (the page's side leaves it out), and a card's month is said without it.
    func testAChoiceInAListIsReplayed() {
        var recording = ScenarioRecording()
        _ = recording.loaded("https://shop.example/address", at: start)
        _ = recording.acted(RecordedStep(.select, selector: "select[name=\"country\"]", value: "FR", label: "France"), at: start.addingTimeInterval(1))
        // Chosen again before anything else: the last choice is the step.
        XCTAssertEqual(recording.acted(RecordedStep(.select, selector: "select[name=\"country\"]", value: "DE", label: "Germany"),
                                       at: start.addingTimeInterval(2)),
                       [RecordedStep(.select, selector: "select[name=\"country\"]", value: "DE", label: "Germany")])
        // A list whose choice loads a page (a language's): the page is waited for, as after a click.
        _ = recording.acted(RecordedStep(.select, selector: "#language", value: "it", label: "it"), at: start.addingTimeInterval(10))
        XCTAssertEqual(recording.loaded("https://shop.example/it/address", at: start.addingTimeInterval(11)), [RecordedStep(.load)])
        // A card's month: which list, not which month — whatever the page's side sent.
        _ = recording.acted(RecordedStep(.select, selector: "#exp-month", value: "07", secret: true, label: "July"), at: start.addingTimeInterval(20))
        _ = recording.acted(RecordedStep(.select, selector: "#size", value: "it's \"L\"", label: "Large\n(L)"), at: start.addingTimeInterval(21))
        XCTAssertEqual(lines(recording), [
            "await page.goto('https://shop.example/address');",
            "await page.selectOption('select[name=\"country\"]', 'DE'); // Germany",
            "await page.selectOption('#language', 'it');",
            "await page.waitForLoadState();",
            "// select #exp-month: •••",
            "await page.selectOption('#size', 'it\\'s \"L\"'); // Large (L)",
        ])
        XCTAssertFalse(recording.steps.contains { $0.value == "07" || $0.label == "July" }, "a card's choice is never kept in a step")
    }

    func testTextIsQuotedAsJavaScript() {
        XCTAssertEqual(ScenarioRecording.quoted("it's a \\ \"test\"\nline\u{2028}"), #"'it\'s a \\ "test"\nline"# + "\\u2028'")
        XCTAssertEqual(ScenarioRecording.quoted("привет"), "'привет'")
        XCTAssertEqual(ScenarioRecording.quoted("\u{01}"), #"'\x01'"#)
    }
}
