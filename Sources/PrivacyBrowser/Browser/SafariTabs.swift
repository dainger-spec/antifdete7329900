import AppKit
import BrowserCore
import ObjCExceptions
import os
import WebKit

/// The tabs of Safari's windows in a profile's process: read, so that a profile shown in Safari's
/// window leaves its tabs for its next start (Settings → Startup → Restore tabs, `OpenTabs`), and
/// opened again at that start; and a new tab on an address, as ⌘T and the address bar make one.
///
/// Until 15 November the setting worked only in a window of ours (an iPhone view, the simplified
/// mode): `BrowserSession` kept the tabs of its own windows and opened them again, while a profile
/// in Safari's window — every Mac profile — started on its start page whatever it had left open.
/// Safari's own way back to a session is its saved window state, which a profile's window does not
/// have (`SafariChrome.disableStateRestoration`: it would be written outside the profile's home),
/// so History › Reopen All Windows from Last Session is disabled there. The tabs are kept the
/// profile's way instead: their addresses alone, encrypted with the profile's key (`tabs.bin`).
///
/// What is Safari's here is private, so each step is tried and none is relied on:
///   * the tabs are the ones Safari hands out for every window
///     (`+[BrowserWindowController allBrowserTabViewItemsFromAllWindows]`, which a profile's first
///     window already needs);
///   * a tab's address is asked of the tab by the names Safari has for it, then of the tab's web
///     view; with neither, each window is read as the one page in front of it — the profile then
///     gets that page back, not its other tabs, and `source` says so;
///   * a tab is opened by Safari's own File › New Tab at End and the tab's `loadURL:`, the tab
///     that was shown is reached with Window › Show Next Tab or Show Previous Tab. When one of
///     them is not taken, the tabs opened so far stay and nothing else is tried.
@MainActor
enum SafariTabs {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariTabs")

    /// One tab of Safari's, as it stands.
    struct Tab {
        let item: NSObject
        let window: NSWindow?
        let url: URL?
        let title: String?
        let isSelected: Bool
    }

    /// How the tabs' pages were last read — for the log and the self-test.
    private(set) static var source = "not read yet"

    // MARK: Reading

    /// Safari's names for a tab's address, in the order they are tried.
    private static let addressGetters = ["URL", "URLString", "expectedOrCurrentURL"]

    /// How a tab's page is read from a tab of a class: by one of Safari's names for its address,
    /// from its web view, or not at all.
    private enum Reading {
        case address(String)
        case webView
        case none
    }

    private static var readings: [String: Reading] = [:]
    /// Names that told no page for a tab whose page was in front of its window (`readingHolds`).
    private static var distrusted: Set<String> = []

    /// The tabs Safari hands out, of every window, in its order.
    private static func items() -> [NSObject] {
        guard SafariChromeHost.isHosting, let windowClass: AnyObject = NSClassFromString("BrowserWindowController") else { return [] }
        let selector = NSSelectorFromString("allBrowserTabViewItemsFromAllWindows")
        guard windowClass.responds(to: selector) else { return [] }
        var found: [NSObject] = []
        if let exception = PBCatchException({
            found = (windowClass.perform(selector)?.takeUnretainedValue() as? [AnyObject] ?? []).compactMap { $0 as? NSObject }
        }) {
            log.error("Safari's list of tabs threw \(exception.name.rawValue, privacy: .public)")
            return []
        }
        return found
    }

    /// Whether `item`'s class has a method `name` that takes nothing and returns an object: only
    /// such a method is called — its result read as an object, anything else would end the process.
    private static func returnsObject(_ item: NSObject, _ name: String) -> Bool {
        guard let method = class_getInstanceMethod(object_getClass(item), NSSelectorFromString(name)),
              method_getNumberOfArguments(method) == 2, let encoding = method_getTypeEncoding(method) else { return false }
        return String(cString: encoding).hasPrefix("@")
    }

