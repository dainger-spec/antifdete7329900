import AppKit

// Entry point. `--self-test` runs headless end-to-end checks against the real WebKit, and the
// `--selftest-*-vault` pair checks App Sandbox container migration (see SelfTest.swift);
// otherwise the SwiftUI app starts.
// Top-level code runs on the main thread; Swift 5 mode does not infer main-actor isolation for it.
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.contains("--self-test") {
        SelfTest.start()
    } else if arguments.contains("--selftest-write-vault") {
        SelfTest.migrationStep(write: true)
    } else if arguments.contains("--selftest-read-vault") {
        SelfTest.migrationStep(write: false)
    } else if arguments.contains("--utun-relay") {
        // The packet tunnel's data path on a utun interface, for CI (root; UTunRelayHarness.swift).
        UTunRelayHarness.start(arguments: arguments)
    } else if let index = arguments.firstIndex(of: "--render-app-icon") {
        // The app icon's iconset, drawn from the Lumen mark (AppIcon.swift; scripts/build-app.sh).
        let folder = arguments.indices.contains(index + 1) ? arguments[index + 1] : "AppIcon.iconset"
        exit(AppIcon.writeIconset(to: URL(fileURLWithPath: folder)) ? 0 : 1)
    } else if arguments.contains("--profile-session") {
        // One profile in its own process, started by the manager process (ProfileProcess.swift
        // says why, ProfileSessionHost.swift what it does). Its language, locale and time zone are
        // already in argv and the environment; the profile's key arrives on stdin (ProfileGrant).
        ProfileSessionHost.start(arguments: arguments)
    } else if arguments.contains("--check-safari-chrome") {
        // Which of the private classes and methods the hosted Safari chrome relies on this macOS
        // still has (SafariChrome.expectedPieces): run after a macOS update, and in CI. In a
        // temporary home of its own and held to a closed proxy, as a profile's process is.
        setvbuf(stdout, nil, _IOLBF, 0)
        exit(SafariChrome.checkPieces(arguments: arguments))
    } else if arguments.contains("--safari-chrome") {
        // Safari's own window hosted in this process, with one of our web views in its tab
        // (SafariChrome.swift). Needs a build without the App Sandbox and with library validation
        // off; it exits with a message when the frameworks cannot be loaded. A developer's tool:
        // it runs no profile — no proxy, none of a profile process's locks — so it is refused
        // unless asked for in so many words (PB_DEVELOPER=1).
        guard ProcessInfo.processInfo.environment["PB_DEVELOPER"] == "1" else {
            FileHandle.standardError.write(Data("--safari-chrome is a developer's tool with no proxy and no profile; set PB_DEVELOPER=1 to run it\n".utf8))
            exit(64)
        }
        SafariChrome.startStandalone(arguments: arguments)
    } else if arguments.contains("--selftest-updates") {
        // The update scenarios of docs/UPDATES.md §8, driven by scripts/update_check.py on a CI
        // runner (UpdateSelfTest.swift): they replace this very app with another build.
        UpdateSelfTest.start(arguments: arguments)
    } else if arguments.contains("--render-ui-snapshots") {
        // The app's screens with sample data, as PNG files for design review (UISnapshots.swift).
        UISnapshots.start(arguments: arguments)
    } else if arguments.contains("--what-sites-see-check") {
        // A new profile's "What sites see" snapshot next to this Mac's real Safari, printed (CI;
        // SelfTest.whatSitesSeeCheck).
        Localization.applyProcessLanguage()
        WebContentLanguage.decide(nil)
        SelfTest.whatSitesSeeCheck(arguments: arguments)
    } else if arguments.contains("--capture-sites") {
        // The app's own start-up, as far as web content can tell: its UI language is set, and the
        // first profile (no proxy) decides the language websites see.
        Localization.applyProcessLanguage()
        WebContentLanguage.decide(nil)
        SiteCapture.start(arguments: arguments)
    } else {
        // Russian by default (English fallback); must be set before AppKit builds its menus.
        Localization.applyProcessLanguage()
        PrivacyBrowserApp.main()
    }
}
