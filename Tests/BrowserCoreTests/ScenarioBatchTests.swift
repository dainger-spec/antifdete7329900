import XCTest
@testable import BrowserCore

/// A scenario run on many profiles (docs/AUTOMATION.md, "On many profiles"): the queue and its
/// limit, how each profile ended, the runs kept in the vault, and a scenario as a file.
final class ScenarioBatchTests: XCTestCase {
    var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let profiles = (0..<5).map { _ in UUID() }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-runs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func batch(limit: Int = 2) -> ScenarioBatch {
        ScenarioBatch(scenarioID: UUID(), scenarioName: "Sign in", entries: profiles.enumerated().map { ScenarioBatch.Entry(profileID: $1, name: "P\($0)") },
                      startedAt: t0, limit: limit)
    }

    func testSoManyAtOnceAndTheNextWhenOneEnds() {
        var run = batch()
        XCTAssertEqual(run.next(), [profiles[0], profiles[1]])
        run.began(profiles[0], at: t0)
        run.began(profiles[1], at: t0, startedProfile: true)
        XCTAssertEqual(run.next(), [], "the limit is taken")
        XCTAssertEqual(run.working, 2)
        run.ended(profiles[0], .finished, at: t0.addingTimeInterval(38), result: "\"in\"")
        XCTAssertEqual(run.entries[0].duration, 38)
        XCTAssertEqual(run.entries[0].result, "\"in\"")
        XCTAssertEqual(run.entries[1].startedProfile, true)
        XCTAssertEqual(run.next(), [profiles[2]])
        run.ended(profiles[0], .failed(reason: "late", line: nil), at: t0, result: nil)
        XCTAssertEqual(run.entries[0].state, .finished, "an end is told once")
        run.ended(profiles[1], .running(since: t0))
        XCTAssertEqual(run.working, 1, "what is not an end ends nothing")
        XCTAssertEqual(ScenarioBatch(scenarioID: UUID(), scenarioName: "", entries: [], limit: 99).limit, 10)
        XCTAssertEqual(ScenarioBatch(scenarioID: UUID(), scenarioName: "", entries: [], limit: 0).limit, 1)
    }

    func testTheRunEndsWithItsLastProfileAndCountsHowEachEnded() {
        var run = batch(limit: 5)
        profiles.forEach { run.began($0, at: t0) }
        run.ended(profiles[0], .finished, at: t0.addingTimeInterval(10))
        run.ended(profiles[1], .failed(reason: "no element matches #a (line 4)", line: 4), at: t0.addingTimeInterval(11), log: (0..<400).map { "line \($0)" })
        run.ended(profiles[2], .stopped, at: t0.addingTimeInterval(12))
        run.ended(profiles[3], .skipped(reason: "password"), at: t0.addingTimeInterval(13))
        XCTAssertTrue(run.isRunning)
        run.ended(profiles[4], .finished, at: t0.addingTimeInterval(20))
        XCTAssertEqual(run.endedAt, t0.addingTimeInterval(20))
        XCTAssertEqual([run.finished, run.failed, run.stopped, run.skipped, run.ended], [2, 1, 1, 1, 5])
        XCTAssertEqual(run.unsuccessful, [profiles[1], profiles[2]], "what \"run the failed again\" takes: not the skipped")
        XCTAssertEqual(run.entries[1].log?.count, ScenarioBatch.keptLogLines)
        XCTAssertEqual(run.entries[1].log?.last, "line 399", "the last lines are what is kept")
        XCTAssertNil(run.entries[0].log, "a run that went well keeps no log")
        XCTAssertEqual(run.next(), [])
    }

    func testStopEndsThoseWaitingAtOnceAndStartsNoMore() {
        var run = batch()
        run.began(profiles[0], at: t0)
        run.stop(at: t0.addingTimeInterval(5))
        XCTAssertEqual(run.next(), [])
        XCTAssertEqual(run.stopped, 4)
        XCTAssertTrue(run.isRunning, "until the one at work has been stopped")
        run.ended(profiles[0], .stopped, at: t0.addingTimeInterval(6))
        XCTAssertEqual(run.endedAt, t0.addingTimeInterval(6))
    }

