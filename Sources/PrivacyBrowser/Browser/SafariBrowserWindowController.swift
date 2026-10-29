import AppKit
import ExceptionCatcher
import Foundation
import ObjectiveC
import WebKit

/// Opens a profile's window with the system browser framework's own window controller instead of
/// the app's `BrowserWindowController`.
///
/// The sequence: make the framework's document controller the process's shared one (which must
/// happen before the application finishes launching — see `prepareProcess`), create a window
/// controller, force its nib to load, finish its content setup, show it, and open a first tab.
/// None of the names is hard-coded as the only possibility — each step takes a list of
/// candidates and reports which were present, which returned nil and which worked, because the
/// names move between releases and the point of this path is to find out what this macOS
/// actually offers.
///
/// With `-safari-chrome` a popup window is tried before that sequence (`PopupVariant`), in case
/// one is laid out without the toolbar's address bar, which is where the ordinary window dies.
/// Measured, it is not: a popup loads the same window with the same toolbar and raises at the
/// same point. Every call into the framework is guarded, on both routes, so an exception it
/// raises ends the attempt rather than the process wherever AppKit lets the exception reach us.
///
/// The profile's `WKWebsiteDataStore` is bound through `SafariHooks.bindDataStore`, which wraps
/// creation rather than following it: the framework makes its own store from a profile
/// identifier, so the binding replaces that factory.
///
/// Every failure returns nil with the trace intact and leaves the process a regular app, so the
/// caller can fall back to the in-process web view path with nothing to undo. On macOS 15 and 26
/// the path does not reach a usable window: it gets as far as the window's address bar laying
/// itself out and fails there on a nil attribute, a raised `NSException`. On macOS 15 that
/// exception comes out of `-window`, is caught, and the profile falls back; on macOS 26 AppKit
/// ends the process inside its layout pass, before anything can catch it — which is why nothing
/// here runs unless the framework path was asked for on the command line.
/// docs/SAFARI_FRAMEWORK_PATH.md has the measurements.
@MainActor
final class SafariBrowserWindowController: NSObject {
    let profileID: UUID
    /// What each step found. Carried into the log and the probe's report, nils included.
    private(set) var trace: [String] = []
    /// Called with each trace line as it happens. The probe prints them: a step that hangs
    /// inside the framework never reaches the end, and the trace would be lost with it.
    var onNote: ((String) -> Void)?

    /// The framework's window controller. Held so the window is not torn down under us.
    private var frameworkController: NSObject?
    /// Held for the process's lifetime: AppKit's shared document controller is never replaced.
    private static var documentController: NSObject?
    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    /// The store the window's web view was actually created with, to compare with the profile's.
    private(set) var boundDataStore: WKWebsiteDataStore?
    /// The popup tab's own web view, for when it is not (yet) in the window's view tree.
    private var tabWebView: WKWebView?
    /// Exceptions raised during the current attempt, as "name: reason". Any one ends a popup's.
    private var raised: [String] = []

    /// Ways of asking for a window controller without the toolbar's address bar, the view that
    /// raises in layout in the ordinary window (docs/SAFARI_FRAMEWORK_PATH.md, §1): a window a page
    /// opens is a popup to the framework, with an address field of its own. None gets one — a
    /// popup loads the same toolbar, its own field is a subclass with the same layout, and every
    /// variant fails (§9). The raw value is the probe step that runs it on its own.
    enum PopupVariant: String, CaseIterable {
        /// `[[BrowserWindowController alloc] initAsPopupWindow:YES]`.
        case initAsPopup = "popup"
        /// The same, with the popup's own address field turned off before the window loads.
        case initAsPopupWithoutField = "popup-nofield"
        /// `[[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]`.
        case browsingModePopup = "popup-mode"
        /// `+[BrowserWindowController hiddenEmptyBrowserWindowControllerWithBrowsingMode:0
        /// profileIdentifier:<profile> isPopupWindow:YES]`, the framework's own factory for a
        /// window with no tab in it.
        case hiddenEmptyPopup = "popup-hidden"
    }

    /// What `-safari-chrome` tries before the ordinary window: the popup initialiser alone. The
    /// rest are for the probe, one per process. In the app each would only build another window
    /// that fails the same way, and the empty-window factory gets as far as a half-made tab —
    /// the likely reason the ordinary window aborted when it was tried after all four (§9).
    static let popupOrder: [PopupVariant] = [.initAsPopup]

    /// `-safari-chrome` on the command line: every profile opened in this run takes the framework
    /// path, whatever its own `useSafariChrome` says. Nothing stored changes, so the next run
    /// without the argument is back to the profile's own setting.
    static let enabledByLaunchArgument = CommandLine.arguments.contains("-safari-chrome")

