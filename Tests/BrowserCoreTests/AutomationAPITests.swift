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
        // An empty token opens nothing.
        let empty = try request("GET", "/v1/profiles", extra: ["Authorization": "Bearer "])
        XCTAssertEqual(AutomationGate.refusal(of: empty, token: "", port: port)?.status, 401)
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

        func refused(_ method: String, _ target: String, body: String = "") throws -> Int? {
            if case .failure(let refusal) = try route(method, target, body: body) { return refusal.response.status }
            return nil
        }
        XCTAssertEqual(try refused("GET", "/v2/profiles"), 404)
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/delete"), 404)
        XCTAssertEqual(try refused("POST", "/v1/profiles"), 405)
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/start"), 405)
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/start", body: "[1]"), 400)
        XCTAssertEqual(try refused("GET", "/v1/profiles/a/cookies?format=har"), 400)
        XCTAssertEqual(try refused("POST", "/v1/profiles/a/cookies"), 400, "no body")
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
    }
}
