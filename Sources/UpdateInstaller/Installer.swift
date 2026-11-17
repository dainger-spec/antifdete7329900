import BrowserCore
import Darwin
import Foundation

/// Replaces an app bundle with a release the app asked for at its quit (docs/UPDATES.md §3). Run by
/// the helper inside the app, which the app starts through LaunchServices once every profile is
/// sealed; trusts nothing it is handed but the request's file names, and checks everything again:
///
/// 1. the installed app's own signature, and from its signed `Info.plist` the keys and the Team ID;
/// 2. the request is for this app, and recent;
/// 3. nothing runs from the bundle any more — the app first of all. A process started since the
///    request is given a few seconds to end by itself (a Lumen opened now steps aside:
///    `UpdateStepAside`); one that stays ends the request (the person is using Lumen; the next quit
///    asks again). Nothing is ever killed; after `patience` the request is given up. Looked at again
///    right before the swap, and right after it at the old app's new place, with the same grace: an
///    app that stays open is never left running from a bundle swapped away and deleted;
/// 4. the release is newer than the installed build, for this macOS, signed with a carried key;
///    the archive's length, SHA-256 and Ed25519 signature;
/// 5. extracted next to the app (so the swap is a rename on one volume): exactly one app, the same
///    identifier, the release's versions, a code signature that holds (strict, nested code) with the
///    Team ID the installed app names;
/// 6. `renamex_np(RENAME_SWAP)`, the new app checked again in place, and started; if it does not
///    check or cannot start, swapped back (and the old one started).
///
/// The outcome is left in the staging folder for the app's next launch.
public final class Installer {
    public struct Environment {
        /// The processes running from inside the bundle, but the installer's own.
        public var processes: (URL) -> [BundleProcess]
        /// Starts the app (LaunchServices); throws when it cannot.
        public var launch: (URL) async throws -> Void
        public var sleep: (TimeInterval) async -> Void
        public var now: () -> Date
        /// The macOS this runs on.
        public var system: BuildVersion
        /// How long the app's processes are waited for; then the request is given up.
        public var patience: TimeInterval
        public var poll: TimeInterval
        /// A request older than this is not carried out: it was not written by the quit that started
        /// this helper.
        public var freshness: TimeInterval
        /// A process of the app started after the request is given this long to end by itself: a
        /// Lumen opened during the install steps aside (`UpdateStepAside`) within a second or two.
        public var stepAsideGrace: TimeInterval
        /// The step under way, for the helper's window (called on the installer's task).
        public var progress: @Sendable (UpdateInstallStep) -> Void
        /// This process, named in the marker.
        public var pid: Int32

        public init(processes: @escaping (URL) -> [BundleProcess], launch: @escaping (URL) async throws -> Void,
                    sleep: @escaping (TimeInterval) async -> Void, now: @escaping () -> Date, system: BuildVersion,
                    patience: TimeInterval = 600, poll: TimeInterval = 0.5, freshness: TimeInterval = 900,
                    stepAsideGrace: TimeInterval = 15, progress: @escaping @Sendable (UpdateInstallStep) -> Void = { _ in },
                    pid: Int32 = getpid()) {
            self.stepAsideGrace = stepAsideGrace
            self.progress = progress
            self.pid = pid
            self.processes = processes
            self.launch = launch
            self.sleep = sleep
            self.now = now
            self.system = system
            self.patience = patience
            self.poll = poll
            self.freshness = freshness
        }
    }

    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The installed app, and what it trusts: read from its `Info.plist` once its signature holds.
    struct InstalledApp {
        let identifier: String
        let build: BuildVersion
        let keys: [String: Data]
        let teamID: String?

