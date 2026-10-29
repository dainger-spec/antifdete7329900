// Runtime probe for Safari's private UI frameworks, from a process that is not Safari.
//
// A shipping competitor hosts Safari's own view controllers inside its per-profile process
// (docs/SAFARI_PROCESS.md §9). Those classes are undocumented and have no headers, so before any
// of it can be written here we need the real class names on this Mac, whether they load at all
// from a foreign process, and whether a profile directory can be given to them through
// CFFIXED_USER_HOME. This probe answers exactly that and changes nothing on disk.
//
//   swiftc -O scripts/safari_chrome_probe.swift -o /tmp/sprobe && /tmp/sprobe
//   /tmp/sprobe --all                        every class of the private Safari frameworks
//   CFFIXED_USER_HOME=/tmp/pbprofile /tmp/sprobe --paths
//   /tmp/sprobe --try-init <ClassName> [--load-view]
//
// Safari's own window on screen, in this process (the minimum set found on macOS 27.0.1 /
// Safari 26; docs/SAFARI_PROCESS.md §9.1 says what each argument answers):
//
//   CFFIXED_USER_HOME=/tmp/pbprofile /tmp/sprobe --prepare --tolerate-nil-attributes \
//     --bridge-images \
//     --stub image/UnifiedField/_assistantButtonIconForContentOption:withSparkle: \
//     --stub nil/BrowserWindowController/_setUpClusterManagerIfNeeded \
//     --try-init BrowserWindowController --show-window
//
// --try-init is a separate run on purpose: a controller that needs Safari's own singletons can
// abort the process, and that must not take the class listing down with it.

import AppKit
import Foundation
import ObjectiveC.runtime
import WebKit

// Line-buffered: a class that aborts inside Safari's own code must still leave the marker of
// what was being tried on the terminal.
setvbuf(stdout, nil, _IOLBF, 0)

// Safari's frameworks assert and abort when a singleton they expect has not been set up, and
// its window layout throws Objective-C exceptions that +[NSApplication _crashOnException:] turns
// into a crash with nothing printed. Each such failure names the next thing to prepare, so the
// probe reports both itself rather than leaving them to a crash report.
func installCrashReporter() {
    let handler: @convention(c) (Int32) -> Void = { signalNumber in
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        var banner = "\n== aborted on signal \(signalNumber) ==\n"
        banner.withUTF8 { buffer in _ = write(2, buffer.baseAddress, buffer.count) }
        backtrace_symbols_fd(&frames, count, 2)
        _exit(1)
    }
    for signalNumber in [SIGABRT, SIGTRAP, SIGSEGV, SIGILL, SIGBUS] {
        signal(signalNumber, handler)
    }
    NSSetUncaughtExceptionHandler { exception in
        var text = "\n== NSException ==\n\(exception.name.rawValue): \(exception.reason ?? "-")\n"
        for frame in exception.callStackSymbols { text += "   " + frame + "\n" }
        text.withUTF8 { buffer in _ = write(2, buffer.baseAddress, buffer.count) }
    }
}
installCrashReporter()

/// An exception thrown during AppKit layout never reaches an uncaught-exception handler:
/// +[NSApplication _crashOnException:] traps the process where it stands. The objc runtime's
/// exception preprocessor runs at the throw itself, which is the only place left to read the
/// reason from.
func installExceptionPreprocessor() {
    typealias Preprocessor = @convention(c) (AnyObject) -> AnyObject
    typealias Install = @convention(c) (Preprocessor) -> Preprocessor
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else {
        print("objc_setExceptionPreprocessor not found; exception reasons will not be printed")
        return
    }
    let install = unsafeBitCast(symbol, to: Install.self)
    _ = install({ thrown in
        var text = "\n== exception thrown ==\n"
        if let exception = thrown as? NSException {
            text += "\(exception.name.rawValue): \(exception.reason ?? "-")\n"
            for frame in exception.callStackSymbols.prefix(25) { text += "   " + frame + "\n" }
        } else {
            text += "\(thrown)\n"
        }
        text.withUTF8 { buffer in _ = write(2, buffer.baseAddress, buffer.count) }
        return thrown
    })
}
installExceptionPreprocessor()

let arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { arguments.contains(name) }
func value(after name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

if CommandLine.arguments.contains("--tolerate-exceptions") {
    // The argument domain only, as WebKit and this project do elsewhere: nothing is written to
    // any preferences file.
    var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    domain["NSApplicationCrashOnExceptions"] = false
    UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
}

// Loaded through their /System/Library paths; on a cryptex system those resolve into
// /System/Volumes/Preboot/Cryptexes/OS/… by themselves.
let frameworks = [
    "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
    "/System/Library/PrivateFrameworks/SafariShared.framework/Versions/A/SafariShared",
    "/System/Library/PrivateFrameworks/SafariFoundation.framework/Versions/A/SafariFoundation",
    "/System/Library/PrivateFrameworks/SafariServices.framework/Versions/A/SafariServices",
    "/System/Library/PrivateFrameworks/PasswordManagerUI.framework/Versions/A/PasswordManagerUI",
]

func dlopenError() -> String {
    guard let message = dlerror() else { return "unknown" }
    return String(cString: message)
}

// MARK: Paths

if flag("--paths") {
    print("== paths ==")
    print("CFFIXED_USER_HOME env   \(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "(unset)")")
    print("HOME env                \(ProcessInfo.processInfo.environment["HOME"] ?? "(unset)")")
    print("NSHomeDirectory()       \(NSHomeDirectory())")
    for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory, .libraryDirectory] {
        let urls = FileManager.default.urls(for: directory, in: .userDomainMask)
        print("\(directory == .applicationSupportDirectory ? "Application Support" : directory == .cachesDirectory ? "Caches            " : "Library           ")      \(urls.first?.path ?? "-")")
    }
    print("")
    print("If NSHomeDirectory() followed CFFIXED_USER_HOME, a per-profile directory can be handed")
    print("to Safari's frameworks the way the competitor does; if it did not, they must be")
    print("redirected another way.")
    exit(0)
}

// MARK: Load

print("== dlopen ==")
var loaded: [String] = []
for path in frameworks {
    if dlopen(path, RTLD_NOW) != nil {
        print("ok    \(path)")
        loaded.append(path)
    } else {
        print("FAIL  \(path)\n        \(dlopenError())")
    }
}
if loaded.isEmpty {
    print("\nNothing loaded. Under the hardened runtime this needs")
    print("com.apple.security.cs.disable-library-validation; run the probe ad-hoc signed (as built")
    print("above) or add the entitlement to whatever host is being tried.")
    exit(1)
}

// MARK: Class list

/// Every Objective-C class whose image is one of the private Safari frameworks.
func privateSafariClasses() -> [(name: String, image: String, superclass: String)] {
    let count = objc_getClassList(nil, 0)
    guard count > 0 else { return [] }
    var classes = [AnyClass?](repeating: nil, count: Int(count))
    classes.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(base), count)
    }
    let interestingImages = ["Safari.framework", "SafariShared.framework", "SafariFoundation.framework",
                             "SafariServices.framework", "PasswordManagerUI.framework"]
    var result: [(String, String, String)] = []
    for case let cls? in classes {
        guard let imagePointer = class_getImageName(cls) else { continue }
        let image = String(cString: imagePointer)
        guard interestingImages.contains(where: { image.contains($0) }) else { continue }
        let superclass = class_getSuperclass(cls).map { String(cString: class_getName($0)) } ?? "-"
        result.append((String(cString: class_getName(cls)), (image as NSString).lastPathComponent, superclass))
    }
    return result.sorted { $0.0 < $1.0 }
}

let classes = privateSafariClasses()
print("\n== classes ==\n\(classes.count) classes from the private Safari frameworks")

if flag("--all") {
    for entry in classes { print("\(entry.image)\t\(entry.name) : \(entry.superclass)") }
} else if let needle = value(after: "--grep") {
    for entry in classes where entry.name.range(of: needle, options: .caseInsensitive) != nil {
        print("   \(entry.name) : \(entry.superclass)   [\(entry.image)]")
    }
} else if let className = value(after: "--methods") {
    guard let cls = NSClassFromString(className) else {
        print("no such class")
        exit(1)
    }
    func dump(_ target: AnyClass, _ mark: String) {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(target, &count) else { return }
        let names = (0..<Int(count)).map { String(cString: sel_getName(method_getName(list[$0]))) }.sorted()
        for name in names { print("  \(mark)\(name)") }
        free(list)
    }
    if let meta = object_getClass(cls) { dump(meta, "+") }
    dump(cls, "-")
} else {
    // The parts of Safari's chrome worth hosting, by what their names contain.
    let groups: [(String, [String])] = [
        ("start page", ["StartPage", "Favorites", "FrequentlyVisited", "SuggestedSites"]),
        ("sidebar / bookmarks", ["Sidebar", "Bookmark", "ReadingList", "TabGroup"]),
        ("window / tabs", ["BrowserWindow", "BrowserTab", "TabBar", "TabView", "WindowController"]),
        ("address bar", ["UnifiedField", "AddressBar", "LocationField", "SearchField", "Toolbar"]),
        ("history", ["History"]),
        ("passwords / autofill", ["Password", "AutoFill", "Credential"]),
    ]
    for (title, needles) in groups {
        let matches = classes.filter { entry in needles.contains { entry.name.contains($0) } }
        print("\n-- \(title) (\(matches.count))")
        for entry in matches.prefix(25) { print("   \(entry.name) : \(entry.superclass)   [\(entry.image)]") }
        if matches.count > 25 { print("   … \(matches.count - 25) more (--all)") }
    }
    print("\n(--all for the full list)")
}

