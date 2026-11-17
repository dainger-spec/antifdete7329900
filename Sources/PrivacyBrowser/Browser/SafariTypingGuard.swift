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
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")

    /// "Class selector" of every method wrapped so far.
    private static var wrapped: Set<String> = []
    /// Exceptions caught here since the process started (the address bar check reads it).
    private(set) static var caught = 0

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

    /// Wraps what Safari's images loaded so far have; called again as images load. Idempotent.
    static func install() {
        quietTypingAids()
        let names = classesOfSafarisImages()
        for name in names {
            guard let cls = NSClassFromString(name) else { continue }
            wrap(cls, name: name)
        }
        if !wrapped.isEmpty {
            log.notice("Typing in Safari's chrome is guarded: \(wrapped.count, privacy: .public) callback(s)")
        }
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

    /// Writes down an exception caught here (its name, the method), and counts it.
    private static func note(_ exception: NSException, in key: String) {
        caught += 1
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
                MainActor.assumeIsolated { SafariTypingGuard.note(exception, in: key) }
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
                MainActor.assumeIsolated { SafariTypingGuard.note(exception, in: key) }
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
                MainActor.assumeIsolated { SafariTypingGuard.note(exception, in: key) }
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
                MainActor.assumeIsolated { SafariTypingGuard.note(exception, in: key) }
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
                MainActor.assumeIsolated { SafariTypingGuard.note(exception, in: key) }
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
                MainActor.assumeIsolated { SafariTypingGuard.note(exception, in: key) }
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
