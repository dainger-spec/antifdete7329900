import AppKit
import MachO
import ObjCExceptions
import os

/// What a profile's Safari window does where Safari's code throws away from typing (the address
/// bar's is `SafariTypingGuard`'s): each one found by the sweep with real input (`SafariSweep`,
/// scripts/sweep.py; CI run 43990525206, macOS 26.7.2 with Safari 26.6.2), each one wrapped where
/// Safari's code meets what this process lacks, and each one said in the log with what it lacked.
///
///   * A key the page did not take is sent again by WebKit (`-[NSApplication sendEvent:]` from
///     `WebViewImpl::doneWithKeyEvent`, out of a run loop source), outside the `@try` AppKit's run
///     loop keeps around the events it hands out itself. A key equivalent whose action threw there
///     ended the profile's process: ⌃⌘2 (View › Show Reading List Sidebar) with the page focused,
///     SIGABRT in `-[NSMenu _performKeyEquivalentForItemAtIndex:]`'s rethrow. Key events are caught
///     around Safari's application object's `sendEvent:` instead, and handed to `reportException:`,
///     as the run loop does with one it caught: the process goes on, the log has it, and the profile's
///     window decides what to tell the person as for any other (`SafariChrome.installUnavailableNotice`).
///   * Safari's Reading List made each row's view with a subview it does not have here, and
///     `+[NSLayoutConstraint safari_constraintsMatchingFrameOfView:withFrameOfView:edgeInsets:]` threw
///     on the nil: once a page was in the Reading List, its sidebar stayed empty (chosen from the
///     menu) or ended the process (⌃⌘2). No view, no constraints to match it: an empty list.
///   * Bookmarks › Add Bookmark… (⌘D) put each bookmark folder in its sheet's location menu, and a
///     folder with no title — a tab group's, once the profile had one — threw in
///     `-[NSMenu safari_addMenuItemForBookmarkFolder:]`: the sheet never came. That folder is left
///     out of the menu and the sheet comes.
@MainActor
enum SafariWindowGuard {
    nonisolated private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")

    /// What is guarded so far, by name.
    private(set) static var guarded: Set<String> = []
    private static var watchesImages = false

    /// Exceptions caught here since the process started, from any thread (the sweep reads it).
    nonisolated static var caught: Int { caughtLock.withLock { caughtCount } }
    nonisolated private static let caughtLock = NSLock()
    nonisolated(unsafe) private static var caughtCount = 0

    nonisolated private static func countCaught() {
        caughtLock.withLock { caughtCount += 1 }
    }

    /// Exceptions AppKit uses to end a modal session or a print job, which must go on up as they
    /// would have.
    nonisolated static let passedOn: Set<String> = ["NSAbortModalException", "NSAbortPrintingException"]

