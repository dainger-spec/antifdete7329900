import XCTest
@testable import BrowserCore

/// A run's failure, as the runner says it in English, read back so that the app can say it in the
/// interface's language (`ScenarioFailureReason`); what it does not know is kept as it is.
final class ScenarioFailureReasonTests: XCTestCase {
    private func parse(_ reason: String) -> ScenarioFailureReason { ScenarioFailureReason.parse(reason).reason }

    func testAmbiguousRecordedControlNamesItsStep() {
        let parsed = ScenarioFailureReason.parse("Error: multiple controls match Save (line 3)")
        XCTAssertEqual(parsed.reason, .ambiguous(selector: "Save"))
        XCTAssertEqual(parsed.line, 3)
    }

    func testTypingFailuresIdentifyTheFieldAndLine() {
        let result = ScenarioFailureReason.parse("Error: typing target lost focus: #edit (line 4)")
        XCTAssertEqual(result.reason, .typingFocus(selector: "#edit"))
        XCTAssertEqual(result.line, 4)
        XCTAssertEqual(parse("Error: typing target changed: #edit (line 4)"), .typingChanged(selector: "#edit"))
        XCTAssertEqual(parse("Error: #notes is read-only (line 2)"), .readOnly(selector: "#notes"))
    }

    func testTheLineAndJavaScriptsPrefixAreTakenOff() {
        let parsed = ScenarioFailureReason.parse("Error: no element matches #nothing-like-it (line 3)")
        XCTAssertEqual(parsed.reason, .notFound(selector: "#nothing-like-it"))
        XCTAssertEqual(parsed.line, 3)
        XCTAssertNil(ScenarioFailureReason.parse("no element matches #a").line)
    }

    func testWhatARunWaitedFor() {
        XCTAssertEqual(parse("timed out: text=My orders to be visible (line 17)"),
                       .timedOut(.element(selector: "text=My orders", state: "visible")))
        XCTAssertEqual(parse("timed out: #spinner to be hidden"), .timedOut(.element(selector: "#spinner", state: "hidden")))
        XCTAssertEqual(parse("timed out: load state domcontentloaded"), .timedOut(.load))
        XCTAssertEqual(parse("timed out: the address to match **/account"), .timedOut(.address("**/account")))
        XCTAssertEqual(parse("timed out: going to https://example.com/"), .timedOut(.opening("https://example.com/")))
        XCTAssertEqual(parse("timed out: going back"), .timedOut(.back))
        XCTAssertEqual(parse("timed out: reloading"), .timedOut(.reload))
        XCTAssertEqual(parse("timed out: the profile's process did not answer"), .timedOut(.profile))
        XCTAssertEqual(parse("timed out: something new"), .timedOut(.other("something new")))
    }

    func testWhatAnElementWas() {
        XCTAssertEqual(parse("#login is not visible"), .notVisible(selector: "#login"))
        XCTAssertEqual(parse("#buy is covered by div.cookie-banner"), .covered(selector: "#buy", by: "div.cookie-banner"))
        XCTAssertEqual(parse("#buy is covered by the page moving under the pointer"), .covered(selector: "#buy", by: nil))
        XCTAssertEqual(parse("#send is disabled"), .disabled(selector: "#send"))
        // A choice of a list that is off is said as the runner says it.
        XCTAssertEqual(parse("the option Red of #colour is disabled"), .other("the option Red of #colour is disabled"))
        XCTAssertEqual(parse("the keyboard layout has no key for \"ж\""), .untypeable("ж"))
    }

    func testNavigationAndTheScript() {
        XCTAssertEqual(parse("navigation failed: nothing to go back to"), .nothingToGoBackTo)
        XCTAssertEqual(parse("navigation failed: nothing to go forward to"), .nothingToGoForwardTo)
        XCTAssertEqual(parse("navigation failed: goto takes an http or https address (line 2)"), .notWebAddress)
        XCTAssertEqual(parse("navigation failed: The Internet connection appears to be offline."),
                       .navigation("The Internet connection appears to be offline."))
        XCTAssertEqual(parse("script error: TypeError: null is not an object"), .script("TypeError: null is not an object"))
        XCTAssertEqual(parse("12 page commands are waiting to run: write await before each one, as in await page.click('#login')"),
                       .notAwaited(12))
        XCTAssertEqual(parse("the page has no window"), .noWindow)
        XCTAssertEqual(parse("no window to run in"), .noWindow)
        XCTAssertEqual(parse("the profile could not start the run"), .couldNotStart)
    }

    func testAScriptsOwnWordsAreKept() {
        XCTAssertEqual(parse("Error: Баланс не найден (line 9)"), .other("Баланс не найден"))
        XCTAssertEqual(parse("ReferenceError: Can't find variable: pag (line 4)"), .other("ReferenceError: Can't find variable: pag"))
        XCTAssertEqual(ScenarioFailureReason.parse("ReferenceError: Can't find variable: pag (line 4)").line, 4)
    }
}
