import AppKit
import Carbon.HIToolbox
import ObjCExceptions
import WebKit

/// The sweep of a profile's window with real input (`--sweep`, CI: .github/workflows/sweep.yml):
/// what a customer does in a profile's Safari window, done with a keyboard and a mouse of the
/// window server's (`SweepInput`), and what came of each thing done.
///
/// A customer could not type into the address bar: at every key the window said "This Safari
/// feature is unavailable in the profile", while the same macOS on the owner's Mac typed. No check
/// saw it: each handed AppKit events it made itself to a window or a view, past Safari's own
/// application object and the input source, on a runner's Mac. This one goes the customer's way,
/// on the Mac states the workflow sets up (a new runner, a Russian Mac with a Russian keyboard, a
/// Mac whose Safari never ran), and writes down for every unit:
///
///   * every Objective-C exception thrown, with the frames below the throw, and those AppKit's run
///     loop caught, with the event it was handling;
///   * every notice the window would have put up (`SafariChrome.presentNotice`, recorded instead
///     of shown so that the sweep goes on);
///   * the main thread stopping for more than two seconds (`SweepWatchdog`);
///   * how many of its key presses and clicks arrived, what it expected and did not see, and the
///     windows that came up. A crash ends the process: the manager's side starts it again and the
///     sweep goes on from the next unit.
///
/// Asked for over the profile's channel (`ProfileCommand.sweep`) by `--sweep` only, never by the app.
@MainActor
enum SafariSweep {
    struct Step {
        let name: String
        let phase: String
        /// The unit ends the process (⌘Q): the manager starts it again and the sweep goes on.
        var endsProcess = false
        /// The step's units, found as it starts (a menu's items); nil: the step is one unit.
        var units: (@MainActor () async -> [String])?
        let run: @MainActor (Int) async -> Void
    }

    static let host = "sweep.selftest.invalid"
    static let pagePath = "/pb-sweep"
    static let secondPath = "/pb-sweep/two"

    private static var isRunning = false
    private static var send: (String) -> Void = { _ in }
    private static var session: BrowserSession?
    private static var walkRecorderOn = false

    /// Starts the sweep at step `from`, unit `sub` (after a crash, the unit after the one that
    /// crashed); `phases` empty: every step. `send` carries one line of JSON per message.
    static func start(from: Int, sub: Int, phases: [String], session: BrowserSession?, send: @escaping (String) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        Self.send = send
        Self.session = session
        installRecorders()
        SweepWatchdog.shared.start { index, seconds in
            SafariSweep.sendFromAnyThread("{\"event\":\"hang\",\"index\":\(index),\"seconds\":\(Int(seconds)),\"pid\":\(getpid())}")
        }
        Task { @MainActor in
            await bringForward()
            let window = browserWindow()
            let point = window.map { NSPoint(x: $0.frame.midX, y: $0.frame.maxY - 6) }
            let route = await SweepInput.chooseRoute(clickingAt: point)
            if let wanted = ProcessInfo.processInfo.environment["PB_SWEEP_INPUT_SOURCE"], !wanted.isEmpty {
                SweepRecord.add("notes", "input source \(wanted): " + (SweepInput.selectInputSource(wanted) ?? "not on this Mac"))
            }
            baseInputSource = SweepInput.inputSourceID()
            let all = steps()
            let chosen = phases.isEmpty ? all : all.filter { phases.contains($0.phase) }
            emit(["event": "list", "count": chosen.count, "from": from, "sub": sub, "route": route,
                  "inputSource": baseInputSource ?? "?", "names": chosen.map(\.name),
                  "language": Bundle.main.preferredLocalizations.first ?? "?",
                  "chrome": SafariChrome.chromeLanguage ?? "?", "start": SweepRecord.take()])
            var index = max(0, from)
            while index < chosen.count {
                let step = chosen[index]
                let usesRecorder = ["context", "keys", "menu"].contains(step.phase)
                if usesRecorder != walkRecorderOn { switchWalkRecorder(on: usesRecorder) }
                await bringForward()
                var names = [step.name]
                if let units = step.units {
                    names = await units()
                    emit(["event": "units", "index": index, "names": names, "found": SweepRecord.take()])
                    await restore(keeping: Set(NSApp.windows.map { ObjectIdentifier($0) }))
                }
                var unit = index == from ? max(0, sub) : 0
                while unit < names.count {
                    await runUnit(step, index: index, unit: unit, name: names[unit])
                    unit += 1
                }
                index += 1
            }
            if walkRecorderOn { switchWalkRecorder(on: false) }
            emit(["event": "done"])
            isRunning = false
        }
    }