    /// The guards whose classes are loaded now; the others as their images load. Idempotent.
    static func install() {
        guardResentKeys()
        guardFrameMatching()
        guardBookmarkFolderItems()
        guard guarded.count < 3, !watchesImages else { return }
        watchesImages = true
        _dyld_register_func_for_add_image { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard SafariWindowGuard.guarded.count < 3 else { return }
                    SafariWindowGuard.guardFrameMatching()
                    SafariWindowGuard.guardBookmarkFolderItems()
                }
            }
        }
    }

    // MARK: Keys sent again by WebKit

    private static func guardResentKeys() {
        let name = "sendEvent:"
        guard !guarded.contains(name) else { return }
        let selector = #selector(NSApplication.sendEvent(_:))
        // Safari's application object's own implementation, the one every event goes through first.
        let owner: AnyClass = NSClassFromString("BrowserApplication") ?? NSApplication.self
        guard let method = class_getInstanceMethod(owner, selector) else { return }
        typealias Send = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let replacement: @convention(block) (AnyObject, NSEvent) -> Void = { application, event in
            guard event.type == .keyDown || event.type == .keyUp else {
                original(application, selector, event)
                return
            }
            guard let thrown = PBCatchException({ original(application, selector, event) }) else { return }
            if passedOn.contains(thrown.name.rawValue) { thrown.raise() }
            countCaught()
            log.error("A key's work threw \(thrown.name.rawValue, privacy: .public) in Safari's code: reported as the run loop reports one, and the profile goes on")
            _ = (application as? NSObject)?.perform(#selector(NSApplication.reportException(_:)), with: thrown)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        guarded.insert(name)
    }

    // MARK: A view matched to a view that is not there

    private static func guardFrameMatching() {
        let name = "safari_constraintsMatchingFrameOfView:withFrameOfView:edgeInsets:"
        guard !guarded.contains(name) else { return }
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(NSLayoutConstraint.self, selector) else { return }
        typealias Matching = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, NSEdgeInsets) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Matching.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, NSEdgeInsets) -> AnyObject? = { owner, view, other, insets in
            guard view == nil || other == nil else { return original(owner, selector, view, other, insets) }
            countCaught()
            let viewsAround = SafariWindowGuard.describe(around: (view ?? other) as? NSView)
            log.error("Safari matched a view's frame to one it does not have here: no constraints (\(viewsAround, privacy: .public))")
            return [] as NSArray
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        guarded.insert(name)
    }

    /// The view that is there and the views around it, each with which of its object instance
    /// variables are nil: what Safari's code expected and this process did not give it.
    static func describe(around view: NSView?) -> String {
        guard let view else { return "neither view is there" }
        var parts: [String] = []
        var current: NSView? = view
        var depth = 0
        while let shown = current, depth < 3 {
            parts.append(String(describing: type(of: shown)) + " " + nilIvars(of: shown))
            current = shown.superview
            depth += 1
        }
        return parts.joined(separator: " < ")
    }

    /// The object instance variables of `object`'s class and its superclasses up to AppKit's, those
    /// that are nil named, the others counted. Read as raw pointers, never retained: a variable
    /// that does not own what it points to is not touched.
    nonisolated static func nilIvars(of object: AnyObject) -> String {
        var empty: [String] = []
        var set = 0
        let base = Unmanaged.passUnretained(object).toOpaque()
        var cls: AnyClass? = object_getClass(object)
        while let current = cls, !NSStringFromClass(current).hasPrefix("NS") {
            var count: UInt32 = 0
            if let list = class_copyIvarList(current, &count) {
                for index in 0..<Int(count) {
                    let ivar = list[index]
                    guard let type = ivar_getTypeEncoding(ivar), type.pointee == CChar(UInt8(ascii: "@")) else { continue }
                    let ivarName = ivar_getName(ivar).map { String(cString: $0) } ?? "?"
                    let value = base.advanced(by: ivar_getOffset(ivar)).load(as: UnsafeRawPointer?.self)
                    if value == nil { empty.append(ivarName) } else { set += 1 }
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return "[nil: \(empty.joined(separator: ", ")); set: \(set)]"
    }

    // MARK: A bookmark folder with no title

    private static func guardBookmarkFolderItems() {
        let name = "safari_addMenuItemForBookmarkFolder:"
        guard !guarded.contains(name) else { return }
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(NSMenu.self, selector) else { return }
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Add.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { menu, folder in
            var item: AnyObject?
            guard let thrown = PBCatchException({ item = original(menu, selector, folder) }) else { return item }
            if passedOn.contains(thrown.name.rawValue) { thrown.raise() }
            countCaught()
            let folderKind = SafariWindowGuard.describe(folder: folder)
            log.error("A bookmark folder could not be put in a menu (\(thrown.name.rawValue, privacy: .public)): left out (\(folderKind, privacy: .public))")
            return nil
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        guarded.insert(name)
    }

    /// A bookmark folder as the log says it: its class, whether it has a title, and what kind of
    /// folder it says it is.
    nonisolated static func describe(folder: AnyObject?) -> String {
        guard let folder = folder as? NSObject else { return "no folder" }
        var parts = [String(describing: type(of: folder))]
        for key in ["title", "isTabGroupFavoritesFolder", "isTabGroup", "isFavoritesFolder", "isBuiltinBookmark", "isReadingListFolder"] {
            guard folder.responds(to: NSSelectorFromString(key)) else { continue }
            var value: Any?
            _ = PBCatchException { value = folder.value(forKey: key) }
            parts.append(key == "title" ? "title \(value == nil ? "nil" : "set")" : "\(key) \(value.map { "\($0)" } ?? "nil")")
        }
        return parts.joined(separator: ", ")
    }
}
