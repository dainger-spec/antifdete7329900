// Measurement, round 6 (claude/measure-automation-input, never merged). In the app (CI 42613676137): (1) the
// first press in a window whose first responder is another view (an address field) came with hasFocus false
// although the web view was made first responder just before it — what does a real click (HID) give there?
// (2) in the warm-up's own window (alpha 0, lowest level, ordered back) one move of 6–45 reached the page.
// Which of its properties does that? Moves to the tracking-area owner, focus answered, in each variant.
// (Round 5's header follows.)
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

struct Fixes { var moves = false, buttons = false, wheel = false, hid = false, view = false, owner = false, firstResponder = false, wheelMode = 0 }

@MainActor final class Probe {
    var windows: [String: (NSWindow, WKWebView, Loader)] = [:]
    var fixes = Fixes()

    var fields: [String: NSTextField] = [:]

    /// style: "plain" (web view only), "field" (a text field above the web view, first responder), "warmup" (as the
    /// app's warm-up window: alpha 0, ignores mouse, lowest level, ordered back), "clear" (alpha 0, normal level),
    /// "faint" (alpha 0.02, lowest level, ordered back), "lowest" (alpha 1, lowest level, ordered back).
    func open(_ name: String, frame: NSRect, style: String = "plain") async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "probe \(name)"
        window.isReleasedWhenClosed = false
        let view: WKWebView
        if style == "field" {
            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 40), configuration: configuration)
            let field = NSTextField(frame: NSRect(x: 10, y: frame.height - 34, width: frame.width - 20, height: 24))
            container.addSubview(view)
            container.addSubview(field)
            window.contentView = container
            fields[name] = field
        } else {
            view = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
            window.contentView = view
        }
        let loader = Loader()
        view.navigationDelegate = loader
        windows[name] = (window, view, loader)
        switch style {
        case "warmup", "faint", "lowest":
            window.alphaValue = style == "warmup" ? 0 : style == "faint" ? 0.02 : 1
            if style == "warmup" { window.ignoresMouseEvents = true }
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
            window.collectionBehavior.insert([.transient, .ignoresCycle, .fullScreenNone])
            window.orderBack(nil)
        case "clear":
            window.alphaValue = 0
            window.orderFront(nil)
        default:
            window.orderFront(nil)
        }
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
        let web = windows.values.first { $0.0 === window }?.1
        if fixes.owner, type == .mouseMoved, let view = web {
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
            guard let view = web else { return }
            switch type {
            case .leftMouseDown:
                if fixes.firstResponder, window.firstResponder !== view { window.makeFirstResponder(view) }
                view.mouseDown(with: event)
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
        if fixes.view, let view = windows.values.first(where: { $0.0 === window })?.1 {
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
            if fixes.view, let view = windows.values.first(where: { $0.0 === window })?.1 { view.scrollWheel(with: ns) } else { window.sendEvent(ns) }
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
        "{\"appActive\":\(NSApp.isActive),\"key\":\(window.isKeyWindow),\"forced\":\(forceFocus),\"occluded\":\(!window.occlusionState.contains(.visible)),\"firstResponderIsWeb\":\(window.firstResponder is WKWebView),\"axTrusted\":\(AXIsProcessTrusted())}"
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
        await open("F", frame: NSRect(x: 40, y: 80, width: 560, height: 460), style: "field")
        for (name, x) in [("warmup", 120.0), ("faint", 160.0), ("lowest", 200.0), ("clear", 240.0)] {
            await open(name, frame: NSRect(x: x, y: 60, width: 560, height: 420), style: name)
        }
        let f = windows["F"]!.0
        func park() async {
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 1010, y: 8), mouseButton: .left) { e.post(tap: .cghidEventTap) }
            await sleep(0.4)
        }
        func toFinder() async {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            await sleep(1.0)
        }
        let owner = Fixes(moves: true, buttons: true, wheel: true, view: true, owner: true)
        var ownerFR = owner
        ownerFR.firstResponder = true

        // (1) The first press with an address field as first responder: a real click, then ours.
        for (name, fx) in [("hid", Fixes(hid: true)), ("owner-fr", ownerFR), ("owner-nofr", owner)] {
            fixes = fx; fixPointer = !fx.hid
            NSApp.activate(ignoringOtherApps: true)
            f.makeKeyAndOrderFront(nil)
            await sleep(0.5)
            f.makeFirstResponder(fields["F"])
            if !fx.hid { await park() }
            await sleep(0.3)
            await run("key-field", name, target: "F")
            fixPointer = false; syntheticLocation = nil
        }
        // The same behind another app, focus answered.
        fixes = ownerFR; fixPointer = true
        f.orderFront(nil)
        await toFinder()
        f.makeFirstResponder(fields["F"])
        applyFocusOverride(true, window: f)
        await sleep(0.4)
        await run("inactive-field", "owner-fr", target: "F")
        applyFocusOverride(false, window: f)
        fixPointer = false; syntheticLocation = nil

        // (2) Moves in the warm-up's kind of window and its variants, behind another app, focus answered.
        for name in ["warmup", "faint", "lowest", "clear"] {
            guard let w = windows[name]?.0 else { continue }
            fixes = ownerFR; fixPointer = true
            await toFinder()
            applyFocusOverride(true, window: w)
            await sleep(0.4)
            await run("inactive-\(name)", "owner-fr", target: name)
            applyFocusOverride(false, window: w)
            fixPointer = false; syntheticLocation = nil
        }
        print("DONE")
        exit(0)
    }
}

Task { @MainActor in await Probe().main() }
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("TIMEOUT"); exit(1) }
application.run()
