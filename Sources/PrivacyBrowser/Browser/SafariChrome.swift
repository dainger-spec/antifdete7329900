import AppKit
import BrowserCore
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
        for missing in missingPieces() {
            log.error("This macOS does not have \(missing, privacy: .public)")
        }
        for absent in absentStubs() {
            log.notice("Not in this Safari (nothing to stub): \(absent, privacy: .public)")
        }
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
        // An exception AppKit's run loop catches is reported through NSApp, which is Safari's now.
        if let application = NSApp { ExceptionLog.watchReportException(of: type(of: application)) }
        return installed
    }

    // MARK: What this file expects of Safari

    /// The configuration factories of `WebKitPreferencesManager` that `SafariChromeHost` patches.
    /// One `jitEnabled:` variant, one reader sibling: Safari has used each of them.
    static let configurationFactories = [
        "contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:",
        "contentWebViewConfigurationForBrowsingMode:profileIdentifier:jitEnabled:",
        "readerWebViewConfigurationForBrowsingMode:profileIdentifier:relatedWebView:",
    ]

    /// A class, or a method of one, that something here relies on.
    struct Piece {
        enum Kind { case type, classMethod, instanceMethod }
        enum Role {
            /// Without it the chrome cannot be hosted at all: the profile opens our own window.
            case structural
            /// What holds a profile's process to its proxy (`ProfileNetworkGuard`): WebKit's and
            /// Foundation's own methods, patched by name.
            case network
            /// A method stubbed because it crashed a hosted chrome on one Safari build (§9.1 of
            /// docs/SAFARI_PROCESS.md). Builds differ: a Safari without the method has nothing
            /// to stub, which is no fault — reported, never failed on.
            case stub
        }
        let className: String
        let selector: String?
        let kind: Kind
        let role: Role

        var name: String {
            guard let selector else { return className }
            return "\(kind == .classMethod ? "+" : "-")[\(className) \(selector)]"
        }

        var isPresent: Bool {
            guard let cls = NSClassFromString(className) else { return false }
            guard let selector else { return true }
            let sel = NSSelectorFromString(selector)
            switch kind {
            case .type: return true
            case .classMethod: return class_getClassMethod(cls, sel) != nil
            case .instanceMethod: return class_getInstanceMethod(cls, sel) != nil
            }
        }
    }

    /// Everything this file, `SafariChromeHost` and `ProfileNetworkGuard` reach for by name, in one
    /// list, so that a macOS update that renames or removes any of it is caught — by
    /// `--check-safari-chrome` in CI, and in front of the user by the profile's process — instead
    /// of degrading in silence. A missing structural piece means our own window; a missing network
    /// piece means a lock of the guard that is not there; stubs only say what this build has.
    static let expectedPieces: [Piece] = [
        Piece(className: "BrowserApplication", selector: "sharedApplication", kind: .classMethod, role: .structural),
        Piece(className: "BrowserWindowController", selector: "openEmptyBrowserWindowController", kind: .classMethod, role: .structural),
        Piece(className: "BrowserWindowController", selector: "allBrowserTabViewItemsFromAllWindows", kind: .classMethod, role: .structural),
        Piece(className: "BrowserTabViewItem", selector: "loadURL:", kind: .instanceMethod, role: .structural),
        Piece(className: "WBSSearchEnginePreferenceObserver", selector: "setUpSharedObserverWithSearchProviderContext:", kind: .classMethod, role: .structural),
        Piece(className: "NSViewController", selector: "_nibWithName:bundle:", kind: .instanceMethod, role: .structural),
        Piece(className: "WKWebView", selector: "initWithFrame:configuration:", kind: .instanceMethod, role: .network),
        Piece(className: "WKWebsiteDataStore", selector: "defaultDataStore", kind: .classMethod, role: .network),
        Piece(className: "WKWebsiteDataStore", selector: "nonPersistentDataStore", kind: .classMethod, role: .network),
        Piece(className: "WKWebsiteDataStore", selector: "dataStoreForIdentifier:", kind: .classMethod, role: .network),
        Piece(className: "WKPreferences", selector: "_setPeerConnectionEnabled:", kind: .instanceMethod, role: .network),
        Piece(className: "WKPreferences", selector: "setFraudulentWebsiteWarningEnabled:", kind: .instanceMethod, role: .network),
        Piece(className: "NSURLSessionConfiguration", selector: "defaultSessionConfiguration", kind: .classMethod, role: .network),
        Piece(className: "NSURLSessionConfiguration", selector: "ephemeralSessionConfiguration", kind: .classMethod, role: .network),
        Piece(className: "NSURLSession", selector: "sharedSession", kind: .classMethod, role: .network),
        Piece(className: "SearchProvidersController", selector: "setDefaultSearchEngine:forPrivateBrowsing:", kind: .instanceMethod, role: .stub),
        Piece(className: "WBSSearchProvidersController", selector: "shared", kind: .classMethod, role: .stub),
        Piece(className: "WebKitPreferencesManager", selector: nil, kind: .type, role: .stub),
        Piece(className: "BrowserWindowController", selector: "_setUpClusterManagerIfNeeded", kind: .instanceMethod, role: .stub),
        Piece(className: "BrowserNavigationDelegate", selector: "donatePageTextMetadata:allowingDonationWithoutReaderText:", kind: .instanceMethod, role: .stub),
        Piece(className: "WKWebViewConfiguration", selector: "_setShouldRelaxThirdPartyCookieBlocking:", kind: .instanceMethod, role: .stub),
        Piece(className: "WBSWebExtensionSQLiteStoreMigrator", selector: "_migrateExtensionSQLiteStoresForDefaultProfile", kind: .instanceMethod, role: .stub),
        Piece(className: "StartPageOnboardingSectionProvider", selector: "reloadData", kind: .instanceMethod, role: .stub),
        Piece(className: "UnifiedField", selector: "_assistantButtonIconForContentOption:withSparkle:", kind: .instanceMethod, role: .stub),
        Piece(className: "BrowserDocument", selector: "fileType", kind: .instanceMethod, role: .stub),
        Piece(className: "NSFileManager", selector: "safari_topLevelDirectoriesAtURL:", kind: .instanceMethod, role: .stub),
        Piece(className: "WBTabGroupSyncAgentProxy", selector: "scheduleSyncIfNeeded", kind: .instanceMethod, role: .stub),
        Piece(className: "WBTabGroupSyncAgentProxy", selector: "addSyncObserver:", kind: .instanceMethod, role: .stub),
        Piece(className: "WBTabGroupSyncAgentProxy", selector: "removeSyncObserver:", kind: .instanceMethod, role: .stub),
    ]

    /// The structural and network pieces this macOS does not have, by name. Meaningful once
    /// `load()` has run (before, Safari's classes are not there to look at).
    static func missingPieces() -> [String] {
        guard isAvailable else { return [] }
        return expectedPieces.filter { $0.role != .stub && !$0.isPresent }.map(\.name)
    }

    /// The structural pieces that are missing: with any of them, the chrome is not hosted.
    static func missingStructuralPieces() -> [String] {
        guard isAvailable else { return [] }
        return expectedPieces.filter { $0.role == .structural && !$0.isPresent }.map(\.name)
    }

    /// What this Safari has of the stubbed methods and of the configuration factories: for the log
    /// and `--check-safari-chrome`, never a failure.
    static func absentStubs() -> [String] {
        guard isAvailable else { return [] }
        var absent = expectedPieces.filter { $0.role == .stub && !$0.isPresent }.map(\.name)
        if let factories = NSClassFromString("WebKitPreferencesManager"),
           !configurationFactories.contains(where: { class_getClassMethod(factories, NSSelectorFromString($0)) != nil }) {
            absent.append("+[WebKitPreferencesManager contentWebViewConfigurationFor…] (none of \(configurationFactories.count): the initializer alone gives web views the profile's data)")
        }
        return absent
    }

    /// `PrivacyBrowser --check-safari-chrome`: loads Safari's frameworks and says which of the
    /// pieces this build relies on this macOS has. Exit code 0 when every structural and network
    /// piece is there, 1 when any is missing, 2 when the frameworks do not load (a sandboxed build,
    /// or a macOS without them). Absent stubs are listed only. Touches nothing else: no window, no
    /// application object, no preferences.
    static func checkPieces(arguments: [String]) -> Int32 {
        isolateForCheck(arguments: arguments)
        defer { removeCheckHome() }
        guard load() else {
            print("SAFARI-CHROME frameworks did not load")
            return 2
        }
        let missing = missingPieces()
        for piece in expectedPieces {
            let state = piece.isPresent ? "PRESENT" : piece.role == .stub ? "absent " : "MISSING"
            print("\(state) \(String(describing: piece.role).padding(toLength: 10, withPad: " ", startingAt: 0)) \(piece.name)")
        }
        if let factories = NSClassFromString("WebKitPreferencesManager") {
            for name in configurationFactories {
                let present = class_getClassMethod(factories, NSSelectorFromString(name)) != nil
                print("\(present ? "PRESENT" : "absent ") factory    +[WebKitPreferencesManager \(name)]")
            }
        }
        print("SAFARI-CHROME \(missing.isEmpty ? "OK" : "MISSING \(missing.count)"): \(missing.joined(separator: ", "))")
        return missing.isEmpty ? 0 : 1
    }

    /// `--nib-check`: in a process like a profile's (`prepareForCheck`), the nibs Safari's chrome
    /// makes itself (`checkedNibs`), made as it makes them — `NSNib(nibNamed:bundle:)` with the main
    /// bundle, which here is this app — each from a timer of AppKit's run loop, where an exception
    /// is lived through and counted (`ExceptionLog`) rather than fatal. A line a nib, then how many
    /// were made from Safari's files and how many exceptions there were.
    static func runNibCheck(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard prepareForCheck(arguments: arguments) else {
            print("NIB-CHECK Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let loader = NibLoader()
        for (index, name) in checkedNibs.enumerated() {
            loader.perform(#selector(NibLoader.load(_:)), with: name as NSString, afterDelay: 0.3 + 0.2 * Double(index))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                print("NIB-CHECK made from Safari's files: \(nibsBridged); exceptions: \(ExceptionLog.reported)")
                removeCheckHome()
                exit(0)
            }
        }
        application.run()
        exit(0)
    }

    /// `--default-browser-check`: whether Safari's own `-[GeneralPreferences
    /// _defaultWebBrowserMayHaveChanged]` throws in a process like a profile's of this app. It did
    /// when ⌘, opened Safari's settings in a profile's window (a nil in an array, on the owner's
    /// Mac), and `stubChromeFeatures` replaces it since; the question is why. The owner's lead: an
    /// app that is a browser as far as the system knows (it declares http and https) has its
    /// question answered. So this prints what the system answers about http and https for this
    /// app, then calls Safari's original on its General pane from a timer of AppKit's run loop,
    /// where an exception is lived through and printed. CI runs it on this app as built and on a
    /// copy that declares itself a browser.
    static func runDefaultBrowserCheck(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard prepareForCheck(arguments: arguments) else {
            print("DEFAULT-BROWSER Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let workspace = NSWorkspace.shared
        let own = Bundle.main.bundleIdentifier ?? ""
        for scheme in ["http", "https"] {
            guard let page = URL(string: "\(scheme)://example.com/") else { continue }
            let all = workspace.urlsForApplications(toOpen: page).map { Bundle(url: $0)?.bundleIdentifier ?? $0.lastPathComponent }
            print("DEFAULT-BROWSER \(scheme): the default is \(workspace.urlForApplication(toOpen: page).map { Bundle(url: $0)?.bundleIdentifier ?? $0.path } ?? "nil"); "
                  + "\(all.count) application(s) open it; this app (\(own)) among them: \(all.contains { $0.caseInsensitiveCompare(own) == .orderedSame })")
        }
        ExceptionLog.onCaughtInRunLoop = { exception, _ in
            print("DEFAULT-BROWSER threw \(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))")
        }
        let caller = DefaultBrowserQuestion()
        caller.perform(#selector(DefaultBrowserQuestion.ask), with: nil, afterDelay: 0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                print("DEFAULT-BROWSER exceptions: \(ExceptionLog.reported)")
                removeCheckHome()
                exit(0)
            }
        }
        application.run()
        exit(0)
    }

    /// The nibs of Safari's Bookmarks sidebar, which its controller makes itself.
    static let checkedNibs = ["AnnotatedBookmarksSidebarViewController", "AnnotatedBookmarksSidebarExpandedTableCellView",
                              "AnnotatedBookmarksSidebarExpandedTableCellViewV2"]

    /// Whether one of Safari's bundles holds `name.nib`.
    static func safariHolds(nib name: String) -> Bool {
        nibURL(named: name) != nil
    }

    // MARK: Preparing

    /// What Safari's app delegate does for its own chrome before any window exists. Each step is
    /// what one measured crash asked for; see `docs/SAFARI_PROCESS.md` §9.1.
    static func prepare() {
        guard isAvailable else { return }
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
        bridgeNibInitializers()
        stubChromeFeatures()
        closeSafarisAutoFill()
        installUnavailableNotice()
    }

    // MARK: Safari's own services

    /// The `com.apple.Safari` keys this file sets for a profile, and what each one is set to.
    /// They live in the profile's process only (`configureSafarisOwnServices`), so they are the
    /// profile's and nobody else's.
    ///
    ///   * Safari's own AutoFill saves passwords into the user's iCloud Keychain — shared by every
    ///     profile and by the real Safari, the opposite of what a profile is for, and next to this
    ///     project's own password vault it would be a second manager in one window.
    ///   * Safari Suggestions are asked of Apple's servers by a system daemon, as this Mac, with
    ///     whatever is typed into the address bar: off.
    ///   * Search engine suggestions: asked from this process, which is held to the profile's proxy
    ///     (`ProfileNetworkGuard`), but nothing else on the address bar needs them: off, so a
    ///     keystroke is never a request.
    ///   * Safe Browsing: asked by a system service, outside the proxy; as the profile says, off by
    ///     default.
    ///   * Privacy-preserving ad measurement: its reports are sent later, outside the page's
    ///     session; off for a profile with a proxy (the web views have it off as well,
    ///     `BrowserSession.applyPrivacyPreferences`).
    ///   * Quick Website Search: Safari fetches the OpenSearch description a page names, from a
    ///     service of its own, as this Mac. Off.
    ///   * Preloading the top hit: a page loaded for what is being typed, before it is chosen.
    ///     Through the profile's proxy like any page, but a request the user did not make. Off.
    ///   * Asking websites' permission for notifications, and Safari's extensions: Web Push is
    ///     registered with this Mac's own push token, extensions are the real Safari's. Off.
    static func servicePreferenceValues(for configuration: ProfileConfiguration) -> [(String, Bool)] {
        [
            ("AutoFillPasswords", false),
            ("AutoFillCreditCardData", false),
            ("AutoFillMiscellaneousForms", false),
            ("AutoFillFromAddressBook", false),
            ("UniversalSearchEnabled", false),
            ("SuppressSearchSuggestions", true),
            ("WarnAboutFraudulentWebsites", configuration.safeBrowsingEnabled),
            ("WebKitPreferences.privateClickMeasurementEnabled", configuration.proxy == nil),
            // A page's dns-prefetch is resolved by this Mac, outside the proxy (`ContentRules`).
            ("WebKitDNSPrefetchingEnabled", configuration.proxy == nil),
            ("WebKitPreferences.dnsPrefetchingEnabled", configuration.proxy == nil),
            ("WebsiteSpecificSearchEnabled", false),
            ("PreloadTopHit", false),
            ("CanPromptForPushNotifications", false),
            ("ExtensionsEnabled", false),
            // A finished download is not opened in another app by itself.
            ("AutoOpenSafeDownloads", false),
        ]
    }

    /// Puts `servicePreferenceValues` in the argument domain of this process, which every
    /// domain's lookups see before what is stored or registered, and which is never written
    /// anywhere. Called before Safari's frameworks load.
    ///
    /// Nothing is written to a preferences domain: `CFFIXED_USER_HOME` moves the process's home,
    /// not where cfprefsd keeps a domain. These settings used to be written to `com.apple.Safari`
    /// as well, meant as the profile's own, and the menu walk (CI run 457, macOS 26 and 27) found
    /// them in the account's real ~/Library/Preferences/com.apple.Safari.plist — every profile's
    /// launch writing the same file, outside the vault, among the real Safari's places — and no
    /// preferences file in the profile's home. Measured in run 460 with the argument domain alone:
    /// Core Foundation's lookup of `com.apple.Safari`, a suite of it and the standard defaults all
    /// answer with the profile's values, and the account's file is not written.
    static func configureSafarisOwnServices(for configuration: ProfileConfiguration) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        for (key, value) in servicePreferenceValues(for: configuration) {
            arguments[key] = value
        }
        servicePreferenceKeys = servicePreferenceValues(for: configuration).map(\.0)
        // History › Home (⇧⌘H) goes to the profile's start page: Safari's own home page setting,
        // which its own action reads (the owner's decision; Safari's default, apple.com/startpage,
        // for a profile without one). Run 488 has Safari taking it from the argument domain.
        if let start = configuration.startURL {
            arguments[homePageKey] = start.absoluteString
            servicePreferenceKeys.append(homePageKey)
        }
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        log.notice("Safari's own services are set for this profile (\(servicePreferenceKeys.count, privacy: .public) keys)")
    }

    /// Safari's home page, which History › Home opens.
    static let homePageKey = "HomePage"

    private static var servicePreferenceKeys: [String] = []

    /// What the profile's `com.apple.Safari` domain says now for every key set above, read back
    /// (the network report shows it, so a Safari that rewrote one is seen).
    static func servicePreferences() -> [String: String] {
        let domain = "com.apple.Safari" as CFString
        var values: [String: String] = [:]
        for key in servicePreferenceKeys {
            let value = CFPreferencesCopyAppValue(key as CFString, domain)
            values[key] = value.map { String(describing: $0) } ?? "unset"
        }
        return values
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
        arguments["ApplePersistence"] = false
        arguments["NSQuitAlwaysKeepsWindows"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        // No window of this process is restorable: AppKit would keep page titles in the saved
        // state, in the shared temporary folder, outside the profile's home.
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("isRestorable")) {
            let replacement: @convention(block) (AnyObject) -> Bool = { _ in false }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

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
        log.notice("Search providers: \(String(describing: controller.value(forKey: "defaultSearchEngineName")), privacy: .private)")
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

    /// Safari's controllers also build nibs themselves, with `-[NSNib initWithNibNamed:bundle:]` —
    /// the Bookmarks sidebar's cells, in `-[AnnotatedBookmarksSidebarViewController _addTableView]`
    /// — and with the bundle Safari would mean: the main bundle, which in this process is this
    /// app, not Safari.app. `bridgeNibLookups` only sees the nibs a view controller loads. AppKit
    /// then throws NSInternalInconsistencyException where Safari would have found its nib: it took
    /// a profile's process down, and once exceptions were lived through, made the sidebar do
    /// nothing (the owner's Mac, macOS 27). When the bundle given does not hold the nib and one of
    /// Safari's does (`nibURL(named:)`), the nib is made from that file, on the same instance.
    ///
    /// Both the public initializer and AppKit's `-_initWithNibNamed:bundle:options:` behind it are
    /// bridged, so that neither way in depends on how the other is built in this macOS; a nib the
    /// given bundle holds goes to AppKit untouched, and so does one nobody holds (said in the log).
    ///
    /// Raw pointers throughout: this stands in for initializers, which take their receiver and
    /// return their result owned, and Swift must not retain or release either on the way.
    private static func bridgeNibInitializers() {
        typealias InitNamedOptions = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeRawPointer?, UnsafeRawPointer?,
                                                     UnsafeRawPointer?) -> UnsafeMutableRawPointer?
        typealias InitTwo = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
        let namedOptions = NSSelectorFromString("_initWithNibNamed:bundle:options:")
        let named = NSSelectorFromString("initWithNibNamed:bundle:")
        let fromData = NSSelectorFromString("initWithNibData:bundle:")
        guard let dataMethod = class_getInstanceMethod(NSNib.self, fromData) else {
            log.notice("No -[NSNib initWithNibData:bundle:]: a nib Safari builds itself is looked for by AppKit alone")
            return
        }
        let initWithData = unsafeBitCast(method_getImplementation(dataMethod), to: InitTwo.self)
        // The nib made on `nib` from Safari's file, or nil for AppKit to look as it would.
        let fromSafari: (UnsafeMutableRawPointer, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?? = { nib, name, bundle in
            guard let name else { return nil }
            var nibName = Unmanaged<NSString>.fromOpaque(name).takeUnretainedValue() as String
            if nibName.hasSuffix(".nib") { nibName = String(nibName.dropLast(4)) }
            let given = bundle.map { Unmanaged<Bundle>.fromOpaque($0).takeUnretainedValue() } ?? Bundle.main
            guard given.url(forResource: nibName, withExtension: "nib") == nil else { return nil }
            guard let url = nibURL(named: nibName), let data = try? Data(contentsOf: url) else {
                log.error("\(nibName, privacy: .public).nib is neither in \(given.bundlePath, privacy: .public) nor in any of Safari's bundles: AppKit will refuse it")
                return nil
            }
            let owner = chromeBundles.first { url.path.hasPrefix($0.bundleURL.path) }
            log.notice("\(nibName, privacy: .public).nib, asked of \(given.bundlePath, privacy: .public), from \(url.path, privacy: .public)")
            nibsBridged += 1
            let contents = data as NSData
            return .some(withExtendedLifetime((contents, owner)) {
                initWithData(nib, fromData, UnsafeRawPointer(Unmanaged.passUnretained(contents).toOpaque()),
                             owner.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
            })
        }
        if let method = class_getInstanceMethod(NSNib.self, namedOptions) {
            let original = unsafeBitCast(method_getImplementation(method), to: InitNamedOptions.self)
            let replacement: @convention(block) (UnsafeMutableRawPointer, UnsafeRawPointer?, UnsafeRawPointer?,
                                                 UnsafeRawPointer?) -> UnsafeMutableRawPointer? = { nib, name, bundle, options in
                if let made = fromSafari(nib, name, bundle) { return made }
                return original(nib, namedOptions, name, bundle, options)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            log.notice("No -[NSNib _initWithNibNamed:bundle:options:] in this macOS: the public initializer is bridged alone")
        }
        if let method = class_getInstanceMethod(NSNib.self, named) {
            let original = unsafeBitCast(method_getImplementation(method), to: InitTwo.self)
            let replacement: @convention(block) (UnsafeMutableRawPointer, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer? = { nib, name, bundle in
                if let made = fromSafari(nib, name, bundle) { return made }
                return original(nib, named, name, bundle)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            log.notice("No -[NSNib initWithNibNamed:bundle:] in this macOS: a nib Safari builds itself is looked for by AppKit alone")
        }
    }

    /// How many nibs `bridgeNibInitializers` made from Safari's files (`--nib-check` says).
    private static var nibsBridged = 0

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
            // Tab groups sync through iCloud by an agent of Safari's, which a profile's process is
            // refused (`ProfileNetworkGuard`: "SyncAgent"). When a tab of a tab group changed, the
            // manager asked the agent to sync through its refused connection, and the process
            // ended there (`_objc_fatal` in `objc_storeWeak` under -[NSXPCConnection
            // _sendInvocation:…]): the menu walk, CI run 461, macOS 26, a page loaded in a window
            // with a tab group. A profile's tab groups are its own and stay in its home.
            ("WBTabGroupSyncAgentProxy", "scheduleSyncIfNeeded"),
            // The same proxy's observers: with twenty profiles launched at once, one profile's
            // process ended at its start in objc_retain under -[NSXPCConnection
            // remoteObjectProxy], from the block -[WBTabGroupSyncAgentProxy addSyncObserver:] runs
            // on its sync observer queue (the scale check, CI run 468, macOS 26). Nothing is
            // observed from an agent the profile does not reach, and nothing removed.
            ("WBTabGroupSyncAgentProxy", "addSyncObserver:"),
            ("WBTabGroupSyncAgentProxy", "removeSyncObserver:"),
        ]
        for (className, selectorName) in nothing {
            replaceWithConstant(className, selectorName) { nil }
        }
        // Classes whose framework loads after this runs are replaced as soon as their image is
        // loaded: here they are not there yet, and replacing them did nothing (CI run 475).
        stubLateFeatures()
        _dyld_register_func_for_add_image { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SafariChrome.stubLateFeatures() } }
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
        // ⌘, and Settings… open the app's own Settings (in the manager's process), not Safari's:
        // Safari's are built on services this process does not have, and their General pane threw
        // on its first look at the default browser (the owner's Mac, 2026-10-30). Elsewhere — the
        // developer's standalone chrome — they do nothing.
        replaceWithConstant("AppController", "showPreferences:") {
            SafariChrome.onShowSettings?()
            return nil
        }
        // What the General pane does when the default browser may have changed — on its own first
        // look, and, by its name, on the system's notice of a change, which would need no click to
        // come. It built an array from the answer and a nil in it threw. Nothing here shows that
        // pane any more, and nothing needs to know which browser is the default.
        // Its own implementation is kept for `--default-browser-check`, which calls it to see why.
        defaultBrowserQuestion = replaceWithConstant("GeneralPreferences", "_defaultWebBrowserMayHaveChanged") { nil }
    }

    /// Methods of classes that load after `stubChromeFeatures` runs, replaced with nothing once
    /// they are there.
    ///
    /// SafariPlatformSupport's completion list is the view of a service of Safari's, which the
    /// kernel refuses a profile's process (`ProfileNetworkGuard`: com.apple.Safari*). Each time
    /// that view's service ended, -[SPSafariPlatformSupport viewServiceDidTerminateWithError:]
    /// asked for the view again (-_setUpCompletionListViewControllerWithSetUpCompletionListViewController:),
    /// and, refused, it ended at once: from a few seconds after its start, the process's main
    /// thread did little else, and it logged "…endpoint for listener 'com.apple.view-bridge':
    /// Connection invalid" about a million times in a menu walk (measurement runs 468 to 475,
    /// macOS 26 and 27; the loop in a sample, run 473). Replaced, twenty times (run 476).
    private static let lateStubs: [(String, String)] = [
        ("SPSafariPlatformSupport", "viewServiceDidTerminateWithError:"),
    ]
    private static var lateStubsMade: Set<String> = []

    /// Replaces the late stubs whose classes are loaded by now; called again as images load.
    static func stubLateFeatures() {
        for (className, selectorName) in lateStubs where !lateStubsMade.contains(className + " " + selectorName) {
            guard NSClassFromString(className) != nil else { continue }
            replaceWithConstant(className, selectorName) { nil }
            lateStubsMade.insert(className + " " + selectorName)
        }
    }

    /// Safari's own `-[GeneralPreferences _defaultWebBrowserMayHaveChanged]`, before
    /// `stubChromeFeatures` replaced it.
    static var defaultBrowserQuestion: IMP?

    /// What ⌘, and Settings… do in Safari's menu (a profile's process asks the manager).
    static var onShowSettings: (() -> Void)?

    // MARK: Safari's own AutoFill

    /// Safari's own AutoFill never sees a form of a profile's page, and never offers anything. On
    /// the owner's Mac, after our offer to save a password, Safari's followed: its save goes to the
    /// owner's own passwords, shared by every profile and the real Safari, and the
    /// `AutoFillPasswords` setting, off in the profile, is not what that path reads. So it is
    /// closed where a form comes in, not by a setting:
    ///   * WebKit hands a submitted form to the web view's input or navigation delegate, which in
    ///     Safari's window is Safari's (`BrowserInputDelegate`). Every class of Safari's frameworks
    ///     that implements one of WebKit's four ways of being told lets the submission go on, and
    ///     does nothing else: Safari's passwords, credit cards and other forms never get it
    ///     (`formSubmissionsKept`).
    ///   * Behind that, Safari's offers to save a password or a credit card do nothing, and are
    ///     counted if anything reaches them all the same (`saveOffersReached`: none is right).
    ///   * Its offers to fill a field — its passwords, cards and the user's own contact card — are
    ///     off, and the Edit menu's AutoFill items that insert them are gone (`installMainMenu`).
    /// Our own offer to save a password comes from the page's isolated world, not from these.
    private static func closeSafarisAutoFill() {
        typealias Handler = @convention(block) () -> Void
        let delegates: [(String, Any)] = [
            ("webView:willSubmitForm:submissionHandler:",
             { (_: AnyObject, _: AnyObject?, _: AnyObject?, handler: Handler?) in keep(handler) } as @convention(block) (AnyObject, AnyObject?, AnyObject?, Handler?) -> Void),
            ("_webView:willSubmitFormValues:userObject:submissionHandler:",
             { (_: AnyObject, _: AnyObject?, _: AnyObject?, _: AnyObject?, handler: Handler?) in keep(handler) }
                as @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, Handler?) -> Void),
            ("_webView:willSubmitFormValues:frameInfo:sourceFrameInfo:userObject:submissionHandler:",
             { (_: AnyObject, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, handler: Handler?) in keep(handler) }
                as @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Handler?) -> Void),
            ("_webView:willSubmitFormValues:frameInfo:sourceFrameInfo:userObject:requestURL:method:submissionHandler:",
             { (_: AnyObject, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, handler: Handler?) in keep(handler) }
                as @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?, Handler?) -> Void),
        ]
        var closed: [String] = []
        for className in classesOfSafarisImages() {
            guard let cls = NSClassFromString(className) else { continue }
            for (selectorName, block) in delegates {
                let selector = NSSelectorFromString(selectorName)
                // Only a class's own method: one it inherits is its superclass's to replace.
                guard let method = class_getInstanceMethod(cls, selector),
                      class_getSuperclass(cls).flatMap({ class_getInstanceMethod($0, selector) }) != method else { continue }
                method_setImplementation(method, imp_implementationWithBlock(block))
                closed.append("-[\(className) \(selectorName)]")
            }
        }
        if closed.isEmpty {
            log.error("No class of Safari's takes a submitted form here: Safari's own AutoFill is not closed where forms come in")
        } else {
            log.notice("Safari's own AutoFill gets no form: \(closed.joined(separator: ", "), privacy: .public)")
        }
        for (className, selectorName) in [
            ("FormDataController", "offerToSaveCredentialsFromForm:forFrame:passwordGenerationCredentials:completionHandler:"),
            ("CreditCardDataController",
             "_offerToSaveCreditCardData:submittedToFrameInBrowserViewController:fromFrameInBrowserViewController:finishedSavingFormDataBlock:"),
        ] {
            replaceWithConstant(className, selectorName) {
                saveOffersReached += 1
                return nil
            }
        }
        // NO: nothing of Safari's to fill a field with.
        replaceWithConstant("BrowserViewController", "_shouldOfferAnyTypeOfAutoFill") { nil }
        replaceWithConstant("FormDataController", "shouldOfferAddressBookAutoFillInTextField:formMetadata:") { nil }
        closeAutoFillInsertActions()
    }

    /// The actions of the Edit menu's AutoFill items (Contact…, Passwords…, Credit Card…): the
    /// system's AutoFill, filling a page from the account's own contact card, passwords and cards.
    static let autoFillInsertActions = ["_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:",
                                        "_handleInsertFromCreditCardsCommand:"]

    /// The actions of the items whose work is done outside the profile (`removeItemsOutsideTheProfile`):
    /// File › Add to Dock…, Import Browsing Data from File or Folder…, Export Browsing Data to File…,
    /// View › Show Shared with You.
    static let outsideTheProfileActions = ["generateWebAppForCurrentPage:", "_importFromFile:", "runExportDataPanel:",
                                           "toggleSharedWithYou:"]

    /// Those actions say they are off, however they are sent — the Edit menu (whose items are taken
    /// out as well), a context menu, a key. On macOS 26, Passwords… in a profile's window had
    /// Safari's helper (SafariPlatformSupport) write into the real Safari's container and
    /// ~/Library/Safari and fetch over its own connection, as this Mac (the menu walk, CI run 452).
    ///
    /// Replacing the implementations AppKit and WebKit have was not all of it: with a page's field
    /// focused, something else in the responder chain took the actions and our notice never came
    /// (the menu walk on a page, CI run 463, macOS 26 and 27). So they are stopped where every
    /// action sent to a responder passes, the application's `sendAction:to:from:` — Safari's
    /// application object's, which is the one sending.
    private static func closeAutoFillInsertActions() {
        var replaced: Set<UInt> = []
        let notice: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
            MainActor.assumeIsolated { SafariChrome.presentNotice(L("safari.autofill.closed.title"), L("safari.autofill.closed.text")) }
        }
        for owner in [NSResponder.self, NSView.self, NSTextView.self, WKWebView.self] as [AnyClass] {
            for name in autoFillInsertActions {
                guard let method = class_getInstanceMethod(owner, NSSelectorFromString(name)),
                      replaced.insert(UInt(bitPattern: method)).inserted else { continue }
                method_setImplementation(method, imp_implementationWithBlock(notice))
            }
        }
        // So are the actions of the items whose work is done outside the profile, whichever menu
        // sends them: Safari's Share menu has an Add to Dock… of its own.
        let sendAction = #selector(NSApplication.sendAction(_:to:from:))
        let closed = Set(autoFillInsertActions)
        let outside = Set(outsideTheProfileActions)
        for owner in [NSClassFromString("BrowserApplication"), NSApplication.self].compactMap({ $0 }) {
            guard let method = class_getInstanceMethod(owner, sendAction),
                  replaced.insert(UInt(bitPattern: method)).inserted else { continue }
            typealias Send = @convention(c) (AnyObject, Selector, Selector?, AnyObject?, AnyObject?) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
            let replacement: @convention(block) (AnyObject, Selector?, AnyObject?, AnyObject?) -> Bool = { application, action, target, sender in
                if let action, closed.contains(NSStringFromSelector(action)) {
                    MainActor.assumeIsolated { SafariChrome.presentNotice(L("safari.autofill.closed.title"), L("safari.autofill.closed.text")) }
                    return true
                }
                if let action, outside.contains(NSStringFromSelector(action)) {
                    MainActor.assumeIsolated { SafariChrome.presentNotice(L("safari.outside.title"), L("safari.outside.text")) }
                    return true
                }
                return original(application, sendAction, action, target, sender)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        log.notice("The AutoFill insert actions are off: \(replaced.count, privacy: .public) implementation(s) replaced")
    }

    /// A form went on without Safari's AutoFill seeing it.
    private static func keep(_ handler: (@convention(block) () -> Void)?) {
        formSubmissionsKept += 1
        handler?()
    }

    /// Forms submitted in Safari's window that went on without Safari's AutoFill, and times one of
    /// its offers to save was reached all the same (none is right): the network report has both.
    private(set) static var formSubmissionsKept = 0
    private(set) static var saveOffersReached = 0

    /// The names of the classes of every image of Safari's frameworks loaded in this process.
    private static func classesOfSafarisImages() -> [String] {
        let images = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
            .filter { $0.contains(".framework/") && $0.contains("/Safari") }
        var names: [String] = []
        for image in images {
            var count: UInt32 = 0
            guard let list = objc_copyClassNamesForImage(image, &count) else { continue }
            names += (0..<Int(count)).map { String(cString: list[$0]) }
            free(list)
        }
        return names
    }

    // MARK: When one of Safari's features cannot work here

    /// The menu item whose action was last sent, and when.
    private static var lastMenuItem: (title: String, at: Date)?
    private static var isShowingUnavailable = false

    /// An exception AppKit's run loop caught (and `ExceptionLog` wrote down) right after the user
    /// chose a menu item, pressed a key or clicked is one of Safari's features failing for want of
    /// what only the real Safari has. Instead of nothing happening, the profile's window says so,
    /// naming the menu item when there was one. Nothing is said for an exception nobody asked for
    /// (a timer, a page loading): the log has those. One notice at a time.
    private static func installUnavailableNotice() {
        _ = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { note in
            let title = (note.userInfo?["MenuItem"] as? NSMenuItem)?.title ?? ""
            MainActor.assumeIsolated { lastMenuItem = (title, Date()) }
        }
        ExceptionLog.onCaughtInRunLoop = { _, eventType in
            MainActor.assumeIsolated { showUnavailable(eventType: eventType) }
        }
    }

    private static func showUnavailable(eventType: NSEvent.EventType?) {
        let item = lastMenuItem.flatMap { Date().timeIntervalSince($0.at) < 3 ? $0.title : nil }
        let byInput = eventType.map { [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseUp].contains($0) } ?? false
        guard item != nil || byInput else { return }
        lastMenuItem = nil
        let text = item.map { $0.isEmpty ? L("safari.unavailable.action") : String(format: L("safari.unavailable.item"), $0) }
            ?? L("safari.unavailable.action")
        presentNotice(L("safari.unavailable.title"), text)
    }

    /// Shows a notice in the profile's window: a sheet on it, one at a time. `--exception-check`
    /// prints it instead.
    static var presentNotice: @MainActor (String, String) -> Void = { title, text in
        guard !isShowingUnavailable else { return }
        isShowingUnavailable = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("common.ok"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { _ in MainActor.assumeIsolated { isShowingUnavailable = false } }
        } else {
            alert.runModal()
            isShowingUnavailable = false
        }
    }

    /// Replaces one object-returning method with a constant. On arm64 a block that only returns a
    /// value stands in for a method of any arity: the arguments are left in their registers.
    /// Returns the implementation it replaced.
    @discardableResult
    private static func replaceWithConstant(_ className: String, _ selectorName: String, _ value: @escaping () -> AnyObject?) -> IMP? {
        guard let cls = NSClassFromString(className),
              let method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) else {
            log.notice("Nothing to replace: -[\(className, privacy: .public) \(selectorName, privacy: .public)]")
            return nil
        }
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { _ in value() }
        return method_setImplementation(method, imp_implementationWithBlock(replacement))
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
        removePrivateWindowItems(from: menu)
        removeAutoFillInsertItems(from: menu)
        removeItemsOutsideTheProfile(from: menu)
        addPasteAsTyped(to: menu)
        retargetNewWindow(in: menu)
        NSApplication.shared.mainMenu = menu
        keepAutoFillInsertItemsOut()
        log.notice("Safari's menu bar is up: \(menu.items.count, privacy: .public) items from \(url.path, privacy: .public)")
        return true
    }

    private static var menuObjects: [Any]?

    /// Safari's Edit menu has Paste as Typed (the profile's process reports it).
    private(set) static var pasteAsTypedInMenu = false

    /// Paste as Typed (⌃⌘V) after the Paste items of Safari's Edit menu, the menu that has
    /// `paste:`: the app's own item, typing into Safari's web view that has the keyboard.
    private static func addPasteAsTyped(to menu: NSMenu) {
        guard let edit = menu.items.compactMap(\.submenu)
            .first(where: { $0.items.contains { $0.action == #selector(NSText.paste(_:)) } }) else {
            log.error("Safari's menu has no Edit menu with Paste: no Paste as Typed in its windows")
            return
        }
        let lastPaste = edit.items.lastIndex { item in
            item.action.map { NSStringFromSelector($0).lowercased().contains("paste") } == true
        } ?? edit.items.count - 1
        let item = NSMenuItem(title: L("menu.pasteAsTyped"), action: #selector(PasteAsTypedItem.pasteAsTyped(_:)), keyEquivalent: "v")
        item.keyEquivalentModifierMask = [.command, .control]
        item.target = PasteAsTypedItem.shared
        edit.insertItem(item, at: lastPaste + 1)
        pasteAsTypedInMenu = true
    }

    /// File › New Window (⌘N) opens another window of the profile. Safari's own action
    /// (`_newWindowWithDefaultProfile:`) opens one for Safari's own profiles, which this process
    /// does not have, and its menu kept it disabled: no ⌘N in a profile's window (the menu walk, CI
    /// run 452, macOS 26 and 27). The item keeps its place and its key.
    private static func retargetNewWindow(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                retargetNewWindow(in: submenu)
            } else if let action = item.action, NSStringFromSelector(action) == "_newWindowWithDefaultProfile:" {
                item.target = NewWindowItem.shared
                item.action = #selector(NewWindowItem.newWindow(_:))
            }
        }
    }

    /// "New Private Window" goes: a private window of Safari's would be built, like every web view
    /// here, on the profile's own store — a window that says private and keeps everything. A
    /// profile that should keep nothing is an ephemeral profile.
    private static func removePrivateWindowItems(from menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { removePrivateWindowItems(from: submenu) }
            if let action = item.action, NSStringFromSelector(action).localizedCaseInsensitiveContains("private") {
                menu.removeItem(item)
            }
        }
    }

    /// The Edit menu's AutoFill items insert Safari's own: the user's contact card, their
    /// passwords and credit cards — into a profile's page, which is theirs to keep apart from it
    /// (`closeSafarisAutoFill`). Gone, and their submenu with them when they were all it had (a
    /// submenu Safari fills only as it opens is empty to begin with, and stays). True when an item
    /// was removed.
    @discardableResult
    private static func removeAutoFillInsertItems(from menu: NSMenu) -> Bool {
        let inserting: Set<String> = ["_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:",
                                      "_handleInsertFromCreditCardsCommand:"]
        var removed = false
        for item in menu.items {
            if let submenu = item.submenu {
                if removeAutoFillInsertItems(from: submenu) {
                    removed = true
                    if submenu.items.allSatisfy(\.isSeparatorItem) { menu.removeItem(item) }
                }
                continue
            }
            if let action = item.action, inserting.contains(NSStringFromSelector(action)) {
                menu.removeItem(item)
                removed = true
            }
        }
        return removed
    }

    /// Items whose work is done outside the profile, gone from its menu (the owner's decisions on
    /// the menu walk's findings, docs/SAFARI_MENU.md): File › Add to Dock… makes a web app that
    /// runs in Safari's own web-app container, outside the profile and its proxy; File › Import
    /// Browsing Data from File or Folder… and Export Browsing Data to File… put passwords and cards
    /// into this Mac's keychain and take them from there; View › Show Shared with You shows what
    /// was shared with this Mac's Messages account. The import and export of the profile's own
    /// bookmarks stay. A submenu left with nothing goes with them, and so does a separator left
    /// next to another. True when an item was removed.
    @discardableResult
    private static func removeItemsOutsideTheProfile(from menu: NSMenu) -> Bool {
        let outside = Set(outsideTheProfileActions)
        var removed = false
        for item in menu.items {
            if let submenu = item.submenu {
                if removeItemsOutsideTheProfile(from: submenu) {
                    removed = true
                    if submenu.items.allSatisfy(\.isSeparatorItem) { menu.removeItem(item) }
                }
                continue
            }
            if let action = item.action, outside.contains(NSStringFromSelector(action)) {
                menu.removeItem(item)
                removed = true
            }
        }
        if removed {
            // No separator first, last, or right after another.
            var previousWasSeparator = true
            for item in menu.items {
                if item.isSeparatorItem, previousWasSeparator {
                    menu.removeItem(item)
                } else {
                    previousWasSeparator = item.isSeparatorItem
                }
            }
            if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        }
        return removed
    }

    /// AppKit adds the Edit menu's system items itself once the menu bar is up — AutoFill among
    /// them — so the items taken out above came back: the menu walk found Edit › AutoFill ›
    /// Contact… and Passwords… there, enabled, in a profile's window (CI run 452). They are taken
    /// out again whenever a menu gets an item, and as a menu opens; so are the items whose work is
    /// done outside the profile, which Safari puts in its File menu as it fills it.
    private static func keepAutoFillInsertItemsOut() {
        guard !isKeepingAutoFillOut else { return }
        isKeepingAutoFillOut = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didBeginTrackingNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu else { return }
                // Not while AppKit is still adding to the menu: once it is done.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = SafariChrome.removeAutoFillInsertItems(from: menu)
                        _ = SafariChrome.removeItemsOutsideTheProfile(from: menu)
                    }
                }
            }
        }
        if let menu = NSApplication.shared.mainMenu {
            removeAutoFillInsertItems(from: menu)
            removeItemsOutsideTheProfile(from: menu)
        }
    }

    private static var isKeepingAutoFillOut = false

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

    /// The check loads Safari's frameworks to see what they have, and nothing more — as a
    /// profile's process does: in a home of its own (a temporary folder, removed afterwards), so
    /// that nothing their initializers read or write is the user's, and with the whole process held
    /// to a proxy that goes nowhere (`ProfileNetworkGuard`), so that nothing they start reaches the
    /// network as this Mac. The home is only read when the process starts, so the process replaces
    /// itself with one that has it set.
    private static let checkHomePrefix = "pb-check-safari-chrome-"

    /// A process like a profile's, for a check: Safari's frameworks loaded, `NSApp` Safari's own
    /// application object and its chrome prepared — in a home of its own, held to a closed proxy.
    /// False in the sandboxed build, which runs no process per profile and cannot be held to the
    /// closed proxy (UDP stays open to it, so the guard refuses), and when the frameworks cannot be
    /// loaded here. The home goes with `removeCheckHome()`.
    static func prepareForCheck(arguments: [String]) -> Bool {
        guard !AppEnvironment.isSandboxed else { return false }
        isolateForCheck(arguments: arguments)
        guard load() else { return false }
        // As a profile's process does (SafariChromeHost): Safari's own folders are the home's
        // before any of Safari's code runs, not the account's (which the sandbox refuses anyway).
        if let realHome = SafariPaths.realHome, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            SafariPaths.redirectGetters(from: realHome, to: home)
        }
        guard installApplication() else { return false }
        prepare()
        return true
    }

    private static func isolateForCheck(arguments: [String]) {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil else {
            let closed = ProxySettings(kind: .httpConnect, host: "127.0.0.1", port: 1)
            do {
                try ProfileNetworkGuard.engage(profileID: UUID(), proxy: closed)
            } catch {
                print("SAFARI-CHROME the process could not be held to a closed proxy: \(error)")
                exit(3)
            }
            return
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(checkHomePrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            print("SAFARI-CHROME no temporary home: \(error)")
            exit(3)
        }
        setenv("CFFIXED_USER_HOME", home.path, 1)
        setenv("HOME", home.path, 1)
        guard let executable = Bundle.main.executableURL?.path ?? arguments.first else { exit(3) }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execv(executable, &argv)
        print("SAFARI-CHROME could not restart in a home of its own: \(String(cString: strerror(errno)))")
        exit(3)
    }

    static func removeCheckHome() {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              URL(fileURLWithPath: home).lastPathComponent.hasPrefix(checkHomePrefix) else { return }
        try? FileManager.default.removeItem(atPath: home)
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

/// What Paste as Typed in Safari's Edit menu calls (`SafariChrome.addPasteAsTyped`).
@MainActor
private final class PasteAsTypedItem: NSObject {
    static let shared = PasteAsTypedItem()

    @objc func pasteAsTyped(_ sender: Any?) { HumanPaste.pasteIntoKeyWindow() }
}

/// What File › New Window calls in a profile's process (`SafariChrome.retargetNewWindow`): a window
/// of Safari's for the profile, on its start page, as one the manager asks for.
@MainActor
private final class NewWindowItem: NSObject {
    static let shared = NewWindowItem()

    @objc func newWindow(_ sender: Any?) {
        guard let session = ProfileNetworkGuard.session else { return }
        _ = SafariChromeHost.open(session: session, url: nil)
    }
}

/// Makes one of `--nib-check`'s nibs, from a timer of AppKit's run loop.
private final class NibLoader: NSObject {
    @objc func load(_ name: NSString) {
        MainActor.assumeIsolated {
            let name = name as String
            guard SafariChrome.safariHolds(nib: name) else {
                print("NIB-CHECK \(name): not in this Safari")
                return
            }
            print("NIB-CHECK \(name): asked of the main bundle")
            let nib = NSNib(nibNamed: name, bundle: .main)
            print("NIB-CHECK \(name): \(nib == nil ? "not made" : "made")")
        }
    }
}

/// Asks Safari's own General pane whether the default browser changed (`--default-browser-check`),
/// from a timer of AppKit's run loop.
private final class DefaultBrowserQuestion: NSObject {
    @objc func ask() {
        MainActor.assumeIsolated {
            guard let original = SafariChrome.defaultBrowserQuestion else {
                print("DEFAULT-BROWSER not in this Safari: -[GeneralPreferences _defaultWebBrowserMayHaveChanged]")
                return
            }
            guard let paneClass = NSClassFromString("GeneralPreferences") as? NSObject.Type else {
                print("DEFAULT-BROWSER not in this Safari: GeneralPreferences")
                return
            }
            // A preferences module is had through its class, as Safari's settings window has it.
            typealias Shared = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            let shared = NSSelectorFromString("sharedInstance")
            let pane = class_getClassMethod(paneClass, shared).flatMap { method in
                unsafeBitCast(method_getImplementation(method), to: Shared.self)(paneClass, shared)?.takeUnretainedValue() as? NSObject
            }
            let asked = pane ?? paneClass.init()
            print("DEFAULT-BROWSER asking \(pane == nil ? "a new" : "the shared") \(String(describing: type(of: asked)))")
            typealias Question = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(original, to: Question.self)(asked, NSSelectorFromString("_defaultWebBrowserMayHaveChanged"))
            print("DEFAULT-BROWSER answered without an exception")
        }
    }
}