        init(at app: URL) throws {
            let info = try Installer.info(of: app)
            guard let identifier = info["CFBundleIdentifier"] as? String, let text = info["CFBundleVersion"] as? String,
                  let build = BuildVersion(text) else {
                throw Refusal("the installed app has no identifier or build")
            }
            let teamID = (info["PBUpdateTeamID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            try CodeSignature.check(app, identifier: identifier, teamID: teamID)
            let keys = UpdateKeys.fromInfoPlist(info["PBUpdatePublicKeys"])
            guard !keys.isEmpty else { throw Refusal("the installed app carries no update keys") }
            self.identifier = identifier
            self.build = build
            self.keys = keys
            self.teamID = teamID
        }
    }

    let app: URL
    let staging: URL
    let environment: Environment

    public init(app: URL, staging: URL, environment: Environment) {
        self.app = app.standardizedFileURL
        self.staging = staging
        self.environment = environment
    }

    /// Carries out the request in the staging folder; leaves the outcome there, and returns it. A
    /// Lumen opened meanwhile, which stepped aside and asked for Lumen (`UpdateRelaunchWish`), gets
    /// it at the end whatever came of the install: the new version if it is in place and started
    /// (as always), else the version there was.
    public func run() async -> UpdateOutcome {
        let began = environment.now()
        let outcome = await install(began: began)
        if let wish = UpdateRelaunchWish.read(from: staging), wish.at > began.addingTimeInterval(-5),
           outcome.result == .refused || outcome.result == .gaveUp, environment.processes(app).isEmpty {
            try? await environment.launch(app)
        }
        UpdateRelaunchWish.remove(from: staging)
        return outcome
    }

    private func install(began: Date) async -> UpdateOutcome {
        var from = "?", to = "?", version = "?"
        var consumed = false
        let staging = staging
        let app = app
        let environment = environment
        // The marker a Lumen opened meanwhile finds (`UpdateStepAside`): rewritten at every step,
        // and every few seconds while this waits; gone before any app is started, and at the end.
        var step = UpdateInstallStep.checking
        var marked = Date.distantPast
        func mark(_ next: UpdateInstallStep? = nil) {
            let now = environment.now()
            if let next {
                step = next
                environment.progress(next)
            } else if now.timeIntervalSince(marked) < 5 {
                return
            }
            marked = now
            try? UpdateInstallMarker(pid: environment.pid, appPath: app.path, version: version, step: step, startedAt: began,
                                     updatedAt: now).write(to: staging)
        }
        func finish(_ result: UpdateOutcome.Result, _ reason: UpdateOutcome.Reason, _ detail: String) -> UpdateOutcome {
            UpdateInstallMarker.remove(from: staging)
            let outcome = UpdateOutcome(result: result, detail: detail, fromBuild: from, toBuild: to, version: version,
                                        at: environment.now(), reason: reason)
            try? outcome.write(to: staging)
            return outcome
        }
        /// Waits up to the step-aside grace for every process of `bundle` to end by itself.
        func noneRunning(in bundle: URL) async -> Bool {
            let until = environment.now().addingTimeInterval(environment.stepAsideGrace)
            while !environment.processes(bundle).isEmpty {
                guard environment.now() < until else { return false }
                mark()
                await environment.sleep(environment.poll)
            }
            return true
        }
        mark(.checking)

        let installed: InstalledApp
        do { installed = try InstalledApp(at: app) } catch { return finish(.refused, .untrustedApp, "\(error)") }
        from = installed.build.description
        let request: UpdateRequest
        do { request = try UpdateRequest.read(from: staging) } catch { return finish(.refused, .noRequest, "no request: \(error)") }
        to = request.item.build
        version = request.item.version
        mark(.checking)
        let archive = staging.appendingPathComponent(request.archive)
        // Whatever comes of it, the request is used up; the archive too, unless the app is to try again.
        defer {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(UpdateStaging.requestName))
            if consumed { try? FileManager.default.removeItem(at: archive) }
        }
        guard URL(fileURLWithPath: request.appPath).standardizedFileURL.path == app.path else {
            return finish(.refused, .otherApp, "the request is for \(request.appPath), not \(app.path)")
        }
        guard environment.now().timeIntervalSince(request.requestedAt) < environment.freshness else {
            return finish(.refused, .staleRequest, "the request is from \(request.requestedAt), not from this quit")
        }

        // Every process of the bundle goes first. One started since the request is given the
        // step-aside grace to end by itself — a Lumen opened now steps aside (`UpdateStepAside`) —
        // and ends the request if it stays: that is the person using Lumen, and this quit is over.
        let startedAgain = "the app was started again, and stayed open, before it could be replaced"
        let deadline = environment.now().addingTimeInterval(environment.patience)
        var seen: [pid_t: Date] = [:]
        while true {
            let running = environment.processes(app)
            let now = environment.now()
            for process in running where process.startedAt > request.requestedAt.addingTimeInterval(2) && seen[process.pid] == nil {
                seen[process.pid] = now
            }
            if running.contains(where: { seen[$0.pid].map { now.timeIntervalSince($0) >= environment.stepAsideGrace } ?? false }) {
                return finish(.gaveUp, .startedAgain, startedAgain)
            }
            if running.isEmpty { break }
            guard now < deadline else {
                return finish(.gaveUp, .stillRunning,
                              "\(running.count) process(es) still ran from the app after \(Int(environment.patience)) s; none was stopped")
            }
            mark()
            await environment.sleep(environment.poll)
        }

        consumed = true
        do {
            try UpdateVerifier.checkInstallable(request.item, running: installed.build, system: environment.system, keys: installed.keys)
        } catch {
            switch error as? UpdateError {
            case .notNewer?, .needsNewerSystem?: return finish(.refused, .notApplicable, "\(error)")
            default: return finish(.refused, .badRelease, "\(error)")
            }
        }
        do {
            try UpdateVerifier.checkArchive(at: archive, item: request.item, keys: installed.keys)
        } catch {
            return finish(.refused, .badRelease, "\(error)")
        }
        mark()

        let work = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).update-\(UUID().uuidString)",
                                                                         isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let candidate: URL
        do {
            candidate = try extract(archive, into: work)
            try check(candidate, against: request.item, installed: installed)
            Self.releaseFromQuarantine(candidate)
        } catch {
            return finish(.refused, .badRelease, "\(error)")
        }

