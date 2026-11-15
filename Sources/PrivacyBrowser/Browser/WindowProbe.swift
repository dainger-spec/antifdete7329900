import AppKit
import Foundation
import WebKit

/// What the self-test does to a profile's window from inside the profile's own process, and what
/// the window then shows (`ProfileCommand.lookAtWindow`). The window's controls are pressed the way
/// VoiceOver presses them — the accessibility element found by its identifier is told to press —
/// so a control that is not in the window, or hidden, cannot be pressed; a menu's shortcut goes
/// through the menu bar as the key would; a search is typed into the address bar's field editor
/// and ended with Return. Sent by the self-test only, never by the app.
enum WindowProbeAction: Codable, Equatable {
    case describe
    /// The control whose accessibility identifier this is.
    case press(String)
    /// ⌘ and this key, through the menu bar.
    case shortcut(String)
    /// Typed into the window's address bar, then Return.
    case search(String)
    /// A drag along the phone's bottom bar by this many points (negative: to the left), made of
    /// the mouse events a drag sends.
    case dragBottomBar(Double)
    /// A picture of the window's content as it is drawn now (PNG, base64), for a person to look at.
    case picture
    /// Every editing and browsing action a person takes in a browser window, done as the key
    /// presses it, and what came of it, one line each in `detail` (`WindowAudit`). `withoutMenu`:
    /// with the menu bar emptied first, as a process had none before d4cb4ed (0.1.4) — the control.
    case audit(withoutMenu: Bool)
    /// Taps on the selected tab's page: fields and a button laid over it, each pressed with the
    /// mouse at its middle — the events handed straight to the web view, in the window's
    /// coordinates (a runner's process cannot be the active app, run 42429698672) — and what the
    /// page heard, as JSON in `detail` (`TapProbe`).
    case tap
    /// A new tab on this address, after the window's last one: in Safari's window as File › New Tab
    /// at End and the address bar make one (`SafariTabs.openTab`), in ours as ⌘T and the address do.
    case openTab(String)
    /// The profile's downloads as View › Show Downloads lists them, in `detail`; found when the
    /// menu bar's item is routed to that list (`HostedDownloads`).
    case downloads
    /// The page in front goes to this address, as a link on it would send it (the web view's own
    /// load): a link to a file, say.
    case go(String)
    /// What the page in front measures of its window and screen, in `detail`, with the window's
    /// title and whether it carries the profile's chip (`SafariProfileMarker`).
    case measure
    /// The profile's name and colour taken out of Safari's windows (false) or put back (true): what
    /// a page measures is compared between the two.
    case marker(Bool)
}

struct WindowLook: Codable, Equatable {
    var action = ""
    /// The action found what it acts on (the control, the menu item, the address bar).
    var found = false
    var detail = ""
    var hostsSafariChrome = false
    /// In our window: its tabs, the selected one, and whether the tab overview is up.
    var tabs = -1
    var selected = -1
    var overviewShown = false
    var urls: [String] = []
    /// In Safari's window: how its tabs' pages were read (`SafariTabs.source`).
    var tabsSource = ""
    /// The window's title, and whether the window says whose it is: by its title, by the chip in
    /// its toolbar (`SafariProfileMarker`).
    var windowTitle = ""
    var titleNamesProfile = false
    var hasProfileChip = false
    /// The accessibility identifiers of the window's controls that are shown.
    var controls: [String] = []
    /// The menu bar's items with a ⌘ shortcut: "⌘T New Tab".
    var menuItems: [String] = []
    var picture: String?
}

