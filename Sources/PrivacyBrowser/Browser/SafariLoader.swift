import Foundation
import MachO
import ObjectiveC

/// Opens the system browser framework at runtime and reads what the Objective-C runtime then
/// knows about it. Nothing here is linked at build time: the framework is opened only when the
/// framework window path is asked for, and every step reports what it found instead of trapping.
///
/// The framework ships inside a cryptex since macOS 13, so the path under `/System/Library` is
/// only what older systems had. dyld also resolves framework paths out of the shared cache when
/// no file is on disk, so a path that does not `stat` is still worth a `dlopen`.
enum SafariLoader {
    /// Tried in order; the first that opens wins.
    static let candidatePaths = [
        "/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
        "/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
        "/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari",
        "/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework/Safari",
        "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
        "/System/Library/PrivateFrameworks/Safari.framework/Safari",
    ]

    /// What the framework's bundle holds on disk. The binary lives in the dyld shared cache and
    /// is not a file, but a bundle's resources — the strings its interface is built from — are
    /// ordinary files, and whether they are there decides whether its views can draw.
    static func bundleContents() -> [String] {
        let root = "/System/Library/PrivateFrameworks/Safari.framework"
        var lines: [String] = []
        for relative in ["", "/Versions/A", "/Versions/A/Resources", "/Resources"] {
            let path = root + relative
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                lines.append("\(path): unreadable or absent")
                continue
            }
            let lproj = entries.filter { $0.hasSuffix(".lproj") }
            lines.append("\(path): \(entries.count) entries" +
                         (lproj.isEmpty ? "" : ", \(lproj.count) .lproj (\(lproj.prefix(4).joined(separator: ", ")))") +
                         "; \(entries.prefix(10).sorted().joined(separator: ", "))")
        }
        let bundle = Bundle(path: root)
        lines.append("Bundle(path:) -> \(bundle == nil ? "nil" : "loaded=\(bundle!.isLoaded), identifier=\(bundle!.bundleIdentifier ?? "nil")")")
        return lines
    }

    /// Where to look when none of the candidates opened: the private-framework directories, and
    /// what in them is named after the framework. A path that is in the dyld shared cache and
    /// not on disk will not show up here, which is itself worth knowing.
    static func searchForFramework() -> [String] {
        let parents = [
            "/System/Library/PrivateFrameworks",
            "/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks",
            "/System/Cryptexes/App/System/Library/PrivateFrameworks",
            "/System/Volumes/Preboot/Cryptexes/App/System/Library/Frameworks",
        ]
        var found: [String] = []
        for parent in parents {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) else {
                found.append("\(parent): unreadable")
                continue
            }
            let matches = entries.filter { $0.range(of: "safari", options: .caseInsensitive) != nil }.sorted()
            found.append("\(parent): \(entries.count) entries, matching the name: \(matches.isEmpty ? "none" : matches.joined(separator: ", "))")
        }
        return found
    }

    private static var handle: UnsafeMutableRawPointer?
    /// The candidate that opened, and the `dlerror()` of each that did not.
    private(set) static var openedPath: String?
    private(set) static var openFailures: [(path: String, onDisk: Bool, error: String)] = []

    @discardableResult
    static func load() -> Bool {
        if handle != nil { return true }
        openFailures = []
        for path in candidatePaths {
            let onDisk = FileManager.default.fileExists(atPath: path)
            // Clear any error left by an earlier call so dlerror() below is this call's.
            _ = dlerror()
            if let opened = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                handle = opened
                openedPath = path
                NSLog("SafariLoader: opened \(path)\(onDisk ? "" : " (not on disk: resolved from the shared cache)")")
                return true
            }
            let message = dlerror().map { String(cString: $0) } ?? "no dlerror"
            openFailures.append((path, onDisk, message))
            NSLog("SafariLoader: \(path) -> nil (on disk: \(onDisk), dlerror: \(message))")
        }
        NSLog("SafariLoader: no candidate path opened")
        return false
    }

    /// The loaded image's path as dyld reports it — what `objc_copyClassNamesForImage` needs.
    /// nil when the framework is not loaded, which is also the answer when `dlopen` succeeded
    /// but dyld mapped nothing under that name.
    static var loadedImageName: String? {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.contains("Safari.framework") { return path }
        }
        return nil
    }

    // MARK: Runtime scanning

    /// Every Objective-C class the framework's image contributes, in runtime order.
    static func classNames() -> [String] {
        guard let image = loadedImageName else {
            NSLog("SafariLoader: classNames -> nil (framework image not in the loaded image list)")
            return []
        }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else {
            NSLog("SafariLoader: objc_copyClassNamesForImage(\(image)) -> nil")
            return []
        }
        defer { free(UnsafeMutableRawPointer(names)) }
        return (0..<Int(count)).map { String(cString: names[$0]) }
    }

    /// Classes of the framework whose name contains `fragment` (case-insensitive).
    static func classNames(containing fragment: String) -> [String] {
        classNames().filter { $0.range(of: fragment, options: .caseInsensitive) != nil }
    }

    /// Framework classes that implement `selector` themselves (instance or class side), with
    /// which side it was found on. Used to locate the window-creation entry points without
    /// guessing which class owns them.
    static func classesImplementing(_ selector: String) -> [(className: String, isClassMethod: Bool)] {
        var found: [(String, Bool)] = []
        for name in classNames() {
            guard let cls = objc_getClass(name) as? AnyClass else { continue }
            if ObjCRuntime.declaredSelectors(of: cls).contains(selector) { found.append((name, false)) }
            if let meta = object_getClass(cls), ObjCRuntime.declaredSelectors(of: meta).contains(selector) {
                found.append((name, true))
            }
        }
        return found.map { (className: $0.0, isClassMethod: $0.1) }
    }

    /// Framework classes with at least one declared selector matching every fragment of
    /// `fragments` (case-insensitive), as `(class, [selector])`. The window-creation path is
    /// recovered with this rather than from a fixed list of names.
    static func selectors(matchingAll fragments: [String], onClassSide: Bool = false) -> [(className: String, selectors: [String])] {
        var result: [(String, [String])] = []
        for name in classNames() {
            guard let cls = objc_getClass(name) as? AnyClass else { continue }
            let target: AnyClass? = onClassSide ? object_getClass(cls) : cls
            guard let target else { continue }
            let hits = ObjCRuntime.declaredSelectors(of: target).filter { selector in
                fragments.allSatisfy { selector.range(of: $0, options: .caseInsensitive) != nil }
            }
            if !hits.isEmpty { result.append((name, hits.sorted())) }
        }
        return result.map { (className: $0.0, selectors: $0.1) }
    }

    // MARK: Classes the window path needs

    static func framework(_ name: String) -> AnyClass? {
        guard load() else { return nil }
        guard let cls = NSClassFromString(name) else {
            NSLog("SafariLoader: class \(name) -> nil")
            return nil
        }
        return cls
    }

    static var appControllerClass: AnyClass? { framework("AppController") }
    static var browserWindowControllerClass: AnyClass? { framework("BrowserWindowController") }
    static var browserViewControllerClass: AnyClass? { framework("BrowserViewController") }
}

