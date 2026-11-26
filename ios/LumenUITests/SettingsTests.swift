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
        leaveProxies()
        createSession(name: "Профиль")
        openSession("Профиль")

        // As it comes: Safari's User-Agent (the device profile is full by default:
        // testANewSessionHasTheFullProfile). The device's own canvas and audio, for what follows, are
        // read with the simplified profile — nothing replaced.
        openPage("\(site)/env?first=1")
        let ua = pageLine("ua: ")
        XCTAssertTrue(ua.contains("Version/") && ua.hasSuffix("Safari/604.1"), "a new session reads as Safari: \(ua)")
        chooseProfile("Упрощённый", in: "Профиль")
        openPage("\(site)/env?simplified=1")
        let realCanvas = pageLine("canvas: ")
        let realAudio = pageLine("audio: ")
        XCTAssertEqual(pageLine("png: "), "png: 0", "the canvas's PNG drawn back reads as getImageData (nothing replaced)")
        XCTAssertEqual(pageLine("pngbytes: "), "pngbytes: 0", "the canvas's PNG holds what getImageData reads (nothing replaced)")
        XCTAssertFalse(pageLine("webgl: ").contains("none"), "WebGL is there by default")
        // As Safari on an iPhone (iOS 27.2) and on the Mac: WebKit's own window.browser.
        XCTAssertEqual(pageLine("browser: "), "browser: [object WebPageNamespace] runtime [object WebPageRuntime] connect,sendMessage own,true,true,true,object",
                       "window.browser is WebKit's own, as in Safari")
        XCTAssertEqual(pageLine("lies: "), "lies: 0", "the natives check finds nothing (nothing replaced)")

        // Through the Berlin proxy: Berlin's time zone and German, from the proxy's check.
        chooseProxy("Берлин", in: "Профиль")
        openPage("http://env.lumentest:28380/env?proxy=berlin")
        XCTAssertEqual(pageLine("tz: "), "tz: Europe/Berlin", "the time zone of the proxy's country")
        XCTAssertEqual(pageLine("lang: "), "lang: de-DE", "the language of the proxy's country")
        shot("40 Berlin's time zone and language")

        // iOS 26's Safari, canvas noise, WebGL off, audio noise.
        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        pickFromMenu("userAgentPicker", "iOS 26 — Safari 26")
        reveal(app.buttons["profile-custom"], "the device profile can be one's own").tap()
        pickFromMenu("canvasMode", "Шум")
        pickFromMenu("webglMode", "Выкл")
        pickFromMenu("audioMode", "Шум")
        shot("41 settings")
        app.buttons["settingsDone"].tap()
        openPage("http://env.lumentest:28380/env?changed=1")
        XCTAssertTrue(pageLine("ua: ").contains("Version/26.0"), "the page reads iOS 26's Safari: \(pageLine("ua: "))")
        page("server ua: Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0")
        let noised = pageLine("canvas: ")
        XCTAssertNotEqual(noised.replacingOccurrences(of: "canvas: ", with: ""), realCanvas.replacingOccurrences(of: "canvas: ", with: ""), "the canvas is noised")
        XCTAssertEqual(pageLine("canvas2: ").replacingOccurrences(of: "canvas2: ", with: ""), noised.replacingOccurrences(of: "canvas: ", with: ""), "two reads give the same noise")
        // The noise is one the canvas can hold: its PNG reads back as getImageData, as a native one does
        // (the owner's iPhone, 8 November: 18 bytes apart with a noise that flipped a colour's low bit).
        XCTAssertEqual(pageLine("png: "), "png: 0", "the noised canvas's PNG drawn back reads as getImageData")
        XCTAssertEqual(pageLine("pngbytes: "), "pngbytes: 0", "the noised canvas's PNG holds what getImageData reads")
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
        pickFromMenu("userAgentPicker", "Своя")
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

    /// The owner (8 November): a new session's device profile is full — canvas and audio its own,
    /// none of it seen by the natives check —, and "Упрощённый" gives the device's back.
    func testANewSessionHasTheFullProfile() {
        launch(reset: true)
        createSession(name: "Новый")
        openSession("Новый")
        openPage("\(site)/env?profile=default")
        let canvas = pageLine("canvas: ")
        let audio = pageLine("audio: ")
        XCTAssertEqual(pageLine("lies: "), "lies: 0", "the natives check finds none of the full profile's replacements")
        chooseProfile("Упрощённый", in: "Новый")
        openPage("\(site)/env?profile=simplified")
        XCTAssertNotEqual(canvas, pageLine("canvas: "), "a new session's device profile is full by default: its canvas is its own")
        XCTAssertNotEqual(audio, pageLine("audio: "), "a new session's device profile is full by default: its audio is its own")
        shot("47 the full profile, then the simplified one")
    }

    /// Canvas noise with the device's own time zone: a worker made from a blob must read the page's
    /// canvas. Until the mac app's fix of 8 November (claude/redesign 7fac7fd) PrivacyScripts'
    /// patchWindow hooked blob workers only with a replaced time zone, so here the worker read the real
    /// canvas beside a noised page. The red runs that old condition (workerHookTimeZoneOnly).
    func testBlobWorkerReadsThePageCanvasWithTheDevicesTimeZone() {
        launch(reset: true)
        createSession(name: "Воркер")
        openSession("Воркер")
        // The control: the simplified profile, nothing replaced — the worker reads what the page reads,
        // the comparison works.
        chooseProfile("Упрощённый", in: "Воркер")
        openPage("\(site)/env?worker=real")
        let real = pageLine("canvas: ")
        XCTAssertTrue(pageLine("worker: ").hasPrefix("worker: same"), "with nothing replaced a blob worker reads the page's canvas: \(pageLine("worker: "))")

        app.buttons["settingsButton"].tap()
        wait(app.buttons["settingsDone"], "the settings open")
        reveal(app.buttons["profile-custom"], "the device profile can be one's own").tap()
        pickFromMenu("canvasMode", "Шум")
        app.buttons["settingsDone"].tap()
        openPage("\(site)/env?worker=noise")
        XCTAssertNotEqual(pageLine("canvas: "), real, "the page's canvas is noised")
        let worker = pageLine("worker: ")
        shot("44 a blob worker, canvas noise, the device's time zone")
        XCTAssertTrue(worker.hasPrefix("worker: same"),
                      "canvas noise with the device's own time zone: a blob worker reads the page's canvas (\(worker))")
    }
}
