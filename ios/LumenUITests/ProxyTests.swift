import XCTest

/// Proxies the way a person handles them: add, see the check, give one to a session, change it while
/// the session is open (at once, tabs kept), quit and start again.
final class ProxyTests: LumenUITestCase {
    func testProxyPersonPath() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()   // host names of this run only
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")

        // The check runs by itself on save: alive, the exit address, its country, UDP.
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает")
        waitRow("Берлин", says: "DE")
        waitRow("Берлин", says: "203.0.113.10")
        waitRow("Берлин", says: "UDP: не умеет")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "US")
        waitRow("Нью-Йорк", says: "UDP: не умеет")   // the testbed's B refuses UDP ASSOCIATE
        addProxy(name: "С UDP", kind: "SOCKS5", port: "28383", user: "uc", password: "pc")
        waitRow("С UDP", says: "UDP: умеет")         // C relays it: a STUN answer came back through it
        addProxy(name: "Чужой пароль", kind: "HTTP", port: "28381", user: "ua", password: "wrong")
        waitRow("Чужой пароль", says: "Недоступен")
        shot("30 proxy list checked")
        leaveProxies()

        // A session without a proxy reaches the site directly (the testbed resolves .lumentest for this
        // Mac too). Then it gets the Berlin proxy while open: at once, with no relaunch and its tab as it
        // was, the next page to the same site goes through proxy A — not on the direct connection
        // WebKit keeps open from before (stage 2, CI run 14: WebKit's open connections kept their old
        // route after a change; now they are the relay's, and it closes them).
        createSession(name: "Счета")
        openSession("Счета")
        openPage("http://pre-\(run).lumentest:28380/whoami?before=proxy")
        page("via: напрямую")
        // A connection that stays open, as a site's WebSocket does: the proxy change must close it, or
        // it goes on the old way. (An idle keep-alive connection WebKit may or may not keep — CI run 20:
        // with the change leaving connections open, the next page happened to take a new one.)
        openPage("http://hold-\(run).lumentest:28380/hold?before=proxy")
        page("ws: open")
        chooseProxy("Берлин", in: "Счета")
        assertTabKept("/hold?before=proxy")
        // The socket's state is read now, before the next page leaves the hold page, and judged after a
        // page of a site not visited before (a new connection, through the relay's route at that moment):
        // a proxy not applied at all shows first there, not through A; a proxy applied with the old
        // connection left open shows at the socket (CI run 22: the socket came first and caught both).
        let socket = webSocketState()
        openPage("http://a-\(run).lumentest:28380/whoami?first=1")
        page("via: прокси A")
        page("ip: 127.0.0.2")
        XCTAssertEqual(socket, "ws: closed", "the proxy change closed the connection opened before it (a WebSocket): the page still says \(socket)")
        // The same site again — the page a person refreshes after setting a proxy — through A.
        openPage("http://pre-\(run).lumentest:28380/whoami?again=1")
        page("via: прокси A")
        // The testbed's own count: the first site was reached directly once — the visit before the
        // proxy — and never after it.
        openPage("http://site.lumentest:28380/__seen?token=pre-\(run)")
        let pre = pageLine("route pre-\(run): ")
        XCTAssertTrue(pre.contains("direct=1 "), "nothing went direct after the proxy was set: \(pre)")
        shot("31 through Berlin")

        // Another proxy while the session is open: the next page, to the same site, goes through it,
        // and nothing more of that site through A (its connection is kept alive, as real sites do).
        chooseProxy("Нью-Йорк", in: "Счета")
        assertTabKept("/__seen?token=pre-\(run)")
        openPage("http://a-\(run).lumentest:28380/whoami?after=change")
        page("via: прокси B")
        openPage("http://site.lumentest:28380/__seen?token=a-\(run)")
        let a = pageLine("route a-\(run): ")
        XCTAssertTrue(a.contains("A=1 ") && !a.contains("B=0 "), "nothing more went through A after the change: \(a)")
        shot("32 switched to New York")
        backToList()
        XCTAssertTrue(sessionCard("Счета").label.contains("Нью-Йорк"), "the card names the proxy: \(sessionCard("Счета").label)")
        XCTAssertTrue(sessionCard("Счета").label.contains("US"), "the card shows the exit country: \(sessionCard("Счета").label)")

        // Quit and start again: the card, the proxy, its password (Keychain) — all still work.
        relaunch()
        XCTAssertTrue(sessionCard("Счета").label.contains("Нью-Йорк"), "after a relaunch the card names the proxy")
        openSession("Счета")
        openPage("http://a-\(run).lumentest:28380/whoami?after=relaunch")
        page("via: прокси B")
        shot("33 after relaunch")
    }

    /// The most dangerous breakage: a proxy that is dead, or dies, and the session quietly going
    /// direct. On this testbed going direct is visible: *.lumentest names resolve for this Mac too
    /// (ci.sh), so a page that went around its proxy loads and says "via: напрямую", and the testbed
    /// counts every request and DNS question that reached it.
    func testDeadProxyNeverGoesDirect() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()   // names of this run only
        launch(reset: true)

        // The detector first (and proxy D up): a session without a proxy reaches a .lumentest name
        // directly, and the screen says so.
        createSession(name: "Контроль")
        openSession("Контроль")
        openPage("http://127.0.0.1:28380/__proxy?name=D&state=on")
        openPage("http://direct-\(run).lumentest:28380/whoami?t=control")
        page("via: напрямую")
        backToList()

        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Мёртвый HTTP", kind: "HTTP", port: "28389", user: "ux", password: "px")
        waitRow("Мёртвый HTTP", says: "Недоступен")
        addProxy(name: "Мёртвый SOCKS5", kind: "SOCKS5", port: "28390", user: "ux", password: "px")
        waitRow("Мёртвый SOCKS5", says: "Недоступен")
        addProxy(name: "Умирающий", kind: "HTTP", port: "28384", user: "ud", password: "pd")
        waitRow("Умирающий", says: "Работает")
        shot("37 dead proxies")
        leaveProxies()

        // Dead from the start, of each kind: nothing loads.
        createSession(name: "Без отката")
        openSession("Без отката")
        for (proxy, name) in [("Мёртвый HTTP", "dead-http"), ("Мёртвый SOCKS5", "dead-socks")] {
            chooseProxy(proxy, in: "Без отката")
            go("http://\(name)-\(run).lumentest:28380/whoami?t=\(name)")
            assertNothingLoaded(name)
        }
        shot("38 a dead proxy: nothing loads")

        // Alive, then dead: nothing loads after it, and nothing once a re-check has found it dead.
        chooseProxy("Умирающий", in: "Без отката")
        openPage("http://alive-\(run).lumentest:28380/whoami?t=alive")
        page("via: прокси D")
        backToList()
        openSession("Контроль")
        openPage("http://127.0.0.1:28380/__proxy?name=D&state=off")
        backToList()
        openSession("Без отката")
        go("http://dying-\(run).lumentest:28380/whoami?t=dying")
        assertNothingLoaded("dying")
        backToList()
        app.buttons["proxiesButton"].tap()
        wait(proxyRow("Умирающий"), "the proxy list opens").swipeLeft()
        wait(app.buttons["Проверить"], "the row offers a re-check").tap()
        waitRow("Умирающий", says: "Недоступен")
        leaveProxies()
        openSession("Без отката")
        go("http://rechecked-\(run).lumentest:28380/whoami?t=rechecked")
        assertNothingLoaded("rechecked")
        shot("39 the proxy died: nothing loads")

        // What reached the testbed, read in the control session: nothing of those pages, not even a
        // DNS question; the control's own direct request was counted (the counter works).
        backToList()
        openSession("Контроль")
        for name in ["dead-http", "dead-socks", "dying", "rechecked"] {
            let token = "\(name)-\(run)"
            openPage("http://127.0.0.1:28380/__seen?token=\(token)")
            XCTAssertEqual(pageLine("site \(token): "), "site \(token): 0", "no request of \(name) reached the site")
            XCTAssertEqual(pageLine("dns \(token): "), "dns \(token): 0", "no DNS question for \(name) was asked of this Mac")
        }
        openPage("http://127.0.0.1:28380/__seen?token=direct-\(run)")
        XCTAssertNotEqual(pageLine("site direct-\(run): "), "site direct-\(run): 0", "the control's direct request was counted")
        openPage("http://127.0.0.1:28380/__proxy?name=D&state=on")
    }
}
