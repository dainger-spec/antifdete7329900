import AppKit
import BrowserCore
import os
import WebKit

/// One running profile: its isolated `WKWebsiteDataStore`, its decrypted library (history,
/// bookmarks), and all of its windows and tabs.
///
/// ISOLATION MODEL (native WebKit, macOS 14+):
///   * Persistent profiles use `WKWebsiteDataStore(forIdentifier: profileID)`. WebKit keeps
///     cookies, localStorage/sessionStorage, IndexedDB, Cache API, service workers, the HTTP
///     disk cache, HSTS state, and credentials for that store separately from every other
///     store, and serves it through a separate network *session*.
///   * Ephemeral profiles use `WKWebsiteDataStore.nonPersistent()` (in-memory only).
///   * Every web view of this profile — every tab of every window, and `window.open` popups,
///     which WebKit creates from the opener's configuration — uses this data store.
///
/// PLATFORM LIMITATIONS:
///   * All profiles share one WebKit networking process (separate sessions inside it). This
///     is session isolation, not OS-level process/user isolation.
///   * FINGERPRINTING: the host machine's fingerprintable surface (fonts, screen size and
///     colour depth, GPU / WebGL renderer and parameters, canvas and audio rasterisation,
///     `hardwareConcurrency`, languages, TLS/HTTP2 fingerprint) is identical across all
///     profiles, because WKWebView has no public API to change it. A site that fingerprints
///     the device can link profiles to each other even though their storage and IP differ.
@MainActor
final class BrowserSession {
    let profileID: UUID
    let profileName: String
    let configuration: ProfileConfiguration
    let passwordVault: PasswordVault
    let passwordSettings: ProfilePasswordSettings
    let library: ProfileLibrary
    var onAllWindowsClosed: (() -> Void)?
    /// Where this run's proxy exits (the launch's lookup, or what was remembered for the proxy),
    /// shown in its windows' chrome; set again when a lookup finishes after launch.
    var exitLocation: ProxyLocation? {
        didSet { windows.forEach { $0.exitLocationDidChange() } }
    }

    private(set) var dataStore: WKWebsiteDataStore?
    private let userContentController: WKUserContentController
    /// Receives the AutoFill script's messages (registered in its own content world only).
    private let passwordHandler = PasswordAutoFillHandler()
    private var windows: [BrowserWindowController] = []
    private var libraryWindow: LibraryWindowController?
    private var isClosing = false

    /// Throws when the profile's proxy cannot be applied — before any data store exists, so a
    /// profile with a broken proxy never starts on a direct connection (fail-closed).
    init(profileID: UUID, profileName: String, configuration: ProfileConfiguration,
         passwordVault: PasswordVault, passwordSettings: ProfilePasswordSettings, library: ProfileLibrary) throws {
        let proxies = try ProxyConfigurationFactory.make(configuration.proxy)
        self.profileID = profileID
        self.profileName = profileName
        self.configuration = configuration
        self.passwordVault = passwordVault
        self.passwordSettings = passwordSettings
        self.library = library

        // `.nonPersistent()` needs WebKit initialized but does not initialize it, and an ephemeral
        // profile can be the first WebKit use after unlock (see `ensureWebKitInitialized`).
        WebDataStoreVault.ensureWebKitInitialized()
        let store: WKWebsiteDataStore = configuration.ephemeral
            ? .nonPersistent()
            : WebDataStoreVault.makeStore(for: profileID)
        // Applies to all network loads of this data store. Empty only when no proxy is configured.
        store.proxyConfigurations = proxies
        self.dataStore = store
        // Routed through BehaviorSets so a profile's device generation selects its script bundle.
        self.userContentController = BehaviorSets.makeUserContentController(for: configuration)
        if configuration.proxy != nil {
            // Loads WebKit would otherwise make outside the proxy (see ContentRules).
            if let blocker = ContentRules.dnsPrefetchBlocker {
                userContentController.add(blocker)
            } else {
                Logger(subsystem: "PrivacyBrowser", category: "BrowserSession")
                    .error("No ping-load blocker: dns-prefetch of this profile may resolve outside its proxy")
            }
        }
        passwordHandler.session = self
        PasswordAutoFill.install(in: userContentController, handler: passwordHandler,
                                 testHooks: CommandLine.arguments.contains("--self-test"))
    }

    var windowCount: Int { windows.count }

