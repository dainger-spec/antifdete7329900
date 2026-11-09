// Measurement (claude/measure-automation-input, never merged): what a page sees of input sent by
// each route an app has into its own WKWebView, in each state a profile's window can be in.
//   routes: window   — an AppKit event given to the window (NSWindow.sendEvent), as the warm-up robot does
//           view     — an AppKit event given to the web view itself
//           quartz   — a Quartz event made into an AppKit one, given to the web view
//           pid      — a Quartz event posted to this process (CGEvent.postToPid)
//           hid      — a Quartz event posted at the HID level (CGEvent.post(tap: .cghidEventTap)): what the
//                      window server gets from a real mouse and keyboard — the reference
//   states: key      — this app active, the window key
//           nonkey   — this app active, another window of it key
//           inactive — another app active (Finder)
//           offscreen — the window placed off every screen (as the warm-up's window is)
// For each state × route: a pointer move to the button and a click, a move to the field and a click,
// "ab" typed, three wheel steps; then everything the page recorded (page.html) and the window's
// state. One line per run: "RUN <state> <route> <json>".
//
//     build/AIProbe.app/Contents/MacOS/ai-probe measure/automation_input/page.html
import AppKit
import ApplicationServices
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let page = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? "<p>no page</p>"
let application = NSApplication.shared
application.setActivationPolicy(.regular)

final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
}

enum Route: String, CaseIterable { case window, view, quartz, pid, hid }

@MainActor final class Probe {
    var windows: [String: (NSWindow, WKWebView, Loader)] = [:]

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

    func js(_ view: WKWebView, _ source: String) async -> Any? {
        try? await view.evaluateJavaScript(source)
    }

    func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// The middle of element `id`, in the window's coordinates.
    func point(of id: String, in view: WKWebView) async -> NSPoint? {
        guard let r = await js(view, "__rect('\(id)')") as? [Double], r.count == 4 else { return nil }
        let x = r[0] + r[2] / 2, y = r[1] + r[3] / 2
        let inView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        return view.convert(inView, to: nil)
    }

    func quartzPoint(_ location: NSPoint, in window: NSWindow) -> CGPoint {
        let onScreen = window.convertPoint(toScreen: location)
        let mainHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        return CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
    }

    func mouse(_ type: NSEvent.EventType, at location: NSPoint, window: NSWindow, view: WKWebView, route: Route) {
        let quartzType: CGEventType = type == .leftMouseDown ? .leftMouseDown : type == .leftMouseUp ? .leftMouseUp : .mouseMoved
        switch route {
        case .window, .view:
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
            if route == .window { window.sendEvent(event); return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: view.mouseMoved(with: event)
            }
        case .quartz, .pid, .hid:
            guard let event = CGEvent(mouseEventSource: nil, mouseType: quartzType, mouseCursorPosition: quartzPoint(location, in: window),
                                      mouseButton: .left) else { return }
            if quartzType != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            switch route {
            case .quartz:
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                guard let ns = NSEvent(cgEvent: event) else { return }
                switch type {
                case .leftMouseDown: view.mouseDown(with: ns)
                case .leftMouseUp: view.mouseUp(with: ns)
                default: view.mouseMoved(with: ns)
                }
            case .pid: event.postToPid(getpid())
            default: event.post(tap: .cghidEventTap)
            }
        }
    }

    func key(_ character: String, code: CGKeyCode, down: Bool, window: NSWindow, view: WKWebView, route: Route) {
        switch route {
        case .window, .view:
            guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: code) else { return }
            if route == .window { window.sendEvent(event) } else if down { view.keyDown(with: event) } else { view.keyUp(with: event) }
        case .quartz, .pid, .hid:
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
            let units = Array(character.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            switch route {
            case .quartz:
                guard let ns = NSEvent(cgEvent: event) else { return }
                if down { view.keyDown(with: ns) } else { view.keyUp(with: ns) }
            case .pid: event.postToPid(getpid())
            default: event.post(tap: .cghidEventTap)
            }
        }
    }