        // The checks above take seconds, in which the app can be opened again (its Dock icon, a
        // link, a profile's file): such a process would run on from a bundle swapped away and then
        // deleted, and use the new build's helpers. One that steps aside ends within the grace; one
        // that stays ends the request as a start during the wait does — nothing replaced, the
        // archive kept for the next quit.
        guard await noneRunning(in: app) else {
            consumed = false
            return finish(.gaveUp, .startedAgain, startedAgain)
        }
        mark(.installing)
        guard renamex_np(candidate.path, app.path, UInt32(RENAME_SWAP)) == 0 else {
            return finish(.refused, .swapFailed, "the swap failed (errno \(errno)); the installed app is untouched")
        }
        // From here `candidate` is the old app. Swapped back, it is the installed one again; if even
        // that fails, it is kept beside the app instead of going with the work folder.
        func swapBack() -> String? {
            if renamex_np(candidate.path, app.path, UInt32(RENAME_SWAP)) == 0 { return nil }
            let failure = errno
            let kept = app.deletingLastPathComponent().appendingPathComponent("\(app.deletingPathExtension().lastPathComponent) (previous version).app")
            try? FileManager.default.moveItem(at: candidate, to: kept)
            return "swapping back failed (errno \(failure)); the previous app is at \(kept.path)"
        }
        // One started between that look and the swap runs from the old app at its new place (the
        // kernel names a running executable by where it is now): given the grace to step aside,
        // and if it stays, the old app goes back.
        guard await noneRunning(in: candidate) else {
            guard let failure = swapBack() else {
                consumed = false
                return finish(.gaveUp, .startedAgain, startedAgain)
            }
            return finish(.gaveUp, .startedAgain, "\(startedAgain); \(failure)")
        }
        do {
            try check(app, against: request.item, installed: installed)
        } catch {
            return finish(.refused, .didNotStart, "the new app does not check in place (\(error))" + (swapBack().map { "; \($0)" } ?? ""))
        }
        mark(.relaunching)
        // A Lumen opened from here on is the new version: no marker for it to step aside for.
        UpdateInstallMarker.remove(from: staging)
        do {
            try await environment.launch(app)
        } catch {
            if let failure = swapBack() { return finish(.rolledBack, .didNotStart, "the new app did not start (\(error)); \(failure)") }
            try? await environment.launch(app)
            return finish(.rolledBack, .didNotStart, "the new app did not start (\(error)); the previous one is back")
        }
        return finish(.installed, .installed, "build \(request.item.build) is installed and was started")
    }

    // MARK: Steps

    /// The archive, extracted into `work` by `ditto`: exactly one app at its top level.
    private func extract(_ archive: URL, into work: URL) throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Refusal("ditto could not extract the archive (status \(ditto.terminationStatus))") }
        let entries = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && !$0.lastPathComponent.hasPrefix(".") }
        guard entries.count == 1, let bundle = entries.first, bundle.pathExtension == "app" else {
            throw Refusal("the archive holds \(entries.map(\.lastPathComponent)), not one app")
        }
        return bundle
    }

    /// The bundle is the release: the installed app's identifier, the release's versions, and a code
    /// signature that holds with the Team ID the installed app names.
    private func check(_ bundle: URL, against item: AppcastItem, installed: InstalledApp) throws {
        let info = try Self.info(of: bundle)
        guard info["CFBundleIdentifier"] as? String == installed.identifier else {
            throw Refusal("the archive's app is \(info["CFBundleIdentifier"] ?? "unnamed"), not \(installed.identifier)")
        }
        guard info["CFBundleVersion"] as? String == item.build, info["CFBundleShortVersionString"] as? String == item.version else {
            throw Refusal("the archive's app is \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), "
                + "the release says \(item.version) (\(item.build))")
        }
        try CodeSignature.check(bundle, identifier: installed.identifier, teamID: installed.teamID)
    }

    static func info(of bundle: URL) throws -> [String: Any] {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: url) as? [String: Any] else { throw Refusal("\(bundle.lastPathComponent) has no Info.plist") }
        return info
    }

    /// Checked by its signatures, the app is not left for Gatekeeper to ask about as a download.
    static func releaseFromQuarantine(_ bundle: URL) {
        let name = "com.apple.quarantine"
        removexattr(bundle.path, name, XATTR_NOFOLLOW)
        guard let enumerator = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let relative as String in enumerator {
            removexattr(bundle.appendingPathComponent(relative).path, name, XATTR_NOFOLLOW)
        }
    }
}
