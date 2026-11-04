import AppKit
import WebKit

/// The profile process's side of the input check (`Lumen --input-check`, a measurement on the
/// branch claude/measure-touch, never merged): whether this process's main thread answers, and what
/// a click with the mouse brings a page — which input listeners the page put where, which events
/// came, in which order, with which fields, and whether the page did anything.
///
/// The page's listeners are written down by a script in the page's own world that runs before any
/// of the page's (it wraps `EventTarget.prototype.addEventListener`); the events by listeners of its
/// own on the window, in the capture phase, so they are seen before the page's. The click is made
/// of the events AppKit makes of a click (Quartz's, as `WarmUpRobot` makes them) and handed to the
/// window, which hands them to WebKit as it would a person's.
@MainActor
enum InputProbe {
    private final class Once {
        var done = false
    }

    private static var recorded = Set<ObjectIdentifier>()

    /// The front page's web view: the largest visible web view of the key window, else of the
    /// frontmost window that has one (Safari's chrome holds other web views besides the page's).
    static func frontWebView() -> WKWebView? {
        let windows = [NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows where window.isVisible {
            var found: [WKWebView] = []
            collect(window.contentView, into: &found)
            let visible = found.filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 50 && $0.bounds.height > 50 }
            if let largest = visible.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                return largest
            }
        }
        return nil
    }

    private static func collect(_ view: NSView?, into found: inout [WKWebView]) {
        guard let view else { return }
        if let webView = view as? WKWebView { found.append(webView) }
        for subview in view.subviews { collect(subview, into: &found) }
    }

    /// Answers `ping`: this runs on the main thread, so an answer at all says the window's thread
    /// is free; `page` says whether the front page answered a script within three seconds.
    static func pong(_ number: Int) {
        let started = Date()
        guard let webView = frontWebView() else {
            ProfileSessionHost.send(.pong(number, page: "no web view in any window"))
            return
        }
        let once = Once()
        webView.evaluateJavaScript("document.readyState") { result, error in
            guard !once.done else { return }
            once.done = true
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let said = (result as? String).map { "answered in \(ms) ms: \($0)" }
                ?? "answered in \(ms) ms with \(error.map { String(String(describing: $0).prefix(120)) } ?? "nothing")"
            ProfileSessionHost.send(.pong(number, page: said))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !once.done else { return }
            once.done = true
            ProfileSessionHost.send(.pong(number, page: "NO ANSWER in 3 s"))
        }
    }

    /// Answers `inputProbe`: one line per step, the last one `"step":"done"`.
    static func probe(_ number: Int, _ address: String) {
        Task { @MainActor in
            await run(number, address)
            say(number, ["step": "done", "site": address])
        }
    }

    private static func say(_ number: Int, _ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        ProfileSessionHost.send(.inputReport(number, String(decoding: data, as: UTF8.self)))
    }

    private static let clicksPerPage = 8

    private static func run(_ number: Int, _ address: String) async {
        guard let webView = frontWebView(), let window = webView.window else {
            say(number, ["step": "error", "site": address, "error": "no web view in any window"])
            return
        }
        if !recorded.contains(ObjectIdentifier(webView)) {
            recorded.insert(ObjectIdentifier(webView))
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        say(number, ["step": "window", "site": address,
                     "window": [Int(window.frame.width), Int(window.frame.height)],
                     "webView": [Int(webView.bounds.width), Int(webView.bounds.height)],
                     "windowClass": String(describing: type(of: window)),
                     "visibleWindows": NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) },
                     "windowKey": window.isKeyWindow, "appActive": NSApp.isActive])
        var targets = await open(address, in: webView, number: number, first: true)
        var index = 0
        var clicks = 0
        while index < targets, clicks < clicksPerPage {
            clicks += 1
            let navigated = await click(index, in: webView, window: window, number: number, address: address)
            index += 1
            if navigated {
                // Back where the page was, its targets found again, and on from the next one.
                targets = await open(address, in: webView, number: number, first: false)
            }
        }
    }

    /// Loads `address` (the check's own page for `pb-test:touch`), waits for it to settle, and says
    /// what the page is, what listens to it and what will be clicked. Returns the number of targets.
    private static func open(_ address: String, in webView: WKWebView, number: Int, first: Bool) async -> Int {
        let started = Date()
        if address == "pb-test:touch" {
            webView.loadHTMLString(testPage, baseURL: URL(string: "https://touch-test.invalid/"))
        } else if let url = URL(string: address) {
            webView.load(URLRequest(url: url))
        }
        var state: String?
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            state = await script("return document.readyState", in: webView, world: .page) as? String
            if !webView.isLoading, state == "complete" { break }
        }
        let loadMs = Int(Date().timeIntervalSince(started) * 1000)
        // A page that builds itself after its load (most do) is given time to.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let page = await script(survey, in: webView, world: .page) as? String
        guard let page, let data = page.data(using: .utf8),
              var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            say(number, ["step": first ? "page" : "page-again", "site": address, "loadMs": loadMs, "isLoading": webView.isLoading,
                         "readyState": state ?? "no answer",
                         "error": page == nil ? "the page did not answer the survey in 3 s" : "the survey's answer was not JSON"])
            return 0
        }
        fields["step"] = first ? "page" : "page-again"
        fields["site"] = address
        fields["loadMs"] = loadMs
        fields["isLoading"] = webView.isLoading
        if !first { fields.removeValue(forKey: "listenerCounts"); fields.removeValue(forKey: "environment") }
        say(number, fields)
        return (fields["targets"] as? [Any])?.count ?? 0
    }

    /// Clicks target `index` in the middle with the mouse and says what came. Returns whether the
    /// page went elsewhere (a new document, or the address changed).
    private static func click(_ index: Int, in webView: WKWebView, window: NSWindow, number: Int, address: String) async -> Bool {
        let before = webView.url?.absoluteString ?? ""
        // The window is made key first, as a person's first click on it would: a click on a window
        // that is not key is AppKit's "first mouse", which WebKit takes for activating the window.
        let key = await makeKey(window)
        let armed = await script("return window.__pbArm(\(index))", in: webView, world: .page) as? [String: Any]
        guard let armed, let x = armed["x"] as? Double, let y = armed["y"] as? Double else {
            say(number, ["step": "click", "site": address, "index": index,
                         "error": armed == nil ? "the page did not answer in 3 s before the click" : "the target is gone or hidden",
                         "target": armed?["target"] ?? NSNull()])
            return false
        }
        let innerHeight = armed["innerHeight"] as? Double ?? Double(webView.bounds.height)
        // What changes on the page by itself over 1.5 s, before the click: the yardstick for what
        // the click changed.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let baseline = await script("return window.__pbBaseline()", in: webView, world: .page) as? [String: Any]
        guard let location = windowLocation(of: CGPoint(x: x, y: y), innerHeight: innerHeight, in: webView) else {
            say(number, ["step": "click", "site": address, "index": index, "error": "no place in the window for the point"])
            return false
        }
        let hitView = appKitHit(at: location, in: window)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
            try? await Task.sleep(nanoseconds: type == .leftMouseDown ? 90_000_000 : 40_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let read = await script("return JSON.stringify(window.__pbRead())", in: webView, world: .page) as? String
        let after = webView.url?.absoluteString ?? ""
        var fields: [String: Any] = ["step": "click", "site": address, "index": index, "target": armed["target"] ?? NSNull(),
                                     "point": [Int(x), Int(y)], "hitPage": armed["hit"] ?? NSNull(), "hitAppKit": hitView,
                                     "windowKey": key, "appActive": NSApp.isActive,
                                     "topInset": Int((Double(webView.bounds.height) - innerHeight * Double(webView.pageZoom * webView.magnification)).rounded()),
                                     "baselineMutations": baseline?["mutations"] ?? NSNull(),
                                     "urlBefore": short(before), "urlAfter": short(after), "isLoading": webView.isLoading]
        if let read, let data = read.data(using: .utf8), let got = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in got { fields[key] = value }
            fields["pageAnswered"] = true
        } else {
            fields["pageAnswered"] = false
        }
        let navigated = before != after || webView.isLoading || (fields["pageAnswered"] as? Bool) == false
        say(number, fields)
        if navigated {
            // Where the click led: does that page come up, and answer?
            let started = Date()
            var state: String?
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                state = await script("return document.readyState", in: webView, world: .page) as? String
                if !webView.isLoading, state == "complete" { break }
            }
            let answered = state != nil
            if !answered {
                say(number, ["step": "stall", "what": "page", "site": address, "after": "click \(index)",
                             "url": short(webView.url?.absoluteString ?? ""), "isLoading": webView.isLoading])
                // Long enough for its stacks to be taken while it does not answer.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                state = await script("return document.readyState", in: webView, world: .page) as? String
            }
            say(number, ["step": "after-click", "site": address, "index": index, "ms": Int(Date().timeIntervalSince(started) * 1000),
                         "url": short(webView.url?.absoluteString ?? ""), "isLoading": webView.isLoading,
                         "readyState": state ?? "NO ANSWER", "answeredFirstTry": answered])
        }
        return navigated
    }

    /// Makes `window` the key window of the active app, three seconds at most; whether it is.
    private static func makeKey(_ window: NSWindow) async -> Bool {
        for _ in 0..<15 {
            if window.isKeyWindow, NSApp.isActive { return true }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return window.isKeyWindow && NSApp.isActive
    }

    /// The view AppKit gives a click at `location` (the window's coordinates), and its parents.
    private static func appKitHit(at location: NSPoint, in window: NSWindow) -> String {
        guard let frame = window.contentView?.superview ?? window.contentView, var view = frame.hitTest(location) else { return "none" }
        var names = [String(describing: type(of: view))]
        while let parent = view.superview, names.count < 4 {
            names.append(String(describing: type(of: parent)))
            view = parent
        }
        return names.joined(separator: " < ")
    }

    private static func short(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return String(address.prefix(80)) }
        return String((host + url.path).prefix(80))
    }

    /// Where the viewport point `point` (CSS pixels) is in the web view's window. A web view under
    /// a toolbar (Safari's window) is taller than its viewport: the part under the toolbar is above
    /// the viewport's top.
    private static func windowLocation(of point: CGPoint, innerHeight: Double, in webView: WKWebView) -> NSPoint? {
        guard webView.window != nil else { return nil }
        let scale = Double(webView.pageZoom * webView.magnification)
        let top = max(0, Double(webView.bounds.height) - innerHeight * scale)
        let fromTop = top + Double(point.y) * scale
        let inView = NSPoint(x: Double(point.x) * scale, y: webView.isFlipped ? fromTop : Double(webView.bounds.height) - fromTop)
        return webView.convert(inView, to: nil)
    }

    /// Runs `body` in `world`, three seconds at most; nil without an answer.
    private static func script(_ body: String, in webView: WKWebView, world: WKContentWorld) async -> Any? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            let once = Once()
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: world) { result in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: try? result.get())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: The page's side

    /// Runs in the page's world before any of the page's scripts: writes down every input listener
    /// the page adds, where, and every input event that reaches the window while a click is armed.
    static let recorder = #"""
    (() => {
      if (window.__pbInput) return;
      const TYPES = ["touchstart", "touchend", "touchmove", "touchcancel", "pointerdown", "pointerup", "pointercancel",
                     "mousedown", "mouseup", "click", "dblclick", "contextmenu", "gesturestart", "gestureend", "focusin"];
      const WATCH = new Set(TYPES);
      const describe = (t) => {
        try {
          if (!t) return null;
          if (t === window) return "window";
          if (t === document) return "document";
          if (t.nodeType !== 1) return String(t.nodeName || t.constructor && t.constructor.name || t);
          let s = t.tagName.toLowerCase();
          if (t.id) s += "#" + String(t.id).slice(0, 30);
          const c = (typeof t.className === "string" ? t.className : "").trim().split(/\s+/).filter(Boolean).slice(0, 2).join(".");
          if (c) s += "." + c.slice(0, 40);
          return s;
        } catch (e) { return "?"; }
      };
      const R = { listeners: [], events: [], mutations: 0, armed: 0, describe };
      Object.defineProperty(window, "__pbInput", { value: R, enumerable: false });
      const add = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (type, listener, options) {
        try {
          if (WATCH.has(type) && R.listeners.length < 20000) {
            R.listeners.push({ type, node: this, on: describe(this),
                               passive: !!(options && typeof options === "object" && options.passive),
                               capture: options === true || !!(options && typeof options === "object" && options.capture) });
          }
        } catch (e) {}
        return add.call(this, type, listener, options);
      };
      const moves = { pointermove: 0, mousemove: 0 };
      for (const type of TYPES.concat(["pointermove", "mousemove", "pointerover", "mouseover"])) {
        add.call(window, type, (e) => {
          if (!R.armed) return;
          if (type in moves && ++moves[type] > 2) return;
          const rec = { type: e.type, trusted: e.isTrusted, t: Math.round(performance.now() - R.armed), target: describe(e.target) };
          if (e.pointerType !== undefined) rec.pointerType = e.pointerType;
          if (e.touches !== undefined) rec.touches = e.touches.length;
          if (e.button !== undefined && type !== "focusin") rec.button = e.button;
          R.events.push(rec);
          setTimeout(() => { rec.prevented = e.defaultPrevented; }, 0);
        }, { capture: true, passive: true });
      }
      new MutationObserver((list) => { if (R.armed) R.mutations += list.length; })
        .observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      add.call(window, "pagehide", () => { R.pagehide = true; });
      add.call(window, "beforeunload", () => { R.beforeunload = true; });
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width < 6 || r.height < 6) return null;
        const x = r.left + Math.min(r.width, 400) / 2, y = r.top + Math.min(r.height, 300) / 2;
        if (x < 1 || y < 1 || x >= innerWidth - 1 || y >= innerHeight - 1) return null;
        const hit = document.elementFromPoint(x, y);
        if (!hit || !(hit === el || el.contains(hit))) return null;
        return { x, y, hit };
      };
      const chain = (el) => {
        const types = new Set();
        for (const l of R.listeners) {
          if (l.node === window || l.node === document || (l.node && l.node.nodeType === 1 && l.node.contains(el))) types.add(l.type);
        }
        for (let n = el; n; n = n.parentNode) {
          for (const p of ["onclick", "ontouchstart", "ontouchend", "onmousedown", "onpointerdown", "onpointerup"]) {
            try { if (typeof n[p] === "function") types.add(p); } catch (e) {}
          }
        }
        return [...types].sort();
      };
      const text = (el) => String(el.getAttribute && (el.getAttribute("aria-label") || el.innerText || el.textContent) || "")
        .replace(/\s+/g, " ").trim().slice(0, 40);
      window.__pbTargets = [];
      window.__pbSurvey = () => {
        const TOUCH = new Set(["touchstart", "touchend", "touchmove", "touchcancel"]);
        const CLICK = new Set(["pointerdown", "pointerup", "mousedown", "mouseup", "click", "dblclick"]);
        const counts = {}, roots = {};
        const byNode = new Map();
        for (const l of R.listeners) {
          counts[l.type] = (counts[l.type] || 0) + 1;
          const n = l.node;
          if (n === window || n === document || n === document.documentElement || n === document.body) {
            roots[l.on + " " + l.type] = (roots[l.on + " " + l.type] || 0) + 1;
          } else if (n && n.nodeType === 1) {
            if (!byNode.has(n)) byNode.set(n, new Set());
            byNode.get(n).add(l.type);
          }
        }
        const groups = { "touch only": [], "touch and click": [], "click/pointer": [], "link": [], "button": [] };
        for (const [n, types] of byNode) {
          const touch = [...types].some((t) => TOUCH.has(t)), click = [...types].some((t) => CLICK.has(t));
          if (touch && !click) groups["touch only"].push(n);
          else if (touch && click) groups["touch and click"].push(n);
          else if (click) groups["click/pointer"].push(n);
        }
        for (const a of document.querySelectorAll("a[href]")) groups["link"].push(a);
        for (const b of document.querySelectorAll("button, [role=button], [onclick]")) groups["button"].push(b);
        const chosen = [], seen = new Set();
        for (const [group, nodes] of Object.entries(groups)) {
          let taken = 0;
          for (const n of nodes) {
            if (taken >= 2 || chosen.length >= 10) break;
            if (seen.has(n)) continue;
            const at = visible(n);
            if (!at) continue;
            seen.add(n);
            taken++;
            chosen.push({ node: n, group });
          }
        }
        window.__pbTargets = chosen;
        const env = {
          userAgent: navigator.userAgent, maxTouchPoints: navigator.maxTouchPoints, ontouchstart: "ontouchstart" in window,
          TouchEvent: typeof window.TouchEvent, Touch: typeof window.Touch, PointerEvent: typeof window.PointerEvent,
          pointerCoarse: matchMedia("(pointer: coarse)").matches, pointerFine: matchMedia("(pointer: fine)").matches,
          hoverNone: matchMedia("(hover: none)").matches, anyPointerCoarse: matchMedia("(any-pointer: coarse)").matches,
          innerWidth, innerHeight, devicePixelRatio, screen: [screen.width, screen.height], platform: navigator.platform
        };
        return {
          href: (location.host + location.pathname).slice(0, 80), title: document.title.slice(0, 60), environment: env,
          listenerCounts: counts, listenersOnRoots: roots, elementsWithListeners: byNode.size,
          groupsFound: Object.fromEntries(Object.entries(groups).map(([g, n]) => [g, n.length])),
          targets: chosen.map((c, i) => ({ index: i, group: c.group, element: describe(c.node), text: text(c.node),
                                          href: c.node.href ? String(c.node.href).replace(/^https?:\/\//, "").slice(0, 60) : undefined,
                                          listening: chain(c.node) }))
        };
      };
      window.__pbArm = (index) => {
        const c = window.__pbTargets[index];
        if (!c || !c.node.isConnected) return { gone: true, target: c ? describe(c.node) : null };
        const at = visible(c.node);
        const target = { group: c.group, element: describe(c.node), text: text(c.node) };
        if (!at) return { hidden: true, target };
        R.events = []; R.mutations = 0; R.pagehide = false; R.beforeunload = false;
        for (const k in moves) moves[k] = 0;
        R.href = location.href;
        R.armed = performance.now();
        return { x: at.x, y: at.y, target, hit: describe(at.hit), innerWidth, innerHeight };
      };
      window.__pbBaseline = () => {
        const out = { mutations: R.mutations, events: R.events.length };
        R.events = []; R.mutations = 0;
        for (const k in moves) moves[k] = 0;
        R.armed = performance.now();
        return out;
      };
      window.__pbRead = () => {
        const out = { events: R.events, mutations: R.mutations, sameDocumentHrefChanged: location.href !== R.href,
                      pagehide: !!R.pagehide, beforeunload: !!R.beforeunload,
                      fired: [...document.querySelectorAll("[data-fired]")].map((e) => e.id + ":" + e.dataset.fired),
                      active: describe(document.activeElement) };
        R.armed = 0;
        return out;
      };
    })();
    """#

    /// Asks the recorder what the page is and what will be clicked.
    static let survey = "return window.__pbSurvey ? JSON.stringify(window.__pbSurvey()) : JSON.stringify({error: 'no recorder in this page: its script did not run before the page'})"

    /// The check's own page: one element for each way a site may wait for a tap, each saying
    /// whether its way came (`data-fired`). On an iPhone each fires on a tap; here, what a click gives.
    static let testPage = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Input check</title>
    <style>
      body { font: 15px -apple-system, sans-serif; margin: 12px; }
      .box { display: block; height: 70px; margin: 0 0 10px; border: 2px solid #888; border-radius: 10px; padding: 8px; box-sizing: border-box; }
      .box[data-fired] { background: #cfc; }
    </style></head><body>
    <div class="box" id="click">click listener</div>
    <div class="box" id="touchend">touchend listener only (a tap library)</div>
    <div class="box" id="touchstart">touchstart listener only</div>
    <div class="box" id="pointer-touch">pointerup, only when pointerType is "touch"</div>
    <div class="box" id="touch-prevents-click">touchend that calls preventDefault, and click</div>
    <a class="box" id="link" href="#moved">a link to #moved</a>
    <script>
      const mark = (el, how) => { el.dataset.fired = (el.dataset.fired ? el.dataset.fired + "+" : "") + how; };
      const $ = (id) => document.getElementById(id);
      $("click").addEventListener("click", () => mark($("click"), "click"));
      $("touchend").addEventListener("touchend", () => mark($("touchend"), "touchend"));
      $("touchstart").addEventListener("touchstart", () => mark($("touchstart"), "touchstart"), { passive: true });
      $("pointer-touch").addEventListener("pointerup", (e) => { if (e.pointerType === "touch") mark($("pointer-touch"), "pointerup-touch"); });
      $("touch-prevents-click").addEventListener("touchend", (e) => { e.preventDefault(); mark($("touch-prevents-click"), "touchend"); });
      $("touch-prevents-click").addEventListener("click", () => mark($("touch-prevents-click"), "click"));
      $("link").addEventListener("click", () => mark($("link"), "click"));
    </script></body></html>
    """#
}
