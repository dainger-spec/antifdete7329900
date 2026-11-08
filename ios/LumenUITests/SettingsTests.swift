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
        go("\(site)/env")
        let ua = pageLine("ua: ")
        XCTAssertTrue(ua.contains("Version/") && ua.hasSuffix("Safari/604.1"), "a new session reads as Safari: \(ua)")
        let realCanvas = pageLine("canvas: ")
        let realAudio = pageLine("audio: ")
        XCTAssertFalse(pageLine("webgl: ").contains("none"), "WebGL is there by default")
        XCTAssertEqual(pageLine("lies: "), "lies: 0", "nothing replaced, nothing found")

        // Through the Berlin proxy: Berlin's time zone and German, from the proxy's check.
        chooseProxy("Берлин")
        go("http://env.lumentest:28380/env")
        XCTAssertEqual(pageLine("tz: "), "tz: Europe/Berlin", "the time zone of the proxy's country")
        XCTAssertEqual(pageLine("lang: "), "lang: de-DE", "the language of the proxy's country")
        shot("40 Berlin's time zone and language")

        // iOS 26's Safari, canvas noise, WebGL off, audio noise.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["iOS 26 — Safari 26"], "the presets are listed").tap()
        app.segmentedControls["canvasMode"].buttons["Шум"].tap()
        app.segmentedControls["webglMode"].buttons["Выкл"].tap()
        app.segmentedControls["audioMode"].buttons["Шум"].tap()
        shot("41 settings")
        app.buttons["settingsDone"].tap()
        go("http://env.lumentest:28380/env?changed=1")
        XCTAssertTrue(pageLine("ua: ").contains("Version/26.0"), "the page reads iOS 26's Safari: \(pageLine("ua: "))")
        page("server ua: Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0")
        let noised = pageLine("canvas: ")
        XCTAssertNotEqual(noised.replacingOccurrences(of: "canvas: ", with: ""), realCanvas.replacingOccurrences(of: "canvas: ", with: ""), "the canvas is noised")
        XCTAssertEqual(pageLine("canvas2: ").replacingOccurrences(of: "canvas2: ", with: ""), noised.replacingOccurrences(of: "canvas: ", with: ""), "two reads give the same noise")
        XCTAssertEqual(pageLine("webgl: "), "webgl: none", "WebGL is off")
        XCTAssertNotEqual(pageLine("audio: "), realAudio, "the audio is noised")
        XCTAssertEqual(pageLine("lies: "), "lies: 0", "the natives check finds none of the replacements")
        shot("42 what the page reads")
        app.buttons["reload"].tap()
        sleep(1)
        XCTAssertEqual(pageLine("canvas: "), noised, "the same noise after a reload")

        // A User-Agent of one's own.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["Своя"], "a custom string can be chosen").tap()
        let field = wait(app.textFields["customUA"], "the custom string's field appears")
        field.tap()
        field.typeText("LumenTest/1.0")
        app.buttons["settingsDone"].tap()
        go("http://env.lumentest:28380/env?custom=1")
        XCTAssertEqual(pageLine("ua: "), "ua: LumenTest/1.0")

        // Quit and start again: everything as it was set, the same noise.
        relaunch()
        openSession("Профиль")
        go("http://env.lumentest:28380/env?relaunch=1")
        XCTAssertEqual(pageLine("ua: "), "ua: LumenTest/1.0", "the custom string survives a relaunch")
        XCTAssertEqual(pageLine("tz: "), "tz: Europe/Berlin")
        XCTAssertEqual(pageLine("canvas: "), noised, "the session's noise is the same after a relaunch")
        XCTAssertEqual(pageLine("webgl: "), "webgl: none")
        shot("43 after relaunch")
    }
}
