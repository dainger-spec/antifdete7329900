import AppKit
import os
import WebKit

/// Safari's own window — its toolbar, tab bar and address bar — hosted inside this process, with
/// our `WKWebView` as the content of its tab.
///
/// WHAT THIS IS. macOS ships Safari's user interface as a private framework
/// (`/System/Library/PrivateFrameworks/Safari.framework`, with `SafariShared` and `SafariCore`
/// under it). A process that is not Safari can load it and use its classes: measured on macOS 27.0.1
/// with Safari 26 (framework build 22625) — the window opens through Safari's own factory, with a
/// real `BrowserTabViewItem`, and a `WKWebView` of ours added to that tab's `TabContentView` renders
/// in it. `docs/SAFARI_PROCESS.md` §9.1-9.2 holds the measurements and the competitor's version of
/// the same thing.
///
/// WHAT IT COSTS, in one place so it is not discovered later:
///   * Every class and selector here is private and undocumented. Each macOS update can rename or
///     remove any of them. Nothing in this file is allowed to fail the app: every step is guarded,
///     and `isAvailable` stays false when any of it does not line up, so the caller falls back to
///     our own chrome (`BrowserWindowController` in this module — ours, not Safari's class of the
///     same name).
///   * `dlopen` of a private framework needs the hardened runtime's
///     `com.apple.security.cs.disable-library-validation` and no App Sandbox: inside the sandbox
///     this returns false at `load()`.
///   * Safari's chrome reads the `com.apple.Safari` preferences domain. In this process that domain
///     resolves to Safari's own container and is refused, so what it would have read arrives nil.
///     The process therefore has to run with `CFFIXED_USER_HOME` pointed at the profile's directory
///     (which is also where Safari's frameworks then keep their own databases), and until that
///     directory holds a seeded `com.apple.Safari.plist`, `prepare()` has to tolerate the nils.
///   * `NSApp` must be Safari's `BrowserApplication`: its window factory sends it selectors plain
///     `NSApplication` does not have. So this is for a process whose whole job is one profile's
///     window — the per-profile child process — never for the process that shows the profile list.
@MainActor
enum SafariChrome {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")

