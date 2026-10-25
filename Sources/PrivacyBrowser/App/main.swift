import AppKit

// Entry point. `--self-test` runs headless end-to-end checks against the real WebKit
// (see SelfTest.swift); otherwise the SwiftUI app starts.
// Top-level code runs on the main thread; Swift 5 mode does not infer main-actor isolation for it.
MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--self-test") {
        SelfTest.start()
    } else {
        PrivacyBrowserApp.main()
    }
}
