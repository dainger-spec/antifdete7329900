import AppKit
import ObjCExceptions
import WebKit

/// What each action a person takes in a browser window does in this profile's window (the owner, 8
/// November: in an iPhone view text would not paste — the view is our window, not Safari's, and its
/// process had no menu bar). Each key goes as AppKit sends a key press: to the menu bar's key
/// equivalents first, then the window's views, then the first responder's keyDown; each line says
/// which took it, what changed (the field's text, the page's field, the pasteboard, the zoom, a
/// sheet) and ends "— WORKS" or "— DOES NOT WORK", which the self-test's "window actions" checks
/// read. A context menu is read when it opens and closed at once. Sent by the self-test only.
@MainActor
enum WindowAudit {
    static func run(_ window: NSWindow, controller: BrowserWindowController?, withoutMenu: Bool,
                    addressField: NSTextField?) async -> String {
        var lines: [String] = []
        // Each line also goes to the process's standard error as it is said, and each key before it
        // is pressed: an action that never comes back (CI 759, 760: the whole audit gave no answer, the
        // main thread idle) is the last one named there.
        func trace(_ text: String) { FileHandle.standardError.write(Data("WINDOW-AUDIT \(text)\n".utf8)) }
        func say(_ text: String) { lines.append(text); trace(text) }
        let savedMenu = NSApp.mainMenu
        if withoutMenu { NSApp.mainMenu = NSMenu(title: "none") } // l10n: not text
        defer { if withoutMenu { NSApp.mainMenu = savedMenu } }
        let pasteboard = NSPasteboard.general
        func setClip(_ text: String) { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }
        func clip() -> String { pasteboard.string(forType: .string) ?? "" }
        func pause(_ seconds: Double = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        /// The menu item a key equivalent names, if the menu bar has one.
        func menuItem(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
            func search(_ menu: NSMenu?) -> NSMenuItem? {
                guard let menu else { return nil }
                menu.update()
                for item in menu.items {
                    // An upper-case key equivalent means ⇧ and that key.
                    var itemKey = item.keyEquivalent
                    var itemModifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                    if itemKey.count == 1, itemKey != itemKey.lowercased() { itemModifiers.insert(.shift); itemKey = itemKey.lowercased() }
                    if !itemKey.isEmpty, itemKey == key.lowercased(), itemModifiers == modifiers {
                        return item
                    }
                    if let found = search(item.submenu) { return found }
                }
                return nil
            }
            return search(NSApp.mainMenu)
        }
        /// Presses ⌘key (with `extra`) as AppKit routes a key press; says who took it.
        func press(_ key: String, _ extra: NSEvent.ModifierFlags = []) async -> String {
            let modifiers = NSEvent.ModifierFlags.command.union(extra)
            trace("pressing ⌘\(extra.contains(.shift) ? "⇧" : "")\(extra.contains(.option) ? "⌥" : "")\(extra.contains(.control) ? "⌃" : "")\(key)")
            let item = menuItem(key, modifiers)
            let shown = item.map { "menu item \"\($0.title)\"\($0.isEnabled ? "" : " (disabled)")" } ?? "no menu item"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: extra.contains(.shift) ? key.uppercased() : key,
                                               charactersIgnoringModifiers: key.lowercased(),
                                               isARepeat: false, keyCode: 0) else { return "\(shown); no event" }
            var taker = ""
            // An exception an action raises is caught here, where the key is pressed: unwound through
            // this task, it left it never going on (CI 761, ⌘F's find bar hidden when none was shown).
            let thrown = PBCatchException {
                if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                    taker = "taken by the menu bar"
                } else if window.performKeyEquivalent(with: event) {
                    taker = "taken by a view (\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-"))"
                } else {
                    window.firstResponder?.keyDown(with: event)
                    taker = "given to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing") as a key press"
                }
            }
            if let thrown { taker += ", raised \(thrown.name.rawValue)" }
            await pause()
            return "\(shown); \(taker)"
        }
        func webViews(_ view: NSView?) -> [WKWebView] {
            guard let view else { return [] }
            if let web = view as? WKWebView { return [web] }
            return view.subviews.flatMap(webViews)
        }
        let webView = controller?.selectedTab?.webView ?? webViews(window.contentView).first { !$0.isHidden && $0.window != nil }
        func js(_ source: String) async -> Any? {
            guard let webView else { return nil }
            // At most ten seconds: a page that never answers is said, not waited on for ever.
            let waiter = ScriptWaiter()
            return await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
                waiter.continuation = done
                webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): waiter.finish(value)
                    case .failure(let error): waiter.finish("error: \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    MainActor.assumeIsolated {
                        if waiter.continuation != nil {
                            FileHandle.standardError.write(Data("WINDOW-AUDIT the page did not answer a script in 10 s\n".utf8))
                        }
                        waiter.finish("timeout")
                    }
                }
            }
        }
        say("window \(String(describing: type(of: window))), \(controller == nil ? "Safari's window" : "our window"), "
            + "menu bar: \((NSApp.mainMenu?.items ?? []).map(\.title).joined(separator: " | "))")

        // The address bar.
        if let field = addressField, window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView {
            editor.string = "pb-address-typed"
            editor.selectAll(nil)
            setClip("pb-address-pasted")
            let paste = await press("v")
            say("address bar ⌘V: \(paste) → field \"\(editor.string)\" — \(editor.string.contains("pb-address-pasted") ? "WORKS" : "DOES NOT WORK")")
            let undo = await press("z")
            say("address bar ⌘Z: \(undo) → field \"\(editor.string)\" — \(editor.string.contains("pb-address-pasted") ? "DOES NOT WORK" : "WORKS")")
            editor.string = "pb-address-copy"
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            let all = await press("a")
            let selected = editor.selectedRange().length
            say("address bar ⌘A: \(all) → \(selected) of \(editor.string.count) characters selected — \(selected == editor.string.count ? "WORKS" : "DOES NOT WORK")")
            setClip("pb-nothing")
            let copy = await press("c")
            say("address bar ⌘C: \(copy) → pasteboard \"\(clip())\" — \(clip() == "pb-address-copy" ? "WORKS" : "DOES NOT WORK")")
            let cut = await press("x")
            say("address bar ⌘X: \(cut) → field \"\(editor.string)\", pasteboard \"\(clip())\" — \(editor.string.isEmpty && clip() == "pb-address-copy" ? "WORKS" : "DOES NOT WORK")")
            editor.string = ""
            window.makeFirstResponder(nil)
        } else {
            say("address bar: not found or not editable here")
        }

        // A text field and a line of text on the page.
        guard let webView else {
            say("page: no web view")
            return lines.joined(separator: "\n")
        }
        let prepared = await js("""
            let t = document.getElementById('pbt');
            if (!t) { t = document.createElement('textarea'); t.id = 'pbt'; t.style.cssText = 'display:block;width:200px;height:40px';
              const p = document.createElement('p'); p.id = 'pbp'; p.textContent = 'pb-page-text';
              document.body.prepend(t); document.body.prepend(p); }
            t.value = ''; t.focus(); return document.activeElement === t;
            """)
        window.makeFirstResponder(webView)
        _ = await js("document.getElementById('pbt').focus(); return true;")
        say("page field focused: \(prepared ?? "nil")")
        func fieldValue() async -> String { (await js("return document.getElementById('pbt').value;") as? String) ?? "?" }
        setClip("pb-page-pasted")
        let pastePage = await press("v")
        var value = await fieldValue()
        say("page field ⌘V: \(pastePage) → field \"\(value)\" — \(value.contains("pb-page-pasted") ? "WORKS" : "DOES NOT WORK")")
        let allPage = await press("a")
        setClip("pb-nothing")
        let copyPage = await press("c")
        say("page field ⌘A then ⌘C: \(allPage); \(copyPage) → pasteboard \"\(clip())\" — \(clip() == "pb-page-pasted" ? "WORKS" : "DOES NOT WORK")")
        let cutPage = await press("x")
        value = await fieldValue()
        say("page field ⌘X: \(cutPage) → field \"\(value)\", pasteboard \"\(clip())\" — \(value.isEmpty && clip() == "pb-page-pasted" ? "WORKS" : "DOES NOT WORK")")
        let undoPage = await press("z")
        value = await fieldValue()
        say("page field ⌘Z after the cut: \(undoPage) → field \"\(value)\" — \(value.contains("pb-page-pasted") ? "WORKS" : "DOES NOT WORK")")
        let redoPage = await press("z", .shift)
        value = await fieldValue()
        say("page field ⇧⌘Z: \(redoPage) → field \"\(value)\" — \(value.isEmpty ? "WORKS" : "DOES NOT WORK")")
        _ = await js("""
            document.getElementById('pbt').blur(); const s = getSelection(); s.removeAllRanges();
            const r = document.createRange(); r.selectNodeContents(document.getElementById('pbp')); s.addRange(r); return s.toString();
            """)
        setClip("pb-nothing")
        let copyText = await press("c")
        say("page text selected, ⌘C: \(copyText) → pasteboard \"\(clip())\" — \(clip() == "pb-page-text" ? "WORKS" : "DOES NOT WORK")")
        _ = await js("getSelection().removeAllRanges(); return true;")
        let allDocument = await press("a")
        let selectedText = (await js("return getSelection().toString().length;") as? Int) ?? -1
        say("page ⌘A (nothing focused): \(allDocument) → \(selectedText) characters selected — \(selectedText > 10 ? "WORKS" : "DOES NOT WORK")")
        _ = await js("getSelection().removeAllRanges(); return true;")

        // Find, zoom, print, save, and the rest Safari has a key for.
        // A word the page holds, to be found.
        _ = await js("document.body.insertAdjacentHTML('beforeend', '<p id=pbfind>pbfindword</p>'); getSelection().removeAllRanges(); return true;")
        let find = await press("f")
        // Our window's bar (`PageFindBar`), shown; in Safari's window, any find bar in the window.
        let findShown = controller.map { !$0.findBar.isHidden } ?? (window.contentView.map { view -> Bool in
            func has(_ v: NSView) -> Bool { String(describing: type(of: v)).localizedCaseInsensitiveContains("find") || v.subviews.contains(where: has) }
            return has(view)
        } ?? false)
        say("⌘F (find on the page): \(find) → a find bar in the window: \(findShown ? "yes" : "no") — \(findShown ? "WORKS" : "DOES NOT WORK")")
        if let bar = controller?.findBar, !bar.isHidden {
            // What is typed is found: ⌘G selects the match on the page.
            bar.field.stringValue = "pbfindword"
            let next = await press("g")
            await pause()
            let selected = (await js("return String(getSelection());") as? String) ?? "?"
            say("⌘G (find next): \(next) → the page's selection \"\(selected)\" — \(selected == "pbfindword" ? "WORKS" : "DOES NOT WORK")")
            bar.close()
        }
        await pause()
        let zoomBefore = webView.pageZoom
        let zoomIn = await press("+")
        var zoomIn2 = "not needed"
        if webView.pageZoom == zoomBefore { zoomIn2 = await press("=") }
        let zoomAfterIn = webView.pageZoom
        let zoomOut = await press("-")
        let zoomAfterOut = webView.pageZoom
        let zoomReset = await press("0")
        say("⌘+ / ⌘= (zoom in): \(zoomIn); \(zoomIn2) → page zoom \(zoomBefore) → \(zoomAfterIn) — \(zoomAfterIn > zoomBefore ? "WORKS" : "DOES NOT WORK")")
        say("⌘− (zoom out): \(zoomOut) → \(zoomAfterOut) — \(zoomAfterOut < zoomAfterIn ? "WORKS" : "DOES NOT WORK"); ⌘0: \(zoomReset) → \(webView.pageZoom)")
        webView.pageZoom = zoomBefore
        say("pinch to zoom (trackpad): allowsMagnification \(webView.allowsMagnification) (not pressed here)")
        // ⌘P: a print sheet that opens is closed at once.
        let print = await press("p")
        await pause(1.5)
        var printSeen = "none"
        if let sheet = window.attachedSheet {
            printSeen = "a sheet (\(String(describing: type(of: sheet))))"
            window.endSheet(sheet, returnCode: .cancel)
        } else if let panel = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Print") }) {
            printSeen = "a panel (\(String(describing: type(of: panel))))"
            panel.close()
        } else if NSApp.modalWindow != nil {
            printSeen = "a modal window"
            NSApp.abortModal()
        }
        say("⌘P (print): \(print) → \(printSeen) — \(printSeen == "none" ? "DOES NOT WORK" : "WORKS")")
        // ⌘S: a save panel that opens is closed at once.
        let save = await press("s")
        await pause(1.5)
        var saveSeen = "none"
        if let sheet = window.attachedSheet {
            saveSeen = "a sheet (\(String(describing: type(of: sheet))))"
            window.endSheet(sheet, returnCode: .cancel)
            await pause()
        }
        say("⌘S (save as): \(save) → \(saveSeen) — \(saveSeen.contains("SavePanel") ? "WORKS" : "DOES NOT WORK")")
        // ⌘Y: the history window opens (and is closed again).
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let history = await press("y")
        await pause(1.5)
        let opened = NSApp.windows.filter { $0.isVisible && !windowsBefore.contains(ObjectIdentifier($0)) }
        say("⌘Y (history): \(history) → \(opened.isEmpty ? "no new window" : "a window (\(opened.map { String(describing: type(of: $0)) }.joined(separator: ", ")))") — \(opened.isEmpty ? "DOES NOT WORK" : "WORKS")")
        opened.forEach { $0.close() }
        window.makeKeyAndOrderFront(nil)
        // Keys whose effect leaves the window or this Mac's screen as it is: there, and enabled.
        for (key, extra, name) in [("d", NSEvent.ModifierFlags(), "bookmark this page (⌘D)"), ("b", .option, "show all bookmarks (⌥⌘B)"),
                                   ("w", .shift, "close window (⇧⌘W)"), ("l", .option, "show downloads (⌥⌘L)"),
                                   ("g", [], "find next (⌘G)"), ("g", .shift, "find previous (⇧⌘G)"), ("e", [], "use selection for find (⌘E)")]
                as [(String, NSEvent.ModifierFlags, String)] {
            let item = menuItem(key, NSEvent.ModifierFlags.command.union(extra))
            let there = item.map { $0.isEnabled } ?? false
            say("\(name): \(item.map { "menu item \"\($0.title)\"\($0.isEnabled ? "" : " (disabled)")" } ?? "no menu item") — \(there ? "WORKS" : "DOES NOT WORK")")
        }
        // Full screen: an iPhone has none, so an iPhone view offers none; elsewhere it is there.
        let fullScreen = menuItem("f", [.command, .control])
        if controller?.isPhoneLayout == true {
            say("full screen (⌃⌘F) in an iPhone view: \(fullScreen.map { "menu item \"\($0.title)\"\($0.isEnabled ? "" : " (disabled)")" } ?? "no menu item"), "
                + "the window \(window.collectionBehavior.contains(.fullScreenNone) ? "cannot" : "CAN") go full screen — "
                + "\((fullScreen?.isEnabled ?? false) || !window.collectionBehavior.contains(.fullScreenNone) ? "DOES NOT WORK" : "WORKS")")
        } else {
            say("full screen (⌃⌘F): \(fullScreen.map { "menu item \"\($0.title)\"\($0.isEnabled ? "" : " (disabled)")" } ?? "no menu item") — \((fullScreen?.isEnabled ?? false) ? "WORKS" : "DOES NOT WORK")")
        }
        // Share › Copy Link: the page's address on this Mac's pasteboard.
        func item(withAction name: String, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            menu.update()
            for entry in menu.items {
                if let action = entry.action, NSStringFromSelector(action) == name { return entry }
                if let found = item(withAction: name, in: entry.submenu) { return found }
            }
            return nil
        }
        if let copyLink = item(withAction: "copyLinkCommand:", in: NSApp.mainMenu), let action = copyLink.action {
            setClip("pb-nothing")
            NSApp.sendAction(action, to: nil, from: copyLink)
            await pause()
            let address = webView.url?.absoluteString ?? "?"
            say("share › copy link: menu item \"\(copyLink.title)\" → pasteboard \"\(clip())\" — \(clip() == address ? "WORKS" : "DOES NOT WORK")")
        } else {
            say("share › copy link: no menu item — DOES NOT WORK")
        }
        for (key, extra, name) in [("n", NSEvent.ModifierFlags(), "new window (⌘N)"), ("u", .option, "page source (⌥⌘U)"), ("r", .shift, "reader (⇧⌘R)")]
                as [(String, NSEvent.ModifierFlags, String)] {
            let item = menuItem(key, NSEvent.ModifierFlags.command.union(extra))
            say("\(name), not asked for: \(item.map { "\"\($0.title)\"\($0.isEnabled ? "" : " (disabled)")" } ?? "none")")
        }
        func titles(_ menu: NSMenu?) -> [String] {
            guard let menu else { return [] }
            return menu.items.flatMap { [$0.title] + titles($0.submenu) }
        }
        let shareItems = titles(NSApp.mainMenu).filter { $0.localizedCaseInsensitiveContains("share") || $0.localizedCaseInsensitiveContains("поделиться") }
        say("Share in the menu bar: \(shareItems.isEmpty ? "none" : shareItems.joined(separator: ", "))")

        // The context menu: on the page's field, on its text, and after a long press.
        func point(_ id: String) async -> NSPoint? {
            guard let box = await js("const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2];") as? [Double],
                  box.count == 2 else { return nil }
            let scale = webView.pageZoom * webView.magnification
            let inView = NSPoint(x: box[0] * scale, y: webView.isFlipped ? box[1] * scale : webView.bounds.height - box[1] * scale)
            return webView.convert(inView, to: nil)
        }
        func contextMenu(_ id: String, longPress: Bool) async -> String {
            guard let location = await point(id) else { return "no place for #\(id)" }
            final class Seen { var titles: [String]? }
            let seen = Seen()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu else { return }
                seen.titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                let timer = Timer(timeInterval: 0.4, repeats: false) { _ in menu.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(timer, forMode: .common)
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if longPress {
                if let down = mouse(.leftMouseDown) { webView.mouseDown(with: down) }
                await pause(1.2)
                if let up = mouse(.leftMouseUp) { webView.mouseUp(with: up) }
            } else {
                if let down = mouse(.rightMouseDown) { webView.rightMouseDown(with: down) }
                if let up = mouse(.rightMouseUp) { webView.rightMouseUp(with: up) }
            }
            await pause(2)
            return seen.titles.map { "a menu: \($0.joined(separator: " | "))" } ?? "no menu"
        }
        _ = await js("document.getElementById('pbt').value = 'pb-context'; return true;")
        let onField = await contextMenu("pbt", longPress: false)
        say("right click on the page's field: \(onField)")
        let onText = await contextMenu("pbp", longPress: false)
        say("right click on the page's text: \(onText)")
        let longPress = await contextMenu("pbp", longPress: true)
        say("long press on the page's text: \(longPress)")
        say("drag and drop: not measured (an AppKit drag session cannot be driven by events made here)")
        return lines.joined(separator: "\n")
    }
}

/// One script's answer, given once: by WebKit, or by the audit's time limit.
@MainActor
private final class ScriptWaiter {
    var continuation: CheckedContinuation<Any?, Never>?
    func finish(_ value: Any?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