    private static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
        "/System/Library/PrivateFrameworks/SafariShared.framework/Versions/A/SafariShared",
        "/System/Library/PrivateFrameworks/SafariFoundation.framework/Versions/A/SafariFoundation",
    ]

    private(set) static var isAvailable = false

    // MARK: Loading

    /// Loads Safari's private frameworks. False when they cannot be loaded (the sandbox, library
    /// validation, or a macOS that no longer ships them), and then nothing else here may be called.
    @discardableResult
    static func load() -> Bool {
        guard !isAvailable else { return true }
        for path in frameworkPaths {
            guard dlopen(path, RTLD_NOW) != nil else {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown"
                log.error("Safari's chrome is unavailable: \(path, privacy: .public) did not load (\(reason, privacy: .public))")
                return false
            }
        }
        // The window factory walks Safari's document controller and its application object; without
        // these classes the rest of this file has nothing to drive.
        for className in ["BrowserApplication", "BrowserWindowController", "BrowserTabViewItem"] {
            guard NSClassFromString(className) != nil else {
                log.error("Safari's chrome is unavailable: no \(className, privacy: .public) in this Safari")
                return false
            }
        }
        isAvailable = true
        return true
    }

    /// Makes `NSApp` Safari's own application object. Must run before anything in this process
    /// touches `NSApplication.shared`, and only in a process that hosts Safari's chrome.
    @discardableResult
    static func installApplication() -> Bool {
        guard isAvailable, let applicationClass = NSClassFromString("BrowserApplication") else { return false }
        let shared = NSSelectorFromString("sharedApplication")
        guard (applicationClass as AnyObject).responds(to: shared) else { return false }
        _ = (applicationClass as AnyObject).perform(shared)
        let installed = NSApp?.isKind(of: applicationClass) ?? false
        log.info("NSApp is \(String(describing: NSApp.map { type(of: $0) }), privacy: .public), Safari's own: \(installed, privacy: .public)")
        return installed
    }

    // MARK: Preparing

    /// What Safari's app delegate does for its own chrome before any window exists. Each step is
    /// what one measured crash asked for; see `docs/SAFARI_PROCESS.md` §9.1.
    static func prepare() {
        guard isAvailable else { return }
        setUpSearchEnginePreferenceObserver()
        tolerateNilAttributeValues()
        bridgeImageLookups()
        bridgeNibLookups()
        stubChromeFeatures()
    }

    /// `-windowDidLoad` sends new-window telemetry that asserts this observer exists. It accepts a
    /// nil search provider context, but then nothing holds a search engine and the address bar
    /// cannot turn a query into a URL, so build the context first.
    private static func setUpSearchEnginePreferenceObserver() {
        guard let observer: AnyObject = NSClassFromString("WBSSearchEnginePreferenceObserver") else { return }
        let selector = NSSelectorFromString("setUpSharedObserverWithSearchProviderContext:")
        guard observer.responds(to: selector) else {
            log.notice("WBSSearchEnginePreferenceObserver has no setUpSharedObserverWithSearchProviderContext:")
            return
        }
        _ = observer.perform(selector, with: searchProviderContext())
    }

    /// Safari's search providers. In Safari this object comes up with the app; here it has to be
    /// built, and its default engine set, because the `com.apple.Safari` preferences it would read
    /// are another app's container (see the type comment). `SearchProvidersController` is Safari's
    /// subclass of `WBSSearchProvidersController`, and the observer above takes it as its context.
    private static func searchProviderContext() -> NSObject? {
        guard let cls = NSClassFromString("SearchProvidersController") as? NSObject.Type else {
            log.notice("No SearchProvidersController: the address bar will not search")
            return nil
        }
        let controller = cls.init()
        for selectorName in ["_loadAllProviders", "reloadProviders"] {
            let selector = NSSelectorFromString(selectorName)
            if controller.responds(to: selector) {
                _ = controller.perform(selector)
                break
            }
        }
        setDefaultSearchEngine("Google", on: controller)
        log.info("Search providers: \(String(describing: controller.value(forKey: "defaultSearchEngineName")), privacy: .public)")
        return controller
    }

    /// `-setDefaultSearchEngine:forPrivateBrowsing:` takes a `BOOL`, which `perform` cannot pass,
    /// so it is called through its implementation with the right signature.
    private static func setDefaultSearchEngine(_ name: String, on controller: NSObject) {
        typealias SetEngine = @convention(c) (AnyObject, Selector, NSString, Bool) -> Void
        let selector = NSSelectorFromString("setDefaultSearchEngine:forPrivateBrowsing:")
        guard let method = class_getInstanceMethod(type(of: controller), selector) else { return }
        let setEngine = unsafeBitCast(method_getImplementation(method), to: SetEngine.self)
        for privateBrowsing in [false, true] {
            setEngine(controller, selector, name as NSString, privateBrowsing)
        }
    }

    /// Colours Safari reads from its preferences arrive nil here (see the type comment), and
    /// `-addAttribute:value:range:` with a nil value is turned into a crash by
    /// `+[NSApplication _crashOnException:]` while the address bar lays itself out. Dropping nil
    /// values covers every such site at once.
    private static func tolerateNilAttributeValues() {
        typealias AddAttribute = @convention(c) (AnyObject, Selector, NSString, AnyObject?, NSRange) -> Void
        let selector = NSSelectorFromString("addAttribute:value:range:")
        for className in ["NSConcreteMutableAttributedString", "NSMutableAttributedString"] {
            guard let cls = NSClassFromString(className),
                  let method = class_getInstanceMethod(cls, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: AddAttribute.self)
            let replacement: @convention(block) (AnyObject, NSString, AnyObject?, NSRange) -> Void = { object, name, value, range in
                guard let value else { return }
                original(object, selector, name, value, range)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// Safari's chrome asks the *main* bundle for its icons, and in this process that is our own
    /// executable, so they come back nil and arrays built from them throw. Look in the frameworks'
    /// own bundles instead, then in SF Symbols.
    private static func bridgeImageLookups() {
        typealias ImageNamed = @convention(c) (AnyObject, Selector, NSString) -> NSImage?
        let selector = NSSelectorFromString("imageNamed:")
        guard let method = class_getClassMethod(NSImage.self, selector) else { return }
        let bundles = chromeBundles
        let original = unsafeBitCast(method_getImplementation(method), to: ImageNamed.self)
        let replacement: @convention(block) (AnyObject, NSString) -> NSImage? = { cls, name in
            if let image = original(cls, selector, name) { return image }
            for bundle in bundles {
                if let image = bundle.image(forResource: name as String) { return image }
            }
            return NSImage(systemSymbolName: name as String, accessibilityDescription: nil)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Safari's view controllers load their nibs out of the framework they were built in, and
    /// `NSViewController` works that bundle out as the *main* bundle — in this process, our own
    /// executable — so `-[NSNib _initWithNibNamed:bundle:options:]` finds nothing and the chrome
    /// throws as soon as it builds a sidebar or a start page. Intercept the call that loads the nib
    /// and name the bundle that actually holds a nib of that name.
    ///
    /// Choosing by the controller's own framework is not enough: Safari's classes load nibs out of
    /// each other's frameworks (`LibraryViewController` lives in Safari.framework), so the bundle is
    /// chosen by looking for the nib itself.
    private static func bridgeNibLookups() {
        typealias NibWithName = @convention(c) (AnyObject, Selector, NSString, Bundle?) -> AnyObject?
        let loader = NSSelectorFromString("_nibWithName:bundle:")
        guard let method = class_getInstanceMethod(NSViewController.self, loader) else {
            log.notice("No -[NSViewController _nibWithName:bundle:]: Safari's chrome will not find its nibs")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: NibWithName.self)
        let replacement: @convention(block) (AnyObject, NSString, Bundle?) -> AnyObject? = { object, name, bundle in
            if bundle?.bundlePath.hasPrefix("/System/") != true, let own = chromeBundle(holdingNib: name as String) {
                return original(object, loader, name, own)
            }
            return original(object, loader, name, bundle)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Every bundle Safari's chrome keeps nibs and assets in, under both the ordinary path and the
    /// cryptex one, since a Safari update moves the frameworks between them.
    private static let chromeBundles: [Bundle] = {
        let frameworks = ["Safari", "SafariShared", "SafariSharedUI", "SafariFoundation", "SafariCore", "PasswordManagerUI"]
        let roots = ["/System/Library/PrivateFrameworks",
                     "/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks"]
        return roots.flatMap { root in frameworks.compactMap { Bundle(path: "\(root)/\($0).framework") } }
    }()

    /// The bundle that holds `name.nib`, or nil when none of Safari's does.
    private static func chromeBundle(holdingNib name: String) -> Bundle? {
        if let known = nibBundles[name] { return known }
        guard let found = chromeBundles.first(where: { $0.path(forResource: name, ofType: "nib") != nil }) else {
            log.notice("No Safari bundle holds \(name, privacy: .public).nib")
            return nil
        }
        nibBundles[name] = found
        return found
    }

    private static var nibBundles: [String: Bundle] = [:]

    /// Features of Safari's chrome that need services only Safari has, and take the process down
    /// when they do not find them. None of them is wanted here.
    ///
    ///   * automatic tab clustering: Swift code that traps while the window loads.
    ///   * the address bar's assistant button: its icon comes from somewhere we cannot serve, and
    ///     an array built from the nil throws.
    ///   * donating the page's text to Siri intelligence: a timer about five seconds after a page
    ///     loads (`-[BrowserNavigationDelegate _cachePageTextSoon]`) asks
    ///     `+[WBSHistoryController existingSharedHistoryController]`, which traps because this
    ///     process never built Safari's history controller. This one kills a window that is
    ///     already up and rendering, so it has to be stubbed even though nothing visible uses it.
    private static func stubChromeFeatures() {
        let nothing: [(String, String)] = [
            ("BrowserWindowController", "_setUpClusterManagerIfNeeded"),
            ("BrowserNavigationDelegate", "donatePageTextMetadata:allowingDonationWithoutReaderText:"),
        ]
        for (className, selectorName) in nothing {
            replaceWithConstant(className, selectorName) { nil }
        }
        replaceWithConstant("UnifiedField", "_assistantButtonIconForContentOption:withSparkle:") {
            NSImage(size: NSSize(width: 1, height: 1))
        }
    }

    /// Replaces one object-returning method with a constant. On arm64 a block that only returns a
    /// value stands in for a method of any arity: the arguments are left in their registers.
    private static func replaceWithConstant(_ className: String, _ selectorName: String, _ value: @escaping () -> AnyObject?) {
        guard let cls = NSClassFromString(className),
              let method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) else {
            log.notice("Nothing to replace: -[\(className, privacy: .public) \(selectorName, privacy: .public)]")
            return
        }
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { _ in value() }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    // MARK: Opening a window

    /// Opens one of Safari's browser windows and puts `webView` in its tab, with `addressText` in
    /// its address bar. Returns the window's controller (Safari's `BrowserWindowController`), or nil
    /// when any step of it did not work — the caller then opens our own window instead.
    ///
    /// Safari's own content controller stays in place and the web view is added to its view:
    /// replacing the controller means implementing the tab protocol Safari's own one implements
    /// (`-currentBrowserViewController` and whatever follows it), which buys nothing here.
    @discardableResult
    static func openWindow(embedding webView: WKWebView, addressText: String?) -> NSWindowController? {
        guard isAvailable, let windowClass: AnyObject = NSClassFromString("BrowserWindowController") else { return nil }
        let factory = NSSelectorFromString("openEmptyBrowserWindowController")
        guard windowClass.responds(to: factory) else {
            log.error("No +[BrowserWindowController openEmptyBrowserWindowController] in this Safari")
            return nil
        }
        guard let controller = windowClass.perform(factory)?.takeUnretainedValue() as? NSWindowController else {
            log.error("Safari's window factory returned nothing")
            return nil
        }
        guard let tab = firstTab(of: windowClass) else {
            log.error("Safari's new window reported no tab")
            return controller
        }
        guard let content = tab.perform(NSSelectorFromString("tabContentViewController"))?.takeUnretainedValue() as? NSViewController else {
            log.error("Safari's tab has no content view controller")
            return controller
        }
        let host = content.view
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
        if let addressText {
            let selector = NSSelectorFromString("setURLString:")
            if tab.responds(to: selector) { _ = tab.perform(selector, with: addressText as NSString) }
        }
        log.info("Safari's chrome is up, with our web view in its tab")
        return controller
    }

    /// The tab of the window just opened. Safari hands out its tabs per process, newest last.
    private static func firstTab(of windowClass: AnyObject) -> NSObject? {
        let selector = NSSelectorFromString("allBrowserTabViewItemsFromAllWindows")
        guard windowClass.responds(to: selector),
              let items = windowClass.perform(selector)?.takeUnretainedValue() as? [AnyObject] else { return nil }
        return items.last as? NSObject
    }
}

// MARK: - Standalone run

extension SafariChrome {
    /// `PrivacyBrowser --safari-chrome [url]`: Safari's chrome with one of our web views in it, on
    /// an ephemeral data store, as the way to try this outside the profile machinery. Returns
    /// without running anything when the frameworks cannot be loaded, which is what a sandboxed
    /// build does.
    static func startStandalone(arguments: [String]) {
        guard load() else {
            FileHandle.standardError.write(Data("Safari's private frameworks did not load: this build is sandboxed or library validation is on (see SafariChrome.swift)\n".utf8))
            exit(1)
        }
        installApplication()
        prepare()
        let address = arguments.firstIndex(of: "--safari-chrome")
            .flatMap { arguments.indices.contains($0 + 1) && !arguments[$0 + 1].hasPrefix("--") ? arguments[$0 + 1] : nil }
            ?? "https://example.com"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if let url = URL(string: address) { webView.load(URLRequest(url: url)) }
        guard let controller = openWindow(embedding: webView, addressText: address) else {
            FileHandle.standardError.write(Data("Safari's window did not open; the log says which step\n".utf8))
            exit(1)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }
}