// MARK: Nibs

print("\n== nibs ==")
let resourceRoots = ["/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Resources/Base.lproj",
                     "/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Resources/Base.lproj"]
if let root = resourceRoots.first(where: { FileManager.default.fileExists(atPath: $0) }),
   let names = try? FileManager.default.contentsOfDirectory(atPath: root) {
    let nibs = names.filter { $0.hasSuffix(".nib") }.sorted()
    print("\(nibs.count) nibs in \(root)")
    for name in nibs.filter({ $0.contains("StartPage") || $0.contains("Sidebar") || $0.contains("Bookmark") }).prefix(20) {
        print("   \(name)")
    }
} else {
    print("Safari.framework resources not readable at either path")
}

// MARK: Instantiate one class

// Safari's own window factory calls -[NSApp isRestoringWindows], which plain NSApplication does
// not have: the selector belongs to Safari's own NSApplication subclass. So the process's NSApp
// has to be that class, which is what --safari-app does, before anything else touches NSApp.
if flag("--safari-app") {
    print("\n== safari application ==")
    var candidates: [String] = []
    for entry in classes {
        guard let cls = NSClassFromString(entry.name) else { continue }
        var walk: AnyClass? = class_getSuperclass(cls)
        while let current = walk {
            if current == NSApplication.self { candidates.append(entry.name); break }
            walk = class_getSuperclass(current)
        }
    }
    print("NSApplication subclasses in the Safari frameworks: \(candidates.isEmpty ? ["(none)"] : candidates)")
    let requested = value(after: "--safari-app").flatMap { $0.hasPrefix("--") ? nil : $0 }
    if let name = requested ?? candidates.first, let cls: AnyObject = NSClassFromString(name) {
        print("calling +[\(name) sharedApplication]…")
        let app = cls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue()
        print("NSApp is now \(app.map { String(describing: type(of: $0)) } ?? "nil")")
        print("responds to isRestoringWindows: \((app as? NSObject)?.responds(to: NSSelectorFromString("isRestoringWindows")) ?? false)")
    }
}

/// Our own content, to be put inside a tab of Safari's window.
final class HostedWebViewController: NSViewController {
    let webView = WKWebView()
    override func loadView() {
        view = webView
        webView.load(URLRequest(url: URL(string: "https://example.com")!))
    }
}
var hostedContent: NSViewController?

if flag("--prepare") {
    // Safari's BrowserWindowController aborts in -windowDidLoad unless the shared search engine
    // observer exists: "ASSERTION FAILURE: sharedSearchEngineObserver in
    // +[WBSSearchEnginePreferenceObserver sharedObserver], WBSSearchEnginePreferenceObserver.m:52".
    // The frame below it in the trace names the setup method, so call that first. (The competitor's
    // per-profile process carries BB_SEARCH_ENGINE=google, i.e. it configures the same thing.)
    print("\n== prepare ==")
    let candidates = classes.map(\.name).filter { $0.contains("SearchProviderContext") || $0.contains("SearchProviderSetup") }
    print("context candidates: \(candidates.isEmpty ? ["(none)"] : candidates)")
    var context: NSObject?
    for name in candidates {
        guard let type = NSClassFromString(name) as? NSObject.Type else { continue }
        print("building \(name)…")
        context = type.init()
        print("built: \(context.map { String(describing: $0) } ?? "nil")")
        break
    }
    if let observer = NSClassFromString("WBSSearchEnginePreferenceObserver") {
        let selector = NSSelectorFromString("setUpSharedObserverWithSearchProviderContext:")
        if (observer as AnyObject).responds(to: selector) {
            print("calling setUpSharedObserverWithSearchProviderContext: \(context == nil ? "nil" : "context")…")
            _ = (observer as AnyObject).perform(selector, with: context)
            print("called; sharedObserver = \(String(describing: (observer as AnyObject).perform(NSSelectorFromString("sharedObserver"))?.takeUnretainedValue()))")
        } else {
            print("WBSSearchEnginePreferenceObserver has no setUpSharedObserverWithSearchProviderContext:")
        }
    } else {
        print("WBSSearchEnginePreferenceObserver not found")
    }
}

