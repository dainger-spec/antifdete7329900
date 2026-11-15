import XCTest
@testable import BrowserCore

/// "Perform actions" as the steps the driver makes: what Selenium's ActionChains sends for a
/// hover, a click, a double click, keys and the wheel — and what is refused, saying which.
final class WebDriverActionsTests: XCTestCase {
    private let element = "doc-7"

    private func body(_ sources: [[String: Any]]) -> [String: Any] { ["actions": sources] }
    private func pointer(_ actions: [[String: Any]], type: String = "mouse") -> [String: Any] {
        ["type": "pointer", "id": "mouse", "parameters": ["pointerType": type], "actions": actions]
    }
    private func keys(_ actions: [[String: Any]]) -> [String: Any] { ["type": "key", "id": "key", "actions": actions] }
    private func move(to id: String? = nil, x: Double = 0, y: Double = 0, origin: String? = nil) -> [String: Any] {
        var action: [String: Any] = ["type": "pointerMove", "duration": 250, "x": x, "y": y]
        if let id { action["origin"] = [WebDriverRoute.elementKey: id] } else if let origin { action["origin"] = origin }
        return action
    }
    private let down: [String: Any] = ["type": "pointerDown", "button": 0]
    private let up: [String: Any] = ["type": "pointerUp", "button": 0]
    private func pause(_ milliseconds: Int = 0) -> [String: Any] { ["type": "pause", "duration": milliseconds] }
    private func key(_ type: String, _ value: String) -> [String: Any] { ["type": type, "value": value] }

    private func refusal(_ sources: [[String: Any]]) -> WebDriverError? {
        do {
            _ = try WebDriverActions.steps(body(sources))
            return nil
        } catch {
            return error as? WebDriverError
        }
    }

    /// ActionChains(driver).move_to_element(menu).perform(): the pointer onto the element.
    func testAHoverIsAMove() throws {
        XCTAssertEqual(try WebDriverActions.steps(body([pointer([move(to: element)])])), [.move(.element(element), x: 0, y: 0)])
        // With an offset from the element's middle; from the viewport's corner; from where the pointer is.
        XCTAssertEqual(try WebDriverActions.steps(body([pointer([move(to: element, x: 5, y: -3), move(x: 100, y: 40, origin: "viewport"),
                                                                 move(x: 10, y: 0, origin: "pointer"), move(x: 7, y: 7)])])),
                       [.move(.element(element), x: 5, y: -3), .move(.viewport, x: 100, y: 40), .move(.pointer, x: 10, y: 0),
                        .move(.viewport, x: 7, y: 7)])
        XCTAssertEqual(try WebDriverActions.steps(body([])), [])
    }

    /// move_to_element(button).click().send_keys("ab") as Selenium pads it: the keyboard waits
    /// while the pointer acts, then the pointer while the keys are typed.
    func testAClickThenKeysTickByTick() throws {
        let steps = try WebDriverActions.steps(body([
            pointer([move(to: element), down, up, pause(), pause(), pause(), pause()]),
            keys([pause(), pause(), pause(), key("keyDown", "a"), key("keyUp", "a"), key("keyDown", "b"), key("keyUp", "b")]),
        ]))
        XCTAssertEqual(steps, [.move(.element(element), x: 0, y: 0), .press, .release, .key(.type("ab"))])
    }

    func testADoubleClickAndAPause() throws {
        let steps = try WebDriverActions.steps(body([pointer([move(to: element), down, up, pause(1500), down, up])]))
        XCTAssertEqual(steps, [.move(.element(element), x: 0, y: 0), .press, .release, .pause(1.5), .press, .release])
        // Two sources pausing in one tick wait once, the longer; no pause is longer than the limit.
        XCTAssertEqual(try WebDriverActions.steps(body([pointer([pause(200)]), keys([pause(700)])])), [.pause(0.7)])
        XCTAssertEqual(try WebDriverActions.steps(body([keys([pause(86_400_000)])])), [.pause(WebDriverActions.longestPause)])
    }