    /// The framework's `NSDocumentController` subclass. Its window creation goes through
    /// `+[NSDocumentController sharedDocumentController]` and sends it selectors only this
    /// subclass has, so it must exist before anything else asks for the shared one.
    private static let documentControllerClasses = ["BrowserDocumentController", "SafariDocumentController"]
    /// Classes that may own the application-controller side of the sequence.
    private static let appControllerClasses = [
        "AppController", "BrowserApplicationController", "SafariApplicationController", "ApplicationController",
    ]
    /// Class-side singletons, in the order the framework's own code is most likely to use.
    private static let sharedAccessors = [
        "sharedController", "shared", "sharedAppController", "sharedBrowserController",
        "defaultController", "sharedInstance", "sharedApplicationController",
    ]
    /// Window creation, in order. The first two are the pair the sample stacks named.
    private static let windowCreators = [
        "_createNewWindowWithFrontmostProfile:", "_newWindowWithFrontmostProfile:",
        "newWindowWithFrontmostProfile:", "_newWindowWithProfile:", "_newBrowserWindowController",
        "newBrowserWindowController", "_createNewWindow", "newWindow:", "_openNewWindow:", "openNewWindow:",
    ]
    /// What the framework does after the window loads, before it holds anything to look at.
    private static let contentSetup = [
        "_didCompleteContentSetup", "didCompleteContentSetup", "_setUpContentView", "_loadInitialContent",
    ]
    /// Opening the first tab, so the window is not an empty shell.
    private static let tabOpeners = [
        "openNewTabWithURL:", "_openNewTabWithURL:", "addTabForURL:", "newTab:", "_newTab:", "openNewTab:",
    ]

    init(profileID: UUID) {
        self.profileID = profileID
        super.init()
    }

    // MARK: Creation

    /// The framework window, or nil when any step of the sequence failed. On nil the process is
    /// left in `.regular` activation policy and nothing of the framework's is retained.
    func open(dataStore: WKWebsiteDataStore?, startURL: URL?) -> NSWindow? {
        guard frameworkReady() else { return fail() }

        // -safari-chrome: a popup first, in case it is laid out without the toolbar address bar
        // the window below dies on. Measured, it is not (docs/SAFARI_FRAMEWORK_PATH.md, §9).
        if Self.enabledByLaunchArgument {
            for variant in Self.popupOrder {
                if let window = attemptPopup(variant, dataStore: dataStore, startURL: startURL) { return window }
            }
            note("no popup variant gave a usable window; going on with the ordinary window")
        }

        // Guarded as the popup's calls are. A raise inside a binding would skip the binding's
        // end and leave the profile's store handed to every configuration made afterwards, and
        // one out of -window would unwind past the fallback to the in-process window.
        raised = []
        let previousObserver = startObservingRaises()
        defer { stopObservingRaises(previousObserver) }

        // Everything that can create a web view runs inside the binding.
        //
        // Direct creation first, and the application controller only as the fallback — the
        // opposite of the order the sample stacks suggest. Measured reason: `-[AppController
        // init]` eagerly builds its web-extension controllers, which reach
        // `-[WKWebViewConfiguration _setShouldRelaxThirdPartyCookieBlocking:]`, and WebKit
        // raises "may only be used by Safari" on any process that is not. Creating the window
        // controller directly never touches that branch and gets as far as laying out the
        // window. See docs/SAFARI_FRAMEWORK_PATH.md.
        SafariHooks.forgetObservations()
        var created: NSObject?
        SafariHooks.bindDataStore(dataStore) {
            guarded("creating the window controller") {
                if let direct = self.createDirectly() {
                    created = direct
                } else {
                    self.note("direct creation produced no controller; trying the application controller")
                    created = self.createViaApplicationController()
                }
            }
        }
        guard let controller = created else {
            note("no window controller from any path")
            return fail()
        }
        frameworkController = controller
        note("window controller: \(NSStringFromClass(type(of: controller)))")

        // The window is a lazy nib load on NSWindowController; asking for it is what forces it.
        var loaded: NSWindow?
        guard guarded("-window", { loaded = self.loadWindow(of: controller) }), let window = loaded else { return fail() }
        self.window = window
        note("window: \(NSStringFromClass(type(of: window))), frame \(NSStringFromRect(window.frame))")

        let setUp = SafariHooks.bindDataStore(dataStore) {
            guarded("setting up the window's content") {
                self.finishContentSetup(of: controller)
                self.showWindow(controller)
                self.openFirstTab(of: controller, url: startURL)
            }
        }
        guard setUp else { return fail() }

        guard let contentView = window.contentView else {
            note("window.contentView -> nil; the window loaded but holds nothing")
            return fail()
        }
        note("contentView: \(describeTree(contentView))")

        locateWebView(in: contentView)
        guard let webView else {
            note("no WKWebView in the window; the framework produced a shell with no web content")
            return fail()
        }
        reportDataStore(expected: dataStore)
        if let startURL, webView.url == nil {
            note("loading \(startURL) into the framework's web view")
            webView.load(URLRequest(url: startURL))
        }

        // Only now, with a window that exists and holds a web view, is the process reshaped.
        SafariHooks.applyShell(to: window)
        return window
    }

