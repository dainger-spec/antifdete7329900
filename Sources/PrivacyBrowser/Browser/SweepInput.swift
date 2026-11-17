import AppKit
import Carbon.HIToolbox
import Foundation

/// The tag on every event the sweep posts (`SweepInput`), so that the process can tell its own
/// events arriving from anything else.
let sweepEventTag: Int64 = 0x5042_5357

/// Real input for the sweep (`SafariSweep`): Quartz events posted to the window server at the
/// HID level, as a keyboard and a mouse make them. They reach the profile's process as a person's
/// do — through the window server, the input source (keyboard layout or input method) that is
/// selected, `-[NSApplication sendEvent:]` of Safari's own application object, the menu bar's key
/// equivalents and the key window — which no check did before: the self-test, the window audit and
/// the address bar's check hand AppKit events they make themselves to the window or a view, and the
/// menu walk chooses items with `performActionForItemAtIndex:`.
///
/// When the window server does not deliver them (a Mac where the process may not post events), the
/// sweep says so and posts them to this process (`postToPid`), and failing that puts them in
/// AppKit's own queue (`NSApp.postEvent`): `route` says which, and every unit says how many of its
/// key presses and clicks arrived. Used by the sweep only, never by the app.
@MainActor
enum SweepInput {
    enum Route: String { case hid, pid, queue }