    func testKeysWithModifiersAndNamedKeys() throws {
        // key_down(CONTROL).send_keys("a").key_up(CONTROL), then Page Down, then Enter with Shift.
        let steps = try WebDriverActions.steps(body([keys([
            key("keyDown", "\u{E009}"), key("keyDown", "a"), key("keyUp", "a"), key("keyUp", "\u{E009}"),
            key("keyDown", "\u{E00F}"), key("keyUp", "\u{E00F}"),
            key("keyDown", "\u{E008}"), key("keyDown", "\u{E007}"), key("keyUp", "\u{E007}"), key("keyUp", "\u{E008}"),
            key("keyDown", "x"), key("keyUp", "x"),
        ])]))
        XCTAssertEqual(steps, [.key(.press("Control+a")), .key(.press("PageDown")), .key(.press("Shift+Enter")), .key(.type("x"))])
        // A key the keyboard has no key for is refused as send keys refuses it.
        XCTAssertEqual(refusal([keys([key("keyDown", "\u{E016}")])])?.code, "unsupported operation")
    }

    func testTheWheel() throws {
        let wheel: [String: Any] = ["type": "wheel", "id": "wheel", "actions": [
            ["type": "scroll", "x": 0, "y": 0, "deltaX": 0, "deltaY": 600, "duration": 0, "origin": [WebDriverRoute.elementKey: element]],
            ["type": "scroll", "x": 200, "y": 300, "deltaX": 0, "deltaY": -120, "origin": "viewport"],
        ]]
        XCTAssertEqual(try WebDriverActions.steps(body([wheel])),
                       [.scroll(.element(element), x: 0, y: 0, deltaY: 600), .scroll(.viewport, x: 200, y: 300, deltaY: -120)])
        let sideways: [String: Any] = ["type": "wheel", "id": "wheel", "actions": [["type": "scroll", "deltaX": 50, "deltaY": 0]]]
        XCTAssertEqual(refusal([sideways])?.code, "unsupported operation")
        let fromPointer: [String: Any] = ["type": "wheel", "id": "wheel", "actions": [["type": "scroll", "deltaY": 50, "origin": "pointer"]]]
        XCTAssertEqual(refusal([fromPointer])?.code, "invalid argument")
    }

    /// What a page would not take for a person's from this driver is refused whole, before any of it.
    func testWhatIsRefusedSaysWhich() {
        // drag_and_drop: a move with the button held.
        let drag = refusal([pointer([move(to: element), down, move(to: "doc-9"), up])])
        XCTAssertEqual(drag?.code, "unsupported operation")
        XCTAssertEqual(drag?.message.contains("drag"), true)
        // context_click: the right button.
        XCTAssertEqual(refusal([pointer([move(to: element), ["type": "pointerDown", "button": 2], ["type": "pointerUp", "button": 2]])])?.code,
                       "unsupported operation")
        // A touch.
        XCTAssertEqual(refusal([pointer([move(to: element)], type: "touch")])?.code, "unsupported operation")
        // Shift held while clicking.
        let shiftClick = refusal([pointer([pause(), move(to: element), down, up]), keys([key("keyDown", "\u{E008}"), pause(), pause(), pause()])])
        XCTAssertEqual(shiftClick?.code, "unsupported operation")
        XCTAssertEqual(shiftClick?.message.contains("Shift"), true)
        // click_and_hold with no release in the request.
        XCTAssertEqual(refusal([pointer([move(to: element), down])])?.code, "unsupported operation")
        // What is not the protocol's.
        for odd in [["type": "pointer", "actions": [["type": "fly"]]], ["type": "pointer"], ["type": "joystick", "actions": []],
                    ["type": "key", "actions": [["type": "keyDown", "value": "ab"]]],
                    ["type": "pointer", "actions": [["type": "pointerMove", "x": "left"]]]] as [[String: Any]] {
            XCTAssertEqual(refusal([odd])?.code, "invalid argument", "\(odd)")
        }
        XCTAssertThrowsError(try WebDriverActions.steps(["actions": "none"]))
        XCTAssertThrowsError(try WebDriverActions.steps([:]))
    }
}
