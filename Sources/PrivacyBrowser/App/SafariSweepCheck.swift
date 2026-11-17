import AppKit
import BrowserCore
import Foundation

/// `Lumen --sweep` (CI: .github/workflows/sweep.yml, scripts/sweep.py): a profile's Safari window
/// driven with real input events, from the manager's side (`SafariSweep` is the profile's).
///
/// A new profile in a temporary vault, launched as the app launches one (a process of its own,
/// Safari's window), on the sweep's page (`http://sweep.selftest.invalid/pb-sweep`), held to the
/// self-test proxy (`PB_SELFTEST_HTTP_PROXY_PORT`; `PB_SWEEP_PROXY=socks` and
/// `PB_SELFTEST_SOCKS_PROXY_PORT`: through its SOCKS5 side instead). `PB_SWEEP_LANGUAGE` gives the
/// profile a language (its window then speaks it), `PB_SWEEP_ENGINE` a search engine,
/// `PB_SWEEP_PHASES` the phases to run (comma-separated; none: all), `PB_SWEEP_PROFILES` how many
/// other profiles run beside it (each in its own process, brought in front and back between units).
///
/// One `SWEEP` line of JSON per unit as it ends — what it raised, what it would have told the person,
/// how long the main thread stopped, what it expected and did not see — and `SWEEP-HANG <pid>` as a
/// hang begins, for scripts/sweep.py to take the main thread's stack. A unit that ends the process
/// is a crash (or, for ⌘Q, the quit asked for): the profile is started again and the sweep goes on
/// from the next unit; one that says nothing for 75 seconds is killed. Exit 0 when the sweep got to
/// its end, 1 when it could not.
@MainActor
enum SafariSweepCheck {
    private final class Unit {
        var fields: [String: Any]
        let begin: Double
        init(fields: [String: Any], begin: Double) {
            self.fields = fields
            self.begin = begin
        }
    }

