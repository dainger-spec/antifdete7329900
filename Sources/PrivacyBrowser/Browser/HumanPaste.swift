import AppKit
import BrowserCore
import WebKit

/// Paste as Typed (⌃⌘V, Edit menu): the clipboard's text typed into the field that has the focus
/// in the page — a key down and up per character, on the key a Mac layout has for it, Shift
/// pressed and released around a capital, with a person's pauses (`HumanTyping`). Real key events
/// through the window, as the keyboard's: the page sees trusted keydown, input and keyup events,
/// so a site that refuses a field filled in at once sees typing.
@MainActor
enum HumanPaste {
    enum Outcome: Equatable {
        case typed(Int)
        case nothingToPaste
        case tooLong(Int)
        /// The page has no editable field focused, or the keyboard is not the page's (the address
        /// bar has it, say).
        case notAField
        /// Stopped after this many characters: a key or a click of the user's, or the web view lost
        /// the keyboard (another window, another tab).
        case interrupted(Int)
    }

    /// The text being typed, one at a time.
    private static var typing: Task<Void, Never>?

    /// ⌃⌘V: the clipboard's text into the web view that has the keyboard in the key window — a
    /// window of ours, or Safari's own in a profile's process — and a word when not all of it was.
    static func pasteIntoKeyWindow() {
        guard typing == nil, let window = NSApp.keyWindow else { return }
        var view = window.firstResponder as? NSView
        while let current = view, !(current is WKWebView) { view = current.superview }
        guard let webView = view as? WKWebView else {
            explain(.notAField, in: window)
            return
        }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        typing = Task {
            let outcome = await type(text, into: webView)
            typing = nil
            explain(outcome, in: window)
        }
    }

    /// Says, in a sheet on `window`, why nothing or not everything was typed; nothing when all was.
    static func explain(_ outcome: Outcome, in window: NSWindow) {
        let message: String
        switch outcome {
        case .typed: return
        case .nothingToPaste: message = L("paste.typed.nothing")
        case let .tooLong(count): message = String(format: L("paste.typed.tooLong"), HumanTyping.maximumLength, count)
        case .notAField: message = L("paste.typed.notAField")
        case let .interrupted(count): message = String(format: L("paste.typed.interrupted"), count)
        }
        let alert = NSAlert()
        alert.messageText = L("menu.pasteAsTyped")
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    /// Types `text` into the field focused in `webView`'s page; `speed` > 1 types faster (the
    /// self-test's). Only while the web view has the keyboard, as a person's typing can only go
    /// where the keyboard is.
    static func type(_ text: String, into webView: WKWebView, speed: Double = 1) async -> Outcome {
        guard !text.isEmpty else { return .nothingToPaste }
        guard text.count <= HumanTyping.maximumLength else { return .tooLong(text.count) }
        guard let window = webView.window, hasKeyboard(webView, in: window), await hasFocusedField(webView) else {
            return .notAField
        }
        // The user's own key presses and clicks reach the app through NSApp; the typed keys go to
        // the window directly and are not seen here. Either of the user's stops the typing.
        let user = UserInput()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if !(event.type == .keyDown && event.isARepeat) { user.arrived = true }
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        // As a person: the shortcut's keys let go first, then a moment before the first key.
        let released = Date().addingTimeInterval(2)
        while !NSEvent.modifierFlags.isDisjoint(with: [.command, .control, .option]), Date() < released {
            await pause(0.05)
        }
        await pause(Double.random(in: 0.15...0.4) / speed)
        var generator = SystemRandomNumberGenerator()
        let plan = HumanTyping.plan(text, using: &generator)
        var typed = 0
        for stroke in plan {
            await pause(stroke.pauseBefore / speed)
            guard !user.arrived, hasKeyboard(webView, in: window) else { return .interrupted(typed) }
            if let code = stroke.keyCode {
                if stroke.shift { shift(down: true, in: window) }
                key(.keyDown, stroke, code: code, in: window)
                await pause(stroke.hold / speed)
                key(.keyUp, stroke, code: code, in: window)
                if stroke.shift { shift(down: false, in: window) }
            } else {
                // No key types it here: given as text input, as an input method commits it.
                webView.insertText(stroke.text)
            }
            typed += 1
        }
        return .typed(typed)
    }

    /// The keyboard's keys go to `webView`: its window is the key window and the web view is the
    /// window's first responder.
    static func hasKeyboard(_ webView: WKWebView, in window: NSWindow) -> Bool {
        webView.window === window && window.isKeyWindow
            && (window.firstResponder as? NSView)?.isDescendant(of: webView) == true
    }

    /// The page's focused element takes text: an input of a text kind, a text area, an editable
    /// element, or a frame (whose field the keys go to).
    static func hasFocusedField(_ webView: WKWebView) async -> Bool {
        let script = """
        const e = document.activeElement;
        if (!e) return false;
        if (e.isContentEditable || e.tagName === 'IFRAME') return true;
        if (e.tagName === 'TEXTAREA') return !e.disabled && !e.readOnly;
        if (e.tagName !== 'INPUT') return false;
        const kind = (e.getAttribute('type') || 'text').toLowerCase();
        return !e.disabled && !e.readOnly && ['text', 'search', 'email', 'url', 'tel', 'password', 'number'].includes(kind);
        """
        // In a world of the app's own: the page's scripts can neither see nor change the question.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(returning: (try? result.get()) as? Bool == true)
            }
        }
    }

    /// A key down or up as the keyboard gives it: the characters it types, also as the characters
    /// "ignoring modifiers" (which still apply Shift: Shift-1 is "!" in both), on its key code.
    private static func key(_ type: NSEvent.EventType, _ stroke: HumanTyping.Keystroke, code: UInt16, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: stroke.shift ? .shift : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: stroke.text, charactersIgnoringModifiers: stroke.text,
                                           isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    /// The left Shift key, down or up (a modifier change, as the keyboard sends it).
    private static func shift(down: Bool, in window: NSWindow) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x38, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskShift : []
        guard let flags = NSEvent(cgEvent: event) else { return }
        window.sendEvent(flags)
    }

    private static func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Whether a key press or a click of the user's has come while Paste as Typed types.
@MainActor
private final class UserInput {
    var arrived = false
}
