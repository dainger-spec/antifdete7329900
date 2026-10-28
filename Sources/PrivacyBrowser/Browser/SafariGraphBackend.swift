import AppKit
import BrowserCore
import Darwin
import os

/// SAFARI_GRAPH spike (docs/SAFARI_GRAPH_SPIKE.md): the compatibility gate that decides, at the
/// moment a profile's window is opened, whether this process can use the system Safari UI frameworks
/// (`Safari.framework` and its siblings) in place of our own WKWebView chrome — and, when it cannot,
/// falls back to the proven WKWebView backend.
///
/// This is the shippable half of the spike: **detection and automatic fallback**. The other half —
/// driving Safari's window controller in our address space — is measured out of process by
/// `scripts/safari_graph/probe.m`, because an Apple-only framework that aborts on an entitlement
/// check must not take the app down. On stock macOS `backend()` returns `.webKitFallback`; the reason
/// is the live `dlopen` error, so the log and the self-test show exactly why.
///
/// Off by default. Only the unsandboxed build (SANDBOX=0) consults the gate, and only when the flag
/// is set: `-PBSafariGraph YES` at launch, `defaults write <bundle id> PBSafariGraph -bool YES`
/// (which a profile's own process also reads), or `--safari-graph`.
@MainActor
enum SafariGraph {
    /// Which rendering backend a window uses.
    enum Backend: Equatable {
        /// The system Safari UI frameworks are loadable and their ABI is present.
        case safariFramework(version: String, binary: String)
        /// Our WKWebView chrome, with the reason the Safari backend was not taken.
        case webKitFallback(reason: String)

        var usesSafariFramework: Bool {
            if case .safariFramework = self { return true }
            return false
        }

        /// A one-line explanation for the log, the self-test and the spike doc.
        var summary: String {
            switch self {
            case let .safariFramework(version, binary):
                return "Safari.framework \(version) loadable (\(binary))"
            case let .webKitFallback(reason):
                return "WKWebView fallback: \(reason)"
            }
        }
    }

    /// The Safari major versions the spike was written and measured against. Any other version is
    /// "not suitable" and falls back, so a macOS update that ships a Safari nobody measured never
    /// silently drives an untested framework ABI.
    static let supportedSafariMajors: Set<Int> = [26]

    /// Whether a Safari version (`CFBundleShortVersionString`, e.g. "26.6.2") is one the spike measured.
    static func isSupported(safariVersion: String) -> Bool {
        guard let major = Int(safariVersion.split(separator: ".").first.map(String.init) ?? "") else { return false }
        return supportedSafariMajors.contains(major)
    }

    /// The new mode is on: the unsandboxed build, with the flag set.
    static var isEnabled: Bool {
        guard !AppEnvironment.isSandboxed else { return false }
        return UserDefaults.standard.bool(forKey: "PBSafariGraph") || CommandLine.arguments.contains("--safari-graph")
    }

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariGraph")
    private static var cached: Backend?

    /// The backend this process uses for new windows: decided once per run, then remembered.
    static func backend() -> Backend {
        if let cached { return cached }
        let decided = evaluate()
        cached = decided
        log.notice("backend: \(decided.summary, privacy: .public)")
        return decided
    }

    /// The decision, from scratch (the self-test calls this; windows use `backend()`).
    /// `forceFallback`, or `PB_SAFARI_GRAPH_FORCE_FALLBACK=1`, takes the fallback deterministically.
    static func evaluate(forceFallback: Bool = false) -> Backend {
        if forceFallback || ProcessInfo.processInfo.environment["PB_SAFARI_GRAPH_FORCE_FALLBACK"] == "1" {
            return .webKitFallback(reason: "forced (PB_SAFARI_GRAPH_FORCE_FALLBACK)")
        }

        // 1. Safari's frameworks assume Safari's bundle, entitlements and sandbox profile: only the
        //    unsandboxed build ever tries them.
        guard !AppEnvironment.isSandboxed else {
            return .webKitFallback(reason: "App Sandbox is on; the Safari backend is unsandboxed-only")
        }

        // 2. The version gate: an unmeasured Safari is not suitable.
        let version = HostSafari.version
        guard isSupported(safariVersion: version) else {
            return .webKitFallback(reason: "Safari \(version) is outside the measured majors \(supportedSafariMajors.sorted())")
        }

        // 3. The framework's binary.
        guard let binary = locateSafariFrameworkBinary() else {
            return .webKitFallback(reason: "Safari.framework not found where Safari keeps it")
        }

        // 4. The load itself, in a child process of this same binary (same signature, same hardened
        //    runtime, so the answer is this app's): a framework whose initializers abort on their own
        //    entitlement checks cannot take this process down, and this process never maps Safari's code.
        let check = loadCheck(binary)
        guard check.loaded else {
            return .webKitFallback(reason: check.detail)
        }

        // 5. The ABI: a framework that loads without any of Safari's browser classes has drifted.
        guard check.hasBrowserClasses else {
            return .webKitFallback(reason: "Safari.framework loaded, but none of \(browserClasses) is in it")
        }
        return .safariFramework(version: version, binary: binary)
    }

