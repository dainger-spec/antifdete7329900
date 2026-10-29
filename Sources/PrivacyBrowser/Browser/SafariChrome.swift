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

    /// Loaded up front, all of them: a class that is not registered yet cannot be patched, and
    /// `prepare()` runs before Safari's menu pulls these in by itself. SafariSharedUI is where the
    /// web-extension machinery lives, SafariCore where the assertions come from.
    private static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
        "/System/Library/PrivateFrameworks/SafariShared.framework/Versions/A/SafariShared",
        "/System/Library/PrivateFrameworks/SafariSharedUI.framework/Versions/A/SafariSharedUI",
        "/System/Library/PrivateFrameworks/SafariCore.framework/Versions/A/SafariCore",
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
        log.notice("NSApp is \(String(describing: NSApp.map { type(of: $0) }), privacy: .public), Safari's own: \(installed, privacy: .public)")
        return installed
    }

    // MARK: Preparing

    /// What Safari's app delegate does for its own chrome before any window exists. Each step is
    /// what one measured crash asked for; see `docs/SAFARI_PROCESS.md` §9.1.
    static func prepare() {
        guard isAvailable else { return }
        installExceptionLogging()
        disableStateRestoration()
        setUpSearchEnginePreferenceObserver()
        bridgeImageLookups()
        bridgeColorLookups()
        tolerateNilAttributeValues()
        tolerateNilDictionaryKeys()
        tolerateMissingSafariDirectories()
        tolerateNilDirectoryEnumeration()
        tolerateNilDirectoryListing()
        bridgeNibLookups()
        stubChromeFeatures()
    }

    /// Every failure of a hosted chrome so far has been an Objective-C exception or a trap inside
    /// Safari's code, and AppKit turns the ones thrown during layout into a crash that prints
    /// nothing. The objc runtime's exception preprocessor runs at the throw itself, which is the
    /// only place the reason and the frames below it can still be read. Logged, never swallowed:
    /// the exception goes on to be thrown as before.
    private static func installExceptionLogging() {
        typealias Preprocessor = @convention(c) (AnyObject) -> AnyObject
        typealias Install = @convention(c) (Preprocessor) -> Preprocessor
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else { return }
        let install = unsafeBitCast(symbol, to: Install.self)
        _ = install({ thrown in
            // The exception's own callStackSymbols are empty at this point — it has not been
            // raised yet — so the live stack is read instead.
            var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
            let count = backtrace(&addresses, 48)
            var frames: [String] = []
            if let symbols = backtrace_symbols(&addresses, count) {
                for index in 0..<Int(count) {
                    if let symbol = symbols[index] { frames.append(String(cString: symbol)) }
                }
                free(symbols)
            }
            let logger = Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")
            let description = (thrown as? NSException).map { "\($0.name.rawValue): \($0.reason ?? "-")" }
                ?? String(describing: thrown)
            // One line per frame: os_log truncates a long message, and the frames that matter are
            // the ones at the end of it (that is how the first dictionary-key crash stayed hidden).
            logger.error("\(description, privacy: .public)")
            for frame in frames { logger.error("  \(frame, privacy: .public)") }
            return thrown
        })
    }

    /// Safari's windows are documents, and macOS keeps asking a document to encode its restorable
    /// state — a few seconds after a window opens, on every new tab, and on quit. Safari's
    /// document answers that from state this process does not have: one path threw out of
    /// `-[BrowserDocument fileType]` (stubbed below), another puts a nil key in a dictionary from
    /// a block on the main queue, where the stack no longer says who scheduled it.
    ///
    /// Rather than chase each one, the whole mechanism is turned off here. A hosted chrome has
    /// nothing worth restoring: which profile opens, and what it opens, is decided by the profile,
    /// never by state macOS saved from a previous run.
    private static func disableStateRestoration() {
        // The argument domain only: nothing is written to any preferences file.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        arguments["NSQuitAlwaysKeepsWindows"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        // And the encoding itself, for the state AppKit asks for anyway. This process has no
        // documents of its own, so replacing these on NSDocument affects Safari's and nothing else.
        for selectorName in ["_encodeRestorableStateWithCoder:backgroundQueue:",
                             "encodeRestorableStateWithCoder:backgroundQueue:",
                             "encodeRestorableStateWithCoder:"] {
            guard let method = class_getInstanceMethod(NSDocument.self, NSSelectorFromString(selectorName)) else { continue }
            let replacement: @convention(block) (AnyObject) -> Void = { _ in }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
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
        // Safari's chrome also reads the shared controller of the base class; make sure it exists
        // and carries the same engine, or the address bar has a provider list nobody asked.
        if let base: AnyObject = NSClassFromString("WBSSearchProvidersController"),
           base.responds(to: NSSelectorFromString("shared")),
           let shared = base.perform(NSSelectorFromString("shared"))?.takeUnretainedValue() as? NSObject {
            setDefaultSearchEngine("Google", on: shared)
        }
        setDefaultSearchEngine("Google", on: controller)
        // Safari's chrome reaches its providers through +[WBSSearchProvidersController shared],
        // which the base class creates bare: it never loads the provider list, so the suggestions
        // fetcher is handed a provider with no suggestions template and throws on the nil. Our
        // instance is Safari's own subclass with the list loaded (measured: six providers, Google
        // with both a search and a suggestions template), so that is what `shared` returns here.
        searchProviders = controller
        if let base = NSClassFromString("WBSSearchProvidersController"),
           let method = class_getClassMethod(base, NSSelectorFromString("shared")) {
            let replacement: @convention(block) (AnyObject) -> AnyObject? = { _ in searchProviders }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        log.notice("Search providers: \(String(describing: controller.value(forKey: "defaultSearchEngineName")), privacy: .public)")
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

    /// Something Safari's chrome schedules on the main queue stores into a dictionary with a nil
    /// key, moments after the window is up, and throws. The stack cannot name it: the block's body
    /// is a tail call into `-setObject:forKeyedSubscript:`, so the block itself never appears in a
    /// backtrace, and nothing but the dispatch frames is left. Rather than guess, the insert is
    /// made to drop a nil key — nothing can be stored under one anyway — and to say so in the log,
    /// so it stays visible instead of silently papered over.
    private static func tolerateNilDictionaryKeys() {
        typealias SetObject = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let selector = NSSelectorFromString("setObject:forKeyedSubscript:")
        for className in ["__NSDictionaryM", "NSMutableDictionary"] {
            guard let cls = NSClassFromString(className),
                  let method = class_getInstanceMethod(cls, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: SetObject.self)
            let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { dictionary, object, key in
                guard key != nil else {
                    Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")
                        .notice("Dropped a dictionary write with no key (object \(object == nil ? "nil" : String(describing: type(of: object!)), privacy: .public))")
                    return
                }
                original(dictionary, selector, object, key)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// Safari walks directories it works out from its own container, and in this process several
    /// of those come out nil — `-[NSFileManager safari_topLevelDirectoriesAtURL:]` then hands the
    /// nil to `-enumeratorAtURL:…`, which throws. Patching the walk rather than each of its
    /// callers: a directory that does not exist holds nothing, which is the right answer for every
    /// one of them.
    private static func tolerateMissingSafariDirectories() {
        typealias TopLevelDirectories = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let selector = NSSelectorFromString("safari_topLevelDirectoriesAtURL:")
        guard let method = class_getInstanceMethod(FileManager.self, selector) else {
            log.notice("No -[NSFileManager safari_topLevelDirectoriesAtURL:] in this Safari")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: TopLevelDirectories.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { manager, url in
            guard let url else {
                Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")
                    .notice("Safari asked for the contents of a directory it has no path for")
                return [] as NSArray
            }
            return original(manager, selector, url)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// And the enumerator itself, because Safari reaches it by more paths than the one above: it
    /// is `-enumeratorAtURL:…` that throws on a nil URL, and it is always there to patch, while a
    /// category method may not be registered yet when this runs. No URL, no enumerator.
    private static func tolerateNilDirectoryEnumeration() {
        typealias EnumeratorAtURL = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, UInt, AnyObject?) -> AnyObject?
        let selector = NSSelectorFromString("enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:")
        guard let method = class_getInstanceMethod(FileManager.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: EnumeratorAtURL.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, UInt, AnyObject?) -> AnyObject? = { manager, url, keys, options, handler in
            guard let url else {
                Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")
                    .notice("Safari asked to enumerate a directory it has no path for")
                return nil
            }
            return original(manager, selector, url, keys, options, handler)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The sibling of the enumerator: listing a directory outright. Safari reaches this one a few
    /// seconds later, with a nil URL again. An empty listing is what a directory that has no path
    /// contains.
    private static func tolerateNilDirectoryListing() {
        typealias ContentsOfDirectory = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, UInt, UnsafeMutableRawPointer?) -> AnyObject?
        let selector = NSSelectorFromString("contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:")
        guard let method = class_getInstanceMethod(FileManager.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: ContentsOfDirectory.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, UInt, UnsafeMutableRawPointer?) -> AnyObject? = { manager, url, keys, options, error in
            guard let url else {
                Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")
                    .notice("Safari asked for the contents of a directory it has no path for")
                return [] as NSArray
            }
            return original(manager, selector, url, keys, options, error)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Safari's chrome takes its colours out of an asset catalog by name, the same way it takes
    /// its icons, and asks the *main* bundle for them — so the address bar's "Not Secure" colour
    /// comes back nil here. Look in Safari's own bundles.
    private static func bridgeColorLookups() {
        typealias ColorNamed = @convention(c) (AnyObject, Selector, NSString) -> NSColor?
        let selector = NSSelectorFromString("colorNamed:")
        guard let method = class_getClassMethod(NSColor.self, selector) else { return }
        let bundles = chromeBundles
        let original = unsafeBitCast(method_getImplementation(method), to: ColorNamed.self)
        let replacement: @convention(block) (AnyObject, NSString) -> NSColor? = { cls, name in
            if let color = original(cls, selector, name) { return color }
            for bundle in bundles {
                if let color = NSColor(named: name as String, bundle: bundle) { return color }
            }
            return nil
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// `-[UnifiedField _notSecureAnnotation]` still passes a nil value even with a home of its own
    /// and the colour bridge above, and AppKit turns that into a crash while the address bar lays
    /// itself out — which is every window and every new tab. Dropping nil values is the right
    /// answer here: an attribute nobody provided is an attribute the text does not need.
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
            // Only Safari's own controllers; ours and AppKit's keep their normal lookup, and are
            // not worth a line in the log each.
            guard let imagePointer = object_getClass(object).flatMap({ class_getImageName($0) }),
                  String(cString: imagePointer).contains("Safari") else {
                return original(object, loader, name, bundle)
            }
            // Build the nib from the file itself rather than hand another bundle to AppKit: bundle
            // resolution is what went wrong here twice, and a framework in the Safari cryptex does
            // not answer -pathForResource:ofType: for these nibs at all.
            // `NSNib(contentsOf:)` is not available to Swift (deprecated in 10.9), so the file is
            // read and handed over as data, with the framework it came from as the nib's bundle so
            // that what the nib itself refers to still resolves.
            if let url = nibURL(named: name as String), let data = try? Data(contentsOf: url) {
                let owner = chromeBundles.first { url.path.hasPrefix($0.bundleURL.path) }
                log.notice("\(name, privacy: .public).nib from \(url.path, privacy: .public)")
                return NSNib(nibData: data, bundle: owner)
            }
            log.notice("No Safari framework holds \(name, privacy: .public).nib; letting AppKit try \(bundle?.bundlePath ?? "the main bundle", privacy: .public)")
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
        // Safari.app itself, because part of the chrome's nibs are resources of the application
        // rather than of its frameworks: in Safari the main bundle is Safari.app, and that is the
        // bundle those nibs are looked up in.
        let applications = ["/Applications/Safari.app",
                            "/System/Applications/Safari.app",
                            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        return roots.flatMap { root in frameworks.compactMap { Bundle(path: "\(root)/\($0).framework") } }
            + applications.compactMap(Bundle.init(path:))
    }()

    /// The file `name.nib` inside one of Safari's frameworks. Looked for on disk, under every
    /// layout those frameworks use, because that is the one thing that does not depend on how a
    /// cryptex-backed bundle answers resource lookups. Answers are cached, hits and misses alike.
    private static func nibURL(named name: String) -> URL? {
        if let known = nibURLs[name] { return known }
        let subdirectories = ["Resources", "Resources/Base.lproj", "Resources/en.lproj",
                              "Versions/A/Resources", "Versions/A/Resources/Base.lproj", "Versions/A/Resources/en.lproj",
                              "Contents/Resources", "Contents/Resources/Base.lproj", "Contents/Resources/en.lproj"]
        let found = chromeBundles.lazy.flatMap { bundle in
            subdirectories.lazy.map { bundle.bundleURL.appendingPathComponent($0).appendingPathComponent("\(name).nib") }
        }.first { FileManager.default.fileExists(atPath: $0.path) }
        nibURLs[name] = found
        return found
    }

    private static var nibURLs: [String: URL?] = [:]

    /// Safari's providers, kept for the lifetime of the process because `+shared` hands them out.
    private static var searchProviders: NSObject?

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
            // WebKit gates a few of its private setters on the caller being Safari itself and
            // throws NSObjectNotAvailableException otherwise ("may only be used by Safari"). The
            // web-extensions configuration Safari's menu builds on launch walks into one of them.
            // Doing nothing is also the behaviour we want: this is the switch that relaxes
            // third-party cookie blocking, and no profile here should have it relaxed.
            ("WKWebViewConfiguration", "_setShouldRelaxThirdPartyCookieBlocking:"),
            // Safari's web extensions, which the menu brings up on launch. Its store migrator
            // enumerates a directory it works out from Safari's own container, which is nil here.
            // Not stubbed only to stop the crash: extensions installed in Safari have no business
            // in a profile of this browser, and they would be shared by every profile.
            ("WBSWebExtensionSQLiteStoreMigrator", "_migrateExtensionSQLiteStoresForDefaultProfile"),
            // The start page's onboarding section: Swift code that traps when it cannot reach
            // Safari's own services, and it takes every new tab down with it.
            ("StartPageOnboardingSectionProvider", "reloadData"),
        ]
        for (className, selectorName) in nothing {
            replaceWithConstant(className, selectorName) { nil }
        }
        replaceWithConstant("UnifiedField", "_assistantButtonIconForContentOption:withSparkle:") {
            NSImage(size: NSSize(width: 1, height: 1))
        }
        // Safari's windows are documents, and macOS asks a document for its restorable state a
        // few seconds after it opens and on every new tab. -[BrowserDocument fileType] reads an
        // empty array on the way and throws, which is what killed ⌘T. A document of ours has no
        // state worth restoring anyway (the profile decides what opens), and the windows are
        // marked not restorable as well, in openWindow.
        replaceWithConstant("BrowserDocument", "fileType") { "public.html" as NSString }
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

    // MARK: The menu

    /// Safari's own menu bar, from `MainMenu.nib` in Safari.app.
    ///
    /// Without it a hosted chrome has no keyboard at all: on macOS the shortcuts live in the menu,
    /// so ⌘T, ⌘N, ⌘L, ⌘Y and the rest simply do not exist, which is why only the mouse worked.
    /// The items wired to the first responder (new tab, close tab, the address bar, history,
    /// bookmarks) reach Safari's window controller through the responder chain on their own. The
    /// nib's File's Owner is Safari's application object, which this process has as `NSApp`
    /// (`installApplication`), so its outlets resolve.
    @discardableResult
    static func installMainMenu() -> Bool {
        guard isAvailable else { return false }
        guard let url = nibURL(named: "MainMenu"), let data = try? Data(contentsOf: url) else {
            log.error("No MainMenu.nib in Safari.app: the hosted chrome will have no menu and no shortcuts")
            return false
        }
        let owner = chromeBundles.first { url.path.hasPrefix($0.bundleURL.path) }
        // This overload takes an NSArray, not [Any].
        var objects: NSArray?
        guard NSNib(nibData: data, bundle: owner).instantiate(withOwner: NSApplication.shared, topLevelObjects: &objects) else {
            log.error("Safari's MainMenu.nib did not instantiate")
            return false
        }
        // The nib's other top-level objects are owned by nobody once this returns.
        let topLevel = objects as? [Any] ?? []
        menuObjects = topLevel
        guard let menu = topLevel.compactMap({ $0 as? NSMenu }).first else {
            log.error("Safari's MainMenu.nib holds no menu")
            return false
        }
        NSApplication.shared.mainMenu = menu
        log.notice("Safari's menu bar is up: \(menu.items.count, privacy: .public) items from \(url.path, privacy: .public)")
        return true
    }

    private static var menuObjects: [Any]?

    // MARK: Opening a window

    /// Opens one of Safari's browser windows and, if `address` is given, navigates its tab there
    /// the way Safari does it — through the tab, so that the chrome's own bookkeeping (its label,
    /// its history, its back-forward list) is written as it would be for any page.
    ///
    /// What the page loads with is decided elsewhere: `SafariChromeHost` has already given the
    /// factory that builds Safari's web view configurations the profile's data store, so the web
    /// view this window creates is Safari's in every respect except whose cookies, storage and
    /// proxy it uses.
    @discardableResult
    static func openWindow(address: URL?) -> NSWindowController? {
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
        // Nothing of this window is worth restoring: what opens is the profile's business.
        controller.window?.isRestorable = false
        if let address, let tab = firstTab(of: windowClass) {
            let selector = NSSelectorFromString("loadURL:")
            if tab.responds(to: selector) {
                _ = tab.perform(selector, with: address as NSURL)
            }
        }
        log.notice("Safari's chrome is up\(address.map { ", at " + $0.absoluteString } ?? "")")
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
        relaunchWithProfileHomeIfNeeded(arguments: arguments)
        guard load() else {
            FileHandle.standardError.write(Data("Safari's private frameworks did not load: this build is sandboxed or library validation is on (see SafariChrome.swift)\n".utf8))
            exit(1)
        }
        installApplication()
        prepare()
        installMainMenu()
        let address = arguments.firstIndex(of: "--safari-chrome")
            .flatMap { arguments.indices.contains($0 + 1) && !arguments[$0 + 1].hasPrefix("--") ? arguments[$0 + 1] : nil }
            ?? "https://example.com"
        guard let controller = openWindow(address: URL(string: address)) else {
            FileHandle.standardError.write(Data("Safari's window did not open; the log says which step\n".utf8))
            exit(1)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }

    /// Safari's chrome reads and writes the `com.apple.Safari` preferences domain and its own
    /// databases. Without `CFFIXED_USER_HOME` those resolve into Safari's container, where this
    /// process is refused — the address bar then draws with nil colours and metrics, and the
    /// autofill store cannot be opened. The variable is only read when the process starts, so the
    /// process replaces itself with one that has it set. This is also the shape the per-profile
    /// child process will take, with the profile's own directory in place of this one.
    private static func relaunchWithProfileHomeIfNeeded(arguments: [String]) {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil else { return }
        // Read before the home moves: our own vault must stay where it is.
        let vault = AppEnvironment.vaultDirectory
        let home = vault.appendingPathComponent("SafariChromeHome", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CFFIXED_USER_HOME", home.path, 1)
        setenv("PRIVACYBROWSER_VAULT_DIR", vault.path, 1)
        guard let executable = Bundle.main.executableURL?.path ?? arguments.first else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execv(executable, &argv)
        // Only reached if execv failed; carry on without the profile home.
        log.error("Could not restart with CFFIXED_USER_HOME: \(String(cString: strerror(errno)), privacy: .public)")
    }
}
