import AppKit
import Carbon.HIToolbox
import Foundation
import os
import WebKit

/// The app's own pointer, wheel and keyboard on a page: the one way the warm-up robot and
/// automation act on a page, so that the page sees what a person's mouse and keyboard give it
/// (docs/PAGE_INPUT.md). Events are made by AppKit and given to the web
/// view in this process; nothing is posted to the system's event stream, so the real cursor and
/// keyboard, and other apps, are left alone.
///
/// What a page would otherwise see, measured against the system's own events (HID) on macOS 26
/// and 27 (`measure/automation_input`, claude/measure-automation-input, rounds 1–5), and what is
/// done about each:
/// * **Pointer moves.** `WKWebView` takes no `mouseMoved:` of its own: WebKit takes moves from the
///   owner of its tracking area only, which AppKit calls when the real cursor moves. Moves given
///   to the view are dropped, and a click then comes out of nowhere (`pointerover` in the same
///   millisecond as `pointerdown`). They are given to that owner (`trackingAreas`, `owner`,
///   `mouseMoved:`: public).
/// * **Button state.** WebKit reads the buttons held from `NSEvent.pressedMouseButtons`, the real
///   mouse's: `buttons` 0 and `pressure` 0 on a `pointerdown`. While this input holds a button,
///   that answers it.
/// * **Wheel time and place.** A wheel event made from a Quartz event has time 0 unless given one,
///   and no window, so WebKit puts it at the screen's corner (`screenX/Y` 0/768). It is given the
///   system's clock, and `NSEvent.window` answers the web view's window for it while it is handled,
///   its location being the window's own point.
/// * **Focus.** In a window that is not the key one (another app in front), WebKit tells the page
///   it has no focus, and a click given to the window activates it instead of reaching the page.
///   `holdFocus` makes `isKeyWindow` answer true for the window and tells WebKit (the
///   notification it listens for), so the page keeps its focus; clicks and keys are given to the
///   web view itself.
///
/// The answers are given in this process only, and only for this input's own events and held
/// windows; everything else gets AppKit's own.
@MainActor
final class PageInput {
    /// A fix left out (self-test only): each must turn its own check red.
    enum Fault: String, CaseIterable {
        case moves
        case buttons
        case wheelTime
        case wheelPlace
        case focus
    }

    /// Set by the self-test alone.
    static var fault: Fault?

    private static let log = Logger(subsystem: "PrivacyBrowser", category: "PageInput")

    weak var webView: WKWebView?
    /// Where the pointer last was, in the web view's window (AppKit's points, bottom-left origin).
    private(set) var pointer: NSPoint?
    /// Mouse events since the last button press, for the click count of a double click.
    private var lastClick: (at: TimeInterval, location: NSPoint, count: Int)?

    init(webView: WKWebView) {
        self.webView = webView
        Self.installAnswers()
    }

    // MARK: Points

    /// The web view's window point of the viewport point `point` (CSS pixels from the viewport's
    /// top left).
    func windowPoint(ofViewport point: CGPoint) -> NSPoint? {
        guard let webView, webView.window != nil else { return nil }
        let scale = webView.pageZoom * webView.magnification
        let x = point.x * scale, y = point.y * scale
        let inView = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        return webView.convert(inView, to: nil)
    }

    // MARK: Pointer

