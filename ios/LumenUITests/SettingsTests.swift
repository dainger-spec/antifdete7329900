import XCTest

/// A session's settings as a person changes them, judged by what the testbed's /env page shows:
/// the User-Agent, the time zone and language of the proxy's country, canvas/WebGL/audio, and that
/// no replacement is seen by the natives check.
final class SettingsTests: LumenUITestCase {
    func testSessionSettingsPersonPath() {
        launch(reset: true)
        app.buttons["proxiesButton"].tap()
        addProxy(name: "Берлин", kind: "HTTP", port: "28381", user: "ua", password: "pa")
        waitRow("Берлин", says: "DE")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        createSession(name: "Профиль")
        openSession("Профиль")

        // As it comes: Safari's User-Agent, nothing replaced.
        openPage("\(site)/env?first=1")
        let ua = pageLine("ua: ")
        XCTAssertTrue(ua.contains("Version/") && ua.hasSuffix("Safari/604.1"), "a new session reads as Safari: \(ua)")
        let realCanvas = pageLine("canvas: ")
        let realAudio = pageLine("audio: ")
        XCTAssertFalse(pageLine("webgl: ").contains("none"), "WebGL is there by default")
        XCTAssertEqual(pageLine("lies: "), "lies: 0", "nothing replaced, nothing found")

        // Through the Berlin proxy: Berlin's time zone and German, from the proxy's check.
        chooseProxy("Берлин")
        openPage("http://env.lumentest:28380/env?proxy=berlin")
        XCTAssertEqual(pageLine("tz: "), "tz: Europe/Berlin", "the time zone of the proxy's country")
        XCTAssertEqual(pageLine("lang: "), "lang: de-DE", "the language of the proxy's country")
        shot("40 Berlin's time zone and language")

        // iOS 26's Safari, canvas noise, WebGL off, audio noise.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        reveal(app.buttons["iOS 26 — Safari 26"], "the presets are listed").tap()
        reveal(app.segmentedControls["canvasMode"], "the canvas mode is there").buttons["Шум"].tap()
        reveal(app.segmentedControls["webglMode"], "the WebGL mode is there").buttons["Выкл"].tap()
        reveal(app.segmentedControls["audioMode"], "the audio mode is there").buttons["Шум"].tap()
        shot("41 settings")
        app.buttons["settingsDone"].tap()
        openPage("http://env.lumentest:28380/env?changed=1")
        XCTAssertTrue(pageLine("ua: ").contains("Version/26.0"), "the page reads iOS 26's Safari: \(pageLine("ua: "))")
        page("server ua: Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0")
        let noised = pageLine("canvas: ")
        XCTAssertNotEqual(noised.replacingOccurrences(of: "canvas: ", with: ""), realCanvas.replacingOccurrences(of: "canvas: ", with: ""), "the canvas is noised")
        XCTAssertEqual(pageLine("canvas2: ").replacingOccurrences(of: "canvas2: ", with: ""), noised.replacingOccurrences(of: "canvas: ", with: ""), "two reads give the same noise")
        XCTAssertEqual(pageLine("webgl: "), "webgl: none", "WebGL is off")
        XCTAssertNotEqual(pageLine("audio: "), realAudio, "the audio is noised")
        XCTAssertEqual(pageLine("lies: "), "lies: 0", "the natives check finds none of the replacements")
        shot("42 what the page reads")
        // A reload: the page counts its loads, so the check reads the new one, not the old.
        let before = pageNumber("load: ")
        app.buttons["reload"].tap()
        let reloaded = app.webViews.staticTexts.matching(NSPredicate(format: "label MATCHES %@ AND label != %@", "load: [0-9]+", before)).firstMatch
        XCTAssertTrue(reloaded.waitForExistence(timeout: 20), "the page was loaded again (it said \(before))")
        XCTAssertEqual(pageLine("canvas: "), noised, "the same noise after a reload")

        // A User-Agent of one's own.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        reveal(app.buttons["Своя"], "a custom string can be chosen").tap()
        let field = reveal(app.textFields["customUA"], "the custom string's field appears")
        field.tap()
        field.typeText("LumenTest/1.0")
        app.buttons["settingsDone"].tap()
        openPage("http://env.lumentest:28380/env?custom=1")
        XCTAssertEqual(pageLine("ua: "), "ua: LumenTest/1.0")

        // Quit and start again: everything as it was set, the same noise.
        relaunch()
        openSession("Профиль")
        openPage("http://env.lumentest:28380/env?relaunch=1")
        XCTAssertEqual(pageLine("ua: "), "ua: LumenTest/1.0", "the custom string survives a relaunch")
        XCTAssertEqual(pageLine("tz: "), "tz: Europe/Berlin")
        XCTAssertEqual(pageLine("canvas: "), noised, "the session's noise is the same after a relaunch")
        XCTAssertEqual(pageLine("webgl: "), "webgl: none")
        shot("43 after relaunch")
    }
}
