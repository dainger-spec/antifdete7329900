import AppKit
import WebKit

/// The walk of Safari's menu bar in a profile's own process (`--menu-walk`, CI): every item of
/// every menu chosen once, as a user chooses it, and what came of it.
///
/// The owner went through the menus by hand and found three crashes in an evening; this is the
/// machine doing the same, item by item, so that a change in what an item does — a crash, an
/// exception, a window, a file written outside the profile — shows up in CI rather than on a
/// customer's Mac. It runs in a profile's process exactly as the manager starts one
/// (`SafariMenuWalkCheck`), asked for over the profile's channel (`ProfileCommand.walkMenu`):
/// nothing here runs unless that command comes, and only the `--menu-walk` check sends it.
///
/// For each item, in menu order: the item is chosen with `-[NSMenu performActionForItemAtIndex:]`,
/// as a click on it does (with the menu's validation first: a disabled item is said to be so and
/// not chosen); then, a moment later, what changed is told — windows and sheets that opened or
/// closed, the key window, its first responder and its page, whether the app hid — together with
/// what the item asked for that the walk answers instead of letting it happen: a save, open or
/// print panel (cancelled), an alert (its cancel button), a modal window (aborted), a URL or an
/// application to open, a sharing service, Help, quitting. Exceptions thrown meanwhile are told by
/// name, reason and first frames. The manager adds what it sees from outside: the XPC services
/// that started and the files written, in the profile's home, in the real Safari's places and
/// elsewhere. A crash ends the process: the manager starts the profile again and the walk goes
/// on from the next item.
///
/// Not chosen: the system's Services (they hand the selection to other applications, and
/// `HandOffs` keeps them away from pages), and items that are views rather than commands. Not
/// listed: AppKit's window tiling in the Window menu (`isWindowTiling`).
@MainActor
enum SafariMenuWalk {
    /// One item of the menu bar, where it is and how to choose it.
    private struct Entry {
        let path: [String]
        let menu: NSMenu
        let item: NSMenuItem
        /// Why it is not chosen, when it is not.
        let skipped: String?

        var title: String { path.joined(separator: " › ") }
        var action: String { item.action.map(NSStringFromSelector) ?? "-" }
    }

    /// What a window, the app and the page in front look like, compared before and after an item.
    private struct Look: Equatable {
        var windows: [String: String] = [:]
        var key = "-"
        var responder = "-"
        var page = "-"
        var zoom = "-"
        var hidden = false
    }

    private static var isWalking = false
    private static var send: (String) -> Void = { _ in }
    private static var session: BrowserSession?
    /// The page the profile's window showed when the walk began: every item is chosen on it.
    private static var startPage: URL?

