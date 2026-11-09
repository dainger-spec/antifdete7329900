import AppKit

/// The menu bar of a profile's process whose window is our own (an iPhone view, or the simplified
/// mode): without Safari's chrome nothing gave that process a menu bar at all, so ⌘T, ⌘W, ⌘L and
/// the rest did nothing, and an iPhone view could not open a second tab (the owner, 8 November).
/// The browser's commands go down the responder chain to the key window's `BrowserWindowController`:
/// what a person does in Safari's window — edit, find on the page, zoom, print, save, share, history,
/// bookmarks, downloads, full screen — does the same here (the owner, 8 November: text would not
/// paste in an iPhone view; the self-test's "window actions" group presses each key).
@MainActor
enum OwnWindowMenu {
    static func install() {
        let bar = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        bar.addItem(submenu("Lumen", [ // l10n: not text
            item(String(format: L("menu.hide"), appName), #selector(NSApplication.hide(_:)), "h"),
            item(String(format: L("menu.quit"), appName), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        let share = NSMenuItem(title: L("menu.share"), action: nil, keyEquivalent: "")
        share.submenu = NSMenu(title: L("menu.share"))
        share.submenu?.addItem(item(L("menu.copyLink"), #selector(BrowserWindowController.copyLinkCommand(_:)), ""))
        bar.addItem(submenu(L("menu.file"), [
            item(L("menu.newTab"), #selector(BrowserWindowController.newTabCommand(_:)), "t"),
            item(L("menu.reopenClosedTab"), #selector(BrowserWindowController.reopenClosedTabCommand(_:)), "T"),
            item(L("menu.openLocation"), #selector(BrowserWindowController.openLocationCommand(_:)), "l"),
            .separator(),
            item(L("menu.closeWindow"), #selector(BrowserWindowController.closeWindowCommand(_:)), "W"),
            item(L("menu.closeTab"), #selector(NSWindow.performClose(_:)), "w"),
            item(L("menu.saveAs"), #selector(BrowserWindowController.saveAsCommand(_:)), "s"),
            .separator(),
            share,
            .separator(),
            item(L("menu.print"), #selector(BrowserWindowController.printCommand(_:)), "p"),
        ]))
        bar.addItem(submenu(L("menu.edit"), [
            item(L("menu.undo"), Selector(("undo:")), "z"),
            item(L("menu.redo"), Selector(("redo:")), "Z"),
            .separator(),
            item(L("menu.cut"), #selector(NSText.cut(_:)), "x"),
            item(L("menu.copy"), #selector(NSText.copy(_:)), "c"),
            item(L("menu.paste"), #selector(NSText.paste(_:)), "v"),
            item(L("menu.selectAll"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("menu.findOnPage"), #selector(BrowserWindowController.findCommand(_:)), "f"),
            item(L("menu.findNext"), #selector(BrowserWindowController.findNextCommand(_:)), "g"),
            item(L("menu.findPrevious"), #selector(BrowserWindowController.findPreviousCommand(_:)), "G"),
            item(L("menu.useSelectionForFind"), #selector(BrowserWindowController.useSelectionForFindCommand(_:)), "e"),
        ]))
        bar.addItem(submenu(L("menu.view"), [
            item(L("menu.actualSize"), #selector(BrowserWindowController.actualSizeCommand(_:)), "0"),
            item(L("menu.zoomIn"), #selector(BrowserWindowController.zoomInCommand(_:)), "+"),
            // ⌘= as well, Safari's second key for it (the same key without ⇧ on most layouts).
            item(L("menu.zoomIn"), #selector(BrowserWindowController.zoomInCommand(_:)), "=", hidden: true),
            item(L("menu.zoomOut"), #selector(BrowserWindowController.zoomOutCommand(_:)), "-"),
            .separator(),
            fullScreenItem(),
        ]))
        bar.addItem(submenu(L("menu.history"), [
            item(L("menu.showHistory"), #selector(BrowserWindowController.showHistoryCommand(_:)), "y"),
        ]))
        bar.addItem(submenu(L("menu.bookmarks"), [
            item(L("menu.showAllBookmarks"), #selector(BrowserWindowController.showBookmarksCommand(_:)), "b", modifiers: [.command, .option]),
            item(L("menu.bookmarkThisPage"), #selector(BrowserWindowController.bookmarkPageCommand(_:)), "d"),
        ]))
        bar.addItem(submenu(L("menu.browser"), [
            item(L("menu.reload"), #selector(BrowserWindowController.reloadCommand(_:)), "r"),
            item(L("menu.back"), #selector(BrowserWindowController.backCommand(_:)), "["),
            item(L("menu.forward"), #selector(BrowserWindowController.forwardCommand(_:)), "]"),
            .separator(),
            item(L("menu.showAllTabs"), #selector(BrowserWindowController.showAllTabsCommand(_:)), "\\"),
            item(L("menu.showNextTab"), #selector(BrowserWindowController.nextTabCommand(_:)), "}"),
            item(L("menu.showPreviousTab"), #selector(BrowserWindowController.previousTabCommand(_:)), "{"),
        ]))
        let window = submenu(L("menu.window"), [
            item(L("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("menu.showDownloads"), #selector(BrowserWindowController.showDownloadsCommand(_:)), "l", modifiers: [.command, .option]),
        ])
        bar.addItem(window)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window.submenu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// An upper-case key means ⇧⌘ and that key, as AppKit reads key equivalents.
    private static func item(_ title: String, _ action: Selector, _ key: String, hidden: Bool = false,
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isHidden = hidden
        // A hidden item's key still works (⌘= beside ⌘+), as AppKit allows.
        item.allowsKeyEquivalentWhenHidden = hidden
        return item
    }

    /// ⌃⌘F, through the window's controller: an iPhone view has none (an iPhone has no full screen).
    private static func fullScreenItem() -> NSMenuItem {
        item(L("menu.enterFullScreen"), #selector(BrowserWindowController.fullScreenCommand(_:)), "f", modifiers: [.command, .control])
    }
}
