import AppKit
import ObjCExceptions

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
        /// The search providers Safari's chrome has here, as they describe themselves.
        var providers = ""

        var json: String {
            guard let data = try? JSONEncoder().encode(self) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Text that starts with this is composed as an input method composes it instead (marked text,
    /// then the composed text inserted), in the field editor, rather than typed key by key.
    static let composedPrefix = "ime:"

    static func type(_ given: String, into field: NSTextField, in window: NSWindow) async -> Report {
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
        report.caughtByTypingGuard = SafariTypingGuard.caught - guardBefore
        report.field = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        report.providers = SafariChrome.searchProvidersDescription()
        // The field left as it was found: empty, and not editing.
        _ = PBCatchException {
            (field.currentEditor() as? NSTextView)?.string = ""
            window.makeFirstResponder(nil)
        }
        return report
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
