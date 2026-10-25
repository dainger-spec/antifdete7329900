import AppKit

// Entry point. `--self-test` runs headless end-to-end checks against the real WebKit
// (see SelfTest.swift); otherwise the SwiftUI app starts.
if CommandLine.arguments.contains("--self-test") {
    SelfTest.start()
} else {
    PrivacyBrowserApp.main()
}
