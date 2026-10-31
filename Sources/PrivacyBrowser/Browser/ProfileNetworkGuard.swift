import BrowserCore
import Foundation
import Network
import os
import Security
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
    /// How this process answers its loads' challenges (`everyChallengeIsTheProfiles`).
    private static var challengePolicy: ProfileChallengePolicy?
    /// The web view every worker of the process takes its preferences from was made
    /// (`ensureWorkerTemplate`).
    private static var workerTemplateMade = false
    /// Set while that web view is being built: it is the one web view of the process that is
    /// meant to be on the closed store, and the initializer's net leaves it as it is.
    private static var makingTemplate = false
    /// The navigation delegate of web views that have none (`inspect`); a web view holds it weakly.
    private static var defaultNavigationDelegate: WebViewChallenges?

    // MARK: Engaging

    /// Holds this process to `proxy` (or, with none, to no proxy but still to the profile's store).
    /// Throws when the proxy cannot be applied: the process must then not run at all.
    static func engage(profileID: UUID, proxy: ProxySettings?, safeBrowsing: Bool = false) throws {
        guard proxies == nil else { return }
        let proxies = try ProxyConfigurationFactory.make(proxy)
        self.proxies = proxies
        self.profileID = profileID
        let policy = ProfileChallengePolicy(
            hasProxy: !proxies.isEmpty,
            proxyCredential: proxy?.username.map { URLCredential(user: $0, password: proxy?.password ?? "", persistence: .forSession) })
        challengePolicy = policy
        if !proxies.isEmpty {
            // Lock 3. The default privacy context is what every Network.framework connection and
            // URLSession task of this process uses unless it brings its own (macOS 14).
            NWParameters.PrivacyContext.default.proxyConfigurations = proxies
        }
        // With a proxy, every session of the process carries it; with or without, none shares the
        // app's own cookie jar, cache or saved credentials with the other profiles' processes.
        missingHooks += proxyEverySessionConfiguration(proxies, delegate: StoreChallenges(policy: policy))
        missingHooks += closeTheProcess(udp: !proxies.isEmpty)
        // QUIC goes around any proxy: a profile with one does not run with UDP open.
        if !proxies.isEmpty, !closures.sorted.contains("udp") {
            throw CoreError.invalidConfiguration("UDP could not be closed to the profile's process")
        }
        missingHooks += everyStoreStartsClosed(except: profileID)
        missingHooks += everyWebViewGetsTheProfilesData()
        missingHooks += pinPrivacyPreferences()
        missingHooks += pinUserAgent()
        missingHooks += noPagePicksAnotherStore()
        missingHooks += theProfilesContentStays()
        missingHooks += everyChallengeIsTheProfiles(policy)
        missingHooks += noServiceOutsideTheProxy(safeBrowsing: safeBrowsing)
        missingHooks += nothingIsHandedOff()
        HandOffs.closeForProfileProcess()
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
        ensureWorkerTemplate()
    }

    /// The first web view of this process, built before any profile's: never shown, never
    /// loading, on the closed store, with WebRTC and every feature that leaves a proxy off.
    ///
    /// WebKit gives every shared worker and service worker of a process — whichever profile's page
    /// started it — the preferences of the first web view that process ever built
    /// (`WebProcessPool::m_remoteWorkerPreferences`, copied once and never updated). Were that
    /// web view a profile's without a proxy, a page of a profile with one could start a shared
    /// worker with WebTransport in it, which no proxy carries. So the first one is this. A
    /// profile's service workers get the profile's own preferences besides
    /// (`BrowserSession`, `_setServiceWorkerOverridePreferences:`). Idempotent; made in a profile's
    /// process when its default store is closed, before Safari's chrome builds anything.
    ///
    /// Only there. In the manager's process, which runs profile after profile, a template made
    /// there kept a stopped profile's session alive in WebKit — measured in CI run 383, released or
    /// not: its session cookies came back at the next launch. What the manager's profiles' workers
    /// get without it is measured by the self-test (`workersInOurWindows`).
    static func ensureWorkerTemplate() {
        guard !workerTemplateMade else { return }
        workerTemplateMade = true
        WebDataStoreVault.ensureWebKitInitialized()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = closedStore
        WebKitPreferences.setBool(configuration.preferences, "_setPeerConnectionEnabled:", false)
        for key in BrowserSession.featuresOffWithAProxy { WebKitFeatures.set(configuration.preferences, key, false) }
        makingTemplate = true
        _ = WKWebView(frame: .zero, configuration: configuration)
        makingTemplate = false
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
            if makingTemplate { return original(receiver, selector, frame, configuration) }
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
                if makingTemplate { return original(receiver, initialize, configuration) }
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

    /// The profile's scripts and its rule list stay in every page of the process, whatever
    /// Safari's chrome does to the content controllers they were put in.
    ///
    ///   * A navigation can carry a content controller of its own (`WKWebpagePreferences`, as it
    ///     can carry a data store): it gets the profile's content first.
    ///   * Safari empties a controller's scripts or rule lists when it reloads its own: the
    ///     profile's are put back right after (`BrowserSession.restoreContent`).
    ///   * With a proxy, "Reload Without Content Blockers" and a site's "content blockers off"
    ///     switch everything off but the proxied profile's rule list, which is what keeps a page's
    ///     dns-prefetch from being resolved by this Mac (`ContentRules`): the blocker is the
    ///     exception every such switch keeps on, and the reload without blockers is a reload.
    private static func theProfilesContentStays() -> [String] {
        typealias ObjectSetter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        typealias Action = @convention(c) (AnyObject, Selector) -> Void
        let pagePreferences: AnyClass = WKWebpagePreferences.self

        let pageController = NSSelectorFromString("_setUserContentController:")
        if let method = class_getInstanceMethod(pagePreferences, pageController) {
            let original = unsafeBitCast(method_getImplementation(method), to: ObjectSetter.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { preferences, controller in
                if let controller = controller as? WKUserContentController {
                    session?.applyContent(to: controller)
                }
                original(preferences, pageController, controller)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // After each, what the profile put in that controller is put back.
        let controllerClass: AnyClass = WKUserContentController.self
        for name in ["removeAllUserScripts", "removeAllContentRuleLists", "_removeAllUserContentFilters"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(controllerClass, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Action.self)
            let replacement: @convention(block) (AnyObject) -> Void = { controller in
                original(controller, selector)
                if let controller = controller as? WKUserContentController { session?.restoreContent(in: controller) }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        for name in ["_removeAllUserScriptsAssociatedWithContentWorld:", "removeContentRuleList:", "_removeUserContentFilter:",
                     "_removeAllContentRuleListsAssociatedWithContentWorld:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(controllerClass, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: ObjectSetter.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { controller, argument in
                original(controller, selector, argument)
                if let controller = controller as? WKUserContentController { session?.restoreContent(in: controller) }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        guard !(proxies ?? []).isEmpty else { return [] }
        let blocker: Set<String> = [ContentRules.identifier]
        let lists = NSSelectorFromString("_setContentRuleListsEnabled:exceptions:")
        typealias ListsSetter = @convention(c) (AnyObject, Selector, Bool, NSSet?) -> Void
        let listsMethod = class_getInstanceMethod(pagePreferences, lists)
        let listsOriginal = listsMethod.map { unsafeBitCast(method_getImplementation($0), to: ListsSetter.self) }
        if let method = listsMethod, let original = listsOriginal {
            // The exceptions are the lists that do the opposite of `enabled`: with everything
            // off, the blocker is one of them; with everything on, it is never one.
            let replacement: @convention(block) (AnyObject, Bool, NSSet?) -> Void = { preferences, enabled, exceptions in
                var kept = Set((exceptions as? Set<String>) ?? [])
                if enabled { kept.subtract(blocker) } else { kept.formUnion(blocker) }
                original(preferences, lists, enabled, kept as NSSet)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let blockers = NSSelectorFromString("_setContentBlockersEnabled:")
        if let method = class_getInstanceMethod(pagePreferences, blockers) {
            typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
            let replacement: @convention(block) (AnyObject, Bool) -> Void = { preferences, enabled in
                if enabled {
                    original(preferences, blockers, true)
                } else if let listsOriginal {
                    log.notice("Content blockers off for a page: every list but the proxied profile's rule list")
                    listsOriginal(preferences, lists, false, blocker as NSSet)
                } else {
                    log.notice("Content blockers off for a page refused: this WebKit cannot keep the proxied profile's rule list on alone")
                    original(preferences, blockers, true)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let reloadWithout = NSSelectorFromString("_reloadWithoutContentBlockers")
        if let method = class_getInstanceMethod(WKWebView.self, reloadWithout) {
            let replacement: @convention(block) (AnyObject) -> WKNavigation? = { webView in
                log.notice("Reload without content blockers: reloaded with the proxied profile's rule list")
                return (webView as? WKWebView)?.reload()
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        return []
    }

    // MARK: Challenges

    /// The challenges of the profile's loads are answered by the profile, whoever's delegate gets
    /// them (`ProfileChallengePolicy`): the proxy's own request for credentials with the profile's
    /// credentials, and, with a proxy, every server-trust question without this Mac fetching
    /// anything for it (`ServerTrust`) — never with the system's default handling.
    ///
    /// WebKit asks a web view's navigation delegate, a download's delegate and, for a load no page
    /// is behind, its data store's delegate; and it decides whether to ask a delegate at all when
    /// the delegate is set, by whether it answers that question. So the delegates are covered as
    /// they are set: their class answers the profile's part before its own code runs, and a class
    /// with no answer of its own gets one that leaves the rest to the system's default, as before.
    /// A web view with no navigation delegate at all gets one that does only this
    /// (`inspect`). And a web view's certificate, read back for the address bar's padlock and the
    /// certificate sheet, never fetches either.
    private static func everyChallengeIsTheProfiles(_ policy: ProfileChallengePolicy) -> [String] {
        var missing: [String] = []
        typealias ObjectSetter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        for (owner, setter, question, takesSubject) in [
            (WKWebView.self as AnyClass, "setNavigationDelegate:", "webView:didReceiveAuthenticationChallenge:completionHandler:", true),
            (WKDownload.self as AnyClass, "setDelegate:", "download:didReceiveAuthenticationChallenge:completionHandler:", true),
            (WKWebsiteDataStore.self as AnyClass, "set_delegate:", "didReceiveAuthenticationChallenge:completionHandler:", false),
        ] {
            let selector = NSSelectorFromString(setter)
            guard let method = class_getInstanceMethod(owner, selector) else {
                missing.append("-[\(NSStringFromClass(owner)) \(setter)]")
                continue
            }
            let original = unsafeBitCast(method_getImplementation(method), to: ObjectSetter.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, delegate in
                if let delegate { answerChallenges(of: delegate, question, takesSubject: takesSubject, policy) }
                original(receiver, selector, delegate)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        if policy.hasProxy {
            let serverTrust = NSSelectorFromString("serverTrust")
            if let method = class_getInstanceMethod(WKWebView.self, serverTrust) {
                typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<SecTrust>?
                let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
                let replacement: @convention(block) (AnyObject) -> Unmanaged<SecTrust>? = { webView in
                    let trust = original(webView, serverTrust)
                    if let trust { SecTrustSetNetworkFetchAllowed(trust.takeUnretainedValue(), false) }
                    return trust
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
            }
        }
        return missing
    }

    /// Classes (by name) whose answer to a challenge question already goes through the profile.
    nonisolated private static let coveredClasses = LockedSet()

    /// Makes `delegate`'s class answer `question` — `<subject>:didReceiveAuthenticationChallenge:
    /// completionHandler:`, or without the subject — the profile's way first (`policy`).
    private static func answerChallenges(of delegate: AnyObject, _ question: String, takesSubject: Bool,
                                         _ policy: ProfileChallengePolicy) {
        guard !(delegate is AnswersProfileChallenges), let delegateClass = object_getClass(delegate) else { return }
        guard coveredClasses.insertIfNew("\(NSStringFromClass(delegateClass)) \(question)") else { return }
        typealias Completion = @convention(block) (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        let selector = NSSelectorFromString(question)
        let existing = class_getInstanceMethod(delegateClass, selector)
        let implementation: IMP
        if takesSubject {
            typealias Question = @convention(c) (AnyObject, Selector, AnyObject?, URLAuthenticationChallenge, Completion) -> Void
            let original = existing.map { unsafeBitCast(method_getImplementation($0), to: Question.self) }
            let replacement: @convention(block) (AnyObject, AnyObject?, URLAuthenticationChallenge, @escaping Completion) -> Void = { receiver, subject, challenge, completion in
                if policy.answer(challenge, { completion($0, $1) }) { return }
                if let original {
                    original(receiver, selector, subject, challenge, completion)
                } else {
                    completion(.performDefaultHandling, nil)
                }
            }
            implementation = imp_implementationWithBlock(replacement)
        } else {
            typealias Question = @convention(c) (AnyObject, Selector, URLAuthenticationChallenge, Completion) -> Void
            let original = existing.map { unsafeBitCast(method_getImplementation($0), to: Question.self) }
            let replacement: @convention(block) (AnyObject, URLAuthenticationChallenge, @escaping Completion) -> Void = { receiver, challenge, completion in
                if policy.answer(challenge, { completion($0, $1) }) { return }
                if let original {
                    original(receiver, selector, challenge, completion)
                } else {
                    completion(.performDefaultHandling, nil)
                }
            }
            implementation = imp_implementationWithBlock(replacement)
        }
        // On the delegate's own class: replaces its method, or adds one in front of an inherited
        // one (which the replacement then calls), or adds the only one.
        let types = existing.flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) }
            ?? (takesSubject ? "v@:@@@?" : "v@:@@?")
        class_replaceMethod(delegateClass, selector, implementation, types)
        log.notice("Challenges of \(NSStringFromClass(delegateClass), privacy: .public) go through the profile first")
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
                      "passd", "translationd", "PasswordBreach",
                      // Seen in CI connected from the hosted chrome: Screen Time's web usage (which
                      // syncs through iCloud), Siri Suggestions' and the personalization store's
                      // learning, shortcuts and link context, input analytics, Safari's own
                      // notifications, and the shared web credentials daemon, which fetches a site's
                      // associated-domains file as this Mac.
                      "ScreenTime", "suggestd", "PersonalizationPortrait", "synapse", "linkd", "inputanalyticsd",
                      "SafariNotificationAgent", "SharedWebCredentials",
                      // Stores that keep page titles, addresses or usage outside the profile: the
                      // Spotlight index, usage tracking and Biome, the knowledge store; and sharing.
                      "corespotlight", "spotlight.IndexAgent", "UsageTracking", "biome", "knowledge",
                      "duetexpert", "coreduet", "intelligenceplatform", "sharingd",
                      // iCloud Keychain's AutoFill (off in the profile's Safari settings; its agent
                      // was seen fetching as this Mac while the hosted chrome ran).
                      "AuthenticationServices"]
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
        /// True when `name` was not in the set and now is.
        func insertIfNew(_ name: String) -> Bool { lock.withLock { names.insert(name).inserted } }
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
        webView.allowsLinkPreview = false // and kept off (`HandOffs`)
        HostedPageHistory.follow(webView)
        // The profile's User-Agent, not whatever Safari's code computes (and kept: `pinUserAgent`).
        if let agent = profileUserAgent { webView.customUserAgent = agent }
        // A web view nobody gives a navigation delegate would have its challenges answered the
        // system's default way: until someone does, it has one that answers only those.
        if webView.navigationDelegate == nil, let challengePolicy {
            if defaultNavigationDelegate == nil { defaultNavigationDelegate = WebViewChallenges(policy: challengePolicy) }
            webView.navigationDelegate = defaultNavigationDelegate
        }
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
        // A page's dns-prefetch is resolved by this Mac, outside the proxy (`ContentRules`); in
        // WebKit before 7621 it never consults the content rules, and Safari turns it on.
        pin("_setDNSPrefetchingEnabled:", required: false) { asked in asked && (proxies ?? []).isEmpty }
        // ICE candidate filtering (no host addresses to a page that was not granted the camera)
        // is on, as in Safari; gathering on every interface only for the tunnel's hardware checks.
        pin("_setICECandidateFilteringEnabled:", required: false) { _ in true }
        pin("_setEnumeratingAllNetworkInterfacesEnabled:", required: false) { asked in asked && allInterfacesAllowed }

        // The feature switches, by key. Every boolean preference is a feature too, WebRTC's
        // included, so the same switch reaches it by another way: the same answers there.
        for name in ["_setEnabled:forFeature:", "_setEnabled:forExperimentalFeature:", "_setEnabled:forInternalDebugFeature:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(preferencesClass, selector) else { continue }
            typealias FeatureSetter = @convention(c) (AnyObject, Selector, Bool, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: FeatureSetter.self)
            let replacement: @convention(block) (AnyObject, Bool, AnyObject?) -> Void = { preferences, asked, feature in
                let key = (feature as? NSObject).flatMap { object -> String? in
                    object.responds(to: NSSelectorFromString("key")) ? object.value(forKey: "key") as? String : nil
                }
                original(preferences, selector, pinnedFeature(key, asked: asked), feature)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        return missing
    }

    /// The User-Agent the profile declares (`ProfileConfiguration.userAgent`), nil for WebKit's own.
    private static var profileUserAgent: String? {
        session?.configuration.userAgent(hostSafariVersion: HostSafari.version)
    }

    /// A web view of the process keeps the profile's User-Agent, whoever sets another (Safari's
    /// Develop menu, its site quirks).
    private static func pinUserAgent() -> [String] {
        let selector = NSSelectorFromString("setCustomUserAgent:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return ["-[WKWebView setCustomUserAgent:]"] }
        typealias Setter = @convention(c) (AnyObject, Selector, NSString?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let replacement: @convention(block) (AnyObject, NSString?) -> Void = { webView, asked in
            original(webView, selector, profileUserAgent.map { $0 as NSString } ?? asked)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return []
    }

    /// The feature `key` as the profile allows it, when something asks for `asked`.
    private static func pinnedFeature(_ key: String?, asked: Bool) -> Bool {
        let proxied = !(proxies ?? []).isEmpty
        switch key {
        case "PeerConnectionEnabled"?:
            return asked && (session.map { $0.configuration.effectiveWebRTCPolicy != .disabled } ?? false)
        case "ICECandidateFilteringEnabled"?:
            return true
        case "EnumeratingAllNetworkInterfacesEnabled"?:
            return asked && allInterfacesAllowed
        case "DNSPrefetchingEnabled"?:
            return asked && !proxied
        case "SafeBrowsingEnabled"?:
            return asked && (session?.configuration.safeBrowsingEnabled ?? false)
        case let key? where proxied && BrowserSession.featuresOffWithAProxy.contains(key):
            return false
        default:
            return asked
        }
    }

    /// WebRTC may gather on every interface: the profile's WebRTC goes through the tunnel, and the
    /// hardware checks asked for it (`BrowserSession.applyPrivacyPreferences`).
    private static var allInterfacesAllowed: Bool {
        guard let session, case .relay = session.configuration.webRTCRouting else { return false }
        return DebugSwitches.tunnelAllInterfaces
    }

    /// Each way of turning on what the profile has off, tried on preferences of no web view: the
    /// ways that get through the pins (`pinPrivacyPreferences`), for the report. Empty is right.
    private static func pinBypasses() -> [String] {
        guard let session else { return [] }
        var bypasses: [String] = []
        let proxied = !(proxies ?? []).isEmpty
        var off: [(key: String, getter: String?, setter: String?)] = []
        if session.configuration.effectiveWebRTCPolicy == .disabled {
            off.append(("PeerConnectionEnabled", "_peerConnectionEnabled", "_setPeerConnectionEnabled:"))
        }
        if !session.configuration.safeBrowsingEnabled {
            off.append(("SafeBrowsingEnabled", "_isSafeBrowsingEnabled", "_setSafeBrowsingEnabled:"))
        }
        if proxied {
            off.append(("DNSPrefetchingEnabled", "_dnsPrefetchingEnabled", "_setDNSPrefetchingEnabled:"))
            for key in BrowserSession.featuresOffWithAProxy.sorted() {
                off.append((key: key, getter: nil, setter: nil))
            }
        }
        for (key, getter, setter) in off {
            let scratch = WKPreferences()
            WebKitFeatures.set(scratch, key, false)
            if let setter { WebKitPreferences.setBool(scratch, setter, false) }
            func isOn() -> Bool {
                if let getter, let value = WebKitPreferences.bool(scratch, getter) { return value }
                return WebKitFeatures.isEnabled(scratch, key) == true
            }
            if let setter, WebKitPreferences.setBool(scratch, setter, true), isOn() {
                bypasses.append("\(setter) → \(key)")
            }
            for route in ["_setEnabled:forFeature:", "_setEnabled:forExperimentalFeature:", "_setEnabled:forInternalDebugFeature:"] {
                if WebKitFeatures.set(scratch, key, true, through: route), isOn() {
                    bypasses.append("\(route) → \(key)")
                }
            }
        }
        return bypasses
    }

    /// What the kernel refuses this process, for the life of the process, through a sandbox
    /// profile that allows everything else:
    ///
    ///   * With a proxy, every UDP datagram it would send — QUIC above all, which goes around any
    ///     proxy: Network.framework ignores a privacy context's proxies for QUIC (reported on macOS
    ///     27.0.1, FB24760235), and no HTTP or SOCKS5 proxy here carries UDP anyway. Names are still
    ///     resolved, by mDNSResponder over a local socket; WebKit's own processes are not this one,
    ///     and their UDP (WebRTC, WebTransport) is off with a proxy.
    ///   * Any read or write in the real Safari's places (`SafariPaths`): Safari's frameworks find
    ///     them from the account's real home, not from the profile's, and a profile must neither
    ///     leave its browsing there nor read the user's own into itself.
    nonisolated private static func closeTheProcess(udp: Bool) -> [String] {
        var rules: [String] = []
        if udp { rules.append("(deny network-outbound (remote udp \"*:*\"))") }
        if let realHome = SafariPaths.realHome, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
           realHome != home {
            rules.append("(deny file-read* file-write* \(SafariPaths.sandboxFilter(realHome: realHome)))")
        }
        guard !rules.isEmpty else { return [] }
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "sandbox_init") else {
            return ["sandbox_init (UDP and the real Safari's places stay open)"]
        }
        let sandboxInit = unsafeBitCast(symbol, to: SandboxInit.self)
        let profile = "(version 1)(allow default)" + rules.joined()
        var error: UnsafeMutablePointer<CChar>?
        guard sandboxInit(profile, 0, &error) == 0 else {
            let reason = error.map { String(cString: $0) } ?? "unknown"
            Logger(subsystem: "PrivacyBrowser", category: "ProfileNetworkGuard")
                .error("The process could not be closed: \(reason, privacy: .private) (\(profile, privacy: .private))")
            return ["sandbox: not applied (\(reason))"]
        }
        if udp { closures.insert("udp") }
        if rules.count > (udp ? 1 : 0) { closures.insert("safari-places") }
        Logger(subsystem: "PrivacyBrowser", category: "ProfileNetworkGuard")
            .notice("The kernel closes to this process: \(closures.sorted.joined(separator: ", "), privacy: .public)")
        return []
    }

    /// What the kernel closed to this process (`closeTheProcess`): "udp", "safari-places".
    nonisolated private static let closures = LockedSet()

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
    ///
    /// And a session made without a delegate gets `delegate`, which answers the profile's part of
    /// its challenges (`ProfileChallengePolicy`) — a server's certificate checked without this Mac
    /// fetching for it — where with no delegate the system's default handling would.
    nonisolated private static func proxyEverySessionConfiguration(_ proxies: [ProxyConfiguration],
                                                                   delegate: StoreChallenges) -> [String] {
        var missing: [String] = []
        typealias Factory = @convention(c) (AnyObject, Selector) -> Unmanaged<URLSessionConfiguration>?
        for name in ["defaultSessionConfiguration", "ephemeralSessionConfiguration"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else {
                missing.append("+[NSURLSessionConfiguration \(name)]")
                continue
            }
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let isDefault = name == "defaultSessionConfiguration"
            let replacement: @convention(block) (AnyObject) -> Unmanaged<URLSessionConfiguration>? = { cls in
                let result = original(cls, selector)
                if let configuration = result?.takeUnretainedValue(), configuration.proxyConfigurations.isEmpty {
                    configuration.proxyConfigurations = proxies
                }
                // The default configuration's cookie jar, cache and saved credentials are the
                // app's, which the process of every profile of this bundle would share: none here.
                if isDefault, let configuration = result?.takeUnretainedValue() {
                    configuration.httpCookieStorage = nil
                    configuration.urlCache = nil
                    configuration.urlCredentialStorage = nil
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
                    .notice("A background URL session was asked for (\(String(describing: identifier), privacy: .private)); it runs in this process, through the profile's proxy")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.proxyConfigurations = proxies
                return configuration
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        typealias Maker = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        let withDelegate = NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:")
        if let method = class_getClassMethod(URLSession.self, withDelegate) {
            let original = unsafeBitCast(method_getImplementation(method), to: Maker.self)
            let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>? = { cls, configuration, given, queue in
                // A configuration made some other way (its own initializer, a private factory) or
                // emptied since: the session is made with the profile's proxies all the same (a
                // session copies its configuration when it is made).
                if !proxies.isEmpty, let configuration = configuration as? URLSessionConfiguration,
                   configuration.proxyConfigurations.isEmpty {
                    configuration.proxyConfigurations = proxies
                }
                return original(cls, withDelegate, configuration, given ?? delegate, queue)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            let plain = NSSelectorFromString("sessionWithConfiguration:")
            if let method = class_getClassMethod(URLSession.self, plain) {
                let replacement: @convention(block) (AnyObject, AnyObject?) -> Unmanaged<AnyObject>? = { cls, configuration in
                    original(cls, withDelegate, configuration, delegate, nil)
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
            }
        } else {
            missing.append("+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]")
        }

        let shared = NSSelectorFromString("sharedSession")
        if let method = class_getClassMethod(URLSession.self, shared) {
            let configuration = URLSessionConfiguration.default
            configuration.proxyConfigurations = proxies
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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
            if view.allowsLinkPreview { report.webViewsWithLinkPreview += 1 }
            if report.hasProxy {
                if WebKitPreferences.bool(configuration.preferences, "_dnsPrefetchingEnabled") == true {
                    report.webViewsWithDNSPrefetch += 1
                }
                for key in BrowserSession.featuresOffWithAProxy where WebKitFeatures.isEnabled(configuration.preferences, key) == true {
                    report.webViewsWithFeatureOn[key, default: 0] += 1
                }
            }
        }
        report.pinBypasses = pinBypasses()
        let trust = ServerTrust.tally.counts
        report.trustEvaluated = trust.evaluated
        report.trustRefused = trust.refused
        report.udpClosed = closures.sorted.contains("udp")
        report.safariPlacesClosed = closures.sorted.contains("safari-places")
        report.safariPathsRedirected = SafariPaths.redirected
        report.workerPreferences = BrowserSession.workerPreferencesApplied
        report.webKitVersion = WebKitBuild.version
        let environment = ProcessInfo.processInfo.environment
        report.environmentNames = environment.keys.sorted()
        for name in ["HOME", "TMPDIR", "CFFIXED_USER_HOME"] { report.places[name] = environment[name] ?? "" }
        report.places["temporaryDirectory"] = FileManager.default.temporaryDirectory.path
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
        // What would be handed to another app, to the owner's devices or to their keychain: an
        // address to open (through the proxy's leak host, so that one that did open would be seen
        // in a capture), the sharing services, a copy, a password to keep (`HandOffs`).
        if let probe, var parts = URLComponents(url: probe, resolvingAgainstBaseURL: false) {
            parts.host = parts.host.map { $0.replacingOccurrences(of: "probe-", with: "open-") }
            parts.path = "/pb-leak/opened"
            if let address = parts.url { report.openedInAnotherApp = NSWorkspace.shared.open(address) }
        }
        report.sharingServices = NSSharingService.sharingServices(forItems: [probe ?? URL(string: "https://example.org/")!]).count
        NSPasteboard.general.clearContents()
        report.credentialsKept = URLCredential(user: "pb", password: "pb", persistence: .permanent).persistence != .forSession
        report.handOffsRefused = HandOffs.refused
        if report.hasProxy {
            // UDP and QUIC to addresses nothing answers: refused by the kernel here, and a packet
            // to either in a capture is one that left (scripts/egress_check.py).
            report.udp["udp"] = await datagram(to: "192.0.2.16", using: .udp)
            report.udp["quic"] = await datagram(to: "192.0.2.17", using: NWParameters(quic: NWProtocolQUIC.Options(alpn: ["h3"])))
        }
        return report
    }

    /// What became of a connection to `host`:443 made with `parameters` and given one datagram:
    /// "refused …" when it could not be made or the datagram could not be sent, "sent" or
    /// "ready" when it was (for UDP and QUIC, that is a packet on its way), "waiting" otherwise.
    private static func datagram(to host: String, using parameters: NWParameters) async -> String {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters)
        let queue = DispatchQueue(label: "PrivacyBrowser.udp-probe")
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("pb".utf8), completion: .contentProcessed { error in
                        once.finish(error.map { "refused \($0)" } ?? "sent")
                    })
                case let .failed(error):
                    once.finish("refused \(error)")
                case let .waiting(error):
                    once.finish("refused (waiting) \(error)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { once.finish("no answer in 4 s") }
        }
        connection.cancel()
        return outcome
    }

    /// Resumes a continuation the first time only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
        func finish(_ value: String) {
            let pending = lock.withLock { () -> CheckedContinuation<String, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
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
    /// With a proxy: web views whose dns-prefetch preference is on (which decides dns-prefetch
    /// before WebKit 7621; from then on the content rules do, `ContentRules`).
    var webViewsWithDNSPrefetch = 0
    /// With a proxy: by feature key (`BrowserSession.featuresOffWithAProxy`), web views that have
    /// it on in their engine.
    var webViewsWithFeatureOn: [String: Int] = [:]
    /// Ways of turning on what the profile has off that get through the pins. Empty is right.
    var pinBypasses: [String] = []
    /// Server-trust questions answered without this Mac fetching (`ServerTrust`), and of those
    /// the ones refused.
    var trustEvaluated = 0
    var trustRefused = 0
    /// With a proxy: the kernel refuses this process any UDP (`ProfileNetworkGuard.closeTheProcess`).
    var udpClosed = false
    /// The kernel refuses this process the real Safari's places (`SafariPaths`).
    var safariPlacesClosed = false
    /// The path getters of Safari's frameworks that answer with the profile's home (`SafariPaths`).
    var safariPathsRedirected: [String] = []
    /// With a proxy: what became of a UDP datagram and of a QUIC connection, by name.
    var udp: [String: String] = [:]
    /// The profile's service workers have the profile's preferences (nil: this WebKit cannot).
    var workerPreferences: Bool?
    /// WebKit's version (`CFBundleVersion`), for telling apart what differs between versions.
    var webKitVersion = ""
    /// Web views that would show a link preview (fetched by Quick Look, outside the profile).
    var webViewsWithLinkPreview = 0
    /// An address handed to another app opened there; the sharing services offered; a password
    /// marked permanent would be kept (in the owner's keychain). All three false or 0 is right.
    var openedInAnotherApp = false
    var sharingServices = 0
    var credentialsKept = false
    /// What `HandOffs` refused, by kind ("open", "share", "clipboard").
    var handOffsRefused: [String: Int] = [:]
    /// The names in the process's environment (`ProfileProcess.childEnvironment`), and where its
    /// home and temporary files go: `HOME`, `TMPDIR`, `CFFIXED_USER_HOME` and Foundation's
    /// temporary directory, by those names.
    var environmentNames: [String] = []
    var places: [String: String] = [:]

    /// Nothing in the process is outside the profile's data or proxy, as far as it can tell.
    var isClean: Bool {
        webViewsOffProfile == 0 && webViewsWithWebRTC == 0 && processProxy
            && webViewsWithFeatureOn.values.allSatisfy { $0 == 0 }
            && pinBypasses.isEmpty && (!hasProxy || udpClosed)
            && probes.values.allSatisfy { $0.hasPrefix("ok ") }
    }
}