    /// The framework open, its window controller class present, and its document controller the
    /// process's shared one: what every route to a window needs first.
    private func frameworkReady() -> Bool {
        guard SafariLoader.load() else {
            note("framework not loaded; none of \(SafariLoader.candidatePaths.count) paths opened")
            for failure in SafariLoader.openFailures { note("  \(failure.path) (on disk \(failure.onDisk)): \(failure.error)") }
            return false
        }
        note("framework image: \(SafariLoader.loadedImageName ?? "nil (dlopen succeeded but dyld lists no image)")")
        guard SafariLoader.browserWindowControllerClass != nil else {
            note("BrowserWindowController -> nil; framework classes named *WindowController*: " +
                 SafariLoader.classNames(containing: "WindowController").prefix(12).joined(separator: ", ").ifEmpty("none"))
            return false
        }
        // Before anything else asks AppKit for the shared document controller.
        return installDocumentController()
    }

    /// Undoes the activation-policy change and drops everything held, then reports nil.
    private func fail() -> NSWindow? {
        SafariHooks.undoShell()
        adoptLoadedWindow()
        retireFrameworkWindow()
        frameworkController = nil
        window = nil
        webView = nil
        note("giving up; the in-process web view path remains")
        return nil
    }

    // MARK: The document controller

    /// Opens the framework and makes its `NSDocumentController` subclass the process's shared
    /// one. **This has to run before the application finishes launching**, and is the reason the
    /// `-safari-chrome` launch argument exists rather than only the per-profile setting.
    ///
    /// AppKit gives `+sharedDocumentController` to the first `NSDocumentController` created in
    /// the process and never replaces it. It creates one itself while finishing launching —
    /// state restoration asks for it — so by the time a profile window is opened it is too late:
    /// `-[BrowserDocumentController init]` gets AppKit's existing plain instance back out of
    /// `[super init]` and then sends it `_commonInit`, which a plain `NSDocumentController` does
    /// not have. The process dies on that unrecognized selector. Measured on macOS 15 and 26,
    /// sandboxed and not; see docs/SAFARI_FRAMEWORK_PATH.md.
    ///
    /// Irreversible: once the framework's document controller is the shared one it stays so for
    /// the rest of the run, even if the window path then fails and the app falls back to its own
    /// windows. That is why nothing calls this unless the framework path was explicitly asked
    /// for on the command line.
    @discardableResult
    static func prepareProcess() -> Bool {
        guard documentController == nil else { return true }
        guard SafariLoader.load() else {
            NSLog("SafariWindow: prepareProcess -> framework not loaded")
            return false
        }
        for className in documentControllerClasses {
            guard let cls = NSClassFromString(className) as? NSObject.Type else {
                NSLog("SafariWindow: class \(className) -> nil")
                continue
            }
            // The framework's own accessor first: it is what the framework calls on itself, and
            // it is what decides how the instance is set up.
            let viaAccessor = ObjCRuntime.callReturningObject(cls, "sharedDocumentController")
            NSLog("SafariWindow: +[\(className) sharedDocumentController]: \(viaAccessor.reason)")
            let instance = viaAccessor.value ?? cls.init()
            let shared = NSDocumentController.shared
            guard shared === instance else {
                NSLog("SafariWindow: made \(className), but +sharedDocumentController is " +
                      "\(NSStringFromClass(type(of: shared))) — a document controller already existed, " +
                      "and AppKit never replaces it")
                return false
            }
            documentController = instance
            NSLog("SafariWindow: +sharedDocumentController is now \(NSStringFromClass(type(of: instance)))")
            return true
        }
        NSLog("SafariWindow: no document controller class; framework classes named *DocumentController*: " +
              SafariLoader.classNames(containing: "DocumentController").prefix(12).joined(separator: ", ").ifEmpty("none"))
        return false
    }

    private func installDocumentController() -> Bool {
        guard let installed = Self.documentController else {
            note("document controller -> nil: prepareProcess() did not run, or ran too late. " +
                 "The framework's subclass can only become the shared one before the application " +
                 "finishes launching, which is what -safari-chrome is for.")
            return false
        }
        note("document controller: \(NSStringFromClass(type(of: installed)))")
        return true
    }

    // MARK: The popup path

    /// One popup variant on its own, as the probe runs it: one per process, so a variant that
    /// ends the process costs only itself.
    func openPopup(_ variant: PopupVariant, dataStore: WKWebsiteDataStore?, startURL: URL?) -> NSWindow? {
        guard frameworkReady() else { return fail() }
        return attemptPopup(variant, dataStore: dataStore, startURL: startURL)
    }

