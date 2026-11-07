import XCTest

/// Proxies the way a person handles them: add, see the check, give one to a session, change it while
/// the session is open, quit and start again.
final class ProxyTests: LumenUITestCase {
    func testProxyPersonPath() {
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
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A session through the Berlin proxy: the site sees proxy A (a .lumentest name resolves only there).
        createSession(name: "Счета")
        openSession("Счета")
        chooseProxy("Берлин")
        go("http://site.lumentest:28380/whoami")
        page("via: прокси A")
        page("ip: 127.0.0.2")
        shot("31 through Berlin")

        // Another proxy while the session is open: the next page goes through it, no relaunch.
        chooseProxy("Нью-Йорк")
        go("http://site.lumentest:28380/whoami?after=change")
        page("via: прокси B")
        shot("32 switched to New York")
        backToList()
        XCTAssertTrue(sessionCard("Счета").label.contains("Нью-Йорк"), "the card names the proxy: \(sessionCard("Счета").label)")
        XCTAssertTrue(sessionCard("Счета").label.contains("US"), "the card shows the exit country: \(sessionCard("Счета").label)")

        // Quit and start again: the card, the proxy, its password (Keychain) — all still work.
        relaunch()
        XCTAssertTrue(sessionCard("Счета").label.contains("Нью-Йорк"), "after a relaunch the card names the proxy")
        openSession("Счета")
        go("http://site.lumentest:28380/whoami?after=relaunch")
        page("via: прокси B")
        shot("33 after relaunch")
    }
}
