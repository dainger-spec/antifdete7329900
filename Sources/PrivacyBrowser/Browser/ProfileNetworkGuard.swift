import BrowserCore
import Foundation
import Network
import os
import WebKit

/// What a profile's own process may send, and through which proxy — decided before anything in
/// it can send at all.
///
/// A profile in a process of its own (`ProfileProcess`) is the only profile there, so the whole
/// process can be held to that profile's proxy, not only its web views. It has to be: the web
/// views are not the only thing in it that talks to the network. Safari's frameworks, hosted for
/// its chrome (`SafariChrome`), bring clients of their own — search suggestions, icons, site
/// metadata — that know nothing of a data store's proxy and would go out as this Mac. And a web
/// view Safari builds by a path nobody patched would get a store of Safari's, with no proxy at
/// all. Both are the one failure this product may not have, so neither is left to a single patch.
///
/// THREE LOCKS, each one the fallback of the one before it:
///   1. Every web view of the process is built on the profile's data store, which is what carries
///      the profile's proxy (`give`, called from Safari's configuration factories and from the
///      initializer every web view goes through).
///   2. Every other data store the process creates carries a proxy that does not exist
///      (127.0.0.1:1, failover off) — WebKit's own default store included. A web view that ends
///      up on one of them by some path nobody thought of loads nothing, instead of loading as
///      this Mac.
///   3. Everything else in the process that uses URLSession or Network.framework goes through the
///      profile's proxy: the process's default privacy context carries it, and so does every
///      URLSession configuration made here.
/// What runs in another process — a daemon that Safari's frameworks ask for something — is out
/// of reach of all three; those features are turned off instead
/// (`SafariChrome.configureSafarisOwnServices`).
///
/// Only in a profile's own process. The manager process runs no profile of its own (and, in the
/// single-process mode, several at once), so none of this is engaged there.
@MainActor
enum ProfileNetworkGuard {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileNetworkGuard")

    /// The proxies of the profile this process runs: empty for a profile without one, nil until
    /// `engage` ran (which is: not a profile's process).
    private(set) static var proxies: [ProxyConfiguration]?
    static var isEngaged: Bool { proxies != nil }
    private static var profileID: UUID?

    /// The profile running in this process. One per process, by construction. Registered as soon
    /// as its session exists — before any window, because a profile may be launched only to be
    /// warmed up, and the robot's web views need the profile's store just the same.
    private(set) static weak var session: BrowserSession?

    /// Called once when a web view turns out not to be on the profile's data store, or on it
    /// without the profile's proxy. That web view loads nothing (lock 2), and the user is told.
    static var onWebViewOffProfile: (() -> Void)?
    private static var toldOffProfile = false

    /// Web views whose configuration came to the initializer without the profile's store: the
    /// ones only the initializer's net gave the profile's data to.
    private static var webViewsCaughtByNet = 0
    /// Every web view this process has built, held weakly, for `report`.
    private static let webViews = NSHashTable<WKWebView>.weakObjects()
    /// WebKit's real default store, closed and kept alive so that WebKit keeps handing out this one.
    private static var realDefaultStore: WKWebsiteDataStore?
    /// Hooks that could not be installed because what they patch is not in this macOS.
    private static var missingHooks: [String] = []

    // MARK: Engaging

    /// Holds this process to `proxy` (or, with none, to no proxy but still to the profile's store).
    /// Throws when the proxy cannot be applied: the process must then not run at all.
    static func engage(profileID: UUID, proxy: ProxySettings?, safeBrowsing: Bool = false) throws {
        guard proxies == nil else { return }
        let proxies = try ProxyConfigurationFactory.make(proxy)
        self.proxies = proxies
        self.profileID = profileID
        if !proxies.isEmpty {
            // Lock 3. The default privacy context is what every Network.framework connection and
            // URLSession task of this process uses unless it brings its own (macOS 14).
            NWParameters.PrivacyContext.default.proxyConfigurations = proxies
            missingHooks += proxyEverySessionConfiguration(proxies)
        }
        missingHooks += everyStoreStartsClosed(except: profileID)
        missingHooks += everyWebViewGetsTheProfilesData()
        missingHooks += pinPrivacyPreferences()
        missingHooks += noPagePicksAnotherStore()
        missingHooks += noServiceOutsideTheProxy(safeBrowsing: safeBrowsing)
        missingHooks += nothingIsHandedOff()
        log.notice("This process is held to its profile's proxy: \(proxies.count, privacy: .public) proxies, \(missingHooks.count, privacy: .public) hooks missing")
        for hook in missingHooks {
            log.error("Not in this macOS: \(hook, privacy: .public)")
        }
    }

