import AppKit
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
///   `shared`           obtaining the application controller instance
///   `create`           the application-controller window path
///   `create-bootstrap` the same, after the launch callbacks
///   `create-direct`    allocating the window controller directly
///   `window`           the whole path as the app runs it, data store included
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
        say("step \(step)")
        say("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        say("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")

        // The steps that build a window need a running application; the rest must not wait for one.
        if ["shared", "create", "create-bootstrap", "create-direct", "window"].contains(step) {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                print("PROBE TIMEOUT after 90 s")
                exit(3)
            }
            Task { @MainActor in
                if step == "window" { await windowStep() } else { run(step) }
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
        guard loaded else { return }
        let related = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.contains("Safari") || path.contains("WebKit") ? path : nil
        }
        say("loaded images of interest (\(related.count)):")
        related.forEach { say("  \($0)") }
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
                if !hits.isEmpty { say("  *\(interesting)*: \(hits.prefix(14).map { $0.split(separator: " ").first.map { String($0) } ?? "" }.joined(separator: ", "))") }
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
        let window = controller.open(dataStore: WKWebsiteDataStore.nonPersistent(), startURL: URL(string: "about:blank"))
        controller.trace.forEach { say("  \($0)") }
        say("window: \(window.map { NSStringFromClass(type(of: $0)) } ?? "nil")")
        say("activation policy afterwards: \(NSApp.activationPolicy().rawValue) (0 = regular, 1 = accessory)")
    }

    private static func createDirectStep() {
        guard let cls = SafariLoader.browserWindowControllerClass as? NSObject.Type else {
            return say("BrowserWindowController -> nil")
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
        WebDataStoreVault.ensureWebKitInitialized()
        let profileID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        let target = URL(string: "https://example.com/")!
        say("profile store: \(SafariHooks.describe(store))")
        let controller = SafariBrowserWindowController(profileID: profileID)
        let window = controller.open(dataStore: store, startURL: target)
        controller.trace.forEach { say("  \($0)") }
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
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let names = records.map(\.displayName).sorted()
        say("records in the PROFILE's store after the load: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        say("the profile's store holds the loaded origin: \(names.contains { target.host?.hasSuffix($0) == true })")
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
