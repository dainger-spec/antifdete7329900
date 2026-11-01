import AppKit
import BrowserCore

/// `Lumen --release-check`: what `scripts/release.sh` runs on the app it is about to publish — signed
/// as it ships (Developer ID, the hardened runtime, notarized and stapled in a release) — before
/// anything is zipped. What Lumen promises is a profile in a process of its own whose window is
/// Safari's own chrome (docs/ISOLATION_AND_LIMITATIONS.md §4a); a build where that cannot happen is
/// not released (docs/UPDATES.md §6, "Which build is released").
///
/// One profile is started the way the app starts one, with nothing set by hand: the build's own
/// defaults decide whether it gets a process of its own and Safari's window, so a switch left in this
/// environment or in this Mac's defaults fails the check instead of deciding it. The profile is held
/// to a proxy that goes nowhere, as CI's checks hold theirs, in a vault of its own in a temporary
/// folder; it is stopped and sealed, and the folder removed, at the end. PASS only when the
/// profile's own process says Safari's chrome hosts its window; anything else is FAIL with what was
/// seen, and exit status 1.
///
/// `--control` is the check's proof that it can fail: the same launch with Safari's chrome turned
/// off for the profile's process (`PB_SAFARI_CHROME=0`, which that process inherits) must come back
/// FAIL for its window. CI runs both, and the check on the sandboxed build, which must fail too.
@MainActor
enum ReleaseCheck {
    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
            print("RELEASE-CHECK FAIL the check did not finish in 4 minutes")
            exit(1)
        }
        let control = arguments.contains("--control")
        Task { @MainActor in exit(await run(control: control)) }
        application.run()
    }

    private static func fail(_ reason: String) -> Int32 {
        print("RELEASE-CHECK FAIL \(reason)")
        return 1
    }

    private static func run(control: Bool) async -> Int32 {
        let info = Bundle.main.infoDictionary ?? [:]
        let identifier = Bundle.main.bundleIdentifier ?? "this app"
        print("RELEASE-CHECK INFO \(identifier) \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")), "
              + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(HostSafari.version)"
              + (control ? "; the control: Safari's chrome turned off for the profile's process" : ""))
        // In the App Sandbox Safari's frameworks cannot be loaded, and every profile runs in the
        // app's one process (ProfileProcess.isEnabled, SafariChromeHost.reasonForOwnWindow).
        if AppEnvironment.isSandboxed {
            return fail("the build runs in the App Sandbox: Safari's frameworks cannot be loaded there, and every profile runs in the app's one process")
        }
        // What a person gets, not what this environment or this Mac was told.
        let environment = ProcessInfo.processInfo.environment
        let switches = ["PB_PROFILE_PROCESS", "PB_SAFARI_CHROME"].filter { environment[$0] != nil }
        if !switches.isEmpty {
            return fail("set in this environment: \(switches.joined(separator: ", ")); the check runs what a person gets, so unset them")
        }
        if UserDefaults.standard.object(forKey: "PBProfileProcess") != nil {
            return fail("PBProfileProcess is set in this Mac's defaults for \(identifier); the check runs what a person gets, so remove it "
                        + "(defaults delete \(identifier) PBProfileProcess)")
        }
        guard ProfileProcess.isEnabled else {
            return fail("a profile does not get a process of its own by default in this build")
        }
        // The license (the server's docs/CONTRACT.md §2, §7.2): a released build talks to its account
        // server over https and trusts the keys of the server's documents — never the development
        // server's, which anyone knows (and the production server refuses to sign with it).
        guard let account = AccountConfiguration.resolve(info: info, environment: [:], arguments: []), account.source == .build else {
            return fail("no account server in this build (PBAccountServerURL, https): its license would not be checked")
        }
        guard !account.keys.isEmpty else {
            return fail("no keys of the documents of rights in this build (PBEntitlementPublicKeys): no license could be accepted")
        }
        guard account.keys[EntitlementKeys.developmentKeyID] == nil else {
            return fail("the development server's key (\(EntitlementKeys.developmentKeyID)) is trusted by this build: anyone can sign documents with it")
        }
        print("RELEASE-CHECK INFO the account server \(account.serverURL.host ?? "?"), \(account.keys.count) key(s) of documents of rights")
        // Inherited by the profile's process: its window is then this app's own (the control).
        if control { setenv("PB_SAFARI_CHROME", "0", 1) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-release-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: UUID().uuidString, iterations: 10_000))
            profile = try repository.create(name: "Release check", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 1), matchProxyLocation: false))
        } catch {
            return fail("could not make a profile to start: \(error)")
        }
        let manager = ProfileManager(repository: repository)
        var hostsChrome: Bool?
        var exited: Int32?
        manager.onProfileRunning = { _, hosts in hostsChrome = hosts }
        manager.onChildExited = { _, status in exited = status }
        manager.onError = { message in print("RELEASE-CHECK INFO the manager was told: \(message)") }
        do {
            try await manager.launch(profile.id)
        } catch {
            return fail("the profile did not start: \(error)")
        }
        let process = manager.processIdentifier(of: profile.id)
        let started = Date()
        while hostsChrome == nil, exited == nil, Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if manager.isRunning(profile.id) { try? await manager.stop(profile.id) }

        guard let process else {
            return fail("the profile ran in the app's own process, not in a process of its own")
        }
        switch hostsChrome {
        case true?:
            print("RELEASE-CHECK PASS a profile in a process of its own (pid \(process)), its window Safari's own chrome")
            return 0
        case false?:
            return fail("the profile's window is the app's own, not Safari's: a simplified mode (its process's log says why, SafariChromeHost)")
        case nil:
            return fail(exited.map { "the profile's process exited (status \($0)) before its window came up" }
                        ?? "no word from the profile's process in 90 s")
        }
    }
}
