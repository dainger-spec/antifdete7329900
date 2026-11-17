import AppKit
import ObjCExceptions
import WebKit

/// Typing into the address bar of a profile's window as a person types: one key press at a time,
/// each a key-down and a key-up sent to the window, as AppKit hands a key to a window
/// (`WindowProbeAction.typeInAddressBar`). What it says: what the field holds afterwards, every
/// Objective-C exception thrown while it typed — its name, its reason as the log has it, and the
/// frames of the throw — and how many of them came out of a key press or reached the run loop.
///
/// A customer's address bar, in Safari's window of a profile, put up "This Safari feature is not
/// available in a profile" at every key, so that nothing could be typed (0.1.17 or earlier,
/// macOS 26): an exception at every key press, which the run loop caught and the window then
/// announced. This is how the self-test (and `--address-bar-check`) types, so that it sees what
/// that customer saw, on each search engine a profile can have. Sent by the self-test only.
@MainActor
enum AddressBarTyping {
    struct Thrown: Codable, Equatable {
        var name: String
        var reason: String
        var frames: [String]
    }

    struct Report: Codable, Equatable {
        var typed = ""
        /// What the field's editor held once the typing was over.
        var field = ""
        /// Whether the window was the key window while it typed (a runner's process may not be the
        /// active app: the key presses are then sent to the window, which is where AppKit sends them).
        var windowWasKey = false
        /// Exceptions that came out of a key press (caught here, around the window's sendEvent:).
        var outOfKeyPresses = 0
        /// Exceptions the run loop caught while it typed (`ExceptionLog.reported`): a timer or a
        /// block the typing scheduled.
        var caughtByRunLoop = 0
        /// Every exception thrown while it typed, caught or not, by whomever.
        var thrown: [Thrown] = []
        /// Exceptions Safari's text callbacks raised that were caught where the text system called
        /// them, so that the key press went on (`SafariTypingGuard`).
        var caughtByTypingGuard = 0
        /// Notices the window put up while it typed (`SafariChrome.noticesPresented`).
        var notices = 0
        /// The windows that were up, other than before the typing, once it was over: Safari's
        /// completion list is one (whether the typing reached the completions at all).
        var windowsWhileTyping: [String] = []
        /// Safari's classes on the typing's way, by name (completions, cloud tabs, suggestions): what a
        /// stub would name.
        var completionClasses: [String] = []
        /// The search providers Safari's chrome has here, as they describe themselves.
        var providers = ""
        /// Accessibility reads made after each key press, as an app that watches every key through
        /// the accessibility API makes them (`AccessibilitySweep`), and those that raised: element's
        /// class, attribute, parameter — with a range inside the text.
        var accessibilityReads = 0
        var accessibilityExceptions: [String] = []
        /// The same, for a range past the text's end (a client that asked with a stale range).
        var accessibilityPastEndExceptions: [String] = []

