import AppKit
import os
import WebKit

/// Safari's chrome as the window of a profile, in the profile's own process.
///
/// `SafariChrome` can host Safari's window in any process; this is the piece that gives that window
/// a profile's content: a `WKWebView` built from the profile's own configuration — its data store,
/// its proxy, its scripts — put inside Safari's tab. The frame is Safari's, everything behind it
/// is ours.
///
/// Only in a per-profile child process (`ProfileSessionHost`): hosting Safari's chrome needs
/// `NSApp` to be Safari's own application object and the process to have a home of its own, and
/// neither is true of the process that shows the profile list. `PB_SAFARI_CHROME=0` turns it off
/// and the profile opens our own window instead, which is also what happens on a macOS where the
/// private frameworks no longer load.
@MainActor
enum SafariChromeHost {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChromeHost")
    private static var isPrepared = false
    /// The web view of the hosted window, which nothing else retains.
    private static var hostedWebViews: [WKWebView] = []

    static var isTurnedOff: Bool { ProcessInfo.processInfo.environment["PB_SAFARI_CHROME"] == "0" }

    /// Loads Safari's frameworks and makes this process the kind of process its chrome expects.
    /// Must run before anything touches `NSApplication.shared`. False when the chrome is not
    /// available, and then nothing about this process has been changed.
    @discardableResult
    static func prepareForChildProcess() -> Bool {
        guard !isPrepared else { return true }
        guard !isTurnedOff else { return false }
        guard SafariChrome.load() else { return false }
        SafariChrome.installApplication()
        SafariChrome.prepare()
        SafariChrome.installMainMenu()
        isPrepared = true
        return true
    }

    /// Opens Safari's window for `session` and puts the profile's web view in its tab. False when
    /// the chrome is not hosted here, and the caller opens our own window as before.
    static func open(session: BrowserSession, url: URL?) -> Bool {
        guard isPrepared else { return false }
        let webView = WKWebView(frame: .zero, configuration: session.makeWebViewConfiguration())
        webView.customUserAgent = session.configuration.userAgent(hostSafariVersion: HostSafari.version)
        let address = url ?? session.configuration.startURL
        if let address { webView.load(URLRequest(url: address)) }
        guard let controller = SafariChrome.openWindow(embedding: webView, addressText: address?.absoluteString) else {
            log.error("Safari's chrome did not open a window for \(session.profileName, privacy: .public); using ours")
            return false
        }
        hostedWebViews.append(webView)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        log.info("\(session.profileName, privacy: .public) runs in Safari's chrome")
        return true
    }
}
