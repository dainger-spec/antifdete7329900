import AppKit

/// The menu bar of a profile's process whose window is our own (an iPhone view, or the simplified
/// mode): without Safari's chrome nothing gave that process a menu bar at all, so ⌘T, ⌘W, ⌘L and
/// the rest did nothing, and an iPhone view could not open a second tab (the owner, 8 November).
/// The browser's commands go down the responder chain to the key window's `BrowserWindowController`.
@MainActor
enum OwnWindowMenu {
    static func install() {
        let bar = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        bar.addItem(submenu("Lumen", [ // l10n: not text
            item(String(format: L("menu.hide"), appName), #selector(NSApplication.hide(_:)), "h"),
            item(String(format: L("menu.quit"), appName), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        bar.addItem(submenu(L("menu.file"), [
            item(L("menu.newTab"), #selector(BrowserWindowController.newTabCommand(_:)), "t"),
            item(L("menu.reopenClosedTab"), #selector(BrowserWindowController.reopenClosedTabCommand(_:)), "T"),
            item(L("menu.openLocation"), #selector(BrowserWindowController.openLocationCommand(_:)), "l"),
            .separator(),
            item(L("menu.closeTab"), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        bar.addItem(submenu(L("menu.edit"), [
            item(L("menu.undo"), Selector(("undo:")), "z"),
            item(L("menu.redo"), Selector(("redo:")), "Z"),
            .separator(),
            item(L("menu.cut"), #selector(NSText.cut(_:)), "x"),
            item(L("menu.copy"), #selector(NSText.copy(_:)), "c"),
            item(L("menu.paste"), #selector(NSText.paste(_:)), "v"),
            item(L("menu.selectAll"), #selector(NSText.selectAll(_:)), "a"),
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
    private static func item(_ title: String, _ action: Selector, _ key: String, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.isHidden = hidden
        return item
    }
}
