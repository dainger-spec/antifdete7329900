import XCTest
@testable import BrowserCore

/// The WebDriver's addresses and keys, as its clients (Selenium) send them.
final class WebDriverProtocolTests: XCTestCase {
    private func parse(_ method: String, _ path: String) -> WebDriverRequest? {
        try? WebDriverRoute.parse(method: method, path: "/wd/tok/Shop%20one" + path).get()
    }

    private func failure(_ method: String, _ path: String) -> WebDriverError? {
        if case let .failure(error) = WebDriverRoute.parse(method: method, path: path) { return error }
        return nil
    }

    func testTheAddressNamesTheTokenAndTheProfile() {
        let id = UUID()
        XCTAssertEqual(WebDriverRoute.address(port: 50777, token: "abc", profile: id), "http://127.0.0.1:50777/wd/abc/\(id.uuidString)")
        XCTAssertEqual(parse("GET", "/status"), WebDriverRequest(token: "tok", profile: "Shop one", command: "status"))
        XCTAssertEqual(parse("POST", "/session")?.command, "newSession")
        XCTAssertEqual(parse("DELETE", "/session/s1"), WebDriverRequest(token: "tok", profile: "Shop one", command: "deleteSession", session: "s1"))
        XCTAssertTrue(WebDriverRoute.handles("/wd/x"))
        XCTAssertFalse(WebDriverRoute.handles("/v1/profiles"))
        XCTAssertEqual(failure("GET", "/wd/tok")?.code, "unknown command", "no profile in the address")
    }

    func testTheCommandsSeleniumSends() {
        let expected: [(String, String, String)] = [
            ("POST", "/session/s/url", "navigate"), ("GET", "/session/s/url", "currentURL"), ("GET", "/session/s/title", "title"),
            ("POST", "/session/s/back", "back"), ("POST", "/session/s/refresh", "refresh"), ("GET", "/session/s/source", "pageSource"),
            ("POST", "/session/s/element", "findElement"), ("POST", "/session/s/elements", "findElements"),
            ("GET", "/session/s/element/active", "activeElement"),
            ("POST", "/session/s/execute/sync", "executeSync"), ("POST", "/session/s/execute/async", "executeAsync"),
            ("GET", "/session/s/cookie", "getCookies"), ("POST", "/session/s/cookie", "addCookie"), ("DELETE", "/session/s/cookie", "deleteCookies"),
            ("GET", "/session/s/screenshot", "screenshot"), ("GET", "/session/s/window/rect", "getWindowRect"),
            ("POST", "/session/s/window/rect", "setWindowRect"), ("GET", "/session/s/window/handles", "windowHandles"),
            ("POST", "/session/s/timeouts", "setTimeouts"),
        ]
        for (method, path, command) in expected {
            XCTAssertEqual(parse(method, path), WebDriverRequest(token: "tok", profile: "Shop one", command: command, session: "s"), path)
        }
        XCTAssertEqual(parse("POST", "/session/s/element/e-1/click"),
                       WebDriverRequest(token: "tok", profile: "Shop one", command: "click", session: "s", element: "e-1"))
        XCTAssertEqual(parse("POST", "/session/s/element/e-1/value")?.command, "sendKeys")
        XCTAssertEqual(parse("POST", "/session/s/element/e-1/elements")?.command, "findElements")
        XCTAssertEqual(parse("GET", "/session/s/element/e-1/attribute/data%2Fx"),
                       WebDriverRequest(token: "tok", profile: "Shop one", command: "elementAttribute", session: "s", element: "e-1", name: "data/x"))
        XCTAssertEqual(parse("GET", "/session/s/element/e-1/css/color")?.name, "color")
        XCTAssertEqual(parse("DELETE", "/session/s/cookie/sid"),
                       WebDriverRequest(token: "tok", profile: "Shop one", command: "deleteCookie", session: "s", name: "sid"))
    }

    func testWhatIsNotACommandSaysSo() {
        XCTAssertEqual(failure("GET", "/wd/tok/p/session/s/nothing")?.code, "unknown command")
        XCTAssertEqual(failure("GET", "/wd/tok/p/session/s/nothing")?.status, 404)
        XCTAssertEqual(failure("PUT", "/wd/tok/p/session/s/url")?.code, "unknown method")
        XCTAssertEqual(failure("PUT", "/wd/tok/p/session/s/url")?.status, 405)
        XCTAssertEqual(failure("GET", "/wd/tok/p/session/s/element/e/click")?.code, "unknown method")
        XCTAssertEqual(failure("GET", "/wd/tok/p/elsewhere")?.code, "unknown command")
        let body = try? JSONSerialization.jsonObject(with: WebDriverError.noSuchElement("nothing matches #x").body) as? [String: [String: String]]
        XCTAssertEqual(body?["value"]?["error"], "no such element")
        XCTAssertEqual(body?["value"]?["message"], "nothing matches #x")
    }

    func testKeysAsStrokes() throws {
        XCTAssertEqual(try WebDriverKeys.strokes("Hello"), [.type("Hello")])
        XCTAssertEqual(try WebDriverKeys.strokes("ab\u{E007}"), [.type("ab"), .press("Enter")])
        XCTAssertEqual(try WebDriverKeys.strokes("\u{E004}x\u{E003}"), [.press("Tab"), .type("x"), .press("Backspace")])
        // A modifier holds until NULL: select all, then type over it.
        XCTAssertEqual(try WebDriverKeys.strokes("\u{E03D}a\u{E000}new"), [.press("Meta+a"), .type("new")])
        XCTAssertEqual(try WebDriverKeys.strokes("\u{E008}\u{E004}"), [.press("Shift+Tab")])
        XCTAssertEqual(try WebDriverKeys.strokes(""), [])
        XCTAssertThrowsError(try WebDriverKeys.strokes("\u{E031}")) { error in
            XCTAssertEqual((error as? WebDriverError)?.code, "unsupported operation")
        }
    }
}