    private final class Sweep {
        var hostsChrome: Bool?
        var done = false
        var exited: Int32?
        var current: Unit?
        var units = 0
        var nextIndex = 0
        var nextSub = 0
    }

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A process of its own per profile, with Safari's window: what this check is about.
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3300) {
            print("SWEEP-ERROR the sweep did not finish in 55 minutes")
            exit(1)
        }
        Task { @MainActor in exit(await run()) }
        application.run()
    }

    private static func run() async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("SWEEP-ERROR the sandboxed build runs no process per profile")
            return 1
        }
        let environment = ProcessInfo.processInfo.environment
        guard let httpPort = environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            print("SWEEP-ERROR no PB_SELFTEST_HTTP_PROXY_PORT: the sweep's page comes from the self-test proxy")
            return 1
        }
        let socksPort = environment["PB_SELFTEST_SOCKS_PROXY_PORT"].flatMap(Int.init)
        let wantsSocks = environment["PB_SWEEP_PROXY"] == "socks"
        let proxy = wantsSocks && socksPort != nil
            ? ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort ?? 1)
            : ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
        let phases = (environment["PB_SWEEP_PHASES"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let language = environment["PB_SWEEP_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 }
        let engine = environment["PB_SWEEP_ENGINE"].flatMap { SearchEngine(rawValue: $0) }
        let others = min(4, max(0, environment["PB_SWEEP_PROFILES"].flatMap(Int.init) ?? 0))
        // What a person who keeps tabs has on: what ⌘Q left open comes back at the next start.
        BrowsingPreferences.current.restoreTabs = true

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        var extra: [ProfileSummary] = []
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "sweep", iterations: 10_000))
            profile = try repository.create(name: "Sweep", configuration: ProfileConfiguration(
                startURL: URL(string: "http://\(SafariSweep.host)\(SafariSweep.pagePath)"), proxy: proxy,
                matchProxyLocation: false, searchEngine: engine, languageOverride: language))
            for number in 0..<others {
                // The others alternate between the proxy's two sides.
                let otherProxy = number % 2 == 0 && socksPort != nil
                    ? ProxySettings(kind: .socks5, host: "127.0.0.1", port: socksPort ?? 1)
                    : ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: httpPort)
                extra.append(try repository.create(name: "Sweep \(number + 2)", configuration: ProfileConfiguration(
                    startURL: URL(string: "http://\(SafariSweep.host)\(SafariSweep.secondPath)"), proxy: otherProxy,
                    matchProxyLocation: false)))
            }
        } catch {
            print("SWEEP-ERROR could not make a profile: \(error)")
            return 1
        }
        print("SWEEP-INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version), "
              + "proxy \(wantsSocks && socksPort != nil ? "SOCKS5" : "HTTP"), language \(language ?? "this Mac's"), "
              + "engine \(engine?.rawValue ?? "default"), phases \(phases.isEmpty ? "all" : phases.joined(separator: ",")), "
              + "\(others) other profile(s)")

        let sweep = Sweep()
        let manager = ProfileManager(repository: repository)
        manager.onProfileRunning = { id, hosts in
            if id == profile.id { sweep.hostsChrome = hosts }
        }
        manager.onError = { message in print("SWEEP-INFO the manager was told: \(message)") }
        manager.onShowSettings = { sweep.current?.fields["manager"] = "asked for its Settings" }
        manager.onChildExited = { id, status in
            if id == profile.id {
                sweep.exited = status
            } else {
                print("SWEEP-INFO another profile's process ended (status \(status))")
            }
        }
        manager.onSweep = { id, line in
            guard id == profile.id else { return }
            handle(line, sweep: sweep, pid: manager.processIdentifier(of: profile.id))
        }

        for other in extra {
            do {
                try await manager.launch(other.id)
            } catch {
                print("SWEEP-INFO another profile did not start: \(error)")
            }
        }

        var launches = 0
        while !sweep.done, launches < 30 {
            launches += 1
            sweep.hostsChrome = nil
            sweep.exited = nil
            do {
                try await manager.launch(profile.id)
            } catch {
                print("SWEEP-ERROR the profile did not start: \(error)")
                break
            }
            let started = Date()
            while sweep.hostsChrome == nil, sweep.exited == nil, Date().timeIntervalSince(started) < 90 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard sweep.hostsChrome == true else {
                print("SWEEP-ERROR the profile's window is not Safari's (\(sweep.hostsChrome == nil ? "no answer" : "this app's own window"))")
                break
            }
            let pid = manager.processIdentifier(of: profile.id) ?? 0
            print("SWEEP-INFO launch \(launches): the profile's process is \(pid), from step \(sweep.nextIndex) unit \(sweep.nextSub)")
            // The others in front for a moment, as a person switching between profiles; then the
            // sweep's own takes the keyboard back as it starts.
            for other in extra where manager.isRunning(other.id) {
                // A launch of a running profile brings its window in front, as the list does.
                try? await manager.launch(other.id)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            manager.sweep(profile.id, from: sweep.nextIndex, sub: sweep.nextSub, phases: phases)
            while !sweep.done, sweep.exited == nil {
                if let current = sweep.current, Date().timeIntervalSince1970 - current.begin > 75, current.fields["killed"] == nil {
                    current.fields["killed"] = "no end in 75 s"
                    print("SWEEP-HANG \(pid) \(current.fields["index"] as? Int ?? -1) killed")
                    _ = kill(pid, SIGKILL)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if sweep.done { break }
            if let current = sweep.current {
                current.fields["exit"] = Int(sweep.exited ?? -1)
                current.fields["event"] = nil
                finish(current, sweep: sweep)
            } else {
                print("SWEEP-INFO the profile's process ended between units (status \(sweep.exited ?? -1)); starting it again")
            }
            // Its home is sealed as it ends: the next start opens it again.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        for id in [profile.id] + extra.map(\.id) where manager.isRunning(id) {
            try? await manager.stop(id)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print("SWEEP-INFO \(sweep.units) units in \(launches) launch(es); "
              + (sweep.done ? "the sweep got to its end" : "the sweep did NOT get to its end"))
        return sweep.done ? 0 : 1
    }

    private static func handle(_ line: String, sweep: Sweep, pid: Int32?) {
        guard let data = line.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = fields["event"] as? String else {
            print("SWEEP-INFO not a line of the sweep: \(line.prefix(300))")
            return
        }
        switch event {
        case "list":
            print("SWEEP-LIST " + line)
        case "units":
            print("SWEEP-UNITS " + line)
        case "begin":
            let unit = Unit(fields: fields, begin: fields["time"] as? Double ?? Date().timeIntervalSince1970)
            sweep.current = unit
            print("SWEEP-PROGRESS \(fields["index"] as? Int ?? -1).\(fields["sub"] as? Int ?? 0) \(fields["name"] as? String ?? "?")")
        case "end":
            guard let current = sweep.current else { return }
            for (key, value) in fields where key != "event" { current.fields[key] = value }
            finish(current, sweep: sweep)
        case "after":
            print("SWEEP-AFTER " + line)
        case "shot":
            print("SWEEP-SHOT \(fields["index"] as? Int ?? -1) \(fields["sub"] as? Int ?? 0)")
        case "hang":
            print("SWEEP-HANG \(pid ?? 0) \(fields["index"] as? Int ?? -1) \(fields["seconds"] as? Int ?? 0)")
        case "done":
            sweep.done = true
        default:
            print("SWEEP-INFO " + line)
        }
    }

    private static func finish(_ unit: Unit, sweep: Sweep) {
        sweep.current = nil
        sweep.units += 1
        let index = unit.fields["index"] as? Int ?? sweep.nextIndex
        let sub = unit.fields["sub"] as? Int ?? sweep.nextSub
        sweep.nextIndex = index
        sweep.nextSub = sub + 1
        unit.fields["begin"] = unit.begin
        guard JSONSerialization.isValidJSONObject(unit.fields),
              let data = try? JSONSerialization.data(withJSONObject: unit.fields, options: [.sortedKeys]) else {
            print("SWEEP-INFO a unit that is not JSON: \(index).\(sub)")
            return
        }
        print("SWEEP " + String(decoding: data, as: UTF8.self))
    }
}