/// Objective-C runtime reads used by the framework path and by its probe. Declared members only
/// (`class_copy*` does not walk superclasses), so a dump says which class in a chain owns what.
enum ObjCRuntime {
    static func declaredSelectors(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }
        return (0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }
    }

    /// Declared selectors with their type encodings, as `"-selector  encoding"`.
    static func declaredSignatures(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }
        return (0..<Int(count)).map { index in
            let selector = NSStringFromSelector(method_getName(methods[index]))
            let encoding = method_getTypeEncoding(methods[index]).map { String(cString: $0) } ?? "?"
            return "\(selector)  \(encoding)"
        }
    }

    static func ivars(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).compactMap { index in
            guard let name = ivar_getName(list[index]).map({ String(cString: $0) }) else { return nil }
            let type = ivar_getTypeEncoding(list[index]).map { String(cString: $0) } ?? "?"
            return "\(name)  \(type)"
        }
    }

    static func properties(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { index in
            let name = String(cString: property_getName(list[index]))
            let attributes = property_getAttributes(list[index]).map { String(cString: $0) } ?? "?"
            return "\(name)  \(attributes)"
        }
    }

    /// Sends `name` to `receiver` — an instance or a class object — and hands back its result
    /// only when the method really returns an object. `perform` is avoided throughout: on a
    /// method that returns void it would read whatever was left in the return register, and on a
    /// class object its typing in Swift is not worth the argument. The reason a call produced
    /// nothing comes back with it, so every caller can log the nil with its cause.
    ///
    /// A `_new…` method hands back +1 and this never releases it: one over-retained object per
    /// window beats a double free in a path whose whole job is to survive the unknown.
    static func callReturningObject(_ receiver: AnyObject, _ name: String) -> (value: NSObject?, reason: String) {
        let selector = NSSelectorFromString(name)
        guard let cls: AnyClass = object_getClass(receiver) else { return (nil, "\(name) -> receiver has no class") }
        guard let method = class_getInstanceMethod(cls, selector) else { return (nil, "\(name) -> not implemented") }
        let returnTypePointer = method_copyReturnType(method)
        let returnType = String(cString: returnTypePointer)
        free(returnTypePointer)
        guard returnType == "@" || returnType == "#" else {
            return (nil, "\(name) returns '\(returnType)', not an object")
        }
        let colons = name.filter { $0 == ":" }.count
        guard colons <= 1 else { return (nil, "\(name) takes \(colons) arguments") }
        // The result comes back as a raw pointer rather than a Swift object: what the method
        // returns it at — +0 or, for the `_new…` family, +1 — is not knowable from here, and a
        // pointer lets this decide rather than letting ARC guess wrong in either direction.
        let imp = method_getImplementation(method)
        let returned: UnsafeRawPointer?
        if colons == 0 {
            typealias Call = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
            returned = unsafeBitCast(imp, to: Call.self)(receiver, selector)
        } else {
            typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> UnsafeRawPointer?
            returned = unsafeBitCast(imp, to: Call.self)(receiver, selector, nil)
        }
        guard let returned else { return (nil, "\(name) -> nil") }
        guard let value = Unmanaged<AnyObject>.fromOpaque(returned).takeUnretainedValue() as? NSObject else {
            return (nil, "\(name) -> a non-NSObject")
        }
        return (value, "\(name) -> \(NSStringFromClass(type(of: value)))")
    }

    /// `[[cls alloc] name:integer isPopup:flag]` — an initialiser taking an integer and a flag,
    /// the shape the framework's own window initialiser has. Scalar arguments cannot go through
    /// `send`, whose arguments are objects.
    static func allocating(_ cls: AnyClass, _ name: String, integer: Int, flag: Bool) -> (value: NSObject?, reason: String) {
        let allocSelector = NSSelectorFromString("alloc")
        guard let meta: AnyClass = object_getClass(cls),
              let allocMethod = class_getInstanceMethod(meta, allocSelector) else {
            return (nil, "+alloc -> not implemented")
        }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        guard let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(cls as AnyObject, allocSelector) else {
            return (nil, "+alloc -> nil")
        }
        let instance = Unmanaged<AnyObject>.fromOpaque(allocated).takeUnretainedValue()
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return (nil, "\(name) -> not implemented") }
        typealias Init = @convention(c) (AnyObject, Selector, Int, ObjCBool) -> UnsafeRawPointer?
        guard let returned = unsafeBitCast(method_getImplementation(method), to: Init.self)(instance, selector, integer, ObjCBool(flag)) else {
            return (nil, "\(name) -> nil")
        }
        guard let value = Unmanaged<AnyObject>.fromOpaque(returned).takeUnretainedValue() as? NSObject else {
            return (nil, "\(name) -> a non-NSObject")
        }
        return (value, "\(name) -> \(NSStringFromClass(type(of: value)))")
    }

    /// `[[cls alloc] name:flag]` — an initialiser taking only a flag, the shape of the window
    /// controller's popup initialiser. Looked up before allocating, so a missing one leaks nothing.
    static func allocating(_ cls: AnyClass, _ name: String, flag: Bool) -> (value: NSObject?, reason: String) {
        let allocSelector = NSSelectorFromString("alloc")
        let selector = NSSelectorFromString(name)
        guard let meta: AnyClass = object_getClass(cls),
              let allocMethod = class_getInstanceMethod(meta, allocSelector) else {
            return (nil, "+alloc -> not implemented")
        }
        guard let method = class_getInstanceMethod(cls, selector) else { return (nil, "\(name) -> not implemented") }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        guard let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(cls as AnyObject, allocSelector) else {
            return (nil, "+alloc -> nil")
        }
        let instance = Unmanaged<AnyObject>.fromOpaque(allocated).takeUnretainedValue()
        typealias Init = @convention(c) (AnyObject, Selector, ObjCBool) -> UnsafeRawPointer?
        guard let returned = unsafeBitCast(method_getImplementation(method), to: Init.self)(instance, selector, ObjCBool(flag)) else {
            return (nil, "\(name) -> nil")
        }
        return reported(returned, name)
    }

    /// A method taking an integer and a flag — the shape of the window controller's tab factory.
    static func callReturningObject(_ receiver: AnyObject, _ name: String, integer: Int, flag: Bool) -> (value: NSObject?, reason: String) {
        let selector = NSSelectorFromString(name)
        guard let cls: AnyClass = object_getClass(receiver),
              let method = class_getInstanceMethod(cls, selector) else { return (nil, "\(name) -> not implemented") }
        typealias Call = @convention(c) (AnyObject, Selector, Int, ObjCBool) -> UnsafeRawPointer?
        guard let returned = unsafeBitCast(method_getImplementation(method), to: Call.self)(receiver, selector, integer, ObjCBool(flag)) else {
            return (nil, "\(name) -> nil")
        }
        return reported(returned, name)
    }

    /// A method taking an integer, an object and a flag — the shape of the window controller's
    /// class-side factory for an empty window.
    static func callReturningObject(_ receiver: AnyObject, _ name: String,
                                    integer: Int, object: AnyObject?, flag: Bool) -> (value: NSObject?, reason: String) {
        let selector = NSSelectorFromString(name)
        guard let cls: AnyClass = object_getClass(receiver),
              let method = class_getInstanceMethod(cls, selector) else { return (nil, "\(name) -> not implemented") }
        typealias Call = @convention(c) (AnyObject, Selector, Int, AnyObject?, ObjCBool) -> UnsafeRawPointer?
        guard let returned = unsafeBitCast(method_getImplementation(method), to: Call.self)(receiver, selector, integer, object, ObjCBool(flag)) else {
            return (nil, "\(name) -> nil")
        }
        return reported(returned, name)
    }

    /// Sends a method that takes nothing and returns `BOOL`. nil when it is not implemented or
    /// returns something else, so a report can tell "false" from "not there".
    static func callReturningBool(_ receiver: AnyObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard !name.contains(":"),
              let cls: AnyClass = object_getClass(receiver),
              let method = class_getInstanceMethod(cls, selector) else { return nil }
        let returnTypePointer = method_copyReturnType(method)
        let returnType = String(cString: returnTypePointer)
        free(returnTypePointer)
        // `BOOL` is encoded `B` on arm64 and `c` on x86_64.
        guard returnType == "B" || returnType == "c" else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(method_getImplementation(method), to: Call.self)(receiver, selector).boolValue
    }

    /// Sends a method taking one flag, for its effect — a `BOOL` property's setter. False when
    /// the receiver does not implement it.
    @discardableResult
    static func send(_ receiver: AnyObject, _ name: String, flag: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard name.filter({ $0 == ":" }).count == 1,
              let cls: AnyClass = object_getClass(receiver),
              let method = class_getInstanceMethod(cls, selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Call.self)(receiver, selector, ObjCBool(flag))
        return true
    }

    /// A returned object pointer as an `NSObject`, with the line that reports it.
    private static func reported(_ returned: UnsafeRawPointer, _ name: String) -> (value: NSObject?, reason: String) {
        guard let value = Unmanaged<AnyObject>.fromOpaque(returned).takeUnretainedValue() as? NSObject else {
            return (nil, "\(name) -> a non-NSObject")
        }
        return (value, "\(name) -> \(NSStringFromClass(type(of: value)))")
    }

    /// A three-argument class or instance method taking an integer and two objects — the shape
    /// the framework's web view configuration factory has.
    static func callReturningObject(_ receiver: Any, _ name: String,
                                    integer: Int, first: AnyObject?, second: AnyObject?) -> (value: NSObject?, reason: String) {
        let target = receiver as AnyObject
        let selector = NSSelectorFromString(name)
        guard let cls: AnyClass = object_getClass(target),
              let method = class_getInstanceMethod(cls, selector) else { return (nil, "\(name) -> not implemented") }
        typealias Call = @convention(c) (AnyObject, Selector, Int, AnyObject?, AnyObject?) -> UnsafeRawPointer?
        guard let returned = unsafeBitCast(method_getImplementation(method), to: Call.self)(target, selector, integer, first, second) else {
            return (nil, "\(name) -> nil")
        }
        guard let value = Unmanaged<AnyObject>.fromOpaque(returned).takeUnretainedValue() as? NSObject else {
            return (nil, "\(name) -> a non-NSObject")
        }
        return (value, "\(name) -> \(NSStringFromClass(type(of: value)))")
    }

    /// Sends `name` for its effect, with no assumption about what it returns. False when the
    /// receiver does not implement it or it takes more than one argument.
    @discardableResult
    static func send(_ receiver: AnyObject, _ name: String, argument: AnyObject? = nil) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let cls: AnyClass = object_getClass(receiver),
              let method = class_getInstanceMethod(cls, selector) else { return false }
        let colons = name.filter { $0 == ":" }.count
        guard colons <= 1 else { return false }
        let imp = method_getImplementation(method)
        if colons == 0 {
            typealias Call = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(imp, to: Call.self)(receiver, selector)
        } else {
            typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            unsafeBitCast(imp, to: Call.self)(receiver, selector, argument)
        }
        return true
    }

    /// `cls` and every superclass, nearest first.
    static func chain(of cls: AnyClass) -> [String] {
        var names: [String] = []
        var current: AnyClass? = cls
        while let step = current {
            names.append(NSStringFromClass(step))
            current = class_getSuperclass(step)
        }
        return names
    }
}