    /// Starts the walk at item `from` (after a crash, the one after the item that crashed).
    /// `send` carries one line of JSON per message to the manager.
    static func start(from: Int, session: BrowserSession?, send: @escaping (String) -> Void) {
        guard !isWalking else { return }
        isWalking = true
        Self.send = send
        Self.session = session
        startPage = NSApp.windows.first { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }
            .flatMap { webView(in: $0.contentView)?.url }
        WalkRecorder.install()
        // What an item brings up in another application (the Passwords app, a picker of the
        // system's) is not a window of this process: the system tells it.
        let center = NSWorkspace.shared.notificationCenter
        for (name, said) in [(NSWorkspace.didLaunchApplicationNotification, "another application started"),
                             (NSWorkspace.didActivateApplicationNotification, "another application came to the front")] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                WalkRecorder.note("\(said): \(application.bundleIdentifier ?? application.localizedName ?? "?")")
            }
        }
        Task { @MainActor in
            probePreferences()
            let list = entries()
            // The AutoFill items' actions, sent as a key or a context menu sends them: whether
            // anything still acts on them once their items are out of the menu (SafariChrome).
            let direct = SafariChrome.autoFillInsertActions
            emit(["event": "list", "count": list.count + direct.count, "from": from])
            var index = max(0, from)
            while index < list.count {
                await walk(list[index], at: index)
                index += 1
            }
            while index < list.count + direct.count {
                await sendDirectly(direct[index - list.count], at: index)
                index += 1
            }
            WalkRecorder.uninstall()
            emit(["event": "done", "count": list.count + direct.count])
            isWalking = false
        }
    }

    /// Where this process's preferences go (measurement branch): Safari's code writes its own
    /// keys into this app's preferences domain, which run 456 found in the account's real home.
    /// Whether a domain named by a path in the profile's home is kept there instead.
    private static func probePreferences() {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { return }
        let realHome = SafariPaths.realHome ?? ""
        let path = home + "/Library/Preferences/pb.walk.probe"
        let suite = UserDefaults(suiteName: path)
        suite?.set("written", forKey: "PBWalkProbe")
        let synchronized = suite?.synchronize() ?? false
        let manager = FileManager.default
        let named = "pb.walk.probe.plist"
        let found = [path + ".plist", realHome + "/Library/Preferences/" + named,
                     realHome + "/Library/Preferences" + path + ".plist"].filter { manager.fileExists(atPath: $0) }
        let standard = UserDefaults.standard
        standard.set("written", forKey: "PBWalkProbeStandard")
        standard.synchronize()
        let domain = Bundle.main.bundleIdentifier ?? "?"
        let homePlist = home + "/Library/Preferences/" + domain + ".plist"
        let realPlist = realHome + "/Library/Preferences/" + domain + ".plist"
        let realHas = (NSDictionary(contentsOfFile: realPlist)?["PBWalkProbeStandard"]) != nil
        let homeHas = (NSDictionary(contentsOfFile: homePlist)?["PBWalkProbeStandard"]) != nil
        // What Safari's lookups of its own service settings answer here, by the three ways it
        // could ask: Core Foundation for its domain, a suite of its domain, the standard defaults.
        let safariSuite = UserDefaults(suiteName: "com.apple.Safari")
        var answers: [String] = []
        for key in ["AutoFillPasswords", "UniversalSearchEnabled", "WebKitDNSPrefetchingEnabled", "WarnAboutFraudulentWebsites"] {
            let core = CFPreferencesCopyAppValue(key as CFString, "com.apple.Safari" as CFString).map { "\($0)" } ?? "unset"
            let suiteValue = safariSuite?.object(forKey: key).map { "\($0)" } ?? "unset"
            let standardValue = UserDefaults.standard.object(forKey: key).map { "\($0)" } ?? "unset"
            answers.append("\(key): CF \(core), suite \(suiteValue), standard \(standardValue)")
        }
        emit(["event": "info", "text": "Safari's service settings as read here: " + answers.joined(separator: "; ")])
        // What Safari's tab group sync proxy does with its agent's connection (measurement branch).
        if let proxy = NSClassFromString("WBTabGroupSyncAgentProxy") {
            var count: UInt32 = 0
            var names: [String] = []
            if let methods = class_copyMethodList(proxy, &count) {
                for index in 0..<Int(count) { names.append("-" + NSStringFromSelector(method_getName(methods[index]))) }
                free(methods)
            }
            if let meta = object_getClass(proxy), let methods = class_copyMethodList(meta, &count) {
                for index in 0..<Int(count) { names.append("+" + NSStringFromSelector(method_getName(methods[index]))) }
                free(methods)
            }
            emit(["event": "info", "text": "WBTabGroupSyncAgentProxy's methods: " + names.sorted().joined(separator: " ")])
        }
        emit(["event": "info", "text": "preferences: a suite named by a path in the profile's home "
              + "(synchronize \(synchronized), read back \(suite?.string(forKey: "PBWalkProbe") ?? "nothing")) is written to "
              + (found.isEmpty ? "no file found" : found.map { $0.hasPrefix(home) ? "the profile's home" : $0 }.joined(separator: ", "))
              + "; this app's own domain (\(domain)) written through the standard defaults reaches "
              + "the account's real home: \(realHas), the profile's home: \(homeHas)"])
    }

    // MARK: The items

    /// Every item of the menu bar, depth first, in the order the menus show them. The menus
    /// Safari fills as they open (History, Bookmarks, Window) are filled first.
    private static func entries() -> [Entry] {
        guard let bar = NSApp.mainMenu else { return [] }
        var list: [Entry] = []
        func add(_ menu: NSMenu, _ path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !isWindowTiling(item) {
                let here = path + [item.title.isEmpty ? "(untitled)" : item.title]
                if let submenu = item.submenu {
                    if submenu === NSApp.servicesMenu {
                        list.append(Entry(path: here, menu: menu, item: item,
                                          skipped: "the system's Services, \(submenu.items.count) items"))
                    } else {
                        add(submenu, here)
                    }
                } else if item.view != nil {
                    list.append(Entry(path: here, menu: menu, item: item, skipped: "a view in the menu, not a command"))
                } else {
                    list.append(Entry(path: here, menu: menu, item: item, skipped: nil))
                }
            }
        }
        for top in bar.items {
            guard let submenu = top.submenu else { continue }
            add(submenu, [top.title.isEmpty ? submenu.title : top.title])
        }
        return list
    }

    /// AppKit's own window tiling in the Window menu (Fill, Center, Move & Resize, Zoom All, Full
    /// Screen Tile, Remove Window from Set): the system's, in every application, and there or not
    /// by the window's state (runs 456 and 457 on macOS 26: 174 items, then 147). Not walked.
    private static func isWindowTiling(_ item: NSMenuItem) -> Bool {
        if let submenu = item.submenu {
            let actions = submenu.items.compactMap { $0.action.map(NSStringFromSelector) }
            return !actions.isEmpty && actions.allSatisfy { $0.hasPrefix("_zoom") }
        }
        guard let action = item.action.map(NSStringFromSelector) else { return item.title == "Full Screen Tile" }
        return action.hasPrefix("_zoom") || action == "zoomAll:" || action == "_removeWindowFromStageManagerSet:"
    }

    // MARK: One item

    private static func walk(_ entry: Entry, at index: Int) async {
        await bringWindowForward()
        let windowsBefore = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let before = look()
        WalkRecorder.reset()
        emit(["event": "begin", "index": index, "path": entry.title, "action": entry.action,
              "keys": keys(of: entry.item), "time": Date().timeIntervalSince1970])
        var enabled = false
        var chosen = false
        if entry.skipped == nil {
            entry.menu.update()
            enabled = entry.item.isEnabled
            let position = entry.menu.index(of: entry.item)
            if enabled, position >= 0 {
                // A modal session the recorder does not answer (a window run modally some other
                // way) would hold the walk: it is ended from the run loop it runs in.
                let watchdog = DispatchWorkItem {
                    MainActor.assumeIsolated {
                        if let modal = NSApp.modalWindow {
                            WalkRecorder.note("a modal window: \(SafariMenuWalk.describe(modal)) — ended by the walk")
                            NSApp.abortModal()
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: watchdog)
                Chooser.choose { entry.menu.performActionForItem(at: position) }
                chosen = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                watchdog.cancel()
            }
        }
        let after = look()
        var seen = WalkRecorder.take()
        let opened = NSApp.windows.filter { !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible }
        for window in opened {
            seen.effects.append("\(window.isSheet ? "a sheet" : "a window"): \(describe(window))")
        }
        let changes = differences(before, after)
        var fields: [String: Any] = [
            "event": "end", "index": index, "path": entry.title, "action": entry.action,
            "enabled": enabled, "chosen": chosen, "effects": seen.effects, "changes": changes,
            "exceptions": seen.exceptions, "time": Date().timeIntervalSince1970,
        ]
        if let skipped = entry.skipped { fields["skipped"] = skipped }
        emit(fields)
        await restore(keeping: windowsBefore)
    }

    /// An action sent to the first responder with no menu item, as a key or a context menu sends
    /// it: what still acts on it.
    private static func sendDirectly(_ name: String, at index: Int) async {
        await bringWindowForward()
        let windowsBefore = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let before = look()
        WalkRecorder.reset()
        let path = "(sent to the first responder) \(name)"
        emit(["event": "begin", "index": index, "path": path, "action": name, "keys": "-",
              "time": Date().timeIntervalSince1970])
        var taken = false
        Chooser.choose { taken = NSApp.sendAction(NSSelectorFromString(name), to: nil, from: nil) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = look()
        var seen = WalkRecorder.take()
        if !taken { seen.effects.append("nothing in the responder chain takes it") }
        for window in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(window)) && window.isVisible {
            seen.effects.append("\(window.isSheet ? "a sheet" : "a window"): \(describe(window))")
        }
        emit(["event": "end", "index": index, "path": path, "action": name, "enabled": true, "chosen": taken,
              "effects": seen.effects, "changes": differences(before, after), "exceptions": seen.exceptions,
              "time": Date().timeIntervalSince1970])
        await restore(keeping: windowsBefore)
    }

    /// A browser window of the profile's in front and key, opening one if the last item closed it.
    private static func bringWindowForward() async {
        var browser = NSApp.windows.first { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }
        if browser == nil, let session {
            _ = SafariChromeHost.open(session: session, url: nil)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            browser = NSApp.windows.first { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }
        }
        NSApp.activate(ignoringOtherApps: true)
        browser?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        // On the page the walk began on: an item before may have opened a tab or another page
        // (run 456: after File › New Tab every item ran on an empty tab, where Print, Share and
        // Export as PDF are disabled).
        if let page = startPage, let browser, let webView = webView(in: browser.contentView), webView.url != page {
            webView.load(URLRequest(url: page))
            let deadline = Date().addingTimeInterval(8)
            while webView.isLoading || webView.url != page, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            browser.makeFirstResponder(webView)
        }
    }

    /// Back to where the item began: what it opened closed, the app shown, no window minimized
    /// or full screen, no sheet up. (Toggles an item made, such as a hidden toolbar, stay.)
    private static func restore(keeping windows: Set<ObjectIdentifier>) async {
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
            window.close()
        }
        try? await Task.sleep(nanoseconds: leftFullScreen ? 2_000_000_000 : 300_000_000)
    }

    /// Runs an item's action from the run loop, as a click does, never from inside the walk's
    /// task. An exception the action throws then unwinds through AppKit's frames only, and AppKit
    /// catches it; through the task's it would leave the Swift runtime's record of the running job
    /// pointing into a stack that is gone. Run 460: Bookmarks › Add Bookmark… threw on a page, the
    /// exception went through the walk's task, and the process crashed in the runtime as the
    /// exception was being written down (`MainActor.assumeIsolated` in `ExceptionLog`).
    private final class Chooser: NSObject {
        private let action: @MainActor () -> Void

        private init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        static func choose(_ action: @escaping @MainActor () -> Void) {
            let chooser = Chooser(action)
            chooser.perform(#selector(Chooser.run), with: nil, afterDelay: 0)
        }

        @MainActor @objc private func run() {
            action()
        }
    }

    // MARK: Looking

    private static func look() -> Look {
        var look = Look()
        for window in NSApp.windows where window.isVisible || window.isMiniaturized {
            look.windows["\(window.windowNumber)"] = describe(window)
        }
        look.hidden = NSApp.isHidden
        if let key = NSApp.keyWindow {
            look.key = describe(key)
            look.responder = key.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
            if let webView = webView(in: key.contentView) {
                look.page = webView.url?.absoluteString ?? "(no page)"
                look.zoom = String(format: "%.2f×%.2f", webView.pageZoom, webView.magnification)
            }
        }
        return look
    }

    private static func differences(_ before: Look, _ after: Look) -> [String] {
        var changes: [String] = []
        if before.key != after.key { changes.append("key window: \(before.key) → \(after.key)") }
        if before.responder != after.responder { changes.append("first responder: \(before.responder) → \(after.responder)") }
        if before.page != after.page { changes.append("page: \(before.page) → \(after.page)") }
        if before.zoom != after.zoom { changes.append("zoom: \(before.zoom) → \(after.zoom)") }
        if before.hidden != after.hidden { changes.append(after.hidden ? "the app hid" : "the app showed") }
        for (number, window) in before.windows where after.windows[number] == nil {
            changes.append("closed: \(window)")
        }
        for (number, window) in before.windows {
            if let now = after.windows[number], now != window { changes.append("window: \(window) → \(now)") }
        }
        return changes.sorted()
    }

    static func describe(_ window: NSWindow) -> String {
        var states: [String] = []
        if window.isMiniaturized { states.append("minimized") }
        if window.styleMask.contains(.fullScreen) { states.append("full screen") }
        if !window.isVisible { states.append("hidden") }
        let title = window.title.isEmpty ? "" : " '\(window.title.prefix(60))'"
        return "\(type(of: window))\(title)" + (states.isEmpty ? "" : " (\(states.joined(separator: ", ")))")
    }

    private static func webView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = webView(in: subview) { return found }
        }
        return nil
    }

    private static func keys(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "-" }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) || key != key.lowercased() { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    private static func emit(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        send(String(decoding: data, as: UTF8.self))
    }
}

