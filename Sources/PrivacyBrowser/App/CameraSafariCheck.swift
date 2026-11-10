import AppKit
import BrowserCore
import Foundation

/// `Lumen --camera-safari-check` (CI): a profile that substitutes its camera, run in its own
/// process where the window is Safari's — the one case the ordinary self-test (this app's own
/// windows) does not cover (owner, 10 November: a run in a window of the app's own is not Safari).
///
/// A new profile in a temporary vault, held to the self-test proxy (`PB_SELFTEST_HTTP_PROXY_PORT`)
/// and set to substitute the camera (a moving test pattern at 1280×720, labelled for the check), is
/// started without a window, as Run starts a stopped profile. A scenario then goes to a loopback
/// page the proxy serves — `http://127.0.0.1:<port>/…`, a secure context, where `navigator.media
/// Devices` exists at all — and, in the page's own world, calls `getUserMedia({video})` and
/// `enumerateDevices`. It passes when the run finished in a window of Safari's (its log's first
/// line), the page is a secure context, the stream's track reports the substitution's size and
/// label with a per-origin 64-hex deviceId, `getUserMedia` still prints as native code, two frames
/// taken a moment apart differ (the sensor-like grain, so the picture is not frozen), and
/// `enumerateDevices` lists exactly our one camera. Exit 0 then; 1, with what was found, when not.
/// scripts/camera_safari_check.sh starts the proxy and runs it.
@MainActor
enum CameraSafariCheck {
    private static let tag = "CAMERA-SAFARI"
    private static let label = "Lumen Camera Check"

    private final class Seen {
        var hostsChrome: Bool?
        var exited: Int32?
    }

    /// What the run does in the page's own world, and the line of its log this side reads.
    private static let script = """
        await page.goto(params.base);
        const report = await page.evaluate(async () => {
          const out = { secure: isSecureContext,
                        hasMedia: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia) };
          if (!out.hasMedia) return JSON.stringify(out);
          try {
            const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } });
            const track = stream.getVideoTracks()[0];
            out.settings = track.getSettings();
            out.label = track.label;
            out.native = /\\[native code\\]/.test(Function.prototype.toString.call(navigator.mediaDevices.getUserMedia));
            const canvas = document.createElement('canvas'); canvas.width = 48; canvas.height = 36;
            const ctx = canvas.getContext('2d');
            const video = document.createElement('video');
            video.srcObject = stream; video.muted = true; video.playsInline = true;
            await video.play().catch(() => {});
            await new Promise((r) => setTimeout(r, 150));
            ctx.drawImage(video, 0, 0, 48, 36); const first = canvas.toDataURL();
            await new Promise((r) => setTimeout(r, 200));
            ctx.drawImage(video, 0, 0, 48, 36); const second = canvas.toDataURL();
            out.framesDiffer = first !== second;
            const devices = await navigator.mediaDevices.enumerateDevices();
            const cameras = devices.filter((d) => d.kind === 'videoinput');
            out.cameraCount = cameras.length;
            out.cameraLabel = cameras[0] ? cameras[0].label : null;
            out.deviceIdHex = cameras[0] ? /^[0-9a-f]{64}$/.test(cameras[0].deviceId) : false;
            track.stop();
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-camera-safari-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A moving test pattern (no chosen file needed), at a size and label the check looks for.
        let camera = CameraSubstitution(mode: .substitute, source: .bars, width: 1280, height: 720,
                                        frameRate: 30, deviceLabel: label, audio: .off,
                                        deviceSecret: "cameracheckseed")
        let repository: ProfileRepository
        let profile: ProfileSummary
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "camera-safari", iterations: 10_000))
            profile = try repository.create(name: "Camera in Safari", configuration: ProfileConfiguration(
                proxy: ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: port), matchProxyLocation: false,
                cameraSubstitution: camera))
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
        } else {
            // A secure loopback origin the proxy serves: where navigator.mediaDevices exists at all.
            let base = "http://127.0.0.1:\(port)/pb-automation/form"
            if !manager.runScenario(profile.id, name: "Camera in Safari", source: script,
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
            print("\(tag) PASS a page in a window of Safari's got the substituted camera: our stream and our one listed camera, native and not frozen")
            return 0
        }
        print("\(tag) FAIL " + problems.joined(separator: "; "))
        return 1
    }

    /// What the run's end and log say against what a substituted camera in Safari's window must leave.
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
        if result["hasMedia"] as? Bool != true {
            problems.append("navigator.mediaDevices.getUserMedia was not there")
            return problems
        }
        if let error = result["error"] as? String { problems.append("getUserMedia threw \(error)") }
        let settings = result["settings"] as? [String: Any] ?? [:]
        if (settings["width"] as? NSNumber)?.intValue != 1280 || (settings["height"] as? NSNumber)?.intValue != 720 {
            problems.append("the track's size was \(settings["width"] ?? "?")×\(settings["height"] ?? "?")")
        }
        if result["label"] as? String != label { problems.append("the track's label was \(result["label"] ?? "none")") }
        if result["native"] as? Bool != true { problems.append("getUserMedia did not print as native code") }
        if result["framesDiffer"] as? Bool != true { problems.append("two frames a moment apart were the same (the picture is frozen)") }
        if (result["cameraCount"] as? NSNumber)?.intValue != 1 { problems.append("enumerateDevices listed \(result["cameraCount"] ?? "?") cameras, not one") }
        if result["cameraLabel"] as? String != label { problems.append("the listed camera's label was \(result["cameraLabel"] ?? "none")") }
        if result["deviceIdHex"] as? Bool != true { problems.append("the camera's deviceId was not a 64-hex, per-origin id") }
        return problems
    }
}
