import XCTest

/// Signing in to a Lumen account (the owner and the lead, 9 November; the server's docs/IPHONE.md),
/// against the testbed's stand-in for the account server (ios/testbed/account.py): login and password,
/// an activation that says "ios", and the rights read from the signed document — its features and
/// limits — and from nothing else. What an account is, its address says (the stand-in's list).
final class AccountTests: LumenUITestCase {
    let password = "correct-horse-1"

    /// The app as a release build starts — nothing fixed, the account decides — with the stand-in
    /// for its server, the stand-in's key for its documents, and the testbed for its site.
    func launchWithAccount(reset: Bool = true, run: String) {
        launch(reset: reset, access: "account", environment: [
            "LUMEN_TEST_ACCOUNT_SERVER": "http://account.lumentest:28395",
            "LUMEN_TEST_ENTITLEMENT_KEYS": "cbbc653cdb8bd787:dNOl9JtGQJg6VOEIn3+1dscg5hWYkx9XUqm+qJ5CnZc=",
            "LUMEN_TEST_SITE_URL": "http://127.0.0.1:28380/site-\(run)",
            // The sync's key kept without Face ID: a simulator has no passcode and no face.
            "LUMEN_TEST_SYNC_NO_PRESENCE": "1",
        ])
    }

    func openPlan() {
        app.buttons["plansButton"].tap()
        wait(app.staticTexts["profileCounter"], "the account's screen opens")
    }

    func closePlan() {
        app.buttons["plansDone"].tap()
        wait(app.navigationBars["Сессии"], "back on the session list")
    }

    /// On the plan's screen: the sign-in form filled and sent.
    func signIn(_ email: String, password: String? = nil) {
        reveal(app.buttons["signIn"], "the plan's screen offers to sign in").tap()
        typeInto(wait(app.textFields["signInEmail"], "the sign-in form opens"), email)
        let secret = app.secureTextFields["signInPassword"]
        typeInto(secret, password ?? self.password)
        // A secure field's typing can be lost (CI run 74: the second sign-in of a test sent nothing —
        // the button stayed disabled, its password field empty): typed again once when it is.
        let submit = app.buttons["submitSignIn"]
        if !submit.isEnabled || ((secret.value as? String) ?? "").isEmpty {
            typeInto(secret, password ?? self.password)
        }
        XCTAssertTrue(submit.isEnabled, "the sign-in form takes the address and the password")
        reveal(submit, "the form has its button").tap()
    }

    /// The form's own words, once it has an answer.
    func signInMessage(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        wait(app.staticTexts["signInMessage"], what, timeout: 30, file: file, line: line).label
    }

    func cancelSignIn() {
        app.buttons["cancelSignIn"].tap()
        waitGone(app.textFields["signInEmail"], "the sign-in form closes")
    }

    func signOut() {
        reveal(app.buttons["signOut"], "the plan's screen offers to sign out").tap()
        touchable("confirmSignOut", "signing out asks first").tap()
        wait(app.staticTexts["signedOut"], "signed out", timeout: 20)
    }

    func waitLabel(_ id: String, _ text: String, _ what: String, timeout: TimeInterval = 30,
                   file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts[id]
        let predicate = NSPredicate(format: "label == %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(what): \(element.exists ? element.label : "nothing")", file: file, line: line)
    }

