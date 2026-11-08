import AppKit
import BrowserCore
import Foundation

/// `Lumen --input-check` (a measurement on the branch claude/measure-touch, never merged): what a
/// click with the mouse brings a page in a mobile view and in a Mac profile, and whether a profile's
/// process stops answering on the way — the owner's report from macOS 27.0.1, 2 November: in a
/// mobile view, pages scroll and Google's search works, but on many sites a tap is not taken, and
/// following a link sometimes freezes the browser for good (tiktok.com).
///
/// Two profiles without a proxy, each in a process of its own as the app runs them: a mobile view
/// (`--mobile`, default the iPhone of this Mac's Safari) and a Mac profile. For each site of
/// `--sites`, the profile's process opens it and clicks its elements (`InputProbe`); every two
/// seconds its main thread is asked to answer (`ping`). Ten seconds without an answer, or a page
/// that does not answer after a click, is an `INPUT-STALL` line: scripts/input_check.py takes the
/// main threads' stacks then (spindump), and writes `stacks-<n>` in `--out` when it has them; a
/// process that never answers again is stopped after that and started again for the next site.
/// One `INPUT` line of JSON per step; the script makes the report.
@MainActor
enum InputCheck {
    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        setenv("PB_PROFILE_PROCESS", "1", 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3000) {
            print("INPUT-ERROR did not finish in 50 minutes")
            exit(1)
        }
        Task { @MainActor in exit(await run(arguments: arguments)) }
        application.run()
    }

    private static func value(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func line(_ prefix: String, _ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        print(prefix + " " + String(decoding: data, as: UTF8.self))
    }

    private static func run(arguments: [String]) async -> Int32 {
        guard !AppEnvironment.isSandboxed else {
            print("INPUT-ERROR the sandboxed build runs no process per profile")
            return 1
        }
        let sites = (value("--sites", in: arguments) ?? "pb-test:touch,https://www.tiktok.com/,https://www.google.com/search?q=lumen")
            .split(separator: ",").map(String.init)
        let major = HostSafari.version.split(separator: ".").first.map(String.init) ?? "26"
        let mobileID = value("--mobile", in: arguments) ?? (major == "27" ? "ios-27" : "ios-26")
        let kinds = (value("--profiles", in: arguments) ?? "mobile,mac").split(separator: ",").map(String.init)
        let out = URL(fileURLWithPath: value("--out", in: arguments) ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        line("INPUT", ["step": "machine", "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                       "safari": HostSafari.version, "mobileGeneration": mobileID])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-input-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "input-check"))
        } catch {
            print("INPUT-ERROR no vault: \(error)")
            return 1
        }
        var profiles: [(kind: String, id: UUID)] = []
        for kind in kinds {
            let configuration = ProfileConfiguration(startURL: URL(string: "about:blank"), proxy: nil,
                                                     deviceGenerationID: kind.hasPrefix("mobile") ? mobileID : DeviceGenerations.defaultID,
                                                     matchProxyLocation: false)
            do {
                profiles.append((kind, try repository.create(name: kind.hasPrefix("mobile") ? "Mobile view" : "Mac", configuration: configuration).id))
            } catch {
                print("INPUT-ERROR the \(kind) profile was not made: \(error)")
                return 1
            }
        }

        let manager = ProfileManager(repository: repository)
        var running: [UUID: Bool] = [:]
        var exits: [UUID: Int32] = [:]
        var pongs: [UUID: Date] = [:]
        var reports: [Int: [String]] = [:]
        manager.onProfileRunning = { id, chrome in running[id] = chrome }
        manager.onChildExited = { id, status in exits[id] = status }
        manager.onError = { message in line("INPUT", ["step": "manager-error", "message": String(message.prefix(300))]) }
        manager.onPong = { id, _, _ in pongs[id] = Date() }
        manager.onInputReport = { _, number, report in reports[number, default: []].append(report) }

        var number = 0
        var stalls = 0
        var failed = false
        for profile in profiles {
            var processUp = false
            for site in sites {
                if !processUp {
                    running[profile.id] = nil
                    exits[profile.id] = nil
                    do { try await manager.launch(profile.id) } catch {
                        line("INPUT", ["step": "launch-error", "profile": profile.kind, "error": "\(error)"])
                        failed = true
                        break
                    }
                    let deadline = Date().addingTimeInterval(90)
                    while running[profile.id] == nil, exits[profile.id] == nil, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard let chrome = running[profile.id], let pid = manager.processIdentifier(of: profile.id) else {
                        line("INPUT", ["step": "launch-error", "profile": profile.kind,
                                       "error": exits[profile.id].map { "its process ended (status \($0))" } ?? "no window in 90 s"])
                        failed = true
                        break
                    }
                    line("INPUT", ["step": "running", "profile": profile.kind, "pid": Int(pid), "safariChrome": chrome])
                    processUp = true
                    // Its window comes up and settles before anything is asked of it.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                number += 1
                let asked = number
                pongs[profile.id] = Date()
                guard manager.sendProbe(profile.id, .inputProbe(asked, profile.kind == "mobile-oldshim" ? "oldshim|" + site : site)) else {
                    line("INPUT", ["step": "send-error", "profile": profile.kind, "site": site])
                    processUp = false
                    continue
                }
                var printed = 0
                var done = false
                var stalledMain = false
                var pingNumber = 0
                let deadline = Date().addingTimeInterval(300)
                while !done, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let lines = reports[asked] ?? []
                    while printed < lines.count {
                        let text = lines[printed]
                        printed += 1
                        print("INPUT {\"profile\":\"\(profile.kind)\"," + text.dropFirst())
                        if text.contains("\"step\":\"done\"") { done = true }
                        if text.contains("\"step\":\"stall\"") {
                            stalls += 1
                            let pid = manager.processIdentifier(of: profile.id).map { Int($0) } ?? -1
                            line("INPUT-STALL", ["n": stalls, "profile": profile.kind, "pid": pid, "what": "page", "site": site])
                        }
                    }
                    if exits[profile.id] != nil {
                        line("INPUT", ["step": "process-ended", "profile": profile.kind, "site": site, "status": Int(exits[profile.id] ?? 0)])
                        processUp = false
                        break
                    }
                    pingNumber += 1
                    if pingNumber % 4 == 0 { manager.sendProbe(profile.id, .ping(pingNumber)) }
                    if !stalledMain, let last = pongs[profile.id], Date().timeIntervalSince(last) > 10 {
                        stalledMain = true
                        stalls += 1
                        let pid = manager.processIdentifier(of: profile.id).map { Int($0) } ?? -1
                        line("INPUT-STALL", ["n": stalls, "profile": profile.kind, "pid": pid, "what": "main thread",
                                             "site": site, "silentSeconds": Int(Date().timeIntervalSince(last))])
                        // The stacks are taken while it does not answer; then it is given a minute more.
                        let marker = out.appendingPathComponent("stacks-\(stalls)")
                        let wait = Date().addingTimeInterval(150)
                        while !FileManager.default.fileExists(atPath: marker.path), Date() < wait {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        let again = Date().addingTimeInterval(60)
                        while let last = pongs[profile.id], Date().timeIntervalSince(last) > 10, Date() < again {
                            manager.sendProbe(profile.id, .ping(pingNumber))
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                        if let last = pongs[profile.id], Date().timeIntervalSince(last) > 10 {
                            line("INPUT", ["step": "frozen", "profile": profile.kind, "site": site,
                                           "silentSeconds": Int(Date().timeIntervalSince(last)),
                                           "said": "its main thread did not answer for good; the process is stopped"])
                            if pid > 0 { kill(pid_t(pid), SIGKILL) }
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            processUp = false
                            break
                        }
                        line("INPUT", ["step": "thawed", "profile": profile.kind, "site": site])
                        stalledMain = false
                    }
                }
                if !done, processUp {
                    line("INPUT", ["step": "probe-timeout", "profile": profile.kind, "site": site, "lines": printed])
                }
            }
            if processUp {
                do { try await manager.stop(profile.id) } catch {
                    line("INPUT", ["step": "stop-error", "profile": profile.kind, "error": "\(error)"])
                }
            }
        }
        line("INPUT", ["step": "finished", "stalls": stalls])
        return failed ? 1 : 0
    }
}