/// What an item asked for that the walk answers itself, and the exceptions thrown while it ran.
///
/// Installed only for the walk and taken out after it: every way AppKit shows a save, open or
/// print panel, an alert, a modal window, Help or a sharing service, opens a URL or an
/// application, hides the other applications or quits is noted and answered as Cancel (or not
/// done), so that the walk neither waits for a click nor reaches outside the profile.
final class WalkRecorder: @unchecked Sendable {
    nonisolated(unsafe) private static var effects: [String] = []
    nonisolated(unsafe) private static var exceptions: [String] = []
    /// The methods replaced, with what they were, to put back after the walk.
    nonisolated(unsafe) private static var replaced: [(Method, IMP)] = []
    nonisolated(unsafe) private static var previousPresentNotice: (@MainActor (String, String) -> Void)?
    nonisolated(unsafe) private static var previousShowSettings: (() -> Void)?

    static func note(_ text: String) { effects.append(text) }

    static func reset() {
        effects = []
        exceptions = []
    }

    static func take() -> (effects: [String], exceptions: [String]) {
        defer { reset() }
        return (effects, exceptions)
    }

    @MainActor
    static func install() {
        ExceptionLog.onThrown = { name, reason, frames in
            WalkRecorder.exceptions.append("\(name): \(reason.prefix(240)) | " + frames.prefix(8).joined(separator: " / "))
        }
        previousPresentNotice = SafariChrome.presentNotice
        SafariChrome.presentNotice = { title, text in WalkRecorder.note("our notice: \(title) — \(text)") }
        previousShowSettings = SafariChrome.onShowSettings
        let showSettings = previousShowSettings
        SafariChrome.onShowSettings = {
            WalkRecorder.note("asks the manager for its Settings")
            showSettings?()
        }
        answerPanels()
        answerAlerts()
        answerPrinting()
        answerWorkspace()
        answerSharing()
        answerApplication()
    }