    func testTheTableAsTextAndAsCSV() {
        var run = batch(limit: 5)
        run.entries[0].name = "Shop \"DE\", 01"
        run.began(profiles[0], at: t0)
        run.ended(profiles[0], .finished, at: t0.addingTimeInterval(41.6), result: "{\"a\":\t1}\nx")
        let words: (ScenarioBatch.State) -> String = { $0 == .finished ? "Done" : "Waiting" }
        let table = run.table(header: ["Profile", "State", "Seconds", "Result"], words: words)
        XCTAssertEqual(table.split(separator: "\n").count, 6)
        XCTAssertTrue(table.hasPrefix("Profile\tState\tSeconds\tResult\nShop \"DE\", 01\tDone\t42\t{\"a\": 1} x\n"), "a tab or a newline in a cell does not make a column or a row")
        let csv = run.csv(header: ["Profile", "State", "Seconds", "Result"], words: words)
        XCTAssertTrue(csv.hasPrefix("\"Profile\",\"State\",\"Seconds\",\"Result\"\r\n\"Shop \"\"DE\"\", 01\",\"Done\",\"42\","))
    }

    func testTheRunsAreKeptSealedNewestFirstAndBounded() throws {
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertEqual(try ScenarioRunHistory.load(from: vault), ScenarioRunHistory())
        var history = ScenarioRunHistory()
        var first = batch()
        history.put(first)
        history.put(batch())
        XCTAssertEqual(history.runs.count, 2)
        XCTAssertEqual(history.runs[1].id, first.id, "the newest is first")
        first.began(profiles[0], at: t0)
        history.put(first)
        XCTAssertEqual(history.runs.count, 2, "the same run is put in its own place")
        XCTAssertEqual(history.runs[1].working, 1)
        XCTAssertEqual(history.last(of: first.scenarioID)?.id, first.id)
        try history.save(to: vault)
        XCTAssertEqual(try ScenarioRunHistory.load(from: vault), history)
        let raw = try Data(contentsOf: root.appendingPathComponent("scenario-runs.bin"))
        XCTAssertNil(raw.range(of: Data("Sign in".utf8)), "a run's scenario is in the clear")
        // The app quit while a run was going: found again, it is one that was stopped.
        history.closeUnfinished(at: t0.addingTimeInterval(60))
        XCTAssertTrue(history.runs.allSatisfy { !$0.isRunning })
        XCTAssertEqual(history.runs[1].stopped, 5)
        for _ in 0..<150 { history.put(batch()) }
        XCTAssertEqual(history.runs.count, ScenarioRunHistory.kept)
    }

