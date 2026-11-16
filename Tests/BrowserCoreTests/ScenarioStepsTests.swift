import XCTest
@testable import BrowserCore

/// A scenario's text as steps (docs/AUTOMATION.md, "Steps"): the cut is lossless, a known line is
/// read for its words, anything else is kept as it is, and every change moves whole lines.
final class ScenarioStepsTests: XCTestCase {
    private let recorded = """
    await page.goto('https://shop.example/login');
    await page.type('#email', 'alice@example.com');
    await page.type('input[name="password"]', params.password || ''); // not recorded
    await page.click('text=Sign in');
    await page.waitForLoadState();
    await page.click('[data-testid="orders"]');

    """

    func testThePiecesJoinedAreTheTextByteForByte() {
        var texts = ScenarioTemplate.all.map(\.script) + [recorded, "", "\n", "await page.goto('a')", "// only a comment", "a();\r\nb();\r\n"]
        texts += [
            "const s = 'a // not a comment { [ (';\nawait page.click(s);\n",
            "const t = `line one\n${ [1, 2].map((x) => `in ${x}`).join(', ') }\nline three`;\nlog(t);\n",
            "/* a block\n comment { */\nawait sleep(5);\n",
            "if (a) {\n  b();\n}\nelse {\n  c();\n}\nd();\n",
            "const r = await page\n  .title();\nlog(r);\n",
            "while (true) {\n",
            "log('it\\'s'); log(\"x\");\n",
        ]
        for text in texts {
            XCTAssertEqual(ScenarioSteps(text).source, text, "lossless: \(text.prefix(40))")
        }
    }

    func testARecordingIsReadAsItsSteps() {
        let steps = ScenarioSteps(recorded).steps
        XCTAssertEqual(steps.map(\.kind), [.open, .type, .type, .click, .waitLoad, .click])
        XCTAssertEqual(steps[2].arguments, [.text("input[name=\"password\"]"), .profile("password")], "the note at the line's end is not the command's")
        XCTAssertEqual(steps[0].arguments, [.text("https://shop.example/login")])
        XCTAssertEqual(steps[1].arguments, [.text("#email"), .text("alice@example.com")])
        XCTAssertEqual(steps[3].arguments, [.text("text=Sign in")])
        XCTAssertEqual(steps[5].lines, 6...6)
        // "Type over what was there" is one step.
        let over = ScenarioSteps("await page.click('#q'); await page.press('Meta+a'); await page.type('#q', 'new');\n").steps
        XCTAssertEqual(over.map(\.kind), [.type])
        XCTAssertEqual(over[0].arguments, [.text("#q"), .text("new")])
    }

    func testACommentAboveNamesTheStepAndSettingsAreNotSteps() {
        let source = ScenarioTemplate.template("signin")!.source { $0 }
        let cut = ScenarioSteps(source)
        XCTAssertTrue(cut.isCut)
        XCTAssertEqual(cut.steps.map(\.title), ["step.openSignIn", "step.typeLogin", "step.typePassword", "step.sendForm", "step.waitSignedIn", "step.result"])
        XCTAssertEqual(cut.steps.map(\.kind), [.open, .type, .type, .code, .code, .result])
        XCTAssertEqual(cut.steps[0].arguments, [.setting("LOGIN_URL")])
        XCTAssertEqual(cut.steps[1].arguments, [.setting("LOGIN_FIELD"), .profile("login")])
        XCTAssertEqual(cut.steps[5].arguments, [.text("result.signedIn")])
        // An error's "(line 17)" is the step that waits: its comment's line and its own.
        XCTAssertEqual(cut.steps[4].lines, 16...17)
        XCTAssertEqual(cut.step(atLine: 17)?.index, 4)
        XCTAssertNil(cut.step(atLine: 2), "a setting's line is no step's")
    }

    func testBlocksOfTheTwoShapesHaveStepsInside() {
        let feed = ScenarioSteps(ScenarioTemplate.template("feed")!.script).steps
        XCTAssertEqual(feed.map(\.kind), [.open, .repeatTimes, .result])
        XCTAssertEqual(feed[1].arguments, [.setting("SCREENS")])
        XCTAssertEqual(feed[1].children.map(\.kind), [.scroll, .pause])
        let banner = ScenarioSteps("if (await page.isVisible('#banner')) {\n  await page.click('text=Accept');\n}\n").steps
        XCTAssertEqual(banner.map(\.kind), [.ifVisible])
        XCTAssertEqual(banner[0].arguments, [.text("#banner")])
        XCTAssertEqual(banner[0].children.map(\.kind), [.click])
        XCTAssertEqual(banner[0].children[0].lines, 2...2)
        // Any other block is its own code, whole.
        let other = ScenarioSteps("for (const a of list) {\n  await page.goto(a);\n}\nlog('done');\n").steps
        XCTAssertEqual(other.map(\.kind), [.code, .log])
        XCTAssertEqual(other[0].lines, 1...3)
    }