    @MainActor
    static func uninstall() {
        for (method, implementation) in replaced.reversed() { method_setImplementation(method, implementation) }
        replaced = []
        ExceptionLog.onThrown = nil
        if let previousPresentNotice { SafariChrome.presentNotice = previousPresentNotice }
        SafariChrome.onShowSettings = previousShowSettings
    }

    /// Replaces `name` of `owner` — its own method, or the one it inherits (then the class that
    /// has it is the one changed, once) — with `block`, keeping what it was.
    private static func replace(_ owner: AnyClass, _ name: String, with block: Any) {
        guard let method = class_getInstanceMethod(owner, NSSelectorFromString(name)) else { return }
        guard !replaced.contains(where: { $0.0 == method }) else { return }
        let previous = method_setImplementation(method, imp_implementationWithBlock(block))
        replaced.append((method, previous))
    }

    // MARK: Panels and alerts

    @MainActor
    private static func answerPanels() {
        let runModal: @convention(block) (NSSavePanel) -> Int = { panel in
            WalkRecorder.note(panelText(panel, shownBy: "run modally"))
            return NSApplication.ModalResponse.cancel.rawValue
        }
        let sheet: @convention(block) (NSSavePanel, NSWindow?, (@convention(block) (Int) -> Void)?) -> Void = { panel, _, handler in
            WalkRecorder.note(panelText(panel, shownBy: "as a sheet"))
            DispatchQueue.main.async { handler?(NSApplication.ModalResponse.cancel.rawValue) }
        }
        let begin: @convention(block) (NSSavePanel, (@convention(block) (Int) -> Void)?) -> Void = { panel, handler in
            WalkRecorder.note(panelText(panel, shownBy: "on its own"))
            DispatchQueue.main.async { handler?(NSApplication.ModalResponse.cancel.rawValue) }
        }
        // The panel classes this process really makes (a panel can be a subclass of AppKit's).
        let candidates: [AnyClass?] = [NSSavePanel.self, NSOpenPanel.self, object_getClass(NSSavePanel()), object_getClass(NSOpenPanel())]
        for owner in candidates.compactMap({ $0 }) {
            replace(owner, "runModal", with: runModal)
            replace(owner, "beginSheetModalForWindow:completionHandler:", with: sheet)
            replace(owner, "beginWithCompletionHandler:", with: begin)
        }
    }