    /// The profile's browser windows (self-test hook).
    var windowControllers: [BrowserWindowController] { windows }

    var tabContext: BrowserTabContext {
        BrowserTabContext(profileName: profileName, userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version),
                          passwordVault: passwordVault, passwordSettings: passwordSettings, library: library,
                          proxyCredential: configuration.proxy.flatMap { proxy in
                              proxy.username.map { URLCredential(user: $0, password: proxy.password ?? "", persistence: .forSession) }
                          })
    }

    /// Applies this profile to a `WKWebViewConfiguration` that Safari's chrome built for one of
    /// its own web views (`SafariChromeHost`): the profile's data store — which carries its proxy,
    /// since the proxy is set on the store — and, into Safari's own content controller, the
    /// profile's scripts, its DNS-prefetch blocker and its AutoFill.
    ///
    /// Safari's content controller is kept rather than replaced with ours: it holds the scripts
    /// Safari injects into every page it shows, and the point of hosting its chrome is that pages
    /// see what they would see in Safari. Ours are added to it. AutoFill is installed the same way
    /// it is installed in our own web views — its message handlers cannot be copied from one
    /// controller to another (WebKit has no API that lists them), so they are installed again
    /// here, which is why this is a method of the session and not a copy loop somewhere else.
    func applyProfile(to webConfiguration: WKWebViewConfiguration) {
        if let dataStore { webConfiguration.websiteDataStore = dataStore }
        let controller = webConfiguration.userContentController
        // Safari reuses a configuration's controller across the web views of a tab; everything
        // below would otherwise be injected again on each of them.
        guard appliedControllers.add(controller) else { return }
        // Built fresh rather than copied from our own controller: ours also carries AutoFill, and
        // that is installed below with its handlers rather than as a lone script.
        for script in BehaviorSets.makeUserContentController(for: configuration).userScripts {
            controller.addUserScript(script)
        }
        if configuration.proxy != nil, let blocker = ContentRules.dnsPrefetchBlocker {
            controller.add(blocker)
        }
        PasswordAutoFill.install(in: controller, handler: passwordHandler,
                                 testHooks: CommandLine.arguments.contains("--self-test"))
        Logger(subsystem: "PrivacyBrowser", category: "BrowserSession")
            .notice("Profile scripts and AutoFill installed into a content controller of Safari's chrome")
    }

    /// Content controllers this profile has already been applied to, held weakly.
    private let appliedControllers = WeakSet()

    /// A set that does not keep what it remembers alive, so that a controller Safari released is
    /// not applied to a second time by mistake and is not kept in memory either.
    private final class WeakSet {
        private let table = NSHashTable<AnyObject>.weakObjects()
        /// True when `object` was not in the set and has been added.
        func add(_ object: AnyObject) -> Bool {
            guard !table.contains(object) else { return false }
            table.add(object)
            return true
        }
    }

    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let webConfiguration = WKWebViewConfiguration()
        if let dataStore { webConfiguration.websiteDataStore = dataStore }
        webConfiguration.userContentController = userContentController
        // Safe Browsing lookups bypass the per-profile proxy; opt-in per profile.
        webConfiguration.preferences.isFraudulentWebsiteWarningEnabled = configuration.safeBrowsingEnabled
        // Popups only in response to a user gesture.
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // As Safari: the Fullscreen API is available (a WKWebView has it off by default, which a
        // page sees as document.fullscreenEnabled === undefined).
        webConfiguration.preferences.isElementFullscreenEnabled = true
        // As Safari: pages see the system's fonts only, not the ones the user installed (a WKWebView
        // shows those by default, and a font list is among the strongest fingerprints). There is no
        // public switch; this is the WKPreferences property Safari turns off, set only when this
        // WebKit has it.
        WebKitPreferences.setBool(webConfiguration.preferences, "_setShouldAllowUserInstalledFonts:", false)
        // WebRTC off (the default, and with a proxy the tunnel cannot carry: `webRTCRouting`) is switched off
        // in the engine, as Lockdown Mode does: no RTC interface in any frame, nothing for a page to
        // reach before the shim runs. The shim's removal stays as the fallback for a WebKit without
        // this WKPreferences property.
        if configuration.effectiveWebRTCPolicy == .disabled {
            WebKitPreferences.setBool(webConfiguration.preferences, "_setPeerConnectionEnabled:", false)
        }
        // WebRTC through the packet tunnel: libwebrtc gathers on the tunnel interface for the relay
        // addresses (measured with a utun in CI; the tunnel's enforced routes are a second line).
        // For the hardware checks in docs/TUNNEL.md it can also be made to gather on every
        // interface: `defaults write <bundle id> PBTunnelAllInterfaces -bool YES`.
        if case .relay = configuration.webRTCRouting, UserDefaults.standard.bool(forKey: "PBTunnelAllInterfaces") {
            WebKitPreferences.setBool(webConfiguration.preferences, "_setEnumeratingAllNetworkInterfacesEnabled:", true)
        }
        return webConfiguration
    }

    // MARK: Windows

    @discardableResult
    func openWindow(url: URL?) -> BrowserWindowController {
        let controller = BrowserWindowController(session: self)
        windows.append(controller)
        controller.showWindow(nil)
        controller.addTab(url: url)
        return controller
    }

    /// A window for the warm-up robot: a real window with a real tab, because WebKit only loads,
    /// scrolls and runs scripts for content that is in one, but placed far off every screen so the
    /// user never sees it and it never takes focus. Closed when the run ends.
    ///
    /// Not an off-screen `WKWebView` without a window: WebKit suspends rendering and throttles
    /// timers for a view that is in no window, and a warm-up that does not render is not a warm-up
    /// — the sites it visits are exactly the ones that measure it.
    @discardableResult
    func openOffscreenWindow() -> BrowserWindowController {
        let controller = BrowserWindowController(session: self)
        windows.append(controller)
        if let window = controller.window {
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior.insert(.stationary)
            window.orderFront(nil)
        }
        controller.addTab(url: URL(string: "about:blank"))
        return controller
    }

    /// Opens `url` in a new tab of this profile's frontmost window (or a new window).
    func openInNewTab(_ url: URL) {
        if let controller = frontmostWindow {
            controller.addTab(url: url)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(url: url)
        }
    }

    /// The profile's window nearest the front (the warm-up robot opens its tab there).
    var frontmostWindow: BrowserWindowController? {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        return ordered.first { controller in windows.contains { $0 === controller } } ?? windows.last
    }

    /// The tab showing `webView`, in any window of this profile.
    func tab(for webView: WKWebView) -> BrowserTab? {
        for controller in windows {
            if let tab = controller.tabs.first(where: { $0.webView === webView }) { return tab }
        }
        return nil
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        if windows.isEmpty && !isClosing {
            onAllWindowsClosed?()
        }
    }

    func bringToFront() {
        frontmostWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Library window

    func showLibrary(_ section: LibraryView.Section, from controller: BrowserWindowController? = nil) {
        if libraryWindow == nil {
            libraryWindow = LibraryWindowController(session: self) { [weak self] url in
                self?.openInNewTab(url)
            } onClose: { [weak self] in
                self?.libraryWindow = nil
            }
        }
        libraryWindow?.show(section)
    }

    // MARK: Shutdown

    /// Closes every window, writes pending history, and drops this session's reference to the
    /// data store so that WebKit can release the store's network session (precondition for
    /// sealing it).
    func shutDown() {
        guard !isClosing else { return } // idempotent: window-close stop and lock/quit can both call this
        isClosing = true
        let libraryWin = libraryWindow
        libraryWindow = nil
        // Snapshot and clear first so any re-entrant `windowDidClose` sees an empty list.
        // `tearDown()` nils each window's delegate, so `close()` here never calls back into us.
        let toClose = windows
        windows.removeAll()
        libraryWin?.window?.delegate = nil
        libraryWin?.close()
        for controller in toClose {
            controller.tearDown()
            controller.close()
        }
        library.flush()
        userContentController.removeAllUserScripts()
        // The controller holds its handlers strongly.
        userContentController.removeAllScriptMessageHandlers()
        dataStore = nil
    }
}

/// WebKit preferences with no public API (`WKPreferencesPrivate.h`). Each is applied
/// only when this WebKit implements the selector, so a WebKit without it is left as it is.
enum WebKitPreferences {
    @discardableResult
    static func setBool(_ object: NSObject, _ setter: String, _ value: Bool) -> Bool {
        let selector = NSSelectorFromString(setter)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else { return false }
        typealias Setter = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value)
        return true
    }

    static func bool(_ object: NSObject, _ getter: String) -> Bool? {
        let selector = NSSelectorFromString(getter)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else { return nil }
        typealias Getter = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
    }
}
