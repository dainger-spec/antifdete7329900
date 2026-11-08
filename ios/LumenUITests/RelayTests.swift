import Network
import XCTest

/// The relay — every session's way out — must not become a new hole: only the session gets through
/// its door (not another app on this device, not anything on a network), the names of the sites a
/// proxied session opens are the proxy's to look up, never this device's, and when the relay itself
/// is down, or the network under it changes, nothing goes around it.
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

    /// The relay dies — nothing answers on its port, and the session's data store, not told, still
    /// points there — and later starts again with a gap, the data store told. In neither moment does
    /// a page go around it; once it is back, the session browses through its proxy again.
    func testRelayDownLetsNothingOut() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "Работает")
        leaveProxies()
        createSession(name: "Обрыв")
        openSession("Обрыв")
        chooseProxy("Нью-Йорк", in: "Обрыв")
        openPage("http://relay-\(run).lumentest:28380/whoami?t=before")
        page("via: прокси B")
        let first = relayPort()

        // The relay dies for 40 s; a page asked for meanwhile goes nowhere.
        app.buttons["debugRelayDeath"].tap()
        go("http://deadrelay-\(run).lumentest:28380/whoami?t=deadrelay")
        assertNothingLoaded("deadrelay")
        shot("42 the relay is dead: nothing loads")
        // Back, on a new port: through the proxy again.
        let second = relayPort(other: first, timeout: 55)
        openPage("http://relay-\(run).lumentest:28380/whoami?t=back")
        page("via: прокси B")

        // The relay starts again, its listener down for 40 s (the data store given a port nothing
        // answers on); a page asked for meanwhile goes nowhere either.
        app.buttons["debugRelayRestart"].tap()
        wait(app.staticTexts.matching(NSPredicate(format: "label == %@", "relay down")).firstMatch, "the session says its relay is down")
        go("http://gap-\(run).lumentest:28380/whoami?t=gap")
        assertNothingLoaded("gap")
        _ = relayPort(other: second, timeout: 55)
        openPage("http://relay-\(run).lumentest:28380/whoami?t=after")
        page("via: прокси B")
        shot("43 the relay is back: through the proxy")

        // The testbed got nothing of those two pages, not even a DNS question.
        for name in ["deadrelay", "gap"] {
            let token = "\(name)-\(run)"
            openPage("http://site.lumentest:28380/__seen?token=\(token)")
            XCTAssertEqual(pageLine("site \(token): "), "site \(token): 0", "no request of \(name) reached the site")
            XCTAssertEqual(pageLine("dns \(token): "), "dns \(token): 0", "no DNS question for \(name) was asked of this Mac")
        }
    }

    /// The network under the session changes (a drill: a simulator never switches between Wi-Fi and
    /// cellular — that is measured on a real iPhone): every connection made before the change is
    /// closed, and the next page goes through the proxy again, nothing of it directly.
    func testNetworkChangeClosesConnections() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "Работает")
        leaveProxies()
        createSession(name: "Сеть")
        openSession("Сеть")
        chooseProxy("Нью-Йорк", in: "Сеть")
        let token = "net-\(run)"
        // A connection that stays open (a WebSocket, as real sites keep): made before the change, it
        // must not live on after it. (CI run 20: an idle keep-alive one closed by itself, either way.)
        openPage("http://\(token).lumentest:28380/hold?t=before")
        page("via: прокси B")
        page("ws: open")
        app.buttons["debugNetworkChange"].tap()
        assertWebSocketClosed("a network change closes the connections made before it (a WebSocket)")
        openPage("http://\(token).lumentest:28380/whoami?t=after")
        page("via: прокси B")
        openPage("http://site.lumentest:28380/__seen?token=\(token)&when=last")
        let route = pageLine("route \(token): ")
        XCTAssertTrue(route.contains("direct=0 ") && !route.contains("B=0 "), "every request went through the proxy, none directly: \(route)")
        shot("44 after a network change: through the proxy")
    }

    /// The instrument for the real iPhone's network switch (ios/DEVICE.md, q4), checked here first: in
    /// a session without a proxy it sees the device's own address — the leak it is there to catch —
    /// and through a proxy, with a network change and a relay restart under it, it sees none.
    func testNetworkProbe() {
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "Работает")
        leaveProxies()
        createSession(name: "Контроль")
        createSession(name: "Замер")
        openSession("Замер")
        chooseProxy("Нью-Йорк", in: "Замер")
        backToList()
        wait(app.buttons["netProbeButton"], "the session list leads to the network probe (DEBUG)").tap()
        wait(app.navigationBars["Замер сети"], "the probe opens")
        let verdict = app.staticTexts["probeVerdict"]

        // The detector first: a session without a proxy goes out from the device's own address.
        app.buttons["probe-Контроль"].tap()
        app.buttons["probeStart"].tap()
        let leak = NSPredicate(format: "label BEGINSWITH %@", "УТЕЧКА")
        let seen = XCTWaiter.wait(for: [expectation(for: leak, evaluatedWith: verdict)], timeout: 25)
        XCTAssertEqual(seen, .completed, "the probe sees the device's own address in a session without a proxy: \(verdict.label)")
        shot("45 the probe: a session without a proxy is a leak")
        // Its worker check, which the owner's iPhone run reads in a session with canvas noise: here, with
        // nothing replaced, the page and a worker made from a blob draw the same.
        let worker = app.staticTexts["probeWorker"]
        XCTAssertTrue(worker.waitForExistence(timeout: 15), "the probe's worker check answers")
        XCTAssertTrue(worker.label.hasPrefix("воркер из blob: тот же канвас"), "the probe's worker check works in its page: \(worker.label)")
        app.buttons["probeStart"].tap()

        // Through the proxy, a network change and a relay restart (40 s down) under it, and 10 s after the
        // relay is back: its answers come through the proxy again.
        app.buttons["probe-Замер"].tap()
        app.buttons["probeStart"].tap()
        sleep(6)
        wait(app.buttons["probeDrillNetwork"], "the probe offers the drills").tap()
        sleep(4)
        app.buttons["probeDrillRestart"].tap()
        sleep(50)
        app.buttons["probeStart"].tap()
        XCTAssertTrue(verdict.label.hasPrefix("Утечек нет"),
                      "the probe sees no leak through the proxy, a network change and a relay restart: \(verdict.label)")
        shot("46 the probe: through the proxy, no leak")
    }

    /// The relay's port, as the session's screen shows it to the tests (DEBUG builds only); with
    /// `other`, waits until it is a different one (the relay back on a new port).
    func relayPort(other: UInt16? = nil, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> UInt16 {
        let element = app.staticTexts["debugRelayPort"]
        let deadline = Date().addingTimeInterval(timeout)
        var port: UInt16 = 0
        repeat {
            if element.exists, element.label.hasPrefix("relay "), let number = UInt16(element.label.dropFirst(6)), number != other {
                port = number
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        XCTAssertNotEqual(port, 0, "the session shows its relay's port\(other.map { " (a new one, not \($0))" } ?? "") — \(element.exists ? element.label : "nothing")",
                          file: file, line: line)
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