        var json: String {
            guard let data = try? JSONEncoder().encode(self) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Text that starts with this is composed as an input method composes it instead (marked text,
    /// then the composed text inserted), in the field editor, rather than typed key by key.
    static let composedPrefix = "ime:"

    /// `leaveText`: the field is left editing with what was typed in it (a Return comes next).
    static func type(_ given: String, into field: NSTextField, in window: NSWindow, leaveText: Bool = false) async -> Report {
        var report = Report()
        let composing = given.hasPrefix(composedPrefix)
        let text = composing ? String(given.dropFirst(composedPrefix.count)) : given
        report.typed = text
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = ""
        }
        var thrown: [Thrown] = []
        let previous = ExceptionLog.onThrown
        ExceptionLog.onThrown = { name, reason, frames in
            previous?(name, reason, frames)
            thrown.append(Thrown(name: name, reason: reason, frames: Array(frames.prefix(40))))
        }
        let reportedBefore = ExceptionLog.reported
        let noticesBefore = SafariChrome.noticesPresented
        let guardBefore = SafariTypingGuard.caught
        report.windowWasKey = window.isKeyWindow
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
        if composing, let editor = field.currentEditor() as? NSTextView {
            // As an input method composes: the marked text grows a character at a time, then the
            // whole is inserted in its place.
            var marked = ""
            for character in text {
                marked.append(character)
                let current = marked
                let caught = PBCatchException {
                    editor.setMarkedText(current, selectedRange: NSRange(location: (current as NSString).length, length: 0),
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                if caught != nil { report.outOfKeyPresses += 1 }
                try? await Task.sleep(nanoseconds: 180_000_000)
                sweep(field, in: window, into: &report)
            }
            let caught = PBCatchException { editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            if caught != nil { report.outOfKeyPresses += 1 }
        }
        for character in text where !composing {
            for event in keyEvents(character, in: window) {
                let caught = PBCatchException { window.sendEvent(event) }
                if caught != nil { report.outOfKeyPresses += 1 }
            }
            // As a person types: what a key press schedules (the completions) runs before the next.
            try? await Task.sleep(nanoseconds: 180_000_000)
            sweep(field, in: window, into: &report)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for shown in NSApp.windows where shown.isVisible && !windowsBefore.contains(ObjectIdentifier(shown)) {
            var name = String(describing: Swift.type(of: shown))
            if let content = shown.contentViewController { name += " " + String(describing: Swift.type(of: content)) }
            report.windowsWhileTyping.append(name)
        }
        ExceptionLog.onThrown = previous
        report.thrown = thrown
        report.caughtByRunLoop = ExceptionLog.reported - reportedBefore
        report.notices = SafariChrome.noticesPresented - noticesBefore
        report.field = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        report.providers = SafariChrome.searchProvidersDescription()
        let words = ["Completion", "CloudTab", "SharedWithYou", "TopHit", "Suggestion", "UnifiedField"]
        report.completionClasses = Array(SafariTypingGuard.classesOfSafarisImages()
            .filter { name in words.contains { name.contains($0) } }.sorted().prefix(300))
        report.caughtByTypingGuard = SafariTypingGuard.caught - guardBefore
        // The field left as it was found: empty, and not editing.
        if !leaveText {
            _ = PBCatchException {
                (field.currentEditor() as? NSTextView)?.string = ""
                window.makeFirstResponder(nil)
            }
        }
        return report
    }

    // MARK: Return

    /// What a Return in the address bar did (`enter`).
    struct Entered: Codable, Equatable {
        var typing = Report()
        var firstCompletion = false
        /// What the field held when Return was pressed: after the Down arrow, the row chosen.
        var fieldAtReturn = ""
        var pageBefore = ""
        var pageAfter = ""
        /// Every address the window's front page took after Return, in order.
        var pagesSeen: [String] = []
        /// Another page came in front (a tab switched to, a new web view).
        var frontPageChanged = false
        var tabsBefore = 0
        var tabsAfter = 0
        /// Exceptions out of the Down arrow's and the Return's key events, caught here.
        var outOfKeyPresses = 0
        var thrown: [Thrown] = []
        var caughtByTypingGuard = 0
        var caughtByRunLoop = 0
        var notices = 0
        /// The Return was taken for the address bar's (`AddressBarCommit`).
        var returnSeen = false
        /// Where Safari's code threw after Return, and what this process loaded itself.
        var thrownAfterReturn: [String] = []
        var rescues: [String] = []
        /// The frames that started the page Return loaded: Safari's commit path, by name.
        var navigationFrames: [String] = []
        /// The commit's methods guarded in this Safari (`SafariTypingGuard.commitMethods`).
        var commitMethods: [String] = []
        /// The search went to the profile's engine by the profile's process, Safari's having another.
        var searchedWithProfilesEngine = false

        var json: String {
            guard let data = try? JSONEncoder().encode(self) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class Pages {
        var seen: [String] = []
        func add(_ page: WKWebView?) {
            let address = page?.url?.absoluteString ?? "none"
            if seen.last != address { seen.append(address) }
        }
    }

    /// Types `given` as `type` does, then — with `firstCompletion`, after the Down arrow — presses
    /// Return, a key-down and a key-up sent to the window as AppKit sends a key, and watches the
    /// window's front tab for four seconds.
    static func enter(_ given: String, firstCompletion: Bool, into field: NSTextField, in window: NSWindow) async -> Entered {
        var entered = Entered()
        entered.firstCompletion = firstCompletion
        let pageBefore = SafariChromeHost.frontPage(in: window)
        entered.pageBefore = pageBefore?.url?.absoluteString ?? ""
        entered.tabsBefore = SafariTabs.tabs().filter { $0.window === window }.count
        entered.typing = await type(given, into: field, in: window, leaveText: true)
        var thrown: [Thrown] = []
        let previous = ExceptionLog.onThrown
        ExceptionLog.onThrown = { name, reason, frames in
            previous?(name, reason, frames)
            thrown.append(Thrown(name: name, reason: reason, frames: Array(frames.prefix(40))))
        }
        let reportedBefore = ExceptionLog.reported
        let noticesBefore = SafariChrome.noticesPresented
        let guardBefore = SafariTypingGuard.caught
        let returnsBefore = AddressBarCommit.returns
        let rescuesBefore = AddressBarCommit.rescues.count
        let thrownBefore = AddressBarCommit.thrownAfterReturn.count
        let searchesBefore = AddressBarCommit.searchesDone
        if firstCompletion {
            for event in keyEvents(code: 125, characters: "\u{F701}", modifiers: [.numericPad, .function], in: window) {
                if PBCatchException({ window.sendEvent(event) }) != nil { entered.outOfKeyPresses += 1 }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        entered.fieldAtReturn = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let pages = Pages()
        var observations: [NSKeyValueObservation] = []
        if let pageBefore {
            observations.append(pageBefore.observe(\.url, options: [.new]) { page, _ in pages.add(page) })
        }
        for event in keyEvents(code: 36, characters: "\r", modifiers: [], in: window) {
            if PBCatchException({ window.sendEvent(event) }) != nil { entered.outOfKeyPresses += 1 }
        }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            pages.add(SafariChromeHost.frontPage(in: window))
        }
        observations.removeAll()
        let front = SafariChromeHost.frontPage(in: window)
        entered.pageAfter = front?.url?.absoluteString ?? ""
        entered.frontPageChanged = front !== pageBefore
        entered.pagesSeen = pages.seen
        entered.tabsAfter = SafariTabs.tabs().filter { $0.window === window }.count
        ExceptionLog.onThrown = previous
        entered.thrown = thrown
        entered.caughtByRunLoop = ExceptionLog.reported - reportedBefore
        entered.notices = SafariChrome.noticesPresented - noticesBefore
        entered.caughtByTypingGuard = SafariTypingGuard.caught - guardBefore
        entered.returnSeen = AddressBarCommit.returns > returnsBefore
        entered.rescues = Array(AddressBarCommit.rescues.dropFirst(rescuesBefore))
        entered.thrownAfterReturn = Array(AddressBarCommit.thrownAfterReturn.dropFirst(thrownBefore))
        entered.navigationFrames = AddressBarCommit.lastNavigationFrames
        entered.commitMethods = SafariTypingGuard.commitMethods
        entered.searchedWithProfilesEngine = AddressBarCommit.searchesDone > searchesBefore
        return entered
    }

    /// A key-down and a key-up of the key with this code (Return, an arrow).
    private static func keyEvents(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> [NSEvent] {
        [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)
        }
    }

    /// The accessibility of the address bar and of Safari's completion list, read after a key press.
    private static func sweep(_ field: NSTextField, in window: NSWindow, into report: inout Report) {
        var elements: [NSObject] = [field]
        if let cell = field.cell { elements.append(cell) }
        if let editor = field.currentEditor() as? NSTextView { elements.append(editor) }
        for shown in NSApp.windows where shown.isVisible && shown !== window
            && String(describing: Swift.type(of: shown)).contains("Completion") {
            if let content = shown.contentView { elements += AccessibilitySweep.views(under: content, limit: 80) }
        }
        let typedSoFar = (field.currentEditor() as? NSTextView)?.string ?? ""
        let length = (typedSoFar as NSString).length
        let center = window.convertPoint(toScreen: field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
        let result = AccessibilitySweep.read(elements, textLength: length, point: center)
        report.accessibilityReads += result.reads
        for line in result.failures where !report.accessibilityExceptions.contains(line) { report.accessibilityExceptions.append(line) }
        for line in result.pastEnd where !report.accessibilityPastEndExceptions.contains(line) {
            report.accessibilityPastEndExceptions.append(line)
        }
    }

    /// A key-down and a key-up of the key that types `character` on this Mac's keyboard layout.
    private static func keyEvents(_ character: Character, in window: NSWindow) -> [NSEvent] {
        let key = PageInput.key(typing: character)
        let characters = key?.characters ?? String(character)
        let ignoring = key?.charactersIgnoringModifiers ?? String(character)
        let code = key?.code ?? 0
        let modifiers = key?.modifiers ?? []
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: characters, charactersIgnoringModifiers: ignoring,
                                            isARepeat: false, keyCode: code) {
                events.append(event)
            }
        }
        return events
    }
}

/// What an app that acts on every key press through the accessibility API — a keyboard-layout
/// switcher, a grammar checker, a text expander, a password manager — reads of the focused field
/// after each key: every attribute of each element, and every parameterized attribute with the
/// parameters such a client gives (a range of the text, an index, a line, a point). Called
/// in-process, each read inside an Objective-C @try, through the runtime: the informal
/// NSAccessibility methods, which the accessibility server calls when such an app asks.
@MainActor
enum AccessibilitySweep {
    struct Result {
        var reads = 0
        var failures: [String] = []
        var pastEnd: [String] = []
    }

    static func views(under root: NSView, limit: Int) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSView] = [root]
        while !queue.isEmpty, found.count < limit {
            let view = queue.removeFirst()
            found.append(view)
            queue += view.subviews
        }
        return found
    }

    static func read(_ elements: [NSObject], textLength length: Int, point: NSPoint) -> Result {
        var result = Result()
        let names = NSSelectorFromString("accessibilityAttributeNames")
        let value = NSSelectorFromString("accessibilityAttributeValue:")
        let parameterizedNames = NSSelectorFromString("accessibilityParameterizedAttributeNames")
        let parameterized = NSSelectorFromString("accessibilityAttributeValue:forParameter:")
        for element in elements {
            let kind = String(describing: Swift.type(of: element))
            func record(_ exception: NSException, _ what: String, pastEnd: Bool) {
                let line = kind + " " + what + ": " + exception.name.rawValue
                if pastEnd {
                    result.pastEnd.append(line)
                } else {
                    result.failures.append(line)
                }
            }
            var attributes: [String] = []
            if element.responds(to: names) {
                if let thrown = PBCatchException({ attributes = element.perform(names)?.takeUnretainedValue() as? [String] ?? [] }) {
                    record(thrown, "accessibilityAttributeNames", pastEnd: false)
                }
            }
            for attribute in attributes where element.responds(to: value) {
                result.reads += 1
                if let thrown = PBCatchException({ _ = element.perform(value, with: attribute as NSString) }) {
                    record(thrown, attribute, pastEnd: false)
                }
            }
            var parameterizedAttributes: [String] = []
            if element.responds(to: parameterizedNames) {
                if let thrown = PBCatchException({
                    parameterizedAttributes = element.perform(parameterizedNames)?.takeUnretainedValue() as? [String] ?? []
                }) {
                    record(thrown, "accessibilityParameterizedAttributeNames", pastEnd: false)
                }
            }
            for attribute in parameterizedAttributes where element.responds(to: parameterized) {
                for (parameter, label, pastEnd) in parameters(for: attribute, length: length, point: point) {
                    result.reads += 1
                    if let thrown = PBCatchException({ _ = element.perform(parameterized, with: attribute as NSString, with: parameter) }) {
                        record(thrown, attribute + " " + label, pastEnd: pastEnd)
                    }
                }
            }
        }
        return result
    }

    /// The parameters a client asks a parameterized attribute with: a range, an index or a line
    /// inside the text and one just past it, or a point on the field.
    private static func parameters(for attribute: String, length: Int, point: NSPoint) -> [(NSObject, String, Bool)] {
        if attribute.hasSuffix("ForRange") {
            let whole = NSRange(location: 0, length: length)
            let last = NSRange(location: max(length - 1, 0), length: length > 0 ? 1 : 0)
            let past = NSRange(location: length, length: 1)
            return [(NSValue(range: whole), "{0,\(length)}", false), (NSValue(range: last), "{\(last.location),\(last.length)}", false),
                    (NSValue(range: past), "{\(length),1}", true)]
        }
        if attribute.hasSuffix("ForIndex") || attribute.hasSuffix("ForLine") {
            return [(NSNumber(value: 0), "0", false), (NSNumber(value: length), "\(length)", false), (NSNumber(value: length + 1), "\(length + 1)", true)]
        }
        if attribute.hasSuffix("ForPosition") || attribute.hasSuffix("ForScreenPoint") || attribute.hasSuffix("ForPoint") {
            return [(NSValue(point: point), "the field's middle", false)]
        }
        return []
    }
}
