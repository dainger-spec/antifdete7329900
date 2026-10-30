import AppKit
import BrowserCore
import Foundation
import os
import UpdateInstaller

// PrivacyBrowser Updater: Contents/Helpers/PrivacyBrowser Updater.app inside the app
// (docs/UPDATES.md §3). The app starts it through LaunchServices at the end of a quit in which every
// profile was sealed — so it is not a child of the app, and not in the app's sandbox — and it
// replaces the app it is in with the release the app's request names. It takes no arguments and
// makes no network request; what it installs is only what checks with the keys of the installed
// app's own signed Info.plist.

let log = Logger(subsystem: "PrivacyBrowser", category: "Updater")

/// The app this helper is in: three folders up from its own bundle.
let helper = Bundle.main.bundleURL.standardizedFileURL
let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard helper.deletingLastPathComponent().lastPathComponent == "Helpers", app.pathExtension == "app",
      let identifier = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String else {
    log.error("Not inside an app's Contents/Helpers: \(helper.path, privacy: .private)")
    exit(2)
}

/// The user's own home (the staging folder is in it, outside every container).
let home: URL = {
    if let directory = getpwuid(getuid())?.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}()
let staging = UpdateStaging.folder(bundleIdentifier: identifier, home: home)

// One helper at a time: a second start while one waits does nothing.
let lock = open(staging.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
    log.notice("Another updater is already at work, or there is nothing to install")
    exit(0)
}

let environment = Installer.Environment(
    processes: { BundleProcess.running(inside: $0) },
    launch: { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    },
    sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
    now: { Date() },
    system: BuildVersion(ProcessInfo.processInfo.operatingSystemVersion))

Task {
    let outcome = await Installer(app: app, staging: staging, environment: environment).run()
    log.notice("Update: \(outcome.result.rawValue, privacy: .public), \(outcome.fromBuild, privacy: .private) → \(outcome.toBuild, privacy: .private): \(outcome.detail, privacy: .private)")
    exit(outcome.result == .installed ? 0 : 1)
}
dispatchMain()