    /// A popup window start to finish: the controller, its window loaded and shown, shell mode,
    /// its tab, the web view and the web view's store. nil — with the controller closed and the
    /// process a regular app again — when any step returns nil or anything raises.
    private func attemptPopup(_ variant: PopupVariant, dataStore: WKWebsiteDataStore?, startURL: URL?) -> NSWindow? {
        note("popup path, \(variant.rawValue)")
        // Whether an exception AppKit catches during layout ends the process rests on this.
        note("NSApplicationCrashOnExceptions: \(Self.crashOnExceptionsSetting())")
        raised = []
        tabWebView = nil
        // Any exception raised while this runs ends the attempt, the ones AppKit catches itself
        // during layout included, which no caller ever sees. One the framework raised and caught
        // on its own would end it too; none is expected here, and a false failure costs only the
        // in-process window instead of this one.
        let previousObserver = startObservingRaises()
        defer { stopObservingRaises(previousObserver) }
        SafariHooks.forgetObservations()

        // Everything that can build a web view runs inside the binding, and each call into the
        // framework inside a guard. An exception therefore ends the attempt in here and never
        // unwinds through the binding, which would leave the profile's store bound to every
        // configuration made afterwards, other profiles' included.
        let built = SafariHooks.bindDataStore(dataStore) { buildPopup(variant) }
        guard built, let window, let webView else {
            return abandonPopup(variant, because: raised.isEmpty ? "no window with a web view" : "raised \(raised.joined(separator: "; "))")
        }
        describeWindow(window)
        guard reportDataStore(expected: dataStore) else {
            return abandonPopup(variant, because: "the web view is not on the profile's store")
        }
        if let startURL, webView.url == nil {
            note("loading \(startURL) into the popup's web view")
            guarded("loading the start page") { _ = webView.load(URLRequest(url: startURL)) }
        }
        guard raised.isEmpty else { return abandonPopup(variant, because: "raised \(raised.joined(separator: "; "))") }
        note("popup path, \(variant.rawValue): window up, its web view on the profile's store")
        return window
    }

    /// Creates, loads, shows and fills the popup window; true once it holds a web view with
    /// nothing raised on the way. Runs inside the data store binding.
    private func buildPopup(_ variant: PopupVariant) -> Bool {
        guard let cls = SafariLoader.browserWindowControllerClass else { return false }
        var made: NSObject?
        guard guarded("creating the controller", { made = self.createPopupController(variant, of: cls) }) else { return false }
        guard let controller = made else { return false }   // the nil is noted with its cause
        frameworkController = controller
        note("popup controller: \(NSStringFromClass(type(of: controller))); isPopupWindow=\(flag(controller, "isPopupWindow")), " +
             "isWindowLoaded=\(flag(controller, "isWindowLoaded"))")
        note("isPopupWindowUnifiedFieldVisible=\(flag(controller, "isPopupWindowUnifiedFieldVisible")), " +
             "isWindowLoaded=\(flag(controller, "isWindowLoaded"))")
        guard raised.isEmpty else { return false }

        if variant == .initAsPopupWithoutField {
            var sent = false
            guard guarded("setPopupWindowUnifiedFieldVisible:NO", {
                sent = ObjCRuntime.send(controller, "setPopupWindowUnifiedFieldVisible:", flag: false)
            }) else { return false }
            note("setPopupWindowUnifiedFieldVisible:NO -> \(sent ? "sent" : "not implemented"); " +
                 "isPopupWindowUnifiedFieldVisible=\(flag(controller, "isPopupWindowUnifiedFieldVisible")), " +
                 "isWindowLoaded=\(flag(controller, "isWindowLoaded"))")
            guard sent, raised.isEmpty else { return false }
        }

        // Asking for the window is what loads the nib and runs -windowDidLoad, whose layout pass
        // is where the ordinary window raised.
        var loaded: NSWindow?
        guard guarded("-window", { loaded = self.loadWindow(of: controller) }), let window = loaded else { return false }
        self.window = window
        note("-window -> \(NSStringFromClass(type(of: window))), frame \(NSStringFromRect(window.frame)), visible \(window.isVisible)")
        guard raised.isEmpty else { return false }

        var shown = false
        guard guarded("showWindow:", { shown = ObjCRuntime.send(controller, "showWindow:", argument: nil) }) else { return false }
        if !shown {
            note("showWindow: -> not implemented; ordering the window front directly")
            guard guarded("makeKeyAndOrderFront:", { window.makeKeyAndOrderFront(nil) }) else { return false }
        }
        settle(window, "after showWindow:")
        note("showWindow: \(shown ? "sent" : "not implemented"); visible \(window.isVisible), key \(window.isKeyWindow)")
        guard raised.isEmpty else { return false }

        guarded("shell mode") { SafariHooks.applyShell(to: window) }
        settle(window, "in shell mode")
        note("shell mode: activation policy \(NSApp.activationPolicy().rawValue) (1 = accessory), " +
             "style mask \(window.styleMask.rawValue), level \(window.level.rawValue)")
        guard raised.isEmpty else { return false }

        if findWebView(in: window) == nil {
            note("no web view in the window yet; opening its tab")
            guard openPopupTab(of: controller), raised.isEmpty else { return false }
            settle(window, "after the tab opened")
            guard raised.isEmpty else { return false }
        }
        guard let found = findWebView(in: window) ?? tabWebView else {
            note("web view -> nil: none in the window's views, and the tab handed none back")
            return false
        }
        webView = found
        note("web view: \(ObjCRuntime.chain(of: type(of: found)).joined(separator: " <- "))")
        return true
    }