    func testAScenarioAsAFileHasItsTextAndNothingOfAProfile() throws {
        let scenario = Scenario(name: "Sign in", source: "await page.goto('https://Shop.example/login');\nawait page.goto('http://b.example/x');\nlog('https://shop.example/again');\n",
                                folder: "Shops", note: "for the shop")
        let data = try ScenarioFile(scenario).data()
        guard case .success(let file) = ScenarioFile.read(data) else { return XCTFail("a file just written is read") }
        XCTAssertEqual([file.name, file.note ?? "", file.source], [scenario.name, "for the shop", scenario.source])
        XCTAssertEqual(file.hosts, ["shop.example", "b.example"])
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "Shops"), "the folder is this Mac's")
        XCTAssertEqual(ScenarioFile.read(Data("{\"kind\":\"other\",\"format\":1,\"name\":\"x\",\"source\":\"\"}".utf8)), .failure(.notAScenario))
        XCTAssertEqual(ScenarioFile.read(Data("not json".utf8)), .failure(.notAScenario))
        XCTAssertEqual(ScenarioFile.read(Data("{\"kind\":\"lumen.scenario\",\"format\":2,\"name\":\"x\",\"source\":\"\"}".utf8)), .failure(.newer))
        XCTAssertEqual(ScenarioFile.read(Data(count: ScenarioFile.maximumBytes + 1)), .failure(.tooLarge))
    }

    /// The review's sites: those written out — the host, not a name before `@`, in any case — and
    /// whether the code may open addresses it builds, said beside them.
    func testTheReviewSaysWhenTheCodeBuildsAddresses() {
        XCTAssertEqual(ScenarioFile.hosts(in: "goto('HTTPS://Social.Example@evil.example/x'); goto('http://a.example:8080/')"), ["evil.example", "a.example"])
        let written = [
            "await page.goto('https://shop.example/login');\nawait page.type('#u', params.login || '');\n",
            "await page.goto(\"https://shop.example/\", { waitUntil: 'load' });\n",
            "const PAGE_URL = 'https://shop.example/'; // where\n\nif (PAGE_URL) { await page.goto(PAGE_URL); }\n",
            "// page, goto, evaluate and eval in a comment are not code\nawait page.goto('https://shop.example/');\n",
            "await page.click('text=Next page'); await page.click('.page-header');\n",
            "",
        ]
        for text in written { XCTAssertFalse(ScenarioFile.buildsAddresses(text), text) }
        let built = [
            "const report = ['ht', 'tps:/', '/stats.', 'example'].join('') + '/r';\nawait page.goto(report);\n",
            "await page.goto('https://social.example/');\nawait page.evaluate((a) => fetch('htt' + 'ps://c.example.net/x'), 1, {world: 'page'});\n",
            "await page.goto('ht\\x74ps://evil.example/');\n",
            "await page.goto(`https://${host}/`);\n",
            "const PAGE_URL = 'ht\\x74ps://evil.example/'; // where\n\nawait page.goto(PAGE_URL);\n",
            "const PAGE_URL = 'https://shop.example/'; // where\n\n{ const PAGE_URL = 'ht' + 'tps://evil.example'; await page.goto(PAGE_URL); }\n",
            "const go = page.goto; await go('https://x.example');\n",
            "await page['go' + 'to']('https://x.example');\n",
            "await __command('goto', ['https://x.example']);\n",
            "with (o) { await page.goto(PAGE_URL); }\n",
        ]
        for text in built { XCTAssertTrue(ScenarioFile.buildsAddresses(text), text) }
        // The templates that open a setting's address say nothing more; those that build one, or run code in the page, say so.
        let building: Set<String> = ["search", "pages", "list", "screens"]
        for template in ScenarioTemplate.all {
            let source = template.source(settings: ["PAGE_URL": .text("https://shop.example/"), "LOGIN_URL": .text("https://shop.example/login")]) { "<\($0)>" }
            XCTAssertEqual(ScenarioFile.buildsAddresses(source), building.contains(template.id), template.id)
        }
    }

    func testAnOlderLibraryReadsAndACopyHasAFreeName() throws {
        let old = "{\"format\":1,\"scenarios\":[{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"source\":\"log(1);\",\"createdAt\":0,\"updatedAt\":0}]}"
        var library = try JSONDecoder().decode(ScenarioLibrary.self, from: Data(old.utf8))
        XCTAssertNil(library.scenarios[0].folder)
        library.scenarios[0].folder = "B"
        let copy = library.copy(of: library.scenarios[0], at: t0)
        XCTAssertEqual([copy.name, copy.source, copy.folder ?? ""], ["Old 2", "log(1);", "B"])
        XCTAssertNotEqual(copy.id, library.scenarios[0].id)
        library.put(copy, at: t0)
        library.put(Scenario(name: "Other", source: "", folder: "A"), at: t0)
        XCTAssertEqual(library.folders, ["A", "B"])
    }
}