    /// WebKit's default data store, the one `+[WKWebsiteDataStore defaultDataStore]` hands out,
    /// gets the closed proxy, and from then on that call answers with the profile's store.
    ///
    /// The default store exists in WebKit's C++ even where nothing asks the Objective-C class for
    /// it, so replacing the class method alone would leave a store with no proxy for WebKit to fall
    /// back on. Asking for it once, closing it and keeping it alive means the one WebKit has is
    /// the closed one. Needs `NSApp` to exist already (WebKit is initialized on the way), so it
    /// runs once the process is the kind of application it is going to be; idempotent.
    static func takeOverDefaultStore() {
        guard isEngaged, realDefaultStore == nil else { return }
        WebDataStoreVault.ensureWebKitInitialized()
        let real = WKWebsiteDataStore.default()
        closeStore(real)
        realDefaultStore = real
        let selector = NSSelectorFromString("defaultDataStore")
        guard let method = class_getClassMethod(WKWebsiteDataStore.self, selector) else {
            missingHooks.append("+[WKWebsiteDataStore defaultDataStore]")
            log.error("WKWebsiteDataStore's default store is not where it was; it stays closed")
            return
        }
        let replacement: @convention(block) (AnyObject) -> WKWebsiteDataStore = { _ in
            session?.dataStore ?? closedStore
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        log.notice("The default website data store of this process is closed, and asking for it gives the profile's")
    }

    /// The profile whose data every web view of this process is built with.
    static func register(session: BrowserSession) {
        guard isEngaged else { return }
        Self.session = session
    }

    // MARK: Lock 1: every web view on the profile's store

    /// Gives `configuration` the profile's data store, preferences and scripts. With no profile
    /// yet — nothing should be built then, and if something is, it must not reach the network as
    /// this Mac — the configuration gets a store nothing can load through.
    static func give(_ configuration: WKWebViewConfiguration, builtBy origin: String) {
        guard let session else {
            log.error("\(origin, privacy: .public) before the profile was ready: it gets a store that loads nothing")
            configuration.websiteDataStore = closedStore
            // And nothing that leaves a store's proxy anyway (the setters are pinned: with no
            // profile yet, they answer off).
            configuration.preferences.isFraudulentWebsiteWarningEnabled = false
            WebKitPreferences.setBool(configuration.preferences, "_setPeerConnectionEnabled:", false)
            for key in BrowserSession.featuresOffWithAProxy { WebKitFeatures.set(configuration.preferences, key, false) }
            return
        }
        session.applyProfile(to: configuration)
    }

    /// Every web view built in this process is built with the profile's data, whoever built it:
    /// the profile is given at the last moment before the web view exists, in the initializer
    /// every web view built in code goes through, and what the web view ended up with is read
    /// back. (A web view decoded from a nib does not come through here; its store comes from
    /// `+defaultDataStore` or `+nonPersistentDataStore`, which locks 1 and 2 cover.)
    private static func everyWebViewGetsTheProfilesData() -> [String] {
        let selector = NSSelectorFromString("initWithFrame:configuration:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return ["-[WKWebView initWithFrame:configuration:]"]
        }
        // The configuration is an object, so ARC may hold it; the web view that comes back is
        // passed on exactly as it came, because an initializer hands over ownership of it.
        typealias Initializer = @convention(c) (AnyObject, Selector, CGRect, AnyObject?) -> Unmanaged<AnyObject>?
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: @convention(block) (AnyObject, CGRect, AnyObject?) -> Unmanaged<AnyObject>? = { receiver, frame, configuration in
            if let configuration = configuration as? WKWebViewConfiguration {
                // A web view whose configuration reaches its initializer without the profile's
                // store is one that Safari's configuration factories did not cover: without this
                // net it would have loaded on a store of Safari's. Counted, so that whether the
                // nets are load-bearing on a given macOS is measured, never found out by a leak.
                if let session, configuration.websiteDataStore !== session.dataStore {
                    webViewsCaughtByNet += 1
                    log.error("A web view reached its initializer without the profile's store (Safari's factories missed it); given the profile's now")
                }
                give(configuration, builtBy: "A web view being built")
            }
            let result = original(receiver, selector, frame, configuration)
            if let webView = result?.takeUnretainedValue() as? WKWebView {
                inspect(webView)
            }
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))

        // The initializer every initializer goes through, -initWithCoder: (a web view in a nib)
        // included: the same, once more, where nothing else reaches. Private, so only noted when
        // absent; giving a configuration the profile twice changes nothing.
        let initialize = NSSelectorFromString("_initializeWithConfiguration:")
        if let method = class_getInstanceMethod(WKWebView.self, initialize) {
            typealias Initialize = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Initialize.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, configuration in
                if let configuration = configuration as? WKWebViewConfiguration {
                    give(configuration, builtBy: "A web view being initialized")
                }
                original(receiver, initialize, configuration)
                if let webView = receiver as? WKWebView { inspect(webView) }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        return []
    }

    /// A page's navigation can carry a data store of its own (`WKWebpagePreferences`, set by the
    /// browser's navigation delegate — Safari's, here): in this process it is always the profile's,
    /// or the closed one before the profile is ready.
    private static func noPagePicksAnotherStore() -> [String] {
        let selector = NSSelectorFromString("_setWebsiteDataStore:")
        guard let method = class_getInstanceMethod(WKWebpagePreferences.self, selector) else { return [] }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { preferences, store in
            let profiles: WKWebsiteDataStore = session?.dataStore ?? closedStore
            if let store, store !== profiles {
                log.error("A navigation asked for another data store: it gets the profile's")
            }
            original(preferences, selector, store == nil ? nil : profiles)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return []
    }

    /// The XPC services of Safari's and of the system that would make requests for a profile from
    /// another process — as this Mac, outside every lock in this one — are not reached from here:
    /// a connection to one of them is made to a name that does not exist, so it fails at once and
    /// its error handler runs, as for any service that is unavailable. Every service this process
    /// does connect to is noted for the report, so that a new one is seen.
    ///
    ///   * SearchHelper: Safari's search suggestions and the OpenSearch descriptions pages name.
    ///   * SafeBrowsing: the lookups, unless the profile asks for them.
    ///   * parsecd: Safari Suggestions. cloudd and the sync agents: iCloud Tabs, bookmarks, tab
    ///     groups. webpushd: Web Push, registered with this Mac's own push token.
    ///   * passd (Apple Pay), translationd (Safari's page translation, which sends the page's text)
    ///     and Safari's password breach check: measured in CI, the hosted chrome woke the first
    ///     two on its own and both went to Apple's servers as this Mac while the profile ran.
    ///
    /// Connections are made from any thread, so this runs on whichever it is called from.
    nonisolated private static func noServiceOutsideTheProxy(safeBrowsing: Bool) -> [String] {
        var denied = ["Safari.SearchHelper", "parsec", "cloudd", "SyncAgent", "CloudTabs", "webpushd",
                      "passd", "translationd", "PasswordBreach"]
        if !safeBrowsing { denied.append("SafeBrowsing") }
        let deny = denied
        var missing: [String] = []
        let reroute: @Sendable (String) -> String = { name in
            let refused = deny.contains { name.localizedCaseInsensitiveContains($0) }
            servicesSeen.insert(refused ? "\(name) (refused)" : name)
            return refused ? "\(name).refused-in-a-profile" : name
        }
        let service = NSSelectorFromString("initWithServiceName:")
        if let method = class_getInstanceMethod(NSXPCConnection.self, service) {
            typealias Initializer = @convention(c) (AnyObject, Selector, NSString?) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
            let replacement: @convention(block) (AnyObject, NSString?) -> Unmanaged<AnyObject>? = { receiver, name in
                original(receiver, service, name.map { reroute($0 as String) as NSString })
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            missing.append("-[NSXPCConnection initWithServiceName:]")
        }
        let machService = NSSelectorFromString("initWithMachServiceName:options:")
        if let method = class_getInstanceMethod(NSXPCConnection.self, machService) {
            typealias Initializer = @convention(c) (AnyObject, Selector, NSString?, UInt) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
            let replacement: @convention(block) (AnyObject, NSString?, UInt) -> Unmanaged<AnyObject>? = { receiver, name, options in
                original(receiver, machService, name.map { reroute($0 as String) as NSString }, options)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            missing.append("-[NSXPCConnection initWithMachServiceName:options:]")
        }
        return missing
    }

    /// XPC services this process has connected to (refused ones marked), for the report.
    nonisolated private static let servicesSeen = LockedSet()

    /// A set any thread may add to.
    final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func insert(_ name: String) { lock.withLock { _ = names.insert(name) } }
        var sorted: [String] { lock.withLock { names.sorted() } }
    }

    /// Safari publishes the page in front as a Handoff activity, which the system advertises to the
    /// owner's other devices on their Apple ID — the profile's addresses, outside its proxy and
    /// tied to the owner. In a profile's process no activity becomes current, and none is eligible
    /// for Handoff, Spotlight or public indexing.
    nonisolated private static func nothingIsHandedOff() -> [String] {
        var missing: [String] = []
        let becomeCurrent = NSSelectorFromString("becomeCurrent")
        if let method = class_getInstanceMethod(NSUserActivity.self, becomeCurrent) {
            let replacement: @convention(block) (AnyObject) -> Void = { _ in }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            missing.append("-[NSUserActivity becomeCurrent]")
        }
        typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
        for name in ["setEligibleForHandoff:", "setEligibleForSearch:", "setEligibleForPublicIndexing:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(NSUserActivity.self, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
            let replacement: @convention(block) (AnyObject, Bool) -> Void = { activity, _ in
                original(activity, selector, false)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        return missing
    }

    /// What a finished web view actually holds. Not on the profile's store, or on it without the
    /// proxy the profile has, is a web view that would have loaded as this Mac without lock 2.
    private static func inspect(_ webView: WKWebView) {
        webViews.add(webView)
        let store = webView.configuration.websiteDataStore
        let onProfile = session.map { $0.dataStore === store } ?? false
        let wanted = !(proxies ?? []).isEmpty
        let carried = store.proxyConfigurations.count
        if !onProfile || (wanted && carried == 0) {
            log.error("A web view is NOT on the profile's data: profile's store=\(onProfile, privacy: .public) proxies=\(carried, privacy: .public) profile has a proxy=\(wanted, privacy: .public)")
            if !toldOffProfile {
                toldOffProfile = true
                onWebViewOffProfile?()
            }
        } else {
            log.notice("A web view of \(session?.profileName ?? "?", privacy: .private) is up: proxies=\(carried, privacy: .public)")
        }
    }

    /// The profile's privacy preferences (`BrowserSession.applyPrivacyPreferences`) cannot be set
    /// otherwise in this process, by anyone.
    ///
    /// Giving a web view's configuration the profile's preferences once is not enough where the
    /// web view is Safari's: Safari applies its own settings to its web views' preferences, and
    /// does so again when a setting changes or a window opens — its WebRTC on, its Safe Browsing
    /// on. So the setters themselves keep to the profile: WebRTC only when the profile's routing
    /// allows it, Safe Browsing only when the profile asks for it, the features that leave the
    /// proxy never with a proxy, installed fonts never. Before the profile's session exists, the
    /// answer is the closed one.
    private static func pinPrivacyPreferences() -> [String] {
        var missing: [String] = []
        let preferencesClass: AnyClass = WKPreferences.self
        typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
        func pin(_ name: String, required: Bool, _ value: @escaping (Bool) -> Bool) {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(preferencesClass, selector) else {
                if required { missing.append("-[WKPreferences \(name)]") }
                return
            }
            let original = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
            let replacement: @convention(block) (AnyObject, Bool) -> Void = { preferences, asked in
                original(preferences, selector, value(asked))
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        pin("_setPeerConnectionEnabled:", required: true) { asked in
            asked && (session.map { $0.configuration.effectiveWebRTCPolicy != .disabled } ?? false)
        }
        pin("setFraudulentWebsiteWarningEnabled:", required: true) { _ in
            session?.configuration.safeBrowsingEnabled ?? false
        }
        pin("_setSafeBrowsingEnabled:", required: false) { _ in
            session?.configuration.safeBrowsingEnabled ?? false
        }
        pin("_setShouldAllowUserInstalledFonts:", required: false) { _ in false }

        // The feature switches, by key: only the ones that leave the proxy, only with a proxy.
        let pinnedOff = BrowserSession.featuresOffWithAProxy
        for name in ["_setEnabled:forFeature:", "_setEnabled:forExperimentalFeature:", "_setEnabled:forInternalDebugFeature:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(preferencesClass, selector) else { continue }
            typealias FeatureSetter = @convention(c) (AnyObject, Selector, Bool, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: FeatureSetter.self)
            let replacement: @convention(block) (AnyObject, Bool, AnyObject?) -> Void = { preferences, asked, feature in
                let key = (feature as? NSObject).flatMap { object -> String? in
                    object.responds(to: NSSelectorFromString("key")) ? object.value(forKey: "key") as? String : nil
                }
                let proxied = !(proxies ?? []).isEmpty
                let value = asked && !(proxied && key.map(pinnedOff.contains) == true)
                original(preferences, selector, value, feature)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        return missing
    }

    // MARK: Lock 2: every other store closed

    /// A store nothing can load through: non-persistent, pointed at a proxy that does not exist,
    /// with failover off, so every load through it fails instead of going out as this Mac.
    static let closedStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [deadProxy]
        return store
    }()

    nonisolated static var deadProxy: ProxyConfiguration {
        var dead = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 1))
        dead.allowFailover = false
        return dead
    }

    /// Points `store` at the dead proxy. A store must be touched on the main thread; one made
    /// elsewhere is closed as soon as the main thread gets to it, which is before it can carry a
    /// page (pages are loaded from the main thread too).
    nonisolated private static func closeStore(_ store: WKWebsiteDataStore) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { store.proxyConfigurations = [deadProxy] }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store.proxyConfigurations = [deadProxy] }
            }
        }
    }

    /// Every data store made in this process starts out closed. The profile's own then gets its
    /// proxy — or, for a profile without one, none — from `BrowserSession`, right after it is made;
    /// a store made for the profile's identifier is left as it is, since that is the profile's.
    nonisolated private static func everyStoreStartsClosed(except profileID: UUID) -> [String] {
        var missing: [String] = []
        let storeClass: AnyClass = WKWebsiteDataStore.self
        let logger = Logger(subsystem: "PrivacyBrowser", category: "ProfileNetworkGuard")

        // +nonPersistentDataStore
        let nonPersistent = NSSelectorFromString("nonPersistentDataStore")
        if let method = class_getClassMethod(storeClass, nonPersistent) {
            typealias Factory = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let replacement: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { cls in
                let result = original(cls, nonPersistent)
                if let store = result?.takeUnretainedValue() as? WKWebsiteDataStore { closeStore(store) }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            missing.append("+[WKWebsiteDataStore nonPersistentDataStore]")
        }

        // +dataStoreForIdentifier: (Swift's init(forIdentifier:))
        let forIdentifier = NSSelectorFromString("dataStoreForIdentifier:")
        if let method = class_getClassMethod(storeClass, forIdentifier) {
            typealias Factory = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Unmanaged<AnyObject>? = { cls, identifier in
                let result = original(cls, forIdentifier, identifier)
                let isProfiles = (identifier as? NSUUID).map { $0 as UUID == profileID } ?? false
                if !isProfiles, let store = result?.takeUnretainedValue() as? WKWebsiteDataStore {
                    logger.notice("A data store for another identifier than the profile's was made: closed")
                    closeStore(store)
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            missing.append("+[WKWebsiteDataStore dataStoreForIdentifier:]")
        }

        // -_initWithConfiguration: — how Safari makes the stores of its own profiles and private
        // windows. Private, so its absence is only noted.
        let withConfiguration = NSSelectorFromString("_initWithConfiguration:")
        if let method = class_getInstanceMethod(storeClass, withConfiguration) {
            typealias Initializer = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
            let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Unmanaged<AnyObject>? = { receiver, configuration in
                let result = original(receiver, withConfiguration, configuration)
                let identifier = (configuration as? NSObject).flatMap { object -> UUID? in
                    let getter = NSSelectorFromString("identifier")
                    guard object.responds(to: getter) else { return nil }
                    return (object.perform(getter)?.takeUnretainedValue() as? NSUUID).map { $0 as UUID }
                }
                if identifier != profileID, let store = result?.takeUnretainedValue() as? WKWebsiteDataStore {
                    logger.notice("A data store was made from a configuration of its own: closed")
                    closeStore(store)
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        return missing
    }

    // MARK: Lock 3: the process's own connections

    /// Every URLSession configuration made in this process carries the profile's proxy, unless it
    /// was given proxies of its own (the proxy lookup's, which are the same ones); the shared
    /// session is one made from such a configuration; and a background session — which would run
    /// in a system daemon, outside this process and every lock in it — is made an ordinary one.
    nonisolated private static func proxyEverySessionConfiguration(_ proxies: [ProxyConfiguration]) -> [String] {
        var missing: [String] = []
        typealias Factory = @convention(c) (AnyObject, Selector) -> Unmanaged<URLSessionConfiguration>?
        for name in ["defaultSessionConfiguration", "ephemeralSessionConfiguration"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else {
                missing.append("+[NSURLSessionConfiguration \(name)]")
                continue
            }
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let replacement: @convention(block) (AnyObject) -> Unmanaged<URLSessionConfiguration>? = { cls in
                let result = original(cls, selector)
                if let configuration = result?.takeUnretainedValue(), configuration.proxyConfigurations.isEmpty {
                    configuration.proxyConfigurations = proxies
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        for name in ["backgroundSessionConfigurationWithIdentifier:", "backgroundSessionConfiguration:"] {
            let background = NSSelectorFromString(name)
            guard let method = class_getClassMethod(URLSessionConfiguration.self, background) else { continue }
            let replacement: @convention(block) (AnyObject, AnyObject?) -> URLSessionConfiguration = { _, identifier in
                Logger(subsystem: "PrivacyBrowser", category: "ProfileNetworkGuard")
                    .notice("A background URL session was asked for (\(String(describing: identifier), privacy: .public)); it runs in this process, through the profile's proxy")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.proxyConfigurations = proxies
                return configuration
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        let shared = NSSelectorFromString("sharedSession")
        if let method = class_getClassMethod(URLSession.self, shared) {
            let configuration = URLSessionConfiguration.default
            configuration.proxyConfigurations = proxies
            let session = URLSession(configuration: configuration)
            let replacement: @convention(block) (AnyObject) -> URLSession = { _ in session }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            missing.append("+[NSURLSession sharedSession]")
        }
        return missing
    }

    // MARK: Report

    /// What this process can say about where its traffic goes — the answer to "is this profile
    /// leaking?", measured from inside: the web views and their stores, WebRTC in their engines,
    /// the process's own connections and, with `probe`, a request made by each of the process's
    /// own ways of making one. `probe` must be reachable only through the profile's proxy for
    /// its answer to mean anything (the self-test uses a host that resolves nowhere else).
    static func report(probe: URL?) async -> ProfileNetworkReport {
        var report = ProfileNetworkReport()
        let profileProxies = proxies ?? []
        report.hasProxy = !profileProxies.isEmpty
        let views = webViews.allObjects
        report.webViews = views.count
        let webRTCWanted = session.map { $0.configuration.effectiveWebRTCPolicy != .disabled } ?? false
        for view in views {
            let configuration = view.configuration
            let store = configuration.websiteDataStore
            if session?.dataStore !== store || (report.hasProxy && store.proxyConfigurations.isEmpty) {
                report.webViewsOffProfile += 1
            }
            if !webRTCWanted, WebKitPreferences.bool(configuration.preferences, "_peerConnectionEnabled") == true {
                report.webViewsWithWebRTC += 1
            }
        }
        report.webViewsCaughtByNet = webViewsCaughtByNet
        report.defaultStoreClosed = realDefaultStore.map { !$0.proxyConfigurations.isEmpty } ?? false
        report.processProxy = !report.hasProxy
            || (!URLSessionConfiguration.default.proxyConfigurations.isEmpty
                && !NWParameters.PrivacyContext.default.proxyConfigurations.isEmpty)
        report.missing = missingHooks + SafariChrome.missingPieces()
        report.features = WebKitFeatures.applied
        report.services = servicesSeen.sorted
        report.safariPreferences = SafariChrome.servicePreferences()
        if let probe {
            report.probes["shared"] = await fetch(probe, with: URLSession.shared)
            let ephemeral = URLSession(configuration: .ephemeral)
            report.probes["ephemeral"] = await fetch(probe, with: ephemeral)
            ephemeral.invalidateAndCancel()
            if !profileProxies.isEmpty {
                // As the proxy lookup makes its requests: its own proxies, set on its session.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.proxyConfigurations = profileProxies
                let explicit = URLSession(configuration: configuration)
                report.probes["explicit"] = await fetch(probe, with: explicit)
                explicit.invalidateAndCancel()
            }
        }
        return report
    }

    private static func fetch(_ url: URL, with session: URLSession) async -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return "ok \(status) " + String(decoding: data.prefix(160), as: UTF8.self)
        } catch {
            return "failed \(error.localizedDescription)"
        }
    }
}

/// What a profile's process says about where its traffic goes (`ProfileNetworkGuard.report`).
struct ProfileNetworkReport: Codable, Equatable {
    var hasProxy = false
    /// Web views alive in the process.
    var webViews = 0
    /// Of those, the ones not on the profile's data store, or on it without the profile's proxy.
    var webViewsOffProfile = 0
    /// Of those, the ones whose engine has WebRTC on while the profile wants it off.
    var webViewsWithWebRTC = 0
    /// Web views that reached their initializer without the profile's store — Safari's
    /// configuration factories did not cover them — and got it there (`ProfileNetworkGuard`).
    var webViewsCaughtByNet = 0
    /// WebKit's own default store carries the closed proxy.
    var defaultStoreClosed = false
    /// The process's own connections carry the profile's proxy (true for a profile without one).
    var processProxy = false
    /// Name → "ok <status> <start of the body>" or "failed <why>".
    var probes: [String: String] = [:]
    /// Classes, methods and hooks this build expects and this macOS does not have.
    var missing: [String] = []
    /// WebKit feature switches set for the profile, and whether this WebKit has them.
    var features: [String: Bool] = [:]
    /// Safari's own services as its preferences in this profile have them.
    var safariPreferences: [String: String] = [:]
    /// XPC services the process connected to; the ones refused (`noServiceOutsideTheProxy`) say so.
    var services: [String] = []

    /// Nothing in the process is outside the profile's data or proxy, as far as it can tell.
    var isClean: Bool {
        webViewsOffProfile == 0 && webViewsWithWebRTC == 0 && processProxy
            && probes.values.allSatisfy { $0.hasPrefix("ok ") }
    }
}