    static var route = Route.hid
    private static var monitor: Any?
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Counts the sweep's own key presses, clicks and wheel events as they arrive.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == sweepEventTag { SweepRecord.noteArrived() }
            return event
        }
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Which way the window server takes the sweep's events into this process: a key that does
    /// nothing (F19) by each route in turn until one arrives.
    static func chooseRoute(clickingAt point: NSPoint?) async -> String {
        install()
        var said: [String] = []
        for candidate in [Route.hid, Route.pid, Route.queue] {
            route = candidate
            let before = SweepRecord.arrivedCount
            await press(kVK_F19)
            await pause(0.6)
            if SweepRecord.arrivedCount > before { return said.isEmpty ? candidate.rawValue : candidate.rawValue + " (" + said.joined(separator: "; ") + ")" }
            if candidate == .hid, let point {
                // Not in front, perhaps: a click on the window brings it, as a person's does.
                await click(point)
                await pause(0.5)
                await press(kVK_F19)
                await pause(0.6)
                if SweepRecord.arrivedCount > before { return "hid, after a click on the window" }
            }
            said.append("\(candidate.rawValue): nothing arrived")
        }
        route = .queue
        return "queue (" + said.joined(separator: "; ") + ")"
    }

    // MARK: Posting

    private static func post(_ event: CGEvent, counted: Bool) {
        event.setIntegerValueField(.eventSourceUserData, value: sweepEventTag)
        if counted { SweepRecord.notePosted() }
        switch route {
        case .hid:
            event.post(tap: .cghidEventTap)
        case .pid:
            event.postToPid(getpid())
        case .queue:
            if let made = NSEvent(cgEvent: event) { NSApp.postEvent(made, atStart: false) }
        }
    }

    static let arrowKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    static let functionKeys: Set<Int> = [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_F1, kVK_F2,
                                         kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F19]

    private static func modifierKeys(_ flags: CGEventFlags) -> [(Int, CGEventFlags)] {
        var keys: [(Int, CGEventFlags)] = []
        if flags.contains(.maskCommand) { keys.append((kVK_Command, .maskCommand)) }
        if flags.contains(.maskControl) { keys.append((kVK_Control, .maskControl)) }
        if flags.contains(.maskAlternate) { keys.append((kVK_Option, .maskAlternate)) }
        if flags.contains(.maskShift) { keys.append((kVK_Shift, .maskShift)) }
        return keys
    }

    private static func keyEvent(_ code: Int, down: Bool, flags: CGEventFlags, text: String?, modifierOnly: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        if modifierOnly { event.type = .flagsChanged }
        event.flags = flags
        if let text {
            var units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        post(event, counted: down && !modifierOnly)
    }

    /// One key pressed and let go, with `modifiers` held around it as fingers hold them. `text`:
    /// the characters it types, given with the event instead of taken from the keyboard layout.
    static func press(_ code: Int, _ modifiers: CGEventFlags = [], text: String? = nil) async {
        let held = modifierKeys(modifiers)
        var flags: CGEventFlags = []
        for (key, flag) in held {
            flags.insert(flag)
            keyEvent(key, down: true, flags: flags, text: nil, modifierOnly: true)
            await pause(0.02)
        }
        var keyFlags = flags
        if arrowKeys.contains(code) {
            keyFlags.insert(.maskSecondaryFn)
            keyFlags.insert(.maskNumericPad)
        } else if functionKeys.contains(code) {
            keyFlags.insert(.maskSecondaryFn)
        }
        keyEvent(code, down: true, flags: keyFlags, text: text, modifierOnly: false)
        await pause(0.03)
        keyEvent(code, down: false, flags: keyFlags, text: text, modifierOnly: false)
        for (key, flag) in held.reversed() {
            await pause(0.02)
            flags.remove(flag)
            keyEvent(key, down: false, flags: flags, text: nil, modifierOnly: true)
        }
        await pause(0.05)
    }

    /// Text typed key by key on the keyboard layout that is selected; a character no key of it
    /// types goes as a key event that carries it (as the system's own character viewer types).
    static func type(_ text: String, gap: Double = 0.07) async {
        for character in text {
            if let key = PageInput.key(typing: character) {
                var flags: CGEventFlags = []
                if key.modifiers.contains(.shift) { flags.insert(.maskShift) }
                if key.modifiers.contains(.option) { flags.insert(.maskAlternate) }
                await press(Int(key.code), flags)
            } else {
                await press(0, [], text: String(character))
            }
            await pause(gap)
        }
    }

    /// Text typed as key events that carry their characters, whatever the layout.
    static func typeCarried(_ text: String, gap: Double = 0.07) async {
        for character in text {
            await press(0, [], text: String(character))
            await pause(gap)
        }
    }

    /// The keys of an ANSI keyboard, by the character they type without Shift: what a menu's key
    /// equivalent is pressed with whatever the layout (AppKit matches key equivalents against the
    /// layout's ASCII-capable sibling, as a Russian layout's ⌘T is the key of T).
    static let ansiKeys: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]

    /// Shifted characters, by the key's own character.
    static let shiftedKeys: [Character: Character] = [
        "{": "[", "}": "]", "+": "=", "_": "-", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]

    /// The key and whether it needs Shift for a menu item's key equivalent; nil when it names no key.
    static func key(forEquivalent equivalent: String) -> (code: Int, shift: Bool)? {
        guard let scalar = equivalent.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0xF700: return (kVK_UpArrow, false)
        case 0xF701: return (kVK_DownArrow, false)
        case 0xF702: return (kVK_LeftArrow, false)
        case 0xF703: return (kVK_RightArrow, false)
        case 0xF704: return (kVK_F1, false)
        case 0xF705: return (kVK_F2, false)
        case 0xF706: return (kVK_F3, false)
        case 0xF707: return (kVK_F4, false)
        case 0xF708: return (kVK_F5, false)
        case 0xF709: return (kVK_F6, false)
        case 0xF728: return (kVK_ForwardDelete, false)
        case 0xF729: return (kVK_Home, false)
        case 0xF72B: return (kVK_End, false)
        case 0xF72C: return (kVK_PageUp, false)
        case 0xF72D: return (kVK_PageDown, false)
        case 0x1B: return (kVK_Escape, false)
        case 0x0D, 0x03: return (kVK_Return, false)
        case 0x08, 0x7F: return (kVK_Delete, false)
        case 0x09, 0x19: return (kVK_Tab, false)
        default: break
        }
        guard let character = equivalent.first else { return nil }
        let lower = String(character).lowercased().first ?? character
        if let code = ansiKeys[lower] { return (code, lower != character) }
        if let base = shiftedKeys[character], let code = ansiKeys[base] { return (code, true) }
        return nil
    }

    // MARK: The mouse

    /// A point of AppKit's screen space in the window server's (its origin at the top left).
    static func quartzPoint(_ point: NSPoint) -> CGPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: top - point.y)
    }

    private static func mouse(_ type: CGEventType, at point: NSPoint, button: CGMouseButton, state: Int, counted: Bool) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: quartzPoint(point),
                                  mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(state))
        post(event, counted: counted)
    }

    static func move(to point: NSPoint) async {
        mouse(.mouseMoved, at: point, button: .left, state: 0, counted: false)
        await pause(0.08)
    }

    /// A click (or a double click, `times` 2) at `point`, in AppKit's screen space.
    static func click(_ point: NSPoint, right: Bool = false, times: Int = 1) async {
        await move(to: point)
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for count in 1...max(1, times) {
            mouse(down, at: point, button: button, state: count, counted: true)
            await pause(0.05)
            mouse(up, at: point, button: button, state: count, counted: false)
            await pause(0.07)
        }
    }

    /// The wheel turned `lines` lines over `point` (negative: down the page).
    static func scroll(at point: NSPoint, lines: Int32) async {
        await move(to: point)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        post(event, counted: true)
        await pause(0.15)
    }

    // MARK: Input sources

    static func inputSourceID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(current, kTISPropertyInputSourceID)
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Selects the input source `id` — a keyboard layout or an input method — enabling it first,
    /// as a person adds one in System Settings and picks it in the menu bar. Nil when this Mac
    /// does not have it; else what was done.
    @discardableResult
    static func selectInputSource(_ id: String) -> String? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let found = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else { return nil }
        let list = found as NSArray
        guard list.count > 0 else { return nil }
        let chosen = list[0] as! TISInputSource
        let enabled = TISEnableInputSource(chosen)
        let selected = TISSelectInputSource(chosen)
        return "enabled \(enabled), selected \(selected), now \(inputSourceID() ?? "?")"
    }
}