    func testWhatIsNotACommandIsKeptAsCode() {
        for line in ["await page.click('#a', { clickCount: 2 });", "await page.click('#a'); await page.click('#b');", "const x = await page.title();",
                     "await page.type('#a', 'b', { delay: 50 });", "page.click('#a');"] {
            XCTAssertEqual(ScenarioSteps(line + "\n").steps.map(\.kind), [.code], line)
        }
        XCTAssertEqual(ScenarioSteps("await page.waitFor('h1', { timeout: 5000 });\n").steps.first?.arguments, [.text("h1"), .raw("5000")])
        XCTAssertEqual(ScenarioSteps("await page.scroll(600);\nawait sleep(1500);\nawait page.press('Enter');\n").steps.map(\.kind), [.scroll, .pause, .press])
    }

    func testATextThatCannotBeCutIsOneStepOfItsCode() {
        for text in ["while (true) {\n  await page.scroll(1);\n", "log(`open\n", "call(a,\n"] {
            let cut = ScenarioSteps(text)
            XCTAssertFalse(cut.isCut, text)
            XCTAssertEqual(cut.steps.count, 1)
            XCTAssertEqual(cut.source, text)
            XCTAssertEqual(cut.moving(0, to: 1).source, text, "nothing is moved in it")
            XCTAssertEqual(cut.removing(0).source, text)
        }
    }

