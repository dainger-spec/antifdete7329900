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
// --try-init is a separate run on purpose: a controller that needs Safari's own singletons can
// abort the process, and that must not take the class listing down with it.

import AppKit
import Foundation
import ObjectiveC.runtime

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
