import AppKit
import Foundation
import MachO
import ObjCExceptions

/// MEASUREMENT BRANCH ONLY (claude/measure-banner). What Safari's app-banner tracker does in a
/// profile's own process, printed on standard error as `BANNER-MEASURE` lines, by
/// `PB_MEASURE_BANNER`:
///   * "watch": as a user's profile had it — no fix; who calls the tracker's `-load`, what the
///     tracker holds then, every file URL asked for with no path (passed on: it throws, as it did);
///   * "nil": the same, but a file URL with no path is answered with nil, so that the run goes on
///     and shows what the tracker does next;
///   * "fix": with the candidate fix (`SafariChrome.closeAppBannerTrackers`), watched the same way.
/// And the classes of Safari's images named for banners or app links, with their instance
/// variables and methods; and Safari's path getters that answered nil or "".
@MainActor
enum BannerMeasure {
    nonisolated static func say(_ line: String) {
        FileHandle.standardError.write(Data(("BANNER-MEASURE [\(getpid())] " + line + "\n").utf8))
    }

    private static var mode = ""
    private static var imagesSeen: UInt32 = 0
    private static var hooked: Set<String> = []
    private static var dumped: Set<String> = []
    private static var gettersWatched = false

    static func install() {
        guard let mode = ProcessInfo.processInfo.environment["PB_MEASURE_BANNER"], !mode.isEmpty else { return }
        Self.mode = mode
        say("mode \(mode)")
        watchFileURLs(answeringNil: mode == "nil")
        watchApplicationListings()
        ExceptionLog.onThrown = { name, reason, frames in
            say("thrown on \(threadName()): \(name): \(reason) | from: \(frames.prefix(12).map(short).joined(separator: " | "))")
        }
        ExceptionLog.onNotCaught = { name, thread in say("NOT CAUGHT, on \(thread): \(name) — the process ends") }
        _dyld_register_func_for_add_image { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { BannerMeasure.scanImages() } }
        }
        scanImages()
        // What is there once Safari's window is up and its first page has been asked for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                scanImages()
                say("after 4 s: tracker classes hooked \(hooked.sorted()); stubs reached \(SafariStubCount.snapshot)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
            MainActor.assumeIsolated { askTrackerDirectly() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            MainActor.assumeIsolated {
                scanImages()
                say("after 14 s: stubs reached \(SafariStubCount.snapshot); still running")
                var images: [String] = []
                for index in 0..<_dyld_image_count() {
                    guard let image = _dyld_get_image_name(index) else { continue }
                    let path = String(cString: image)
                    if path.range(of: "Safari", options: .caseInsensitive) != nil || path.contains("WebBookmarks")
                        || path.contains("BrowserKit") || path.contains("AppleMediaServices") || path.contains("StoreKit")
                        || path.contains("CloudKit") || path.contains("Intelligence") || path.contains("Siri") {
                        images.append((path as NSString).lastPathComponent)
                    }
                }
                say("loaded images of note (\(images.count)): \(images.sorted().joined(separator: ", "))")
            }
        }
    }

