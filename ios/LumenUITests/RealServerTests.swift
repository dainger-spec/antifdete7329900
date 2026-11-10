import XCTest

/// The app against the real Lumen account server (the lead, 10 November 2026): the test account
/// signs in, the document of rights is checked with the production key, the plan's rights open,
/// they hold over a restart, and signing out frees the phone's place. Run by hand only (the
/// "RealServerTests" suite of ios-app.yml) — it talks to production. The account's address and
/// password come from the runner's environment (the repository's secrets), never from the sources.
/// The repository is public: no screenshot is taken while the address is on the screen, no message
/// of a failure holds it, and the workflow wipes both from what it uploads (ios-app.yml).
final class RealServerTests: LumenUITestCase {
    func testSigningInOnTheRealServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["LUMEN_E2E_EMAIL"], let password = environment["LUMEN_E2E_PASSWORD"],
              !email.isEmpty, !password.isEmpty else {
            if environment["LUMEN_E2E_REQUIRED"] == "1" { XCTFail("the test account is not given: LUMEN_E2E_EMAIL, LUMEN_E2E_PASSWORD") }
            throw XCTSkip("no test account given — the real server is not touched")
        }
        // Nothing fixed, as a release starts: the account decides. The server, the site and the
        // key of the documents are the app's own (its Info.plist).
        let settings: [String: String] = [:]
        launch(reset: true, access: "account", environment: settings)

        app.buttons["plansButton"].tap()
        wait(app.staticTexts["profileCounter"], "the account's screen opens")
        wait(app.staticTexts["signedOut"], "nobody is signed in")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 0 из 2")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: нет")

        reveal(app.buttons["signIn"], "the account's screen offers to sign in").tap()
        typeInto(wait(app.textFields["signInEmail"], "the sign-in form opens"), email)
        typeInto(app.secureTextFields["signInPassword"], password)
        reveal(app.buttons["submitSignIn"], "the form has its button").tap()
        if !app.staticTexts["accountEmail"].waitForExistence(timeout: 45) {
            let said = app.staticTexts["signInMessage"].exists ? app.staticTexts["signInMessage"].label : "nothing"
            XCTFail("not signed in on the real server; the form says: \(said)")
            return
        }
        // The repository is public: the address is in no message of a failure.
        XCTAssertTrue(app.staticTexts["accountEmail"].label.lowercased() == email.lowercased(), "the signed-in address is the test account's")
        paidPlanShown("signed in")

        // The document is kept and checked again at the start: the rights hold over a restart.
        app.terminate()
        launch(reset: false, access: "account", environment: settings)
        app.buttons["plansButton"].tap()
        wait(app.staticTexts["accountEmail"], "still signed in after a restart", timeout: 30)
        paidPlanShown("after a restart")

        // Signing out frees the phone's place on the server and brings the free level back.
        reveal(app.buttons["signOut"], "the account's screen offers to sign out").tap()
        touchable("confirmSignOut", "signing out asks first").tap()
        wait(app.staticTexts["signedOut"], "signed out", timeout: 30)
        XCTAssertFalse(app.staticTexts["planName"].exists, "no plan is named once signed out")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 0 из 2")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: нет")
        shot("90 real server: signed out again")
    }

    /// The test account's plan as its document says it: pro, proxies open, room for profiles beyond
    /// the free two (how many, the other devices of the license decide).
    func paidPlanShown(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let plan = wait(app.staticTexts["planName"], "\(when): a paid plan is named", timeout: 30, file: file, line: line).label
        XCTAssertEqual(plan, "Тариф: Профессиональный", when, file: file, line: line)
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: есть", when, file: file, line: line)
        let counter = app.staticTexts["profileCounter"].label
        let room = Int(counter.components(separatedBy: " из ").last ?? "") ?? 0
        XCTAssertTrue(counter.hasPrefix("Профили: 0 из ") && room > 2 && room <= 50, "\(when): the counter is the plan's — \(counter)", file: file, line: line)
    }
}
