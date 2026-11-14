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
        XCTAssertEqual(WebDriverRoute.address(port: 50777, masterToken: "abc", profile: id),
                       "http://127.0.0.1:50777/wd/\(WebDriverRoute.token(masterToken: "abc", profile: id))/\(id.uuidString)")
        XCTAssertFalse(WebDriverRoute.address(port: 50777, masterToken: "abc", profile: id).contains("/wd/abc/"),
                       "the API's own token is never in a WebDriver address")
        XCTAssertEqual(parse("GET", "/status"), WebDriverRequest(token: "tok", profile: "Shop one", command: "status"))
        XCTAssertEqual(parse("POST", "/session")?.command, "newSession")
        XCTAssertEqual(parse("DELETE", "/session/s1"), WebDriverRequest(token: "tok", profile: "Shop one", command: "deleteSession", session: "s1"))
        XCTAssertTrue(WebDriverRoute.handles("/wd/x"))
        XCTAssertFalse(WebDriverRoute.handles("/v1/profiles"))
        XCTAssertEqual(failure("GET", "/wd/tok")?.code, "unknown command", "no profile in the address")
    }

    /// A profile's token: HMAC-SHA256 of "webdriver:" + its UUID under the API's token, base64url
    /// without padding — a script that has the API's token can make it (docs/AUTOMATION.md).
    func testAProfilesTokenIsMadeFromTheAPIsToken() {
        let master = "kT3vQ9mXw2LrB7sYp0Zc"
        let profile = UUID(uuidString: "6B0E3C1F-9A2D-4E7B-8C15-0D4F6A7B8C9D")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        // Python: base64.urlsafe_b64encode(hmac.new(master, b"webdriver:" + uuid, sha256).digest()).rstrip(b"=")
        XCTAssertEqual(WebDriverRoute.token(masterToken: master, profile: profile), "uRA-uC_eCD4sTFbzTshYP3AsrCNk5mQXbPX04RQdd5E")
        XCTAssertEqual(WebDriverRoute.token(masterToken: master, profile: other), "soxoOJ-5u5qfzgK7-dPFjCHsykBpVTOly9aK1FOzOag")
        XCTAssertEqual(WebDriverRoute.token(masterToken: master, profile: profile).count, 43)
        XCTAssertNotEqual(WebDriverRoute.token(masterToken: "another", profile: profile), WebDriverRoute.token(masterToken: master, profile: profile),
                          "a renewed API token gives the profile another one")
    }

    /// Under /wd/ only the profile's own token opens the profile: not the API's, not another
    /// profile's; and under /v1/ the profile's token is not the API's.
    func testOnlyTheProfilesOwnTokenOpensItsAddress() {
        let master = AutomationSettings.newToken()
        let profile = UUID(), other = UUID()
        let own = WebDriverRoute.token(masterToken: master, profile: profile)
        XCTAssertTrue(WebDriverRoute.tokenMatches(own, masterToken: master, profile: profile))
        XCTAssertFalse(WebDriverRoute.tokenMatches(master, masterToken: master, profile: profile), "the API's token is not taken under /wd/")
        XCTAssertFalse(WebDriverRoute.tokenMatches(own, masterToken: master, profile: other), "nor one profile's token for another")
        XCTAssertFalse(WebDriverRoute.tokenMatches("", masterToken: master, profile: profile))
        XCTAssertFalse(WebDriverRoute.tokenMatches(own, masterToken: AutomationSettings.newToken(), profile: profile), "nor after a new API token")
        XCTAssertFalse(WebDriverRoute.tokenMatches(WebDriverRoute.token(masterToken: "", profile: profile), masterToken: "", profile: profile),
                       "no API token, no WebDriver")
        // The parsed address carries the token as it was sent.
        let path = "/wd/\(own)/\(profile.uuidString)/status"
        let parsed = try? WebDriverRoute.parse(method: "GET", path: path).get()
        XCTAssertEqual(parsed?.token, own)
        XCTAssertEqual(parsed?.profile, profile.uuidString)
        // The /v1/ gate takes the API's token alone.
        let headers = ["host": "127.0.0.1:50777", "authorization": "Bearer \(own)"]
        let request = AutomationHTTP.Request(method: "GET", path: "/v1/profiles", query: [:], headers: headers, body: Data(), headerLines: [])
        XCTAssertEqual(AutomationGate.refusal(of: request, token: master, port: 50777)?.status, 401)
    }

    /// "navigate" goes where a scenario's goto goes: http, https, and about:blank.
    func testNavigateTakesWebAddressesOnly() {
        for text in ["https://example.com/", "http://example.com/login?x=1", "HTTPS://Example.com", "about:blank"] {
            XCTAssertNotNil(WebDriverRoute.navigableURL(text), text)
        }
        for text in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>", "about:config", "about:blank#x",
                     "ftp://example.com/", "x-apple-helpbook://open", "https:///nohost", "example.com", ""] {
            XCTAssertNil(WebDriverRoute.navigableURL(text), text)
        }
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
