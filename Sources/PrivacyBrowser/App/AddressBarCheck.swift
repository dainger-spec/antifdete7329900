import AppKit
import BrowserCore
import Foundation

/// `Lumen --address-bar-check` (CI): typing into the address bar of Safari's window in a profile's
/// own process, one profile per search engine a profile can have, as a person types — one key
/// press at a time (`AddressBarTyping`).
///
/// A customer's address bar put up "This Safari feature is not available in a profile" at every
/// key, so that nothing could be typed, and the customer uninstalled the app (0.1.17 or earlier,
/// macOS 26, the profile's engine Google). It passes, for an engine, when the field holds what was
/// typed, no key press raised an exception, the run loop caught none while it typed, and the window
/// put up no notice. Every exception thrown meanwhile is printed with its frames, whether it passed
/// or not: what Safari's chrome threw, and where. `--engines google,bing` picks the engines.
/// scripts/address_bar_check.sh starts the proxy the profiles are held to and runs it.
@MainActor
enum AddressBarCheck {
    private static let tag = "ADDRESS-BAR"
    static let text = "google"

    private final class Seen {
        var hostsChrome: Bool?
        var exited: Int32?
        var look: WindowLook?
    }

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) {
            print("\(tag) FAIL the check did not finish in 15 minutes")
            exit(1)
        }
        var engines = [SearchEngine.google] + SearchEngine.allCases.filter { $0 != .google }
        if let index = arguments.firstIndex(of: "--engines"), index + 1 < arguments.count {
            let names = arguments[index + 1].split(separator: ",").map(String.init)
            engines = engines.filter { names.contains($0.rawValue.lowercased()) || names.contains($0.rawValue) }
        }
        let chosen = engines
        Task { @MainActor in exit(await run(chosen)) }
        application.run()
    }

    private static func run(_ engines: [SearchEngine]) async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("\(tag) FAIL the sandboxed build runs no process per profile")
            return 1
        }
        guard let port = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            print("\(tag) FAIL PB_SELFTEST_HTTP_PROXY_PORT is not set: scripts/selftest_proxy.py is the profiles' proxy")
            return 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-address-bar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "address-bar", iterations: 10_000))
        } catch {
            print("\(tag) FAIL could not make a vault: \(error)")
            return 1
        }
        print("\(tag) INFO macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version), "
              + "locale \(Locale.current.identifier)")
        var failed = 0
        for engine in engines {
            // Google, the default and the customer's engine, more ways: Cyrillic, an input method's
            // composing, and the same profile launched a second time (its home no longer new).
            let texts = engine == .google ? [text, "google.selftest", "гугл", AddressBarTyping.composedPrefix + "гугл"] : [text]
            let launches = engine == .google ? 2 : 1
            let problems = await check(engine, texts: texts, launches: launches, repository: repository, port: port)
            if problems.isEmpty {
                print("\(tag) PASS \(engine.name): \(texts.joined(separator: ", ")) typed into Safari's address bar "
                      + "(\(launches) launch(es)), with no exception and no notice")
            } else {
                failed += 1
                print("\(tag) FAIL \(engine.name): " + problems.joined(separator: "; "))
            }
        }
        return failed == 0 ? 0 : 1
    }

    private static func check(_ engine: SearchEngine, texts: [String], launches: Int,
                              repository: ProfileRepository, port: Int) async -> [String] {
        let profile: ProfileSummary
        do {
            profile = try repository.create(name: "Address bar \(engine.name)", configuration: ProfileConfiguration(
                // A page whose address and title hold what is typed: what Safari completes from (the
                // open tab, the page's history, its top hit), as a person's profile would have it.
                startURL: URL(string: "http://www.google.selftest.invalid/search?q=google"),
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port), ephemeral: false,
                matchProxyLocation: false, searchEngine: engine))
        } catch {
            return ["could not make a profile: \(error)"]
        }
        var problems: [String] = []
        for launch in 1...launches {
            let seen = Seen()
            let manager = ProfileManager(repository: repository)
            manager.onProfileRunning = { _, hosts in seen.hostsChrome = hosts }
            manager.onChildExited = { _, status in seen.exited = status }
            manager.onWindowLook = { _, look in seen.look = look }
            manager.onError = { message in print("\(tag) INFO the manager was told: \(message)") }
            do {
                try await manager.launch(profile.id)
            } catch {
                return problems + ["launch \(launch): the profile did not start: \(error)"]
            }
            await wait(90) { seen.hostsChrome != nil || seen.exited != nil }
            guard seen.hostsChrome == true else {
                return problems + ["launch \(launch): the profile's process does not host Safari's chrome ("
                    + (seen.hostsChrome == nil ? "no answer, exit \(seen.exited.map { "\($0)" } ?? "none")" : "this app's own window") + ")"]
            }
            // The window settles (its first page, its toolbar) before a person would type; a second tab
            // and another page that match what is typed, as a profile in use has them.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            for action in [WindowProbeAction.openTab("http://google.selftest.invalid/one?tab"),
                           .go("http://www.google.selftest.invalid/two?visited")] {
                seen.look = nil
                if manager.lookAtWindow(profile.id, action) { await wait(30) { seen.look != nil || seen.exited != nil } }
            }
            for typed in (launch == 1 ? texts : [text]) {
                seen.look = nil
                print("\(tag) INFO \(engine.name), launch \(launch): typing \(typed)")
                if !manager.lookAtWindow(profile.id, .typeInAddressBar(typed)) {
                    problems.append("launch \(launch), \(typed): the profile's process was not asked")
                    continue
                }
                await wait(60) { seen.look != nil || seen.exited != nil }
                problems += findings(seen.look, engine: engine).map { "launch \(launch), \(typed): \($0)" }
                if seen.exited != nil { break }
            }
            if let exited = seen.exited { problems.append("launch \(launch): the profile's process ended (status \(exited))") }
            if manager.isRunning(profile.id) { try? await manager.stop(profile.id) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return problems
    }

    private static func findings(_ look: WindowLook?, engine: SearchEngine) -> [String] {
        guard let look else { return ["no answer from the profile's window"] }
        guard look.found else { return ["no address bar found in the window (\(look.detail))"] }
        guard let report = try? JSONDecoder().decode(AddressBarTyping.Report.self, from: Data(look.detail.utf8)) else {
            return ["an answer that is not a report: \(look.detail.prefix(300))"]
        }
        print("\(tag) INFO \(engine.name): field \"\(report.field)\", window key \(report.windowWasKey), "
              + "exceptions out of key presses \(report.outOfKeyPresses), caught by the run loop \(report.caughtByRunLoop), "
              + "windows that came up \(report.windowsWhileTyping.joined(separator: " | ")), caught by the typing guard \(report.caughtByTypingGuard), thrown in all \(report.thrown.count), notices \(report.notices)")
        for line in report.providers.split(separator: "\n") { print("\(tag) INFO \(engine.name) providers: \(line.prefix(400))") }
        // Each distinct exception once, with its frames.
        var said: Set<String> = []
        for thrown in report.thrown where said.insert(thrown.name + thrown.reason).inserted {
            let times = report.thrown.filter { $0.name == thrown.name && $0.reason == thrown.reason }.count
            print("\(tag) THROWN \(engine.name) ×\(times): \(thrown.name): \(thrown.reason.prefix(600))")
            for frame in thrown.frames { print("\(tag) FRAME   \(frame.prefix(220))") }
        }
        var problems: [String] = []
        if report.field != report.typed { problems.append("the field holds \"\(report.field)\", not \"\(report.typed)\"") }
        if report.outOfKeyPresses > 0 { problems.append("\(report.outOfKeyPresses) key press(es) raised an exception") }
        if report.caughtByRunLoop > 0 { problems.append("the run loop caught \(report.caughtByRunLoop) exception(s) while it typed") }
        if report.notices > 0 { problems.append("the window put up \(report.notices) notice(s)") }
        return problems
    }

    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) async {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
