import XCTest
@testable import BrowserCore

/// The local automation API's wire, its gate and its routes (`AutomationHTTP`).
final class AutomationAPITests: XCTestCase {
    let token = "t0ken-of-43-characters-xxxxxxxxxxxxxxxxxxx"
    let port = 50_777

    private func raw(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        if !body.isEmpty { head += "Content-Length: \(body.utf8.count)\r\n" }
        return Data((head + "\r\n" + body).utf8)
    }

    private func request(_ method: String, _ target: String, body: String = "", extra: [String: String] = [:]) throws -> AutomationHTTP.Request {
        var headers = ["Host": "127.0.0.1:\(port)", "Authorization": "Bearer \(token)"]
        headers.merge(extra) { $1 }
        guard case .request(let request) = AutomationHTTP.parse(raw(method, target, headers: headers, body: body)) else {
            throw XCTSkip("did not parse")
        }
        return request
    }

    private func status(_ parsed: AutomationHTTP.Parsed) -> Int? {
        if case .invalid(let response) = parsed { return response.status }
        return nil
    }

    // MARK: Parsing

    func testARequestIsReadOnceItsBodyHasArrived() throws {
        let whole = raw("POST", "/v1/profiles/Shop/open?x=1&name=a%20b", headers: ["Host": "127.0.0.1:50777"], body: "{\"url\":\"https://a.test/\"}")
        XCTAssertEqual(AutomationHTTP.parse(whole.prefix(20)), .incomplete)
        XCTAssertEqual(AutomationHTTP.parse(whole.dropLast(3)), .incomplete, "the body is not all there")
        guard case .request(let request) = AutomationHTTP.parse(whole) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/profiles/Shop/open")
        XCTAssertEqual(request.query, ["x": "1", "name": "a b"])
        XCTAssertEqual(request.headers["host"], "127.0.0.1:50777")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{\"url\":\"https://a.test/\"}")
    }

    func testWhatIsNotARequestThisAPITakesIsRefused() {
        XCTAssertEqual(status(AutomationHTTP.parse(Data("GARBAGE\r\n\r\n".utf8))), 400)
        XCTAssertEqual(status(AutomationHTTP.parse(raw("GET", "/v1/profiles", headers: ["Host": "a", "host": "b"]))), 400,
                       "a Host given twice")
        XCTAssertEqual(status(AutomationHTTP.parse(raw("POST", "/v1/profiles/a/cookies", headers: ["Transfer-Encoding": "chunked"]))), 411)
        XCTAssertEqual(status(AutomationHTTP.parse(raw("POST", "/v1/profiles/a/cookies",
                                                        headers: ["Content-Length": "\(AutomationHTTP.maximumBodyBytes + 1)"]))), 413)
        XCTAssertEqual(status(AutomationHTTP.parse(Data(repeating: 0x41, count: AutomationHTTP.maximumHeaderBytes + 1))), 431)
    }

    // MARK: The gate

