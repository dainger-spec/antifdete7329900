import AppKit
import BrowserCore
import Foundation

/// `Lumen --address-bar-check` (CI): typing into the address bar of Safari's window in a profile's
/// own process, one profile per search engine a profile can have, as a person types — one key
/// press at a time (`AddressBarTyping`) — and pressing Return.
///
/// A customer's address bar put up "This Safari feature is not available in a profile" at every
/// key, so that nothing could be typed, and the customer uninstalled the app (0.1.17 or earlier,
/// macOS 26, the profile's engine Google). Another, on macOS 27.2.1, typed "google" and pressed
/// Return: the field showed the committed search, the page stayed empty, and the same notice came
/// up. It passes, for an engine, when the field holds what was typed, no key press raised an
/// exception, the run loop caught none while it typed, the window put up no notice — and a real
/// Return (key-down and key-up sent to the window) started the search with the profile's engine,
/// as the self-test proxy sees it, with nothing thrown on the way. Google's profile also goes to a
/// typed address ("example.com") and to the completion list's first row (Down arrow, Return).
/// Every exception thrown meanwhile is printed with its frames, whether it passed or not: what
/// Safari's chrome threw, and where.
///
/// And Safari's stores in each profile's home, before the typing and after (`SafariStores`): which
/// of a complete per-profile Safari data tree (`SafariStoreLayout.stores`) exist and open, what the
/// profile's launch made sure of, and where Safari's path getters pointed.
///
/// `--engines google,bing` picks the engines; `--quick` types "google" once, in one launch.
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

    /// What every profile's stores were after its run, by store, for the summary.
    private static var storesSeen: [String: [SafariStoreLayout.Assessment]] = [:]

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) {
            print("\(tag) FAIL the check did not finish in 25 minutes")
            exit(1)
        }
        var engines = [SearchEngine.google] + SearchEngine.allCases.filter { $0 != .google }
        if let index = arguments.firstIndex(of: "--engines"), index + 1 < arguments.count {
            let names = arguments[index + 1].split(separator: ",").map(String.init)
            engines = engines.filter { names.contains($0.rawValue.lowercased()) || names.contains($0.rawValue) }
        }
        let chosen = engines
        let quick = arguments.contains("--quick")
        Task { @MainActor in exit(await run(chosen, quick: quick)) }
        application.run()
    }

    private static func run(_ engines: [SearchEngine], quick: Bool) async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("\(tag) FAIL the sandboxed build runs no process per profile")
            return 1
        }
        guard let port = ProcessInfo.processInfo.environment["PB_SELFTEST_HTTP_PROXY_PORT"].flatMap(Int.init) else {
            print("\(tag) FAIL PB_SELFTEST_HTTP_PROXY_PORT is not set: scripts/selftest_proxy.py is the profiles' proxy")
            return 1
        }
        // The vault where a person's is, in the account's ~/Library/Application Support: a profile's
        // home is then under ~/Library as on a user's Mac (`SafariPaths.moved`, the sandbox's rules on
        // the vault). Until 17 November this check's vault was in a temporary folder.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("pb-address-bar-\(UUID().uuidString)", isDirectory: true)
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
              + "locale \(Locale.current.identifier), the vault in ~/Library/Application Support")
        var failed = 0
        for engine in engines {
            // Google, the default and the customers' engine, more ways: Cyrillic, an input method's
            // composing, and the same profile launched a second time (its home no longer new).
            let full = engine == .google && !quick
            let texts = full ? [text, "google.selftest", "гугл", AddressBarTyping.composedPrefix + "гугл"] : [text]
            let launches = full ? 2 : 1
            let problems = await check(engine, texts: texts, launches: launches, full: full, repository: repository, port: port)
            if problems.isEmpty {
                print("\(tag) PASS \(engine.name): \(texts.joined(separator: ", ")) typed into Safari's address bar and Return pressed "
                      + "(\(launches) launch(es)): the search went to \(engine.name), with no exception and no notice")
            } else {
                failed += 1
                print("\(tag) FAIL \(engine.name): " + problems.joined(separator: "; "))
            }
        }
        summarizeStores()
        return failed == 0 ? 0 : 1
    }

    private static func check(_ engine: SearchEngine, texts: [String], launches: Int, full: Bool,
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
            func ask(_ action: WindowProbeAction, _ seconds: TimeInterval = 60) async -> WindowLook? {
                seen.look = nil
                guard manager.lookAtWindow(profile.id, action) else { return nil }
                await wait(seconds) { seen.look != nil || seen.exited != nil }
                return seen.look
            }
            let label = "\(engine.name), launch \(launch)"
            // The window settles (its first page, its toolbar) before a person would type; a second tab
            // and another page that match what is typed, as a profile in use has them.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let storesBefore = await ask(.safariStores)
            problems += storeFindings(storesBefore, label: label + ", before typing", details: false)
                .map { "launch \(launch), Safari's stores before typing: \($0)" }
            for action in [WindowProbeAction.openTab("http://google.selftest.invalid/one?tab"),
                           .go("http://www.google.selftest.invalid/two?visited")] {
                _ = await ask(action, 30)
            }
            for typed in (launch == 1 ? texts : [text]) {
                print("\(tag) INFO \(label): typing \(typed)")
                guard let look = await ask(.typeInAddressBar(typed)) else {
                    problems.append("launch \(launch), \(typed): the profile's process did not answer")
                    if seen.exited != nil { break }
                    continue
                }
                problems += findings(look, engine: engine).map { "launch \(launch), \(typed): \($0)" }
                if seen.exited != nil { break }
            }
            // Return: the search with the profile's engine; on Google's first launch also a typed
            // address and the completion list's first row.
            var returns: [(String, Bool, Expected)] = [(text, false, .engine)]
            if full && launch == 1 {
                returns += [("example.com", false, .host("example.com")), (text, true, .anyNavigation)]
            }
            for (typed, firstCompletion, expected) in returns where seen.exited == nil {
                let what = firstCompletion ? "\(typed), Down arrow, Return" : "\(typed), Return"
                print("\(tag) INFO \(label): \(what)")
                let before = await proxyTargets(port: port, since: 0)
                let look = await ask(.enterInAddressBar(typed, firstCompletion: firstCompletion), 90)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let after = await proxyTargets(port: port, since: before.count)
                problems += returnFindings(look, engine: engine, label: label + ", " + what, expected: expected,
                                           targets: after.hosts, printPath: engine == .google && launch == 1)
                    .map { "launch \(launch), \(what): \($0)" }
            }
            if seen.exited == nil {
                let after = await ask(.safariStores)
                problems += storeFindings(after, label: label + ", after", details: engine == .google && launch == launches)
                    .map { "launch \(launch), Safari's stores after: \($0)" }
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
        if engine == .google, !report.completionClasses.isEmpty {
            print("\(tag) CLASSES \(report.completionClasses.joined(separator: " "))")
        }
        for line in report.providers.split(separator: "\n") { print("\(tag) INFO \(engine.name) providers: \(line.prefix(400))") }
        print("\(tag) INFO \(engine.name): \(report.accessibilityReads) accessibility reads after the key presses, "
              + "\(report.accessibilityExceptions.count) raised, \(report.accessibilityPastEndExceptions.count) past the text's end raised")
        for line in report.accessibilityExceptions { print("\(tag) AX-THREW \(engine.name): \(line.prefix(300))") }
        for line in report.accessibilityPastEndExceptions { print("\(tag) AX-PAST-END \(engine.name): \(line.prefix(300))") }
        printThrown(report.thrown, label: engine.name)
        var problems: [String] = []
        if report.field != report.typed { problems.append("the field holds \"\(report.field)\", not \"\(report.typed)\"") }
        if report.outOfKeyPresses > 0 { problems.append("\(report.outOfKeyPresses) key press(es) raised an exception") }
        if report.caughtByRunLoop > 0 { problems.append("the run loop caught \(report.caughtByRunLoop) exception(s) while it typed") }
        if !report.accessibilityExceptions.isEmpty {
            problems.append("\(report.accessibilityExceptions.count) accessibility read(s) of the field or the completion list raised "
                            + "(as an app that reads the focused field at every key would: \(report.accessibilityExceptions.prefix(3).joined(separator: "; ")))")
        }
        if report.notices > 0 { problems.append("the window put up \(report.notices) notice(s)") }
        return problems
    }

    /// Each distinct exception once, with its frames.
    private static func printThrown(_ thrown: [AddressBarTyping.Thrown], label: String) {
        var said: Set<String> = []
        for one in thrown where said.insert(one.name + one.reason).inserted {
            let times = thrown.filter { $0.name == one.name && $0.reason == one.reason }.count
            print("\(tag) THROWN \(label) ×\(times): \(one.name): \(one.reason.prefix(600))")
            for frame in one.frames { print("\(tag) FRAME   \(frame.prefix(220))") }
        }
    }

    // MARK: Return

    private enum Expected {
        /// The profile's engine's results, as the proxy or the front page sees them.
        case engine
        /// This host.
        case host(String)
        /// Any page started: a completion may be an address, a search or an open tab switched to.
        case anyNavigation
    }

    private static func returnFindings(_ look: WindowLook?, engine: SearchEngine, label: String, expected: Expected,
                                       targets: [String], printPath: Bool) -> [String] {
        guard let look else { return ["no answer from the profile's window"] }
        guard look.found else { return ["no address bar found in the window (\(look.detail.prefix(200)))"] }
        guard let entered = try? JSONDecoder().decode(AddressBarTyping.Entered.self, from: Data(look.detail.utf8)) else {
            return ["an answer that is not a report: \(look.detail.prefix(300))"]
        }
        let seenByProxy = targets.isEmpty ? "nothing" : targets.joined(separator: " ")
        var line = "\(tag) RETURN \(label): field at Return \"\(entered.fieldAtReturn)\", the front page \(entered.pageBefore) → "
        line += "\(entered.pagesSeen.joined(separator: " → ")) (another page in front: \(entered.frontPageChanged)), "
        line += "tabs \(entered.tabsBefore) → \(entered.tabsAfter), the proxy saw \(seenByProxy); "
        line += "taken for the address bar's \(entered.returnSeen), "
        if entered.searchedWithProfilesEngine { line += "searched with the profile's engine by the profile's process (Safari's is another), " }
        line += "caught by the typing guard \(entered.caughtByTypingGuard), by the run loop \(entered.caughtByRunLoop), "
        line += "thrown in all \(entered.thrown.count), notices \(entered.notices)"
        print(line)
        for place in entered.thrownAfterReturn { print("\(tag) COMMIT-THREW \(label): \(place.prefix(300))") }
        for rescue in entered.rescues { print("\(tag) RESCUED \(label): \(rescue.prefix(300))") }
        printThrown(entered.thrown, label: label)
        if printPath {
            print("\(tag) COMMIT-METHODS \(entered.commitMethods.count): \(entered.commitMethods.joined(separator: ", ").prefix(4000))")
            for frame in entered.navigationFrames { print("\(tag) COMMIT-PATH \(label)   \(frame.prefix(220))") }
        }
        let pages = entered.pagesSeen.compactMap { URL(string: $0) }
        let started: Bool
        let wanted: String
        switch expected {
        case .engine:
            wanted = "a search with \(engine.name)"
            started = targets.contains { AddressBarIntent.isResultsHost($0, of: engine) }
                || pages.contains { AddressBarIntent.isResultsHost($0.host ?? "", of: engine) }
        case .host(let host):
            wanted = host
            started = targets.contains { $0.hasPrefix(host + ":") || $0 == host } || pages.contains { $0.host == host }
        case .anyNavigation:
            wanted = "a page"
            started = entered.pagesSeen.count > 1 || entered.frontPageChanged || entered.tabsAfter != entered.tabsBefore || !targets.isEmpty
        }
        var problems: [String] = []
        if !started { problems.append("Return started no navigation to \(wanted)") }
        if !entered.returnSeen { problems.append("the Return was not taken for the address bar's (AddressBarCommit)") }
        if !entered.rescues.isEmpty {
            problems.append("Safari's code threw in the commit and the profile's process loaded it itself: \(entered.rescues.joined(separator: "; "))")
        } else if !entered.thrownAfterReturn.isEmpty {
            problems.append("Safari's code threw after Return: \(entered.thrownAfterReturn.joined(separator: "; "))")
        }
        if entered.outOfKeyPresses > 0 { problems.append("\(entered.outOfKeyPresses) key press(es) raised an exception") }
        if entered.caughtByRunLoop > 0 { problems.append("the run loop caught \(entered.caughtByRunLoop) exception(s)") }
        if entered.notices > 0 { problems.append("the window put up \(entered.notices) notice(s)") }
        return problems
    }

    /// Every request and tunnel the self-test proxy saw from `since` on (scripts/selftest_proxy.py,
    /// `/pb-targets.json`), asked of the proxy itself.
    private static func proxyTargets(port: Int, since: Int) async -> (count: Int, hosts: [String]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
        ]
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: "http://proxied.selftest.invalid/pb-targets.json?since=\(since)"),
              let answer = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any] else {
            print("\(tag) INFO the proxy's list of requests could not be read")
            return (since, [])
        }
        return (object["count"] as? Int ?? since, (object["targets"] as? [String] ?? []).map { $0.lowercased() })
    }

    // MARK: Safari's stores

    private static func storeFindings(_ look: WindowLook?, label: String, details: Bool) -> [String] {
        guard let look, look.found,
              let report = try? JSONDecoder().decode(SafariStores.Report.self, from: Data(look.detail.utf8)) else {
            return ["no report of Safari's stores from the profile's process (\(look?.detail.prefix(200) ?? "no answer"))"]
        }
        if let made = report.preparation {
            print("\(tag) STORES \(label): the launch made \(made.made.count) folder(s)\(made.made.isEmpty ? "" : " (\(made.made.joined(separator: ", ")))"), "
                  + "made writable \(made.madeWritable), set aside \(made.setAside), could not \(made.failed)")
        } else {
            print("\(tag) STORES \(label): the launch made sure of nothing (not run in this process)")
        }
        for store in report.stores { print("\(tag) STORE \(label): \(store.line)") }
        let present = report.stores.filter(\.exists).count
        print("\(tag) STORES \(label): \(present) of \(report.stores.count) present; \(report.files.count) file(s) under the home's Library")
        if details {
            for file in report.files { print("\(tag) FILE \(file.prefix(220))") }
            for getter in report.getters { print("\(tag) GETTER \(getter.prefix(300))") }
        }
        if label.hasSuffix("after") {
            for store in report.stores { storesSeen[store.path, default: []].append(store) }
        }
        var problems: [String] = []
        for store in report.stores where store.exists {
            if !store.wellFormed { problems.append("\(store.path) is not a \(store.kind.rawValue)") }
            if !store.writable { problems.append("\(store.path) is not writable") }
            if store.opened?.hasPrefix("DOES NOT OPEN") == true { problems.append("\(store.path) \(store.opened ?? "")") }
        }
        for store in report.stores where store.kind == .folder && !store.exists {
            problems.append("the folder \(store.path) is missing")
        }
        if let made = report.preparation, !made.failed.isEmpty { problems.append("the launch could not: \(made.failed.joined(separator: "; "))") }
        return problems
    }

    /// Each store of the complete tree, against what the profiles' runs left.
    private static func summarizeStores() {
        guard !storesSeen.isEmpty else { return }
        var present: [String] = []
        var missing: [String] = []
        for store in SafariStoreLayout.stores {
            let seen = storesSeen[store.path] ?? []
            let there = seen.filter(\.exists).count
            let opening = seen.filter { $0.opened?.hasPrefix("opens") == true }.count
            let line = "\(store.path) (\(there)/\(seen.count)\(store.kind == .database ? ", opens \(opening)" : ""))"
            if there > 0 { present.append(line) } else { missing.append(line) }
        }
        print("\(tag) STORES SUMMARY present after the runs: \(present.joined(separator: ", "))")
        print("\(tag) STORES SUMMARY missing after the runs: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
    }

    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) async {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
