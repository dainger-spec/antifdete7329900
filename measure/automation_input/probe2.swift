// Measurement, round 2 (claude/measure-automation-input, never merged). Round 1 found that AppKit
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

swizzleClassGetter(NSEvent.self, "pressedMouseButtons") { _ in syntheticButtons > 0 ? syntheticButtons : -1 }
swizzleBool(NSWindow.self, "isKeyWindow") { this in forceFocus && this === focusWindow ? true : nil }
swizzleBool(NSApplication.self, "isActive") { _ in forceFocus ? true : nil }

final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
}

struct Fixes { var moves = false, buttons = false, wheel = false, hid = false }

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
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
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
        guard let ns = NSEvent(cgEvent: event) else { return }
        window.sendEvent(ns)
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
        let a = windows["A"]!.0, b = windows["B"]!.0

        let variants: [(String, Fixes)] = [
            ("hid", Fixes(hid: true)),
            ("base", Fixes()),
            ("moves", Fixes(moves: true)),
            ("buttons", Fixes(moves: true, buttons: true)),
            ("wheel", Fixes(moves: true, buttons: true, wheel: true)),
        ]
        for (name, f) in variants {
            fixes = f
            NSApp.activate(ignoringOtherApps: true)
            a.makeKeyAndOrderFront(nil)
            await sleep(0.6)
            await run("key", name, target: "A")
        }
        let all = Fixes(moves: true, buttons: true, wheel: true)
        // Another window key: as is, then with the focus answered for A.
        for forced in [false, true] {
            fixes = all
            NSApp.activate(ignoringOtherApps: true)
            a.orderFront(nil)
            b.makeKeyAndOrderFront(nil)
            await sleep(0.6)
            applyFocusOverride(forced, window: a)
            await sleep(0.4)
            await run("nonkey", forced ? "fix" : "all", target: "A")
            applyFocusOverride(false, window: a)
        }
        // Another app active: as is, then with the focus answered for A.
        for forced in [false, true] {
            fixes = all
            a.orderFront(nil)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            await sleep(1.0)
            applyFocusOverride(forced, window: a)
            await sleep(0.4)
            await run("inactive", forced ? "fix" : "all", target: "A")
            applyFocusOverride(false, window: a)
        }
        print("DONE")
        exit(0)
    }
}

Task { @MainActor in await Probe().main() }
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("TIMEOUT"); exit(1) }
application.run()
