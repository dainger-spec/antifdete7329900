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
        routeNavigationToOurWebViews()
        keepOurWebViewsOnTop()
        isPrepared = true
        return true
    }

    /// Safari's address bar, its bookmarks and its menu all navigate by telling the tab to load a
    /// URL. Left alone, that drives Safari's own web view — the one with Safari's data store, no
    /// proxy of ours and none of the profile's scripts — and the window shows nothing useful,
    /// which is exactly what typing an address did before this. Routed into the profile's web
    /// view instead, so that the chrome drives our engine.
    private static func routeNavigationToOurWebViews() {
        typealias LoadURL = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let selector = NSSelectorFromString("loadURL:")
        guard let cls = NSClassFromString("BrowserTabViewItem"),
              let method = class_getInstanceMethod(cls, selector) else {
            log.notice("No -[BrowserTabViewItem loadURL:]: the address bar will not reach our web view")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: LoadURL.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { tab, url in
            guard let url = url as? URL, let webView = webView(of: tab) else {
                original(tab, selector, url)
                return
            }
            log.notice("\(url.absoluteString, privacy: .public) into the profile's web view")
            webView.load(URLRequest(url: url))
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Safari installs the view of whatever it thinks the tab shows — its start page, its own web
    /// view — into the same place ours sits, and ours ends up underneath. After each of those,
    /// ours is put back on top and resized to fit.
    private static func keepOurWebViewsOnTop() {
        typealias InstallView = @convention(c) (AnyObject, Selector) -> Void
        let selector = NSSelectorFromString("_installCurrentViewControllerView")
        guard let cls = NSClassFromString("TabContentViewController"),
              let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: InstallView.self)
        let replacement: @convention(block) (AnyObject) -> Void = { controller in
            original(controller, selector)
            guard let view = (controller as? NSViewController)?.viewIfLoaded else { return }
            for webView in hostedWebViews where webView.superview === view {
                webView.frame = view.bounds
                view.addSubview(webView, positioned: .above, relativeTo: nil)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The profile's web view in that tab. One profile has one window for now, so the tab the web
    /// view was put into is remembered and anything else falls back to it.
    private static func webView(of tab: AnyObject) -> WKWebView? {
        if let known = webViewsByTab.object(forKey: tab) { return known }
        return hostedWebViews.last
    }

    private static let webViewsByTab = NSMapTable<AnyObject, WKWebView>.weakToStrongObjects()

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
        if let tab = SafariChrome.lastHostedTab { webViewsByTab.setObject(webView, forKey: tab) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        log.notice("\(session.profileName, privacy: .public) runs in Safari's chrome")
        return true
    }
}
