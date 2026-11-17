import AppKit
import MachO
import ObjCExceptions
import os

/// Typing into Safari's chrome goes on whatever Safari's code throws on the way.
///
/// A customer's address bar, in Safari's window of a profile, threw at every key press (0.1.17 or
/// earlier, macOS 26, Google): the run loop caught each exception, and the window said "not
/// available in a profile" at every key, so nothing could be typed. An exception that unwinds out
/// of the text system's callbacks leaves the key press half done — the text system's delegate is
/// called while the field editor is inside its edit — so it is caught where Safari's code is
/// called by the text system, written to the log (`ExceptionLog` has it with its frames, from the
/// throw), and the key press goes on as if that callback had done nothing.
///
/// Only the text system's own callbacks are wrapped, whose signatures AppKit fixes, on Safari's
/// classes that implement them themselves: the delegates' `textDidChange:` and the rest (the
/// address bar's `UnifiedField`, the find bar's field, the controllers behind them, on any version
/// of Safari), and on Safari's own text fields and text views, the key press, the insertion and
/// the change. What a callback answers when it threw: nothing done (`doCommandBySelector:` NO, so
/// the field editor does it itself), the change allowed (`shouldChangeTextInRange:` YES).
@MainActor
enum SafariTypingGuard {
    nonisolated private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")

    /// "Class selector" of every method wrapped so far.
    private static var wrapped: Set<String> = []
    /// Exceptions caught here since the process started (the address bar check reads it). From any
    /// thread: the completions' own classes are called on their queues too.
    nonisolated static var caught: Int { caughtLock.withLock { caughtCount } }
    nonisolated private static let caughtLock = NSLock()
    nonisolated(unsafe) private static var caughtCount = 0

    /// Callbacks with an NSNotification, on any of Safari's classes.
    static let notificationCallbacks = ["textDidChange:", "textDidBeginEditing:", "textDidEndEditing:",
                                        "controlTextDidChange:", "controlTextDidBeginEditing:", "controlTextDidEndEditing:",
                                        "textViewDidChangeSelection:"]
    /// `-textView:doCommandBySelector:` and `-control:textView:doCommandBySelector:`.
    static let commandCallbacks = ["textView:doCommandBySelector:", "control:textView:doCommandBySelector:"]
    static let shouldChange = "textView:shouldChangeTextInRange:replacementString:"
    /// On Safari's own NSText and NSTextField subclasses.
    static let textViewMethods = ["keyDown:", "insertText:", "insertText:replacementRange:", "didChangeText", "complete:"]

    /// The address bar's field editor, as it begins editing: none of the system's typing aids —
    /// inline predictions, completion, spelling correction, text replacement — which are this Mac's
    /// own settings (System Settings › Keyboard), different from one Mac to the next, and which
    /// rewrite the field's text behind Safari's own inline completion of an address. An address is
    /// not prose: Safari's own field has none of them either.
    private static var observesEditing = false

