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
        // Without the ping-load blocker a page's dns-prefetch would be resolved by this Mac: a
        // profile with a proxy does not start (fail-closed), as with a proxy that cannot be applied.
        // (`ContentRules.prepare` comes first wherever a profile is launched.)
        if configuration.proxy != nil, ContentRules.dnsPrefetchBlocker == nil {
            throw CoreError.invalidConfiguration(ContentRules.failedToCompile
                ? "the ping-load blocker did not compile" : "the ping-load blocker is not ready")
        }
        self.profileID = profileID
        self.profileName = profileName
        self.configuration = configuration
        self.passwordVault = passwordVault
        self.passwordSettings = passwordSettings
        self.library = library

        // `.nonPersistent()` needs WebKit initialized but does not initialize it, and an ephemeral
        // profile can be the first WebKit use after unlock (see `ensureWebKitInitialized`).
        WebDataStoreVault.ensureWebKitInitialized()
        // Before the first web view of any profile: the one every worker of the process copies
        // its preferences from.
        ProfileNetworkGuard.ensureWorkerTemplate()
        let store: WKWebsiteDataStore = configuration.ephemeral
            ? .nonPersistent()
            : WebDataStoreVault.makeStore(for: profileID)
        // Applies to all network loads of this data store. Empty only when no proxy is configured.
        store.proxyConfigurations = proxies
        self.dataStore = store
        // Said plainly in the log, because this one line tells apart the two ways a profile can
        // end up loading pages as this Mac: a store built without its proxy (this says 0), and a
        // store built with it that something later replaced (SafariChromeHost reports that).
        Logger(subsystem: "PrivacyBrowser", category: "BrowserSession")
            .notice("Profile \(profileName, privacy: .public): has a proxy=\(configuration.proxy != nil, privacy: .public) store proxies=\(store.proxyConfigurations.count, privacy: .public)")
        // Routed through BehaviorSets so a profile's device generation selects its script bundle.
        self.userContentController = BehaviorSets.makeUserContentController(for: configuration)
        if configuration.proxy != nil, let blocker = ContentRules.dnsPrefetchBlocker {
            // Loads WebKit would otherwise make outside the proxy (see ContentRules).
            userContentController.add(blocker)
        }
        self.profileScripts = userContentController.userScripts
        self.autoFillScript = PasswordAutoFill.script(testHooks: CommandLine.arguments.contains("--self-test"))
        self.storeChallenges = StoreChallenges(policy: ProfileChallengePolicy(
            hasProxy: configuration.proxy != nil,
            proxyCredential: configuration.proxy.flatMap { proxy in
                proxy.username.map { URLCredential(user: $0, password: proxy.password ?? "", persistence: .forSession) }
            }))
        passwordHandler.session = self
        PasswordAutoFill.install(in: userContentController, handler: passwordHandler, script: autoFillScript)
        if configuration.proxy != nil {
            // The challenges of loads no page is behind (a service worker's) come to the store's
            // own delegate; without one they get the system's default handling (`ServerTrust`).
            let setDelegate = NSSelectorFromString("_setDelegate:")
            if store.responds(to: setDelegate) { store.perform(setDelegate, with: storeChallenges) }
        }
        // A service worker of this profile has the profile's preferences, not those of whichever
        // web view the process built first (`ProfileNetworkGuard.ensureWorkerTemplate`).
        let workerPreferences = WKPreferences()
        applyPrivacyPreferences(to: workerPreferences)
        let override = NSSelectorFromString("_setServiceWorkerOverridePreferences:")
        Self.workerPreferencesApplied = store.responds(to: override)
        if store.responds(to: override) { store.perform(override, with: workerPreferences) }
    }

    /// The scripts every page of this profile gets (the privacy scripts of its device generation),
    /// and AutoFill's: kept, so that what Safari's chrome takes out of a controller can be put back.
    private let profileScripts: [WKUserScript]
    private let autoFillScript: WKUserScript
    /// The data store's delegate (`StoreChallenges`); the store holds it weakly.
    private let storeChallenges: StoreChallenges
    /// Whether this WebKit let a profile's service workers have the profile's preferences.
    private(set) static var workerPreferencesApplied: Bool?

    var windowCount: Int { windows.count }

    /// The profile's browser windows (self-test hook).
    var windowControllers: [BrowserWindowController] { windows }

    var tabContext: BrowserTabContext {
        BrowserTabContext(profileName: profileName, userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version),
                          passwordVault: passwordVault, passwordSettings: passwordSettings, library: library,
                          hasProxy: configuration.proxy != nil,
                          proxyCredential: configuration.proxy.flatMap { proxy in
                              proxy.username.map { URLCredential(user: $0, password: proxy.password ?? "", persistence: .forSession) }
                          })
    }

    /// Applies this profile to a `WKWebViewConfiguration` that something else built — in a
    /// profile's own process, every web view goes through here (`ProfileNetworkGuard`), Safari's
    /// chrome's above all: the profile's data store, which carries its proxy since the proxy is
    /// set on the store; the profile's privacy preferences (WebRTC, Safe Browsing and the rest of
    /// `applyPrivacyPreferences`), which Safari's own configuration has the other way round; and,
    /// into that configuration's content controller, the profile's scripts, its ping-load blocker
    /// and its AutoFill.
    ///
    /// The data store is replaced even when this session has none any more (it is shutting
    /// down): a configuration that kept the store it came with would load as this Mac.
    ///
    /// Safari's content controller is kept rather than replaced with ours: it holds the scripts
    /// Safari injects into every page it shows, and the point of hosting its chrome is that pages
    /// see what they would see in Safari. Ours are added to it. AutoFill is installed the same way
    /// it is installed in our own web views — its message handlers cannot be copied from one
    /// controller to another (WebKit has no API that lists them), so they are installed again
    /// here, which is why this is a method of the session and not a copy loop somewhere else.
    func applyProfile(to webConfiguration: WKWebViewConfiguration) {
        webConfiguration.websiteDataStore = dataStore ?? ProfileNetworkGuard.closedStore
        applyPrivacyPreferences(to: webConfiguration.preferences)
        applyContent(to: webConfiguration.userContentController)
    }

    /// The profile's scripts, its ping-load blocker and its AutoFill, into a content controller
    /// something else made (a configuration's, or one a navigation brings: `ProfileNetworkGuard`).
    func applyContent(to controller: WKUserContentController) {
        // Our own controller already has all of it (`makeWebViewConfiguration`); a second copy of
        // the privacy scripts would patch what they patched once already, which a page can see.
        guard controller !== userContentController else { return }
        // Safari reuses a configuration's controller across the web views of a tab; everything
        // below would otherwise be injected again on each of them.
        guard appliedControllers.add(controller) else { return }
        // AutoFill's script is installed below, with its handlers.
        for script in profileScripts {
            controller.addUserScript(script)
        }
        if configuration.proxy != nil, let blocker = ContentRules.dnsPrefetchBlocker {
            controller.add(blocker)
        }
        PasswordAutoFill.install(in: controller, handler: passwordHandler, script: autoFillScript)
        Logger(subsystem: "PrivacyBrowser", category: "BrowserSession")
            .notice("Profile scripts and AutoFill installed into a content controller of Safari's chrome")
    }

    /// Puts back into `controller` — one the profile was applied to, which something has just
    /// emptied of scripts or rule lists — whatever of the profile's is no longer there. The
    /// message handlers stay where they are through such a wipe, so only scripts and the blocker
    /// come back. (Our own controller is emptied only when the session closes, and stays so.)
    func restoreContent(in controller: WKUserContentController) {
        guard controller !== userContentController, appliedControllers.contains(controller) else { return }
        let present = Set(controller.userScripts.map(\.source))
        var restored = 0
        for script in profileScripts + [autoFillScript] where !present.contains(script.source) {
            controller.addUserScript(script)
            restored += 1
        }
        if configuration.proxy != nil, let blocker = ContentRules.dnsPrefetchBlocker {
            controller.add(blocker)
        }
        Self.contentRestorations += 1
        Logger(subsystem: "PrivacyBrowser", category: "BrowserSession")
            .notice("A content controller of Safari's chrome was emptied: \(restored, privacy: .public) of the profile's scripts and its rule lists put back")
    }

    /// How many times `restoreContent` ran in this process (the self-test).
    private(set) static var contentRestorations = 0

    /// The preferences that decide what a page of this profile can reach outside its proxy, or
    /// what this Mac's own services are asked on its behalf. One place, for our own web views and
    /// for the ones Safari's chrome builds, so that neither can have them the other way round.
    ///
    ///   * WebRTC opens its sockets outside the data store's proxy: off in the engine, as Lockdown
    ///     Mode does, whenever the profile's WebRTC is off (the default, and always with a proxy
    ///     the tunnel cannot carry: `webRTCRouting`). No RTC interface in any frame, nothing for a
    ///     page to reach before the shim runs; the shim's removal stays as the fallback for a
    ///     WebKit without this preference.
    ///   * Safe Browsing lookups are made by a system service, outside the proxy: per profile,
    ///     off by default. Safari's own configuration has it on.
    ///   * With a proxy, the features whose traffic does not go through the data store's proxy
    ///     at all (`featuresOffWithAProxy`). A Safari user can have them off as well (Private Click
    ///     Measurement in Safari's Advanced settings, the rest as Lockdown Mode does).
    ///   * As Safari: pages see the system's fonts only, not the ones the user installed.
    func applyPrivacyPreferences(to preferences: WKPreferences) {
        preferences.isFraudulentWebsiteWarningEnabled = configuration.safeBrowsingEnabled
        // There is no public switch for installed fonts; this is the WKPreferences property Safari
        // turns off, set only when this WebKit has it.
        WebKitPreferences.setBool(preferences, "_setShouldAllowUserInstalledFonts:", false)
        if configuration.effectiveWebRTCPolicy == .disabled {
            WebKitPreferences.setBool(preferences, "_setPeerConnectionEnabled:", false)
        }
        // WebRTC through the packet tunnel: libwebrtc gathers on the tunnel interface for the relay
        // addresses (measured with a utun in CI; the tunnel's enforced routes are a second line).
        // For the hardware checks in docs/TUNNEL.md it can also be made to gather on every
        // interface: `defaults write <bundle id> PBTunnelAllInterfaces -bool YES`.
        if case .relay = configuration.webRTCRouting, UserDefaults.standard.bool(forKey: "PBTunnelAllInterfaces") {
            WebKitPreferences.setBool(preferences, "_setEnumeratingAllNetworkInterfacesEnabled:", true)
        }
        if configuration.proxy != nil {
            for key in Self.featuresOffWithAProxy { WebKitFeatures.set(preferences, key, false) }
            // A page's dns-prefetch is resolved by this Mac, outside the proxy: before WebKit 7621
            // through this switch, which the content rules do not reach (`ContentRules`).
            WebKitPreferences.setBool(preferences, "_setDNSPrefetchingEnabled:", false)
        }
    }

    /// The WebKit features whose traffic does not go through the data store's proxy, and are off
    /// in every web view of a profile with a proxy (`ProfileNetworkGuard` pins them there):
    ///   * WebTransport: QUIC, which an HTTP or SOCKS5 proxy cannot carry.
    ///   * Private Click Measurement: attribution reports sent later, outside the page's session.
    ///   * Web Authentication and Digital Credentials: passkeys are the user's own iCloud Keychain,
    ///     the same in every profile and in Safari, and their checks are made by system services.
    ///   * Web archives loaded on a store of their own: WebKit moves such a page to a fresh
    ///     ephemeral store — one without the profile's proxy — for whatever the archive lacks.
    nonisolated static let featuresOffWithAProxy: Set<String> = [
        "WebTransportEnabled", "PrivateClickMeasurementEnabled", "WebAuthenticationEnabled",
        "DigitalCredentialsEnabled", "LoadWebArchiveWithEphemeralStorageEnabled",
    ]

    /// Content controllers this profile has already been applied to, held weakly.
    private let appliedControllers = WeakSet()

    /// A set that does not keep what it remembers alive, so that a controller Safari released is
    /// not applied to a second time by mistake and is not kept in memory either.
    private final class WeakSet {
        private let table = NSHashTable<AnyObject>.weakObjects()
        func contains(_ object: AnyObject) -> Bool { table.contains(object) }
        /// True when `object` was not in the set and has been added.
        func add(_ object: AnyObject) -> Bool {
            guard !table.contains(object) else { return false }
            table.add(object)
            return true
        }
    }

    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let webConfiguration = WKWebViewConfiguration()
        // Never the default store: it has no proxy (a session that is shutting down has no store).
        webConfiguration.websiteDataStore = dataStore ?? ProfileNetworkGuard.closedStore
        webConfiguration.userContentController = userContentController
        // Popups only in response to a user gesture.
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // As Safari: the Fullscreen API is available (a WKWebView has it off by default, which a
        // page sees as document.fullscreenEnabled === undefined).
        webConfiguration.preferences.isElementFullscreenEnabled = true
        applyPrivacyPreferences(to: webConfiguration.preferences)
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
        controller.isForWarmUp = true
        windows.append(controller)
        if let window = controller.window {
            // Not moved off screen: AppKit pulls an ordinary window back onto a screen when it is
            // ordered front, which is why the warm-up was visible. Fully transparent instead, at
            // the lowest window level, taking no clicks and in no window list — WebKit still
            // treats it as on screen, which is what keeps rendering and timers running and
            // `document.visibilityState` at "visible", exactly as for a page someone is reading.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior.insert([.transient, .ignoresCycle, .fullScreenNone])
            window.orderBack(nil)
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

    /// The profile's window nearest the front. Never the warm-up's own window, which the user
    /// cannot see: a new tab, or bringing the profile forward, has no business going there.
    var frontmostWindow: BrowserWindowController? {
        let shown = windows.filter { !$0.isForWarmUp }
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        return ordered.first { controller in shown.contains { $0 === controller } } ?? shown.last
    }

    /// The window `tab` is in, the warm-up's own included.
    func window(of tab: BrowserTab) -> BrowserWindowController? {
        windows.first { controller in controller.tabs.contains { $0 === tab } }
    }

    /// A window of this profile that the user can see. False while it is only being warmed up.
    var hasVisibleWindow: Bool { windows.contains { !$0.isForWarmUp } }

    /// The tab showing `webView`, in any window of this profile.
    func tab(for webView: WKWebView) -> BrowserTab? {
        for controller in windows {
            if let tab = controller.tabs.first(where: { $0.webView === webView }) { return tab }
        }
        return nil
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        // The warm-up's own window is none of the user's: its closing is not the profile's last
        // window closing, and a profile that is only being warmed up has not lost a window at all.
        // (Without this, a warm-up ending would have quit a profile the user was browsing in.)
        guard !isClosing, !controller.isForWarmUp, !hasVisibleWindow else { return }
        onAllWindowsClosed?()
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

/// The WebKit this app runs on, by its build (`CFBundleVersion` of WebKit.framework, as
/// "21622.1.22.118.4"): what WebKit does outside a proxy differs between versions, and the
/// self-test and the network report say which one they saw.
enum WebKitBuild {
    static let version: String = Bundle(identifier: "com.apple.WebKit")?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
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

/// WebKit's feature switches (`_WKFeature`, the list behind Safari's Feature Flags settings), by
/// key — "WebTransportEnabled", "PrivateClickMeasurementEnabled". Private API, looked up at run
/// time: a WebKit without the list, or without a feature in it, is left as it is, and `applied`
/// says which keys were found, for the network report.
@MainActor
enum WebKitFeatures {
    /// Key → whether this WebKit has that feature, for every key `set` was asked about.
    private(set) static var applied: [String: Bool] = [:]

    /// Sets `key` through the one setter named, when this WebKit has both (the network report
    /// tries each way in turn: `ProfileNetworkGuard.pinBypasses`).
    static func set(_ preferences: WKPreferences, _ key: String, _ enabled: Bool, through setter: String) -> Bool {
        let selector = NSSelectorFromString(setter)
        guard let feature = features[key], let method = class_getInstanceMethod(WKPreferences.self, selector) else { return false }
        typealias Setter = @convention(c) (NSObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, selector, enabled, feature)
        return true
    }

    @discardableResult
    static func set(_ preferences: WKPreferences, _ key: String, _ enabled: Bool) -> Bool {
        guard let feature = features[key] else {
            applied[key] = false
            return false
        }
        // -_setEnabled:forFeature: since 2023; the older WebKit split them in two lists.
        for setter in ["_setEnabled:forFeature:", "_setEnabled:forExperimentalFeature:", "_setEnabled:forInternalDebugFeature:"] {
            let selector = NSSelectorFromString(setter)
            guard let method = class_getInstanceMethod(WKPreferences.self, selector) else { continue }
            typealias Setter = @convention(c) (NSObject, Selector, Bool, AnyObject) -> Void
            unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, selector, enabled, feature)
            applied[key] = true
            return true
        }
        applied[key] = false
        return false
    }

    /// Whether `key` is on in `preferences`, or nil when this WebKit cannot say.
    static func isEnabled(_ preferences: WKPreferences, _ key: String) -> Bool? {
        guard let feature = features[key] else { return nil }
        for getter in ["_isEnabledForFeature:", "_isEnabledForExperimentalFeature:", "_isEnabledForInternalDebugFeature:"] {
            let selector = NSSelectorFromString(getter)
            guard let method = class_getInstanceMethod(WKPreferences.self, selector) else { continue }
            typealias Getter = @convention(c) (NSObject, Selector, AnyObject) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Getter.self)(preferences, selector, feature)
        }
        return nil
    }

    /// Every feature this WebKit lists, by key.
    private static let features: [String: AnyObject] = {
        var byKey: [String: AnyObject] = [:]
        let preferencesClass: AnyObject = WKPreferences.self
        for list in ["_features", "_experimentalFeatures", "_internalDebugFeatures"] {
            let selector = NSSelectorFromString(list)
            guard preferencesClass.responds(to: selector),
                  let items = preferencesClass.perform(selector)?.takeUnretainedValue() as? [NSObject] else { continue }
            for item in items where item.responds(to: NSSelectorFromString("key")) {
                if let key = item.value(forKey: "key") as? String, byKey[key] == nil { byKey[key] = item }
            }
        }
        return byKey
    }()
}