    /// Safari's browser-window classes across releases; one of them present means the ABI is here.
    static let browserClasses = ["BrowserWindowController", "BrowserController", "SFBrowserWindowController"]

    private struct LoadCheck {
        var loaded: Bool
        var hasBrowserClasses: Bool
        var detail: String
    }

    /// Runs `PrivacyBrowser --safari-graph-load-check <binary>` and reads its one-line answer.
    private static func loadCheck(_ binary: String) -> LoadCheck {
        guard let executable = Bundle.main.executableURL else {
            return LoadCheck(loaded: false, hasBrowserClasses: false, detail: "no executable to run the load check from")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--safari-graph-load-check", binary]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return LoadCheck(loaded: false, hasBrowserClasses: false, detail: "the load check could not start: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return LoadCheck(loaded: false, hasBrowserClasses: false, detail: "the load check did not finish in 20 s")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(separator: "\n").last(where: { $0.hasPrefix("LOADCHECK ") }).map(String.init) ?? ""
        if process.terminationReason == .uncaughtSignal {
            return LoadCheck(loaded: false, hasBrowserClasses: false,
                             detail: "loading it killed the checking process (signal \(process.terminationStatus))")
        }
        if line.hasPrefix("LOADCHECK ok") {
            let classes = line.components(separatedBy: "classes=").last ?? ""
            return LoadCheck(loaded: true, hasBrowserClasses: !classes.isEmpty, detail: line)
        }
        let prefix = "LOADCHECK fail "
        let reason = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : "no answer (exit \(process.terminationStatus))"
        return LoadCheck(loaded: false, hasBrowserClasses: false, detail: "dlopen refused: \(reason)")
    }

    /// `PrivacyBrowser --safari-graph-load-check <binary>`: the child side of `loadCheck`. Loads
    /// `binary` here and prints one line: `LOADCHECK ok classes=…` or `LOADCHECK fail <dlerror>`.
    static func runLoadCheck(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--safari-graph-load-check"), arguments.indices.contains(index + 1) else {
            print("LOADCHECK fail no binary given")
            exit(2)
        }
        let binary = arguments[index + 1]
        _ = dlerror()
        guard dlopen(binary, RTLD_NOW | RTLD_LOCAL) != nil else {
            let message = dlerror().map { String(cString: $0) } ?? "no dlerror text"
            print("LOADCHECK fail \(message)")
            exit(1)
        }
        let present = browserClasses.filter { NSClassFromString($0) != nil }
        print("LOADCHECK ok classes=\(present.joined(separator: ","))")
        exit(0)
    }

    /// Where Safari.framework has lived: the staged framework (in the app cryptex since macOS 13),
    /// and Safari.app's own Frameworks folder. The first Mach-O that exists.
    static func locateSafariFrameworkBinary() -> String? {
        var roots = [
            "/System/Library/StagedFrameworks/Safari/Safari.framework",
            "/System/Cryptexes/App/System/Library/StagedFrameworks/Safari/Safari.framework",
        ]
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            roots.append(safari.appendingPathComponent("Contents/Frameworks/Safari.framework").path)
        }
        for root in roots {
            for layout in ["Safari", "Versions/Current/Safari", "Versions/A/Safari"] {
                let binary = "\(root)/\(layout)"
                if FileManager.default.fileExists(atPath: binary) { return binary }
            }
        }
        return nil
    }

    /// A profile window in the new mode: Safari's when the gate passes, else ours. Returns the
    /// window and the backend decided for it.
    @discardableResult
    static func openWindow(for session: BrowserSession, url: URL?) -> (controller: BrowserWindowController, backend: Backend) {
        let decided = backend()
        if decided.usesSafariFramework {
            // The in-process Safari window is what the spike measures (probe.m); it is not built, so a
            // passing gate still renders in WKWebView, and the log says so.
            log.notice("Safari.framework is loadable here, but the in-process Safari window is not built; WKWebView renders")
        }
        return (session.openWindow(url: url), decided)
    }

    /// A profile's first window, as both launch paths open it: through the gate in the new mode,
    /// exactly as before otherwise.
    @discardableResult
    static func openFirstWindow(for session: BrowserSession, url: URL?) -> BrowserWindowController {
        guard isEnabled else { return session.openWindow(url: url) }
        return openWindow(for: session, url: url).controller
    }
}