    /// The person's path: free without an account; signed in, the plan's rights; the plan over on the
    /// server, the free level from the document and the locks; unlinked on the server, signed out.
    func testSigningInOpensThePlan() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        let email = "pro-\(run)@lumen.test"
        launchWithAccount(run: run)
        app.buttons["proxiesButton"].tap()
        wait(app.navigationBars["Прокси"], "the proxy list opens")
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "Работает")
        leaveProxies()

        // Nobody signed in: the free level.
        openPlan()
        wait(app.staticTexts["signedOut"], "nobody is signed in")
        XCTAssertFalse(app.staticTexts["planName"].exists, "no plan is named to a person who is not signed in")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: нет")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 0 из 2")

        // Signed in: the plan as the document says it.
        signIn(email)
        wait(app.staticTexts["accountEmail"], "signed in: the activation said it is an iPhone's", timeout: 30)
        XCTAssertEqual(app.staticTexts["accountEmail"].label, email)
        waitLabel("planName", "Тариф: Профессиональный", "the plan is the document's")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: есть")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 0 из 50")
        XCTAssertFalse(passwordOffer.exists, "no offer to keep the account's password among the person's own")
        shot("70 signed in: the plan")
        closePlan()

        // Three profiles; the first lives behind a proxy.
        createSession(name: "Первый")
        createSession(name: "Второй")
        createSession(name: "Третий")
        openSession("Первый")
        chooseProxy("Берлин", in: "Первый")
        openPage("http://acc-\(run).lumentest:28380/whoami?t=paid")
        page("via: прокси A")
        // What the server saw of the activation: an iPhone, its hashed id, no name of anything, and
        // the session ended once it had served.
        openPage("http://site.lumentest:28380/__account?email=\(email)&t=seen")
        XCTAssertEqual(pageLine("platform: "), "platform: ios")
        XCTAssertEqual(pageLine("machine: "), "machine: 64 hex", "the iPhone's id goes as a hash")
        XCTAssertEqual(pageLine("label: "), "label: none", "no name is sent")
        XCTAssertEqual(pageLine("sessions open: "), "sessions open: 0", "the account's session is ended after the activation")

        // The paid period over on the server: the next document gives the free level, and the app
        // takes it — the proxied profile locked, the third beyond the count, the second as it was.
        openPage("http://site.lumentest:28380/__account?email=\(email)&set=ended")
        XCTAssertEqual(pageLine("plan: "), "plan: ended")
        backToList()
        openPlan()
        reveal(app.buttons["refreshAccount"], "the plan's screen asks the server again").tap()
        waitLabel("planProxies", "Прокси: нет", "a fresh document that gives less is taken")
        XCTAssertFalse(app.staticTexts["planName"].exists, "a plan whose period ended is not named as one")
        XCTAssertEqual(app.staticTexts["accountNotice"].label, "Оплаченный период закончился. Прокси недоступны.")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 3 из 2")
        shot("71 the paid period over")
        closePlan()
        XCTAssertTrue(sessionCard("Первый").label.contains("Заперт: без прокси не откроется"),
                      "the profile that lived behind a proxy is locked: \(sessionCard("Первый").label)")
        XCTAssertTrue(sessionCard("Третий").label.contains("сверх числа профилей"),
                      "a profile beyond the plan's count is locked: \(sessionCard("Третий").label)")
        XCTAssertFalse(sessionCard("Второй").label.contains("Заперт"), "a profile within the count stays open: \(sessionCard("Второй").label)")
        sessionCard("Третий").tap()
        wait(app.descendants(matching: .any)["lockedSession"], "the profile beyond the count says why it does not open")
        backToList()
        openSession("Второй")
        openPage("http://acc-\(run).lumentest:28380/whoami?t=free")
        XCTAssertNotNil(webText("напрямую"), "a profile within the count browses without a proxy")

        // Unlinked on the server (the site's cabinet): the next answer signs the iPhone out.
        openPage("http://site.lumentest:28380/__account?email=\(email)&set=revoked")
        backToList()
        openPlan()
        reveal(app.buttons["refreshAccount"], "the plan's screen asks the server again").tap()
        wait(app.staticTexts["signedOut"], "an iPhone unlinked on the server is signed out", timeout: 30)
        XCTAssertEqual(app.staticTexts["accountNotice"].label, "Этот iPhone отключён от аккаунта. Войдите снова.")
        XCTAssertFalse(app.staticTexts["planName"].exists)
        shot("72 unlinked on the server")
        closePlan()

        // Signed in again on the same iPhone: the same device to the server (one id through it all).
        openPlan()
        signIn(email)
        wait(app.staticTexts["accountEmail"], "signed in again", timeout: 30)
        closePlan()
        openSession("Второй")
        openPage("http://site.lumentest:28380/__account?email=\(email)&t=again")
        XCTAssertEqual(pageLine("machines: "), "machines: 1", "the iPhone keeps one id")
        XCTAssertEqual(pageLine("profiles sent: "), "profiles sent: 3")
    }

    /// What the server may answer a sign-in with, each said to the person as it is — and the rights
    /// of accounts that are not a plain paid plan.
    func testRefusalsChecksAndOtherPlans() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launchWithAccount(run: run)
        createSession(name: "Проба")
        openPlan()

        // A wrong password.
        signIn("pro-\(run)@lumen.test", password: "not-the-password")
        XCTAssertEqual(signInMessage("a wrong password is refused"), "Неверная почта или пароль.")
        cancelSignIn()

        // The license's phones are all taken: the refusal says so.
        signIn("phones-\(run)@lumen.test")
        let limit = signInMessage("the activation over the limit of phones is refused")
        XCTAssertTrue(limit.contains("наибольшее число iPhone (3)"), "the limit of phones is said with its reason: \(limit)")
        shot("73 the limit of phones")
        cancelSignIn()

        // A document signed with another key, under the trusted key's name: not taken.
        signIn("forged-\(run)@lumen.test")
        let forged = app.staticTexts["signInMessage"]
        XCTAssertTrue(forged.waitForExistence(timeout: 30), "a document signed with another key is refused")
        XCTAssertEqual(forged.label, "Сервер Lumen не отвечает. Проверьте соединение и попробуйте ещё раз.")
        cancelSignIn()
        wait(app.staticTexts["signedOut"], "nobody is signed in after a refused document")

        // A document signed with a key this app does not carry: the app is the one out of date.
        signIn("newkey-\(run)@lumen.test")
        XCTAssertEqual(signInMessage("a document under an unknown key is not judged"), "Обновите Lumen.")
        cancelSignIn()

        // A blocked account.
        signIn("blocked-\(run)@lumen.test")
        XCTAssertEqual(signInMessage("a blocked account is refused"), "Аккаунт заблокирован, напишите в поддержку.")
        cancelSignIn()

        // After failed attempts the server asks for the site's robot check: in the app's own window.
        signIn("robot-\(run)@lumen.test")
        let robot = app.webViews.buttons["Я не робот"]
        XCTAssertTrue(robot.waitForExistence(timeout: 30), "the robot check opens in the app")
        shot("74 the robot check")
        robot.tap()
        wait(app.staticTexts["accountEmail"], "signed in after the robot check", timeout: 30)
        XCTAssertEqual(app.state, .runningForeground, "the check never left the app")
        signOut()

        // Or for a code from the account's email.
        signIn("code-\(run)@lumen.test")
        let code = wait(app.textFields["signInCode"], "the code from the email is asked for", timeout: 30)
        typeInto(code, "111111")
        reveal(app.buttons["submitCode"], "the code's button").tap()
        XCTAssertEqual(signInMessage("a wrong code is refused"), "Код неверный или устарел.")
        replaceText(code, with: "424242")
        reveal(app.buttons["submitCode"], "the code's button").tap()
        wait(app.staticTexts["accountEmail"], "signed in with the code", timeout: 30)
        signOut()

        // A paid plan whose document names no proxies has none: the features decide, not the name.
        signIn("browseonly-\(run)@lumen.test")
        wait(app.staticTexts["accountEmail"], "signed in", timeout: 30)
        waitLabel("planName", "Тариф: Профессиональный", "the plan's name is the document's")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: нет", "no proxies without the feature")
        signOut()

        // An account without a plan: the free level, as the document writes it. The trial: both.
        signIn("free-\(run)@lumen.test")
        wait(app.staticTexts["accountEmail"], "signed in", timeout: 30)
        waitLabel("profileCounter", "Профили: 1 из 2", "an account without a plan has the free level")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: нет")
        XCTAssertFalse(app.staticTexts["planName"].exists, "no plan is named to an account that has paid for none")
        closePlan()
        XCTAssertFalse(sessionCard("Проба").label.contains("Заперт"), "the free level opens its profiles: \(sessionCard("Проба").label)")
        openPlan()
        signOut()
        signIn("trial-\(run)@lumen.test")
        wait(app.staticTexts["accountEmail"], "signed in", timeout: 30)
        waitLabel("planName", "Тариф: 7 дней бесплатно", "a running trial works on the iPhone")
        XCTAssertEqual(app.staticTexts["planProxies"].label, "Прокси: есть")
        XCTAssertEqual(app.staticTexts["profileCounter"].label, "Профили: 1 из 3")
        shot("75 the trial")
        signOut()

        // A blocked account: its document opens nothing (features []) — not the free level.
        signIn("disabled-\(run)@lumen.test")
        wait(app.staticTexts["accountEmail"], "signed in", timeout: 30)
        waitLabel("accountNotice", "Аккаунт заблокирован, напишите в поддержку.", "a blocked account is told so")
        XCTAssertFalse(app.staticTexts["planName"].exists)
        closePlan()
        XCTAssertTrue(sessionCard("Проба").label.contains("Заперт"), "a blocked account opens no profile: \(sessionCard("Проба").label)")
        sessionCard("Проба").tap()
        wait(app.descendants(matching: .any)["lockedSession"], "the profile says why it does not open")
        shot("76 a blocked account")
    }

    /// The sync's step 2 (ios/SYNC_PLAN.md): the iPhone connects to the account's vault — the one the
    /// stand-in's Mac made, master password "vault-pass-1" — with the master password asked once and
    /// only a key kept; a wrong password keeps nothing; "forget" asks for it again. Without a plan
    /// the sync is a state, not an error.
    func testSyncConnectsTheMacsVault() {
        let run = String(UUID().uuidString.prefix(6)).lowercased()
        launchWithAccount(run: run)
        openPlan()
        signIn("pro-\(run)@lumen.test")
        wait(app.staticTexts["accountEmail"], "signed in", timeout: 30)
        reveal(app.buttons["syncButton"], "the account's screen offers the sync").tap()

        let field = wait(app.secureTextFields["syncPassword"], "the vault is found and its master password asked", timeout: 30)
        typeInto(field, "wrong-pass")
        app.buttons["syncConnect"].tap()
        waitLabel("syncMessage", "Неверный мастер-пароль.", "a wrong master password keeps nothing")
        XCTAssertFalse(app.staticTexts["syncConnected"].exists)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "vault-pass-1")
        app.buttons["syncConnect"].tap()
        wait(app.staticTexts["syncConnected"], "the right master password connects the vault", timeout: 30)
        XCTAssertFalse(passwordOffer.exists, "no offer to keep the master password among the person's own")
        shot("77 the vault connected")

        // Step 3: one run reads the Mac's profiles (the stand-in's vault, made by the Mac's own code)
        // and makes them sessions — the one behind a proxy with its proxy, login and password, bound.
        app.buttons["syncNow"].tap()
        let result = wait(app.staticTexts["syncResult"], "the run says what came", timeout: 60)
        XCTAssertTrue(result.label.hasPrefix("Профилей с Mac: 2"), "both of the Mac's profiles came: \(result.label)")
        shot("79 the Mac's profiles read")
        app.buttons["syncDone"].tap()
        closePlan()
        wait(sessionCard("Магазин с Mac"), "the Mac's profile is a session here")
        wait(sessionCard("Почта с Mac"), "and the other one")
        XCTAssertTrue(sessionCard("Магазин с Mac").label.contains("Синхронизирован с Mac"), "its description came: \(sessionCard("Магазин с Mac").label)")
        openSession("Магазин с Mac")
        openPage("http://synced-\(run).lumentest:28380/whoami?t=synced")
        page("via: прокси B")
        backToList()

        // Step 4: the next run brings the Mac's cookies into the session made by the first — the
        // Mac's sign-in on macstate.lumentest is there.
        openPlan()
        reveal(app.buttons["syncButton"], "the sync's screen again").tap()
        wait(app.staticTexts["syncConnected"], "still connected", timeout: 15)
        app.buttons["syncNow"].tap()
        let second = wait(app.staticTexts["syncResult"], "the second run says what came", timeout: 60)
        XCTAssertTrue(second.label.contains("Куки обновлены: 1"), "the Mac's cookie went into the session: \(second.label)")
        app.buttons["syncDone"].tap()
        closePlan()
        openSession("Магазин с Mac")
        // /state says no "at:" line: the cookie's own line is waited for (as BrowserTests do).
        go("http://macstate.lumentest:28380/state")
        page("cookie: from-mac", timeout: 30)
        backToList()
        openPlan()
        reveal(app.buttons["syncButton"], "the sync's screen once more").tap()
        wait(app.staticTexts["syncConnected"], "still connected", timeout: 15)

        // Step 5: the renewal carries the synced profiles' tokens (CONTRACT.md §6.2) — one place each
        // for a profile on the Mac and here.
        app.buttons["syncDone"].tap()
        reveal(app.buttons["refreshAccount"], "the account's screen refreshes").tap()
        wait(app.staticTexts["accountEmail"], "still signed in after the renewal", timeout: 30)
        sleep(2)
        closePlan()
        openSession("Почта с Mac")
        openPage("http://site.lumentest:28380/__account?email=pro-\(run)@lumen.test&t=tokens")
        XCTAssertEqual(pageLine("profile tokens: "), "profile tokens: 2", "the renewal said which profiles are synced")
        backToList()
        openPlan()
        reveal(app.buttons["syncButton"], "the sync's screen after the renewal").tap()
        wait(app.staticTexts["syncConnected"], "still connected", timeout: 15)

        // Kept: the screen opened again says so at once, no password asked.
        app.buttons["syncDone"].tap()
        reveal(app.buttons["syncButton"], "the sync again").tap()
        wait(app.staticTexts["syncConnected"], "the kept key: connected without asking", timeout: 15)
        XCTAssertFalse(app.secureTextFields["syncPassword"].exists)
        // Forgotten: the password is asked again.
        app.buttons["syncForget"].tap()
        wait(app.secureTextFields["syncPassword"], "forgotten: the master password is asked again", timeout: 30)
        app.buttons["syncDone"].tap()
        signOut()

        // An account without a plan: the sync is said to be the plan's, nothing asked.
        signIn("free-\(run)@lumen.test")
        wait(app.staticTexts["accountEmail"], "signed in without a plan", timeout: 30)
        reveal(app.buttons["syncButton"], "the sync's screen is there without a plan too").tap()
        wait(app.staticTexts["syncNotInPlan"], "without a plan the sync says it is the plan's", timeout: 30)
        XCTAssertFalse(app.secureTextFields["syncPassword"].exists, "no master password is asked without a plan")
        shot("78 the sync without a plan")
    }
}
