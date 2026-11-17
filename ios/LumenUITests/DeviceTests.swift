import UIKit
import XCTest

/// The person's main path on the iPhones testers carry, as ios/scripts/devices.sh sets each one up
/// (the workflow's job "devices"): the 4.7-inch iPhone SE on the oldest iOS the app installs on (18),
/// the Pro Max with the iPhone in dark appearance, the smallest iPhone at the largest accessibility
/// text size. The main jobs run on one iPhone 17 Pro, newest iOS, light, default text.
///
/// Along the path every control a person needs must be on the screen and take a touch, the app must
/// stay dark whatever the iPhone's appearance, and turning the iPhone must leave it upright (the app
/// is portrait only, iPhone only). Each screen is kept as a picture (screens/<leg>/ in the artifact)
/// for a person to look at: what a test cannot judge — a word cut short, a crowded row — is seen there.
final class DeviceTests: LumenUITestCase {
    let password = "correct-horse-1"

    func testThePathOnThisIPhone() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        let leg = ProcessInfo.processInfo.environment["LUMEN_DEVICE_LEG"] ?? "device"
        // As a release build starts: nothing fixed, nobody signed in — the free level — with the
        // testbed's stand-in for the account server.
        launch(reset: true, access: "account", environment: [
            "LUMEN_TEST_ACCOUNT_SERVER": "http://account.lumentest:28395",
            "LUMEN_TEST_ENTITLEMENT_KEYS": "cbbc653cdb8bd787:dNOl9JtGQJg6VOEIn3+1dscg5hWYkx9XUqm+qJ5CnZc=",
            "LUMEN_TEST_SITE_URL": "http://127.0.0.1:28380/site-\(run)",
        ])

        // The first launch: no session yet, and the way to make one.
        onScreen(reveal(app.buttons["newSessionEmpty"], "the first launch offers a new session"), "the empty list's button", wholly: false)
        onScreen(app.buttons["newSession"], "the list's own button for a new session")
        onScreen(app.buttons["plansButton"], "the account's button")
        onScreen(app.buttons["proxiesButton"], "the proxies' button")
        assertDark("the first launch")
        shot("\(leg) 01 first launch")

        // Two sessions (the free level's two), one with a long name.
        let long = "Магазин — длинное имя для маленького экрана"
        createSession(name: long, notes: "Описание сессии, которое не помещается в одну строку на узком экране", tags: "работа")
        createSession(name: "Почта")
        // A list scrolls: a card is reached as a person reaches it, then it must take a touch.
        onScreen(reveal(sessionCard(long), "the card with the long name can be reached"), "the card with the long name", wholly: false)
        onScreen(reveal(sessionCard("Почта"), "the second card can be reached"), "the second card", wholly: false)
        shot("\(leg) 02 sessions")

        // A session's browser: the address bar and the bar below the page, a page loaded.
        openSession(long)
        onScreen(app.textFields["addressBar"], "the address bar")
        onScreen(app.buttons["tabsButton"], "the tabs' button")
        onScreen(app.buttons["settingsButton"], "the settings' button")
        // The page's "at:" line, which says " — напрямую" for a page reached without a proxy.
        openPage("http://\(site)/whoami?t=device-\(run)")
        if app.keyboards.count > 0 { app.webViews.firstMatch.tap() }
        onScreen(app.buttons["tabsButton"], "the tabs' button with a page loaded")
        shot("\(leg) 03 a page")

        openTabs()
        onScreen(app.buttons["newTab"], "a new tab's button")
        shot("\(leg) 04 tabs")
        onScreen(app.buttons["tabsDone"], "the tabs close").tap()
        waitForBrowser(session: long)

        app.buttons["settingsButton"].tap()
        onScreen(wait(app.buttons["settingsDone"], "the settings open"), "the settings' Done")
        // The dashboard's design: the device profile is a choice of rows (Полный, Упрощённый, Свой).
        _ = onScreen(reveal(app.buttons["profile-full"], "the device profile's choice can be reached"), "the device profile's choice", wholly: false)
        shot("\(leg) 05 settings")
        app.buttons["settingsDone"].tap()
        waitForBrowser(session: long)
        backToList()

        // The proxies: the form, then the proxy checked.
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает", timeout: 40)
        onScreen(proxyRow("Берлин"), "the proxy's row", wholly: false)
        onScreen(app.buttons["newProxy"], "the list's button for a new proxy")
        assertDark("the proxies")
        shot("\(leg) 06 proxies")
        leaveProxies()

