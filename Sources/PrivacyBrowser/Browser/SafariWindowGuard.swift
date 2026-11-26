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
///   * Bookmarks › Add Bookmark… (⌘D) put each bookmark folder in its sheet's location menu, and
///     once the profile had a tab group it was handed a folder that is not there (nil: the group's
///     favorites, CI run 43999545658) — `-[NSMenu safari_addMenuItemForBookmarkFolder:]` threw on its
///     title and the sheet never came. No folder, no menu item: the sheet comes.
///   * File › New Window's key (⌘N) did nothing: the File menu's delegate (Safari's AppController)
///     answers for the menu's key equivalents itself (`menuHasKeyEquivalent:forEvent:target:action:`),
///     so AppKit never looked at the item, which opens a window of the profile chosen by a click
///     (`SafariChrome.retargetNewWindow`). An item of the menu that this app retargeted answers its
///     own key.
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

    /// The menus of `bar` whose delegate answers for their key equivalents itself: an item this app
    /// retargeted (its target is one of this app's own objects) answers its own key there. Called
    /// once Safari's menu bar is up (`SafariChrome.installMainMenu`).
    static func guardMenuKeys(in bar: NSMenu) {
        let selector = NSSelectorFromString("menuHasKeyEquivalent:forEvent:target:action:")
        func walk(_ menu: NSMenu) {
            // Once per implementation: two delegates' classes may share one.
            if let delegate = menu.delegate, let owner = object_getClass(delegate), menu.items.contains(where: isRetargeted),
               let method = class_getInstanceMethod(owner, selector),
               guarded.insert("keys \(UInt(bitPattern: method_getImplementation(method)))").inserted {
                wrapKeyAnswer(method, selector: selector)
                // And the wrapper itself is not wrapped again.
                guarded.insert("keys \(UInt(bitPattern: method_getImplementation(method)))")
            }
            for item in menu.items { if let submenu = item.submenu { walk(submenu) } }
        }
        walk(bar)
    }

    /// An item whose target is one of this app's own objects (its class is in this app's
    /// executable, not in a framework): put there in place of Safari's.
    static func isRetargeted(_ item: NSMenuItem) -> Bool {
        guard let target = item.target, item.action != nil, !item.keyEquivalent.isEmpty,
              let image = class_getImageName(type(of: target)) else { return false }
        return String(cString: image).contains("/Contents/MacOS/")
    }

    private static func wrapKeyAnswer(_ method: Method, selector: Selector) {
        typealias Answer = @convention(c) (AnyObject, Selector, NSMenu, NSEvent, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Answer.self)
        let replacement: @convention(block) (AnyObject, NSMenu, NSEvent, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool = { delegate, menu, event, target, action in
            let answered = original(delegate, selector, menu, event, target, action)
            guard let item = menu.items.first(where: { isRetargeted($0) && SafariWindowGuard.matches(event, $0) }),
                  let itemTarget = item.target, let target, let action else { return answered }
            target.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee = UnsafeRawPointer(Unmanaged.passUnretained(itemTarget).toOpaque())
            action.assumingMemoryBound(to: Selector?.self).pointee = item.action
            return true
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Whether a key press is `item`'s key equivalent: its modifiers, and its character as the
    /// keyboard's layout gives it with or without them (a Russian layout gives Latin with ⌘).
    static func matches(_ event: NSEvent, _ item: NSMenuItem) -> Bool {
        guard event.type == .keyDown, !item.keyEquivalent.isEmpty else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        var wanted = item.keyEquivalentModifierMask.intersection(relevant)
        let key = item.keyEquivalent.lowercased()
        if key != item.keyEquivalent { wanted.insert(.shift) }
        guard event.modifierFlags.intersection(relevant) == wanted else { return false }
        return [event.charactersIgnoringModifiers, event.characters].contains { $0?.lowercased() == key }
    }

    /// The guards whose classes may load after Safari's chrome is prepared.
    private static let lateGuards = ["safari_constraintsMatchingFrameOfView:withFrameOfView:edgeInsets:",
                                     "safari_addMenuItemForBookmarkFolder:", "reading list rows"]

    /// The guards whose classes are loaded now; the others as their images load. Idempotent.
    static func install() {
        explainUnavailableDeveloperMenu()
        guardMissingTitlebarController()
        guardResentKeys()
        guardLate()
        guard lateGuards.contains(where: { !guarded.contains($0) }), !watchesImages else { return }
        watchesImages = true
        _dyld_register_func_for_add_image { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SafariWindowGuard.guardLate() } }
        }
    }

    private static func explainUnavailableDeveloperMenu() {
        let name = "updateIncludeDevelopMenuButton"
        let update = NSSelectorFromString(name)
        let outlet = NSSelectorFromString("includeDevelopMenuButton")
        guard !guarded.contains(name), let owner = NSClassFromString("AdvancedPreferences"),
              let method = class_getInstanceMethod(owner, update),
              let encoding = method_getTypeEncoding(method), String(cString: encoding) == "v16@0:8",
              let getter = class_getInstanceMethod(owner, outlet), let signature = method_getTypeEncoding(getter),
              String(cString: signature) == "@16@0:8" else { return }
        typealias Update = @convention(c) (NSObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Update.self)
        let replacement: @convention(block) (NSObject) -> Void = { pane in
            original(pane, update)
            guard let button = pane.perform(outlet)?.takeUnretainedValue() as? NSButton else { return }
            let help = L("safari.preferences.developerUnavailable")
            if !button.isEnabled, button.action == nil, button.toolTip == nil {
                button.toolTip = help
                button.setAccessibilityHelp(help)
            } else if button.isEnabled, button.toolTip == help {
                button.toolTip = nil
                button.setAccessibilityHelp(nil)
            }
        }
        class_replaceMethod(owner, update, imp_implementationWithBlock(replacement), encoding)
        guarded.insert(name)
    }

    /// Switching the native tab layout can ask a hosted window to remove a controller it never installed.
    private static func guardMissingTitlebarController() {
        let name = "_removeTitlebarViewController:"
        let selector = NSSelectorFromString(name)
        guard !guarded.contains(name), let owner = NSClassFromString("BrowserWindowController"),
              let method = class_getInstanceMethod(owner, selector),
              let encoding = method_getTypeEncoding(method), String(cString: encoding) == "v24@0:8@16" else { return }
        typealias Remove = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Remove.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { window, controller in
            guard let controller else { return }
            original(window, selector, controller)
        }
        class_replaceMethod(owner, selector, imp_implementationWithBlock(replacement), encoding)
        guarded.insert(name)
    }

    private static func guardLate() {
        guard lateGuards.contains(where: { !guarded.contains($0) }) else { return }
        guardFrameMatching()
        guardBookmarkFolderItems()
        watchReadingListRows()
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
                    guard value == nil else {
                        set += 1
                        continue
                    }
                    // Its declared class, and whether this process has that class at all.
                    let encoding = String(cString: type)
                    let declared = encoding.count > 3 ? String(encoding.dropFirst(2).dropLast()) : ""
                    let className = declared.split(separator: "<").first.map(String.init) ?? ""
                    let present = className.isEmpty ? "" : (NSClassFromString(className) == nil ? " absent" : "")
                    empty.append(declared.isEmpty ? ivarName : "\(ivarName) \(declared)\(present)")
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return "[nil: \(empty.joined(separator: ", ")); set: \(set)]"
    }

    // MARK: What a Reading List row gets from its nib

    /// While Safari makes a Reading List row (`-[ReadingListTableCellView _setUpSubviews]`).
    private static var makingReadingListRow = false
    private static var rowNibsSaid = 0

    /// The row's item view (`_readingListItemView`, an AnnotatedBookmarksSidebarExpandedTableCellView)
    /// is nil in a profile's process although its nib (…ExpandedTableCellViewV2) is found and made
    /// (CI run 44012019641): the rows come up with nothing in them. Said in the log for the first
    /// rows: what each nib the row instantiates holds at its top level, and for whom.
    private static func watchReadingListRows() {
        let name = "reading list rows"
        let setUpSelector = NSSelectorFromString("_setUpSubviews")
        guard !guarded.contains(name), let cell = NSClassFromString("ReadingListTableCellView"),
              let setUp = class_getInstanceMethod(cell, setUpSelector),
              let instantiate = class_getInstanceMethod(NSNib.self, NSSelectorFromString("instantiateWithOwner:topLevelObjects:")) else { return }
        guarded.insert(name)
        typealias Plain = @convention(c) (AnyObject, Selector) -> Void
        let originalSetUp = unsafeBitCast(method_getImplementation(setUp), to: Plain.self)
        let setUpReplacement: @convention(block) (AnyObject) -> Void = { view in
            makingReadingListRow = true
            defer { makingReadingListRow = false }
            originalSetUp(view, setUpSelector)
        }
        method_setImplementation(setUp, imp_implementationWithBlock(setUpReplacement))
        let instantiateSelector = method_getName(instantiate)
        typealias Instantiate = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutableRawPointer?) -> Bool
        let original = unsafeBitCast(method_getImplementation(instantiate), to: Instantiate.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, UnsafeMutableRawPointer?) -> Bool = { nib, owner, objects in
            let made = original(nib, instantiateSelector, owner, objects)
            guard makingReadingListRow, rowNibsSaid < 3 else { return made }
            rowNibsSaid += 1
            var classes: [String] = []
            if let objects, let raw = objects.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee {
                for object in Unmanaged<NSArray>.fromOpaque(raw).takeUnretainedValue() {
                    classes.append(String(describing: type(of: object as AnyObject)))
                }
            }
            let topLevel = classes.joined(separator: ", ")
            let ownerClass = owner.map { String(describing: type(of: $0)) } ?? "none"
            let madeSaid = made ? "made" : "not made"
            log.notice("A Reading List row's nib: \(madeSaid, privacy: .public), owner \(ownerClass, privacy: .public), top level: \(topLevel, privacy: .public)")
            return made
        }
        method_setImplementation(instantiate, imp_implementationWithBlock(replacement))
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
            guard folder != nil else {
                countCaught()
                log.notice("Safari asked for a menu item for a bookmark folder that is not there: none")
                return nil
            }
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