    private func createPopupController(_ variant: PopupVariant, of cls: AnyClass) -> NSObject? {
        let call: (value: NSObject?, reason: String)
        switch variant {
        case .initAsPopup, .initAsPopupWithoutField:
            call = ObjCRuntime.allocating(cls, "initAsPopupWindow:", flag: true)
            note("[[BrowserWindowController alloc] initAsPopupWindow:YES]: \(call.reason)")
        case .browsingModePopup:
            call = ObjCRuntime.allocating(cls, "initWithBrowsingMode:isPopupWindow:", integer: 0, flag: true)
            note("[[BrowserWindowController alloc] initWithBrowsingMode:0 isPopupWindow:YES]: \(call.reason)")
        case .hiddenEmptyPopup:
            let name = "hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:"
            call = ObjCRuntime.callReturningObject(cls, name, integer: 0, object: profileID.uuidString as NSString, flag: true)
            note("+[BrowserWindowController \(name)] with 0, \(profileID.uuidString), YES: \(call.reason)")
        }
        return call.value
    }

    /// The popup's one tab, which is where its web view comes from. Called inside the data store
    /// binding: opening the tab is when the framework builds the web view's configuration.
    private func openPopupTab(of controller: NSObject) -> Bool {
        let name = "makeBrowserViewControllerInTabAtIndex:andSelect:"
        var call: (value: NSObject?, reason: String)?
        guard guarded(name, { call = ObjCRuntime.callReturningObject(controller, name, integer: 0, flag: true) }) else { return false }
        note("\(name) with 0, YES: \(call?.reason ?? "no result")")
        if let tab = call?.value {
            var tabView: NSObject?
            guard guarded("-webView on the tab", { tabView = ObjCRuntime.callReturningObject(tab, "webView").value }) else { return false }
            note("-[\(NSStringFromClass(type(of: tab))) webView] -> \(tabView.map { NSStringFromClass(type(of: $0)) } ?? "nil")")
            tabWebView = tabView as? WKWebView
            return true
        }
        var opened: Bool?
        guard guarded("openNewTab", { opened = ObjCRuntime.callReturningBool(controller, "openNewTab") }) else { return false }
        note("openNewTab -> \(opened.map { $0 ? "true" : "false" } ?? "not implemented")")
        return opened == true
    }

    /// Closes whatever the attempt made and makes the process a regular app again, so the next
    /// variant — or the ordinary window, or the in-process one — starts from nothing.
    private func abandonPopup(_ variant: PopupVariant, because reason: String) -> NSWindow? {
        note("popup path, \(variant.rawValue): giving up — \(reason)")
        adoptLoadedWindow()
        if let window { describeWindow(window) }
        if let controller = frameworkController { describeFields(of: controller) }
        note("the profile's store was handed out \(SafariHooks.observations.count) times during the attempt")
        SafariHooks.observations.prefix(8).forEach { note("  \($0)") }
        retireFrameworkWindow()
        SafariHooks.undoShell()
        frameworkController = nil
        window = nil
        webView = nil
        tabWebView = nil
        boundDataStore = nil
        return nil
    }

    /// When -window itself raised, the nib had loaded and the window exists; only the controller
    /// has it, and asking again returns it without loading anything.
    private func adoptLoadedWindow() {
        guard window == nil, let controller = frameworkController, flag(controller, "isWindowLoaded") == "true" else { return }
        var loaded: NSWindow?
        guarded("-window, already loaded") { loaded = ObjCRuntime.callReturningObject(controller, "window").value as? NSWindow }
        window = loaded
    }

    /// Takes a window that failed half-built out of AppKit's way. Closing it is not enough: its
    /// layout was cut short, so the next display cycle lays it out again, toolbar and all, and
    /// the address field raises there — outside any guard, where AppKit ends the process.
    /// Measured on macOS 15. Without its toolbar the field is in no window, and nothing lays it
    /// out again.
    private func retireFrameworkWindow() {
        if let window { guarded("detaching the toolbar") { window.toolbar = nil } }
        if let controller = frameworkController { guarded("closing the controller") { _ = ObjCRuntime.send(controller, "close") } }
        if let window { guarded("ordering the window out") { window.orderOut(nil) } }
    }

