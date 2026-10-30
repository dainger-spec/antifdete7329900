import AppKit
import BrowserCore
import Foundation
import OSLog

/// Settings → Diagnostics: a ZIP for support and a short report to paste into a message — what a
/// support person asks first, without what is the user's own.
///
/// In the ZIP: the short report (versions, macOS, this Mac's Safari and WebKit, the checks the app
/// makes of itself), the state (settings, and the profiles by number: running or not, the kind of
/// connection and what their settings are), the app's log of this run and, where the build can
/// read the system's log, the last half hour of the app's, its profiles' processes' and WebKit's.
/// Never in it: a profile's name, tags or notes, a proxy's address or credentials, passwords,
/// cookies, history, addresses visited, request or response bodies. The log keeps the user's data
/// private as it is written (`privacy: .private`, checked by scripts/check_log_privacy.py), and
/// the self-test searches a bundle's bytes for what must not be there. Nothing is sent: the ZIP
/// goes where the person saves it.
@MainActor
enum Diagnostics {
    /// One check the app makes of itself; `passed` nil: a fact, not a check.
    struct Check: Equatable {
        var passed: Bool?
        var text: String
    }

    /// What the report and the state are made from, gathered once.
    struct Snapshot {
        struct Profile {
            var number: Int
            var state: String
            var configuration: ProfileConfiguration?
        }
        var profiles: [Profile] = []
        var proxies: [ProxyListEntry] = []
        var vault: String
        var updates: String
        var tunnel: String
        var settings: [String: Any] = [:]
    }

    // MARK: What is gathered

    /// The app as it is now.
    static func snapshot(model: AppModel) -> Snapshot {
        let vault: String
        switch model.phase {
        case .setup: vault = "not set up"
        case .locked: vault = "locked"
        case .unlocked: vault = "unlocked"
        }
        var snapshot = Snapshot(vault: vault, updates: describe(model.updater?.state), tunnel: describe(TunnelManager.shared.state))
        snapshot.profiles = model.profiles.enumerated().map { index, profile in
            let state = model.isBusy(profile.id) ? "starting or encrypting" : model.isRunning(profile.id) ? "running" : "stopped"
            return Snapshot.Profile(number: index + 1, state: state, configuration: try? model.configuration(for: profile.id))
        }
        snapshot.proxies = model.proxyList?.entries ?? []
        snapshot.settings = settings(model.settings)
        return snapshot
    }

    /// The profiles of `repository` (the self-test's), none running.
    static func snapshot(repository: ProfileRepository) -> Snapshot {
        var snapshot = Snapshot(vault: "unlocked", updates: "not asked", tunnel: describe(TunnelManager.shared.state))
        snapshot.profiles = repository.list().enumerated().map { index, profile in
            Snapshot.Profile(number: index + 1, state: "stopped", configuration: try? repository.loadConfiguration(profile.id))
        }
        return snapshot
    }

    /// The checks the app can make of itself here and now.
    static func checks(_ snapshot: Snapshot) async -> [Check] {
        await ContentRules.prepare()
        var checks: [Check] = [
            Check(passed: ContentRules.proxiedProfileRules != nil, text: "Rule list of profiles with a proxy compiled (pings, dns-prefetch, this Mac)"),
            Check(passed: ContentRules.localNetworkRules != nil, text: "Rule list of profiles that protect their local requests compiled"),
            Check(passed: nil, text: "Vault: \(snapshot.vault); profiles: \(snapshot.profiles.count), running: \(snapshot.profiles.filter { $0.state == "running" }.count)"),
        ]
        let working = snapshot.proxies.filter { $0.lastCheck?.isAlive == true }.count
        checks.append(Check(passed: nil, text: "Proxies in the list: \(snapshot.proxies.count), working at their last check: \(working)"))
        checks.append(Check(passed: nil, text: "Packet tunnel (WebRTC through SOCKS5): \(snapshot.tunnel)"))
        checks.append(Check(passed: nil, text: "Updates: \(snapshot.updates)"))
        checks.append(Check(passed: nil, text: "Profiles in processes of their own: \(ProfileProcess.isEnabled ? "on" : "off")"))
        checks.append(Check(passed: nil, text: "Language websites see this run: \(WebContentLanguage.decided?.first ?? "not decided yet")"))
        return checks
    }