if flag("--tolerate-nil-attributes") {
    // Safari's chrome reads its colours from the com.apple.Safari preferences domain, which in a
    // foreign process resolves to Safari's own container and is refused ("accessing these
    // preferences requires user-preference-read"), so every such colour arrives nil and the first
    // -addAttribute:value:range: with it takes the window down. Patching each site one by one is
    // whack-a-mole; skipping nil values once covers the whole class, which is what a hosted
    // chrome needs until the preferences are supplied properly (CFFIXED_USER_HOME plus a seeded
    // com.apple.Safari.plist).
    print("\n== tolerate nil attributes ==")
    typealias AddAttribute = @convention(c) (AnyObject, Selector, NSString, AnyObject?, NSRange) -> Void
    let selector = NSSelectorFromString("addAttribute:value:range:")
    var patched = 0
    for className in ["NSConcreteMutableAttributedString", "NSMutableAttributedString"] {
        guard let cls = NSClassFromString(className),
              let method = class_getInstanceMethod(cls, selector) else { continue }
        let original = unsafeBitCast(method_getImplementation(method), to: AddAttribute.self)
        let replacement: @convention(block) (AnyObject, NSString, AnyObject?, NSRange) -> Void = { object, name, value, range in
            guard let value else { return }
            original(object, selector, name, value, range)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        patched += 1
        print("patched -[\(className) addAttribute:value:range:]")
    }
    if patched == 0 { print("no attributed-string class to patch") }
}

// --stub <kind>/<Class>/<selector> replaces one object-returning method with a harmless value,
// repeatable. Each round of hosting Safari's chrome names another method that assumes it is
// inside Safari; this turns answering that into another argument rather than another build. On
// arm64 a block that only returns a value can stand in for a method of any arity, as long as the
// method returns an object: the arguments stay untouched in their registers.
// Kinds: image, string, attributed, array, nil.
let stubs: [String] = arguments.indices.compactMap { index in
    guard arguments[index] == "--stub", arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
if !stubs.isEmpty {
    print("\n== stubs ==")
    for spec in stubs {
        let parts = spec.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, let cls = NSClassFromString(parts[1]),
              let method = class_getInstanceMethod(cls, NSSelectorFromString(parts[2])) else {
            print("could not stub \(spec)")
            continue
        }
        let kind = parts[0]
        let replacement: @convention(block) (AnyObject) -> AnyObject? = { _ in
            switch kind {
            case "image": return NSImage(size: NSSize(width: 1, height: 1))
            case "string": return "" as NSString
            case "attributed": return NSAttributedString(string: "")
            case "array": return [] as NSArray
            default: return nil
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        print("stubbed -[\(parts[1]) \(parts[2])] -> \(kind)")
    }
}

if flag("--bridge-images") {
    // Safari's chrome asks for its icons by name from the *main* bundle, and in a foreign process
    // that is the probe's own executable — CoreUI says so above the crash ("unable to find a
    // bundle 'NSBundle </tmp> (loaded)' with identifier '(null)'"). So every icon comes back nil
    // and the first array built from one throws. Fall back to the private frameworks' own
    // bundles, which carry Safari's asset catalogs.
    print("\n== bridge images ==")
    let bundles = ["/System/Library/PrivateFrameworks/Safari.framework",
                   "/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks/Safari.framework",
                   "/System/Library/PrivateFrameworks/SafariShared.framework",
                   "/System/Library/PrivateFrameworks/SafariFoundation.framework",
                   "/System/Library/PrivateFrameworks/PasswordManagerUI.framework"].compactMap(Bundle.init(path:))
    print("fallback bundles: \(bundles.count)")
    typealias ImageNamed = @convention(c) (AnyObject, Selector, NSString) -> NSImage?
    let selector = NSSelectorFromString("imageNamed:")
    if let method = class_getClassMethod(NSImage.self, selector) {
        let original = unsafeBitCast(method_getImplementation(method), to: ImageNamed.self)
        let replacement: @convention(block) (AnyObject, NSString) -> NSImage? = { cls, name in
            if let image = original(cls, selector, name) { return image }
            for bundle in bundles {
                if let image = bundle.image(forResource: name as String) { return image }
            }
            // A chrome icon Safari draws from SF Symbols, when its catalogs have no such name.
            return NSImage(systemSymbolName: name as String, accessibilityDescription: nil)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        print("patched +[NSImage imageNamed:]")
    } else {
        print("+[NSImage imageNamed:] not found")
    }
}

if flag("--patch-unified-field") {
    // -[UnifiedField _notSecureAnnotation] builds an attributed string for the address bar's
    // "Not Secure" badge and passes a nil attribute value when Safari's own environment is not
    // there, which AppKit's layout turns into a crash. Replacing that one method is the same
    // move the competitor makes with its SafariZoomFix.dylib: patch the few methods of Safari's
    // chrome that assume they are inside Safari.
    print("\n== patch ==")
    if let cls = NSClassFromString("UnifiedField"),
       let method = class_getInstanceMethod(cls, NSSelectorFromString("_notSecureAnnotation")) {
        let replacement: @convention(block) (AnyObject) -> AnyObject = { _ in NSAttributedString(string: "") }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        print("patched -[UnifiedField _notSecureAnnotation]")
    } else {
        print("UnifiedField or its _notSecureAnnotation not found")
    }
}

// --open-window uses Safari's own factory instead of creating the controller by hand, which is how
// Safari opens a window itself. With --inject-web it then hands one of that window's tabs a view
// controller of ours holding a WKWebView (-[BrowserTabViewItem setTabContentViewController:]) and
// sets the address bar's text, which is the seam a hosted chrome would be built on.
if flag("--open-window") {
    print("\n== open window ==")
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    guard let windowClass: AnyObject = NSClassFromString("BrowserWindowController") else {
        print("BrowserWindowController not found")
        exit(1)
    }
    print("calling +openEmptyBrowserWindowController…")
    let opened = windowClass.perform(NSSelectorFromString("openEmptyBrowserWindowController"))?.takeUnretainedValue()
    print("opened: \(String(describing: opened))")
    if let controller = opened as? NSWindowController, let window = controller.window {
        print("window: \(window.frame) title=\(window.title)")
        print("contentViewController: \(String(describing: window.contentViewController))")
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }

    if flag("--inject-web") {
        print("\n-- inject")
        let items = (windowClass.perform(NSSelectorFromString("allBrowserTabViewItemsFromAllWindows"))?
            .takeUnretainedValue()) as? [AnyObject] ?? []
        print("tabs in all windows: \(items.count)")
        if let tab = items.first as? NSObject {
            print("tab: \(tab)")
            let hosted = HostedWebViewController()
            hostedContent = hosted
            let setContent = NSSelectorFromString("setTabContentViewController:")
            print("responds to setTabContentViewController: \(tab.responds(to: setContent))")
            if tab.responds(to: setContent) {
                _ = tab.perform(setContent, with: hosted)
                print("handed the tab our view controller")
            }
            let setURLString = NSSelectorFromString("setURLString:")
            if tab.responds(to: setURLString) {
                _ = tab.perform(setURLString, with: "https://example.com" as NSString)
                print("set the address bar text")
            }
        } else {
            print("the window reported no tab to inject into")
        }
    }

    print("showing for 20 s…")
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    print("still alive after 20 s")
    exit(0)
}

if let className = value(after: "--try-init") {
    print("\n== \(className) ==")
    guard let cls = NSClassFromString(className) else {
        print("no such class after loading the frameworks")
        exit(1)
    }
    var chain: [String] = []
    var walk: AnyClass? = cls
    while let current = walk {
        chain.append(String(cString: class_getName(current)))
        walk = class_getSuperclass(current)
    }
    print("chain: \(chain.joined(separator: " < "))")
    guard let objectType = cls as? NSObject.Type else {
        print("not an NSObject subclass; cannot be created this way")
        exit(1)
    }

    // NSApplication must exist before anything builds a window or reads a nib.
    let application = NSApplication.shared
    application.setActivationPolicy(flag("--show-window") ? .regular : .accessory)

    print("init…")
    let object = objectType.init()
    print("init ok: \(object)")

    if flag("--load-view"), let controller = object as? NSViewController {
        print("nibName: \(controller.nibName ?? "-")")
        print("loading view… (this is where the nib is read)")
        let view = controller.view
        print("view ok: \(String(describing: Swift.type(of: view))) \(view.frame)")
    }

    if let controller = object as? NSWindowController {
        print("windowNibName: \(controller.windowNibName ?? "-")")
        print("reading .window… (this is where the window nib is read)")
        if let window = controller.window {
            print("window ok: \(String(describing: Swift.type(of: window))) \(window.frame) title=\(window.title)")
            print("contentViewController: \(String(describing: window.contentViewController))")
            if flag("--show-window") {
                print("showing it for 10 s…")
                controller.showWindow(nil)
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                RunLoop.main.run(until: Date().addingTimeInterval(10))
                print("still alive after 10 s")
            }
        } else {
            print("window is nil")
        }
    }
}
