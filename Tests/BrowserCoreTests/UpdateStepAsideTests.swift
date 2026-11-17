import Foundation
import XCTest
@testable import BrowserCore

/// A Lumen opened during an install steps aside for a live installer and only for one
/// (`UpdateStepAside`), and every outcome of an install is said in the interface's words, never in
/// the installer's English (`UpdateOutcome.kind`, `noticeKey`): 0.1.18's tester reopened Lumen while
/// it was being updated and read "the app was started again before it could be replaced" in an
/// error alert on the lock screen.
final class UpdateStepAsideTests: XCTestCase {
    var root: URL!
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let app = "/Applications/Lumen.app"
    let build = BuildVersion("18")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-stepaside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(build: String) throws -> AppcastItem {
        let archive = root.appendingPathComponent("Lumen-\(build).zip")
        try Data(repeating: 7, count: 256).write(to: archive)
        return try UpdateSigner.item(archive: archive, version: "0.1.\(build)", build: build, minimumSystemVersion: "14.0",
                                     url: URL(string: "https://updates.example/Lumen-\(build).zip")!, notes: "",
                                     publishedAt: now, privateKey: UpdateSigner.newKey().privateKey)
    }

    private func request(build: String = "19", at: Date? = nil, path: String? = nil) throws -> UpdateRequest {
        UpdateRequest(appPath: path ?? app, archive: "Lumen-\(build).zip", item: try item(build: build), requestedAt: at ?? now.addingTimeInterval(-3))
    }

    private func marker(pid: Int32 = 4242, path: String? = nil, started: TimeInterval = -3, updated: TimeInterval = -1) -> UpdateInstallMarker {
        UpdateInstallMarker(pid: pid, appPath: path ?? app, version: "0.1.19", step: .checking,
                            startedAt: now.addingTimeInterval(started), updatedAt: now.addingTimeInterval(updated))
    }

    private func decide(_ marker: UpdateInstallMarker?, _ request: UpdateRequest?, alive: Set<Int32> = [4242],
                        build: BuildVersion? = nil) -> UpdateStepAside.Decision {
        UpdateStepAside.decide(marker: marker, request: request, appPath: app, build: build ?? self.build, now: now,
                               isAlive: { alive.contains($0) })
    }

    // MARK: Stepping aside

    func testAFreshMarkerOfALiveInstallerForThisAppStepsAside() throws {
        XCTAssertEqual(decide(marker(), try request()), .stepAside)
        XCTAssertEqual(decide(marker(), nil), .stepAside, "the request may already be used up")
        // The path as macOS may give it, not standardized.
        XCTAssertEqual(UpdateStepAside.decide(marker: marker(), request: nil, appPath: "/Applications/./Lumen.app", build: build,
                                              now: now, isAlive: { _ in true }), .stepAside)
    }

    func testADeadInstallerIsNoReasonToStepAside() throws {
        XCTAssertEqual(decide(marker(), try request(), alive: []), .start)
        XCTAssertEqual(decide(marker(pid: 0), nil, alive: [0]), .start)
        XCTAssertEqual(decide(marker(pid: -1), nil, alive: [-1]), .start)
    }

    func testAStaleMarkerIsNoReasonToStepAside() throws {
        // Not rewritten for longer than the heartbeat limit: its installer is gone (its pid reused).
        XCTAssertEqual(decide(marker(started: -150, updated: -(UpdateStepAside.heartbeatLimit + 1)), nil), .start)
        XCTAssertEqual(decide(marker(started: -150, updated: -(UpdateStepAside.heartbeatLimit - 1)), nil), .stepAside)
        // At it longer than `longest`: something holds it; the person gets Lumen.
        XCTAssertEqual(decide(marker(started: -(UpdateStepAside.longest + 1), updated: -1), nil), .start)
        // From the future (a clock set back): not believed.
        XCTAssertEqual(decide(marker(started: 60, updated: 60), nil), .start)
    }

    func testAnotherCopyOfTheAppIsNoReasonToStepAside() throws {
        XCTAssertEqual(decide(marker(path: "/Users/someone/Downloads/Lumen.app"), nil), .start)
        XCTAssertEqual(decide(nil, try request(path: "/Users/someone/Downloads/Lumen.app")), .start)
    }

    func testTheVersionBeingInstalledNeverStepsAside() throws {
        XCTAssertEqual(decide(marker(), try request(build: "19"), build: BuildVersion("19")!), .start)
        XCTAssertEqual(decide(marker(), try request(build: "19"), build: BuildVersion("20")!), .start)
    }

    func testARecentRequestWithoutAMarkerWaitsForItsInstaller() throws {
        XCTAssertEqual(decide(nil, try request(at: now.addingTimeInterval(-2))), .waitForInstaller)
        XCTAssertEqual(decide(nil, try request(at: now.addingTimeInterval(-(UpdateStepAside.requestWindow + 1)))), .start,
                       "a request left by an installer that never came")
        XCTAssertEqual(decide(nil, nil), .start)
        // A stale marker beside a recent request: the installer is gone, the app starts.
        XCTAssertEqual(decide(marker(), try request(), alive: []), .start)
    }

    func testThisProcessIsAliveAndANonexistentOneIsNot() {
        XCTAssertTrue(UpdateStepAside.isAlive(getpid()))
        XCTAssertFalse(UpdateStepAside.isAlive(0))
        XCTAssertFalse(UpdateStepAside.isAlive(Int32.max - 7))
    }

    // MARK: The files

