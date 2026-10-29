import AppKit
import Network
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
    /// This process hosts Safari's chrome: its windows are Safari's own.
    static var isHosting: Bool { isPrepared }

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
        everyWebViewGetsTheProfilesData()
        theDefaultStoreIsTheProfiles()
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
                if let configuration = result?.takeUnretainedValue() as? WKWebViewConfiguration {
                    give(configuration, builtBy: "a configuration factory of Safari's")
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

    /// Every web view built in this process is built with the profile's data, whoever built it.
    ///
    /// The factories above are Safari's usual way of making a configuration, but they are not the
    /// only way, and a web view built by a path they do not cover would be built with a store of
    /// Safari's own — a store with no proxy, so the page would see this Mac's own address. That is
    /// the one failure this product may not have, so the profile is given at the last moment
    /// before the web view exists, in the initializer every web view goes through, and what the
    /// web view ended up with is read back and logged.
    private static func everyWebViewGetsTheProfilesData() {
        let selector = NSSelectorFromString("initWithFrame:configuration:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            log.error("WKWebView's initializer is not where it was: a web view of Safari's chrome could load outside the profile's proxy")
            return
        }
        // The configuration is an object, so ARC may hold it; the web view that comes back is
        // passed on exactly as it came, because an initializer hands over ownership of it.
        typealias Initializer = @convention(c) (AnyObject, Selector, CGRect, AnyObject?) -> Unmanaged<AnyObject>?
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: @convention(block) (AnyObject, CGRect, AnyObject?) -> Unmanaged<AnyObject>? = { receiver, frame, configuration in
            if let configuration = configuration as? WKWebViewConfiguration {
                give(configuration, builtBy: "a web view being built")
            }
            let result = original(receiver, selector, frame, configuration)
            if let webView = result?.takeUnretainedValue() as? WKWebView {
                report(webView)
            }
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        log.notice("Every web view of this process will be built with the profile's data")
    }

    /// `+[WKWebsiteDataStore defaultDataStore]` answers with the profile's store in this process.
    ///
    /// The other half of the same problem: where Safari's chrome does not take the store from the
    /// configuration we handed it but asks WebKit for "the default one", that default is a store
    /// of Safari's with no proxy. Here it is the profile's, so there is no such thing in this
    /// process as a store that goes straight out.
    private static func theDefaultStoreIsTheProfiles() {
        let selector = NSSelectorFromString("defaultDataStore")
        guard let method = class_getClassMethod(WKWebsiteDataStore.self, selector) else {
            log.error("WKWebsiteDataStore's default store is not where it was: Safari's chrome could load outside the profile's proxy")
            return
        }
        let replacement: @convention(block) (AnyObject) -> WKWebsiteDataStore = { _ in
            session?.dataStore ?? closedStore
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        log.notice("The default website data store of this process is the profile's")
    }

    /// Gives `configuration` the profile's data store and scripts. With no profile yet — nothing
    /// should be built then, and if something is, it must not reach the network as this Mac — the
    /// configuration gets a store nothing can load through.
    private static func give(_ configuration: WKWebViewConfiguration, builtBy origin: String) {
        guard let session else {
            log.error("\(origin, privacy: .public) before the profile was ready: it gets a store that loads nothing")
            configuration.websiteDataStore = closedStore
            return
        }
        session.applyProfile(to: configuration)
    }

    /// What a finished web view actually holds: the store it got, and how many proxies that store
    /// carries. `proxies=0` in a profile that has a proxy is a leak, and this is where it shows.
    private static func report(_ webView: WKWebView) {
        let store = webView.configuration.websiteDataStore
        let proxies = store.proxyConfigurations.count
        let isProfiles = session?.dataStore === store
        let wanted = session?.configuration.proxy != nil
        if !isProfiles || (wanted && proxies == 0) {
            log.error("A web view of Safari's chrome did NOT get the profile's data: profile's store=\(isProfiles, privacy: .public) proxies=\(proxies, privacy: .public) profile has a proxy=\(wanted, privacy: .public)")
        } else {
            log.notice("A web view of \(session?.profileName ?? "?", privacy: .public) is up: proxies=\(proxies, privacy: .public)")
        }
    }

    /// A store nothing can load through: non-persistent, pointed at a proxy that does not exist,
    /// with failover off, so every load through it fails instead of going out as this Mac.
    private static let closedStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.nonPersistent()
        var dead = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 1))
        dead.allowFailover = false
        store.proxyConfigurations = [dead]
        return store
    }()

    /// The profile running in this process. One per process, by construction.
    private static weak var session: BrowserSession?

    /// The profile whose data every web view of this process is built with. Registered as soon as
    /// the session exists — before any window, because a profile may be launched to be warmed up
    /// and never get one, and its robot's web views need the profile's store just the same.
    static func register(session: BrowserSession) {
        guard isPrepared else { return }
        Self.session = session
    }

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