    /// Moves the pointer to the viewport point `point` along `path` (viewport points, the last of
    /// which should be `point`), waiting `interval` between moves. False when the web view has no
    /// window.
    @discardableResult
    func move(along path: [CGPoint], interval: TimeInterval) async -> Bool {
        for point in path {
            guard let location = windowPoint(ofViewport: point) else { return false }
            mouse(.mouseMoved, at: location)
            if interval > 0 { try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
        }
        return true
    }

    /// A straight path of `steps` points from where the pointer is (or `start`, the first time)
    /// to `point`, eased at both ends, with the fractions of a point a real pointer has.
    func path(to point: CGPoint, from start: CGPoint, steps: Int) -> [CGPoint] {
        let from = pointerViewportPoint() ?? start
        let count = max(1, steps)
        return (1...count).map { step in
            let t = Double(step) / Double(count)
            let eased = t * t * (3 - 2 * t)
            return CGPoint(x: from.x + (point.x - from.x) * eased, y: from.y + (point.y - from.y) * eased)
        }
    }

    /// The pointer's place in viewport points, if it has one.
    func pointerViewportPoint() -> CGPoint? {
        guard let webView, let pointer else { return nil }
        let inView = webView.convert(pointer, from: nil)
        let scale = webView.pageZoom * webView.magnification
        guard scale > 0 else { return nil }
        let y = webView.isFlipped ? inView.y : webView.bounds.height - inView.y
        return CGPoint(x: inView.x / scale, y: y / scale)
    }

    /// Presses the left button where the pointer is. `clickCount` names the press's place in a
    /// double or triple click; nil counts as AppKit does (a press soon after the last, near it).
    func press(clickCount: Int? = nil) {
        guard let pointer else { return }
        mouse(.leftMouseDown, at: pointer, clickCount: clickCount)
    }

    /// Lets the left button go where the pointer is.
    func release() {
        guard let pointer else { return }
        mouse(.leftMouseUp, at: pointer)
    }

    /// Presses and lets go, holding the button `hold` seconds.
    func click(hold: TimeInterval, clickCount: Int? = nil) async {
        await takeFirstResponder()
        press(clickCount: clickCount)
        try? await Task.sleep(nanoseconds: UInt64(max(0, hold) * 1_000_000_000))
        release()
    }

    /// Makes the web view its window's first responder, as a window does for the view clicked,
    /// a beat before the press: WebKit tells the page it has focus a little later, and a press sent
    /// at once would come first (measured: hasFocus false at that first press, round 6 and CI
    /// 42613676137; a real click gave false on macOS 26 and true on 27).
    func takeFirstResponder() async {
        guard Self.fault != .focus, let webView, let window = webView.window else { return }
        let responder = window.firstResponder as? NSView
        if let responder, responder === webView || responder.isDescendant(of: webView) { return }
        window.makeFirstResponder(webView)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func mouse(_ type: NSEvent.EventType, at location: NSPoint, clickCount forced: Int? = nil) {
        guard let webView, let window = webView.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var clickCount = 0
        if type == .leftMouseDown {
            // A second press soon after the first, near it, is a double click (as AppKit counts).
            if let forced {
                clickCount = max(1, forced)
            } else if let last = lastClick, now - last.at <= NSEvent.doubleClickInterval,
               abs(last.location.x - location.x) <= 4, abs(last.location.y - location.y) <= 4 {
                clickCount = last.count + 1
            } else {
                clickCount = 1
            }
            lastClick = (now, location, clickCount)
            if Self.fault != .buttons { Answers.buttons = 1 }
        } else if type == .leftMouseUp {
            clickCount = lastClick?.count ?? 1
            Answers.buttons = 0
        }
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: now,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0) else { return }
        pointer = location
        switch type {
        case .mouseMoved:
            if Self.fault == .moves {
                webView.mouseMoved(with: event)
                return
            }
            // WebKit's own way in for moves: the owner of the web view's tracking area.
            var reached = Set<ObjectIdentifier>()
            for area in webView.trackingAreas {
                guard let owner = area.owner as? NSObject, owner !== webView,
                      reached.insert(ObjectIdentifier(owner)).inserted,
                      owner.responds(to: #selector(NSResponder.mouseMoved(with:))) else { continue }
                owner.perform(#selector(NSResponder.mouseMoved(with:)), with: event)
            }
            if reached.isEmpty {
                Self.log.notice("The web view has no tracking area owner; the move is given to the view")
                webView.mouseMoved(with: event)
            }
        case .leftMouseDown:
            if Self.fault == .focus {
                window.sendEvent(event)
                return
            }
            // A window makes the view clicked its first responder before the press reaches it
            // (the page then has focus at its pointerdown, as with a person's click).
            let responder = window.firstResponder as? NSView
            if responder == nil || !(responder === webView || responder!.isDescendant(of: webView)) {
                window.makeFirstResponder(webView)
            }
            webView.mouseDown(with: event)
        case .leftMouseUp:
            if Self.fault == .focus { window.sendEvent(event) } else { webView.mouseUp(with: event) }
        default:
            break
        }
    }

    // MARK: Wheel

    /// One wheel event of `delta` points (positive: down) where the pointer is (or at the middle
    /// of the web view), as a mouse with smooth scrolling sends it. False when it could not be made.
    @discardableResult
    func wheel(_ delta: Double, horizontal: Double = 0) -> Bool {
        guard let webView, let window = webView.window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: horizontal == 0 ? 1 : 2,
                                  wheel1: Int32(-delta.rounded()), wheel2: Int32(-horizontal.rounded()), wheel3: 0) else { return false }
        let location = pointer ?? webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        if Self.fault != .wheelTime {
            // The time the system gives its own events: nanoseconds since boot.
            event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        if Self.fault == .wheelPlace {
            // The old way: the screen point, no window.
            let onScreen = window.convertPoint(toScreen: location)
            event.location = CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
        } else {
            // A windowless event's location is read bottom-up against the main screen; with its
            // window answered as this one, it is read as the window's own point.
            event.location = CGPoint(x: location.x, y: mainHeight - location.y)
        }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let wheel = NSEvent(cgEvent: event) else { return false }
        if Self.fault != .wheelPlace {
            Answers.wheel = wheel
            Answers.wheelWindow = window
        }
        defer {
            Answers.wheel = nil
            Answers.wheelWindow = nil
        }
        webView.scrollWheel(with: wheel)
        return true
    }

    // MARK: Keyboard

    /// A key as a keyboard gives it: its virtual key code, the characters it types (with and
    /// without modifiers), and the modifiers held.
    struct Key: Equatable {
        var code: UInt16
        var characters: String
        /// As AppKit gives it: without the modifiers but Shift.
        var charactersIgnoringModifiers: String
        var modifiers: NSEvent.ModifierFlags
    }

    /// Named keys (US codes; the same on every layout).
    static let named: [String: Key] = [
        "Enter": Key(code: UInt16(kVK_Return), characters: "\r", charactersIgnoringModifiers: "\r", modifiers: []),
        "Tab": Key(code: UInt16(kVK_Tab), characters: "\t", charactersIgnoringModifiers: "\t", modifiers: []),
        "Backspace": Key(code: UInt16(kVK_Delete), characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", modifiers: []),
        "Escape": Key(code: UInt16(kVK_Escape), characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", modifiers: []),
        "Space": Key(code: UInt16(kVK_Space), characters: " ", charactersIgnoringModifiers: " ", modifiers: []),
        "ArrowLeft": Key(code: UInt16(kVK_LeftArrow), characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", modifiers: [.function, .numericPad]),
        "ArrowRight": Key(code: UInt16(kVK_RightArrow), characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", modifiers: [.function, .numericPad]),
        "ArrowUp": Key(code: UInt16(kVK_UpArrow), characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", modifiers: [.function, .numericPad]),
        "ArrowDown": Key(code: UInt16(kVK_DownArrow), characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", modifiers: [.function, .numericPad]),
    ]

    /// The key of the current keyboard layout that types `character`, with Shift or Option if it
    /// needs them; nil when no key of this layout types it.
    static func key(typing character: Character) -> Key? {
        if character == " " { return named["Space"] }
        if character == "\n" || character == "\r" { return named["Enter"] }
        if character == "\t" { return named["Tab"] }
        return Layout.current().key(for: String(character))
    }

    /// Presses and lets go of `key`, with its modifier keys pressed before and let go after (as a
    /// person's fingers do), holding it `hold` seconds.
    func press(_ key: Key, hold: TimeInterval, gap: TimeInterval = 0.03) async {
        let modifierKeys = Self.modifierKeys(of: key.modifiers)
        var held: NSEvent.ModifierFlags = []
        for (flag, code) in modifierKeys {
            held.insert(flag)
            flagsChanged(code: code, flags: held)
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
        }
        keyEvent(.keyDown, key, flags: held.union(key.modifiers.intersection([.function, .numericPad])))
        try? await Task.sleep(nanoseconds: UInt64(max(0, hold) * 1_000_000_000))
        keyEvent(.keyUp, key, flags: held.union(key.modifiers.intersection([.function, .numericPad])))
        for (flag, code) in modifierKeys.reversed() {
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            held.remove(flag)
            flagsChanged(code: code, flags: held)
        }
    }

    private static func modifierKeys(of flags: NSEvent.ModifierFlags) -> [(NSEvent.ModifierFlags, UInt16)] {
        var keys: [(NSEvent.ModifierFlags, UInt16)] = []
        if flags.contains(.command) { keys.append((.command, UInt16(kVK_Command))) }
        if flags.contains(.control) { keys.append((.control, UInt16(kVK_Control))) }
        if flags.contains(.option) { keys.append((.option, UInt16(kVK_Option))) }
        if flags.contains(.shift) { keys.append((.shift, UInt16(kVK_Shift))) }
        return keys
    }

    private func keyEvent(_ type: NSEvent.EventType, _ key: Key, flags: NSEvent.ModifierFlags) {
        guard let webView, let window = webView.window,
              let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                           isARepeat: false, keyCode: key.code) else { return }
        if Self.fault == .focus {
            window.sendEvent(event)
        } else if type == .keyDown {
            webView.keyDown(with: event)
        } else {
            webView.keyUp(with: event)
        }
    }

    private func flagsChanged(code: UInt16, flags: NSEvent.ModifierFlags) {
        guard let webView, let window = webView.window,
              let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: "", charactersIgnoringModifiers: "",
                                           isARepeat: false, keyCode: code) else { return }
        if Self.fault == .focus { window.sendEvent(event) } else { webView.flagsChanged(with: event) }
    }

    // MARK: Focus

    /// Keeps the page of `window` focused while another window or app is in front, until
    /// `releaseFocus`. Nothing to do for the key window itself.
    func holdFocus() {
        guard Self.fault != .focus, let window = webView?.window, heldWindow !== window else { return }
        if heldWindow != nil { releaseFocus() }
        let identifier = ObjectIdentifier(window)
        let first = Answers.heldWindows[identifier] == nil
        Answers.heldWindows[identifier, default: 0] += 1
        heldWindow = window
        // What WebKit listens for to read the window's key state again.
        if first && !window.isKeyWindowUnanswered {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }

    /// The window `holdFocus` held: AppKit's own answer again, and WebKit told when that is "not key".
    func releaseFocus() {
        guard let window = heldWindow else { return }
        heldWindow = nil
        Self.letGo(window)
    }

    private weak var heldWindow: NSWindow?

    private static func letGo(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        let count = (Answers.heldWindows[identifier] ?? 1) - 1
        Answers.heldWindows[identifier] = count > 0 ? count : nil
        if count <= 0 && !window.isKeyWindow {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    deinit {
        // A window still held is let go with its input, on the main actor.
        weak var window = heldWindow
        guard window != nil else { return }
        Task { @MainActor in
            if let window { PageInput.letGo(window) }
        }
    }

    // MARK: Answers in this process

    /// What the replaced methods answer; main thread only (AppKit's events are handled there).
    fileprivate enum Answers {
        static var buttons = 0
        static var wheel: NSEvent?
        static weak var wheelWindow: NSWindow?
        static var heldWindows: [ObjectIdentifier: Int] = [:]
        static var installed = false
    }

    private static func installAnswers() {
        guard !Answers.installed else { return }
        Answers.installed = true
        // The buttons held: the real mouse's, or this input's while it holds one.
        let pressed = #selector(getter: NSEvent.pressedMouseButtons)
        if let method = class_getClassMethod(NSEvent.self, pressed) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let replacement: @convention(block) (AnyObject) -> Int = { receiver in
                let real = original(receiver, pressed)
                return Thread.isMainThread && Answers.buttons != 0 ? real | Answers.buttons : real
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            log.error("NSEvent.pressedMouseButtons not found: pages see no button held during this input's presses")
        }
        // The window of this input's wheel event while it is handled.
        let windowGetter = #selector(getter: NSEvent.window)
        if let method = class_getInstanceMethod(NSEvent.self, windowGetter) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSWindow?
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let replacement: @convention(block) (AnyObject) -> NSWindow? = { event in
                if Thread.isMainThread, let wheel = Answers.wheel, event === wheel, let window = Answers.wheelWindow { return window }
                return original(event, windowGetter)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            log.error("NSEvent.window not found: wheel events keep no window")
        }
        // A held window is the key one for whoever asks in this process (WebKit does).
        let keyGetter = #selector(getter: NSWindow.isKeyWindow)
        if let method = class_getInstanceMethod(NSWindow.self, keyGetter) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            NSWindow.unansweredIsKeyWindow = { original($0, keyGetter) }
            let replacement: @convention(block) (AnyObject) -> Bool = { window in
                if Thread.isMainThread, !Answers.heldWindows.isEmpty, Answers.heldWindows[ObjectIdentifier(window)] != nil { return true }
                return original(window, keyGetter)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        } else {
            log.error("NSWindow.isKeyWindow not found: a window out of front cannot keep its page's focus")
        }
    }
}

extension NSWindow {
    /// AppKit's own answer, before `PageInput`'s held windows.
    fileprivate static var unansweredIsKeyWindow: ((NSWindow) -> Bool)?

    fileprivate var isKeyWindowUnanswered: Bool { Self.unansweredIsKeyWindow?(self) ?? isKeyWindow }
}

// MARK: Keyboard layout

/// The current keyboard layout's keys, read with `UCKeyTranslate`: which key (and which of Shift
/// and Option) types a character.
private struct Layout {
    private var keys: [String: PageInput.Key] = [:]

    private static var cached: (id: String, layout: Layout)?

    static func current() -> Layout {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return Layout() }
        let id: String = property(source, kTISPropertyInputSourceID) ?? "?"
        if let cached, cached.id == id { return cached.layout }
        let layout = Layout(source)
        cached = (id, layout)
        return layout
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    private init() {}

    private init(_ source: TISInputSource) {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        // Plain, then Shift, then Option, then both: the first way that types a character wins.
        let ways: [(NSEvent.ModifierFlags, UInt32)] = [([], 0), (.shift, UInt32(shiftKey >> 8)),
                                                        (.option, UInt32(optionKey >> 8)), ([.shift, .option], UInt32((shiftKey | optionKey) >> 8))]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func type(_ code: UInt16, _ modifiers: UInt32) -> String? {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let capacity = characters.count
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, capacity, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
            for (flags, modifiers) in ways {
                for code in UInt16(0)..<UInt16(128) {
                    guard let typed = type(code, modifiers), typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
                          keys[typed] == nil else { continue }
                    // AppKit's characters without modifiers keep Shift.
                    let ignoring = type(code, flags.contains(.shift) ? UInt32(shiftKey >> 8) : 0) ?? typed
                    keys[typed] = PageInput.Key(code: code, characters: typed, charactersIgnoringModifiers: ignoring, modifiers: flags)
                }
            }
        }
    }

    func key(for character: String) -> PageInput.Key? { keys[character] }
}
