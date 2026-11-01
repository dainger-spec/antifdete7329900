import AppKit
import os
import ServiceManagement

/// The one place this app asks the system to open something: an address in another app, a file in
/// the Finder, System Settings, the update's installer. Nothing else in the app calls NSWorkspace's
/// opening methods, SMAppService's settings or SwiftUI's `Link` — `scripts/check_system_opens.py`
/// fails CI on any other call.
///
/// Why one place: the owner found "What sites see" opening its page in this Mac's own Safari by
/// itself (1 November). What an app hands to the system leaves every profile: another app fetches
/// it as this Mac, with this Mac's address, cookies and accounts. Each kind of opening is named
/// here with why it is allowed, and a profile's own process is refused all of them: it never
/// hands anything outside its sandbox (the owner's rule), whatever code of its own or Safari's
/// asks — `HandOffs` closes the system's ways around this for Safari's code.
@MainActor
enum SystemOpen {
    enum Purpose: String, Codable, Sendable {
        /// "What sites see": the measuring page in this Mac's Safari, on the person's explicit
        /// "Compare with Safari" — never by itself.
        case compareInSafari
        /// The app's website and support pages (Settings › About).
        case website
        /// A folder of the app's own in the Finder (the vault's, a kept deleted profile's).
        case revealInFinder
        /// System Settings, where network extensions are allowed (the tunnel).
        case systemSettings
        /// The update's installer (this app's own helper).
        case updateInstaller
        /// System Settings › Date & Time: this Mac's clock is off from the account server's
        /// (`clock.skew`, the server's CONTRACT §8.3).
        case dateAndTime
        /// This app again, once it has quit: the interface's language takes a restart.
        case relaunch
    }

    struct Request: Equatable, Sendable {
        let purpose: Purpose
        let target: String
    }

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SystemOpen")

    /// What was asked of this place in this process, refused or not (the self-test reads it).
    private(set) static var requests: [Request] = []
    /// Of those, the ones refused because this is a profile's own process.
    private(set) static var refused = 0
    /// The self-test's stand-in for the system: what this place would hand to the system goes to
    /// it instead, and its answer is this place's. Everything above it is the app's own path.
    static var standIn: ((Purpose, URL) async -> Bool)?

    /// A profile's own process (`ProfileSessionHost`): nothing is opened from it.
    static var isProfileProcess: Bool { CommandLine.arguments.contains("--profile-session") }

    /// Whether `purpose` may go on: noted, and refused in a profile's process.
    private static func admit(_ purpose: Purpose, _ target: String) -> Bool {
        requests.append(Request(purpose: purpose, target: target))
        guard !isProfileProcess else {
            refused += 1
            log.notice("Refused in a profile's process: \(purpose.rawValue, privacy: .public)")
            return false
        }
        return true
    }

    /// The measuring page of "What sites see" in this Mac's Safari, as a new tab of its own.
    static func openInThisMacsSafari(_ url: URL) async -> Bool {
        guard admit(.compareInSafari, url.absoluteString) else { return false }
        if let standIn { return await standIn(.compareInSafari, url) }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return false }
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }

    /// One of the app's own web pages (its website, its support page) in the default browser.
    @discardableResult
    static func openWebsite(_ url: URL) -> Bool {
        guard admit(.website, url.absoluteString) else { return false }
        if let standIn {
            Task { _ = await standIn(.website, url) }
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    /// Folders of the app's own, selected in the Finder.
    static func revealInFinder(_ urls: [URL]) {
        guard admit(.revealInFinder, urls.map(\.path).joined(separator: ", ")) else { return }
        if let standIn, let first = urls.first {
            Task { _ = await standIn(.revealInFinder, first) }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// System Settings where network extensions are allowed: on macOS 15+ General › Login Items &
    /// Extensions, through the documented API; on macOS 14 Privacy & Security, through its URL.
    static func openSystemSettingsForExtensions() {
        guard admit(.systemSettings, "network extensions") else { return }
        if let standIn, let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            Task { _ = await standIn(.systemSettings, url) }
            return
        }
        if #available(macOS 15, *) {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        for candidate in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                          "x-apple.systempreferences:com.apple.preference.security"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// System Settings at Date & Time.
    static func openSystemSettingsForDateAndTime() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") else { return }
        guard admit(.dateAndTime, url.absoluteString) else { return }
        if let standIn {
            Task { _ = await standIn(.dateAndTime, url) }
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Quits the app as ⌘Q does — its profiles stopped and sealed — and opens it again once this
    /// process has ended: a shell waits for it (at most two minutes; a quit that was cancelled
    /// opens nothing), then opens this same app. Where the shell cannot be started (the App
    /// Sandbox), the app only quits: the person opens it again. Returns whether it will reopen.
    @discardableResult
    static func relaunchAfterQuit() -> Bool {
        let app = Bundle.main.bundleURL
        guard admit(.relaunch, app.path) else { return false }
        if let standIn {
            Task { _ = await standIn(.relaunch, app) }
            return true
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "for i in $(seq 1 600); do kill -0 \(pid) 2>/dev/null || exec /usr/bin/open -n \"$0\"; sleep 0.2; done", app.path]
        var reopens = true
        do {
            try waiter.run()
        } catch {
            reopens = false
            log.notice("The app could not be set to open again after it quits: \(error.logKind, privacy: .public)")
        }
        NSApp.terminate(nil)
        return reopens
    }

    /// The update's installer, this app's own helper, started without being brought forward.
    static func startUpdateInstaller(at helper: URL) async throws {
        guard admit(.updateInstaller, helper.path) else { throw CocoaError(.userCancelled) }
        if let standIn {
            _ = await standIn(.updateInstaller, helper)
            return
        }
        let open = NSWorkspace.OpenConfiguration()
        open.activates = false
        open.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: open)
    }
}