        // The account: the free level, the sign-in form, a paid plan signed in, signed out again.
        // At the largest text the counter is below the account's own rows: read where a person scrolls to it.
        app.buttons["plansButton"].tap()
        onScreen(wait(app.buttons["plansDone"], "the account's screen opens"), "the account's Done")
        XCTAssertEqual(reveal(app.staticTexts["profileCounter"], "the account's screen says how many profiles").label, "Профили: 2 из 2")
        assertDark("the account's screen")
        shot("\(leg) 07 account, nobody signed in")
        reveal(app.buttons["signIn"], "the account's screen offers to sign in").tap()
        typeInto(wait(app.textFields["signInEmail"], "the sign-in form opens", timeout: 15), "pro-\(run)@lumen.test")
        let secret = app.secureTextFields["signInPassword"]
        typeInto(secret, password)
        if ((secret.value as? String) ?? "").isEmpty { typeInto(secret, password) }   // AccountTests.signIn: a secure field's typing can be lost
        onScreen(app.buttons["cancelSignIn"], "the sign-in form's Cancel")
        shot("\(leg) 08 sign-in form")
        reveal(app.buttons["submitSignIn"], "the sign-in form's button can be reached").tap()
        // Signed in, the account's screen keeps where it was scrolled; at the largest text on the SE
        // the address's row is above it and the list has not made it (run 163): scrolled to, as a
        // person does, once the plan's rows say the sign-in went through.
        let email = app.staticTexts["accountEmail"]
        let signedIn = Date().addingTimeInterval(40)
        while !email.exists, Date() < signedIn {
            if app.staticTexts["planProxies"].exists || app.staticTexts["profileCounter"].exists { scroll(towardStart: true) }
            usleep(500_000)
        }
        XCTAssertTrue(email.exists, "signed in")
        // The plan, below the account's rows: scrolled to, as a person does, once the server named it.
        let plan = app.staticTexts["planName"]
        let named = Date().addingTimeInterval(30)
        while !reachable(plan), Date() < named {
            scroll(towardStart: isAbove(plan))
            usleep(500_000)
        }
        XCTAssertTrue(reachable(plan), "the plan is named once signed in")
        XCTAssertEqual(plan.label, "Тариф: Профессиональный")
        onScreen(reveal(app.buttons["signOut"], "the account's screen offers to sign out"), "the sign-out button", wholly: false)
        shot("\(leg) 09 signed in")
        app.buttons["signOut"].tap()
        let confirm = touchable("confirmSignOut", "signing out asks first")
        XCTAssertTrue(confirm.isHittable, "the sign-out's confirmation takes a touch")
        shot("\(leg) 10 sign out?")
        confirm.tap()
        wait(app.staticTexts["signedOut"], "signed out", timeout: 20)
        app.buttons["plansDone"].tap()
        wait(app.navigationBars["Сессии"], "back on the session list")

        // Turned on its side and back, the iPhone keeps the app upright (portrait only) and usable.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertTrue(app.navigationBars["Сессии"].exists, "the list stays on the screen with the iPhone on its side")
        shot("\(leg) 11 on its side")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        onScreen(reveal(sessionCard("Почта"), "a card can be reached"), "a card, the iPhone upright again", wholly: false)
    }

    /// `element` is there and takes a touch; `wholly`: and lies wholly inside the window — a button
    /// of a bar, a field, a form's button (a row of a list that scrolls may stand at its edge).
    @discardableResult
    func onScreen(_ element: XCUIElement, _ what: String, wholly: Bool = true,
                  file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(what): there", file: file, line: line)
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertTrue(element.isHittable, "\(what): takes a touch (\(frame) in \(window))", file: file, line: line)
        if wholly {
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(frame), "\(what): wholly on the screen (\(frame) in \(window))",
                          file: file, line: line)
        }
        return element
    }

    /// The screen is dark: the app's look (Eclipse) whatever the iPhone's appearance.
    func assertDark(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let level = Self.meanLuminance(XCUIScreen.main.screenshot().image)
        XCTAssertLessThan(level, 0.3, "\(what): the app is dark whatever the iPhone's appearance (mean luminance \(level))",
                          file: file, line: line)
    }

    /// The mean luminance of a picture, 0 (black) to 1 (white), from a small copy of it.
    static func meanLuminance(_ image: UIImage) -> Double {
        guard let picture = image.cgImage else { return 1 }
        let width = 24, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 1 }
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return sum / Double(width * height) / 255
    }
}