    /// What `item`'s method `name` returns (checked by `returnsObject` first); nil when it throws.
    private static func object(_ item: NSObject, _ name: String) -> AnyObject? {
        var value: AnyObject?
        if let exception = PBCatchException({ value = item.perform(NSSelectorFromString(name))?.takeUnretainedValue() }) {
            log.error("A tab of Safari's threw \(exception.name.rawValue, privacy: .public) when asked for its page")
            return nil
        }
        return value
    }

    private static func reading(for item: NSObject) -> Reading {
        let className = NSStringFromClass(type(of: item))
        if let known = readings[className] { return known }
        let found: Reading
        if let name = addressGetters.first(where: { !distrusted.contains($0) && returnsObject(item, $0) }) {
            found = .address(name)
        } else if returnsObject(item, "webView") {
            found = .webView
        } else {
            found = .none
        }
        readings[className] = found
        return found
    }

    /// A way of reading that tells no page for the tab in front of a window whose page is a web
    /// page does not tell this Safari's tabs' pages.
    private static func readingHolds(_ open: [Tab]) -> Bool {
        for tab in open where tab.isSelected && tab.url == nil {
            guard let window = tab.window, let front = SafariChromeHost.frontPage(in: window)?.url,
                  OpenTabs.isRestorable(front) else { continue }
            return false
        }
        return true
    }

    /// The next way of reading the tabs of `item`'s class, after one that did not hold. False when
    /// there is none left.
    private static func demote(_ item: NSObject) -> Bool {
        let className = NSStringFromClass(type(of: item))
        switch reading(for: item) {
        case .address(let name):
            distrusted.insert(name)
            readings[className] = nil
            return true
        case .webView:
            readings[className] = Reading.none
            return true
        case .none:
            return false
        }
    }

    private static func webView(of item: NSObject) -> WKWebView? {
        returnsObject(item, "webView") ? object(item, "webView") as? WKWebView : nil
    }

    /// The tab's page; nil for a tab without one, and for a tab left on an address that became a
    /// download (a link to a file opened in a tab of its own): that is no page to open again.
    private static func address(of item: NSObject) -> URL? {
        guard let url = statedAddress(of: item), !HostedDownloads.shared.addresses.contains(url) else { return nil }
        return url
    }

    private static func statedAddress(of item: NSObject) -> URL? {
        switch reading(for: item) {
        case .address(let name):
            let value = object(item, name)
            if let url = value as? URL { return url }
            // A tab that fails to load keeps the address it was sent to, which its web view does not.
            if let text = value as? String, !text.isEmpty { return URL(string: text) }
            return nil
        case .webView:
            return webView(of: item)?.url
        case .none:
            return nil
        }
    }

    private static func window(of item: NSObject) -> NSWindow? {
        if let window = (item as? NSTabViewItem)?.tabView?.window { return window }
        if returnsObject(item, "browserWindowController"),
           let controller = object(item, "browserWindowController") as? NSWindowController { return controller.window }
        return webView(of: item)?.window
    }

    private static func isSelected(_ item: NSObject, in window: NSWindow?) -> Bool {
        if let tab = item as? NSTabViewItem, let tabView = tab.tabView { return tabView.selectedTabViewItem === tab }
        guard let window, let page = webView(of: item) else { return false }
        return SafariChromeHost.frontPage(in: window) === page
    }

    /// A window whose tabs are the profile's: one of Safari's browser windows that is on screen or
    /// in the Dock, and the person's — not the window of a scenario's run or a WebDriver session,
    /// whose pages are the run's (as a warm-up's window, in ours, is none of the profile's tabs).
    private static func isOpen(_ window: NSWindow) -> Bool {
        SafariChromeHost.isBrowserWindow(window) && (window.isVisible || window.isMiniaturized)
            && !SafariChromeHost.isAutomationWindow(window)
    }

