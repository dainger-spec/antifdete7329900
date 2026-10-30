import AppKit
import BrowserCore
import Foundation

/// `PrivacyBrowser --selftest-updates run|verify`: the update scenarios of docs/UPDATES.md §8, driven
/// by `scripts/update_check.py` on a CI runner — the app's own updater against a local HTTPS feed
/// (`PB_SELFTEST_UPDATE_CONTROL` says which list it serves), a "new" build of this app the script
/// made and signed, and the real installer helper.
///
/// `run`, in the old build: not one request with automatic checks off; the first request once they
/// are on, to a feed that lists only this build and an older one, which offers nothing; a stale
/// appcast, a forged one and a changed archive refused; the real release downloaded and checked;
/// nothing handed over while a profile with a window and a warm-up without one run; then the quit
/// path — both stopped and sealed — the gate, and the installer. The script waits for the swap.
///
/// `verify`, in the new build after the swap and the relaunch: the old build's vault opens with its
/// profiles and their data, and a profile's website data sealed by the old build opens, and is
/// sealed again on stop.
///
/// It makes a vault in `PRIVACYBROWSER_VAULT_DIR` and hands a real update to the installer, which
/// replaces this very app: only with `PB_SELFTEST_UPDATES=1`, which only that script sets.
@MainActor
enum UpdateSelfTest {
    static let password = "update-check"
    private static var failures = 0

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = ProcessInfo.processInfo.environment
        guard environment["PB_SELFTEST_UPDATES"] == "1", environment["PRIVACYBROWSER_VAULT_DIR"] != nil else {
            print("--selftest-updates replaces this app with another build: only scripts/update_check.py runs it "
                + "(PB_SELFTEST_UPDATES=1 and PRIVACYBROWSER_VAULT_DIR)")
            exit(64)
        }
        let index = arguments.firstIndex(of: "--selftest-updates")
        let phase = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ""
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            print("SELFTEST-UPDATES TIMEOUT after 300 s")
            exit(3)
        }
        Task { @MainActor in
            switch phase {
            case "run": await run()
            case "verify": await verify()
            default:
                print("usage: PrivacyBrowser --selftest-updates run|verify")
                exit(64)
            }
            print("SELFTEST-UPDATES \(phase) \(failures == 0 ? "PASSED" : "FAILED"): \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
    }

    // MARK: The old build

    private static func run() async {
        guard let configuration = AppUpdater.Configuration.main() else {
            check("this build has an update feed and keys", false, "build it with UPDATE_FEED_URL and UPDATE_PUBLIC_KEYS")
            return
        }
        info("app \(configuration.app.path), build \(configuration.build), feed \(configuration.feed.absoluteString)")
        // Nothing remembered, nothing staged.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("PBUpdate") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: configuration.staging)
        do {
            let root = AppEnvironment.vaultDirectory
            let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: password, iterations: 10_000))
            let window = try repository.create(name: "Window", configuration: ProfileConfiguration())
            let warmUp = try repository.create(name: "Warm-up", configuration: ProfileConfiguration())
            for profile in [window, warmUp] {
                info("profile \(profile.name) \(profile.id.uuidString)")
                _ = try repository.bookmarkStore(for: profile.id, key: repository.profileKey(for: profile.id))
                    .add(title: "Before the update", url: URL(string: "https://example.org/before")!) // l10n: not text
            }
            AppUpdater.firstCheckDelay = 2
            let updater = AppUpdater(configuration: configuration)

            // Automatic checks off: not one request, though one would be due after 2 s.
            try await serve("valid")
            let before = try await feedRequests()
            updater.automaticChecks = false
            updater.start()
            // The control connection's close goes by before the window opens.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            info("egress-window begin \(Date().timeIntervalSince1970)")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            info("egress-window end \(Date().timeIntervalSince1970)")
            let afterOff = try await feedRequests()
            check("automatic checks off: the feed was not asked in 8 s", afterOff == before, "\(afterOff - before) request(s)")
            check("automatic checks off: nothing happened", updater.state == .idle, "\(updater.state)")

            // On: the first check is due 2 s later — the capture's control. The feed lists only this
            // build and an older one.
            try await serve("downgrade")
            info("feed-control-window begin \(Date().timeIntervalSince1970)")
            updater.automaticChecks = true
            let asked = await waitUntil(20) { ((try? await feedRequests()) ?? 0) > afterOff }
            let settled = await waitUntil(20) {
                if case .upToDate = updater.state { return true }
                return false
            }
            info("feed-control-window end \(Date().timeIntervalSince1970)")
            updater.automaticChecks = false
            check("automatic checks on: the feed was asked", asked)
            check("downgrade: a feed of this build and an older one offers nothing", settled, "\(updater.state)")
            check("downgrade: nothing was downloaded", !archiveStaged(configuration))

            try await serve("stale")
            await updater.checkNow()
            check("stale: a validly signed appcast older than the one accepted is refused", failed(updater, saying: "older"), "\(updater.state)")

            try await serve("forged")
            await updater.checkNow()
            check("forged: an appcast whose list was changed under its signature is refused", failed(updater, saying: "signature"), "\(updater.state)")
            check("forged: nothing was downloaded", !archiveStaged(configuration))

            try await serve("tampered")
            await updater.checkNow()
            check("changed archive: refused once downloaded", failed(updater, saying: "SHA-256"), "\(updater.state)")
            check("changed archive: not kept", !archiveStaged(configuration))

            try await serve("valid")
            await updater.checkNow()
            guard case .ready(let item) = updater.state else {
                check("the release is downloaded and checked", false, "\(updater.state)")
                return
            }
            check("the release is downloaded and checked", archiveStaged(configuration), "build \(item.build)")

            // Two profiles run: one with a window, one warming up without.
            let manager = ProfileManager(repository: repository)
            manager.onError = { info("profile error: \($0)") }
            try await manager.launch(window.id)
            try await manager.launch(warmUp.id, openingWindow: false)
            let running = await waitUntil(60) { manager.runningProfileIDs.isSuperset(of: [window.id, warmUp.id]) }
            check("two profiles run: one with a window, one warming up without", running)
            let activity = manager.activity()
            info("activity \(activity.map { "\($0.id == window.id ? "Window" : "Warm-up"): \($0.activity)" })")
            let listsWindow = activity.contains(where: { $0.id == window.id && $0.activity != .warmUpOnly })
            let listsWarmUp = activity.contains(where: { $0.id == warmUp.id && $0.activity == .warmUpOnly })
            check("Install Now would list the window and the warm-up without one", listsWindow && listsWarmUp, "\(activity)")
            let busy = UpdateGate.check(vaultRoot: root, hasActivity: manager.hasActivity, forcedExits: 0)
            check("while they run, the gate does not pass", !busy.passed)
            let refused = await updater.installAtQuit(gate: busy)
            check("while they run, nothing is handed over", refused == .refused(busy.reasons), "\(refused)")
            check("while they run, no request is written",
                  !FileManager.default.fileExists(atPath: configuration.staging.appendingPathComponent(UpdateStaging.requestName).path))
            check("while they run, no installer runs",
                  NSRunningApplication.runningApplications(withBundleIdentifier: configuration.bundleIdentifier + ".Updater").isEmpty)

            // The quit path: everything stopped and sealed, then the gate, then the installer.
            let killedBefore = ProfileProcess.forcedExits
            manager.prepareForQuit()
            await manager.shutDown()
            let gate = UpdateGate.check(vaultRoot: root, hasActivity: manager.hasActivity,
                                        forcedExits: ProfileProcess.forcedExits - killedBefore)
            check("after the quit's seal, every profile is sealed — the warm-up without a window too", gate.passed,
                  gate.reasons.joined(separator: "; "))
            check("no profile process had to be killed", ProfileProcess.forcedExits == killedBefore)
            guard gate.passed else { return }
            let handed = await updater.installAtQuit(gate: gate)
            check("the release is handed to the installer", handed == .started, "\(handed)")
            info("handed-over pid \(getpid()) at \(Date().timeIntervalSince1970)")
        } catch {
            check("the update scenarios ran without unexpected errors", false, String(describing: error))
        }
    }

    // MARK: The new build

    private static func verify() async {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        check("this is the new build", build == ProcessInfo.processInfo.environment["PB_SELFTEST_UPDATE_BUILD"], "build \(build)")
        do {
            let root = AppEnvironment.vaultDirectory
            let repository = try ProfileRepository(vault: MasterVault.unlock(in: root, password: password))
            let names = repository.list().map(\.name).sorted()
            check("the old build's vault opens, with its profiles", names == ["Warm-up", "Window"], "\(names)")
            for summary in repository.list() {
                let key = try repository.profileKey(for: summary.id)
                _ = try repository.loadConfiguration(summary.id, key: key)
                let titles = try repository.bookmarkStore(for: summary.id, key: key).all().map(\.title)
                check("\(summary.name): its settings and bookmarks open", titles == ["Before the update"], "\(titles)")
            }
            // The website data the old build sealed opens in the new one, and is sealed again.
            if let window = repository.list().first(where: { $0.name == "Window" }) {
                let manager = ProfileManager(repository: repository)
                manager.onError = { info("profile error: \($0)") }
                try await manager.launch(window.id)
                let running = await waitUntil(60) { manager.runningProfileIDs.contains(window.id) }
                check("Window: starts in the new build from what the old one sealed", running)
                manager.prepareForQuit()
                await manager.shutDown()
                let gate = UpdateGate.check(vaultRoot: root, hasActivity: manager.hasActivity, forcedExits: 0)
                check("Window: sealed again on stop", gate.passed, gate.reasons.joined(separator: "; "))
            }
            if let configuration = AppUpdater.Configuration.main() {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: configuration.staging.path)) ?? []
                check("the installer used up the archive and the request",
                      !left.contains { $0.hasSuffix(".zip") || $0 == UpdateStaging.requestName }, "\(left)")
            }
        } catch {
            check("the new build opens the old build's data", false, String(describing: error))
        }
    }

    // MARK: Helpers

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS \(name)")
        } else {
            failures += 1
            let extra = detail()
            print("FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    private static func info(_ text: String) { print("INFO \(text)") }

    private static func failed(_ updater: AppUpdater, saying text: String) -> Bool {
        if case .failed(let reason) = updater.state { return reason.contains(text) }
        return false
    }

    private static func archiveStaged(_ configuration: AppUpdater.Configuration) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: configuration.staging.path)) ?? []).contains { $0.hasSuffix(".zip") }
    }

    private static func waitUntil(_ seconds: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await condition()
    }

    // MARK: The local feed (scripts/update_check.py)

    private static let control = URLSession(configuration: .ephemeral)

    /// Has the feed serve `mode`: valid, downgrade, stale, forged or tampered.
    private static func serve(_ mode: String) async throws {
        _ = try await controlRequest("serve?mode=\(mode)")
    }

    /// How many times the feed was asked for its appcast so far.
    private static func feedRequests() async throws -> Int {
        Int(try await controlRequest("hits").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private static func controlRequest(_ path: String) async throws -> String {
        guard let base = ProcessInfo.processInfo.environment["PB_SELFTEST_UPDATE_CONTROL"], let url = URL(string: base + "/" + path) else {
            throw CoreError.invalidConfiguration("PB_SELFTEST_UPDATE_CONTROL")
        }
        let (data, _) = try await control.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }
}