/// What happened while one unit of the sweep ran — written from AppKit's callbacks, the exception
/// hooks and the watchdog's thread as well as the main actor; behind a lock.
final class SweepRecord: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lists: [String: [String]] = [:]
    nonisolated(unsafe) private static var hangs: [Double] = []
    nonisolated(unsafe) private static var posted = 0
    nonisolated(unsafe) private static var arrived = 0

    static func add(_ kind: String, _ text: String) {
        lock.withLock {
            var list = lists[kind] ?? []
            if list.count < 60 { list.append(String(text.prefix(1500))) }
            lists[kind] = list
        }
    }

    static func addHang(_ seconds: Double) {
        lock.withLock { hangs.append((seconds * 10).rounded() / 10) }
    }

    static func notePosted() { lock.withLock { posted += 1 } }
    static func noteArrived() { lock.withLock { arrived += 1 } }
    static var arrivedCount: Int { lock.withLock { arrived } }

    /// Everything since the last call, and emptied.
    static func take() -> [String: Any] {
        lock.withLock { () -> [String: Any] in
            var taken: [String: Any] = [:]
            for (kind, list) in lists { taken[kind] = list }
            taken["hangs"] = hangs
            taken["posted"] = posted
            taken["arrived"] = arrived
            lists = [:]
            hangs = []
            posted = 0
            arrived = 0
            return taken
        }
    }

    /// An exception as it was thrown: its name, its reason as the log has it, and the frames below
    /// the throw, each as its image and symbol.
    static func describeThrow(_ name: String, _ reason: String, _ frames: [String]) -> String {
        var compact = frames.map(compactFrame)
        if let throwAt = compact.lastIndex(where: { $0.contains("objc_exception_throw") || $0.contains("NSException raise") }) {
            compact = Array(compact[(throwAt + 1)...])
        }
        return "\(name): \(reason.prefix(300)) | " + compact.prefix(22).joined(separator: " / ")
    }

    private static func compactFrame(_ frame: String) -> String {
        let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return frame }
        return String(parts[1]) + " " + parts.dropFirst(3).joined(separator: " ")
    }
}

/// The main thread's pulse while the sweep runs: a timer on it in every run loop mode marks each
/// tenth of a second, and a thread of its own looks. A gap over two seconds is a hang: said at once
/// from the thread (so that the manager's side can take the main thread's stack while it lasts),
/// and its length added to the unit when the main thread is back.
final class SweepWatchdog: @unchecked Sendable {
    static let shared = SweepWatchdog()
    private let lock = NSLock()
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var reported = false
    private var started = false
    private var step = -1
    private var report: (@Sendable (Int, Double) -> Void)?

    func start(report: @escaping @Sendable (Int, Double) -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            self.report = report
            lastTick = ProcessInfo.processInfo.systemUptime
            return !started
        }
        guard first else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in SweepWatchdog.shared.tick() }
        RunLoop.main.add(timer, forMode: .common)
        let thread = Thread { SweepWatchdog.shared.watch() }
        thread.name = "PBSweepWatchdog"
        thread.start()
    }

    func setStep(_ index: Int) {
        lock.withLock { step = index }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = lock.withLock { () -> Double in
            let gap = now - lastTick
            lastTick = now
            reported = false
            return gap
        }
        guard gap > 2 else { return }
        // A menu that is open runs its own loop, where this timer may not fire: not a hang.
        if SweepMenus.tracked != nil || now - SweepMenus.lastTrackingEnd < 1 {
            SweepRecord.add("menuGaps", String(format: "%.1f s", gap))
        } else {
            SweepRecord.addHang(gap)
        }
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            let now = ProcessInfo.processInfo.systemUptime
            let due = lock.withLock { () -> (Int, Double, (@Sendable (Int, Double) -> Void)?)? in
                guard now - lastTick > 2, !reported, SweepMenus.tracked == nil else { return nil }
                reported = true
                return (step, now - lastTick, report)
            }
            if let due { due.2?(due.0, due.1) }
        }
    }
}