    /// Every tab of Safari's open windows, window by window as Safari lists them, each window's in
    /// the order its tab bar has them. A tab whose window Safari does not tell is taken for a tab
    /// of the window of the tab listed before it.
    static func tabs(excluding closing: NSWindow? = nil) -> [Tab] {
        let listed = items()
        var windows: [NSWindow?] = listed.map(window(of:))
        var last: NSWindow?
        for index in windows.indices {
            if let window = windows[index] { last = window } else { windows[index] = last }
        }
        if let first = windows.compactMap({ $0 }).first {
            for index in windows.indices where windows[index] == nil { windows[index] = first }
        }
        var read: [Tab] = []
        for (item, window) in zip(listed, windows) {
            guard let window, window !== closing, isOpen(window) else { continue }
            let title = (item as? NSTabViewItem)?.label ?? webView(of: item)?.title
            read.append(Tab(item: item, window: window, url: address(of: item), title: title,
                            isSelected: isSelected(item, in: window)))
        }
        // Each window's tabs in its tab bar's order, where the tabs say which that is.
        func place(_ tab: Tab) -> Int? {
            guard let item = tab.item as? NSTabViewItem, let index = item.tabView?.indexOfTabViewItem(item), index != NSNotFound else { return nil }
            return index
        }
        if read.allSatisfy({ place($0) != nil }) {
            var order: [ObjectIdentifier: Int] = [:]
            for tab in read {
                guard let window = tab.window else { continue }
                if order[ObjectIdentifier(window)] == nil { order[ObjectIdentifier(window)] = order.count }
            }
            read.sort { first, second in
                let one = first.window.flatMap { order[ObjectIdentifier($0)] } ?? 0
                let two = second.window.flatMap { order[ObjectIdentifier($0)] } ?? 0
                return one != two ? one < two : (place(first) ?? 0) < (place(second) ?? 0)
            }
        }
        return read
    }

    /// What Safari's open windows hold, as a start can open it again, and whether there was a
    /// window to read at all. Read from Safari's tabs; when this Safari's tabs tell no page, from
    /// the page in front of each window.
    static func snapshot(excluding closing: NSWindow? = nil) -> (windows: [OpenTabs.Window], looked: Bool) {
        var open = tabs(excluding: closing)
        // A name of Safari's that does not tell the page in front is not the tab's address: the
        // next one, then the tab's web view, then the windows' pages in front.
        var tried = 0
        while tried < addressGetters.count + 1, let first = open.first, !readingHolds(open), demote(first.item) {
            open = tabs(excluding: closing)
            tried += 1
        }
        if let first = open.first, readingHolds(open) {
            var told = false
            switch reading(for: first.item) {
            case .address(let name):
                source = "Safari's tabs, by their -\(name)"
                told = true
            case .webView:
                // Told by the web views only where the tabs do hand out web views.
                source = "Safari's tabs, by their web views"
                told = open.contains { webView(of: $0.item) != nil }
            case .none:
                break
            }
            if told {
                var numbers: [ObjectIdentifier: Int] = [:]
                let seen = open.map { tab -> ObservedTab in
                    let key = tab.window.map { ObjectIdentifier($0) }
                    let number = key.flatMap { numbers[$0] } ?? numbers.count
                    if let key { numbers[key] = number }
                    return ObservedTab(window: number, url: tab.url, isSelected: tab.isSelected)
                }
                return (OpenTabs.windows(of: seen), true)
            }
        }
        let windows = NSApp.windows.filter { $0 !== closing && isOpen($0) }
        source = "the page in front of each window (this Safari's tabs tell no page)"
        let seen = windows.enumerated().map { ObservedTab(window: $0.offset, url: SafariChromeHost.frontPage(in: $0.element)?.url, isSelected: true) }
        return (OpenTabs.windows(of: seen), !windows.isEmpty)
    }

    // MARK: Keeping