    /// Runs one call into the framework, catching an Objective-C exception it raises — which
    /// Swift cannot — so the attempt fails instead of the process. False when it raised.
    @discardableResult
    private func guarded(_ what: String, _ body: @escaping () -> Void) -> Bool {
        guard let exception = PBCatchException(body) else { return true }
        let line = "\(exception.name.rawValue): \(exception.reason ?? "no reason")"
        if !raised.contains(line) { raised.append(line) }
        note("\(what) raised \(line); caught, so the attempt ends and the process does not")
        return false
    }

    /// Records every exception raised from here on, the moment it is raised and with the stack it
    /// came from. Returns the observer it replaced, for `stopObservingRaises`.
    private func startObservingRaises() -> PBRaisedExceptionObserver? {
        PBObserveRaisedExceptions { [weak self] exception, stack in
            MainActor.assumeIsolated { () -> Void in
                guard let self else { return }
                self.noteRaised(exception, stack: stack)
            }
        }
    }

    private func stopObservingRaises(_ previous: PBRaisedExceptionObserver?) {
        _ = PBObserveRaisedExceptions(previous)
    }

    /// An exception as it is raised, with the stack it came from — printed at once, because the
    /// process may not live to report it any other way.
    private func noteRaised(_ exception: NSException, stack: [String]) {
        let line = "\(exception.name.rawValue): \(exception.reason ?? "no reason")"
        raised.append(line)
        note("RAISED \(line)")
        for frame in stack { note("  \(frame)") }
    }