    func testTheMarkerAndTheWishOnDisk() throws {
        XCTAssertNil(UpdateInstallMarker.read(from: root))
        let written = marker()
        try written.write(to: root)
        XCTAssertEqual(UpdateInstallMarker.read(from: root), written)
        UpdateInstallMarker.remove(from: root)
        XCTAssertNil(UpdateInstallMarker.read(from: root))

        XCTAssertNil(UpdateRelaunchWish.read(from: root))
        try UpdateRelaunchWish(at: now).write(to: root)
        XCTAssertEqual(UpdateRelaunchWish.read(from: root)?.at, now)
        UpdateRelaunchWish.remove(from: root)
        XCTAssertNil(UpdateRelaunchWish.read(from: root))

        // A request of a build before 0.1.19 has no texts, and still reads.
        let request = try request()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(request)) as? [String: Any])
        json["texts"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent(UpdateStaging.requestName))
        XCTAssertNil(try UpdateRequest.read(from: root).texts)
        var withTexts = request
        withTexts.texts = ["updates.progress.title": "Идёт установка обновления"]
        try withTexts.write(to: root)
        XCTAssertEqual(try UpdateRequest.read(from: root).texts?["updates.progress.title"], "Идёт установка обновления")
    }

    // MARK: Outcomes in the person's words

    /// The outcome 0.1.18's tester got, as 0.1.18's installer wrote it (no reason): a Lumen opened
    /// again — a notice, not an error, in the interface's words.
    func testAnOutcomeOfAnEarlierInstallerIsToldFromItsDetail() {
        func outcome(_ result: UpdateOutcome.Result, _ detail: String) -> UpdateOutcome {
            UpdateOutcome(result: result, detail: detail, fromBuild: "17", toBuild: "18", version: "0.1.18", at: now)
        }
        XCTAssertEqual(outcome(.gaveUp, "the app was started again before it could be replaced").kind, .startedAgain)
        XCTAssertEqual(outcome(.gaveUp, "2 process(es) still ran from the app after 600 s; none was stopped").kind, .stillRunning)
        XCTAssertEqual(outcome(.refused, "the request is from 2026-11-17 10:00:00 +0000, not from this quit").kind, .staleRequest)
        XCTAssertEqual(outcome(.refused, "the request is for /a.app, not /b.app").kind, .otherApp)
        XCTAssertEqual(outcome(.refused, "no request: The file couldn’t be opened.").kind, .noRequest)
        XCTAssertEqual(outcome(.refused, "the swap failed (errno 1); the installed app is untouched").kind, .swapFailed)
        XCTAssertEqual(outcome(.refused, "the installed app carries no update keys").kind, .untrustedApp)
        XCTAssertEqual(outcome(.refused, "the archive's app is 0.1 (1), the release says 0.2 (2)").kind, .badRelease)
        XCTAssertEqual(outcome(.refused, "something new").kind, .unknown)
        XCTAssertEqual(outcome(.rolledBack, "the new app did not start (x); the previous one is back").kind, .didNotStart)
        XCTAssertEqual(outcome(.installed, "build 18 is installed and was started").kind, .installed)
        XCTAssertEqual(outcome(.gaveUp, "the app was started again before it could be replaced").noticeKey, "updates.outcome.startedAgain")
        XCTAssertTrue(outcome(.gaveUp, "the app was started again before it could be replaced").archiveKept)
    }

    func testAnInstallersReasonWinsAndAnUnknownOneIsReadAsUnknown() throws {
        var outcome = UpdateOutcome(result: .refused, detail: "the request is for /a.app, not /b.app", fromBuild: "18", toBuild: "19",
                                    version: "0.1.19", at: now, reason: .badRelease)
        XCTAssertEqual(outcome.kind, .badRelease)
        outcome.reason = "somethingANewerInstallerSays"
        XCTAssertEqual(outcome.kind, .otherApp, "told from the detail")
        try outcome.write(to: root)
        XCTAssertEqual(UpdateOutcome.read(from: root), outcome, "a reason this build does not know does not make it unreadable")
    }

    /// Every outcome has its sentence in both languages, with the version's `%@`; the Russian ones
    /// hold no English (nothing but "Lumen" and "Mac" in Latin letters), and none says "error".
    func testEveryOutcomeIsSaidInBothLanguagesWithoutTheInstallersEnglish() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        func table(_ language: String) throws -> [String: String] {
            let text = try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
            var entries: [String: String] = [:]
            let pattern = try NSRegularExpression(pattern: #"^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";"#, options: .anchorsMatchLines)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
                entries[String(text[key])] = String(text[value])
            }
            return entries
        }
        let ru = try table("ru"), en = try table("en")
        for reason in UpdateOutcome.Reason.allCases {
            let key = "updates.outcome.\(reason.rawValue)"
            let russian = try XCTUnwrap(ru[key], "ru has \(key)")
            let english = try XCTUnwrap(en[key], "en has \(key)")
            XCTAssertTrue(russian.contains("%@") && english.contains("%@"), key)
            let latin = russian.replacingOccurrences(of: "%@", with: "")
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.unicodeScalars.contains { $0.isASCII } && !$0.isEmpty }
            XCTAssertTrue(Set(latin).isSubset(of: ["Lumen", "Mac", "macOS"]), "\(key): \(latin)")
            XCTAssertFalse(russian.localizedCaseInsensitiveContains("ошибка"), key)
            XCTAssertFalse(english.localizedCaseInsensitiveContains("error"), key)
        }
    }
}