@MainActor
enum WindowProbe {
    static func perform(_ action: WindowProbeAction, session: BrowserSession?) async -> WindowLook {
        var look = WindowLook()
        let controller = session?.windowControllers.first { $0.window?.isVisible == true }
        let window = controller?.window ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        switch action {
        case .describe:
            look.action = "describe"
            look.found = window != nil
        case .press(let identifier):
            look.action = "press \(identifier)"
            if let window, let element = element(identifier, in: window) {
                // An AppKit button is clicked as a click clicks it; anything else is pressed as
                // VoiceOver presses it.
                if let button = element as? NSButton, button.isEnabled {
                    button.performClick(nil)
                    look.found = true
                } else {
                    look.found = press(element)
                }
                look.detail = String(describing: type(of: element))
            }
        case .shortcut(let key):
            look.action = "⌘\(key.uppercased())"
            if let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        characters: key, charactersIgnoringModifiers: key,
                                                        isARepeat: false, keyCode: 0) {
                look.found = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            }
        case .dragBottomBar(let distance):
            look.action = "drag \(Int(distance)) pt along the bottom bar"
            if let window, let bar = bottomBar(in: window.contentView) {
                let frame = bar.convert(bar.bounds, to: nil)
                let start = NSPoint(x: distance < 0 ? frame.maxX - 6 : frame.minX + 6, y: frame.midY)
                let end = NSPoint(x: start.x + distance, y: start.y)
                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                // Straight to the bar, as AppKit sends a drag to the view it began in.
                if let down = mouse(.leftMouseDown, start), let drag = mouse(.leftMouseDragged, end), let up = mouse(.leftMouseUp, end) {
                    bar.mouseDown(with: down)
                    bar.mouseDragged(with: drag)
                    bar.mouseUp(with: up)
                    look.found = true
                }
            }
        case .picture:
            look.action = "picture"
            if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                look.picture = rep.representation(using: .png, properties: [:])?.base64EncodedString()
                look.found = look.picture != nil
            }
        case .audit(let withoutMenu):
            look.action = "audit" + (withoutMenu ? " without a menu bar" : "")
            if let window {
                let before = ExceptionLog.reported
                look.detail = await WindowAudit.run(window, controller: controller, withoutMenu: withoutMenu,
                                                    addressField: addressField(in: window))
                // An exception an action threw, which the run loop caught and lived through: named,
                // so the self-test says which action threw what (CI 758 lost it in a crash).
                if ExceptionLog.reported > before {
                    let thrown = ExceptionLog.loggedLines(containing: "caught by the run loop").suffix(ExceptionLog.reported - before)
                    look.detail += thrown.map { "\nexception during the actions: \($0.prefix(300))" }.joined()
                }
                look.found = true
            }
        case .tap:
            look.action = "tap"
            if let window, let webView = controller?.selectedTab?.webView {
                look.detail = await TapProbe.run(webView, in: window)
                look.found = !look.detail.isEmpty
            }
        case .openTab(let address):
            look.action = "open a tab"
            if let window, let url = URL(string: address) {
                if SafariChromeHost.isHosting, SafariChromeHost.isBrowserWindow(window) {
                    look.found = await SafariTabs.openTab(url, in: window)
                } else if let controller {
                    controller.addTab(url: url)
                    look.found = true
                }
            }
        case .go(let address):
            look.action = "go"
            if let window, let url = URL(string: address) {
                let page = controller?.selectedTab?.webView ?? (SafariChromeHost.isBrowserWindow(window) ? SafariChromeHost.frontPage(in: window) : nil)
                if let page {
                    _ = page.load(URLRequest(url: url))
                    look.found = true
                }
            }
        case .downloads:
            look.action = "downloads"
            if SafariChromeHost.isHosting {
                look.found = HostedDownloads.shared.isRouted
                look.detail = HostedDownloads.shared.listText() + "\n" + HostedDownloads.counts.text
            } else {
                look.found = controller != nil
                look.detail = BrowserTab.finishedDownloads.map(\.lastPathComponent).joined(separator: "\n")
            }
        case .search(let text):
            look.action = "search"
            if let window, let field = addressField(in: window) {
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.selectAll(nil)
                    editor.insertText(text, replacementRange: editor.selectedRange())
                    editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    look.found = true
                }
                look.detail = String(describing: type(of: field))
                    + (SafariChromeHost.isHosting ? ", Safari's engine \(SafariChrome.searchEngineInUse); search keys: \(searchKeys())" : "")
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        look.hostsSafariChrome = SafariChromeHost.isHosting
        if let controller {
            look.tabs = controller.tabCount
            look.selected = controller.selectedTabIndex
            look.overviewShown = controller.isShowingTabOverview
            look.urls = controller.tabs.map { $0.url?.absoluteString ?? "" }
        } else if SafariChromeHost.isHosting, let window, SafariChromeHost.isBrowserWindow(window) {
            // Safari's window: its tabs as Safari hands them out, and how their pages were read.
            _ = SafariTabs.snapshot()
            let own = SafariTabs.tabs().filter { $0.window === window }
            look.tabs = own.count
            look.selected = own.firstIndex(where: \.isSelected) ?? -1
            look.urls = own.map { $0.url?.absoluteString ?? "" }
            look.tabsSource = SafariTabs.source
        }
        if let window {
            look.controls = identifiers(in: window)
            // What the Window menu lists the window as, where it lists it; else the window's own title.
            let listed = NSApp.windowsMenu?.items.first { $0.target === window }?.title
            look.windowTitle = listed ?? window.title
            if SafariChromeHost.isHosting, SafariChromeHost.isBrowserWindow(window) {
                let state = SafariProfileMarker.state(of: window)
                look.titleNamesProfile = state.title
                look.hasProfileChip = state.chip
            }
        }
        look.menuItems = menuShortcuts(NSApp.mainMenu)
        return look
    }

    /// Everything a page can measure of its window and its screen, as the page in front measures
    /// it: one line, the same for the same window.
    private static func measured(by page: WKWebView) async -> String {
        let script = """
        [window.outerWidth, window.outerHeight, window.innerWidth, window.innerHeight, window.outerHeight - window.innerHeight,
         window.screenX, window.screenY, screen.width, screen.height, screen.availWidth, screen.availHeight, window.devicePixelRatio,
         document.documentElement.clientWidth, document.documentElement.clientHeight,
         window.visualViewport ? window.visualViewport.width : -1, window.visualViewport ? window.visualViewport.height : -1].join(' ')
        """
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            page.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: (value as? String) ?? "error: \(error.map { String(describing: $0) } ?? "no value")")
            }
        }
    }

    private static func bottomBar(in view: NSView?) -> MobileBottomBar? {
        guard let view else { return nil }
        if let bar = view as? MobileBottomBar { return bar }
        for subview in view.subviews { if let bar = bottomBar(in: subview) { return bar } }
        return nil
    }

    // The accessibility tree through the Objective-C runtime: AppKit's views, SwiftUI's nodes and
    // plain elements all answer these, whatever Swift makes of the protocol's optional members.
    private static func send(_ object: Any, _ name: String) -> Any? {
        guard let object = object as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func children(of object: Any) -> [Any] { send(object, "accessibilityChildren") as? [Any] ?? [] }
    private static func identifier(of object: Any) -> String? { send(object, "accessibilityIdentifier") as? String }

    private static func press(_ object: Any) -> Bool {
        guard let object = object as? NSObject else { return false }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Press.self)(object, selector)
    }

    /// Every control under the window's content: its views (an AppKit control's identifier is its
    /// view's), and inside a SwiftUI hosting view the accessibility nodes SwiftUI makes for its
    /// buttons — each with whether something above it is hidden (a hidden overview's buttons are
    /// not there for a person).
    private static func walk(_ root: Any, hidden: Bool = false, depth: Int = 0, _ visit: (Any, Bool) -> Bool) -> Bool {
        guard depth < 60 else { return false }
        var hidden = hidden
        if let view = root as? NSView { hidden = hidden || view.isHidden }
        if visit(root, hidden) { return true }
        if let view = root as? NSView {
            for subview in view.subviews where walk(subview, hidden: hidden, depth: depth + 1, visit) { return true }
            if String(describing: type(of: view)).contains("HostingView") {
                for child in children(of: view) where walk(child, hidden: hidden, depth: depth + 1, visit) { return true }
            }
        } else {
            for child in children(of: root) where walk(child, hidden: hidden, depth: depth + 1, visit) { return true }
        }
        return false
    }

    private static func element(_ identifier: String, in window: NSWindow) -> Any? {
        var found: Any?
        guard let content = window.contentView else { return nil }
        _ = walk(content) { element, hidden in
            guard !hidden, Self.identifier(of: element) == identifier else { return false }
            found = element
            return true
        }
        return found
    }

    private static func identifiers(in window: NSWindow) -> [String] {
        var names: [String] = []
        guard let content = window.contentView else { return [] }
        _ = walk(content) { element, hidden in
            if !hidden, let id = Self.identifier(of: element), !id.isEmpty { names.append(id) }
            return names.count > 300
        }
        return names
    }

    /// The window's address bar: ours by name, Safari's as the first editable text field of its
    /// toolbar (its unified field).
    private static func addressField(in window: NSWindow) -> NSTextField? {
        if let controller = window.windowController as? BrowserWindowController { return controller.addressBar }
        var field: NSTextField?
        func search(_ view: NSView) {
            for subview in view.subviews where field == nil {
                if let text = subview as? NSTextField, text.isEditable, !text.isHiddenOrHasHiddenAncestor {
                    field = text
                    return
                }
                search(subview)
            }
        }
        if let frameView = window.contentView?.superview { search(frameView) }
        return field
    }

    /// The preferences this process reads with "Search" in their name, and what they say.
    private static func searchKeys() -> String {
        var found: [String] = []
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.localizedCaseInsensitiveContains("search") {
            found.append("\(key)=\(String(describing: value).prefix(60))")
        }
        let domain = "com.apple.Safari" as CFString
        for key in (CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? [])
        where key.localizedCaseInsensitiveContains("search") {
            found.append("Safari:\(key)=\(String(describing: CFPreferencesCopyAppValue(key as CFString, domain)).prefix(60))")
        }
        return found.sorted().joined(separator: "; ")
    }

    private static func menuShortcuts(_ menu: NSMenu?) -> [String] {
        guard let menu else { return [] }
        var items: [String] = []
        for item in menu.items {
            if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.contains(.command) {
                let shift = item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : ""
                items.append("\(shift)⌘\(item.keyEquivalent.uppercased()) \(item.title)")
            }
            items += menuShortcuts(item.submenu)
        }
        return items
    }
}