    /// After `SafariPaths.redirectGetters`: Safari's path getters, each said once when it answers
    /// nil or "".
    static func watchGetters() {
        guard !mode.isEmpty, !gettersWatched else { return }
        gettersWatched = true
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        var count = 0
        for entry in SafariPaths.redirected {
            // "-[Class selector]" or "+[Class selector]"
            let isClassMethod = entry.hasPrefix("+")
            let body = entry.dropFirst(2).dropLast()
            let parts = body.split(separator: " ")
            guard parts.count == 2, let cls = NSClassFromString(String(parts[0])) else { continue }
            let selector = NSSelectorFromString(String(parts[1]))
            let owner: AnyClass? = isClassMethod ? object_getClass(cls) : cls
            guard let owner, let method = class_getInstanceMethod(owner, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let lock = NSLock()
            var said = false
            let replacement: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { receiver in
                let result = original(receiver, selector)
                let value = result?.takeUnretainedValue()
                let empty: Bool
                if value == nil {
                    empty = true
                } else if let string = value as? NSString {
                    empty = string.length == 0
                } else if let url = value as? NSURL {
                    empty = (url.path ?? "").isEmpty
                } else {
                    empty = false
                }
                if empty {
                    let first = lock.withLock { () -> Bool in
                        defer { said = true }
                        return !said
                    }
                    if first {
                        say("getter \(entry) answered \(value == nil ? "nil" : "\"\"") on \(threadName()), from: \(callers(8))")
                    }
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            count += 1
        }
        say("watching \(count) of Safari's path getters for nil or empty answers")
    }

    // MARK: The app-link banner's chain

    private static var chainWatched: Set<String> = []

    /// Safari's app-link banner, from the link to the tracker: each step said with who called it.
    private static func watchChain(of cls: AnyClass, name: String) {
        let steps: [(String, String, Bool)] = [
            ("WBSAppLink", "decideOpenStrategyWithCompletionHandler:", false),
            ("WBSAppLink", "getAppLinkAttributesWithCompletionHandler:", false),
            // (-_getAppLinkForBanner:withCompletionHandler: takes a BOOL first: not watched here, where
            // every argument is taken as an object.)
            ("AppLinkBannerController", "getBannerWithCompletionHandler:", false),
            ("WBSBannerTracker", "isBannerBlockedForIdentifier:completion:", false),
            ("WBSBannerTracker", "blockBannerForIdentifier:", false),
            ("WBSBannerTracker", "_saveOnInteralQueue", false),
            ("WBSBannerTracker", "sharedTracker", true),
            ("WBSAppLinkBannerTracker", "sharedTracker", true),
        ]
        for (owner, selectorName, isClassMethod) in steps where owner == name {
            let key = "\(isClassMethod ? "+" : "-")[\(owner) \(selectorName)]"
            guard !chainWatched.contains(key) else { continue }
            chainWatched.insert(key)
            let selector = NSSelectorFromString(selectorName)
            guard let target: AnyClass = isClassMethod ? object_getClass(cls) : cls,
                  let method = class_getInstanceMethod(target, selector) else {
                say("no \(key)")
                continue
            }
            let arguments = selectorName.filter { $0 == ":" }.count
            let implementation = method_getImplementation(method)
            switch arguments {
            case 0:
                typealias Call = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
                let original = unsafeBitCast(implementation, to: Call.self)
                let block: @convention(block) (AnyObject) -> Unmanaged<AnyObject>? = { receiver in
                    say("\(key) on \(threadName()), from: \(callers(10))")
                    return original(receiver, selector)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            case 1:
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                let original = unsafeBitCast(implementation, to: Call.self)
                let block: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, first in
                    say("\(key) for \(describeLink(receiver)) on \(threadName()), from: \(callers(10))")
                    original(receiver, selector, first)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            default:
                typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
                let original = unsafeBitCast(implementation, to: Call.self)
                let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { receiver, first, second in
                    say("\(key) (\(first.map { String(describing: $0).prefix(120) } ?? "nil")) for \(describeLink(receiver)) on \(threadName()), from: \(callers(10))")
                    original(receiver, selector, first, second)
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
            }
            say("watching \(key)")
        }
    }

    /// A WBSAppLink's URL, or what the receiver is.
    nonisolated private static func describeLink(_ receiver: AnyObject) -> String {
        if NSStringFromClass(type(of: receiver)) == "WBSAppLink", receiver.responds(to: NSSelectorFromString("url")),
           let url = receiver.perform(NSSelectorFromString("url"))?.takeUnretainedValue() as? URL {
            return "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)"
        }
        return NSStringFromClass(type(of: receiver))
    }

    /// After the pages: Safari's app-link tracker asked directly, as its banner asks it
    /// (-isBannerBlockedForIdentifier:completion:), with what it answers on the way; and how
    /// Safari tells a web app of a site (the keys it reads from a bundle's Info dictionary, and the
    /// folders it looks in).
    static func askTrackerDirectly() {
        guard !mode.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            MainActor.assumeIsolated {
                if let exception = PBCatchException({ probeWebAppLookup() }) {
                    say("web app: the probe threw \(exception.name.rawValue): \(exception.reason ?? "")")
                }
            }
        }
        guard let cls: AnyObject = NSClassFromString("WBSAppLinkBannerTracker") else {
            say("direct: no WBSAppLinkBannerTracker in this process")
            return
        }
        say("direct: +[WBSAppLinkBannerTracker sharedTracker] (mode \(mode))")
        guard let tracker = cls.perform(NSSelectorFromString("sharedTracker"))?.takeUnretainedValue() else {
            say("direct: sharedTracker is nil")
            return
        }
        for getter in ["categoryName", "_filePath"] where tracker.responds(to: NSSelectorFromString(getter)) {
            let value = tracker.perform(NSSelectorFromString(getter))?.takeUnretainedValue()
            say("direct: -\(getter) -> \(value.map { "\"\($0)\" (\(NSStringFromClass(type(of: $0))))" } ?? "nil")")
        }
        typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int
        let basis = NSSelectorFromString("basis")
        if let method = class_getInstanceMethod(type(of: tracker), basis) {
            let call = unsafeBitCast(method_getImplementation(method), to: IntegerGetter.self)
            say("direct: -basis -> \(call(tracker, basis))")
        }
        say("direct: the tracker holds: \(holdings(of: tracker))")
        // As the banner asks it: is the banner for this identifier blocked?
        typealias Ask = @convention(c) (AnyObject, Selector, NSString, Any?) -> Void
        let askSelector = NSSelectorFromString("isBannerBlockedForIdentifier:completion:")
        if let method = class_getInstanceMethod(type(of: tracker), askSelector) {
            let ask = unsafeBitCast(method_getImplementation(method), to: Ask.self)
            let completion: @convention(block) (Bool) -> Void = { blocked in
                say("direct: the tracker answered blocked=\(blocked) on \(threadName())")
            }
            say("direct: -isBannerBlockedForIdentifier:completion: (\"selftest.invalid\")")
            ask(tracker, askSelector, "selftest.invalid" as NSString, completion)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            say("direct: 5 s later, still running; stubs reached \(SafariStubCount.snapshot)")
        }
    }

    /// The keys Safari reads from a web app's Info dictionary to find its scope: a dictionary that
    /// says which keys it was asked for, and answers each with another such dictionary, handed to
    /// -[WBSAppLink _scopeURLFromInfoDictionary:] on a bare instance (no initializer run).
    private static func probeWebAppLookup() {
        guard let linkClass = NSClassFromString("WBSAppLink"), let created = class_createInstance(linkClass, 0) else { return }
        let bare = created as AnyObject
        let scopeSelector = NSSelectorFromString("_scopeURLFromInfoDictionary:")
        guard bare.responds(to: scopeSelector) else { return }
        let spy = KeySpy(path: "Info")
        let answer = bare.perform(scopeSelector, with: spy)?.takeUnretainedValue()
        say("web app: -_scopeURLFromInfoDictionary: read \(KeySpy.asked) and answered \(answer.map { String(describing: $0) } ?? "nil")")
    }

    /// Folders listed by anyone in this process whose path names applications or web apps, with
    /// who listed them: where Safari looks for a web app of a site.
    nonisolated private static func watchApplicationListings() {
        typealias ListPath = @convention(c) (AnyObject, Selector, NSString?, UnsafeMutableRawPointer?) -> AnyObject?
        typealias ListURL = @convention(c) (AnyObject, Selector, NSURL?, AnyObject?, UInt, UnsafeMutableRawPointer?) -> AnyObject?
        func interesting(_ path: String?) -> Bool {
            guard let path else { return false }
            return path.range(of: "Application", options: .caseInsensitive) != nil || path.range(of: "WebApp", options: .caseInsensitive) != nil
                || path.range(of: "Web App", options: .caseInsensitive) != nil
        }
        let byPath = NSSelectorFromString("contentsOfDirectoryAtPath:error:")
        if let method = class_getInstanceMethod(FileManager.self, byPath) {
            let original = unsafeBitCast(method_getImplementation(method), to: ListPath.self)
            let block: @convention(block) (AnyObject, NSString?, UnsafeMutableRawPointer?) -> AnyObject? = { manager, path, error in
                if interesting(path as String?) { say("listing \(path ?? "nil") on \(threadName()), from: \(callers(8))") }
                return original(manager, byPath, path, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        let byURL = NSSelectorFromString("contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:")
        if let method = class_getInstanceMethod(FileManager.self, byURL) {
            let original = unsafeBitCast(method_getImplementation(method), to: ListURL.self)
            let block: @convention(block) (AnyObject, NSURL?, AnyObject?, UInt, UnsafeMutableRawPointer?) -> AnyObject? = { manager, url, keys, options, error in
                if interesting(url?.path) { say("listing \(url?.path ?? "nil") on \(threadName()), from: \(callers(8))") }
                return original(manager, byURL, url, keys, options, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    nonisolated(unsafe) static var listingsSaid = false

    // MARK: Classes

    /// Classes of Safari's images loaded since the last look: those named for banners or app
    /// links described, the trackers' `-load` watched.
    private static func scanImages() {
        let total = _dyld_image_count()
        guard total > imagesSeen else { return }
        for index in imagesSeen..<total {
            guard let image = _dyld_get_image_name(index) else { continue }
            let path = String(cString: image)
            guard path.range(of: "/Safari", options: .caseInsensitive) != nil
                    || path.range(of: "WebBookmarks", options: .caseInsensitive) != nil else { continue }
            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(image, &count) else { continue }
            defer { free(names) }
            for position in 0..<Int(count) {
                let name = String(cString: names[position])
                guard name.contains("Banner") || name.contains("AppLink") || name.contains("ItunesApp")
                        || name.contains("ITunesApp") || name.contains("SmartApp") else { continue }
                guard let cls = objc_lookUpClass(names[position]) else { continue }
                describe(cls, name: name, image: (path as NSString).lastPathComponent)
                if name.contains("Tracker") { watchLoad(of: cls, name: name) }
                watchChain(of: cls, name: name)
            }
        }
        imagesSeen = total
    }

    private static func describe(_ cls: AnyClass, name: String, image: String) {
        guard !dumped.contains(name) else { return }
        dumped.insert(name)
        let superName = class_getSuperclass(cls).map { NSStringFromClass($0) } ?? "nil"
        say("class \(name) : \(superName) (\(image))")
        var ivarCount: UInt32 = 0
        if let ivars = class_copyIvarList(cls, &ivarCount) {
            let list = (0..<Int(ivarCount)).map { index -> String in
                let ivar = ivars[index]
                return "\(ivar_getName(ivar).map { String(cString: $0) } ?? "?") \(ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?")"
            }
            free(ivars)
            say("  ivars of \(name): \(list.joined(separator: ", "))")
        }
        for (kind, owner) in [("-", Optional(cls)), ("+", object_getClass(cls))] {
            guard let owner else { continue }
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(owner, &methodCount) else { continue }
            let list = (0..<Int(methodCount)).map { index -> String in
                let method = methods[index]
                let types = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
                return "\(kind)\(NSStringFromSelector(method_getName(method))) \(types)"
            }
            free(methods)
            // In pieces: a long line is cut by the log.
            for start in stride(from: 0, to: list.count, by: 25) {
                say("  methods of \(name) \(kind) [\(start)…]: \(list[start..<min(start + 25, list.count)].joined(separator: " | "))")
            }
        }
    }

    /// `-load` of a tracker class that has one of its own: who called it, what the tracker holds,
    /// then on to the implementation it replaced (Safari's own, or the fix).
    private static func watchLoad(of cls: AnyClass, name: String) {
        guard !hooked.contains(name) else { return }
        hooked.insert(name)
        let selector = NSSelectorFromString("load")
        var count: UInt32 = 0
        var own = false
        if let methods = class_copyMethodList(cls, &count) {
            own = (0..<Int(count)).contains { method_getName(methods[$0]) == selector }
            free(methods)
        }
        guard own, let method = class_getInstanceMethod(cls, selector) else {
            say("\(name) has no -load of its own")
            return
        }
        typealias Load = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Load.self)
        var info = Dl_info()
        let implementation = dladdr(unsafeBitCast(method_getImplementation(method), to: UnsafeRawPointer.self), &info) != 0
            ? info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?" : "?"
        say("watching -[\(name) load] (its implementation now in \(implementation))")
        let replacement: @convention(block) (AnyObject) -> Void = { tracker in
            say("-[\(NSStringFromClass(type(of: tracker))) load] (of \(name)) called on \(threadName()), from: \(callers(12))")
            say("  the tracker holds: \(holdings(of: tracker))")
            original(tracker, selector)
            say("  -[\(name) load] returned; stubs reached \(SafariStubCount.snapshot)")
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The object instance variables of `object`, up its classes to NSObject, with what each holds.
    nonisolated private static func holdings(of object: AnyObject) -> String {
        var parts: [String] = []
        var current: AnyClass? = type(of: object)
        while let cls = current, cls != NSObject.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(cls, &count) {
                for index in 0..<Int(count) {
                    let ivar = ivars[index]
                    let name = ivar_getName(ivar).map { String(cString: $0) } ?? "?"
                    let encoding = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?"
                    guard encoding.hasPrefix("@"), encoding != "@?" else {
                        parts.append("\(name) (\(encoding))")
                        continue
                    }
                    let value = object_getIvar(object, ivar)
                    let shown = value.map { "\(String(describing: Swift.type(of: $0 as AnyObject))): \(String(describing: $0).prefix(240))" } ?? "nil"
                    parts.append("\(name) = \(shown)")
                }
                free(ivars)
            }
            current = class_getSuperclass(cls)
        }
        return parts.joined(separator: "; ")
    }

    // MARK: File URLs

    nonisolated private static func watchFileURLs(answeringNil: Bool) {
        typealias WithFlag = @convention(c) (AnyObject, Selector, NSString?, Bool) -> AnyObject?
        typealias Plain = @convention(c) (AnyObject, Selector, NSString?) -> AnyObject?
        let flagged = NSSelectorFromString("initFileURLWithPath:isDirectory:")
        if let method = class_getInstanceMethod(NSURL.self, flagged) {
            let original = unsafeBitCast(method_getImplementation(method), to: WithFlag.self)
            let replacement: @convention(block) (AnyObject, NSString?, Bool) -> AnyObject? = { url, path, isDirectory in
                if path == nil || path?.length == 0 {
                    say("-[NSURL initFileURLWithPath:isDirectory:] given \(path == nil ? "nil" : "\"\"") on \(threadName()), from: \(callers(12))"
                        + (answeringNil ? " — answered nil" : " — passed on"))
                    if answeringNil { return nil }
                }
                return original(url, flagged, path, isDirectory)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let plain = NSSelectorFromString("initFileURLWithPath:")
        if let method = class_getInstanceMethod(NSURL.self, plain) {
            let original = unsafeBitCast(method_getImplementation(method), to: Plain.self)
            let replacement: @convention(block) (AnyObject, NSString?) -> AnyObject? = { url, path in
                if path == nil || path?.length == 0 {
                    say("-[NSURL initFileURLWithPath:] given \(path == nil ? "nil" : "\"\"") on \(threadName()), from: \(callers(12))"
                        + (answeringNil ? " — answered nil" : " — passed on"))
                    if answeringNil { return nil }
                }
                return original(url, plain, path)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    // MARK: Frames

    nonisolated private static func threadName() -> String {
        if let name = Thread.current.name, !name.isEmpty { return name }
        let label = String(cString: __dispatch_queue_get_label(nil))
        return label.isEmpty ? "an unnamed thread" : label
    }

    /// The frames below the caller, image and symbol only.
    nonisolated private static func callers(_ count: Int) -> String {
        Thread.callStackSymbols.dropFirst(2).prefix(count).map(short).joined(separator: " | ")
    }

    nonisolated private static func short(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().filter { !$0.hasPrefix("0x") }.joined(separator: " ")
    }
}

/// MEASUREMENT BRANCH ONLY. A dictionary that says which keys it was asked for, by path, and
/// answers each with another such dictionary.
final class KeySpy: NSDictionary {
    nonisolated(unsafe) static var asked: [String] = []
    private var path = ""

    init(path: String) {
        self.path = path
        super.init()
    }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var count: Int { 0 }
    override func object(forKey key: Any) -> Any? {
        let name = "\(path).\(key)"
        KeySpy.asked.append(name)
        return KeySpy(path: name)
    }
    override func keyEnumerator() -> NSEnumerator { NSArray().objectEnumerator() }
    override func value(forKey key: String) -> Any? { object(forKey: key) }
}
