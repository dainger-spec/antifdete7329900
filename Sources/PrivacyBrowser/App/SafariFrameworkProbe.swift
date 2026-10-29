import AppKit
import ExceptionCatcher
import Foundation
import MachO
import ObjectiveC
import WebKit

/// `PrivacyBrowser --safari-probe <step> [--out <folder>]`: one step of the system browser
/// framework window path, in its own process, reporting what it found.
///
/// The steps are separate processes on purpose. Reaching into a framework built for another
/// application crashes rather than returns, and a crash that takes a step down should cost that
/// step only — the driver (`scripts/safari_framework/run_probe.py`) records the signal and the
/// crash report and runs the next one. Everything printed here goes into
/// docs/SAFARI_FRAMEWORK_PATH.md.
///
/// Steps:
///   `image`            which path opens, what dyld then lists
///   `classes`          every class the framework's image contributes (full list to the folder)
///   `selectors`        which class owns the window-creation selectors, found by scanning
///   `appcontroller`    the application controller's methods and ivars
///   `windowcontroller` the window controller's methods, ivars, properties, superclasses
///   `documentcontroller` the document controller and the document it makes
///   `documentcontroller-create` what happens when AppKit already made one
///   `webconfig`        the framework's web view configuration factory, called on its own
///   `shared`           obtaining the application controller instance
///   `create`           the application-controller window path
///   `create-bootstrap` the same, after the launch callbacks
///   `create-direct`    allocating the window controller directly
///   `window`           the whole path as the app runs it, data store included
///   `popupfield`       the popup's own address field against the one that raises in layout
///   `popup`, `popup-nofield`, `popup-mode`, `popup-hidden`
///                      one popup variant each (`SafariBrowserWindowController.PopupVariant`),
///                      data store included, run without NSApplicationCrashOnExceptions
@MainActor
enum SafariFrameworkProbe {
    private static var outputFolder: URL?

    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--safari-probe"), arguments.indices.contains(index + 1) else {
            print("usage: PrivacyBrowser --safari-probe <step> [--out <folder>]")
            exit(2)
        }
        let step = arguments[index + 1]
        if let outIndex = arguments.firstIndex(of: "--out"), arguments.indices.contains(outIndex + 1) {
            let folder = URL(fileURLWithPath: arguments[outIndex + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            outputFolder = folder
        }
        installExceptionReporting()
        // Written to this app's preferences by the create-bootstrap step; every other step has
        // to start without it, or the riskiest call in the path runs where it was not asked for.
        if step != "create-bootstrap" { UserDefaults.standard.removeObject(forKey: "PBSafariBootstrapAppController") }
        let popup = SafariBrowserWindowController.PopupVariant(rawValue: step)
        if popup != nil {
            // The popup steps run as the app does. Whether an exception raised inside the
            // framework can be caught is what they measure, and crashing on exceptions would
            // end the process before anything had the chance to catch one. The popup path
            // records every exception as it is raised instead, so nothing is lost to a hang.
            UserDefaults.standard.removeObject(forKey: "NSApplicationCrashOnExceptions")
        } else {
            // AppKit catches an exception raised under its run loop and carries on, which turns
            // a clean failure into a hang with nothing to read. This makes it a crash instead, so
            // the driver gets the backtrace that says which framework call raised.
            UserDefaults.standard.set(true, forKey: "NSApplicationCrashOnExceptions")
        }
        say("step \(step)")
        say("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        say("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        say("NSApplicationCrashOnExceptions: \(UserDefaults.standard.bool(forKey: "NSApplicationCrashOnExceptions"))")

        // The steps that build a window need a running application; the rest must not wait for one.
        if popup != nil || ["shared", "create", "create-bootstrap", "create-direct", "window", "documentcontroller-create"].contains(step) {
            // Before NSApplication exists, let alone finishes launching: AppKit makes its own
            // document controller on the way up, and the framework's subclass can only be the
            // shared one if it got there first.
            if step != "documentcontroller-create" {
                say("prepareProcess: \(SafariBrowserWindowController.prepareProcess())")
                say("shared document controller is now \(NSStringFromClass(type(of: NSDocumentController.shared)))")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                print("PROBE TIMEOUT after 90 s")
                exit(3)
            }
            Task { @MainActor in
                if let popup {
                    await popupStep(popup)
                } else if step == "window" {
                    await windowStep()
                } else {
                    run(step)
                }
                say("step \(step) finished")
                exit(0)
            }
            app.run()
        } else {
            run(step)
            say("step \(step) finished")
            exit(0)
        }
    }

    private static func run(_ step: String) {
        switch step {
        case "image": imageStep()
        case "classes": classesStep()
        case "selectors": selectorsStep()
        case "appcontroller": dumpClassStep(candidates: SafariLoader.classNames(containing: "AppController"), fallback: "AppController")
        case "windowcontroller": dumpClassStep(candidates: SafariLoader.classNames(containing: "BrowserWindowController"),
                                               fallback: "BrowserWindowController")
        case "documentcontroller": dumpClassStep(candidates: ["BrowserDocumentController", "BrowserDocument"],
                                                 fallback: "BrowserDocumentController")
        case "documentcontroller-create": documentControllerCreateStep()
        case "popupfield": popupFieldStep()
        case "webconfig": webConfigurationStep()
        case "shared": sharedStep()
        case "create": createStep(bootstrap: false)
        case "create-bootstrap": createStep(bootstrap: true)
        case "create-direct": createDirectStep()
        default:
            say("unknown step \(step)")
            exit(2)
        }
    }

    // MARK: Steps

    private static func imageStep() {
        for path in SafariLoader.candidatePaths {
            say("candidate \(path): on disk \(FileManager.default.fileExists(atPath: path))")
        }
        let loaded = SafariLoader.load()
        say("dlopen succeeded: \(loaded)")
        for failure in SafariLoader.openFailures {
            say("  failed \(failure.path) (on disk \(failure.onDisk)): \(failure.error)")
        }
        say("opened path: \(SafariLoader.openedPath ?? "nil")")
        say("dyld image name: \(SafariLoader.loadedImageName ?? "nil")")
        guard loaded else {
            say("searching for it instead:")
            SafariLoader.searchForFramework().forEach { say("  \($0)") }
            return
        }
        let related = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.contains("Safari") || path.contains("WebKit") ? path : nil
        }
        say("loaded images of interest (\(related.count)):")
        related.forEach { say("  \($0)") }
        say("what the framework bundle holds on disk:")
        SafariLoader.bundleContents().forEach { say("  \($0)") }
    }

    /// The framework's own web view configuration factory, called directly. Everything the
    /// window path does with web content goes through it, so whatever it does here is the
    /// ceiling for the whole approach — measured on its own rather than inferred from a
    /// backtrace five frames deep.
    private static func webConfigurationStep() {
        guard SafariLoader.load() else { return say("framework not loaded") }
        guard let cls = NSClassFromString("WebKitPreferencesManager") else {
            return say("WebKitPreferencesManager -> nil")
        }
        let classSide = object_getClass(cls).map { ObjCRuntime.declaredSelectors(of: $0).sorted() } ?? []
        let factories = classSide.filter { $0.range(of: "configuration", options: .caseInsensitive) != nil }
        say("configuration factories: \(factories.isEmpty ? "none" : factories.joined(separator: ", "))")
        let name = "contentWebViewConfigurationForBrowsingMode:profileIdentifier:automationSessionIdentifier:"
        guard classSide.contains(name) else { return say("\(name) -> not declared") }
        // A profile identifier is required: with nil the framework's own store factory raises
        // from -[_WKWebsiteDataStoreConfiguration initWithIdentifier:] before anything else runs.
        let identifier = UUID().uuidString
        say("calling +[WebKitPreferencesManager \(name)] for profile \(identifier) …")
        let call = ObjCRuntime.callReturningObject(cls, name, integer: 0, first: identifier as NSString, second: nil)
        say("  \(call.reason)")
        if let configuration = call.value as? WKWebViewConfiguration {
            say("  websiteDataStore: \(SafariHooks.describe(configuration.websiteDataStore))")
        }
        // And again with the profile's own store bound, to see whether the factory is the key.
        WebDataStoreVault.ensureWebKitInitialized()
        let ours = WKWebsiteDataStore.nonPersistent()
        SafariHooks.forgetObservations()
        let bound = SafariHooks.bindDataStore(ours) {
            ObjCRuntime.callReturningObject(cls, name, integer: 0, first: UUID().uuidString as NSString, second: nil)
        }
        say("with the profile's store bound: \(bound.reason)")
        SafariHooks.observations.forEach { say("  \($0)") }
        if let configuration = bound.value as? WKWebViewConfiguration {
            say("  websiteDataStore is the bound one: \(configuration.websiteDataStore === ours)")
        }
    }

    private static func classesStep() {
        guard SafariLoader.load() else { return say("framework not loaded") }
        let names = SafariLoader.classNames()
        say("classes in the image: \(names.count)")
        write(names.sorted().joined(separator: "\n"), to: "framework-classes.txt")
        for fragment in ["AppController", "BrowserWindowController", "BrowserViewController", "WindowController",
                         "Profile", "WebView", "TabContent", "BrowserWindow"] {
            let hits = names.filter { $0.range(of: fragment, options: .caseInsensitive) != nil }.sorted()
            say("*\(fragment)*: \(hits.count) -> \(hits.prefix(25).joined(separator: ", "))")
        }
    }

    private static func selectorsStep() {
        guard SafariLoader.load() else { return say("framework not loaded") }
        for selector in ["_newWindowWithFrontmostProfile:", "_createNewWindowWithFrontmostProfile:",
                         "newWindowWithFrontmostProfile:", "showWindow:", "_didCompleteContentSetup"] {
            let owners = SafariLoader.classesImplementing(selector)
            say("\(selector): \(owners.isEmpty ? "nil — no class in the image declares it" : owners.map { "\($0.className)\($0.isClassMethod ? " (class method)" : "")" }.joined(separator: ", "))")
        }
        var report = ""
        for fragments in [["newwindow"], ["createnewwindow"], ["frontmostprofile"], ["websitedatastore"], ["profile", "window"]] {
            let matches = SafariLoader.selectors(matchingAll: fragments)
            say("selectors matching \(fragments): \(matches.count) classes")
            report += "== \(fragments.joined(separator: " + ")) ==\n"
            for match in matches {
                report += "\(match.className): \(match.selectors.joined(separator: ", "))\n"
            }
            for match in matches.prefix(12) {
                say("  \(match.className): \(match.selectors.prefix(8).joined(separator: ", "))")
            }
        }
        write(report, to: "framework-selectors.txt")
    }

    private static func dumpClassStep(candidates: [String], fallback: String) {
        guard SafariLoader.load() else { return say("framework not loaded") }
        let names = candidates.isEmpty ? [fallback] : candidates
        say("classes to dump: \(names.joined(separator: ", "))")
        var report = ""
        for name in names {
            guard let cls = NSClassFromString(name) else {
                say("\(name) -> nil")
                continue
            }
            let chain = ObjCRuntime.chain(of: cls)
            say("\(name): \(chain.joined(separator: " <- "))")
            let instance = ObjCRuntime.declaredSignatures(of: cls).sorted()
            let classSide = object_getClass(cls).map { ObjCRuntime.declaredSignatures(of: $0).sorted() } ?? []
            let ivars = ObjCRuntime.ivars(of: cls)
            let properties = ObjCRuntime.properties(of: cls)
            say("  \(instance.count) instance methods, \(classSide.count) class methods, \(ivars.count) ivars, \(properties.count) properties")
            for interesting in ["init", "window", "profile", "webview", "datastore", "configuration", "shared", "new", "tab"] {
                let hits = (instance + classSide).filter { $0.range(of: interesting, options: .caseInsensitive) != nil }
                if !hits.isEmpty { say("  *\(interesting)*: \(hits.prefix(14).map { $0.split(separator: " ").first.map(String.init) ?? "" }.joined(separator: ", "))") }
            }
            let storeIvars = ivars.filter { $0.range(of: "store", options: .caseInsensitive) != nil || $0.range(of: "profile", options: .caseInsensitive) != nil }
            say("  ivars naming a store or a profile: \(storeIvars.isEmpty ? "none" : storeIvars.joined(separator: " | "))")
            report += "===== \(name) =====\nchain: \(chain.joined(separator: " <- "))\n"
            report += "-- class methods --\n" + classSide.joined(separator: "\n")
            report += "\n-- instance methods --\n" + instance.joined(separator: "\n")
            report += "\n-- ivars --\n" + ivars.joined(separator: "\n")
            report += "\n-- properties --\n" + properties.joined(separator: "\n") + "\n\n"
        }
        write(report, to: "framework-\(fallback).txt")
    }

    /// The popup's own address field against the toolbar's, which raises in layout: whether the
    /// popup's is that class underneath, and so lays out — and raises — the same way.
    private static func popupFieldStep() {
        guard SafariLoader.load() else { return say("framework not loaded") }
        guard let unifiedField = NSClassFromString("UnifiedField") else { return say("UnifiedField -> nil") }
        let failing = ["_notSecureAnnotation", "_layOutFaviconAndMainContentView", "layout"]
        for name in ["UnifiedField", "PopupWindowUnifiedField", "InteriorUnifiedField",
                     "PopupWindowUnifiedFieldContainerView", "PopupWindowUnifiedFieldViewController"] {
            guard let cls = NSClassFromString(name) else {
                say("\(name) -> nil")
                continue
            }
            let chain = ObjCRuntime.chain(of: cls)
            say("\(name): \(chain.joined(separator: " <- ")); a UnifiedField: \(chain.contains("UnifiedField"))")
            let declared = Set(ObjCRuntime.declaredSelectors(of: cls))
            for selector in failing {
                let sel = NSSelectorFromString(selector)
                guard let method = class_getInstanceMethod(cls, sel) else {
                    say("  -\(selector): not implemented")
                    continue
                }
                // The same implementation as UnifiedField's is the one that raised there.
                let sameAsField = class_getInstanceMethod(unifiedField, sel).map {
                    unsafeBitCast(method_getImplementation($0), to: UnsafeRawPointer.self) ==
                        unsafeBitCast(method_getImplementation(method), to: UnsafeRawPointer.self)
                } ?? false
                say("  -\(selector): \(declared.contains(selector) ? "declared here" : "inherited")" +
                    (name != "UnifiedField" && sameAsField ? ", UnifiedField's own implementation" : ""))
            }
        }
        dumpClassStep(candidates: ["PopupWindowUnifiedField", "PopupWindowUnifiedFieldViewController", "BrowserViewController"],
                      fallback: "PopupWindowUnifiedField")
    }

    /// Which way of getting the framework's document controller works, and whether AppKit then
    /// agrees it is the shared one. Runs under a running application on purpose: it is the one
    /// step that measures what happens when AppKit got there first.
    private static func documentControllerCreateStep() {
        guard SafariLoader.load() else { return say("framework not loaded") }
        guard let cls = NSClassFromString("BrowserDocumentController") as? NSObject.Type else {
            return say("BrowserDocumentController -> nil")
        }
        say("chain: \(ObjCRuntime.chain(of: cls).joined(separator: " <- "))")
        let declared = Set(ObjCRuntime.declaredSelectors(of: cls))
        say("declares -init: \(declared.contains("init")), -_commonInit: \(declared.contains("_commonInit"))")
        let classSide = object_getClass(cls).map { Set(ObjCRuntime.declaredSelectors(of: $0)) } ?? []
        say("declares +sharedDocumentController: \(classSide.contains("sharedDocumentController"))")
        say("a document controller exists before we ask: this step is about to find out")
        let viaAccessor = ObjCRuntime.callReturningObject(cls, "sharedDocumentController")
        say("+[BrowserDocumentController sharedDocumentController]: \(viaAccessor.reason)")
        say("NSDocumentController.shared is \(NSStringFromClass(type(of: NSDocumentController.shared)))")
    }

    private static func sharedStep() {
        guard SafariLoader.load() else { return say("framework not loaded") }
        for className in ["AppController", "BrowserApplicationController", "SafariApplicationController"] {
            guard let cls = NSClassFromString(className) else {
                say("\(className) -> nil")
                continue
            }
            let classSide = object_getClass(cls).map { ObjCRuntime.declaredSelectors(of: $0) } ?? []
            let accessors = classSide.filter { $0.hasPrefix("shared") || $0.hasPrefix("default") || $0 == "controller" }
            say("\(className) class-side singletons: \(accessors.isEmpty ? "none" : accessors.joined(separator: ", "))")
            for accessor in accessors {
                say("sending +[\(className) \(accessor)] …")
                say("  " + ObjCRuntime.callReturningObject(cls, accessor).reason)
            }
        }
    }

    private static func createStep(bootstrap: Bool) {
        if bootstrap { UserDefaults.standard.set(true, forKey: "PBSafariBootstrapAppController") }
        WebDataStoreVault.ensureWebKitInitialized()
        let controller = SafariBrowserWindowController(profileID: UUID())
        controller.onNote = { say("  \($0)") }
        let window = controller.open(dataStore: WKWebsiteDataStore.nonPersistent(), startURL: URL(string: "about:blank"))
        say("window: \(window.map { NSStringFromClass(type(of: $0)) } ?? "nil")")
        say("activation policy afterwards: \(NSApp.activationPolicy().rawValue) (0 = regular, 1 = accessory)")
    }

    private static func createDirectStep() {
        guard let cls = SafariLoader.browserWindowControllerClass as? NSObject.Type else {
            return say("BrowserWindowController -> nil")
        }
        if let documentControllerClass = NSClassFromString("BrowserDocumentController") as? NSObject.Type {
            let created = documentControllerClass.init()
            say("document controller created: \(NSStringFromClass(type(of: created))); " +
                "+sharedDocumentController is \(NSStringFromClass(type(of: NSDocumentController.shared)))")
        } else {
            say("BrowserDocumentController -> nil")
        }
        say("initialisers it declares: " +
            ObjCRuntime.declaredSelectors(of: cls).filter { $0.hasPrefix("init") }.sorted().joined(separator: ", "))
        say("allocating \(NSStringFromClass(cls)) …")
        let instance = cls.init()
        say("instance: \(NSStringFromClass(type(of: instance)))")
        say("asking for -window (this is what loads the nib) …")
        let call = ObjCRuntime.callReturningObject(instance, "window")
        say("  " + call.reason)
        guard let window = call.value as? NSWindow else { return }
        say("contentView: \(window.contentView.map { NSStringFromClass(type(of: $0)) } ?? "nil")")
        say("subviews: \(window.contentView?.subviews.count ?? 0)")
    }

    /// The whole path, and then the only check that settles the data store question: load a page
    /// in the framework's window and ask the *profile's* store whether that origin's data landed
    /// in it. The configuration copy on the web view cannot answer that (see the note in
    /// `SafariBrowserWindowController.reportDataStore`).
    private static func windowStep() async {
        await openAndCheck { controller, store, target in controller.open(dataStore: store, startURL: target) }
    }

    /// One popup variant on its own, then the same check.
    private static func popupStep(_ variant: SafariBrowserWindowController.PopupVariant) async {
        await openAndCheck { controller, store, target in controller.openPopup(variant, dataStore: store, startURL: target) }
    }

    private static func openAndCheck(_ opening: (SafariBrowserWindowController, WKWebsiteDataStore, URL) -> NSWindow?) async {
        WebDataStoreVault.ensureWebKitInitialized()
        let profileID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        let target = URL(string: "https://example.com/")!
        say("profile store: \(SafariHooks.describe(store))")
        // Outside the popup attempt, which records its own: an exception raised by work the
        // framework queued for a later turn of the run loop would otherwise reach AppKit's
        // handler with nothing here to say so.
        _ = PBObserveRaisedExceptions { exception, stack in
            MainActor.assumeIsolated { () -> Void in
                say("RAISED, seen by the probe: \(exception.name.rawValue): \(exception.reason ?? "no reason")")
                for frame in stack { say("  \(frame)") }
            }
        }
        let controller = SafariBrowserWindowController(profileID: profileID)
        controller.onNote = { say("  \($0)") }
        let window = opening(controller, store, target)
        guard let window else {
            say("RESULT no window")
            say("activation policy afterwards: \(NSApp.activationPolicy().rawValue) (0 = regular, 1 = accessory)")
            return
        }
        say("RESULT window \(NSStringFromClass(type(of: window))) visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))")
        guard let webView = controller.webView else {
            say("web view: nil")
            return
        }
        say("web view: \(NSStringFromClass(type(of: webView)))")
        say("store on the web view's configuration copy is the profile's object: \(controller.boundDataStore === store)")
        for _ in 0..<40 where webView.isLoading || webView.url == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        say("after loading: url=\(webView.url?.absoluteString ?? "nil") title=\(webView.title ?? "nil")")
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let names = records.map(\.displayName).sorted()
        say("records in the PROFILE's store after the load: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        say("the profile's store holds the loaded origin: \(names.contains { target.host?.hasSuffix($0) == true })")
        // The page is in and the address field has something to show: one more layout and
        // display pass, as the window gets on screen.
        let late = PBCatchException {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        say("layout and display after the load: " +
            (late.map { "raised \($0.name.rawValue): \($0.reason ?? "no reason")" } ?? "nothing raised") +
            "; visible=\(window.isVisible)")
        await snapshot(window, webView: webView)
    }

    /// The window as drawn, for the report: its views rendered into a bitmap, which needs no
    /// screen recording permission, and the page as WebKit renders it.
    private static func snapshot(_ window: NSWindow, webView: WKWebView) async {
        var windowPNG: Data?
        let raised = PBCatchException {
            guard let root = window.contentView?.superview ?? window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            windowPNG = rep.representation(using: .png, properties: [:])
        }
        if let raised { say("drawing the window raised \(raised.name.rawValue): \(raised.reason ?? "no reason")") }
        if let windowPNG { write(windowPNG, to: "window.png") } else { say("window drawing: nothing to write") }
        let page: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        if let tiff = page?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            write(png, to: "page.png")
        } else {
            say("page snapshot: none")
        }
    }

    // MARK: Reporting

    private static func say(_ message: String) {
        print("PROBE \(message)")
    }

    private static func write(_ text: String, to name: String) {
        guard let folder = outputFolder else { return }
        let url = folder.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            say("wrote \(name) (\(text.utf8.count) bytes)")
        } catch {
            say("could not write \(name): \(error)")
        }
    }

    private static func write(_ data: Data, to name: String) {
        guard let folder = outputFolder else { return }
        do {
            try data.write(to: folder.appendingPathComponent(name))
            say("wrote \(name) (\(data.count) bytes)")
        } catch {
            say("could not write \(name): \(error)")
        }
    }

    /// An Objective-C exception from inside the framework is the most informative way this can
    /// fail, and its reason is lost once the process aborts. Signals are left to the driver,
    /// which reads the exit status and the crash report.
    private static func installExceptionReporting() {
        NSSetUncaughtExceptionHandler { exception in
            var text = "PROBE EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "no reason")\n"
            for frame in exception.callStackSymbols { text += "PROBE   \(frame)\n" }
            FileHandle.standardError.write(Data(text.utf8))
        }
    }
}
