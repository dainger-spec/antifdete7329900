import AppKit
import BrowserCore
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
        /// What was asked cannot be done to this element (a choice a list does not have), in its
        /// own words.
        case refused(String)

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
            case .refused(let message): return message
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
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "PageDriver")

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
        // This navigation is waited for by itself, not as what an earlier click may have opened.
        lastAction = nil
        let before = webView.url
        start()
        try await waitUntil(what, timeout: timeout ?? self.timeout) {
            let now = try? await self.isolated("return globalThis.__pbDocument === undefined ? -1 : globalThis.__pbDocument;") as? Double
            if let now, now != mark { return true }
            return self.webView.url != before && !self.webView.isLoading
        }
        try await waitForLoadState(state, timeout: timeout)
    }

    /// A page that loads this soon after a click, a key or a choice in a list loads because of
    /// it (`waitForLoadState`).
    static let followsWithin: TimeInterval = 1.5

    /// The last thing done that may open a page — a click, a key, a choice in a list: when, and
    /// the document it was done in (`documentMark`).
    private var lastAction: (at: Date, document: Double?)?

    /// The document's mark in the driver's world, made at the first asking: another document has
    /// none, which is how a navigation is told.
    private func documentMark() async -> Double? {
        let mark = Double.random(in: 1...1_000_000, using: &generator)
        return try? await isolated("if (globalThis.__pbDocument === undefined) { globalThis.__pbDocument = mark; } return globalThis.__pbDocument;",
                                   ["mark": mark]) as? Double
    }

    /// Before a click, a key or a choice: the document it is done in is marked, for a
    /// `waitForLoadState` that follows it.
    private func willAct() async {
        let document = await documentMark()
        lastAction = (Date(), document)
    }

    /// Waits for the page to reach `state`. Right after a click, a key or a choice in a list
    /// (within `followsWithin`), first for the page that action opens to begin loading: the old
    /// page is still "complete" for a moment after the click, and a wait that looked at once
    /// went on to read the page that was being left (`click; waitForLoadState()` is what the
    /// recorder writes for a click that opens a page). With no page coming, it waits out that
    /// moment and no longer.
    func waitForLoadState(_ state: LoadState = .load, timeout: TimeInterval? = nil) async throws {
        if let action = lastAction {
            lastAction = nil
            let until = action.at.addingTimeInterval(Self.followsWithin)
            while Date() < until, !webView.isLoading {
                let now = try? await isolated("return globalThis.__pbDocument === undefined ? -1 : globalThis.__pbDocument;") as? Double
                // Another document already (a quick page, or one from the back-forward cache).
                if let now, now != action.document { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        try await waitUntil("load state \(state.rawValue)", timeout: timeout ?? self.timeout) {
            let ready = try? await self.isolated("return document.readyState;") as? String
            switch state {
            case .domContentLoaded: return ready == "interactive" || ready == "complete"
            case .load: return ready == "complete" && !self.webView.isLoading
            }
        }
    }

    /// Waits until the page's address is one `pattern` matches (`ScenarioURLPattern`), then for
    /// `state`: after a click whose page comes late — a form checked by a script first, a chain
    /// of redirects — where `waitForLoadState` alone cannot know a page is still to come.
    func waitForURL(_ pattern: ScenarioURLPattern, waitUntil state: LoadState = .load, timeout: TimeInterval? = nil) async throws {
        onLog?("waitForURL \(pattern.shown)")
        lastAction = nil
        try await waitUntil("the address to match \(pattern.shown)", timeout: timeout ?? self.timeout) {
            self.webView.url.map { pattern.matches($0.absoluteString) } ?? false
        }
        try await waitForLoadState(state, timeout: timeout)
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
        let value = try await isolated(Self.findAll + "return find(selector, true).length;", ["selector": selector])
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
    /// elements whose text holds it, case and spacing aside). `host >>> inner`: `inner` (CSS or
    /// `text=`) inside the open shadow root of each element `host` finds — a web component's own
    /// elements, which no selector of the document reaches; the recorder names them so. `at`: the
    /// element at a viewport point, inside open shadow roots too; `holds`: whether `t` is `e` or
    /// in it, across shadow roots; `focused`: the element with the focus, likewise.
    private static let findAll = """
        const findIn = (scope, selector) => {
          if (selector.startsWith('control=')) {
            const control = JSON.parse(selector.slice(8));
            const shownBox = e => {
              const r = e.getBoundingClientRect();
              return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility === 'visible' &&
                (!e.checkVisibility || e.checkVisibility({opacityProperty:true, visibilityProperty:true}));
            };
            let roots = control.within ? Array.from(scope.querySelectorAll(control.within)) : [scope];
            if (control.priorPath) {
              const direct = Array.from(scope.querySelectorAll(control.priorPath)).filter(shownBox);
              if (direct.length) return direct;
              roots = roots.filter(shownBox);
              if (roots.length !== 1) return [];
              return Array.from(roots[0].querySelectorAll(control.selector)).filter(shownBox);
            }
            if (roots.length !== 1) return [];
            if (control.fieldLabel !== undefined) {
              const direct = Array.from(scope.querySelectorAll(control.primary));
              if (direct.length) return direct;
              // Some floating labels move out of the input's attributes during hydration.
              // Only a compact wrapper dedicated to this one text field can supply its label.
              const label = control.fieldLabel;
              return Array.from(scope.querySelectorAll(control.selector)).filter(e => {
                if (e.localName !== 'textarea' && !['text','search','tel','url','email'].includes(e.type)) return false;
                if (/password|one-time-code|cc-/.test(e.autocomplete || '')) return false;
                if (!e.getClientRects().length || (e.checkVisibility && !e.checkVisibility({opacityProperty:true, visibilityProperty:true}))) return false;
                if (Array.from(e.labels || []).some(l => l.innerText.trim() === label)) return true;
                let p = e.parentElement;
                for (let i = 0; i < 2 && p && !p.matches('body,html,form'); i++, p = p.parentElement) {
                  if (p.querySelectorAll('input,textarea,select,button,a[href],[contenteditable],[role=button]').length !== 1) break;
                  if (p.innerText.trim() === label && !p.querySelector('label[for],[role=alert],[role=status]')) return true;
                }
                return false;
              });
            }
            return Array.from(roots[0].querySelectorAll(control.selector)).filter(e =>
              e.getClientRects().length && getComputedStyle(e).visibility === 'visible' &&
              (!e.checkVisibility || e.checkVisibility({opacityProperty: true, visibilityProperty: true})) &&
              (control.text === undefined || (e.innerText || '').replace(/\\s+/g, ' ').trim().normalize('NFC') === control.text));
          }
          if (!selector.startsWith('text=')) return Array.from(scope.querySelectorAll(selector));
          const wanted = selector.slice(5).trim().replace(/^"(.*)"$/, '$1').replace(/\\s+/g, ' ').toLowerCase();
          const all = Array.from(scope.querySelectorAll(scope === document ? 'body *' : '*')).filter((e) => {
            const text = (e.innerText || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            return text.includes(wanted);
          });
          const smallest = all.filter((e) => !all.some((other) => other !== e && e.contains(other)));
          // Keep substring matches for existing scripts. When a new, longer label appears,
          // an exact visible match still identifies the original recorded action.
          const exact = smallest.filter(e => e.getClientRects().length && getComputedStyle(e).visibility === 'visible'
            && (e.innerText || '').replace(/\\s+/g, ' ').trim().toLowerCase() === wanted);
          const preferred = new Set(exact);
          return [...exact, ...smallest.filter(e => !preferred.has(e))];
        };
        // Quoted CSS values and the text of a control can contain a literal shadow separator.
        const splitPath = selector => {
          const parts = [];
          let start = 0;
          for (const token of selector.matchAll(/"(?:\\\\.|[^"\\\\])*"|'(?:\\\\.|[^'\\\\])*'|\\\\.|\\s+>>>\\s+/gs)) {
            if (token[0].trim() !== '>>>') continue;
            if (selector.startsWith('text=', start) || selector.startsWith('control=', start)) break;
            parts.push(selector.slice(start, token.index));
            start = token.index + token[0].length;
          }
          return [...parts, selector.slice(start)];
        };
        const find = (selector, allowAmbiguous = false) => {
          const path = splitPath(selector);
          let found = findIn(document, path[0]);
          for (const step of path.slice(1)) found = found.flatMap(host => host.shadowRoot ? findIn(host.shadowRoot, step) : []);
          if (!allowAmbiguous && path[path.length - 1].startsWith('control=') && found.length > 1) return [];
          return found;
        };
        const at = (x, y) => {
          let t = document.elementFromPoint(x, y);
          while (t && t.shadowRoot && typeof t.shadowRoot.elementFromPoint === 'function') {
            const inner = t.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === t) break;
            t = inner;
          }
          return t;
        };
        const holds = (e, t) => {
          for (let n = t; n; n = n.parentNode || (n.nodeType === 11 ? n.host : null)) { if (n === e) return true; }
          // A text selector may resolve to the button's decorative span; the button receives its clicks.
          if (t && t.contains(e) && getComputedStyle(e).pointerEvents === 'none'
              && e.closest('button,a[href],label,summary,[role="button"]') === t) return true;
          return false;
        };
        const disabled = e => {
          const control = e.closest('button,input,select,textarea,option,label,a[href]');
          return e.matches(':disabled') || control?.matches(':disabled') ||
            (control instanceof HTMLLabelElement && control.control?.matches(':disabled')) ||
            e.closest('[aria-disabled]')?.getAttribute('aria-disabled')?.toLowerCase() === 'true';
        };
        const focused = () => {
          let a = document.activeElement;
          while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
          return a;
        };

        """

    // MARK: Lists

    /// Chooses in the list `selector` (a `<select>`, or a label of one) the options `choices`
    /// name — each a text (an option's value, else its label), or `{value:}`, `{label:}`,
    /// `{index:}` — and gives back the values chosen. One choice for a list of one; any number
    /// for a list that takes several, where they replace what was chosen.
    ///
    /// The pointer goes to the list, as a hand's would; the choice itself is made from the
    /// driver's world, as AutoFill fills a field: a list's menu is the system's, not the page's —
    /// a press on the list opens it for nobody to choose in. The page gets `input` and `change`
    /// as it does for a person's choice, but not marked as a person's (`isTrusted` is false):
    /// the one command here of which that is so (docs/AUTOMATION.md).
    @discardableResult
    func selectOption(_ selector: String, _ choices: [Any], timeout: TimeInterval? = nil) async throws -> [String] {
        onLog?("selectOption \(selector)")
        try await reach(selector, timeout: timeout)
        await willAct()
        let value = try await isolated(Self.findAll + Self.chooseOptions, ["selector": selector, "wanted": choices])
        guard let answer = value as? [String: Any] else { throw Failure.script("no answer about \(selector)") }
        if let problem = answer["problem"] as? String {
            let about = answer["about"] as? String ?? ""
            switch problem {
            case "missing": throw Failure.notFound(selector)
            case "notList": throw Failure.refused("\(selector) is not a list (a <select>): it is <\(about)>")
            case "disabled": throw Failure.refused("\(selector) is disabled")
            case "noOption": throw Failure.refused("\(selector) has no option \(about)")
            case "optionDisabled": throw Failure.refused("the option \(about) of \(selector) is disabled")
            default: throw Failure.refused("\(selector) takes one choice: it is not a list of several")
            }
        }
        try await pause(0.08...0.2)
        return answer["values"] as? [String] ?? []
    }

    /// `selector`, `wanted`: the list's options chosen, in the driver's world. Its answer is
    /// `{values}` or `{problem, about}`; scripts/test-shims.mjs runs this text.
    static let chooseOptions = """
        let list = find(selector)[0];
        if (!list) return {problem: 'missing'};
        if (list instanceof HTMLLabelElement && list.control) list = list.control;
        if (!(list instanceof HTMLSelectElement)) return {problem: 'notList', about: String(list.nodeName).toLowerCase()};
        if (list.matches(':disabled')) return {problem: 'disabled'};
        const options = Array.from(list.options);
        const plain = (text) => String(text).replace(/\\s+/g, ' ').trim();
        const pick = (want) => {
          if (want !== null && typeof want === 'object') {
            if (typeof want.index === 'number') return options[want.index];
            if (want.value !== undefined) return options.find((o) => o.value === String(want.value));
            if (want.label !== undefined) return options.find((o) => plain(o.label) === plain(want.label));
            return undefined;
          }
          return options.find((o) => o.value === String(want)) || options.find((o) => plain(o.label) === plain(want));
        };
        const chosen = [];
        for (const want of wanted) {
          const option = pick(want);
          const about = typeof want === 'object' ? JSON.stringify(want) : JSON.stringify(String(want));
          if (!option) return {problem: 'noOption', about};
          if (option.matches(':disabled')) return {problem: 'optionDisabled', about};
          if (!chosen.includes(option)) chosen.push(option);
        }
        if (chosen.length !== 1 && !list.multiple) return {problem: 'several'};
        const before = options.map((o) => o.selected);
        if (list.multiple) { for (const o of options) o.selected = chosen.includes(o); } else { chosen[0].selected = true; }
        if (options.some((o, i) => o.selected !== before[i])) {
          list.dispatchEvent(new Event('input', {bubbles: true, composed: true}));
          list.dispatchEvent(new Event('change', {bubbles: true}));
        }
        return {values: chosen.map((o) => o.value)};
        """

    // MARK: The pointer

    /// Older recordings identified anonymous text fields by a single label attribute. Keep the
    /// exact CSS match first, and let an action follow that label if the page moves it into markup.
    private func actionSelector(_ selector: String) async throws -> String {
        guard selector.contains("[aria-label=") || selector.contains("[placeholder=") || selector.contains(" > h") || selector.first == "h" else { return selector }
        return try await isolated(Self.findAll + #"""
            const path = splitPath(selector), primary = path.pop();
            // Keep the exact leaf of a recorded heading when a responsive layout replaces its outer wrappers.
            const heading = /^(?:(?:div|section|main|article)(?::nth-of-type\(\d+\))? > )*(h[1-6])((?: > (?:div|span)(?::nth-of-type\(\d+\))?)+)$/.exec(primary);
            if (heading) return [...path, 'control=' + JSON.stringify({selector:':scope' + heading[2], within:heading[1], priorPath:primary})].join(' >>> ');
            const m = /^(input|textarea)\[(?:aria-label|placeholder)="([^"\\]+)"\]$/.exec(primary);
            if (!m) return selector;
            return [...path, 'control=' + JSON.stringify({selector:m[1], primary, fieldLabel:m[2]})].join(' >>> ');
            """#, ["selector": selector]) as? String ?? selector
    }

    /// Moves the pointer to the element `selector` and clicks it (`clickCount` 2: a double click),
    /// scrolling it into view with the wheel first when it is out of view.
    func click(_ selector: String, clickCount: Int = 1, timeout: TimeInterval? = nil) async throws {
        onLog?("click \(selector)")
        let selector = try await actionSelector(selector)
        // Older recordings name the control even when the person clicked its label.
        // Use the associated label only for a visually hidden checkbox or radio.
        let label = try? await isolated(Self.findAll + """
            const e = find(selector)[0];
            if (!e || !e.matches('input[type=checkbox],input[type=radio]') || !e.id) return null;
            const r = e.getBoundingClientRect(), style = getComputedStyle(e);
            if (r.width > 1 && r.height > 1 && style.opacity !== '0' && style.visibility === 'visible'
                && style.pointerEvents !== 'none' && style.clipPath === 'none' && style.clip === 'auto') return null;
            const labels = Array.from(e.labels || []);
            const replacement = 'label[for=' + CSS.escape(e.id) + ']';
            const matches = e.getRootNode().querySelectorAll(replacement);
            if (matches.length !== 1 || !labels.includes(matches[0]) || !matches[0].getClientRects().length) return null;
            const path = splitPath(selector).slice(0,-1);
            return [...path, replacement].join(' >>> ');
            """, ["selector": selector]) as? String
        try await reach(label ?? selector, timeout: timeout, clicking: true)
        await willAct()
        // A double click's presses come within the system's interval, each counted as its place.
        let count = max(1, clickCount)
        for index in 0..<count {
            if index > 0 { try await pause(0.06...0.12) }
            await input.click(hold: Double.random(in: 0.05...0.1, using: &generator), clickCount: count > 1 ? index + 1 : nil)
        }
    }

    /// Moves the pointer over the element `selector`.
    func hover(_ selector: String, timeout: TimeInterval? = nil) async throws {
        onLog?("hover \(selector)")
        try await reach(selector, timeout: timeout)
    }

    /// The pointer onto the element, and still on it when it gets there: a page that moved under
    /// the way (still scrolling, a late banner) is followed, as an eye follows it.
    private func reach(_ selector: String, timeout: TimeInterval?, clicking: Bool = false) async throws {
        for attempt in 0..<3 {
            let point = try await pointerTarget(selector, timeout: timeout, clicking: clicking)
            try await moveTo(point)
            let still = try await isolated(Self.findAll + """
                const e = find(selector)[0], t = at(x, y);
                return !!e && !!t && holds(e, t) && (!clicking || !disabled(e));
                """, ["selector": selector, "x": point.x, "y": point.y, "clicking": clicking]) as? Bool
            if still == true { return }
            if attempt == 2 { throw Failure.covered(selector, by: "the page moving under the pointer") }
        }
    }

    /// Moves the pointer to the viewport point `point`, as a hand moves it, and leaves it there
    /// (WebDriver's actions: a hover, the way to a press).
    func movePointer(to point: CGPoint) async throws {
        onLog?("move to \(Int(point.x)),\(Int(point.y))")
        try await moveTo(point)
    }

    /// Clicks the viewport point `point` (CSS pixels from the viewport's top left).
    func click(at point: CGPoint) async throws {
        onLog?("click at \(Int(point.x)),\(Int(point.y))")
        try await moveTo(point)
        await willAct()
        await input.click(hold: Double.random(in: 0.06...0.13, using: &generator))
    }

    /// A point inside the element, where it is the topmost element, once it is visible and in view.
    private func pointerTarget(_ selector: String, timeout: TimeInterval?, clicking: Bool) async throws -> CGPoint {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        do {
            try await waitFor(selector, state: .visible, timeout: timeout)
        } catch Failure.timeout {
            let info = try? await element(selector)
            if selector.contains("control="), (try? await count(selector)) ?? 0 > 1 {
                throw Failure.refused("multiple controls match \(selector)")
            }
            throw info?.found == true ? Failure.notVisible(selector) : Failure.notFound(selector)
        }
        try await scrollIntoView(selector)
        var onTop: String?
        var isDisabled = false
        var missing = false
        repeat {
            // Re-read both the layout and the blocker in one turn of the page. A wrapped link
            // has several rectangles, and only an edge may be outside a banner or sticky header.
            let hit = try await isolated(Self.findAll + """
                const e = find(selector)[0];
                if (!e) return {missing: true};
                if (clicking && disabled(e)) return {disabled: true};
                let blocker = '';
                let inViewport = false, hasBox = false;
                for (const rect of e.getClientRects()) {
                  if (rect.width >= 1 && rect.height >= 1) hasBox = true;
                  const l = Math.max(0, rect.left), r = Math.min(innerWidth, rect.right);
                  const t = Math.max(0, rect.top), b = Math.min(innerHeight, rect.bottom);
                  if (r - l < 1 || b - t < 1) continue;
                  inViewport = true;
                  for (const fy of [0.5, 0.1, 0.9, 0.02, 0.98]) {
                    for (const fx of [0.5, 0.1, 0.9, 0.02, 0.98]) {
                      const x = Math.min(r - 0.5, Math.max(l + 0.5, l + (r-l)*fx));
                      const y = Math.min(b - 0.5, Math.max(t + 0.5, t + (b-t)*fy));
                      const target = at(x,y);
                      if (target && holds(e,target)) return {x,y};
                      if (!blocker && target) {
                        const cover = target.closest('[aria-modal="true"],[role="dialog"],dialog') || target;
                        blocker = cover.id ? '#' + cover.id : (cover.getAttribute('aria-label') || cover.localName);
                      }
                    }
                  }
                }
                return {blocker, offscreen: hasBox && !inViewport};
                """, ["selector": selector, "clicking": clicking]) as? [String: Any]
            missing = hit?["missing"] as? Bool == true
            isDisabled = hit?["disabled"] as? Bool == true
            if let x = hit?["x"] as? Double, let y = hit?["y"] as? Double { return CGPoint(x: x, y: y) }
            onTop = hit?["blocker"] as? String
            if Date() >= deadline { break }
            if hit?["offscreen"] as? Bool == true {
                // Loading content can move the element out of view while a banner is covering it.
                // Re-find it after the scroll, including when the page replaces it mid-scroll.
                do { try await scrollIntoView(selector, until: deadline) }
                catch Failure.notFound { }
                catch Failure.notVisible { }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        } while true
        if isDisabled { throw Failure.refused("\(selector) is disabled") }
        if missing { throw Failure.notFound(selector) }
        if let onTop, !onTop.isEmpty { throw Failure.covered(selector, by: onTop) }
        throw Failure.notVisible(selector)
    }

    /// The pointer's way to `point`: from where it is (or from somewhere on the page the first
    /// time), as a hand moves it.
    private func moveTo(_ point: CGPoint) async throws {
        guard webView.window != nil else { throw Failure.noWindow }
        input.holdFocus()
        let size = webView.bounds.size
        let start = CGPoint(x: Double.random(in: 0.2...0.8, using: &generator) * size.width,
                            y: Double.random(in: 0.3...0.9, using: &generator) * size.height)
        await measureViewport(entering: start)
        let from = input.pointerViewportPoint() ?? start
        let distance = hypot(point.x - from.x, point.y - from.y)
        let steps = max(4, min(60, Int(distance / Double.random(in: 9...15, using: &generator))))
        let moved = await input.move(along: input.path(to: point, from: start, steps: steps),
                                     interval: Double.random(in: 0.012...0.02, using: &generator))
        guard moved else { throw Failure.noWindow }
        try await pause(0.08...0.22)
    }

    // MARK: Where the viewport is

    /// The document and the size of the web view the viewport's place was last measured for.
    private var measuredFor: (document: Double, size: CGSize)?

    /// Finds where the viewport is in the web view (`PageInput.viewportOrigin`), once for a document
    /// and a size of the view. In a window of ours the viewport starts where the view does; in
    /// Safari's the page may run under the toolbar (docs/PAGE_INPUT.md), and a press aimed by the
    /// view's top would land that much off. Measured, not read from the web view: the page is asked
    /// — from the driver's own world, which only listens — where it saw a move of this input, and
    /// the difference is kept. The move is the pointer where it is, or coming onto the page at
    /// `point` the first time, where a hand's would. A page that reports no move (the pointer over
    /// a frame of another site) keeps what was measured before.
    private func measureViewport(entering point: CGPoint) async {
        let size = webView.bounds.size
        let document = try? await isolated("""
            if (globalThis.__pbMoves === undefined) {
              globalThis.__pbMoves = {mark: Math.random(), x: null, y: null};
              addEventListener('mousemove', (e) => { __pbMoves.x = e.clientX; __pbMoves.y = e.clientY; }, {capture: true, passive: true});
            }
            __pbMoves.x = null;
            return __pbMoves.mark;
            """) as? Double
        guard let document else { return }
        if let measuredFor, measuredFor.document == document, measuredFor.size == size { return }
        // Two moves a few points apart must tell the same: the listener hears every move, a
        // person's own mouse over the window too, and one of those taken for the probe would aim
        // every press on the page off. And what they tell must be a place a viewport can be: under
        // the view's top (a toolbar over the page), never to its side. Anything else is not kept,
        // and the next way of the pointer measures again.
        let first = input.pointerViewportPoint() ?? point
        let second = CGPoint(x: first.x + 7, y: first.y + 5)
        guard let one = await viewportOffset(seenAt: first), let two = await viewportOffset(seenAt: second),
              abs(one.x - two.x) <= 1.5, abs(one.y - two.y) <= 1.5 else { return }
        let origin = CGPoint(x: input.viewportOrigin.x + two.x, y: input.viewportOrigin.y + two.y)
        guard abs(origin.x) <= 2, origin.y >= -2, origin.y <= size.height / 2 else { return }
        if abs(two.x) >= 0.5 || abs(two.y) >= 0.5 {
            input.viewportOrigin = origin
            Self.log.notice("The viewport starts \(Int(self.input.viewportOrigin.x.rounded()), privacy: .public), \(Int(self.input.viewportOrigin.y.rounded()), privacy: .public) pt into its web view")
        }
        measuredFor = (document, size)
    }

    /// How far from where the input aimed (`probe`, a viewport point) the page saw its move, in the
    /// view's points; nil when the page reported none (the pointer over a frame of another site).
    private func viewportOffset(seenAt probe: CGPoint) async -> CGPoint? {
        _ = try? await isolated("globalThis.__pbMoves.x = null; return true;")
        guard await input.move(along: [probe], interval: 0) else { return nil }
        let scale = webView.pageZoom * webView.magnification
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let seen = try? await isolated("return __pbMoves.x === null ? null : [__pbMoves.x, __pbMoves.y];") as? [NSNumber]
            guard let seen, seen.count == 2 else { continue }
            return CGPoint(x: (probe.x - seen[0].doubleValue) * scale, y: (probe.y - seen[1].doubleValue) * scale)
        }
        return nil
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

    /// Where the page has scrolled to once it stops moving (a wheel's scrolling runs on for a
    /// moment after the last event).
    private func settledScroll() async throws -> Double? {
        var last = try await isolated("return window.scrollY;") as? Double
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 80_000_000)
            let now = try await isolated("return window.scrollY;") as? Double
            if now == last { return now }
            last = now
        }
        return last
    }

    /// Scrolls with the wheel until the element is wholly in view (or as much of it as fits).
    func scrollIntoView(_ selector: String, until deadline: Date? = nil) async throws {
        // A viewport wheel may scroll the document while the target remains clipped by
        // a nested list. Reveal it in its scroll containers before positioning the pointer.
        _ = try await isolated(Self.findAll + """
            const e = find(selector)[0];
            if (!e) return;
            for (let a = e.parentElement || e.getRootNode().host; a && a !== document.scrollingElement;
                 a = a.parentElement || a.getRootNode().host) {
              const style = getComputedStyle(a);
              const clips = v => /^(auto|scroll|hidden|overlay)$/.test(v);
              const r = e.getBoundingClientRect(), b = a.getBoundingClientRect();
              if ((clips(style.overflowY) && (r.bottom > b.bottom || r.top < b.top)) ||
                  (clips(style.overflowX) && (r.right > b.right || r.left < b.left))) {
                e.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'instant'});
                break;
              }
            }
            """, ["selector": selector])
        for _ in 0..<40 {
            let info = try await element(selector)
            guard info.found else { throw Failure.notFound(selector) }
            let height = info.viewport.height
            let margin = min(40, height / 6)
            if info.box.minY >= margin && info.box.maxY <= height - margin { return }
            if info.box.height > height - 2 * margin && info.inView.height > height / 3 { return }
            if let deadline, Date() >= deadline { return }
            let wanted = info.box.midY - height / 2
            let before = try await isolated("return window.scrollY;") as? Double
            try await scroll(by: max(-600, min(600, wanted)))
            let after = try await settledScroll()
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
    func type(_ selector: String?, _ text: String, delay: ClosedRange<Double> = 0.06...0.18, insertUnmappedText: Bool = false) async throws {
        onLog?("type \(text.count) characters\(selector.map { " into \($0)" } ?? "")")
        // Keys given to a web view in no window go nowhere: said, not logged as typed.
        guard webView.window != nil else { throw Failure.noWindow }
        let keys = try text.map { character in
            // A tab in recorded text (for example pasted TSV) belongs in the field.
            // An explicit press("Tab") still moves keyboard focus.
            let key = insertUnmappedText && character == "\t" ? nil : PageInput.key(typing: character)
            if key == nil && !insertUnmappedText { throw Failure.untypeable(String(character)) }
            return (character, key)
        }
        let typingID = UUID().uuidString
        // The detached node keeps the last value and selection while a replacement mounts.
        // Release it even on cancellation. A late cleanup cannot clear the next command's target.
        defer {
            if selector != nil {
                Task { @MainActor [weak self] in
                    _ = try? await self?.isolated("if (globalThis.__pbTyping?.id === id) { __pbTyping.dispose(); delete globalThis.__pbTyping; }", ["id": typingID])
                }
            }
        }
        if let selector {
            let locator = try await actionSelector(selector)
            let tracking = Self.findAll + ScenarioFieldLocator.script + "\n" + Self.trackTypingTarget
            var arguments = ["selector": locator, "id": typingID]
            let initial = try await isolated(tracking, arguments) as? [String: Any]
            if initial?["focused"] as? Bool != true {
                try await click(locator)
                // The first click can wait through a document replacement. Its field is now
                // focused in the new document, and no character has been sent yet. A different
                // origin must never inherit text intended for the original page.
                arguments["origin"] = initial?["origin"] as? String ?? ""
                _ = try await isolated("if (globalThis.__pbTyping || location.origin === 'null' || location.origin !== origin) return;\n" + tracking,
                                       arguments)
            }
        }
        input.holdFocus()
        var prefix = ""
        for (character, key) in keys {
            var literalLineBreak = false
            if let selector {
                let lineBreak = insertUnmappedText && (character == "\n" || character == "\r" || character == "\r\n")
                literalLineBreak = try await typingIsMultiline(selector, id: typingID, lineBreak: lineBreak, prefix: prefix)
            }
            if literalLineBreak {
                // A newline in pasted text must not activate a chat's Enter-to-send shortcut.
                webView.insertText("\n")
            } else if let key {
                await input.press(key, hold: Double.random(in: 0.04...0.11, using: &generator))
            } else {
                webView.insertText(String(character))
            }
            if insertUnmappedText && selector != nil { prefix.append(character) }
            try await pause(delay)
        }
        if let selector, !prefix.isEmpty,
           try await isolated("const t = globalThis.__pbTyping; return t?.id === id && t.lostEdit();", ["id": typingID]) as? Bool == true {
            _ = try await typingIsMultiline(selector, id: typingID, lineBreak: false, prefix: prefix)
        }
    }

    private static let trackTypingTarget = """
        let target, root, form, component, parents, existingFields, recipient, started = false;
        let watch = false, committed = '', repaired = false, confirming = null, changedDuringKey = false;
        const edited = event => { if (event.isTrusted && started) committed = event.currentTarget.value; };
        const cleared = () => watch && target?.isConnected && focused() === target && committed !== '' && target.value === '';
        const beforeEdit = event => { if (event.isTrusted && confirming === null && cleared()) changedDuringKey = true; };
        const dispose = () => {
          target?.removeEventListener('input', edited, true);
          target?.removeEventListener('beforeinput', beforeEdit, true);
        };
        function remember(e) {
          dispose();
          target = e;
          root = e?.getRootNode();
          form = e?.form;
          component = fieldComponent(e);
          // A simple unowned text field may be cleared when client-side state first attaches.
          // A form, a suggestion widget or a sensitive field can legitimately consume its input.
          if (!started) watch = !!component && e instanceof HTMLInputElement && e.value === '' && !form &&
            !e.closest('form,[role=combobox]') && !e.matches('[list],[multiple],[aria-autocomplete]');
          if (watch) {
            e.addEventListener('beforeinput', beforeEdit, true);
            e.addEventListener('input', edited, true);
          }
          existingFields = new WeakSet(root?.querySelectorAll('input,textarea') || []);
          recipient = null;
          parents = [];
          for (let p = e?.parentElement; p && parents.length < 3; p = p.parentElement) parents.push(p);
        }
        globalThis.__pbTyping?.dispose();
        remember(find(selector)[0]);
        globalThis.__pbTyping = {id, dispose, lostEdit: () => changedDuringKey || cleared(), restore(prefix) {
          if (repaired || !cleared() || prefix !== committed || /[\\s,;]/.test(prefix) ||
              fieldComponent(target) !== component || disabled(target) || target.readOnly || target.form ||
              target.closest('[inert],[aria-readonly="true"],[role=combobox]') || target.matches('[list],[multiple],[aria-autocomplete]')) return false;
          const r = target.getBoundingClientRect();
          if (!holds(target, at(r.x + r.width/2, r.y + r.height/2))) return false;
          repaired = true;
          confirming = prefix;
          return true;
        }, status(lineBreak) {
          let active = focused();
          const neutral = !active || active === document.body || active === document.documentElement;
          if (!target?.isConnected) {
            let matches = find(selector, true);
            if (component && !matches.length) matches = findIn(root, component);
            if (matches.length > 1) return 'ambiguous';
            const next = matches[0];
            if (!next) return neutral ? 'missing' : 'focus';
            if (started) {
              if (existingFields.has(next) || next.getRootNode() !== root || next.form !== form || next.localName !== target.localName ||
                  next.type !== target.type || next.name !== target.name || next.id !== target.id ||
                  next.getAttribute('autocomplete') !== target.getAttribute('autocomplete')) return 'changed';
              if (next instanceof HTMLInputElement || next instanceof HTMLTextAreaElement) {
                if (next.value !== target.value) return 'changed';
                const {selectionStart, selectionEnd, selectionDirection} = target;
                if (next !== active) {
                  if (!neutral) return 'focus';
                  const parent = parents.find(p => p.isConnected);
                  if (!parent?.contains(next) || (!next.id && !next.name && parent === document.body) ||
                      next.type === 'password' || /password|one-time-code|cc-/.test(next.autocomplete || '') ||
                      !next.value || selectionStart == null) return 'changed';
                  if (disabled(next) || next.readOnly || next.closest('[inert],[aria-readonly="true"]')) return 'changed';
                  const r = next.getBoundingClientRect();
                  if (!holds(next, at(r.x + r.width/2, r.y + r.height/2))) return 'idle';
                  next.focus({preventScroll:true});
                  active = focused();
                  if (active !== next || !next.isConnected || next.value !== target.value) return 'focus';
                }
                if (selectionStart != null && (next.selectionStart !== selectionStart || next.selectionEnd !== selectionEnd))
                  next.setSelectionRange(selectionStart, selectionEnd, selectionDirection);
              }
            }
            remember(next);
          }
          const field = target.closest('label')?.control || target;
          if (!active || (!holds(field, active) && !(target.isContentEditable && active.isContentEditable && holds(active, target))))
            return started && neutral ? 'idle' : 'focus';
          if (recipient && recipient !== active) return 'focus';
          if (disabled(active)) return 'disabled';
          if (active.readOnly || active.closest('[aria-readonly]')?.getAttribute('aria-readonly') === 'true') return 'readonly';
          if (changedDuringKey || (confirming !== null && target.value !== confirming)) return 'changed';
          confirming = null;
          if (cleared()) return 'cleared';
          started = true;
          recipient = active;
          return lineBreak && (active instanceof HTMLTextAreaElement || active.isContentEditable) ? 'multiline' : 'ready';
        }};
        return {focused: !!target && focused() === target, origin: location.origin};
        """

    private func typingIsMultiline(_ selector: String, id: String, lineBreak: Bool, prefix: String) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while true {
            try Task.checkCancellation()
            let state = try await isolated("const t = globalThis.__pbTyping; return t?.id === id ? t.status(lineBreak) : 'focus';",
                                           ["id": id, "lineBreak": lineBreak]) as? String
            switch state {
            case "ready": return false
            case "multiline": return true
            case "readonly": throw Failure.refused("\(selector) is read-only")
            case "disabled": throw Failure.refused("\(selector) is disabled")
            case "ambiguous": throw Failure.refused("multiple controls match \(selector)")
            case "changed": throw Failure.refused("typing target changed: \(selector)")
            case "cleared":
                guard !prefix.isEmpty,
                      try await isolated("const t = globalThis.__pbTyping; return t?.id === id && t.restore(prefix);",
                                         ["id": id, "prefix": prefix]) as? Bool == true else {
                    throw Failure.refused("typing target changed: \(selector)")
                }
                // Commit only the missing prefix. Replaying its key presses could run shortcuts twice.
                webView.insertText(prefix)
                try await Task.sleep(for: .milliseconds(60))
            case "missing", "idle":
                if ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(60))
                    continue
                }
                if state == "missing" { throw Failure.notFound(selector) }
                fallthrough
            default: throw Failure.refused("typing target lost focus: \(selector)")
            }
        }
    }

    /// Presses a key or a combination: "Enter", "Tab", "Shift+Tab", "Meta+a", "a".
    func press(_ combination: String) async throws {
        onLog?("press \(combination)")
        guard webView.window != nil else { throw Failure.noWindow }
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
        } else if last.count == 1, let character = last.first,
                  let typed = PageInput.key(typing: character) ?? (modifiers.contains(.command) ? PageInput.commandKey(for: character) : nil) {
            key = typed
        } else {
            throw Failure.untypeable(last)
        }
        key.modifiers.formUnion(modifiers)
        input.holdFocus()
        await willAct()
        await input.press(key, hold: Double.random(in: 0.05...0.12, using: &generator))
        try await pause(0.05...0.12)
        if modifiers == .command && last.lowercased() == "a" {
            // Direct key delivery to WebKit can skip AppKit's Select All menu command.
            // Complete it only inside the focused text field, before the next edit.
            _ = try await isolated(Self.findAll + """
                const e = focused();
                if ((e instanceof HTMLInputElement || e instanceof HTMLTextAreaElement)
                    && e.selectionStart !== null && (e.selectionStart !== 0 || e.selectionEnd !== e.value.length))
                  e.select();
                """)
        }
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
