import AppKit
import Foundation
import os
import WebKit

/// The core commands of a scenario on one page (docs/AUTOMATION.md): going to addresses, clicking,
/// typing, scrolling, waiting for elements, reading what a page shows, and pictures of it. Names
/// follow Playwright's (`goto`, `click`, `type`, `waitFor`, `evaluate`) so that a script moves over
/// in half an hour; full compatibility is not promised.
///
/// Every action on the page is a person's: the pointer travels to an element and presses it, keys
/// are pressed one by one, the page scrolls with the wheel — all through `PageInput`, which the
/// self-test group "the page cannot tell" holds to a person's mouse and keyboard. Nothing is done
/// to the page from a script in its own world: the driver reads the page (where an element is,
/// whether it shows, its text) from a content world of its own, which the page's scripts cannot
/// see, and `evaluate` runs there unless the page's world is asked for by name.
@MainActor
final class PageDriver {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case noWindow
        case timeout(String)
        case notFound(String)
        case notVisible(String)
        /// Another element is on top of it where the pointer would press (a banner, a dialog).
        case covered(String, by: String)
        /// The keyboard layout in use has no key for this character.
        case untypeable(String)
        case script(String)
        case navigation(String)

        var description: String {
            switch self {
            case .noWindow: return "the page has no window"
            case .timeout(let what): return "timed out: \(what)"
            case .notFound(let selector): return "no element matches \(selector)"
            case .notVisible(let selector): return "\(selector) is not visible"
            case .covered(let selector, let by): return "\(selector) is covered by \(by)"
            case .untypeable(let character): return "the keyboard layout has no key for \"\(character)\""
            case .script(let message): return "script error: \(message)"
            case .navigation(let message): return "navigation failed: \(message)"
            }
        }
    }

    enum LoadState: String {
        /// The document parsed (`DOMContentLoaded`).
        case domContentLoaded = "domcontentloaded"
        /// Everything loaded (`load`), and the web view loads nothing more.
        case load
    }

    enum ElementState: String {
        case attached, detached, visible, hidden
    }

    enum World {
        /// The driver's own content world: the page's scripts cannot see what runs there.
        case isolated
        /// The page's own world: what runs there is the page's to see (its globals, its prototypes).
        case page
    }

    /// The driver's content world.
    static let world = WKContentWorld.world(name: "PBAutomation")

    let webView: WKWebView
    let input: PageInput
    /// How a command loads an address (a tab's own `load`, so its history and state follow).
    var navigate: (URL) -> Void
    /// Default wait of a command.
    var timeout: TimeInterval = 30
    /// What each command did, for the run's log. Never what was typed: its length only.
    var onLog: ((String) -> Void)?
    private var generator = SystemRandomNumberGenerator()

    init(webView: WKWebView, navigate: ((URL) -> Void)? = nil) {
        self.webView = webView
        input = PageInput(webView: webView)
        self.navigate = navigate ?? { [weak webView] url in _ = webView?.load(URLRequest(url: url)) }
    }

    // MARK: Going to pages

    /// Loads `url` as the address bar does, and waits for `state`.
    func goto(_ url: URL, waitUntil state: LoadState = .load, timeout: TimeInterval? = nil) async throws {
        onLog?("goto \(url.absoluteString)")
        try await navigation("going to \(url.absoluteString)", state: state, timeout: timeout) { self.navigate(url) }
    }

    func back(timeout: TimeInterval? = nil) async throws {
        onLog?("back")
        guard webView.canGoBack else { throw Failure.navigation("nothing to go back to") }
        try await navigation("going back", state: .load, timeout: timeout) { self.webView.goBack() }
    }

    func forward(timeout: TimeInterval? = nil) async throws {
        onLog?("forward")
        guard webView.canGoForward else { throw Failure.navigation("nothing to go forward to") }
        try await navigation("going forward", state: .load, timeout: timeout) { self.webView.goForward() }
    }

    func reload(timeout: TimeInterval? = nil) async throws {
        onLog?("reload")
        try await navigation("reloading", state: .load, timeout: timeout) { self.webView.reload() }
    }

    /// Starts a navigation and waits until another document is there (the old one's mark, kept in
    /// the driver's world, is gone) or the address changed with nothing loading (a jump within the
    /// page, or a page from the back-forward cache), then for `state`.
    private func navigation(_ what: String, state: LoadState, timeout: TimeInterval?, _ start: () -> Void) async throws {
        let mark = Double.random(in: 1...1_000_000, using: &generator)
        _ = try? await isolated("globalThis.__pbDocument = mark; return true;", ["mark": mark])
        let before = webView.url
        start()
        try await waitUntil(what, timeout: timeout ?? self.timeout) {
            let now = try? await self.isolated("return globalThis.__pbDocument === undefined ? -1 : globalThis.__pbDocument;") as? Double
            if let now, now != mark { return true }
            return self.webView.url != before && !self.webView.isLoading
        }
        try await waitForLoadState(state, timeout: timeout)
    }

    func waitForLoadState(_ state: LoadState = .load, timeout: TimeInterval? = nil) async throws {
        try await waitUntil("load state \(state.rawValue)", timeout: timeout ?? self.timeout) {
            let ready = try? await self.isolated("return document.readyState;") as? String
            switch state {
            case .domContentLoaded: return ready == "interactive" || ready == "complete"
            case .load: return ready == "complete" && !self.webView.isLoading
            }
        }
    }

    var url: URL? { webView.url }
    var title: String? { webView.title }

    // MARK: Elements

    /// Waits until the element `selector` is in `state`.
    func waitFor(_ selector: String, state: ElementState = .visible, timeout: TimeInterval? = nil) async throws {
        onLog?("waitFor \(selector) \(state.rawValue)")
        try await waitUntil("\(selector) to be \(state.rawValue)", timeout: timeout ?? self.timeout) {
            let info = try? await self.element(selector)
            switch state {
            case .attached: return info?.found == true
            case .detached: return info?.found == false
            case .visible: return info?.visible == true
            case .hidden: return info != nil && info?.visible != true
            }
        }
    }

    func count(_ selector: String) async throws -> Int {
        let value = try await isolated(Self.findAll + "return find(selector).length;", ["selector": selector])
        return (value as? NSNumber)?.intValue ?? 0
    }

    func isVisible(_ selector: String) async throws -> Bool { try await element(selector).visible }

    func textContent(_ selector: String) async throws -> String? {
        try await read(selector, "e.textContent")
    }

    func innerText(_ selector: String) async throws -> String? {
        try await read(selector, "e.innerText")
    }

    func inputValue(_ selector: String) async throws -> String? {
        try await read(selector, "('value' in e) ? String(e.value) : null")
    }

    func getAttribute(_ selector: String, _ name: String) async throws -> String? {
        let value = try await isolated(Self.findAll + "const e = find(selector)[0]; if (!e) return {missing: true}; return e.getAttribute(name);",
                                       ["selector": selector, "name": name])
        if let object = value as? [String: Any], object["missing"] != nil { throw Failure.notFound(selector) }
        return value as? String
    }

    private func read(_ selector: String, _ expression: String) async throws -> String? {
        let value = try await isolated(Self.findAll + "const e = find(selector)[0]; if (!e) return {missing: true}; return \(expression);",
                                       ["selector": selector])
        if let object = value as? [String: Any], object["missing"] != nil { throw Failure.notFound(selector) }
        return value as? String
    }

    /// Where the element is and whether a person could see and reach it.
    struct ElementInfo {
        var found: Bool
        var visible: Bool
        /// Its box in viewport points, and the part of it in the viewport.
        var box: CGRect
        var inView: CGRect
        var viewport: CGSize
    }

    func element(_ selector: String) async throws -> ElementInfo {
        let value = try await isolated(Self.findAll + """
            const e = find(selector)[0];
            const w = window.innerWidth, h = window.innerHeight;
            if (!e) return {found: false, visible: false, w, h};
            const r = e.getBoundingClientRect();
            const style = getComputedStyle(e);
            const shown = r.width > 0 && r.height > 0 && style.visibility === 'visible' && style.display !== 'none'
              && (e.checkVisibility ? e.checkVisibility({opacityProperty: true, visibilityProperty: true}) : true);
            const left = Math.max(0, r.left), top = Math.max(0, r.top), right = Math.min(w, r.right), bottom = Math.min(h, r.bottom);
            return {found: true, visible: shown, x: r.left, y: r.top, width: r.width, height: r.height,
                    vx: left, vy: top, vw: Math.max(0, right - left), vh: Math.max(0, bottom - top), w, h};
            """, ["selector": selector])
        guard let object = value as? [String: Any] else { throw Failure.script("no answer about \(selector)") }
        func number(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }
        return ElementInfo(found: object["found"] as? Bool == true, visible: object["visible"] as? Bool == true,
                           box: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                           inView: CGRect(x: number("vx"), y: number("vy"), width: number("vw"), height: number("vh")),
                           viewport: CGSize(width: number("w"), height: number("h")))
    }

    /// Finds elements by CSS, or by their text with `text=` (as Playwright: the smallest visible
    /// elements whose text holds it, case and spacing aside).
    private static let findAll = """
        const find = (selector) => {
          if (!selector.startsWith('text=')) return Array.from(document.querySelectorAll(selector));
          const wanted = selector.slice(5).trim().replace(/^"(.*)"$/, '$1').replace(/\\s+/g, ' ').toLowerCase();
          const all = Array.from(document.querySelectorAll('body *')).filter((e) => {
            const text = (e.innerText || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            return text.includes(wanted);
          });
          return all.filter((e) => !all.some((other) => other !== e && e.contains(other)));
        };

        """

    // MARK: The pointer

    /// Moves the pointer to the element `selector` and clicks it (`clickCount` 2: a double click),
    /// scrolling it into view with the wheel first when it is out of view.
    func click(_ selector: String, clickCount: Int = 1, timeout: TimeInterval? = nil) async throws {
        onLog?("click \(selector)")
        let point = try await pointerTarget(selector, timeout: timeout)
        try await moveTo(point)
        for index in 0..<max(1, clickCount) {
            if index > 0 { try await pause(0.08...0.16) }
            await input.click(hold: Double.random(in: 0.06...0.13, using: &generator))
        }
    }

    /// Moves the pointer over the element `selector`.
    func hover(_ selector: String, timeout: TimeInterval? = nil) async throws {
        onLog?("hover \(selector)")
        let point = try await pointerTarget(selector, timeout: timeout)
        try await moveTo(point)
    }

    /// Clicks the viewport point `point` (CSS pixels from the viewport's top left).
    func click(at point: CGPoint) async throws {
        onLog?("click at \(Int(point.x)),\(Int(point.y))")
        try await moveTo(point)
        await input.click(hold: Double.random(in: 0.06...0.13, using: &generator))
    }

    /// A point inside the element, where it is the topmost element, once it is visible and in view.
    private func pointerTarget(_ selector: String, timeout: TimeInterval?) async throws -> CGPoint {
        do {
            try await waitFor(selector, state: .visible, timeout: timeout)
        } catch Failure.timeout {
            let info = try? await element(selector)
            throw info?.found == true ? Failure.notVisible(selector) : Failure.notFound(selector)
        }
        try await scrollIntoView(selector)
        let info = try await element(selector)
        guard info.inView.width >= 1, info.inView.height >= 1 else { throw Failure.notVisible(selector) }
        // Not always the middle: somewhere in its inner part, as a hand lands; and only where it is
        // the element on top (no banner or dialog over it there).
        var onTop = "nothing"
        for _ in 0..<6 {
            let point = CGPoint(x: info.inView.minX + info.inView.width * Double.random(in: 0.3...0.7, using: &generator),
                                y: info.inView.minY + info.inView.height * Double.random(in: 0.35...0.65, using: &generator))
            let top = try await isolated(Self.findAll + """
                const e = find(selector)[0], t = document.elementFromPoint(x, y);
                if (!e || !t) return 'nothing';
                if (t === e || e.contains(t)) return '';
                return t.id ? '#' + t.id : t.nodeName.toLowerCase();
                """, ["selector": selector, "x": point.x, "y": point.y]) as? String
            if top == "" { return point }
            onTop = top ?? onTop
        }
        throw Failure.covered(selector, by: onTop)
    }

    /// The pointer's way to `point`: from where it is (or from somewhere on the page the first
    /// time), as a hand moves it.
    private func moveTo(_ point: CGPoint) async throws {
        guard webView.window != nil else { throw Failure.noWindow }
        input.holdFocus()
        let size = webView.bounds.size
        let start = CGPoint(x: Double.random(in: 0.2...0.8, using: &generator) * size.width,
                            y: Double.random(in: 0.3...0.9, using: &generator) * size.height)
        let from = input.pointerViewportPoint() ?? start
        let distance = hypot(point.x - from.x, point.y - from.y)
        let steps = max(4, min(60, Int(distance / Double.random(in: 9...15, using: &generator))))
        let moved = await input.move(along: input.path(to: point, from: start, steps: steps),
                                     interval: Double.random(in: 0.012...0.02, using: &generator))
        guard moved else { throw Failure.noWindow }
        try await pause(0.08...0.22)
    }

    // MARK: The wheel

    /// Scrolls by `deltaY` points (positive: down) with the wheel, where the pointer is (it is
    /// brought onto the page first when it is not on it).
    func scroll(by deltaY: Double) async throws {
        onLog?("scroll \(Int(deltaY))")
        if input.pointerViewportPoint() == nil {
            let size = webView.bounds.size
            try await moveTo(CGPoint(x: size.width * Double.random(in: 0.35...0.65, using: &generator),
                                     y: size.height * Double.random(in: 0.4...0.7, using: &generator)))
        }
        input.holdFocus()
        var left = deltaY
        while abs(left) >= 1 {
            let step = (left > 0 ? 1.0 : -1.0) * min(abs(left), Double.random(in: 30...90, using: &generator))
            guard input.wheel(step) else { throw Failure.noWindow }
            left -= step
            try await pause(0.016...0.04)
        }
        try await pause(0.2...0.35)
    }

    /// Scrolls with the wheel until the element is wholly in view (or as much of it as fits).
    func scrollIntoView(_ selector: String) async throws {
        for _ in 0..<40 {
            let info = try await element(selector)
            guard info.found else { throw Failure.notFound(selector) }
            let height = info.viewport.height
            let margin = min(40, height / 6)
            if info.box.minY >= margin && info.box.maxY <= height - margin { return }
            if info.box.height > height - 2 * margin && info.inView.height > height / 3 { return }
            let wanted = info.box.midY - height / 2
            let before = try await isolated("return window.scrollY;") as? Double
            try await scroll(by: max(-600, min(600, wanted)))
            let after = try await isolated("return window.scrollY;") as? Double
            // The page cannot scroll further that way.
            if before == after {
                let now = try await element(selector)
                if now.inView.height >= 1 { return }
                throw Failure.notVisible(selector)
            }
        }
    }

    // MARK: The keyboard

    /// Clicks the element `selector` (when given and not already focused) and types `text` key by
    /// key, `delay` between keys. The log says how many characters, never which.
    func type(_ selector: String?, _ text: String, delay: ClosedRange<Double> = 0.06...0.18) async throws {
        onLog?("type \(text.count) characters\(selector.map { " into \($0)" } ?? "")")
        let keys = try text.map { character -> PageInput.Key in
            guard let key = PageInput.key(typing: character) else { throw Failure.untypeable(String(character)) }
            return key
        }
        if let selector {
            let focused = try await isolated(Self.findAll + "const e = find(selector)[0]; return !!e && document.activeElement === e;",
                                             ["selector": selector]) as? Bool
            if focused != true { try await click(selector) }
        }
        input.holdFocus()
        for key in keys {
            await input.press(key, hold: Double.random(in: 0.04...0.11, using: &generator))
            try await pause(delay)
        }
    }

    /// Presses a key or a combination: "Enter", "Tab", "Shift+Tab", "Meta+a", "a".
    func press(_ combination: String) async throws {
        onLog?("press \(combination)")
        var modifiers: NSEvent.ModifierFlags = []
        var parts = combination.split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { throw Failure.untypeable(combination) }
        for part in parts {
            switch part.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "control", "ctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "meta", "command", "cmd": modifiers.insert(.command)
            default: throw Failure.untypeable(part)
            }
        }
        var key: PageInput.Key
        if let named = PageInput.named[last] {
            key = named
        } else if last.count == 1, let character = last.first, let typed = PageInput.key(typing: character) {
            key = typed
        } else {
            throw Failure.untypeable(last)
        }
        key.modifiers.formUnion(modifiers)
        input.holdFocus()
        await input.press(key, hold: Double.random(in: 0.05...0.12, using: &generator))
        try await pause(0.05...0.12)
    }

    // MARK: Scripts and pictures

    /// Runs `body` (a function body; `arguments` are its variables) in the driver's own world, or
    /// in the page's world when asked for by name: what runs there, the page can see.
    func evaluate(_ body: String, _ arguments: [String: Any] = [:], world: World = .isolated) async throws -> Any? {
        onLog?("evaluate in the \(world == .isolated ? "driver's" : "page's") world")
        return try await run(body, arguments, world: world == .isolated ? Self.world : .page)
    }

    /// A PNG of the viewport, or of the element `selector` (its part in view).
    func screenshot(_ selector: String? = nil) async throws -> Data {
        onLog?("screenshot\(selector.map { " of \($0)" } ?? "")")
        let configuration = WKSnapshotConfiguration()
        if let selector {
            let info = try await element(selector)
            guard info.found else { throw Failure.notFound(selector) }
            guard info.inView.width >= 1, info.inView.height >= 1 else { throw Failure.notVisible(selector) }
            let scale = webView.pageZoom * webView.magnification
            configuration.rect = CGRect(x: info.inView.minX * scale, y: info.inView.minY * scale,
                                        width: info.inView.width * scale, height: info.inView.height * scale)
        }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) } else {
                    continuation.resume(throwing: Failure.script(error?.localizedDescription ?? "no picture"))
                }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.script("no PNG") }
        return png
    }

    // MARK: Waiting

    /// A pause of a random length in `range` seconds.
    func pause(_ range: ClosedRange<Double>) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double.random(in: range, using: &generator) * 1_000_000_000))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await condition() { return }
            guard Date() < deadline else { throw Failure.timeout(what) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func isolated(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await run(body, arguments, world: Self.world)
    }

    private func run(_ body: String, _ arguments: [String: Any], world: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    continuation.resume(throwing: Failure.script(message))
                }
            }
        }
    }

    /// Lets go of the page's held focus (the run is over).
    func finish() {
        input.releaseFocus()
    }
}
