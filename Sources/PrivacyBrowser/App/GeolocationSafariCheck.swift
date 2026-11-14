import AppKit
import BrowserCore
import Foundation

/// `Lumen --geolocation-safari-check` (CI): a profile with a fixed place, run in its own process
/// where the window is Safari's and the engine itself answers geolocation (`NativeGeolocation`).
///
/// A new profile in a temporary vault, held to the self-test proxy (`PB_SELFTEST_HTTP_PROXY_PORT`)
/// and set to a fixed place, is started without a window, as Run starts a stopped profile. A
/// scenario goes to a loopback page the proxy serves — a secure context — and, in the page's own
/// world, asks `navigator.geolocation` for the position and `navigator.permissions` for its state
/// before and after. In a profile's own process the page script leaves geolocation alone (mode
/// 'native'), so the place can only have come from the engine: it passes when the run finished in
/// a window of Safari's, the position is the profile's place with its accuracy, the permission is
/// 'prompt' before the page asks and 'granted' after, and getCurrentPosition prints as native code.
/// Exit 0 then; 1, with what was found, when not. scripts/geolocation_safari_check.sh runs it.
@MainActor
enum GeolocationSafariCheck {
    private static let tag = "GEOLOCATION-SAFARI"
    private static let latitude = 48.858_37
    private static let longitude = 2.294_481
    private static let accuracy = 35.0

    private final class Seen {
        var hostsChrome: Bool?
        var exited: Int32?
    }

    private static let script = """
        await page.goto(params.base);
        const report = await page.evaluate(async () => {
          const out = { secure: isSecureContext, has: !!navigator.geolocation };
          if (!out.has) return JSON.stringify(out);
          try {
            out.before = (await navigator.permissions.query({ name: 'geolocation' })).state;
            out.position = await new Promise((resolve) => navigator.geolocation.getCurrentPosition(
              (p) => resolve({ latitude: p.coords.latitude, longitude: p.coords.longitude, accuracy: p.coords.accuracy,
                               fresh: Math.abs(Date.now() - p.timestamp) < 60000 }),
              (e) => resolve({ error: e.code + ' ' + e.message }),
              { timeout: 15000 }));
            out.after = (await navigator.permissions.query({ name: 'geolocation' })).state;
            out.native = /\\[native code\\]/.test(Function.prototype.toString.call(navigator.geolocation.getCurrentPosition));
          } catch (e) { out.error = String((e && e.name) || e); }
          return JSON.stringify(out);
        }, null, {world: 'page'});
        log('RESULT ' + report);
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-geo-safari-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "geolocation-safari", iterations: 10_000))
            profile = try repository.create(name: "Geolocation in Safari", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port),
                geolocation: .fixed(latitude: latitude, longitude: longitude, accuracyMeters: accuracy),
                matchProxyLocation: false))
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
        } else {
            let base = "http://127.0.0.1:\(port)/pb-automation/form"
            if !manager.runScenario(profile.id, name: "Geolocation in Safari", source: script,
                                    parametersJSON: "{\"base\": \"\(base)\"}") {
                problems.append("the run was not started")
            } else {
                let began = Date()
                while manager.scenarioRuns[profile.id]?.isRunning == true, seen.exited == nil, Date().timeIntervalSince(began) < 150 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                let run = manager.scenarioRuns[profile.id]
                let texts = run?.lines.map(\.text) ?? []
                for text in texts { print("\(tag) LOG \(text.prefix(900))") }
                problems += findings(outcome: run?.outcome, texts: texts)
                if let exited = seen.exited { problems.append("the profile's process ended during the run (status \(exited))") }
            }
        }
        if manager.isRunning(profile.id) { try? await manager.stop(profile.id) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if problems.isEmpty {
            print("\(tag) PASS a page in a window of Safari's got the profile's place from the engine itself")
            return 0
        }
        print("\(tag) FAIL " + problems.joined(separator: "; "))
        return 1
    }

    private static func findings(outcome: ScenarioRunner.Outcome?, texts: [String]) -> [String] {
        var problems: [String] = []
        if outcome != .finished { problems.append("the run ended \(outcome.map { String(describing: $0) } ?? "not at all")") }
        if texts.first != "window: Safari's" { problems.append("the run's window was \(texts.first ?? "not said")") }
        guard let line = texts.first(where: { $0.hasPrefix("RESULT ") }),
              let result = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(7).utf8))) as? [String: Any] else {
            problems.append("the run's log has no result")
            return problems
        }
        if result["secure"] as? Bool != true { problems.append("the page was not a secure context") }
        guard result["has"] as? Bool == true else {
            problems.append("navigator.geolocation was not there")
            return problems
        }
        if let error = result["error"] as? String { problems.append("the page's script threw \(error)") }
        if result["before"] as? String != "prompt" { problems.append("the permission was \(result["before"] ?? "?") before the page asked, not prompt") }
        let position = result["position"] as? [String: Any] ?? [:]
        if let error = position["error"] as? String {
            problems.append("getCurrentPosition failed: \(error)")
        } else {
            let lat = (position["latitude"] as? NSNumber)?.doubleValue ?? .nan
            let lon = (position["longitude"] as? NSNumber)?.doubleValue ?? .nan
            let acc = (position["accuracy"] as? NSNumber)?.doubleValue ?? .nan
            if !(abs(lat - latitude) < 1e-6 && abs(lon - longitude) < 1e-6) {
                problems.append("the position was \(lat), \(lon), not the profile's \(latitude), \(longitude)")
            }
            if !(abs(acc - accuracy) < 0.01) { problems.append("the accuracy was \(acc), not \(accuracy)") }
            if position["fresh"] as? Bool != true { problems.append("the position's timestamp was not now") }
        }
        if result["after"] as? String != "granted" { problems.append("the permission was \(result["after"] ?? "?") after the page asked, not granted") }
        if result["native"] as? Bool != true { problems.append("getCurrentPosition did not print as native code") }
        return problems
    }
}