    static func quietTypingAids() {
        guard !observesEditing else { return }
        observesEditing = true
        _ = NotificationCenter.default.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil, queue: nil) { note in
            guard let field = note.object as? NSTextField,
                  String(describing: Swift.type(of: field)).contains("UnifiedField"),
                  let editor = note.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            MainActor.assumeIsolated { SafariTypingGuard.quiet(editor) }
        }
    }

    private static func quiet(_ editor: NSTextView) {
        _ = PBCatchException {
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.inlinePredictionType = .no
        }
    }

    /// The completions' classes of an image that loaded later (`SafariChrome.stubLateFeatures`, at
    /// every image): only those, by name — not every class of Safari's images again.
    static func installLate() {
        let before = wrapped.count
        for name in completionClasses where !wholeClassesWrapped.contains(name) {
            guard let cls = NSClassFromString(name) else { continue }
            wholeClassesWrapped.insert(name)
            wrapWholeClass(cls, name: name)
        }
        if wrapped.count != before {
            log.notice("Typing in Safari's chrome is guarded: \(wrapped.count, privacy: .public) method(s)")
        }
    }

    /// Wraps what Safari's images loaded so far have. Idempotent.
    static func install() {
        quietTypingAids()
        let before = wrapped.count
        let names = classesOfSafarisImages()
        for name in names {
            guard let cls = NSClassFromString(name) else { continue }
            wrap(cls, name: name)
        }
        for name in completionClasses where !wholeClassesWrapped.contains(name) {
            guard let cls = NSClassFromString(name) else { continue }
            wholeClassesWrapped.insert(name)
            wrapWholeClass(cls, name: name)
        }
        if wrapped.count != before {
            log.notice("Typing in Safari's chrome is guarded: \(wrapped.count, privacy: .public) method(s)")
        }
    }

    // MARK: The completions' own classes

    /// The classes Safari's address bar asks for its completions as a person types (measured on
    /// macOS 26.7.2 with Safari 26.6.2 and on 27.0.1, the address bar check), each one's whole
    /// method list wrapped: the completion controller and list generator, the search suggestions'
    /// coordinator and fetchers, the history service's completions, open tabs, iCloud tabs, the
    /// on-device suggestions model, the completion database and icons. Several reach what a profile's
    /// process does not have, and differs from one Mac to the next — the account's iCloud tabs, the
    /// on-device suggestions model Safari downloaded, Safari's history service (refused) — which a
    /// runner's new account does not: typing passed there with no exception at all, on every engine,
    /// in English and Russian, while the customer's Mac threw at every key. Whatever throws in them now
    /// answers nothing — no completions from there — and typing goes on.
    static let completionClasses = [
        "UnifiedFieldCompletionControllerObjCAdapter", "UnifiedFieldCompletionListGeneratorObjCAdapter",
        "UnifiedFieldCompletionListSearchSuggestionsCoordinator", "UnifiedFieldCompletionListParsecResultValidator",
        "CompletionListVendorForHistoryService", "WBSCompletionListVendorForHistoryService",
        "WBSHistoryServiceURLCompletion", "WBSHistoryURLCompletionSession", "WBSURLCompletionSessionProxy",
        "WBSURLCompletionDatabase", "URLCompletionDatabase", "WBSBrowserTabCompletionProvider",
        "CloudTabStore", "WBSCloudTabStore", "WBSRecentCloudTabsProvider",
        "WBSSearchSuggestionsFetcher", "WebSearchSuggestionsFetcher", "WebSearchSuggestionsFetcherController",
        "SafariSharedUI.WBSSearchEngineSuggestionFetcher", "WBSOfflineSearchSuggestionsFetcher",
        "WBSOnDeviceSearchSuggestionsProvider", "WBSOnDeviceSearchSuggestionsModelManager", "WBSOnDeviceSearchSuggestionsModel",
        "WBSCompletionIconProvider", "WBSCompletionListRankingObserver", "CompletionListWindowController",
        "Safari.CompletionListCollectionViewController",
    ]
    private static var wholeClassesWrapped: Set<String> = []

    /// Every method of `cls` (its own, instance and class side) whose arguments and answer are each
    /// one register wide — objects, selectors, pointers, integers, BOOLs, at most four arguments —
    /// called inside an Objective-C @try. Arguments go through untouched, as raw pointers (no
    /// retain, no release): an integer is never taken for an object. On a throw, it answers nil, 0
    /// or NO. Methods with a float, a struct or more arguments are left as they are, and so are
    /// the object's life cycle (init…, dealloc, copy…, new…, retain, release, .cxx_…).
    private static func wrapWholeClass(_ cls: AnyClass, name className: String) {
        for target in [cls, object_getClass(cls)].compactMap({ $0 }) {
            var count: UInt32 = 0
            guard let list = class_copyMethodList(target, &count) else { continue }
            for index in 0..<Int(count) {
                let method = list[index]
                let selectorName = NSStringFromSelector(method_getName(method))
                let key = className + " " + selectorName
                guard !wrapped.contains(key), isWrappable(method, named: selectorName) else { continue }
                let arguments = Int(method_getNumberOfArguments(method)) - 2
                let returnType = method_copyReturnType(method)
                let returnsNothing = String(cString: returnType) == "v"
                free(returnType)
                if wrapRegisters(method, arguments: arguments, returnsNothing: returnsNothing, key: key) {
                    wrapped.insert(key)
                }
            }
            free(list)
        }
    }

    /// One-register type encodings: an object, a class, a selector, a C string, a pointer, an
    /// integer or a BOOL (after any qualifiers such as const).
    private static func isRegisterWide(_ encoding: String) -> Bool {
        let type = encoding.drop { "rnNoORV".contains($0) }
        guard let first = type.first else { return false }
        if first == "^" { return true }
        return "@#:*qQiIlLsScCB".contains(first) && (first != "@" || !type.hasPrefix("@?") || type == "@?")
    }

    private static func isWrappable(_ method: Method, named name: String) -> Bool {
        let lifeCycle = ["init", "dealloc", "copy", "mutableCopy", "new", "retain", "release", "autorelease", "retainCount",
                         ".cxx_", "_tryRetain", "_isDeallocating", "allowsWeakReference", "retainWeakReference", "class",
                         "respondsToSelector:", "isKindOfClass:", "conformsToProtocol:", "methodSignatureForSelector:",
                         "forwardInvocation:", "forwardingTargetForSelector:", "resolveInstanceMethod:", "load", "initialize"]
        if lifeCycle.contains(where: { name == $0 || (name.hasPrefix($0) && $0 != "class" && $0 != "load") }) { return false }
        let arguments = Int(method_getNumberOfArguments(method))
        guard arguments >= 2, arguments - 2 <= 4 else { return false }
        let returnType = method_copyReturnType(method)
        let answer = String(cString: returnType)
        free(returnType)
        guard answer == "v" || isRegisterWide(answer) else { return false }
        for index in 2..<arguments {
            guard let raw = method_copyArgumentType(method, UInt32(index)) else { return false }
            let encoding = String(cString: raw)
            free(raw)
            guard isRegisterWide(encoding) else { return false }
        }
        return true
    }

    private typealias Raw = UnsafeRawPointer?

    /// The wrapper of a method of this many register-wide arguments.
    nonisolated private static func wrapRegisters(_ method: Method, arguments: Int, returnsNothing: Bool, key: String) -> Bool {
        let imp = method_getImplementation(method)
        let selector = method_getName(method)
        let block: Any
        switch (arguments, returnsNothing) {
        case (0, true):
            typealias Call = @convention(c) (Raw, Selector) -> Void
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw) -> Void = { object in
                if let exception = PBCatchException({ original(object, selector) }) { SafariTypingGuard.note(exception, in: key) }
            }
            block = replacement
        case (0, false):
            typealias Call = @convention(c) (Raw, Selector) -> Raw
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw) -> Raw = { object in
                var answer: Raw = nil
                if let exception = PBCatchException({ answer = original(object, selector) }) { SafariTypingGuard.note(exception, in: key); return nil }
                return answer
            }
            block = replacement
        case (1, true):
            typealias Call = @convention(c) (Raw, Selector, Raw) -> Void
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw) -> Void = { object, a in
                if let exception = PBCatchException({ original(object, selector, a) }) { SafariTypingGuard.note(exception, in: key) }
            }
            block = replacement
        case (1, false):
            typealias Call = @convention(c) (Raw, Selector, Raw) -> Raw
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw) -> Raw = { object, a in
                var answer: Raw = nil
                if let exception = PBCatchException({ answer = original(object, selector, a) }) { SafariTypingGuard.note(exception, in: key); return nil }
                return answer
            }
            block = replacement
        case (2, true):
            typealias Call = @convention(c) (Raw, Selector, Raw, Raw) -> Void
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw, Raw) -> Void = { object, a, b in
                if let exception = PBCatchException({ original(object, selector, a, b) }) { SafariTypingGuard.note(exception, in: key) }
            }
            block = replacement
        case (2, false):
            typealias Call = @convention(c) (Raw, Selector, Raw, Raw) -> Raw
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw, Raw) -> Raw = { object, a, b in
                var answer: Raw = nil
                if let exception = PBCatchException({ answer = original(object, selector, a, b) }) { SafariTypingGuard.note(exception, in: key); return nil }
                return answer
            }
            block = replacement
        case (3, true):
            typealias Call = @convention(c) (Raw, Selector, Raw, Raw, Raw) -> Void
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw, Raw, Raw) -> Void = { object, a, b, c in
                if let exception = PBCatchException({ original(object, selector, a, b, c) }) { SafariTypingGuard.note(exception, in: key) }
            }
            block = replacement
        case (3, false):
            typealias Call = @convention(c) (Raw, Selector, Raw, Raw, Raw) -> Raw
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw, Raw, Raw) -> Raw = { object, a, b, c in
                var answer: Raw = nil
                if let exception = PBCatchException({ answer = original(object, selector, a, b, c) }) { SafariTypingGuard.note(exception, in: key); return nil }
                return answer
            }
            block = replacement
        case (4, true):
            typealias Call = @convention(c) (Raw, Selector, Raw, Raw, Raw, Raw) -> Void
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw, Raw, Raw, Raw) -> Void = { object, a, b, c, d in
                if let exception = PBCatchException({ original(object, selector, a, b, c, d) }) { SafariTypingGuard.note(exception, in: key) }
            }
            block = replacement
        case (4, false):
            typealias Call = @convention(c) (Raw, Selector, Raw, Raw, Raw, Raw) -> Raw
            let original = unsafeBitCast(imp, to: Call.self)
            let replacement: @convention(block) (Raw, Raw, Raw, Raw, Raw) -> Raw = { object, a, b, c, d in
                var answer: Raw = nil
                if let exception = PBCatchException({ answer = original(object, selector, a, b, c, d) }) { SafariTypingGuard.note(exception, in: key); return nil }
                return answer
            }
            block = replacement
        default:
            return false
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }

    private static func wrap(_ cls: AnyClass, name className: String) {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return }
        defer { free(list) }
        let isText = (cls as? NSText.Type) != nil || (cls as? NSTextField.Type) != nil
        for index in 0..<Int(count) {
            let method = list[index]
            let selectorName = NSStringFromSelector(method_getName(method))
            let key = className + " " + selectorName
            guard !wrapped.contains(key) else { continue }
            if notificationCallbacks.contains(selectorName) || (isText && ["keyDown:", "insertText:", "complete:"].contains(selectorName)) {
                wrapOneObject(method, key: key)
            } else if isText && selectorName == "didChangeText" {
                wrapNoArgument(method, key: key)
            } else if isText && selectorName == "insertText:replacementRange:" {
                wrapInsert(method, key: key)
            } else if selectorName == "textView:doCommandBySelector:" {
                wrapCommand(method, key: key)
            } else if selectorName == "control:textView:doCommandBySelector:" {
                wrapControlCommand(method, key: key)
            } else if selectorName == shouldChange {
                wrapShouldChange(method, key: key)
            }
        }
    }

    /// Writes down an exception caught here (its name, the method), and counts it. Any thread.
    nonisolated private static func note(_ exception: NSException, in key: String) {
        caughtLock.withLock { caughtCount += 1 }
        let parts = key.split(separator: " ").map(String.init)
        let className = parts.first ?? ""
        let selectorName = parts.count > 1 ? parts[1] : ""
        let exceptionName = exception.name.rawValue
        log.error("Caught in -[\(className, privacy: .public) \(selectorName, privacy: .public)], typing goes on: \(exceptionName, privacy: .public)")
    }

    private static func wrapOneObject(_ method: Method, key: String) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let selector = method_getName(method)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { object, argument in
            if let exception = PBCatchException({ original(object, selector, argument) }) {
                SafariTypingGuard.note(exception, in: key)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        wrapped.insert(key)
    }

    private static func wrapNoArgument(_ method: Method, key: String) {
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let selector = method_getName(method)
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            if let exception = PBCatchException({ original(object, selector) }) {
                SafariTypingGuard.note(exception, in: key)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        wrapped.insert(key)
    }

    private static func wrapInsert(_ method: Method, key: String) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, NSRange) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let selector = method_getName(method)
        let replacement: @convention(block) (AnyObject, AnyObject?, NSRange) -> Void = { object, text, range in
            if let exception = PBCatchException({ original(object, selector, text, range) }) {
                SafariTypingGuard.note(exception, in: key)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        wrapped.insert(key)
    }

    private static func wrapCommand(_ method: Method, key: String) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, Selector?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let selector = method_getName(method)
        let replacement: @convention(block) (AnyObject, AnyObject?, Selector?) -> Bool = { object, textView, command in
            var handled = false
            if let exception = PBCatchException({ handled = original(object, selector, textView, command) }) {
                SafariTypingGuard.note(exception, in: key)
                return false
            }
            return handled
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        wrapped.insert(key)
    }

    private static func wrapControlCommand(_ method: Method, key: String) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, Selector?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let selector = method_getName(method)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, Selector?) -> Bool = { object, control, textView, command in
            var handled = false
            if let exception = PBCatchException({ handled = original(object, selector, control, textView, command) }) {
                SafariTypingGuard.note(exception, in: key)
                return false
            }
            return handled
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        wrapped.insert(key)
    }

    private static func wrapShouldChange(_ method: Method, key: String) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, NSRange, AnyObject?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let selector = method_getName(method)
        let replacement: @convention(block) (AnyObject, AnyObject?, NSRange, AnyObject?) -> Bool = { object, textView, range, text in
            var allowed = true
            if let exception = PBCatchException({ allowed = original(object, selector, textView, range, text) }) {
                SafariTypingGuard.note(exception, in: key)
                return true
            }
            return allowed
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        wrapped.insert(key)
    }

    /// The names of the classes of every image of Safari's frameworks loaded in this process.
    static func classesOfSafarisImages() -> [String] {
        var names: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let image = String(cString: raw)
            guard image.contains(".framework/"), image.contains("/Safari") else { continue }
            var count: UInt32 = 0
            guard let list = objc_copyClassNamesForImage(image, &count) else { continue }
            for position in 0..<Int(count) { names.append(String(cString: list[position])) }
            free(list)
        }
        return names
    }
}
