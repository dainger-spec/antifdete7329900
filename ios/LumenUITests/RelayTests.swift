import Network
import XCTest

/// The relay — every session's way out — must not become a new hole: only the session gets through
/// its door (not another app on this device, not anything on a network), and the names of the
/// sites a proxied session opens are the proxy's to look up, never this device's.
final class RelayTests: LumenUITestCase {
    /// Another app knocks on the relay of an open session: without the password, with a wrong one,
    /// and from this Mac's network address instead of 127.0.0.1. Only the session itself gets through.
    func testRelayDoorIsShut() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "Работает")
        leaveProxies()
        createSession(name: "Дверь")
        openSession("Дверь")
        chooseProxy("Нью-Йорк", in: "Дверь")
        // The session itself goes through its relay and its proxy.
        openPage("http://door-\(run).lumentest:28380/whoami?t=inside")
        page("via: прокси B")
        let port = relayPort()
        shot("40 a session and its relay")

        // Another app on this device: the test's own process, on 127.0.0.1.
        let connect = "CONNECT outside-\(run).lumentest:28380 HTTP/1.1\r\nHost: outside-\(run).lumentest:28380\r\n"
        let none = ask(port: port, connect + "\r\n")
        XCTAssertEqual(none.map { String($0.prefix(12)) }, "HTTP/1.1 407",
                       "another app without its password is refused by the relay (407), not let through: \(none ?? "no answer")")
        let wrong = ask(port: port, connect + "Proxy-Authorization: Basic \(Data("lumen:guess".utf8).base64EncodedString())\r\n\r\n")
        XCTAssertEqual(wrong.map { String($0.prefix(12)) }, "HTTP/1.1 407",
                       "another app with a wrong password is refused by the relay (407): \(wrong ?? "no answer")")

        // From a network: this Mac's network address (ci.sh hands it on), the relay's port.
        let lan = ProcessInfo.processInfo.environment["LUMEN_LAN"] ?? ""
        XCTAssertFalse(lan.isEmpty || lan.hasPrefix("127."), "the relay from a network: this Mac has a network address to try from (\(lan))")
        let fromNetwork = ask(host: lan, port: port, connect + "\r\n")
        XCTAssertNil(fromNetwork, "the relay from a network: nothing answers at \(lan):\(port) — \(fromNetwork ?? "")")

        // Nothing of those knocks reached the site; the session still browses.
        openPage("http://door-\(run).lumentest:28380/whoami?t=after")
        page("via: прокси B")
        openPage("http://site.lumentest:28380/__seen?token=outside-\(run)")
        XCTAssertEqual(pageLine("site outside-\(run): "), "site outside-\(run): 0", "no knock reached the site")
    }

    /// A proxied session's names are handed to the proxy as names, through both kinds of proxy:
    /// this Mac's resolver — the testbed's DNS server answers *.lumentest for it and counts every
    /// question — is never asked about them.
    func testNamesAreNotLookedUpHere() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "Работает")
        leaveProxies()
        createSession(name: "Имена")
        openSession("Имена")
        chooseProxy("Берлин", in: "Имена")
        openPage("http://names-http-\(run).lumentest:28380/whoami?t=http")
        page("via: прокси A")
        chooseProxy("Нью-Йорк", in: "Имена")
        openPage("http://names-socks-\(run).lumentest:28380/whoami?t=socks")
        page("via: прокси B")
        shot("41 names through both proxies")
        for name in ["names-http", "names-socks"] {
            let token = "\(name)-\(run)"
            openPage("http://site.lumentest:28380/__seen?token=\(token)")
            XCTAssertNotEqual(pageLine("site \(token): "), "site \(token): 0", "the page of \(name) reached the site")
            XCTAssertEqual(pageLine("dns \(token): "), "dns \(token): 0",
                           "names are not looked up here: no DNS question for \(name) reached this Mac's resolver")
        }
    }

    /// The relay's port, as the session's screen shows it to the tests (DEBUG builds only).
    func relayPort(file: StaticString = #filePath, line: UInt = #line) -> UInt16 {
        let label = wait(app.staticTexts["debugRelayPort"], "the session shows its relay's port (test hooks)", file: file, line: line).label
        let port = UInt16(label.replacingOccurrences(of: "relay ", with: "")) ?? 0
        XCTAssertNotEqual(port, 0, "the relay's port is a number: \(label)", file: file, line: line)
        return port
    }

    /// Sends `request` to host:port from this test's own process — another app, as far as the relay
    /// can tell — and returns the first line of the answer; nil if nothing answered within `timeout`.
    func ask(host: String = "127.0.0.1", port: UInt16, _ request: String, timeout: TimeInterval = 6) -> String? {
        final class Answer { var line: String? }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 1, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    if let data, !data.isEmpty {
                        answer.line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first
                    }
                    done.signal()
                }
            case .waiting, .failed:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "lumen.test.ask"))
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        return answer.line
    }
}
