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
        "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari",
        "/System/Library/PrivateFrameworks/Safari.framework/Safari",
    ]

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
    static func callReturningObject(_ receiver: Any, _ name: String) -> (value: NSObject?, reason: String) {
        let selector = NSSelectorFromString(name)
        // `receiver` may be a class object, whose Swift type is a metatype; `as AnyObject` is
        // what turns that back into the Objective-C class object the runtime wants.
        let target = receiver as AnyObject
        guard let cls: AnyClass = object_getClass(target) else { return (nil, "\(name) -> receiver has no class") }
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
            returned = unsafeBitCast(imp, to: Call.self)(target, selector)
        } else {
            typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> UnsafeRawPointer?
            returned = unsafeBitCast(imp, to: Call.self)(target, selector, nil)
        }
        guard let returned else { return (nil, "\(name) -> nil") }
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
