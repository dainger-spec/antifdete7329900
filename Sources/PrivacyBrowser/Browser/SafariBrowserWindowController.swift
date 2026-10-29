import AppKit
import Foundation
import ObjectiveC
import WebKit

/// Opens a profile's window with the system browser framework's own window controller instead of
/// the app's `BrowserWindowController`.
///
/// The sequence is the one the framework uses on itself: the application controller is obtained
/// (or built), asked for a new window with the frontmost profile, and the controller it hands
/// back is forced to load its window, finish its content setup and show it. None of those names
/// is hard-coded as the only possibility — each step takes a list of candidates and reports which
/// were present, which returned nil and which worked, because the names move between releases
/// and the point of this path is to find out what this macOS actually offers.
///
/// The profile's `WKWebsiteDataStore` is bound through `SafariHooks.bindDataStore`, which has to
/// wrap creation rather than follow it: see the note there on `-[WKWebView configuration]`
/// returning a copy.
///
/// Every failure returns nil with the trace intact and leaves the process a regular app, so the
/// caller can fall back to the in-process web view path with nothing to undo.
@MainActor
final class SafariBrowserWindowController: NSObject {
    let profileID: UUID
    /// What each step found. Carried into the log and the probe's report, nils included.
    private(set) var trace: [String] = []

    /// The framework's window controller. Held so the window is not torn down under us.
    private var frameworkController: NSObject?
    private(set) var window: NSWindow?
    private(set) var webView: WKWebView?
    /// The store the window's web view was actually created with, to compare with the profile's.
    private(set) var boundDataStore: WKWebsiteDataStore?

    /// `-safari-chrome` on the command line: every profile opened in this run takes the framework
    /// path, whatever its own `useSafariChrome` says. Nothing stored changes, so the next run
    /// without the argument is back to the profile's own setting.
    static let enabledByLaunchArgument = CommandLine.arguments.contains("-safari-chrome")

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
        guard SafariLoader.load() else {
            note("framework not loaded; none of \(SafariLoader.candidatePaths.count) paths opened")
            for failure in SafariLoader.openFailures { note("  \(failure.path) (on disk \(failure.onDisk)): \(failure.error)") }
            return nil
        }
        note("framework image: \(SafariLoader.loadedImageName ?? "nil (dlopen succeeded but dyld lists no image)")")
        guard SafariLoader.browserWindowControllerClass != nil else {
            note("BrowserWindowController -> nil; framework classes named *WindowController*: " +
                 SafariLoader.classNames(containing: "WindowController").prefix(12).joined(separator: ", ").ifEmpty("none"))
            return nil
        }

        // Everything that can create a web view runs inside the binding.
        SafariHooks.forgetObservations()
        let controller = SafariHooks.bindDataStore(dataStore) { () -> NSObject? in
            if let viaApp = createViaApplicationController() { return viaApp }
            note("application-controller path produced no controller; trying direct creation")
            return createDirectly()
        }
        guard let controller else {
            note("no window controller from any path")
            return fail()
        }
        frameworkController = controller
        note("window controller: \(NSStringFromClass(type(of: controller)))")

        // The window is a lazy nib load on NSWindowController; asking for it is what forces it.
        guard let window = loadWindow(of: controller) else { return fail() }
        self.window = window
        note("window: \(NSStringFromClass(type(of: window))), frame \(NSStringFromRect(window.frame))")

        SafariHooks.bindDataStore(dataStore) {
            finishContentSetup(of: controller)
            showWindow(controller)
            openFirstTab(of: controller, url: startURL)
        }

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

    /// Undoes the activation-policy change and drops everything held, then reports nil.
    private func fail() -> NSWindow? {
        SafariHooks.undoShell()
        if let controller = frameworkController { ObjCRuntime.send(controller, "close") }
        window?.orderOut(nil)
        frameworkController = nil
        window = nil
        webView = nil
        note("giving up; the in-process web view path remains")
        return nil
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
    private func reportDataStore(expected: WKWebsiteDataStore?) {
        guard let webView else { return }
        let actual = webView.configuration.websiteDataStore
        boundDataStore = actual
        let matches = expected != nil && actual === expected
        note("data store on the web view's configuration copy: \(SafariHooks.describe(actual)); " +
             "profile's: \(SafariHooks.describe(expected)); " + (matches ? "SAME OBJECT" : "DIFFERENT"))
        note("the bound store was read \(SafariHooks.observations.count) times while the window was built")
        for observation in SafariHooks.observations.prefix(8) { note("  \(observation)") }
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

    private func describeTree(_ view: NSView, depth: Int = 0) -> String {
        guard depth < 4 else { return "…" }
        let children = view.subviews.map { describeTree($0, depth: depth + 1) }
        let name = NSStringFromClass(type(of: view))
        return children.isEmpty ? name : "\(name)[\(children.joined(separator: " "))]"
    }

    private func note(_ message: String) {
        trace.append(message)
        NSLog("SafariWindow[\(profileID.uuidString.prefix(8))]: \(message)")
    }
}

private extension String {
    /// `self`, or `replacement` when there is nothing to show — so a report never prints a gap.
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