    /// Runs the layout and display passes AppKit would otherwise run on a later turn of the run
    /// loop, so whatever they raise is raised inside the attempt rather than after it.
    private func settle(_ window: NSWindow, _ moment: String) {
        guarded("layout and display \(moment)") {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// What `NSApplicationCrashOnExceptions` reads as, and which domains set it.
    static func crashOnExceptionsSetting() -> String {
        let key = "NSApplicationCrashOnExceptions"
        let defaults = UserDefaults.standard
        func value(_ domain: [String: Any]?) -> String { domain?[key].map { "\($0)" } ?? "unset" }
        return "reads \(defaults.bool(forKey: key)); arguments \(value(defaults.volatileDomain(forName: UserDefaults.argumentDomain))), " +
            "app \(value(Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) })), " +
            "registered \(value(defaults.volatileDomain(forName: UserDefaults.registrationDomain)))"
    }

    /// A `BOOL` the framework reports, as text: "true", "false", or why there is no answer.
    private func flag(_ object: NSObject, _ name: String) -> String {
        var answer: Bool?
        guard guarded(name, { answer = ObjCRuntime.callReturningBool(object, name) }) else { return "raised" }
        return answer.map { $0 ? "true" : "false" } ?? "not implemented"
    }

    /// The first web view anywhere in the window, title bar included.
    private func findWebView(in window: NSWindow) -> WKWebView? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        return Self.firstWebView(in: root)
    }

    /// What the window holds, by class: its views, how many of them are the framework's address
    /// field, and its toolbar.
    private func describeWindow(_ window: NSWindow) {
        if let root = window.contentView?.superview ?? window.contentView {
            note("view tree: \(describeTree(root, limit: 6))")
        }
        unifiedFieldCensus(window).forEach(note)
        note("toolbar: \(window.toolbar.map { "\(NSStringFromClass(type(of: $0))), visible \($0.isVisible)" } ?? "none"); " +
             "title bar accessories: " +
             window.titlebarAccessoryViewControllers.map { NSStringFromClass(type(of: $0)) }.joined(separator: ", ").ifEmpty("none"))
    }

    /// The two address fields the controller can hold — the toolbar's and the popup's own — and
    /// where each is, in the window's view tree or not yet.
    private func describeFields(of controller: NSObject) {
        var toolbarField: NSObject?
        guarded("-unifiedField") { toolbarField = ObjCRuntime.callReturningObject(controller, "unifiedField").value }
        note("-unifiedField -> \(describeView(toolbarField))")
        note("_popupWindowUnifiedField -> \(describeView(objectIvar(controller, "_popupWindowUnifiedField")))")
    }

    private func describeView(_ object: NSObject?) -> String {
        guard let object else { return "nil" }
        guard let view = object as? NSView else { return NSStringFromClass(type(of: object)) }
        return "\(NSStringFromClass(type(of: view))), superview \(view.superview.map { NSStringFromClass(type(of: $0)) } ?? "nil"), " +
            "in a window \(view.window != nil), hidden \(view.isHidden), frame \(NSStringFromRect(view.frame))"
    }

    /// An object-typed instance variable, read without calling anything on the object.
    private func objectIvar(_ object: NSObject, _ name: String) -> NSObject? {
        guard let ivar = class_getInstanceVariable(type(of: object), name) else { return nil }
        return object_getIvar(object, ivar) as? NSObject
    }

    /// The views of the framework's address-field class in the window, subclasses included — the
    /// popup's own field is one, and lays out the same way — each with where it sits.
    private func unifiedFieldCensus(_ window: NSWindow) -> [String] {
        guard let fieldClass = NSClassFromString("UnifiedField") else { return ["class UnifiedField -> nil"] }
        guard let root = window.contentView?.superview ?? window.contentView else { return ["UnifiedField views: the window has no views"] }
        var found: [String] = []
        func visit(_ view: NSView) {
            if view.isKind(of: fieldClass) {
                var ancestors: [String] = []
                var next = view.superview
                while let ancestor = next, ancestors.count < 6 {
                    ancestors.append(NSStringFromClass(type(of: ancestor)))
                    next = ancestor.superview
                }
                found.append("  \(NSStringFromClass(type(of: view))), hidden \(view.isHiddenOrHasHiddenAncestor), " +
                             "in \(ancestors.joined(separator: " < "))")
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return ["UnifiedField views in the window: \(found.count)"] + found
    }

    // MARK: The application-controller path

    private func createViaApplicationController() -> NSObject? {
        guard let appController = applicationController() else { return nil }
        if UserDefaults.standard.bool(forKey: "PBSafariBootstrapAppController") {
            bootstrap(appController)
        }
        for name in Self.windowCreators {
            let call = ObjCRuntime.callReturningObject(appController, name)
            guard let result = call.value else {
                note(call.reason)
                continue
            }
            if isWindowController(result) {
                note(call.reason)
                return result
            }
            // Some of these hand back the window, not its controller.
            if let frameworkWindow = result as? NSWindow, let controller = frameworkWindow.windowController {
                note("\(name) -> NSWindow; taking its controller \(NSStringFromClass(type(of: controller)))")
                return controller
            }
            note("\(call.reason), which is neither a window controller nor a window")
        }
        return nil
    }

    /// The framework's application controller: its singleton if it has one, else a fresh instance.
    private func applicationController() -> NSObject? {
        for className in Self.appControllerClasses {
            guard let cls = NSClassFromString(className) as? NSObject.Type else {
                note("class \(className) -> nil")
                continue
            }
            for accessor in Self.sharedAccessors {
                let call = ObjCRuntime.callReturningObject(cls, accessor)
                guard let shared = call.value else { continue }   // absent accessors are noise, not findings
                note("+[\(className) \(accessor)] -> \(NSStringFromClass(type(of: shared)))")
                return shared
            }
            note("\(className): no class-side singleton among \(Self.sharedAccessors.count) candidates; allocating one")
            let instance = cls.init()
            note("[[\(className) alloc] init] -> \(NSStringFromClass(type(of: instance)))")
            return instance
        }
        note("no application controller class found; framework classes named *AppController*: " +
             SafariLoader.classNames(containing: "AppController").prefix(12).joined(separator: ", ").ifEmpty("none"))
        return nil
    }

    /// The launch callbacks the framework's application controller would get inside its own app.
    /// Off unless `PBSafariBootstrapAppController` is set: this is the step most likely to reach
    /// for state a foreign process does not have, and it crashes rather than returns when it does.
    private func bootstrap(_ appController: NSObject) {
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp) as NSNotification
        for name in ["applicationWillFinishLaunching:", "applicationDidFinishLaunching:", "_finishLaunching"] {
            note("bootstrap: sending \(name)")
            if !ObjCRuntime.send(appController, name, argument: name.hasSuffix(":") ? notification : nil) {
                note("bootstrap: \(name) -> not implemented")
            }
        }
    }

    // MARK: Direct creation

    private func createDirectly() -> NSObject? {
        guard let cls = SafariLoader.browserWindowControllerClass as? NSObject.Type else { return nil }
        let declared = ObjCRuntime.declaredSelectors(of: cls).filter { $0.hasPrefix("init") }.sorted()
        note("BrowserWindowController declares these initialisers: " + declared.joined(separator: ", ").ifEmpty("none"))
        // Only the argument-free one can be sent without knowing what the others want; the list
        // above is what the report carries, so the next round knows which argument to supply.
        // `initWithBrowsingMode:isPopupWindow:` is the one that takes the arguments the others
        // default; 0 is the ordinary (non-private) browsing mode, and this is not a popup.
        let designated = "initWithBrowsingMode:isPopupWindow:"
        if declared.contains(designated) {
            let call = ObjCRuntime.allocating(cls, designated, integer: 0, flag: false)
            note("[[BrowserWindowController alloc] \(designated)]: \(call.reason)")
            if let instance = call.value { return instance }
        }
        guard cls.instancesRespond(to: NSSelectorFromString("init")) else {
            note("BrowserWindowController does not respond to -init")
            return nil
        }
        let instance = cls.init()
        note("[[BrowserWindowController alloc] init] -> \(NSStringFromClass(type(of: instance)))")
        return instance
    }

    // MARK: After creation

    /// `-[NSWindowController window]` is what loads the nib; without it the controller holds nothing.
    private func loadWindow(of controller: NSObject) -> NSWindow? {
        let call = ObjCRuntime.callReturningObject(controller, "window")
        guard let window = call.value as? NSWindow else {
            note("\(call.reason) — the nib did not load, or the controller has no window")
            return nil
        }
        return window
    }

    private func finishContentSetup(of controller: NSObject) {
        let sent = Self.contentSetup.filter { name in
            guard ObjCRuntime.send(controller, name) else { return false }
            note("content setup: sent \(name)")
            return true
        }
        if sent.isEmpty { note("content setup: none of \(Self.contentSetup.count) candidates is implemented") }
    }

    private func showWindow(_ controller: NSObject) {
        guard ObjCRuntime.send(controller, "showWindow:", argument: nil) else {
            note("showWindow: -> not implemented; ordering the window front directly")
            window?.makeKeyAndOrderFront(nil)
            return
        }
        note("showWindow: sent; window isVisible=\(window?.isVisible ?? false)")
    }

    private func openFirstTab(of controller: NSObject, url: URL?) {
        for name in Self.tabOpeners {
            let argument: AnyObject? = name.hasSuffix(":") ? (url as NSURL?) : nil
            guard ObjCRuntime.send(controller, name, argument: argument) else { continue }
            note("first tab: sent \(name)")
            return
        }
        note("first tab: none of \(Self.tabOpeners.count) candidates is implemented")
    }

    // MARK: The web view and its store

    private func locateWebView(in root: NSView) {
        if let found = Self.firstWebView(in: root) {
            webView = found
            note("web view: \(ObjCRuntime.chain(of: type(of: found)).joined(separator: " <- "))")
            return
        }
        let observations = SafariHooks.observations
        if observations.isEmpty {
            note("web view -> nil, and the data store getter was never read: the framework built no web content")
        } else {
            note("web view -> nil in the view tree, though the store was handed out \(observations.count) times")
        }
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = firstWebView(in: subview) { return found }
        }
        return nil
    }

    /// Whether the store the window's web view got is the profile's own.
    ///
    /// `webView.configuration` is a copy, and a copy carries whatever was *assigned* to the
    /// original — not what WebKit read out of the getter while building the page. So this
    /// answers "did the framework hold our store", and the count below answers "was ours the one
    /// WebKit read". Only a lookup of the loaded origin in the profile's own store settles it for
    /// certain, which is what the probe's `window` step does.
    @discardableResult
    private func reportDataStore(expected: WKWebsiteDataStore?) -> Bool {
        guard let webView else { return false }
        let actual = webView.configuration.websiteDataStore
        boundDataStore = actual
        let matches = expected != nil && actual === expected
        note("data store on the web view's configuration copy: \(SafariHooks.describe(actual)); " +
             "profile's: \(SafariHooks.describe(expected)); " + (matches ? "SAME OBJECT" : "DIFFERENT"))
        note("the bound store was read \(SafariHooks.observations.count) times while the window was built")
        for observation in SafariHooks.observations.prefix(8) { note("  \(observation)") }
        return matches
    }

    /// True when the object is an `NSWindowController`, or quacks like one in a class we do not have.
    private func isWindowController(_ object: NSObject) -> Bool {
        object is NSWindowController || object.responds(to: NSSelectorFromString("showWindow:"))
    }

    // MARK: Teardown

    func close() {
        if let controller = frameworkController, ObjCRuntime.send(controller, "close") {
            // The controller closed its own window.
        } else {
            window?.close()
        }
        frameworkController = nil
        window = nil
        webView = nil
    }

    // MARK: Reporting

    private func describeTree(_ view: NSView, depth: Int = 0, limit: Int = 4) -> String {
        guard depth < limit else { return "…" }
        let children = view.subviews.map { describeTree($0, depth: depth + 1, limit: limit) }
        let name = NSStringFromClass(type(of: view))
        return children.isEmpty ? name : "\(name)[\(children.joined(separator: " "))]"
    }

    private func note(_ message: String) {
        trace.append(message)
        NSLog("SafariWindow[\(profileID.uuidString.prefix(8))]: \(message)")
        onNote?(message)
    }
}

private extension String {
    /// `self`, or `replacement` when there is nothing to show — so a report never prints a gap.
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