    private static func panelText(_ panel: NSSavePanel, shownBy how: String) -> String {
        let kind = panel is NSOpenPanel ? "an open panel" : "a save panel"
        let folder = panel.directoryURL?.path ?? "no folder"
        let name = panel.nameFieldStringValue.isEmpty ? "" : ", name '\(panel.nameFieldStringValue)'"
        return "\(kind) (\(how), answered Cancel), in \(place(folder))\(name)"
    }

    /// A folder said by where it is: the profile's home, the account's home, elsewhere.
    static func place(_ path: String) -> String {
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], path.hasPrefix(home) {
            return "the profile's home" + path.dropFirst(home.count)
        }
        if let real = SafariPaths.realHome, path.hasPrefix(real) {
            return "the account's home" + path.dropFirst(real.count)
        }
        return path
    }

    private static func answerAlerts() {
        // The alert's cancel: the button Escape presses, or else its last.
        let cancel: (NSAlert) -> (Int, String) = { alert in
            let buttons = alert.buttons
            let index = buttons.firstIndex { $0.keyEquivalent == "\u{1b}" } ?? max(0, buttons.count - 1)
            let title = buttons.indices.contains(index) ? buttons[index].title : "-"
            return (NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index, title)
        }
        let runModal: @convention(block) (NSAlert) -> Int = { alert in
            let (response, title) = cancel(alert)
            WalkRecorder.note("an alert (run modally): '\(alert.messageText)' — '\(alert.informativeText.prefix(160))'; "
                              + "buttons \(alert.buttons.map(\.title)); answered '\(title)'")
            return response
        }
        let sheet: @convention(block) (NSAlert, NSWindow?, (@convention(block) (Int) -> Void)?) -> Void = { alert, _, handler in
            let (response, title) = cancel(alert)
            WalkRecorder.note("an alert (as a sheet): '\(alert.messageText)' — '\(alert.informativeText.prefix(160))'; "
                              + "buttons \(alert.buttons.map(\.title)); answered '\(title)'")
            DispatchQueue.main.async { handler?(response) }
        }
        replace(NSAlert.self, "runModal", with: runModal)
        replace(NSAlert.self, "beginSheetModalForWindow:completionHandler:", with: sheet)
    }

    private static func answerPrinting() {
        let run: @convention(block) (NSPrintOperation) -> Bool = { operation in
            WalkRecorder.note("printing (\(operation.showsPrintPanel ? "with" : "without") the print panel), not done")
            return false
        }
        let runForWindow: @convention(block) (NSPrintOperation, NSWindow?, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void = { operation, _, _, _, _ in
            WalkRecorder.note("printing on a sheet (\(operation.showsPrintPanel ? "with" : "without") the print panel), not done")
        }
        replace(NSPrintOperation.self, "runOperation", with: run)
        replace(NSPrintOperation.self, "runOperationModalForWindow:delegate:didRunSelector:contextInfo:", with: runForWindow)
        let pageLayout: @convention(block) (NSPageLayout) -> Int = { _ in
            WalkRecorder.note("page setup, answered Cancel")
            return NSApplication.ModalResponse.cancel.rawValue
        }
        replace(NSPageLayout.self, "runModal", with: pageLayout)
    }

    // MARK: Outside the profile

    private static func answerWorkspace() {
        let openURL: @convention(block) (NSWorkspace, NSURL) -> Bool = { _, url in
            WalkRecorder.note("asks the system to open \(described(url as URL)), not opened")
            return true
        }
        let openURLConfigured: @convention(block) (NSWorkspace, NSURL, AnyObject?, (@convention(block) (AnyObject?, AnyObject?) -> Void)?) -> Void = { _, url, _, handler in
            WalkRecorder.note("asks the system to open \(described(url as URL)), not opened")
            DispatchQueue.main.async { handler?(nil, nil) }
        }
        let openURLsWithApplication: @convention(block) (NSWorkspace, NSArray, NSURL, AnyObject?, (@convention(block) (AnyObject?, AnyObject?) -> Void)?) -> Void = { _, urls, application, _, handler in
            let names = (urls as? [URL] ?? []).map(described).joined(separator: ", ")
            WalkRecorder.note("asks \(application.lastPathComponent ?? "an application") to open \(names), not opened")
            DispatchQueue.main.async { handler?(nil, nil) }
        }
        let openApplication: @convention(block) (NSWorkspace, NSURL, AnyObject?, (@convention(block) (AnyObject?, AnyObject?) -> Void)?) -> Void = { _, application, _, handler in
            WalkRecorder.note("asks the system to start \(application.lastPathComponent ?? "an application"), not started")
            DispatchQueue.main.async { handler?(nil, nil) }
        }
        let showInFinder: @convention(block) (NSWorkspace, NSArray) -> Void = { _, urls in
            let names = (urls as? [URL] ?? []).map { place($0.path) }.joined(separator: ", ")
            WalkRecorder.note("asks the Finder to show \(names), not shown")
        }
        let selectFile: @convention(block) (NSWorkspace, NSString?, NSString) -> Bool = { _, file, _ in
            WalkRecorder.note("asks the Finder to show \(place(file.map { $0 as String } ?? "-")), not shown")
            return true
        }
        replace(NSWorkspace.self, "openURL:", with: openURL)
        replace(NSWorkspace.self, "openURL:configuration:completionHandler:", with: openURLConfigured)
        replace(NSWorkspace.self, "openURLs:withApplicationAtURL:configuration:completionHandler:", with: openURLsWithApplication)
        replace(NSWorkspace.self, "openApplicationAtURL:configuration:completionHandler:", with: openApplication)
        replace(NSWorkspace.self, "activateFileViewerSelectingURLs:", with: showInFinder)
        replace(NSWorkspace.self, "selectFile:inFileViewerRootedAtPath:", with: selectFile)
    }

    /// A URL said by its scheme and host, or as a place when it is a file.
    private static func described(_ url: URL) -> String {
        if url.isFileURL { return "the file " + place(url.path) }
        return "\(url.scheme ?? "?"):\(url.host.map { "//" + $0 } ?? "")\(url.path.isEmpty ? "" : url.path)"
    }

    private static func answerSharing() {
        let perform: @convention(block) (NSSharingService, NSArray) -> Void = { service, items in
            WalkRecorder.note("shares \(items.count) item(s) with '\(service.title)', not shared")
        }
        let picker: @convention(block) (NSSharingServicePicker, NSRect, NSView, UInt) -> Void = { _, _, _, _ in
            WalkRecorder.note("the sharing menu, not shown")
        }
        replace(NSSharingService.self, "performWithItems:", with: perform)
        replace(NSSharingServicePicker.self, "showRelativeToRect:ofView:preferredEdge:", with: picker)
    }

    @MainActor
    private static func answerApplication() {
        let quit: @convention(block) (NSApplication, AnyObject?) -> Void = { _, _ in
            WalkRecorder.note("asks to quit (the profile would seal and close), not quit")
        }
        let hideOthers: @convention(block) (NSApplication, AnyObject?) -> Void = { _, _ in
            WalkRecorder.note("asks to hide the other applications, not done")
        }
        let help: @convention(block) (NSApplication, AnyObject?) -> Void = { _, _ in
            WalkRecorder.note("asks for Help (the Help viewer, another application), not shown")
        }
        let palette: @convention(block) (NSApplication, AnyObject?) -> Void = { _, _ in
            WalkRecorder.note("asks for the system's character viewer, not shown")
        }
        let runModalForWindow: @convention(block) (NSApplication, NSWindow) -> Int = { _, window in
            MainActor.assumeIsolated {
                WalkRecorder.note("a window run modally: \(SafariMenuWalk.describe(window)), ended by the walk")
                window.orderOut(nil)
            }
            return NSApplication.ModalResponse.abort.rawValue
        }
        let helpAnchor: @convention(block) (NSHelpManager, NSString, NSString?) -> Void = { _, anchor, book in
            WalkRecorder.note("asks for Help at '\(anchor)' in \(book.map { "'\($0)'" } ?? "the app's book"), not shown")
        }
        // Safari's application object may have its own; AppKit's is replaced as well.
        var owners: [AnyClass] = []
        var owner: AnyClass? = object_getClass(NSApp)
        while let current = owner {
            owners.append(current)
            if current == NSApplication.self { break }
            owner = class_getSuperclass(current)
        }
        for owner in owners {
            replace(owner, "terminate:", with: quit)
            replace(owner, "hideOtherApplications:", with: hideOthers)
            replace(owner, "showHelp:", with: help)
            replace(owner, "orderFrontCharacterPalette:", with: palette)
            replace(owner, "runModalForWindow:", with: runModalForWindow)
        }
        replace(NSHelpManager.self, "openHelpAnchor:inBook:", with: helpAnchor)
    }
}