    func testOnlyARequestWithTheTokenToThisListenerAndFromNoWebPageIsActedOn() throws {
        XCTAssertNil(AutomationGate.refusal(of: try request("GET", "/v1/profiles"), token: token, port: port))
        for host in ["localhost:50777", "[::1]:50777", "LOCALHOST:50777"] {
            XCTAssertNil(AutomationGate.refusal(of: try request("GET", "/v1/profiles", extra: ["Host": host]), token: token, port: port), host)
        }
        func refusal(_ extra: [String: String]) throws -> Int? {
            AutomationGate.refusal(of: try request("GET", "/v1/profiles", extra: extra), token: token, port: port)?.status
        }
        XCTAssertEqual(try refusal(["Authorization": "Bearer wrong"]), 401)
        XCTAssertEqual(try refusal(["Authorization": "Bearer \(token)x"]), 401)
        XCTAssertEqual(try refusal(["Authorization": token]), 401, "the scheme is part of it")
        XCTAssertEqual(try refusal(["Authorization": ""]), 401)
        // DNS rebinding: a page's own name pointed at 127.0.0.1, and another port.
        XCTAssertEqual(try refusal(["Host": "attacker.example:50777"]), 403)
        XCTAssertEqual(try refusal(["Host": "127.0.0.1:50778"]), 403)
        XCTAssertEqual(try refusal(["Host": "127.0.0.1"]), 403)
        // A browser's request, even with the right token and host.
        XCTAssertEqual(try refusal(["Origin": "null"]), 403)
        XCTAssertEqual(try refusal(["Origin": "http://127.0.0.1:50777"]), 403)
        XCTAssertEqual(try refusal(["Sec-Fetch-Site": "cross-site"]), 403)
        XCTAssertEqual(try refusal(["Sec-Fetch-Dest": "empty"]), 403)
        // What Safari sends for a page's fetch to 127.0.0.1: the whole fetch-metadata set.
        let browser = ["Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty",
                       "Origin": "https://attacker.example", "User-Agent": "Mozilla/5.0 (Macintosh) Safari/605.1.15"]
        XCTAssertEqual(try refusal(browser), 403)
        XCTAssertEqual(try refusal(browser.filter { $0.key != "Origin" }), 403, "a page's GET with no Origin")
        // What Node's built-in fetch (undici, so WebdriverIO too) sends: Sec-Fetch-Mode and nothing else of the set.
        let node = ["Sec-Fetch-Mode": "cors", "Accept": "*/*", "Accept-Language": "*", "User-Agent": "node",
                    "Accept-Encoding": "gzip, deflate"]
        XCTAssertNil(try refusal(node), "Node's fetch is not a web page")
        XCTAssertEqual(try refusal(node.merging(["Authorization": "Bearer wrong"]) { $1 }), 401, "and still needs the token")
        // An empty token opens nothing.
        let empty = try request("GET", "/v1/profiles", extra: ["Authorization": "Bearer "])
        XCTAssertEqual(AutomationGate.refusal(of: empty, token: "", port: port)?.status, 401)
    }

