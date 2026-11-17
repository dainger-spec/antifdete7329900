import AppKit
import Carbon.HIToolbox
import ObjCExceptions
import WebKit

/// What each step of the sweep does (`SafariSweep.steps`): only what a keyboard and a mouse do
/// (`SweepInput`), then a look at the window, the page and the field. A look never acts; what is
/// not as a person would expect it is written down as `failed`.
@MainActor
enum SweepSteps {
    private typealias S = SafariSweep

    static func responder() -> String {
        NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
    }

    static func keyWindow() -> String {
        NSApp.keyWindow.map { SafariMenuWalk.describe($0) } ?? "-"
    }

    static func pageAddress() -> String {
        S.frontPage()?.url?.absoluteString ?? "-"
    }

    static func waitForPath(_ path: String, seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let page = S.frontPage(), page.url?.path == path, !page.isLoading { return true }
            await SweepInput.pause(0.25)
        }
        return false
    }

    static func waitForAddress(containing text: String, seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let page = S.frontPage(), page.url?.absoluteString.contains(text) == true, !page.isLoading { return true }
            await SweepInput.pause(0.25)
        }
        return false
    }

    /// The app's visible windows, other than the browser window, over `point` (screen space).
    static func windowsOver(_ point: NSPoint) -> String {
        let main = S.browserWindow()
        let over = NSApp.windows.filter { $0 !== main && $0.isVisible && $0.frame.contains(point) }
        return over.isEmpty ? "none" : over.map { SafariMenuWalk.describe($0) }.joined(separator: ", ")
    }

    static func webViewCount() -> Int {
        func count(_ view: NSView) -> Int {
            if view is WKWebView { return view.isHiddenOrHasHiddenAncestor ? 0 : 1 }
            return view.subviews.reduce(0) { $0 + count($1) }
        }
        guard let content = S.browserWindow()?.contentView else { return 0 }
        return count(content)
    }

    // MARK: The address bar

    static func addressLatin() async {
        guard let field = S.addressField(), let point = S.center(of: field) else {
            S.expect(false, "the window has an address bar")
            return
        }
        await SweepInput.click(point)
        await SweepInput.pause(0.5)
        S.note("after the click: responder \(responder())")
        await SweepInput.type("sweep")
        await SweepInput.pause(1.5)
        let text = S.fieldText(S.addressField())
        S.note("the field: \(text)")
        S.expect(text.contains("sweep"), "the field holds what was typed")
        await S.escape()
        await S.escape()
    }

    static func addressCyrillicCarried() async {
        await S.focusAddressBar()
        await SweepInput.typeCarried("привет мир")
        await SweepInput.pause(1.5)
        let text = S.fieldText(S.addressField())
        S.note("the field: \(text)")
        S.expect(text.contains("привет"), "the field holds the Cyrillic typed")
        await S.escape()
        await S.escape()
    }

    /// Russian keyboard layouts, by input source: Russian, Russian – PC (the one most Russian
    /// keyboards are), Russian – Phonetic.
    static let russianLayouts: [(String, String)] = [
        ("com.apple.keylayout.Russian", "Russian"),
        ("com.apple.keylayout.RussianWin", "Russian – PC"),
        ("com.apple.keylayout.Russian-Phonetic", "Russian – Phonetic"),
    ]

    static func addressRussianLayout(_ unit: Int) async {
        guard russianLayouts.indices.contains(unit) else { return }
        let (id, name) = russianLayouts[unit]
        guard let selected = SweepInput.selectInputSource(id) else {
            S.note("\(name) is not on this Mac")
            return
        }
        S.note("\(name): \(selected)")
        await S.focusAddressBar()
        await SweepInput.type("привет")
        await SweepInput.pause(1.5)
        let text = S.fieldText(S.addressField())
        S.note("the field: \(text)")
        S.expect(text.contains("привет"), "the field holds what the Russian keys typed")
        await SweepInput.press(kVK_Delete)
        await SweepInput.press(kVK_Delete)
        await SweepInput.pause(0.5)
        await S.escape()
        await S.escape()
    }

    /// Input methods that compose (marked text, then a candidate): what is typed, and the keys that
    /// commit it.
    static let inputMethods: [(String, String, String, [Int])] = [
        ("com.apple.inputmethod.SCIM.ITABC", "Pinyin – Simplified", "nihao", [kVK_Space]),
        ("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "Japanese – Romaji", "nihon", [kVK_Space, kVK_Return]),
    ]

    static func addressInputMethod(_ unit: Int) async {
        guard inputMethods.indices.contains(unit) else { return }
        let (id, name, typed, commit) = inputMethods[unit]
        guard let selected = SweepInput.selectInputSource(id) else {
            S.note("\(name) is not on this Mac")
            return
        }
        S.note("\(name): \(selected)")
        await S.focusAddressBar()
        await SweepInput.type(typed)
        await SweepInput.pause(0.8)
        S.note("composing: \(S.fieldText(S.addressField()))")
        for key in commit {
            await SweepInput.press(key)
            await SweepInput.pause(0.6)
        }
        let text = S.fieldText(S.addressField())
        S.note("the field: \(text)")
        S.expect(!text.isEmpty && !text.hasPrefix("http"), "the field holds what the input method composed")
        if let base = S.baseInputSource { SweepInput.selectInputSource(base) }
        await S.escape()
        await S.escape()
    }

    static func addressPaste() async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://\(S.host)\(S.pagePath)?pasted=1", forType: .string)
        await S.focusAddressBar()
        await S.command(kVK_ANSI_V)
        await SweepInput.pause(0.6)
        S.note("the field: \(S.fieldText(S.addressField()))")
        await SweepInput.press(kVK_Return)
        let went = await waitForAddress(containing: "pasted=1")
        S.expect(went, "Return went to the pasted address (\(pageAddress()))")
    }

    static func addressSuggestions() async {
        await S.ensurePage()
        await S.focusAddressBar()
        await SweepInput.type("sweep")
        await SweepInput.pause(1.2)
        let others = NSApp.windows.filter { $0.isVisible && !SafariChromeHost.isBrowserWindow($0) }.map { SafariMenuWalk.describe($0) }
        S.note("windows up while typing: \(others)")
        for code in [kVK_DownArrow, kVK_DownArrow, kVK_UpArrow] {
            await SweepInput.press(code)
            await SweepInput.pause(0.4)
            S.note("after an arrow: \(S.fieldText(S.addressField()))")
        }
        await S.escape()
        await S.escape()
    }

    static func addressSearch() async {
        await S.focusAddressBar()
        await SweepInput.type("lumen sweep words")
        await SweepInput.pause(0.5)
        await SweepInput.press(kVK_Return)
        await SweepInput.pause(3)
        S.note("the page after Return: \(pageAddress())")
        S.expect(!(S.frontPage()?.url?.path == S.pagePath && S.frontPage()?.url?.host == S.host), "Return left the page for the search")
        await S.ensurePage()
    }

    static func addressEscape() async {
        await S.ensurePage()
        await S.focusAddressBar()
        await SweepInput.type("abc")
        await SweepInput.pause(0.4)
        // In Safari the first Escape closes the completion list, the second puts the address back.
        await S.escape()
        await SweepInput.pause(0.4)
        S.note("the field after one Escape: \(S.fieldText(S.addressField()))")
        await S.escape()
        await SweepInput.pause(0.4)
        let text = S.fieldText(S.addressField())
        S.note("the field after two: \(text)")
        S.expect(!text.contains("abc"), "Escape put the address back")
        await S.escape()
    }

    static func addressEditing() async {
        await S.focusAddressBar()
        await SweepInput.type("abcdef")
        await SweepInput.pause(0.4)
        for _ in 0..<3 { await SweepInput.press(kVK_LeftArrow) }
        for _ in 0..<2 { await SweepInput.press(kVK_Delete) }
        await SweepInput.pause(0.4)
        let edited = S.fieldText(S.addressField())
        S.note("after ←←← and two Deletes: \(edited)")
        S.expect(edited.hasPrefix("adef"), "the arrows and Delete edited the field")
        await S.command(kVK_ANSI_A)
        await SweepInput.press(kVK_Delete)
        await SweepInput.pause(0.4)
        let emptied = S.fieldText(S.addressField())
        S.note("after ⌘A and Delete: \(emptied)")
        S.expect(emptied.isEmpty, "⌘A and Delete emptied the field")
        await S.escape()
        await S.escape()
    }

    /// The sweep's page as a person types it into the address bar: with its scheme, since its
    /// host's `.invalid` is no domain Safari knows, and without one Safari searches for it (CI run
    /// 43990525206: Return went to DuckDuckGo).
    static func typedAddress(_ path: String) -> String { "http://\(S.host)\(path)" }

    static func addressGo() async {
        await S.focusAddressBar()
        await SweepInput.type(typedAddress(S.secondPath))
        await SweepInput.pause(0.4)
        await SweepInput.press(kVK_Return)
        let went = await waitForPath(S.secondPath)
        S.expect(went, "Return went to the typed address (\(pageAddress()))")
    }

    // MARK: Tabs

    static func newTab() async {
        let before = S.tabCount()
        await S.command(kVK_ANSI_T)
        await SweepInput.pause(1.2)
        let after = S.tabCount()
        S.expect(after == before + 1, "⌘T made a tab (\(before) → \(after)); responder \(responder())")
        await SweepInput.type(typedAddress(S.pagePath))
        await SweepInput.pause(0.3)
        await SweepInput.press(kVK_Return)
        let went = await waitForPath(S.pagePath)
        S.expect(went, "the new tab went to the typed address (\(pageAddress()))")
    }

    static func closeTab() async {
        await S.ensureTabs(2)
        let before = S.tabCount()
        await S.command(kVK_ANSI_W)
        await SweepInput.pause(1.2)
        let after = S.tabCount()
        S.expect(after == before - 1, "⌘W closed a tab (\(before) → \(after))")
    }

    static func reopenTab() async {
        let before = S.tabCount()
        await S.command(kVK_ANSI_T, .maskShift)
        await SweepInput.pause(1.5)
        let after = S.tabCount()
        S.expect(after == before + 1, "⇧⌘T reopened a tab (\(before) → \(after))")
    }

    static func numberedTabs() async {
        await S.ensureTabs(3)
        let count = S.tabCount()
        var seen: [String] = []
        var wrong: [String] = []
        for number in 1...9 {
            guard let code = SweepInput.ansiKeys[Character(String(number))] else { continue }
            await S.command(code)
            await SweepInput.pause(0.5)
            let selected = S.selectedTab()
            seen.append("⌘\(number)→\(selected + 1)")
            let expected = number == 9 ? count - 1 : (number <= count ? number - 1 : selected)
            if selected != expected { wrong.append("⌘\(number)") }
        }
        S.note("\(count) tabs: " + seen.joined(separator: ", "))
        S.expect(wrong.isEmpty, "⌘1 to ⌘9 selected their tabs (not: \(wrong))")
    }

    static func controlTab() async {
        await S.ensureTabs(2)
        let first = S.selectedTab()
        await SweepInput.press(kVK_Tab, .maskControl)
        await SweepInput.pause(0.6)
        let second = S.selectedTab()
        await SweepInput.press(kVK_Tab, [.maskControl, .maskShift])
        await SweepInput.pause(0.6)
        let third = S.selectedTab()
        S.expect(second != first && third == first, "⌃Tab went on and ⌃⇧Tab back (\(first) → \(second) → \(third))")
    }

    /// The tabs of the window's tab bar, left to right, found as the views of one class, one per tab;
    /// and what views of the window have "Tab" in their class's name, for the record.
    static func tabPoints() -> (points: [NSPoint], said: String) {
        guard let window = S.browserWindow(), let root = window.contentView?.superview else { return ([], "no window") }
        var byClass: [String: [NSView]] = [:]
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 40 else { return }
            let name = NSStringFromClass(type(of: view))
            if name.contains("Tab"), !view.isHiddenOrHasHiddenAncestor { byClass[name, default: []].append(view) }
            for subview in view.subviews { walk(subview, depth + 1) }
        }
        walk(root, 0)
        let count = S.tabCount()
        let said = byClass.map { name, views in "\(name)×\(views.count) \(Int(views[0].frame.width))×\(Int(views[0].frame.height))" }
            .sorted().joined(separator: ", ")
        var best: (String, [NSView], CGFloat)?
        // Every tab's view, or every one but the pinned ones (a pinned tab has a view of its own).
        for (name, views) in byClass where views.count >= 2 && views.count <= max(count, 2) {
            guard views.allSatisfy({ $0.frame.height >= 16 && $0.frame.height <= 64 && $0.frame.width >= 40 }) else { continue }
            let area = views.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height }
            if best == nil || area > (best?.2 ?? 0) { best = (name, views, area) }
        }
        guard let best else { return ([], said) }
        let points = best.1.compactMap { S.center(of: $0) }.sorted { $0.x < $1.x }
        return (points, "\(best.0) chosen; " + said)
    }

    /// Items of a context menu the sweep does not choose: what reaches outside the profile (the
    /// Photos library, the desktop picture, the system's Services) and the Web Inspector.
    static let avoidedWords = ["Photos", "Фото", "Desktop", "рабочего стола", "Services", "Службы", "Inspect", "Проверить"]

    static func avoided(_ item: NSMenuItem) -> Bool {
        let id = (item.identifier?.rawValue ?? "") + " " + (item.action.map(NSStringFromSelector) ?? "")
        return avoidedWords.contains { item.title.localizedCaseInsensitiveContains($0) || id.localizedCaseInsensitiveContains($0) }
    }

    private static var menuTitles: [String: [String]] = [:]
    /// The same items by their identifier or action: an item whose title says what is selected
    /// (Look Up “…”) is found again by it.
    private static var menuIDs: [String: [String]] = [:]

    static func itemID(_ item: NSMenuItem) -> String {
        item.identifier?.rawValue ?? item.action.map(NSStringFromSelector) ?? item.title
    }

    /// Opens a menu, writes down what it holds, and keeps the titles of what the sweep chooses in
    /// it, one unit each.
    static func menuUnits(_ key: String, opening open: @MainActor () async -> Bool) async -> [String] {
        var opened = true
        let menu = await S.openMenu { opened = await open() }
        guard opened, let menu else {
            menuTitles[key] = []
            await S.escape()
            return [opened ? "(no menu came up)" : "(nothing to right-click)"]
        }
        S.note("the menu: " + S.describeMenu(menu).joined(separator: "; "))
        let chosen = S.stops(in: menu).filter { $0.submenu == nil && !avoided($0) }
        let titles = chosen.map(\.title)
        menuTitles[key] = titles
        menuIDs[key] = chosen.map(itemID)
        await S.escape()
        return titles.isEmpty ? ["(nothing to choose)"] : titles
    }

    /// Opens the menu again and chooses its unit `unit` with the arrow keys and Return.
    static func chooseInMenu(_ key: String, _ unit: Int, opening open: @MainActor () async -> Bool) async {
        guard let titles = menuTitles[key], titles.indices.contains(unit) else {
            S.expect(false, "the menu came up with something to choose")
            return
        }
        let title = titles[unit]
        var opened = true
        let menu = await S.openMenu { opened = await open() }
        guard opened, let menu else {
            S.expect(false, "the menu came up")
            await S.escape()
            return
        }
        let id = menuIDs[key].flatMap { $0.indices.contains(unit) ? $0[unit] : nil }
        let shown = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.isAlternate }
        guard let item = shown.first(where: { $0.title == title }) ?? shown.first(where: { id != nil && itemID($0) == id }) else {
            S.expect(false, "\(title) is in the menu this time")
            await S.escape()
            return
        }
        if item.title != title { S.note("this time it says \(item.title)") }
        guard item.isEnabled else {
            // The tab the menu is for has no tab to its right, say: off, as in Safari.
            S.note("off this time")
            await S.escape()
            return
        }
        if let why = await S.choose(item, in: menu) {
            S.expect(false, "\(title) chosen with the arrow keys: \(why)")
        } else {
            S.note("chosen with the arrow keys and Return")
        }
        await SweepInput.pause(1.5)
    }

    static func tabMenuUnits() async -> [String] {
        await S.ensureTabs(3)
        await SweepInput.pause(0.5)
        let (points, said) = tabPoints()
        S.note("the tab bar's views: \(said)")
        return await menuUnits("tab") {
            guard points.count >= 2 else { return false }
            await SweepInput.click(points[1], right: true)
            return true
        }
    }

    static func tabMenu(_ unit: Int) async {
        await S.ensureTabs(3)
        let (points, _) = tabPoints()
        await chooseInMenu("tab", unit) {
            guard points.count >= 2 else { return false }
            await SweepInput.click(points[1], right: true)
            return true
        }
        S.note("tabs now: \(S.tabCount()), the tab bar's: \(tabPoints().said)")
    }

    // MARK: The page

    static func find() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_F)
        await SweepInput.pause(0.7)
        S.note("after ⌘F: responder \(responder())")
        await SweepInput.type("needle")
        await SweepInput.pause(0.6)
        await SweepInput.press(kVK_Return)
        await SweepInput.press(kVK_Return)
        await S.command(kVK_ANSI_G)
        await S.command(kVK_ANSI_G, .maskShift)
        await SweepInput.pause(0.5)
        let selection = await S.script("return String(window.getSelection());") as? String ?? "-"
        S.note("the page's selection: \(selection); responder \(responder())")
        await S.escape()
        await SweepInput.pause(0.4)
    }

    static func reader() async {
        await S.ensurePage()
        await SweepInput.pause(1)
        let before = webViewCount()
        await S.command(kVK_ANSI_R, .maskShift)
        await SweepInput.pause(2.5)
        let during = webViewCount()
        S.note("web views in the window: \(before) → \(during); responder \(responder())")
        await SweepInput.press(kVK_DownArrow)
        await S.command(kVK_ANSI_R, .maskShift)
        await SweepInput.pause(1.5)
        S.note("after ⇧⌘R again: \(webViewCount())")
    }

    static func zoom() async {
        await S.ensurePage()
        var seen = [S.zoomText()]
        for code in [kVK_ANSI_Equal, kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_0] {
            await S.command(code)
            await SweepInput.pause(0.7)
            seen.append(S.zoomText())
        }
        S.note("the page's zoom: " + seen.joined(separator: " → "))
        S.expect(seen.count == 5 && seen[1] != seen[0] && seen[4] == seen[0], "⌘= zoomed in and ⌘0 back")
    }

    static func linkAndBack() async {
        await S.ensurePage()
        guard let point = await S.pagePoint("#link") else {
            S.expect(false, "the page has its link")
            return
        }
        await SweepInput.click(point)
        let went = await waitForPath(S.secondPath)
        S.expect(went, "the click on the link went to its page (\(pageAddress()))")
        await S.command(kVK_ANSI_LeftBracket)
        let back = await waitForPath(S.pagePath)
        S.expect(back, "⌘[ went back (\(pageAddress()))")
        await S.command(kVK_ANSI_RightBracket)
        let forward = await waitForPath(S.secondPath)
        S.expect(forward, "⌘] went forward (\(pageAddress()))")
    }

    static func pageField() async {
        await S.ensurePage()
        guard let point = await S.pagePoint("#field") else {
            S.expect(false, "the page has its field")
            return
        }
        await SweepInput.click(point)
        await SweepInput.pause(0.5)
        let saw = await S.pageSaw()
        S.note("the page saw: \(saw); responder \(responder())")
        await SweepInput.type("hello ")
        await SweepInput.typeCarried("мир ")
        if let russian = SweepInput.selectInputSource("com.apple.keylayout.RussianWin") ?? SweepInput.selectInputSource("com.apple.keylayout.Russian") {
            S.note("a Russian layout: \(russian)")
            await SweepInput.type("тест")
            if let base = S.baseInputSource { SweepInput.selectInputSource(base) }
        }
        await SweepInput.pause(0.5)
        let value = await S.script("const f = document.getElementById('field'); return f ? f.value : '-';") as? String ?? "-"
        S.note("the field: \(value)")
        S.expect(value.contains("hello") && value.contains("мир"), "the page's field holds what was typed")
        await S.command(kVK_ANSI_A)
        await S.command(kVK_ANSI_C)
        await SweepInput.press(kVK_RightArrow)
        await S.command(kVK_ANSI_V)
        await SweepInput.pause(0.5)
        let pasted = await S.script("const f = document.getElementById('field'); return f ? f.value : '-';") as? String ?? "-"
        S.note("after ⌘A ⌘C → ⌘V: \(pasted)")
        S.expect(pasted.count > value.count, "⌘C and ⌘V copied the field's text into it")
        await SweepInput.press(kVK_Tab)
    }

    /// A click on an empty part of the page, as a person clicks into a page before the wheel or a
    /// link: what the address bar had open (Tab out of the page's field took the keyboard there,
    /// and its list over the page took the wheel and the click: CI run 43990525206) closes.
    static func clickIntoPage() async {
        guard let point = await S.pagePoint("#blank") else { return }
        await SweepInput.click(point)
        await SweepInput.pause(0.4)
    }

    static func wheel() async {
        guard let page = await S.ensurePage(), let center = S.center(of: page) else { return }
        await clickIntoPage()
        S.note("before the wheel: responder \(responder()), windows over the page: \(windowsOver(center))")
        _ = await S.script("window.scrollTo(0, 0); return 0;")
        await SweepInput.scroll(at: center, lines: -10)
        await SweepInput.pause(1)
        let down = (await S.script("return window.scrollY;") as? NSNumber)?.doubleValue ?? -1
        await SweepInput.scroll(at: center, lines: 10)
        await SweepInput.pause(1)
        let up = (await S.script("return window.scrollY;") as? NSNumber)?.doubleValue ?? -1
        S.note("the page's scroll after the wheel: down \(down), up \(up)")
        S.expect(down > 0, "the wheel scrolled the page")
    }

    static func download() async {
        await S.ensurePage()
        await clickIntoPage()
        let before = HostedDownloads.counts.text
        guard let point = await S.pagePoint("#download") else {
            S.expect(false, "the page has its download link")
            return
        }
        await SweepInput.click(point)
        await SweepInput.pause(3)
        let after = HostedDownloads.counts.text
        S.note("downloads: \(before) → \(after)")
        S.expect(before != after, "the click started a download")
        await S.escape()
    }

    static func printPage() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_P)
        await SweepInput.pause(3)
        let sheet = S.browserWindow()?.attachedSheet.map { SafariMenuWalk.describe($0) }
        let modal = NSApp.modalWindow.map { SafariMenuWalk.describe($0) }
        S.note("after ⌘P: sheet \(sheet ?? "none"), modal \(modal ?? "none"), key \(keyWindow())")
        S.expect(sheet != nil || modal != nil, "the print panel came up")
        if !NSApp.isActive {
            // Another app came in front as the panel opened (CI run 43990525206, macOS 26: the
            // first print on the Mac); a person clicks the panel to go on.
            S.note("the app is not in front after ⌘P: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing") is")
            if let panel = S.browserWindow()?.attachedSheet {
                await SweepInput.click(NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 8))
                await SweepInput.pause(0.6)
            }
        }
        await S.escape()
        await SweepInput.pause(1.5)
        S.expect(S.browserWindow()?.attachedSheet == nil && NSApp.modalWindow == nil, "Escape cancelled it")
    }

    static func share() async {
        await S.ensurePage()
        guard let button = shareButton(), let point = S.center(of: button) else {
            let items = S.browserWindow()?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            S.expect(false, "the toolbar has a Share button (its items: \(items))")
            return
        }
        let windowsBefore = NSApp.windows.filter(\.isVisible).count
        let menu = await S.openMenu { await SweepInput.click(point) }
        await SweepInput.pause(0.6)
        S.note("after a click on Share: " + (menu.map { S.describeMenu($0).joined(separator: "; ") } ?? "no menu; key \(keyWindow())"))
        // A person who clicks Share expects something to come up: a menu, a popover, a sheet.
        S.expect(menu != nil || NSApp.windows.filter(\.isVisible).count > windowsBefore || S.browserWindow()?.attachedSheet != nil,
                 "a click on Share brought something up")
        await S.escape()
    }

    static func shareButton() -> NSView? {
        guard let window = S.browserWindow() else { return nil }
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.localizedCaseInsensitiveContains("share") }),
           let view = item.view, !view.isHiddenOrHasHiddenAncestor {
            return view
        }
        var found: NSView?
        func walk(_ view: NSView) {
            guard found == nil else { return }
            if let control = view as? NSControl, !control.isHiddenOrHasHiddenAncestor,
               let action = control.action, NSStringFromSelector(action).localizedCaseInsensitiveContains("share") {
                found = control
                return
            }
            for subview in view.subviews { walk(subview) }
        }
        if let root = window.contentView?.superview { walk(root) }
        return found
    }

    static func reload() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_R)
        await SweepInput.pause(1.5)
        await S.command(kVK_ANSI_Period)
        await SweepInput.pause(0.6)
        let path = S.frontPage()?.url?.path
        S.expect(path == S.pagePath, "the page is still there after ⌘R and ⌘. (\(pageAddress()))")
    }

    // MARK: Context menus

    static let contexts = ["the page", "a link", "an image", "selected text", "the page's text field"]

    /// Right-clicks on what `context` names on the sweep's page; false when the page has none.
    static func openContext(_ context: String) async -> Bool {
        await S.ensurePage()
        let selector: String
        switch context {
        case "a link": selector = "#link"
        case "an image": selector = "#image"
        case "selected text": selector = "#words"
        case "the page's text field": selector = "#field"
        default: selector = "#blank"
        }
        guard let point = await S.pagePoint(selector) else { return false }
        if context == "selected text" {
            await SweepInput.click(point, times: 2)
            await SweepInput.pause(0.4)
        } else if context == "the page's text field" {
            await SweepInput.click(point)
            await SweepInput.typeCarried("слово word")
            await SweepInput.pause(0.3)
        }
        await SweepInput.click(point, right: true)
        return true
    }

    static func contextUnits(_ context: String) async -> [String] {
        await menuUnits("context " + context) { await openContext(context) }
    }

    static func contextItem(_ context: String, _ unit: Int) async {
        await chooseInMenu("context " + context, unit) { await openContext(context) }
        S.note("the page now: \(pageAddress()); tabs \(S.tabCount())")
    }

    // MARK: Bookmarks and history

    static func addBookmark() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_D)
        await SweepInput.pause(1.5)
        let sheet = S.browserWindow()?.attachedSheet
        S.note("after ⌘D: sheet \(sheet.map { SafariMenuWalk.describe($0) } ?? "none"), key \(keyWindow()), responder \(responder())")
        S.expect(sheet != nil, "⌘D brought up the bookmark's sheet")
        guard sheet != nil else { return }
        await SweepInput.type(" sweep")
        await SweepInput.press(kVK_Return)
        await SweepInput.pause(1.2)
        S.expect(S.browserWindow()?.attachedSheet == nil, "Return added it and the sheet went")
    }

    static func sidebarText() -> String {
        guard let page = S.frontPage(), let window = page.window else { return "-" }
        let left = page.convert(NSPoint.zero, to: nil).x
        return "the page starts \(Int(left)) points into the window (\(Int(window.frame.width)) wide); responder \(responder())"
    }

    static func sidebar() async {
        await S.ensurePage()
        let before = sidebarText()
        await S.command(kVK_ANSI_L, .maskShift)
        await SweepInput.pause(1.2)
        S.note("after ⇧⌘L: \(sidebarText()) (before: \(before))")
        if let window = S.browserWindow() {
            await SweepInput.click(NSPoint(x: window.frame.minX + 110, y: window.frame.midY))
            await SweepInput.pause(0.5)
            await SweepInput.press(kVK_DownArrow)
            await SweepInput.press(kVK_DownArrow)
            await SweepInput.pause(0.5)
            S.note("after a click in it and two ↓: responder \(responder())")
        }
        await S.command(kVK_ANSI_1, .maskControl)
        await SweepInput.pause(1.2)
        S.note("after ⌃⌘1: \(sidebarText())")
        await S.command(kVK_ANSI_L, .maskShift)
        await SweepInput.pause(1)
        S.note("after ⇧⌘L again: \(sidebarText())")
    }

    static func editBookmarks() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_B, .maskAlternate)
        await SweepInput.pause(2)
        S.note("after ⌥⌘B: responder \(responder()), page \(pageAddress()), web views \(webViewCount())")
        await SweepInput.press(kVK_DownArrow)
        await SweepInput.press(kVK_DownArrow)
        await SweepInput.pause(0.5)
        await S.command(kVK_ANSI_B, .maskAlternate)
        await SweepInput.pause(1)
    }

    /// The favorites bar's buttons, found by their class's name, and what was found.
    static func favorites() -> (points: [NSPoint], said: String) {
        guard let window = S.browserWindow(), let root = window.contentView?.superview else { return ([], "no window") }
        var names: [String: Int] = [:]
        var points: [NSPoint] = []
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 40 else { return }
            let name = NSStringFromClass(type(of: view))
            if (name.contains("Favorite") || name.contains("BookmarksBar") || name.contains("BookmarkButton")), !view.isHiddenOrHasHiddenAncestor {
                names[name, default: 0] += 1
                if name.contains("Button"), let point = S.center(of: view) { points.append(point) }
            }
            for subview in view.subviews { walk(subview, depth + 1) }
        }
        walk(root, 0)
        return (points, names.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", "))
    }

    static func favoritesBar() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_B, .maskShift)
        await SweepInput.pause(1.2)
        let bar = favorites()
        S.note("after ⇧⌘B: \(bar.said.isEmpty ? "no view of a favorites bar" : bar.said)")
        if let first = bar.points.first {
            await SweepInput.click(first)
            await SweepInput.pause(1.5)
            S.note("after a click on a favorite: \(pageAddress())")
        }
        await S.command(kVK_ANSI_B, .maskShift)
        await SweepInput.pause(0.8)
    }

    static func history() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_Y)
        await SweepInput.pause(2)
        S.note("after ⌘Y: key \(keyWindow()), responder \(responder()), page \(pageAddress())")
        await SweepInput.type("sweep")
        await SweepInput.pause(1)
        S.note("after typing: responder \(responder())")
        await SweepInput.press(kVK_DownArrow)
        await SweepInput.pause(0.4)
        await S.escape()
        await S.command(kVK_ANSI_Y)
        await SweepInput.pause(1)
    }

    // MARK: The window

    static func fullScreen() async {
        await S.command(kVK_ANSI_F, .maskControl)
        await SweepInput.pause(3.5)
        let inFull = S.browserWindow()?.styleMask.contains(.fullScreen) ?? false
        S.expect(inFull, "⌃⌘F put the window in full screen")
        await S.focusAddressBar()
        await SweepInput.type("full")
        await SweepInput.pause(0.8)
        S.note("typed in full screen: \(S.fieldText(S.addressField()))")
        await S.escape()
        await S.escape()
        await S.command(kVK_ANSI_F, .maskControl)
        await SweepInput.pause(3.5)
        let out = !(S.browserWindow()?.styleMask.contains(.fullScreen) ?? false)
        S.expect(out, "⌃⌘F took it out of full screen")
    }

    static func minimize() async {
        guard let window = S.browserWindow() else { return }
        await S.command(kVK_ANSI_M)
        await SweepInput.pause(1.5)
        S.expect(window.isMiniaturized, "⌘M minimized the window")
        window.deminiaturize(nil)
        await SweepInput.pause(1.2)
    }

    static func newWindow() async {
        await S.ensureTabs(2)
        let before = S.browserWindowCount()
        await S.command(kVK_ANSI_N)
        await SweepInput.pause(2.5)
        let after = S.browserWindowCount()
        S.expect(after == before + 1, "⌘N opened a window (\(before) → \(after))")
        guard after > before else { return }
        await S.focusAddressBar()
        await SweepInput.type(typedAddress(S.secondPath))
        await SweepInput.press(kVK_Return)
        await SweepInput.pause(2)
        S.note("the new window's page: \(pageAddress())")
        await S.command(kVK_ANSI_W)
        await SweepInput.pause(1.5)
        S.expect(S.browserWindowCount() == before, "⌘W closed it (\(S.browserWindowCount()) windows)")
    }

    static func settings() async {
        await S.command(kVK_ANSI_Comma)
        await SweepInput.pause(1.5)
        S.note("after ⌘,: key \(keyWindow())")
    }

    // MARK: Every key equivalent

    struct Shortcut {
        let path: [String]
        let code: Int
        let flags: CGEventFlags
        let keys: String
        let action: String
    }

    private static var shortcuts: [Shortcut] = []

    /// Items the sweep never chooses: they end the process or leave it (Quit, Close Window, Close
    /// All Windows: the step of its own does ⌘Q), hide it, or hand the keyboard to another
    /// process (dictation, the character viewer, Help).
    static let skippedActions: Set<String> = ["terminate:", "hide:", "hideOtherApplications:", "performClose:", "closeAllWindows:",
                                              "orderFrontCharacterPalette:", "startDictation:", "showHelp:"]

    static func keysText(_ flags: CGEventFlags, _ equivalent: String) -> String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        let printable = equivalent.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value < 0xF700 }
        return text + (printable ? equivalent.uppercased() : equivalent.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined())
    }

    /// Fills a menu as it fills itself when it opens; an exception there is caught here, not in the
    /// sweep's task.
    static func fill(_ menu: NSMenu) {
        _ = PBCatchException {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
    }

    static func shortcutUnits() -> [String] {
        shortcuts = []
        guard let bar = NSApp.mainMenu else { return [] }
        func add(_ menu: NSMenu, _ path: [String]) {
            fill(menu)
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                let here = path + [item.title]
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { add(submenu, here) }
                    continue
                }
                let mask = item.keyEquivalentModifierMask
                guard !item.keyEquivalent.isEmpty, mask.contains(.command) || mask.contains(.control) else { continue }
                let action = item.action.map(NSStringFromSelector) ?? "-"
                guard !skippedActions.contains(action), let key = SweepInput.key(forEquivalent: item.keyEquivalent) else { continue }
                var flags: CGEventFlags = []
                if mask.contains(.command) { flags.insert(.maskCommand) }
                if mask.contains(.control) { flags.insert(.maskControl) }
                if mask.contains(.option) { flags.insert(.maskAlternate) }
                if mask.contains(.shift) || key.shift { flags.insert(.maskShift) }
                guard !shortcuts.contains(where: { $0.code == key.code && $0.flags == flags }) else { continue }
                shortcuts.append(Shortcut(path: here, code: key.code, flags: flags, keys: keysText(flags, item.keyEquivalent), action: action))
            }
        }
        for top in bar.items {
            if let submenu = top.submenu { add(submenu, [top.title]) }
        }
        return shortcuts.map { "\($0.keys) \($0.path.joined(separator: " › "))" }
    }

    static func shortcut(_ unit: Int) async {
        guard shortcuts.indices.contains(unit) else { return }
        let chosen = shortcuts[unit]
        await S.ensureTabs(2)
        await S.ensurePage()
        S.note("action \(chosen.action)")
        // A menu whose delegate answers for its key equivalents itself is not asked for its items'.
        if let menu = liveItems(chosen.path)?.last?.menu, let delegate = menu.delegate,
           (delegate as AnyObject).responds(to: NSSelectorFromString("menuHasKeyEquivalent:forEvent:target:action:")) {
            S.note("its menu's delegate (\(String(describing: type(of: delegate)))) answers for its key equivalents itself")
        }
        await SweepInput.press(chosen.code, chosen.flags)
        await SweepInput.pause(1.5)
        S.note("after it: key \(keyWindow()), responder \(responder()), page \(pageAddress())")
    }

    // MARK: Every item of the menu bar

    private static var menuPaths: [[String]] = []

    /// AppKit's own window tiling in the Window menu, in every application: not walked (as the menu
    /// walk does not).
    static func isWindowTiling(_ item: NSMenuItem) -> Bool {
        let tiling = { (action: String) in action.hasPrefix("_zoom") || action.hasPrefix("_tile") }
        if let submenu = item.submenu {
            let actions = submenu.items.compactMap { $0.action.map(NSStringFromSelector) }
            return !actions.isEmpty && actions.allSatisfy(tiling)
        }
        guard let action = item.action.map(NSStringFromSelector) else { return false }
        return tiling(action) || action == "zoomAll:" || action == "_removeWindowFromStageManagerSet:"
    }

    static func menuBarUnits() -> [String] {
        menuPaths = []
        guard let bar = NSApp.mainMenu else { return [] }
        func add(_ menu: NSMenu, _ path: [String]) {
            fill(menu)
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
                let here = path + [item.title]
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu, !isWindowTiling(item) { add(submenu, here) }
                    continue
                }
                let action = item.action.map(NSStringFromSelector) ?? "-"
                if skippedActions.contains(action) || isWindowTiling(item) || item.view != nil { continue }
                menuPaths.append(here)
            }
        }
        for top in bar.items {
            if let submenu = top.submenu { add(submenu, [top.title]) }
        }
        return menuPaths.map { $0.joined(separator: " › ") }
    }

    /// The items of the menu bar on the way to `path`, as the menus hold them now.
    static func liveItems(_ path: [String]) -> [NSMenuItem]? {
        guard let bar = NSApp.mainMenu else { return nil }
        var menu: NSMenu? = bar
        var items: [NSMenuItem] = []
        for title in path {
            guard let current = menu else { return nil }
            if current !== bar { fill(current) }
            guard let item = current.items.first(where: { $0.title == title && !$0.isHidden && !$0.isAlternate && !$0.isSeparatorItem }) else {
                return nil
            }
            items.append(item)
            menu = item.submenu
        }
        return items
    }

    static func menuItem(_ unit: Int) async {
        guard menuPaths.indices.contains(unit) else { return }
        await S.ensureTabs(2)
        await S.ensurePage()
        guard let items = liveItems(menuPaths[unit]), let item = items.last else {
            S.note("not in the menu bar now")
            return
        }
        if let menu = item.menu {
            fill(menu)
            if !item.isEnabled {
                S.note("disabled")
                return
            }
        }
        if let why = await chooseInMenuBar(items) {
            if why == S.offWhenOpened {
                S.note(why)
            } else {
                S.expect(false, "chosen with a click and the keyboard: \(why)")
            }
        } else {
            S.note("chosen with a click on the menu bar, the arrow keys and Return")
        }
        await SweepInput.pause(1.5)
        S.note("after it: key \(keyWindow()), responder \(responder()), page \(pageAddress())")
    }

    /// Opens the menu bar as a person does: a click on the application's menu, just right of the
    /// Apple menu, or else ⌃F2. What opened it; nil when nothing did.
    static func openMenuBar() async -> String? {
        guard let screen = NSScreen.screens.first else { return nil }
        SweepMenus.tracked = nil
        for x in [70.0, 95.0] {
            await SweepInput.click(NSPoint(x: screen.frame.minX + x, y: screen.frame.maxY - 10))
            for _ in 0..<10 {
                if SweepMenus.tracked != nil || NSApp.mainMenu?.highlightedItem != nil { return "a click \(Int(x)) points in" }
                await SweepInput.pause(0.1)
            }
        }
        await SweepInput.press(kVK_F2, .maskControl)
        for _ in 0..<10 {
            if SweepMenus.tracked != nil || NSApp.mainMenu?.highlightedItem != nil { return "⌃F2" }
            await SweepInput.pause(0.1)
        }
        return nil
    }

    static func escapeMenus() async {
        for _ in 0..<3 {
            await S.escape()
            await SweepInput.pause(0.1)
        }
    }

    /// Chooses the last of `items` (a path from the menu bar down) with a click on the menu bar,
    /// the arrow keys and Return. Nil when chosen; else why not.
    static func chooseInMenuBar(_ items: [NSMenuItem]) async -> String? {
        guard let bar = NSApp.mainMenu, let top = items.first else { return "no menu bar" }
        guard let how = await openMenuBar() else { return "the menu bar did not open to a click or to ⌃F2" }
        let visible = bar.items.filter { !$0.isHidden }
        let target = visible.firstIndex { $0 === top } ?? 0
        if bar.highlightedItem != nil {
            var moves = 0
            while bar.highlightedItem !== top, moves < visible.count + 2 {
                let at = bar.highlightedItem.flatMap { highlighted in visible.firstIndex { $0 === highlighted } } ?? 0
                await SweepInput.press(target > at ? kVK_RightArrow : kVK_LeftArrow)
                moves += 1
                await SweepInput.pause(0.2)
            }
            guard bar.highlightedItem === top else {
                await escapeMenus()
                return "the arrows did not reach the menu \(top.title) (opened by \(how))"
            }
        } else {
            // The menu bar does not say which of its menus is open: the click opened the
            // application's, the first; counted from there.
            if target > 0 {
                for _ in 0..<target {
                    await SweepInput.press(kVK_RightArrow)
                    await SweepInput.pause(0.2)
                }
            }
            S.note("the menu bar does not say which menu is open: counted \(target) to the right")
        }
        var menu = top.submenu
        let below = Array(items.dropFirst())
        for (depth, item) in below.enumerated() {
            guard let current = menu else {
                await escapeMenus()
                return "no submenu on the way"
            }
            if let why = await S.arrow(to: item, in: current, first: depth == 0 ? -1 : 0) {
                await escapeMenus()
                return why
            }
            if depth < below.count - 1 {
                await SweepInput.press(kVK_RightArrow)
                await SweepInput.pause(0.25)
                menu = item.submenu
            }
        }
        await SweepInput.press(kVK_Return)
        return nil
    }

    // MARK: What was found and fixed, again (the phase "regress", also run by full.yml)

    /// The Reading List's table in the window, as rows the table has and row views it made.
    static func readingListRows() -> String {
        guard let window = S.browserWindow(), let root = window.contentView?.superview else { return "no window" }
        var found: NSTableView?
        func walk(_ view: NSView) {
            guard found == nil else { return }
            if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor {
                let owner = table.delegate.map { String(describing: type(of: $0)) } ?? NSStringFromClass(type(of: table))
                if owner.contains("ReadingList") {
                    found = table
                    return
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        guard let table = found else { return "no Reading List in the window" }
        let made = (0..<min(table.numberOfRows, 5)).filter { table.rowView(atRow: $0, makeIfNecessary: false) != nil }.count
        return "rows \(table.numberOfRows), row views \(made)"
    }

    /// A page added to the Reading List (⇧⌘D), then the Reading List shown by its key equivalent
    /// (⌃⌘2) while the page has the keyboard: WebKit sends the key to the page first and to the menu
    /// again after. Each row's view threw, and there the process ended (CI run 43990525206).
    static func readingListByKey() async {
        await S.ensurePage()
        await clickIntoPage()
        await S.command(kVK_ANSI_D, .maskShift)
        await SweepInput.pause(1.5)
        await clickIntoPage()
        S.note("before ⌃⌘2: responder \(responder())")
        await S.command(kVK_ANSI_2, .maskControl)
        await SweepInput.pause(2)
        let rows = readingListRows()
        S.note("the Reading List: \(rows)")
        S.expect(rows.hasPrefix("rows ") && !rows.hasPrefix("rows 0") && !rows.hasSuffix("row views 0"),
                 "the Reading List shows the page added to it")
        await S.command(kVK_ANSI_L, .maskShift)
        await SweepInput.pause(0.8)
    }

    /// A tab group made (⌃⌘N), a page in it, then ⌘D: the bookmark's sheet lists the folders, and a
    /// folder with no title threw there, so the sheet never came (CI run 43990525206).
    static func bookmarkWithTabGroup() async {
        await S.ensurePage()
        await S.command(kVK_ANSI_N, .maskControl)
        await SweepInput.pause(2)
        S.note("after ⌃⌘N: key \(keyWindow()), tabs \(S.tabCount()), responder \(responder())")
        await S.escape()
        await S.focusAddressBar()
        await SweepInput.type(typedAddress(S.pagePath))
        await SweepInput.press(kVK_Return)
        _ = await waitForPath(S.pagePath)
        await S.command(kVK_ANSI_D)
        await SweepInput.pause(2)
        let sheet = S.browserWindow()?.attachedSheet
        S.note("after ⌘D: sheet \(sheet.map { SafariMenuWalk.describe($0) } ?? "none"), key \(keyWindow())")
        S.expect(sheet != nil, "⌘D brought up the bookmark's sheet with a tab group in the window")
        await S.escape()
        await SweepInput.pause(0.6)
    }

    /// Throws when chosen: the regression check's own menu item.
    private final class Thrower: NSObject {
        static let name = NSExceptionName("PBSweepThrow")

        @objc func throwOne(_ sender: Any?) {
            NSException(name: Self.name, reason: "thrown on purpose by the sweep", userInfo: nil).raise()
        }
    }

    private static let thrower = Thrower()

    /// A key equivalent whose action throws, pressed while the page has the keyboard: whatever
    /// Safari's code throws for a key WebKit sends again, the profile's process goes on.
    static func throwingKeyEquivalent() async {
        guard let menu = NSApp.mainMenu?.items.last?.submenu else {
            S.expect(false, "the menu bar has a last menu")
            return
        }
        guard let key = UnicodeScalar(UInt32(NSF13FunctionKey)) else { return }
        let item = NSMenuItem(title: "PB sweep throw", action: #selector(Thrower.throwOne(_:)), keyEquivalent: String(Character(key))) // l10n: not text
        item.keyEquivalentModifierMask = [.command]
        item.target = thrower
        menu.addItem(item)
        defer { menu.removeItem(item) }
        await S.ensurePage()
        await clickIntoPage()
        S.note("before ⌘F13: responder \(responder())")
        await S.command(kVK_F13)
        await SweepInput.pause(1.5)
        S.note("after ⌘F13: the process goes on; key \(keyWindow()), responder \(responder())")
    }

    /// An image's "Save Image to “Downloads”": named, and saved where the settings say.
    static func saveImageToDownloads() async {
        await S.ensurePage()
        let before = HostedDownloads.counts.text
        guard let point = await S.pagePoint("#image") else {
            S.expect(false, "the page has its image")
            return
        }
        let menu = await S.openMenu { await SweepInput.click(point, right: true) }
        guard let menu else {
            S.expect(false, "the image's menu came up")
            await S.escape()
            return
        }
        guard let item = menu.items.first(where: { $0.action.map(NSStringFromSelector) == "_saveImageToDownloadsFolder:" }) else {
            S.note("no Save Image to the downloads folder here: " + S.describeMenu(menu).joined(separator: "; "))
            await S.escape()
            return
        }
        S.note("the item: \(item.title)")
        S.expect(!item.title.contains("(null)"), "the item names the downloads folder")
        if let why = await S.choose(item, in: menu) {
            S.expect(false, "chosen with the arrow keys: \(why)")
            return
        }
        await SweepInput.pause(3)
        let after = HostedDownloads.counts.text
        S.expect(after != before, "the image was saved (\(before) → \(after))")
    }

    // MARK: Quit and come back

    static func quit() async {
        await S.ensureTabs(3)
        await S.ensurePage()
        S.note("tabs before quitting: \(S.tabCount())")
        await S.command(kVK_ANSI_Q)
        await SweepInput.pause(25)
        S.expect(false, "⌘Q ended the process (it is still running; key \(keyWindow()))")
    }

    static func afterRelaunch() async {
        await SweepInput.pause(1.5)
        S.note("after the relaunch: windows \(S.browserWindowCount()), tabs \(S.tabCount()), page \(pageAddress())")
        S.expect(S.tabCount() >= 2, "the tabs left open came back")
        await S.focusAddressBar()
        await SweepInput.type("sweep")
        await SweepInput.pause(1.2)
        let text = S.fieldText(S.addressField())
        S.note("the field: \(text)")
        S.expect(text.contains("sweep"), "typing in the address bar after the relaunch")
        await S.escape()
        await S.escape()
    }
}
