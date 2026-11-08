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

    /// iOS 17 (measured on the 17.5 simulator): an HTTP proxy lets plain-http pages go around it, and a
    /// dead one lets every page go direct. There a session with an HTTP proxy loads nothing and says
    /// why; a SOCKS5 proxy works. Run on a newer simulator told to behave as iOS 17.
    func testHTTPProxyRefusedOnIOS17() {
        extraEnvironment = ["LUMEN_TEST_AS_IOS17": "1"]
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "не поддерживается")
        addProxy(name: "Нью-Йорк", kind: "SOCKS5", port: "28382", user: "ub", password: "pb")
        waitRow("Нью-Йорк", says: "Работает")
        shot("34 iOS 17: the HTTP proxy is not supported")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A session through the HTTP proxy: the page does not load (a .lumentest name resolves only
        // through the testbed's proxies, so a page that loaded went through one of them).
        createSession(name: "Старый iPhone")
        openSession("Старый iPhone")
        chooseProxy("Берлин")
        go("http://site.lumentest:28380/whoami")
        sleep(5)
        let loaded = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "via:")).firstMatch
        XCTAssertFalse(loaded.exists, "nothing loads through the HTTP proxy: \(loaded.exists ? loaded.label : "")")
        let refused = app.descendants(matching: .any)["proxyRefused"]
        wait(refused, "the browser says why the session loads nothing")
        XCTAssertTrue(refused.label.contains("iOS 18") && refused.label.contains("SOCKS5"), "it says what would work: \(refused.label)")
        shot("35 iOS 17: the session loads nothing")

        // The same session through SOCKS5: it loads, the notice is gone.
        chooseProxy("Нью-Йорк")
        waitGone(refused, "with SOCKS5 the notice is gone")
        go("http://site.lumentest:28380/whoami?socks")
        page("via: прокси B")

        // Back to the HTTP proxy, quit and start again: the restored tab (its last page was the
        // SOCKS5 one) loads nothing either.
        chooseProxy("Берлин")
        wait(refused, "back on the HTTP proxy, the notice is back")
        relaunch()
        openSession("Старый iPhone")
        wait(app.descendants(matching: .any)["proxyRefused"], "after a relaunch the notice is there")
        sleep(5)
        let restored = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "via:")).firstMatch
        XCTAssertFalse(restored.exists, "after a relaunch the restored tab does not load: \(restored.exists ? restored.label : "")")
        shot("36 iOS 17: after relaunch")
    }
}
