import AppKit
import BrowserCore
import Foundation

/// `Lumen --scenario-safari-check` (CI): a scenario's run in a profile's own process, where the
/// window is Safari's — from the manager's side, as the scenario editor's Run does it.
///
/// A new profile in a temporary vault, held to the self-test proxy (`PB_SELFTEST_HTTP_PROXY_PORT`,
/// which serves the page), is started without a window, as Run starts a stopped profile, and asked
/// to run a scenario on the automation form: go to it, click its button, type into its field, read
/// both back, and take what the page itself recorded of the click. It passes when the run finished
/// in a window of Safari's (its log's first line), the button counted one click, the field holds
/// what was typed, and the page saw a trusted click on the button inside the button's own box —
/// where a press lands when the viewport's place in Safari's web view is found right
/// (`PageDriver.measureViewport`; docs/PAGE_INPUT.md). Exit 0 then; 1, with what was found, when
/// not. scripts/scenario_safari_check.sh starts the proxy and runs it.
@MainActor
enum ScenarioSafariCheck {
    private static let tag = "SCENARIO-SAFARI"

    private final class Seen {
        var hostsChrome: Bool?
        var exited: Int32?
    }

    /// What the run does, and the line of its log this side reads.
    private static let script = """
        await page.goto(params.base + 'form');
        await page.waitFor('#late');
        await page.click('#button');
        await page.type('#field', 'Hello');
        const box = await page.evaluate(() => {
          const r = document.getElementById('button').getBoundingClientRect();
          return [r.left, r.top, r.right, r.bottom];
        });
        const taken = JSON.parse(await page.evaluate(() => window.__take(), null, {world: 'page'}));
        const click = taken.events.filter((e) => e.type === 'click')[0] || null;
        const result = {clicked: await page.textContent('#clicked'), value: await page.inputValue('#field'), box, click,
          inner: await page.evaluate(() => [innerWidth, innerHeight])};
        log('RESULT ' + JSON.stringify(result));
        """

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window: what this check is about.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            print("\(tag) FAIL the check did not finish in 5 minutes")
            exit(1)
        }
        Task { @MainActor in exit(await run()) }
        application.run()
    }

    private static func run() async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("\(tag) FAIL the sandboxed build runs no process per profile")
            return 1
        }
        guard let port = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            print("\(tag) FAIL PB_SELFTEST_HTTP_PROXY_PORT is not set: scripts/selftest_proxy.py serves the page")
            return 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-scenario-safari-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "scenario-safari", iterations: 10_000))
            profile = try repository.create(name: "Scenario in Safari", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port), matchProxyLocation: false))
        } catch {
            print("\(tag) FAIL could not make a profile: \(error)")
            return 1
        }
        print("\(tag) INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)")

        let seen = Seen()
        let manager = ProfileManager(repository: repository)
        manager.onProfileRunning = { _, hosts in seen.hostsChrome = hosts }
        manager.onChildExited = { _, status in seen.exited = status }
        manager.onError = { message in print("\(tag) INFO the manager was told: \(message)") }

        // As Run starts a stopped profile: with no window of its own.
        do {
            try await manager.launch(profile.id, openingWindow: false)
        } catch {
            print("\(tag) FAIL the profile did not start: \(error)")
            return 1
        }
        let started = Date()
        while seen.hostsChrome == nil, seen.exited == nil, Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        var problems: [String] = []
        if seen.hostsChrome != true {
            problems.append("the profile's process does not host Safari's chrome ("
                + (seen.hostsChrome == nil ? "no answer, exit \(seen.exited.map { "\($0)" } ?? "none")" : "this app's own window") + ")")
        } else if !manager.runScenario(profile.id, name: "Scenario in Safari", source: script,
                                       parametersJSON: "{\"base\": \"http://automation.selftest.invalid/pb-automation/\"}") {
            problems.append("the run was not started")
        } else {
            let began = Date()
            while manager.scenarioRuns[profile.id]?.isRunning == true, seen.exited == nil, Date().timeIntervalSince(began) < 150 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let run = manager.scenarioRuns[profile.id]
            let texts = run?.lines.map(\.text) ?? []
            for text in texts { print("\(tag) LOG \(text.prefix(700))") }
            problems += findings(outcome: run?.outcome, texts: texts)
            if let exited = seen.exited { problems.append("the profile's process ended during the run (status \(exited))") }
        }
        if manager.isRunning(profile.id) { try? await manager.stop(profile.id) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if problems.isEmpty {
            print("\(tag) PASS a scenario ran in a window of Safari's: its click landed on the button, trusted, and its typing is in the field")
            return 0
        }
        print("\(tag) FAIL " + problems.joined(separator: "; "))
        return 1
    }

    /// What the run's end and log say against what a run in Safari's window must leave.
    private static func findings(outcome: ScenarioRunner.Outcome?, texts: [String]) -> [String] {
        var problems: [String] = []
        if outcome != .finished { problems.append("the run ended \(outcome.map { String(describing: $0) } ?? "not at all")") }
        if texts.first != "window: Safari's" { problems.append("the run's window was \(texts.first ?? "not said")") }
        guard let line = texts.first(where: { $0.hasPrefix("RESULT ") }),
              let result = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8))) as? [String: Any] else {
            problems.append("the run's log has no result")
            return problems
        }
        let clicked = result["clicked"] as? String ?? "nothing"
        if clicked != "clicked 1" { problems.append("the button's count says \(clicked)") }
        let value = result["value"] as? String ?? "nothing"
        if value != "Hello" { problems.append("the field holds \(value)") }
        let box = (result["box"] as? [NSNumber])?.map(\.doubleValue) ?? []
        guard let click = result["click"] as? [String: Any], box.count == 4,
              let x = (click["clientX"] as? NSNumber)?.doubleValue, let y = (click["clientY"] as? NSNumber)?.doubleValue else {
            problems.append("the page recorded no click")
            return problems
        }
        if !(x >= box[0] && x <= box[2] && y >= box[1] && y <= box[3]) {
            problems.append("the click was at \(x), \(y), outside the button's box \(box)")
        }
        if click["trusted"] as? Bool != true { problems.append("the click was not a trusted event") }
        if click["target"] as? String != "button" { problems.append("the click's target was \(click["target"] ?? "none")") }
        return problems
    }
}