    func wheel(_ delta: Int32, at location: NSPoint, window: NSWindow, view: WKWebView, route: Route) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0) else { return }
        event.location = quartzPoint(location, in: window)
        switch route {
        case .window, .view, .quartz:
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            guard let ns = NSEvent(cgEvent: event) else { return }
            if route == .window { window.sendEvent(ns) } else { view.scrollWheel(with: ns) }
        case .pid: event.postToPid(getpid())
        case .hid: event.post(tap: .cghidEventTap)
        }
    }

    /// A move in a few steps from `from` to `to`, then a click there.
    func moveAndClick(from: NSPoint, to: NSPoint, window: NSWindow, view: WKWebView, route: Route) async {
        for step in 1...5 {
            let f = Double(step) / 5
            mouse(.mouseMoved, at: NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), window: window, view: view, route: route)
            await sleep(0.03)
        }
        await sleep(0.15)
        mouse(.leftMouseDown, at: to, window: window, view: view, route: route)
        await sleep(0.09)
        mouse(.leftMouseUp, at: to, window: window, view: view, route: route)
        await sleep(0.25)
    }

    func state(_ name: String) -> String {
        guard let entry = windows[name] else { return "{}" }
        let window = entry.0
        let frame = window.frame
        return "{\"appActive\":\(NSApp.isActive),\"key\":\(window.isKeyWindow),\"main\":\(window.isMainWindow),"
            + "\"visible\":\(window.isVisible),\"onScreen\":\(window.occlusionState.contains(.visible)),"
            + "\"frame\":[\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))],"
            + "\"axTrusted\":\(AXIsProcessTrusted())}"
    }

    func run(_ stateName: String, target: String, route: Route) async {
        guard let entry = windows[target] else { return }
        let window = entry.0, view = entry.1
        _ = await js(view, "__reset()")
        guard let button = await point(of: "button", in: view), let field = await point(of: "field", in: view) else {
            print("RUN \(stateName) \(route.rawValue) {\"error\":\"no element points\"}")
            return
        }
        let before = state(target)
        let start = NSPoint(x: button.x + 120, y: button.y - 60)
        await moveAndClick(from: start, to: button, window: window, view: view, route: route)
        await moveAndClick(from: button, to: field, window: window, view: view, route: route)
        for (character, code) in [("a", CGKeyCode(0)), ("b", CGKeyCode(11))] {
            key(character, code: code, down: true, window: window, view: view, route: route)
            await sleep(0.08)
            key(character, code: code, down: false, window: window, view: view, route: route)
            await sleep(0.12)
        }
        for _ in 0..<3 {
            wheel(40, at: field, window: window, view: view, route: route)
            await sleep(0.05)
        }
        await sleep(0.6)
        let taken = (await js(view, "__take()") as? String) ?? "null"
        print("RUN \(stateName) \(route.rawValue) {\"before\":\(before),\"after\":\(state(target)),\"page\":\(taken)}")
    }

    func main() async {
        print("MACHINE macOS \(ProcessInfo.processInfo.operatingSystemVersionString); screens \(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }); AX trusted \(AXIsProcessTrusted())")
        await open("A", frame: NSRect(x: 40, y: 80, width: 560, height: 420))
        await open("B", frame: NSRect(x: 640, y: 80, width: 340, height: 300))
        await open("C", frame: NSRect(x: -6000, y: 200, width: 560, height: 420))
        let (a, _, _) = windows["A"]!
        let (b, _, _) = windows["B"]!

        // key: this app active, A key.
        for route in Route.allCases {
            NSApp.activate(ignoringOtherApps: true)
            a.makeKeyAndOrderFront(nil)
            await sleep(0.6)
            await run("key", target: "A", route: route)
        }
        // nonkey: this app active, B key, events to A.
        for route in Route.allCases {
            NSApp.activate(ignoringOtherApps: true)
            a.orderFront(nil)
            b.makeKeyAndOrderFront(nil)
            await sleep(0.6)
            await run("nonkey", target: "A", route: route)
        }
        // offscreen: C off every screen, this app active, A key.
        for route in Route.allCases {
            NSApp.activate(ignoringOtherApps: true)
            a.makeKeyAndOrderFront(nil)
            windows["C"]!.0.orderFront(nil)
            await sleep(0.6)
            await run("offscreen", target: "C", route: route)
        }
        // inactive: Finder active, events to A.
        for route in Route.allCases {
            a.orderFront(nil)
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            await sleep(1.0)
            await run("inactive", target: "A", route: route)
        }
        print("DONE")
        exit(0)
    }
}

let probe = Probe()
Task { @MainActor in await probe.main() }
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("TIMEOUT"); exit(1) }
application.run()
