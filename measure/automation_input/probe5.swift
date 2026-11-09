// Measurement, round 5 (claude/measure-automation-input, never merged). Round 4: the wheel's window answered
// gave it a screen place (offset like a real one) but at the window's own origin shifted point, and moves were
// still dropped with the real cursor away. WebKit's source says why: WKWebView ignores mouseMoved:, only its
// tracking area's owner passes moves on, and AppKit calls it when the real cursor moves. Here: moves to that
// owner (the control: to the view), and the wheel's location given as the window's own point.
// (Round 4's header follows.)
// Measurement, round 4 (claude/measure-automation-input, never merged). Round 3 left two marks: moves
// reach the page only when the real cursor is over the window, and wheel events say screen 0/768. Here,
// in this process only, while one of our events is handled: NSEvent.mouseLocation answers our pointer's
// place, and the wheel event's window answers our window.
// (Round 3's header follows.)
// After round 2: the fixes
// that worked kept (button state, wheel time, focus answered), and what was left:
//   wheel place — screen 0/768: the wheel event made four ways (sent to the window, posted to the app's
//                 queue, with the window set on the event, with its window location set);
//   first click — a background window's first click taken as an activating one: events given to the view;
//   moves       — moves reached the page only with the real cursor over the window: the cursor parked
//                 away first;
//   occlusion   — a window covered by another: what visibility the page reports, with WebKit's occlusion
//                 detection on and off.
// (Round 2's header follows.)
// Round 1 found that AppKit
// events given to the window or the web view are trusted and reach the page (keys included), but
// leave marks the HID route (a real mouse) does not: no pointer moves before a click, mousedown
// with buttons 0 and pointerdown with pressure 0, wheel events with timeStamp 0 and screen 0/768,
// and document.hasFocus() false when the window is not key or the app not active.
// Here the same click/type/wheel sequence through the window route, with each fix added in turn:
//   base      — as round 1
//   moves     — the window accepts mouse-moved events (acceptsMouseMovedEvents)
//   buttons   — + NSEvent.pressedMouseButtons answers the synthetic button state while it is down
//   wheel     — + wheel events made with a real timestamp and their place on screen
// and the focus a page sees when another window is key or another app active:
//   nonkey-fix / inactive-fix — NSWindow.isKeyWindow (for the target) and NSApp.isActive answer true,
//                               and the notifications WebKit listens for are posted
// Output as round 1: "RUN <state> <variant> <json>"; the HID route of the key state as the reference.
import AppKit
import ApplicationServices
import ObjectiveC
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let page = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? "<p>no page</p>"
let application = NSApplication.shared
application.setActivationPolicy(.regular)

// MARK: Overrides in this process only (what WebKit's UI-process side reads)

var syntheticButtons = 0
var forceFocus = false
weak var focusWindow: NSWindow?

