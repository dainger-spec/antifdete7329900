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
    } else {
        // Russian by default (English fallback); must be set before AppKit builds its menus.
        Localization.applyProcessLanguage()
        Log.start()
        PrivacyBrowserApp.main()
    }
}