    // MARK: Running a unit

    private static func runUnit(_ step: Step, index: Int, unit: Int, name: String) async {
        await bringForward()
        if let base = baseInputSource, SweepInput.inputSourceID() != base { SweepInput.selectInputSource(base) }
        let windowsBefore = Set(NSApp.windows.map { ObjectIdentifier($0) })
        _ = SweepRecord.take()
        _ = WalkRecorder.take()
        SweepWatchdog.shared.setStep(index)
        let shown = step.units == nil ? step.name : "\(step.name) › \(name)"
        emit(["event": "begin", "index": index, "sub": unit, "name": shown, "phase": step.phase, "ends": step.endsProcess,
              "time": Date().timeIntervalSince1970])
        await step.run(unit)
        await SweepInput.pause(0.4)
        var fields = SweepRecord.take()
        let walked = WalkRecorder.take()
        if !walked.effects.isEmpty { fields["answered"] = walked.effects }
        var opened: [String] = []
        for window in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(window)) && window.isVisible {
            opened.append(SafariMenuWalk.describe(window))
        }
        fields["opened"] = opened
        fields["state"] = state()
        fields["event"] = "end"
        fields["index"] = index
        fields["sub"] = unit
        fields["name"] = shown
        fields["phase"] = step.phase
        fields["time"] = Date().timeIntervalSince1970
        emit(fields)
        await restore(keeping: windowsBefore)
        // What the way back to the window raised belongs to the unit before it.
        var after = SweepRecord.take()
        let interesting = ["thrown", "caught", "notices"].contains { (after[$0] as? [String])?.isEmpty == false }
            || (after["hangs"] as? [Double])?.isEmpty == false
        if interesting {
            after["event"] = "after"
            after["index"] = index
            after["sub"] = unit
            emit(after)
        }
    }

    /// The input source the sweep runs with (`PB_SWEEP_INPUT_SOURCE`, else the Mac's): put back
    /// before each unit, after one that chose another.
    private(set) static var baseInputSource: String?

    private static func emit(_ fields: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            send("{\"event\":\"error\",\"what\":\"a line that is not JSON\"}")
            return
        }
        send(String(decoding: data, as: UTF8.self))
    }

    /// A line from the watchdog's thread, written as `ProfileSessionHost.send` writes one.
    nonisolated static func sendFromAnyThread(_ line: String) {
        guard let data = ProfileChannel.encode(ProfileEvent.sweep(line), prefix: ProfileChannel.eventPrefix) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func state() -> String {
        let window = browserWindow()
        let page = window.flatMap { SafariChromeHost.frontPage(in: $0) }
        let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
        let key = NSApp.keyWindow.map { SafariMenuWalk.describe($0) } ?? "-"
        return "active \(NSApp.isActive), key \(key), responder \(responder), page \(page?.url?.absoluteString ?? "-"), "
            + "tabs \(tabCount()), input \(SweepInput.inputSourceID() ?? "?")"
    }

    // MARK: What is recorded

    private static func installRecorders() {
        hookExceptions()
        let previousCaught = ExceptionLog.onCaughtInRunLoop
        ExceptionLog.onCaughtInRunLoop = { exception, eventType in
            SweepRecord.add("caught", "\(exception.name.rawValue) while handling \(SafariSweep.eventName(eventType))")
            previousCaught?(exception, eventType)
        }
        SafariChrome.presentNotice = { title, text in SweepRecord.add("notices", "\(title) — \(text)") }
        let previousSettings = SafariChrome.onShowSettings
        SafariChrome.onShowSettings = {
            SweepRecord.add("notes", "asked the manager for its Settings")
            previousSettings?()
        }
        SweepMenus.install()
    }

    /// Every exception thrown goes into the unit's record, and on to `chained` (the menu walk's
    /// recorder, while it is on).
    private static func hookExceptions(chained: ((String, String, [String]) -> Void)? = nil) {
        ExceptionLog.onThrown = { name, reason, frames in
            SweepRecord.add("thrown", SweepRecord.describeThrow(name, reason, frames))
            chained?(name, reason, frames)
        }
    }

    /// The menu walk's recorder (`WalkRecorder`) while menus are walked: a panel, an alert or a
    /// request to open something outside the profile is answered with its cancel and written down,
    /// so that a menu's item neither waits for a click nor reaches outside the profile.
    private static func switchWalkRecorder(on: Bool) {
        if on {
            WalkRecorder.install()
            let walker = ExceptionLog.onThrown
            hookExceptions(chained: walker)
            SafariChrome.presentNotice = { title, text in SweepRecord.add("notices", "\(title) — \(text)") }
        } else {
            WalkRecorder.uninstall()
            hookExceptions()
            SafariChrome.presentNotice = { title, text in SweepRecord.add("notices", "\(title) — \(text)") }
        }
        walkRecorderOn = on
    }

    nonisolated static func eventName(_ type: NSEvent.EventType?) -> String {
        guard let type else { return "no event" }
        switch type {
        case .keyDown: return "a key press"
        case .keyUp: return "a key's release"
        case .flagsChanged: return "a modifier key"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return "a mouse press"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return "a mouse release"
        case .scrollWheel: return "the wheel"
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged: return "a mouse move"
        case .appKitDefined, .systemDefined, .applicationDefined: return "an event of the system's (\(type.rawValue))"
        case .periodic: return "a timer"
        default: return "event type \(type.rawValue)"
        }
    }

    static func note(_ text: String) { SweepRecord.add("notes", text) }

    static func expect(_ holds: Bool, _ text: String) {
        SweepRecord.add(holds ? "notes" : "failed", (holds ? "as expected: " : "") + text)
    }

    // MARK: The window

    static func browserWindow() -> NSWindow? {
        NSApp.windows.first { SafariChromeHost.isBrowserWindow($0) && $0.isVisible && $0.isKeyWindow }
            ?? NSApp.windows.first { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }
    }

    static func browserWindowCount() -> Int {
        NSApp.windows.filter { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }.count
    }

    /// A browser window of the profile's in front and key, opening one if the last unit closed
    /// every one.
    private static func bringForward() async {
        var window = browserWindow()
        if window == nil, let session {
            _ = SafariChromeHost.open(session: session, url: URL(string: "http://\(host)\(pagePath)"))
            await SweepInput.pause(2.5)
            window = browserWindow()
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !NSApp.isActive || !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await SweepInput.pause(0.4)
        }
    }

    /// Back to where a unit began: no menu open, nothing modal, no sheet, no window minimized or in
    /// full screen, the app shown, and the windows the unit opened closed.
    private static func restore(keeping windows: Set<ObjectIdentifier>) async {
        if let menu = SweepMenus.tracked {
            menu.cancelTracking()
            SweepMenus.tracked = nil
            await SweepInput.pause(0.2)
        }
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        if NSApp.isHidden { NSApp.unhide(nil) }
        var leftFullScreen = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                leftFullScreen = true
            }
        }
        for window in NSApp.windows where !windows.contains(ObjectIdentifier(window)) && window.isVisible {
            // Never the last browser window: closing it ends the profile.
            if SafariChromeHost.isBrowserWindow(window), browserWindowCount() < 2 { continue }
            window.close()
        }
        await SweepInput.pause(leftFullScreen ? 3 : 0.3)
    }

    static func addressField() -> NSTextField? {
        guard let window = browserWindow(), let root = window.contentView?.superview else { return nil }
        var first: NSTextField?
        var unified: NSTextField?
        func search(_ view: NSView) {
            guard unified == nil else { return }
            if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor {
                if NSStringFromClass(type(of: field)).contains("UnifiedField") {
                    unified = field
                    return
                }
                if first == nil { first = field }
            }
            for subview in view.subviews { search(subview) }
        }
        search(root)
        return unified ?? first
    }

    static func fieldText(_ field: NSTextField?) -> String {
        guard let field else { return "(no field)" }
        return (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    static func frontPage() -> WKWebView? {
        browserWindow().flatMap { SafariChromeHost.frontPage(in: $0) }
    }

    static func tabCount() -> Int {
        guard let window = browserWindow() else { return 0 }
        return SafariTabs.tabs().filter { $0.window === window }.count
    }

    static func selectedTab() -> Int {
        guard let window = browserWindow() else { return -1 }
        return SafariTabs.tabs().filter { $0.window === window }.firstIndex(where: \.isSelected) ?? -1
    }

    /// At least `count` tabs in the window, opened as File › New Tab at End and the address bar do.
    static func ensureTabs(_ count: Int) async {
        guard let window = browserWindow(), let url = URL(string: "http://\(host)\(secondPath)") else { return }
        var tries = 0
        while tabCount() < count, tries < count + 2 {
            _ = await SafariTabs.openTab(url, in: window)
            tries += 1
            await SweepInput.pause(0.8)
        }
    }

    /// The sweep's page in the tab in front (`path` of it), loaded if it is not there.
    @discardableResult
    static func ensurePage(_ path: String = pagePath) async -> WKWebView? {
        guard let page = frontPage() else {
            note("no page in the window")
            return nil
        }
        if page.url?.host != host || page.url?.path != path {
            guard let url = URL(string: "http://\(host)\(path)") else { return page }
            page.load(URLRequest(url: url))
            _ = await waitForLoad(page, path: path)
            await SweepInput.pause(0.3)
        }
        return page
    }

    @discardableResult
    static func waitForLoad(_ page: WKWebView?, path: String?, seconds: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let current = page ?? frontPage()
            if let current, !current.isLoading, path == nil || current.url?.path == path { return true }
            await SweepInput.pause(0.2)
        }
        return false
    }

    /// The page's answer to a script, in a world of its own; nil after five seconds.
    static func script(_ body: String, arguments: [String: Any] = [:], in page: WKWebView? = nil) async -> Any? {
        guard let page = page ?? frontPage() else { return nil }
        let once = ScriptAnswer()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            once.continuation = continuation
            page.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): once.finish(value)
                case .failure: once.finish(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.finish(nil) }
        }
    }

    /// Where an element of the page in front is on the screen (AppKit's space), scrolled into view
    /// first; nil when the page has none.
    static func pagePoint(_ selector: String) async -> NSPoint? {
        guard let page = frontPage() else { return nil }
        let body = """
        const element = document.querySelector(selector);
        if (!element) { return null; }
        element.scrollIntoView({block: 'center'});
        const r = element.getBoundingClientRect();
        return [r.left + Math.min(r.width / 2, 30), r.top + r.height / 2, window.innerWidth, window.innerHeight];
        """
        guard let values = await script(body, arguments: ["selector": selector], in: page) as? [Any] else { return nil }
        let numbers = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        let scale = page.bounds.width / CGFloat(numbers[2])
        let inset = max(0, page.bounds.height - CGFloat(numbers[3]) * scale)
        let fromTop = inset + CGFloat(numbers[1]) * scale
        let local = NSPoint(x: CGFloat(numbers[0]) * scale, y: page.isFlipped ? fromTop : page.bounds.height - fromTop)
        guard let window = page.window else { return nil }
        return window.convertPoint(toScreen: page.convert(local, to: nil))
    }

    /// What the page last saw happen (its own listener: the event and the element's id).
    static func pageSaw() async -> String {
        (await script("return document.body ? (document.body.dataset.last || '-') : '-';") as? String) ?? "(no answer)"
    }

    static func center(of view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        return window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    static func zoomText() -> String {
        guard let page = frontPage() else { return "-" }
        return String(format: "%.2f", page.pageZoom)
    }

    // MARK: Keys

    static func escape() async { await SweepInput.press(kVK_Escape) }

    static func command(_ code: Int, _ more: CGEventFlags = []) async {
        await SweepInput.press(code, CGEventFlags.maskCommand.union(more))
    }

    /// ⌘L, as a person goes to the address bar: what the field then is.
    static func focusAddressBar() async {
        await command(kVK_ANSI_L)
        await SweepInput.pause(0.4)
    }

    // MARK: Menus that open

    /// The menu `open` brings up, as tracking begins; nil when none came within two seconds.
    static func openMenu(_ open: @MainActor () async -> Void) async -> NSMenu? {
        SweepMenus.tracked = nil
        await open()
        for _ in 0..<20 {
            if let menu = SweepMenus.tracked { return menu }
            await SweepInput.pause(0.1)
        }
        return nil
    }

    /// The items the arrow keys stop at, in order.
    static func stops(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.isEnabled && !$0.isAlternate }
    }

    /// One line per item of an open menu: its title, its identifier or action, and whether it has
    /// a submenu or is off.
    static func describeMenu(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
            let id = item.identifier?.rawValue ?? item.action.map(NSStringFromSelector) ?? "-"
            return "\(item.title) [\(id)]\(item.submenu != nil ? " ›" : "")\(item.isEnabled ? "" : " (off)")"
        }
    }

    /// Goes down `menu` with the arrow keys to `item`, as a person does with the keyboard. Nil when
    /// it is there; else why not. A menu that does not say which item is highlighted is counted:
    /// `first` is the place the arrows start from (-1: before the first item).
    static func arrow(to item: NSMenuItem, in menu: NSMenu, key: Int = kVK_DownArrow, first: Int = -1) async -> String? {
        let places = stops(in: menu)
        var presses = 0
        var readable = menu.highlightedItem != nil
        while menu.highlightedItem !== item, presses < places.count + 3 {
            await SweepInput.press(key)
            presses += 1
            await SweepInput.pause(0.12)
            if menu.highlightedItem != nil { readable = true }
            if !readable, presses >= 2 { break }
        }
        if menu.highlightedItem === item { return nil }
        if readable {
            return "the arrows did not reach it (highlighted: \(menu.highlightedItem?.title ?? "nothing"))"
        }
        guard let place = places.firstIndex(where: { $0 === item }) else { return "the arrows do not stop at it" }
        let remaining = place - first - presses
        if remaining > 0 {
            for _ in 0..<remaining {
                await SweepInput.press(key)
                await SweepInput.pause(0.12)
            }
        }
        note("reached by counting the arrows: the menu does not say what is highlighted")
        return nil
    }

    /// Chooses `item` of the open `menu` with the arrow keys and Return. Nil when chosen.
    static func choose(_ item: NSMenuItem, in menu: NSMenu) async -> String? {
        if let why = await arrow(to: item, in: menu) {
            await escape()
            return why
        }
        await SweepInput.press(kVK_Return)
        return nil
    }

    // MARK: The steps

    static func steps() -> [Step] {
        var list: [Step] = []
        func add(_ name: String, _ phase: String, ends: Bool = false, units: (@MainActor () async -> [String])? = nil,
                 _ run: @escaping @MainActor (Int) async -> Void) {
            list.append(Step(name: name, phase: phase, endsProcess: ends, units: units, run: run))
        }
        add("address bar: a click on it, then Latin typed key by key", "address") { _ in await SweepSteps.addressLatin() }
        add("address bar: ⌘L, then Cyrillic as key events that carry it", "address") { _ in await SweepSteps.addressCyrillicCarried() }
        add("address bar: Cyrillic typed on a Russian keyboard layout", "address",
            units: { SweepSteps.russianLayouts.map { $0.1 } }) { unit in await SweepSteps.addressRussianLayout(unit) }
        add("address bar: an input method that composes", "address",
            units: { SweepSteps.inputMethods.map { $0.1 } }) { unit in await SweepSteps.addressInputMethod(unit) }
        add("address bar: ⌘V pastes an address, Return goes there", "address") { _ in await SweepSteps.addressPaste() }
        add("address bar: the suggestions, with the arrow keys", "address") { _ in await SweepSteps.addressSuggestions() }
        add("address bar: a search, with Return", "address") { _ in await SweepSteps.addressSearch() }
        add("address bar: Escape puts the address back", "address") { _ in await SweepSteps.addressEscape() }
        add("address bar: editing keys (arrows, Delete, ⌘A)", "address") { _ in await SweepSteps.addressEditing() }
        add("address bar: an address typed, with Return", "address") { _ in await SweepSteps.addressGo() }
        add("tabs: ⌘T, an address typed into the new tab", "tabs") { _ in await SweepSteps.newTab() }
        add("tabs: ⌘W closes a tab", "tabs") { _ in await SweepSteps.closeTab() }
        add("tabs: ⇧⌘T reopens it", "tabs") { _ in await SweepSteps.reopenTab() }
        add("tabs: ⌘1 to ⌘9", "tabs") { _ in await SweepSteps.numberedTabs() }
        add("tabs: ⌃Tab and ⌃⇧Tab", "tabs") { _ in await SweepSteps.controlTab() }
        add("tabs: a tab's context menu", "tabs", units: { await SweepSteps.tabMenuUnits() }) { unit in await SweepSteps.tabMenu(unit) }
        add("page: find ⌘F, typed, Return, ⌘G, Escape", "page") { _ in await SweepSteps.find() }
        add("page: Reader ⇧⌘R, on and off", "page") { _ in await SweepSteps.reader() }
        add("page: zoom ⌘+ ⌘- ⌘0", "page") { _ in await SweepSteps.zoom() }
        add("page: a click on a link, back ⌘[ and forward ⌘]", "page") { _ in await SweepSteps.linkAndBack() }
        add("page: typing into a page's field", "page") { _ in await SweepSteps.pageField() }
        add("page: the wheel", "page") { _ in await SweepSteps.wheel() }
        add("page: a download, by a click on its link", "page") { _ in await SweepSteps.download() }
        add("page: print ⌘P, cancelled with Escape", "page") { _ in await SweepSteps.printPage() }
        add("page: the Share button", "page") { _ in await SweepSteps.share() }
        add("page: reload ⌘R and stop ⌘.", "page") { _ in await SweepSteps.reload() }
        for context in SweepSteps.contexts {
            add("context menu: \(context)", "context", units: { await SweepSteps.contextUnits(context) }) { unit in
                await SweepSteps.contextItem(context, unit)
            }
        }
        add("bookmarks: ⌘D adds one", "library") { _ in await SweepSteps.addBookmark() }
        add("bookmarks: the sidebar ⇧⌘L and ⌃⌘1, a click in it", "library") { _ in await SweepSteps.sidebar() }
        add("bookmarks: Edit Bookmarks ⌥⌘B", "library") { _ in await SweepSteps.editBookmarks() }
        add("bookmarks: the favorites bar ⇧⌘B, a click on a favorite", "library") { _ in await SweepSteps.favoritesBar() }
        add("history: ⌘Y, typed into its search", "library") { _ in await SweepSteps.history() }
        add("window: full screen ⌃⌘F, and back", "window") { _ in await SweepSteps.fullScreen() }
        add("window: minimize ⌘M", "window") { _ in await SweepSteps.minimize() }
        add("window: ⌘N, an address typed, ⌘W", "window") { _ in await SweepSteps.newWindow() }
        add("window: Settings ⌘,", "window") { _ in await SweepSteps.settings() }
        add("keys: every key equivalent of the menu bar", "keys", units: { SweepSteps.shortcutUnits() }) { unit in
            await SweepSteps.shortcut(unit)
        }
        add("menu bar: every item, chosen by a click and the arrow keys", "menu", units: { SweepSteps.menuBarUnits() }) { unit in
            await SweepSteps.menuItem(unit)
        }
        add("quit: ⌘Q", "quit", ends: true) { _ in await SweepSteps.quit() }
        add("after the relaunch: the windows, the tabs, typing", "quit") { _ in await SweepSteps.afterRelaunch() }
        return list
    }
}

/// Waits once for a page's answer to a script (on the main thread: WebKit's answer and the timeout
/// both come there).
private final class ScriptAnswer {
    var continuation: CheckedContinuation<Any?, Never>?

    func finish(_ value: Any?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// The menu being tracked — a context menu, the menu bar — as AppKit says when tracking begins.
final class SweepMenus: @unchecked Sendable {
    nonisolated(unsafe) static var tracked: NSMenu?
    /// When the last tracking ended (the system's uptime).
    nonisolated(unsafe) static var lastTrackingEnd: TimeInterval = 0
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            SweepMenus.tracked = note.object as? NSMenu
        }
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { note in
            SweepMenus.lastTrackingEnd = ProcessInfo.processInfo.systemUptime
            if let menu = note.object as? NSMenu, menu === SweepMenus.tracked { SweepMenus.tracked = nil }
        }
    }
}
