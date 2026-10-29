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
        giveSafarisWebViewsTheProfilesData()
        isPrepared = true
        return true
    }

    /// Every web view Safari's chrome makes for page content is built from a configuration from
    /// one factory. Patched so that the configuration stays Safari's — its preferences, its
    /// process pool, its content controller — while the data store in it is the profile's, and
    /// the profile's scripts are added to it.
    ///
    /// This is the whole point, and it replaces trying to put a web view of ours into Safari's
    /// tab: the chrome navigates, opens tabs, keeps history and shows its start page exactly as
    /// Safari does, and the pages it loads do so with the profile's cookies, storage and proxy.
    private static func giveSafarisWebViewsTheProfilesData() {
        guard let cls = NSClassFromString("WebKitPreferencesManager") else {
            log.notice("No WebKitPreferencesManager: Safari's chrome would load pages with its own data")
            return
        }
        // Opaque arguments and an unmanaged return on purpose. These three factories do not share
        // one signature — one of them takes a BOOL where the others take an object — and letting
        // Swift treat that BOOL as an object would have ARC retain the value 1 and take the
        // process down. Nothing here touches the arguments: they are passed through as the bits
        // they arrived as, and only the configuration that comes back is read.
        typealias Factory = @convention(c) (AnyObject, Selector, Int, OpaquePointer?, OpaquePointer?) -> Unmanaged<AnyObject>?
        var patched = 0
        for selectorName in ["contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:",
                             "contentWebViewConfigurationForBrowsingMode:profileIdentifier:jitEnabled:",
                             "readerWebViewConfigurationForBrowsingMode:profileIdentifier:relatedWebView:"] {
            let selector = NSSelectorFromString(selectorName)
            guard let method = class_getClassMethod(cls, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let replacement: @convention(block) (AnyObject, Int, OpaquePointer?, OpaquePointer?) -> Unmanaged<AnyObject>? = { receiver, mode, second, third in
                let result = original(receiver, selector, mode, second, third)
                if let configuration = result?.takeUnretainedValue() as? WKWebViewConfiguration, let session {
                    session.applyProfile(to: configuration)
                    log.notice("A web view of Safari's chrome got the data of \(session.profileName, privacy: .public)")
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            patched += 1
        }
        if patched == 0 {
            log.notice("None of WebKitPreferencesManager's configuration factories is in this Safari")
        } else {
            log.notice("Safari's web views will be built with the profile's data (\(patched, privacy: .public) factories)")
        }
    }

    /// The profile running in this process. One per process, by construction.
    private static weak var session: BrowserSession?

    /// Opens Safari's window for `session` and puts the profile's web view in its tab. False when
    /// the chrome is not hosted here, and the caller opens our own window as before.
    static func open(session: BrowserSession, url: URL?) -> Bool {
        guard isPrepared else { return false }
        // Registered before the window exists: Safari builds the first web view while opening it,
        // and that web view must already get the profile's data store.
        Self.session = session
        let address = url ?? session.configuration.startURL
        guard let controller = SafariChrome.openWindow(address: address) else {
            log.error("Safari's chrome did not open a window for \(session.profileName, privacy: .public); using ours")
            return false
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        log.notice("\(session.profileName, privacy: .public) runs in Safari's chrome")
        return true
    }
}