    /// A text from outside nested thousands deep, or one long line, is read in a moment (the
    /// import's review read it on the main thread for minutes): blocks are read for their steps
    /// `maximumDepth` levels deep, one deeper is its own code, and other blocks are not cut again.
    func testADeepOrLongTextIsReadInAMoment() {
        let started = Date()
        // Blocks of the two shapes, 4,000 deep: 16 levels of steps, the 17th its own code.
        let levels = 4_000
        let deep = String(repeating: "for (let i = 0; i < 1; i++) {\n", count: levels) + "await sleep(1);\n" + String(repeating: "}\n", count: levels)
        let cut = ScenarioSteps(deep)
        XCTAssertTrue(cut.isCut)
        XCTAssertEqual(cut.source, deep, "lossless")
        var step = cut.steps.first
        var depth = 0
        while let current = step, current.kind == .repeatTimes {
            depth += 1
            step = current.children.first
        }
        XCTAssertEqual(depth, ScenarioSteps.maximumDepth)
        XCTAssertEqual(step?.kind, .code, "past the deepest level read, a block is its own code")
        XCTAssertEqual(step?.children.count, 0)
        // Any other block, 20,000 deep: one step of its own code.
        let braces = String(repeating: "{\n", count: 20_000) + String(repeating: "}\n", count: 20_000)
        XCTAssertEqual(ScenarioSteps(braces).steps.map(\.kind), [.code])
        // Steps switched off inside steps switched off, 200 deep: one step, off.
        let off = String(repeating: ScenarioSteps.offMark, count: 200) + "await sleep(1);\n"
        XCTAssertEqual(ScenarioSteps(off).steps.map(\.isOff), [true])
        XCTAssertEqual(ScenarioSteps(off).source, off)
        // A long line of the recorder's "type over" joints that is none of its commands: its own code.
        let joint = "); await page.press('Meta+a'); await page.type("
        let long = ScenarioSteps("await page.click(" + String(repeating: joint, count: 20_000) + "x) ;\n")
        XCTAssertTrue(long.isCut, "one statement, read for a command")
        XCTAssertEqual(long.steps.map(\.kind), [.code])
        XCTAssertEqual(ScenarioSteps("await page.click('#q'); await page.press('Meta+a'); await page.type('#q', 'new');\n").steps.map(\.kind), [.type],
                       "the recorder's own still is")
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "read in a moment, not for minutes")
    }

    func testMovingRemovingAndSwitchingOffLeaveEveryOtherStepAsItWas() {
        let source = "// first\nawait page.goto('https://a.example/');\n\n// second\nawait page.click('#b');\nawait page.press('Enter');\n"
        let cut = ScenarioSteps(source)
        XCTAssertEqual(cut.steps.count, 3)
        let moved = cut.moving(0, to: 3)
        XCTAssertEqual(moved.source, "\n// second\nawait page.click('#b');\nawait page.press('Enter');\n// first\nawait page.goto('https://a.example/');\n")
        XCTAssertEqual(moved.steps.map(\.title), ["second", nil, "first"])
        XCTAssertEqual(cut.moving(2, to: 0).steps.map(\.kind), [.press, .open, .click])
        XCTAssertEqual(cut.moving(1, to: 1).source, source, "a move to its own place is none")
        XCTAssertEqual(cut.moving(1, to: 2).source, source)
        XCTAssertEqual(cut.removing(1).source, "// first\nawait page.goto('https://a.example/');\n\nawait page.press('Enter');\n")
        // Off: its lines are comments with the mark, still one step, and on again it is as it was.
        let off = cut.toggling(1)
        XCTAssertEqual(off.source, "// first\nawait page.goto('https://a.example/');\n\n//- // second\n//- await page.click('#b');\nawait page.press('Enter');\n")
        XCTAssertEqual(off.steps.map(\.isOff), [false, true, false])
        XCTAssertEqual(off.steps[1].kind, .click)
        XCTAssertEqual(off.steps[1].title, "second")
        XCTAssertEqual(off.toggling(1).source, source)
        // A text without a newline at its end gets one when its last step moves.
        XCTAssertEqual(ScenarioSteps("a();\nb();").moving(1, to: 0).source, "b();\na();\n")
    }

    func testInsertingAndRewriting() {
        let cut = ScenarioSteps("// open\nawait page.goto('https://a.example/');\nawait page.click('#b');\n")
        XCTAssertEqual(cut.inserting("await sleep(1000);", after: 0).source, "// open\nawait page.goto('https://a.example/');\nawait sleep(1000);\nawait page.click('#b');\n")
        XCTAssertEqual(cut.inserting("await sleep(1000);", after: nil).steps.map(\.kind), [.open, .click, .pause])
        let line = ScenarioSteps.statement(.open, [.text("https://b.example/it's")])!
        XCTAssertEqual(line, "await page.goto('https://b.example/it\\'s');")
        let rewritten = cut.rewriting(0, statement: line)
        XCTAssertEqual(rewritten.source, "// open\nawait page.goto('https://b.example/it\\'s');\nawait page.click('#b');\n")
        XCTAssertEqual(rewritten.steps[0].arguments, [.text("https://b.example/it's")], "what is written is read back the same")
        XCTAssertEqual(ScenarioSteps.statement(.type, [.setting("FIELD"), .profile("login")]), "await page.type(FIELD, params.login || '');")
        XCTAssertEqual(ScenarioSteps.statement(.waitFor, [.text("h1"), .raw("30000")]), "await page.waitFor('h1', { timeout: 30000 });")
        XCTAssertNil(ScenarioSteps.statement(.code, []))
        // Each command's line is read back as that command.
        for kind in [ScenarioSteps.Kind.open, .click, .hover, .press, .waitURL, .scroll, .pause, .waitLoad] {
            let code = ScenarioSteps.statement(kind, kind == .scroll || kind == .pause ? [.raw("500")] : [.text("x")])!
            XCTAssertEqual(ScenarioSteps(code + "\n").steps.first?.kind, kind, code)
        }
    }

    // MARK: Settings

    func testTheSettingsAreTheConstLinesOfTheHead() {
        let source = "// A scenario\nconst PAGE_URL = 'https://a.example/'; // The address\nconst TIMES = 5; // How many\nconst DEEP = true;\nconst LIST = ['a', 'b\\'c'];\n\nawait page.goto(PAGE_URL);\nconst LATER = 1;\n"
        let settings = ScenarioSettings(source).settings
        XCTAssertEqual(settings.map(\.name), ["PAGE_URL", "TIMES", "DEEP", "LIST"], "only the head's: one after the first step is not a setting")
        XCTAssertEqual(settings.map(\.value), [.text("https://a.example/"), .number(5), .flag(true), .list(["a", "b'c"])])
        XCTAssertEqual(settings.map(\.label), ["The address", "How many", "", ""])
        XCTAssertEqual(settings.map(\.line), [2, 3, 4, 5])
        // A line that is not a plain value is no setting, and ends the head.
        XCTAssertEqual(ScenarioSettings("const A = 1;\nconst B = A + 1;\nconst C = 2;\n").settings.map(\.name), ["A"])
        XCTAssertEqual(ScenarioSettings("const lower = 1;\n").settings, [])
        // A `;` and a `//` inside a value are the value's.
        let tricky = ScenarioSettings("const NOTE = 'a; // b'; // What it says\nconst URL = 'https://a.example/';\n").settings
        XCTAssertEqual(tricky.map(\.value), [.text("a; // b"), .text("https://a.example/")])
        XCTAssertEqual(tricky.map(\.label), ["What it says", ""])
        let changed = ScenarioSettings.setting("TIMES", to: .number(12), in: source)
        XCTAssertEqual(changed, source.replacingOccurrences(of: "const TIMES = 5; // How many", with: "const TIMES = 12; // How many"))
        XCTAssertEqual(ScenarioSettings.setting("LIST", to: .list(["x"]), in: source), source.replacingOccurrences(of: "['a', 'b\\'c']", with: "['x']"))
        XCTAssertEqual(ScenarioSettings.setting("NONE", to: .number(1), in: source), source)
        // A text with a quote, a backslash and a newline is written so that it reads back the same.
        let odd = "it's a \\ path\nsecond"
        let written = ScenarioSettings.setting("PAGE_URL", to: .text(odd), in: source)
        XCTAssertEqual(ScenarioSettings(written).value(of: "PAGE_URL"), .text(odd))
        XCTAssertEqual(ScenarioSettings(written).settings.count, 4, "a newline in a value does not break the head")
    }

    // MARK: Templates

    func testEveryTemplateIsCutIntoNamedStepsAndItsFormReadsItsSettings() {
        XCTAssertEqual(ScenarioTemplate.all.count, 12)
        XCTAssertEqual(Set(ScenarioTemplate.all.map(\.id)).count, 12)
        for template in ScenarioTemplate.all {
            let source = template.source { "<\($0)>" }
            XCTAssertFalse(source.contains("{{"), "\(template.id): every word is put in")
            let cut = ScenarioSteps(source)
            XCTAssertTrue(cut.isCut, template.id)
            XCTAssertEqual(cut.source, source)
            XCTAssertFalse(cut.steps.isEmpty, template.id)
            for step in cut.steps { XCTAssertNotNil(step.title, "\(template.id): a step without a name: \(step.code)") }
            let settings = ScenarioSettings(source).settings
            XCTAssertEqual(settings.map(\.name), template.parameters.map(\.name), "\(template.id): the form's fields are the head's settings, in order")
            for setting in settings { XCTAssertFalse(setting.label.isEmpty, "\(template.id).\(setting.name) says what it is") }
            XCTAssertEqual(ScenarioValues.namesRead(by: source), template.takes, "\(template.id): the profile's values it reads")
            for parameter in template.parameters {
                switch (parameter.field, settings.first { $0.name == parameter.name }?.value) {
                case (.address, .text?), (.text, .text?), (.selector, .text?), (.number, .number?), (.lines, .list?), (.choice, .text?): break
                default: XCTFail("\(template.id).\(parameter.name): the field and the value are of different kinds")
                }
            }
        }
    }

    func testATemplatesWordsAndSettingsGoIntoItsText() {
        let template = ScenarioTemplate.template("signin")!
        let source = template.source(settings: ["LOGIN_URL": .text("https://shop.example/login"), "SIGNED_IN": .text("text=Мои заказы")]) { key in
            key == "result.signedIn" ? "it's in" : "Words of \(key)\nsecond line"
        }
        let settings = ScenarioSettings(source)
        XCTAssertEqual(settings.value(of: "LOGIN_URL"), .text("https://shop.example/login"))
        XCTAssertEqual(settings.value(of: "SIGNED_IN"), .text("text=Мои заказы"))
        XCTAssertEqual(settings.settings.first?.label, "Words of label.loginURL second line", "a word is one line")
        XCTAssertEqual(ScenarioSteps(source).steps.last?.arguments, [.text("it's in")], "a word inside a text stays inside it")
        XCTAssertTrue(template.words.contains("step.typeLogin"))
    }
}