    private static var timer: Timer?
    /// A start is opening the tabs the profile left: what is read meanwhile is only part of them.
    private(set) static var isReopening = false
    /// A start could not open every tab the profile left (this Safari makes no tab our way): what
    /// was kept stays as it is for the next start, rather than shrinking to what did open.
    private(set) static var reopenedInPart = false
    /// The profile's last window has closed, or every window is closing for a stop: what the
    /// profile leaves open has been read, and windows on their way out are not read again.
    private static var isLeaving = false

    /// Keeps the profile's session told what Safari's windows hold, from the first window on: a
    /// tab closes and a page changes with nothing to hear it by, so the windows are read every few
    /// seconds while the person is in them — Safari's list of tabs asks the window server, and
    /// thirty profiles in the background must not each ask it for nothing (docs/SCALE.md) — and
    /// once more as the app leaves the front, as a window closes and as the profile stops (`note`).
    static func follow() {
        // A window opened after the last one closed is read again.
        isLeaving = false
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApp.isActive { SafariTabs.note() }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SafariTabs.note() }
        }
    }

    /// Reads Safari's windows and tells the profile's session what they hold (`BrowserSession`),
    /// which a stop keeps for the next start. `closing`: a window on its way out — the last one's
    /// tabs are what the profile leaves (`isLast`), another one's are gone with it.
    ///
    /// Nothing is told while the setting is off (a stop then forgets what was kept), while a start
    /// is still opening tabs or could not open them all, or when there was no window to read. The
    /// last window may have let its tabs go by the time its closing is heard: read empty then,
    /// what was read a moment before stands. `leaving`: every window is about to be closed for a
    /// stop — read now, and not again as they go.
    static func note(closing: NSWindow? = nil, isLast: Bool = false, leaving: Bool = false) {
        guard SafariChromeHost.isHosting, !isLeaving else { return }
        defer { if isLast || leaving { isLeaving = true } }
        guard !isReopening, !reopenedInPart, BrowsingPreferences.current.restoreTabs,
              let session = ProfileNetworkGuard.session else { return }
        let read = snapshot(excluding: isLast ? nil : closing)
        guard read.looked else { return }
        let tabs = OpenTabs(windows: read.windows)
        if isLast, tabs.windows.isEmpty { return }
        session.keepOpenTabs(tabs)
    }

    // MARK: Opening

    /// What the last of Safari's actions sent from here threw, if one did (the self-test reads it).
    private(set) static var lastException: String?

    /// One of Safari's menu actions sent to `window` as its menu item sends it — to the item's own
    /// target where the menu names one, else to whatever in the window's responder chain takes it
    /// — whichever window has the keyboard: a start's tabs are opened while the app may not be in
    /// front, when an action sent to nobody in particular finds no window to go to. False when
    /// nothing takes any of `names`.
    @discardableResult
    static func send(_ names: [String], to window: NSWindow) -> Bool {
        for selectorName in names {
            let action = NSSelectorFromString(selectorName)
            let item = NSApp.mainMenu.flatMap { menuItem(with: action, in: $0) }
            var named: AnyObject?
            if let own = item?.target, own.responds(to: action) { named = own }
            guard let target = named ?? responder(to: action, in: window, sender: item) else { continue }
            var taken = false
            if let exception = PBCatchException({ taken = NSApp.sendAction(action, to: target, from: item) }) {
                log.error("Safari's \(selectorName, privacy: .public) threw \(exception.name.rawValue, privacy: .public)")
                lastException = "\(exception.name.rawValue): \(LogRedaction.exceptionReason(exception.reason ?? ""))"
                continue
            }
            if taken { return true }
        }
        return false
    }

    /// What takes `action` in `window`, in the order AppKit asks: the first responder and those
    /// after it, the window, its delegate, its controller and document, the application and its
    /// delegate — each for itself, then for whom it names to take the action in its place; and,
    /// with none of them, whoever AppKit itself finds from the window that has the keyboard.
    private static func responder(to action: Selector, in window: NSWindow, sender: Any?) -> AnyObject? {
        var chain: [AnyObject] = []
        var next: NSResponder? = window.firstResponder
        while let responder = next, chain.count < 64 {
            chain.append(responder)
            next = responder.nextResponder
        }
        chain.append(window)
        if let delegate = window.delegate { chain.append(delegate) }
        if let controller = window.windowController {
            chain.append(controller)
            if let document = controller.document { chain.append(document as AnyObject) }
        }
        chain.append(NSApp)
        if let delegate = NSApp.delegate { chain.append(delegate) }
        for candidate in chain {
            if candidate.responds(to: action) { return candidate }
            if let responder = candidate as? NSResponder, let named = responder.supplementalTarget(forAction: action, sender: sender) {
                return named as AnyObject
            }
        }
        return NSApp.target(forAction: action, to: nil, from: sender).map { $0 as AnyObject }
    }

    private static func menuItem(with action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let found = item.submenu.flatMap({ menuItem(with: action, in: $0) }) { return found }
        }
        return nil
    }

    /// A new tab of `window` on `address`, after its last one, as File › New Tab at End and the
    /// address bar make it. False when this Safari makes no tab that way, or the tab does not take
    /// the address.
    @discardableResult
    static func openTab(_ address: URL, in window: NSWindow) async -> Bool {
        let before = Set(items().map { ObjectIdentifier($0) })
        guard send(["newTabAtEndFromFileMenu:", "newTabFromFileMenu:"], to: window) else {
            log.error("Safari's window took no New Tab")
            return false
        }
        // Safari makes the tab as the action runs; a few turns of the run loop all the same.
        for _ in 0..<20 {
            if let tab = items().last(where: { !before.contains(ObjectIdentifier($0)) }) {
                return SafariChrome.load(address, in: tab)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log.error("Safari's New Tab made no tab")
        return false
    }

    /// The tab of `window` that is `wanted` in its tab bar brought in front, by Window › Show Next
    /// Tab or Show Previous Tab, pressed as few times as it takes.
    private static func show(tab wanted: Int, in window: NSWindow) {
        let own = tabs().filter { $0.window === window }
        guard let current = own.firstIndex(where: \.isSelected) else { return }
        let steps = OpenTabs.selectionSteps(from: current, to: wanted, count: own.count)
        for _ in 0..<steps.presses {
            guard send([steps.forward ? "selectNextTab:" : "selectPreviousTab:"], to: window) else { return }
        }
    }

    /// Opens what the profile left open, after its first window came up on the first of its
    /// pages: that window's other tabs, then the other windows with theirs, each with the tab that
    /// was shown in front; the first window ends in front, as it began. The windows are not read
    /// for keeping until every tab is there.
    static func reopen(_ windows: [OpenTabs.Window], first: NSWindow) {
        guard let leading = windows.first, leading.tabs.count > 1 || windows.count > 1 else { return }
        isReopening = true
        Task { @MainActor in
            defer { isReopening = false }
            var opened = 1
            var complete = true
            for (index, kept) in windows.enumerated() {
                var window: NSWindow? = first
                if index > 0 {
                    let controller = SafariChrome.openWindow(address: kept.tabs.first)
                    controller?.showWindow(nil)
                    if let opened = controller?.window { SafariProfileMarker.mark(opened) }
                    window = controller?.window
                    if window != nil { opened += 1 }
                }
                guard let window else {
                    complete = false
                    break
                }
                var all = true
                for address in kept.tabs.dropFirst() {
                    guard await openTab(address, in: window) else {
                        all = false
                        break
                    }
                    opened += 1
                }
                guard all else {
                    complete = false
                    break
                }
                show(tab: kept.selected, in: window)
            }
            if windows.count > 1 { first.makeKeyAndOrderFront(nil) }
            let total = windows.reduce(0) { $0 + $1.tabs.count }
            if complete {
                log.notice("The profile's tabs are open again: \(opened) of \(total)")
            } else {
                reopenedInPart = true
                log.error("Not every tab the profile left could be opened in Safari's window: \(opened) of \(total)")
            }
        }
    }
}