    /// Version, macOS, this Mac's Safari and WebKit, and the checks, as text to paste.
    static func shortReport(_ snapshot: Snapshot, checks: [Check]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var lines = [
            "PrivacyBrowser \(version), \(AppEnvironment.isSandboxed ? "App Sandbox" : "without the App Sandbox")",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(machine), \(ProcessInfo.processInfo.activeProcessorCount) cores",
            "Safari \(HostSafari.version), WebKit \(WebKitBuild.version)",
            "",
        ]
        for check in checks {
            let mark = check.passed.map { $0 ? "✓" : "✗" } ?? "·"
            lines.append("\(mark) \(check.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The settings, and each profile by number: what its settings are, never what is its own.
    static func state(_ snapshot: Snapshot, checks: [Check]) -> Data {
        let profiles: [[String: Any]] = snapshot.profiles.map { profile in
            var entry: [String: Any] = ["number": profile.number, "state": profile.state]
            guard let c = profile.configuration else {
                entry["settings"] = "could not be read"
                return entry
            }
            entry["connection"] = c.proxy.map { $0.kind.rawValue } ?? "direct"
            if let proxy = c.proxy {
                let listed = snapshot.proxies.first { ProxyList.sameConnection($0.proxy, proxy) }
                entry["proxyLastCheck"] = listed?.lastCheck.map { $0.isAlive ? "working" : "not working" } ?? "not checked"
                entry["proxyHasCredentials"] = proxy.username != nil
            }
            entry["ephemeral"] = c.ephemeral
            entry["generation"] = c.deviceGeneration.id
            entry["userAgent"] = c.userAgent == nil ? (c.safariVersion.map { "Safari \($0)" } ?? "this Mac's Safari") : "typed"
            entry["windowSize"] = describe(c.windowSize)
            entry["localRequests"] = c.localRequests.rawValue
            entry["timeZoneAndLanguage"] = c.effectiveLocaleSource.rawValue
            entry["webRTC"] = c.effectiveWebRTCPolicy.rawValue
            entry["searchEngine"] = (c.searchEngine ?? .standard).rawValue
            entry["history"] = c.historyEnabled
            entry["syncCookies"] = c.syncsCookies
            entry["tags"] = c.tags.count
            entry["hasNotes"] = !c.notes.isEmpty
            return entry
        }
        let object: [String: Any] = [
            "checks": checks.map { ["passed": $0.passed.map { $0 ? "yes" : "no" } ?? "fact", "text": $0.text] },
            "settings": snapshot.settings,
            "profiles": profiles,
            "proxyList": ["count": snapshot.proxies.count,
                          "typeUnknown": snapshot.proxies.filter { !$0.kindKnown }.count,
                          "working": snapshot.proxies.filter { $0.lastCheck?.isAlive == true }.count],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// This process's log since it started: the app's own lines and WebKit's in this process, as
    /// they were written — what is the user's is `<private>` there.
    static func appLog(limit: Int = 20_000) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem BEGINSWITH %@ OR subsystem BEGINSWITH %@", "PrivacyBrowser", "com.apple.WebKit")
            let entries = try store.getEntries(matching: predicate)
            var lines: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                lines.append("\(log.date.formatted(.iso8601)) \(level(log.level)) \(log.subsystem) [\(log.category)] \(log.composedMessage)")
            }
            return lines.suffix(limit).joined(separator: "\n") + "\n"
        } catch {
            return "This process's log could not be read: \(error.localizedDescription)\n"
        }
    }

    /// The system's log of the last `minutes`: the app's, its profiles' processes' and WebKit's.
    /// Only a build without the App Sandbox can read it; a sandboxed one says how to.
    static func systemLog(minutes: Int) async -> String {
        let predicate = #"subsystem BEGINSWITH "PrivacyBrowser" OR subsystem BEGINSWITH "com.apple.WebKit" OR process BEGINSWITH "com.apple.WebKit""#
        guard !AppEnvironment.isSandboxed else {
            return """
            The App Sandbox does not let the app read the system's log. To add it, run in Terminal:
            log show --last \(minutes)m --style compact --predicate '\(predicate)' > webkit-log.txt

            """
        }
        return await run("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "compact", "--predicate", predicate],
                         timeout: 90)
    }

    /// `--check-safari-chrome` in a process of its own (it loads Safari's frameworks, which this
    /// one must not): the private pieces Safari's hosted window relies on, present or not.
    static func safariChromeCheck() async -> String? {
        guard !AppEnvironment.isSandboxed, let executable = Bundle.main.executableURL else { return nil }
        return await run(executable.path, ["--check-safari-chrome"], timeout: 60)
    }

    // MARK: The bundle

    /// The ZIP, as saved: the report, the state, the logs.
    static func bundle(_ snapshot: Snapshot, logMinutes: Int = 30) async -> Data {
        let checks = await checks(snapshot)
        let report = shortReport(snapshot, checks: checks)
        var entries = [
            StoredZip.Entry(path: "report.txt", data: Data(report.utf8)),
            StoredZip.Entry(path: "state.json", data: state(snapshot, checks: checks)),
            StoredZip.Entry(path: "logs/this-run.txt", data: Data(appLog().utf8)),
            StoredZip.Entry(path: "logs/system-last-\(logMinutes)-minutes.txt", data: Data(await systemLog(minutes: logMinutes).utf8)),
        ]
        if let chrome = await safariChromeCheck() {
            entries.append(StoredZip.Entry(path: "safari-chrome.txt", data: Data(chrome.utf8)))
        }
        entries.append(StoredZip.Entry(path: "README.txt", data: Data(readme.utf8)))
        return (try? StoredZip.archive(entries)) ?? Data()
    }

    /// "PrivacyBrowser-Diagnostics-2026-10-30-1015.zip".
    static func suggestedFileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "PrivacyBrowser-Diagnostics-\(formatter.string(from: date)).zip"
    }

    static let readme = """
    PrivacyBrowser diagnostics, for support.

    report.txt      the version, macOS, this Mac's Safari and WebKit, and the app's checks of itself
    state.json      the settings, and the profiles by number: running or not, the kind of connection
                    and what their settings are
    logs/           this run's log, and the system's log of the last minutes where the build can read it

    Not in it: profiles' names, tags and notes, proxies' addresses and credentials, passwords,
    cookies, history, addresses visited, request and response bodies. In the logs, what is the
    user's appears as <private>. Nothing was sent: send this file to support yourself.

    """

    // MARK: Helpers

    private static func settings(_ settings: AppSettings) -> [String: Any] {
        [
            "startup": settings.startup.rawValue,
            "confirmQuit": settings.confirmQuit,
            "newProfiles": ["fromTheConnection": settings.newProfileMatchesConnection,
                            "searchEngine": settings.newProfileSearchEngine.rawValue,
                            "randomWindowSize": settings.newProfileRandomWindowSize,
                            "blockLocalRequests": settings.newProfileBlocksLocalRequests],
            "proxyFailure": settings.proxyFailure.rawValue,
            "browsing": ["passwordAutoFill": settings.browsing.passwordAutoFill,
                         "newTabsNextToCurrent": settings.browsing.newTabsNextToCurrent,
                         "warnClosingTabs": settings.browsing.warnClosingTabs,
                         "pageZoom": settings.browsing.pageZoom,
                         "downloadFolder": settings.browsing.downloadFolder == nil ? "Downloads" : "another folder",
                         "askWhereToSave": settings.browsing.askWhereToSave,
                         "dockInitials": settings.browsing.dockInitials,
                         "restoreTabs": settings.browsing.restoreTabs],
            "profilesInOwnProcesses": ProfileProcess.isEnabled,
        ]
    }

    private static func describe(_ state: UpdateState?) -> String {
        switch state {
        case nil: return "not available"
        case .idle?: return "not asked yet"
        case let .upToDate(date)?: return "up to date (asked \(date.formatted(.iso8601)))"
        case .checking?: return "checking"
        case let .available(item)?: return "\(item.version) available"
        case let .downloading(item)?: return "downloading \(item.version)"
        case let .ready(item)?: return "\(item.version) ready to install"
        case let .blocked(item, block)?: return "\(item.version) blocked: \(block)"
        case let .failed(reason)?: return "last check failed: \(reason)"
        }
    }

    private static func describe(_ state: TunnelManager.State) -> String {
        switch state {
        case .notBuilt: return "not in this build"
        case .checking: return "checking"
        case .off: return "off"
        case .awaitingApproval: return "waiting for the user to allow it"
        case .needsConfiguration: return "allowed, no VPN configuration"
        case .ready: return "ready"
        case .connected: return "connected"
        case let .failed(reason): return "failed: \(reason)"
        }
    }

    private static func describe(_ size: WindowSize?) -> String {
        switch size {
        case nil: return "as it is"
        case let .mac(screen)?: return screen.rawValue
        case let .custom(width, height)?: return "\(width)x\(height)"
        }
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "-"
        }
    }

    /// "arm64", "x86_64".
    private static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A tool's output (at most 20 MB), or why there is none.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> String {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                return "\(path) did not start: \(error.localizedDescription)\n"
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data.prefix(20 * 1024 * 1024), as: UTF8.self)
            return text + (process.terminationStatus == 0 ? "" : "\n(\(path) ended with \(process.terminationStatus))\n")
        }.value
    }
}
