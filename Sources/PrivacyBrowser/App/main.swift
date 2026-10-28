import AppKit

// Entry point. `--self-test` runs headless end-to-end checks against the real WebKit, and the
// `--selftest-*-vault` pair checks App Sandbox container migration (see SelfTest.swift);
// otherwise the SwiftUI app starts.
// Top-level code runs on the main thread; Swift 5 mode does not infer main-actor isolation for it.
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.contains("--self-test") {
        SelfTest.start()
    } else if arguments.contains("--safari-graph-selftest") {
        // The SAFARI_GRAPH spike's own checks (docs/SAFARI_GRAPH_SPIKE.md), apart from the main self-test.
        SelfTest.startSafariGraph()
    } else if arguments.contains("--safari-graph-load-check") {
        // The spike's compatibility gate loads Safari.framework here, in a child, never in the app.
        SafariGraph.runLoadCheck(arguments: arguments)
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
    } else if arguments.contains("--render-ui-snapshots") {
        // The app's screens with sample data, as PNG files for design review (UISnapshots.swift).
        UISnapshots.start(arguments: arguments)
    } else if arguments.contains("--capture-sites") {
        // The app's own start-up, as far as web content can tell: its UI language is set, and the
        // first profile (no proxy) decides the language websites see.
        Localization.applyProcessLanguage()
        WebContentLanguage.decide(nil)
        SiteCapture.start(arguments: arguments)
    } else {
        // Russian by default (English fallback); must be set before AppKit builds its menus.
        Localization.applyProcessLanguage()
        // An instance a launcher of this app started for one profile runs that profile alone
        // (docs/PROCESS_PER_PROFILE.md); any other is the launcher.
        if let assignment = ProfileProcessClient.assignment() {
            ProfileProcessApp.run(assignment)
        }
        PrivacyBrowserApp.main()
    }
}