    func testAWebDriverClientIsAnsweredAndAWebPageIsNot() throws {
        func refusal(_ extra: [String: String]) throws -> Int? {
            var headers = ["Host": "127.0.0.1:\(port)", "Content-Type": "application/json; charset=utf-8"]
            headers.merge(extra) { $1 }
            guard case .request(let request) = AutomationHTTP.parse(raw("POST", "/wd/abc/Shop/session", headers: headers, body: "{}")) else {
                throw XCTSkip("did not parse")
            }
            return AutomationGate.webDriverRefusal(of: request, port: port)?.status
        }
        // Selenium (node:http, urllib3, Java's client): no fetch metadata at all.
        XCTAssertNil(try refusal(["User-Agent": "selenium/4.27.1 (python mac)", "Accept": "application/json"]))
        // WebdriverIO through Node's fetch: Sec-Fetch-Mode alone.
        XCTAssertNil(try refusal(["Sec-Fetch-Mode": "cors", "Accept": "application/json", "User-Agent": "webdriver/9.33.1"]))
        // A page in a browser, with or without Origin.
        XCTAssertEqual(try refusal(["Origin": "https://attacker.example", "Sec-Fetch-Site": "cross-site",
                                    "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "empty"]), 403)
        XCTAssertEqual(try refusal(["Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate",
                                    "Sec-Fetch-Dest": "document", "Sec-Fetch-User": "?1"]), 403)
        XCTAssertEqual(try refusal(["Origin": "null"]), 403)
        XCTAssertEqual(try refusal(["Host": "attacker.example:50777"]), 403)
    }

    /// A connection past the listener's room is answered, in the protocol its request line names.
    func testABusyAnswerSpeaksTheProtocolOfTheRequest() throws {
        let webDriver = AutomationHTTP.busy(firstBytes: raw("POST", "/wd/abc/Shop/session", headers: ["Host": "127.0.0.1:50777"], body: "{}"))
        XCTAssertEqual(webDriver.status, 500, "the protocol's \"unknown error\": every client raises it")
        let value = try XCTUnwrap((try JSONSerialization.jsonObject(with: webDriver.body) as? [String: Any])?["value"] as? [String: Any])
        XCTAssertEqual(value["error"] as? String, "unknown error")
        XCTAssertTrue((value["message"] as? String)?.contains("not acted on") == true)

        for first in [raw("GET", "/v1/profiles", headers: ["Host": "127.0.0.1:50777"]), Data("POST /v1/profiles/a/st".utf8), Data("\r\n".utf8)] {
            let api = AutomationHTTP.busy(firstBytes: first)
            XCTAssertEqual(api.status, 503)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: api.body) as? [String: Any])
            XCTAssertEqual(body["error"] as? String, "busy")
            XCTAssertTrue(String(decoding: api.serialized(), as: UTF8.self).hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        }
        // Only the start of a WebDriver request has come: the path is enough.
        XCTAssertEqual(AutomationHTTP.busy(firstBytes: Data("GET /wd/abc/Shop/session/1/url HT".utf8)).status, 500)
    }

    func testNoAnswerCarriesACORSHeaderOrIsCached() {
        let wire = String(decoding: AutomationHTTP.Response.error(401, "unauthorized", "no").serialized(), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertFalse(wire.lowercased().contains("access-control-"))
        XCTAssertTrue(wire.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
    }

    func testTokensAreLongRandomAndURLSafe() {
        let a = AutomationSettings.newToken(), b = AutomationSettings.newToken()
        XCTAssertEqual(a.count, 43)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, a)
        XCTAssertFalse(AutomationSettings().isEnabled, "off unless turned on")
    }

    // MARK: Routes

    func testRoutes() throws {
        func route(_ method: String, _ target: String, body: String = "") throws -> Result<AutomationRoute, AutomationRefusal> {
            AutomationRoute.of(try request(method, target, body: body))
        }
        XCTAssertEqual(try route("GET", "/v1/profiles").get(), .listProfiles)
        XCTAssertEqual(try route("GET", "/v1/profiles/").get(), .listProfiles)
        XCTAssertEqual(try route("GET", "/v1/profiles/My%20Shop").get(), .profile("My Shop"))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/start").get(), .start("a", window: true))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/start", body: "{\"window\": false}").get(), .start("a", window: false))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/stop").get(), .stop("a"))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/open", body: "{\"url\": \"https://b.test/x\"}").get(),
                       .open("a", url: URL(string: "https://b.test/x")!))
        XCTAssertEqual(try route("GET", "/v1/profiles/a/cookies").get(), .exportCookies("a", .playwright))
        XCTAssertEqual(try route("GET", "/v1/profiles/a/cookies?format=netscape").get(), .exportCookies("a", .netscape))
        XCTAssertEqual(try route("GET", "/v1/profiles/a/cookies?format=extension").get(), .exportCookies("a", .extensionJSON))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/cookies", body: "x").get(), .importCookies("a", Data("x".utf8)))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/scenario", body: "{\"source\": \"await page.goto('https://b.test/')\"}").get(),
                       .runScenario("a", ScenarioRunSpec(source: "await page.goto('https://b.test/')", scenario: nil)))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/scenario", body: "{\"scenario\": \"Sign in\", \"params\": {\"n\": 2}}").get(),
                       .runScenario("a", ScenarioRunSpec(source: nil, scenario: "Sign in", parametersJSON: "{\"n\":2}")))
        XCTAssertEqual(try route("GET", "/v1/profiles/a/scenario").get(), .scenarioState("a"))
        XCTAssertEqual(try route("POST", "/v1/profiles/a/scenario/stop").get(), .stopScenario("a"))
        // A fresh profile in one call: temporary by default, started when asked.
        XCTAssertEqual(try route("POST", "/v1/profiles").get(), .create(AutomationNewProfile()))
        XCTAssertEqual(try route("POST", "/v1/profiles",
                                 body: "{\"name\": \" Run 7 \", \"temporary\": false, \"start\": true, \"window\": false, \"proxy\": \"socks5://u:p@h.test:1080\"}").get(),
                       .create(AutomationNewProfile(name: "Run 7", ephemeral: false,
                                                    proxy: ProxySettings(kind: .socks5, host: "h.test", port: 1080, username: "u", password: "p"),
                                                    start: true, window: false)))

        func refused(_ method: String, _ target: String, body: String = "") throws -> Int? {
            if case .failure(let refusal) = try route(method, target, body: body) { return refusal.response.status }
            return nil
        }
        XCTAssertEqual(try refused("GET", "/v2/profiles"), 404)
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/delete"), 404)
        XCTAssertEqual(try refused("PUT", "/v1/profiles"), 405)
        XCTAssertEqual(try refused("POST", "/v1/profiles", body: "[1]"), 400)
        XCTAssertEqual(try refused("POST", "/v1/profiles", body: "{\"name\": \"  \"}"), 400, "a blank name")
        XCTAssertEqual(try refused("POST", "/v1/profiles", body: "{\"start\": \"yes\"}"), 400, "a flag that is not true or false")
        XCTAssertEqual(try refused("POST", "/v1/profiles", body: "{\"proxy\": \"1.2.3.4:1080\"}"), 400, "no scheme: the type is not guessed")
        XCTAssertEqual(try refused("POST", "/v1/profiles", body: "{\"proxy\": \"not a proxy\"}"), 400)
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/start"), 405)
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/start", body: "[1]"), 400)
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/cookies?format=har"), 400)
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/cookies"), 400, "no body")
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/scenario"), 400, "neither source nor scenario")
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/scenario", body: "{\"source\": \"x\", \"scenario\": \"y\"}"), 400, "both")
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/scenario", body: "{\"source\": \"  \"}"), 400, "blank")
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/scenario", body: "{\"source\": \"x\", \"params\": [1]}"), 400, "params not an object")
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/scenario/stop"), 405)
        for address in ["file:///etc/passwd", "javascript:alert(1)", "about:blank", "https://"] {
            XCTAssertEqual(try refused("POST", "/v1/profiles/a/open", body: "{\"url\": \"\(address)\"}"), 400, address)
        }
    }

    // MARK: Profiles

    func testAProfileIsFoundByIdOrByAnExactNameThatIsOneProfiles() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let a = ProfileSummary(id: UUID(), name: "Shop", createdAt: date, lastLaunchedAt: nil, revision: 1)
        let b = ProfileSummary(id: UUID(), name: "Twin", createdAt: date, lastLaunchedAt: nil, revision: 1)
        let c = ProfileSummary(id: UUID(), name: "Twin", createdAt: date, lastLaunchedAt: nil, revision: 1)
        XCTAssertEqual(try AutomationProfiles.find(a.id.uuidString, in: [a, b, c]).get(), a)
        XCTAssertEqual(try AutomationProfiles.find(a.id.uuidString.lowercased(), in: [a, b, c]).get(), a)
        XCTAssertEqual(try AutomationProfiles.find("Shop", in: [a, b, c]).get(), a)
        XCTAssertEqual(try AutomationProfiles.find(c.id.uuidString, in: [a, b, c]).get(), c)
        if case .failure(let refusal) = AutomationProfiles.find("Twin", in: [a, b, c]) {
            XCTAssertEqual(refusal.response.status, 409)
        } else { XCTFail("an ambiguous name") }
        if case .failure(let refusal) = AutomationProfiles.find("shop", in: [a, b, c]) {
            XCTAssertEqual(refusal.response.status, 404, "names are exact")
        } else { XCTFail("a name in another case") }
    }

    func testAProfilesProxyIsShownWithoutItsCredentials() throws {
        let summary = ProfileSummary(id: UUID(), name: "Shop", createdAt: Date(), lastLaunchedAt: nil, revision: 1)
        let proxy = ProxySettings(kind: .socks5, host: "gw.example", port: 1080, username: "user-name", password: "s3cret-pass")
        let entry = AutomationProfiles.Entry(summary, running: true, busy: false, proxy: proxy)
        XCTAssertEqual(entry.proxy, "socks5://gw.example:1080")
        let body = String(decoding: AutomationHTTP.Response.json(200, [entry]).body, as: UTF8.self)
        XCTAssertFalse(body.contains("s3cret-pass") || body.contains("user-name"), body)
        XCTAssertTrue(body.contains("\"running\" : true"), body)
        XCTAssertTrue(body.contains("\"socks5://gw.example:1080\""), "the address as written, slashes unescaped: \(body)")
    }

    func testDeviceSettingsFromBeforeTheAPIStillRead() throws {
        let earlier = Data("{\"lastSync\":null}".utf8)
        let settings = try JSONDecoder().decode(DeviceSettings.self, from: earlier)
        XCTAssertNil(settings.automation)
        XCTAssertNil(settings.reopenAtUnlock)
    }

    func testTheProfilesToReopenAreKeptEncryptedWithTheDeviceSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-reopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try MasterVault.create(in: root, password: "reopen", iterations: 1_000)
        let ids = [UUID(), UUID()]
        try DeviceSettings(reopenAtUnlock: ids).save(to: vault)
        XCTAssertEqual(try DeviceSettings.load(from: vault).reopenAtUnlock, ids)
        let file = try Data(contentsOf: root.appendingPathComponent("settings.bin"))
        XCTAssertNil(file.range(of: Data(ids[0].uuidString.utf8)), "the ids are not in the file in clear")
    }
}