func swizzleClassGetter(_ cls: AnyClass, _ name: String, _ block: @escaping @convention(block) (AnyObject) -> Int) {
    guard let method = class_getClassMethod(cls, NSSelectorFromString(name)) else { print("NOTE no class method \(name)"); return }
    let original = method_getImplementation(method)
    typealias Fn = @convention(c) (AnyObject, Selector) -> Int
    let call = unsafeBitCast(original, to: Fn.self)
    let replacement: @convention(block) (AnyObject) -> Int = { this in
        let mine = block(this)
        return mine >= 0 ? mine : call(this, NSSelectorFromString(name))
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
}

func swizzleBool(_ cls: AnyClass, _ name: String, _ decide: @escaping (AnyObject) -> Bool?) {
    guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { print("NOTE no method \(name)"); return }
    let original = method_getImplementation(method)
    typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
    let call = unsafeBitCast(original, to: Fn.self)
    let replacement: @convention(block) (AnyObject) -> Bool = { this in
        decide(this) ?? call(this, NSSelectorFromString(name))
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
}

var syntheticLocation: NSPoint?   // screen coordinates, AppKit's (bottom-left origin)
var syntheticWheel: NSEvent?
weak var syntheticWindow: NSWindow?
if let method = class_getClassMethod(NSEvent.self, NSSelectorFromString("mouseLocation")) {
    let original = method_getImplementation(method)
    typealias Fn = @convention(c) (AnyObject, Selector) -> NSPoint
    let call = unsafeBitCast(original, to: Fn.self)
    let block: @convention(block) (AnyObject) -> NSPoint = { this in syntheticLocation ?? call(this, NSSelectorFromString("mouseLocation")) }
    method_setImplementation(method, imp_implementationWithBlock(block))
} else { print("NOTE no mouseLocation") }
if let method = class_getInstanceMethod(NSEvent.self, NSSelectorFromString("window")) {
    let original = method_getImplementation(method)
    typealias Fn = @convention(c) (AnyObject, Selector) -> NSWindow?
    let call = unsafeBitCast(original, to: Fn.self)
    let block: @convention(block) (AnyObject) -> NSWindow? = { this in
        if let wheel = syntheticWheel, this === wheel { return syntheticWindow }
        return call(this, NSSelectorFromString("window"))
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
} else { print("NOTE no NSEvent.window") }
var fixPointer = false

swizzleClassGetter(NSEvent.self, "pressedMouseButtons") { _ in syntheticButtons > 0 ? syntheticButtons : -1 }
swizzleBool(NSWindow.self, "isKeyWindow") { this in forceFocus && this === focusWindow ? true : nil }
swizzleBool(NSApplication.self, "isActive") { _ in forceFocus ? true : nil }

typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
let setWindowLocation: SetWindowLocation? = {
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGEventSetWindowLocation") else { print("NOTE no CGEventSetWindowLocation"); return nil }
    return unsafeBitCast(symbol, to: SetWindowLocation.self)
}()

final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
}

struct Fixes { var moves = false, buttons = false, wheel = false, hid = false, view = false, owner = false, wheelMode = 0 }

@MainActor final class Probe {
    var windows: [String: (NSWindow, WKWebView, Loader)] = [:]
    var fixes = Fixes()

    func open(_ name: String, frame: NSRect) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "probe \(name)"
        window.contentView = view
        window.isReleasedWhenClosed = false
        let loader = Loader()
        view.navigationDelegate = loader
        windows[name] = (window, view, loader)
        window.orderFront(nil)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loader.done = c
            view.loadHTMLString(page, baseURL: URL(string: "http://127.0.0.1/")!)
        }
    }

    func js(_ view: WKWebView, _ source: String) async -> Any? { try? await view.evaluateJavaScript(source) }
    func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func point(of id: String, in view: WKWebView) async -> NSPoint? {
        guard let r = await js(view, "__rect('\(id)')") as? [Double], r.count == 4 else { return nil }
        let x = r[0] + r[2] / 2, y = r[1] + r[3] / 2
        return view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
    }

    func quartzPoint(_ location: NSPoint, in window: NSWindow) -> CGPoint {
        let onScreen = window.convertPoint(toScreen: location)
        let mainHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        return CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
    }

    func mouse(_ type: NSEvent.EventType, at location: NSPoint, window: NSWindow) {
        if fixes.hid {
            let t: CGEventType = type == .leftMouseDown ? .leftMouseDown : type == .leftMouseUp ? .leftMouseUp : .mouseMoved
            guard let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: quartzPoint(location, in: window), mouseButton: .left) else { return }
            if t != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
            e.post(tap: .cghidEventTap)
            return
        }
        if fixes.buttons { syntheticButtons = type == .leftMouseDown ? 1 : 0 }
        if fixPointer { syntheticLocation = window.convertPoint(toScreen: location) }
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
        if fixes.owner, type == .mouseMoved, let view = window.contentView {
            // WebKit takes pointer moves only from the owner of its own tracking area (WKWebView itself ignores
            // mouseMoved:), and AppKit calls that owner only when the real cursor moves. Public API: the view's
            // tracking areas, their owner, the responder's mouseMoved:.
            let owners = view.trackingAreas.compactMap { $0.owner as? NSObject }.filter { $0 !== view }
            var seen = Set<ObjectIdentifier>()
            for owner in owners where seen.insert(ObjectIdentifier(owner)).inserted {
                if owner.responds(to: #selector(NSResponder.mouseMoved(with:))) { owner.perform(#selector(NSResponder.mouseMoved(with:)), with: event) }
            }
            if owners.isEmpty { print("NOTE no tracking area owner") }
            return
        }
        if fixes.view {
            guard let view = window.contentView else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: view.mouseMoved(with: event)
            }
            return
        }
        window.sendEvent(event)
    }

    func key(_ character: String, code: CGKeyCode, down: Bool, window: NSWindow) {
        if fixes.hid {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
            e.post(tap: .cghidEventTap)
            return
        }
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: code) else { return }
        if fixes.view, let view = window.contentView {
            if down { view.keyDown(with: event) } else { view.keyUp(with: event) }
            return
        }
        window.sendEvent(event)
    }

    func wheel(_ delta: Int32, at location: NSPoint, window: NSWindow) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) else { return }
        event.location = quartzPoint(location, in: window)
        if fixes.hid { event.post(tap: .cghidEventTap); return }
        if fixes.wheel {
            // The time the system gives its own events (nanoseconds since boot), and the window under the pointer.
            event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        if fixes.wheelMode == 3, let set = setWindowLocation {
            // The point in the window's own coordinates (top-left origin, as Quartz has it).
            let inWindow = window.contentView.map { $0.convert(location, from: nil) } ?? location
            set(event, CGPoint(x: inWindow.x, y: (window.contentView?.isFlipped ?? false) ? inWindow.y : (window.contentView?.bounds.height ?? 0) - inWindow.y))
        }
        if fixPointer {
            // With the event's window answered as ours, its location is read as the window's own point; a windowless
            // event's location is the Quartz point turned bottom-up against the main screen.
            let mainHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
            event.location = CGPoint(x: location.x, y: mainHeight - location.y)
        }
        guard let ns = NSEvent(cgEvent: event) else { return }
        if fixPointer {
            syntheticWheel = ns; syntheticWindow = window
            syntheticLocation = window.convertPoint(toScreen: location)
        }
        defer { if fixPointer { syntheticWheel = nil } }
        switch fixes.wheelMode {
        case 1: NSApp.postEvent(ns, atStart: false)
        case 2:
            let sel = NSSelectorFromString("_setWindow:")
            if ns.responds(to: sel) { ns.perform(sel, with: window) } else { print("NOTE no _setWindow:") }
            window.sendEvent(ns)
        default:
            if fixes.view, let view = window.contentView { view.scrollWheel(with: ns) } else { window.sendEvent(ns) }
        }
    }

    func moveAndClick(from: NSPoint, to: NSPoint, window: NSWindow) async {
        for step in 1...5 {
            let f = Double(step) / 5
            mouse(.mouseMoved, at: NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), window: window)
            await sleep(0.03)
        }
        await sleep(0.15)
        mouse(.leftMouseDown, at: to, window: window)
        await sleep(0.09)
        mouse(.leftMouseUp, at: to, window: window)
        await sleep(0.25)
    }

    func state(_ window: NSWindow) -> String {
        "{\"appActive\":\(NSApp.isActive),\"key\":\(window.isKeyWindow),\"forced\":\(forceFocus),\"axTrusted\":\(AXIsProcessTrusted())}"
    }

    func run(_ stateName: String, _ variant: String, target: String) async {
        guard let entry = windows[target] else { return }
        let window = entry.0, view = entry.1
        window.acceptsMouseMovedEvents = fixes.moves || fixes.hid
        _ = await js(view, "__reset()")
        guard let button = await point(of: "button", in: view), let field = await point(of: "field", in: view) else {
            print("RUN \(stateName) \(variant) {\"error\":\"no element points\"}")
            return
        }
        let before = state(window)
        await moveAndClick(from: NSPoint(x: button.x + 120, y: button.y - 60), to: button, window: window)
        await moveAndClick(from: button, to: field, window: window)
        for (character, code) in [("a", CGKeyCode(0)), ("b", CGKeyCode(11))] {
            key(character, code: code, down: true, window: window)
            await sleep(0.08)
            key(character, code: code, down: false, window: window)
            await sleep(0.12)
        }
        for _ in 0..<3 { wheel(40, at: field, window: window); await sleep(0.05) }
        await sleep(0.6)
        let taken = (await js(view, "__take()") as? String) ?? "null"
        print("RUN \(stateName) \(variant) {\"before\":\(before),\"after\":\(state(window)),\"page\":\(taken)}")
    }

    func applyFocusOverride(_ on: Bool, window: NSWindow) {
        forceFocus = on
        focusWindow = on ? window : nil
        // What WebKit's view listens for to send the page its focus and activity state.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
    }

    func main() async {
        print("MACHINE macOS \(ProcessInfo.processInfo.operatingSystemVersionString); AX trusted \(AXIsProcessTrusted())")
        await open("A", frame: NSRect(x: 40, y: 80, width: 560, height: 420))
        await open("B", frame: NSRect(x: 640, y: 80, width: 340, height: 300))
        let a = windows["A"]!.0

        func park() async {
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 1010, y: 8), mouseButton: .left) { e.post(tap: .cghidEventTap) }
            await sleep(0.4)
        }
        let control = Fixes(moves: true, buttons: true, wheel: true, view: true)
        let owner = Fixes(moves: true, buttons: true, wheel: true, view: true, owner: true)
        // The cursor parked away: moves to the view (the control: dropped), then to its tracking area's owner.
        for (name, f) in [("view-fix", control), ("owner-fix", owner)] {
            fixes = f; fixPointer = true
            NSApp.activate(ignoringOtherApps: true)
            a.makeKeyAndOrderFront(nil)
            await park()
            await run("key-parked", name, target: "A")
            fixPointer = false; syntheticLocation = nil
        }
        // In the background (another app active), focus and pointer answered: the control, then the owner.
        for (name, f) in [("view-fix", control), ("owner-fix", owner)] {
            fixes = f; fixPointer = true
            a.orderFront(nil)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            await sleep(1.0)
            await park()
            applyFocusOverride(true, window: a)
            await sleep(0.4)
            await run("inactive-all", name, target: "A")
            applyFocusOverride(false, window: a)
            fixPointer = false; syntheticLocation = nil
        }
        // The reference once more, last: a real mouse and keyboard.
        fixes = Fixes(hid: true)
        NSApp.activate(ignoringOtherApps: true)
        a.makeKeyAndOrderFront(nil)
        await sleep(0.6)
        await run("key", "hid", target: "A")
        print("DONE")
        exit(0)
    }
}

Task { @MainActor in await Probe().main() }
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("TIMEOUT"); exit(1) }
application.run()
