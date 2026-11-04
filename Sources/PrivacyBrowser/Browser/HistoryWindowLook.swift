import AppKit
import WebKit

/// What the History window shows, as the person opens it in a profile's window — History › Show
/// All History (⌘Y) — read from the views on screen: every table and outline of the profile's
/// windows, their rows and the texts in them, and the state of the History-clearing items.
///
/// The owner's Mac, 0.1.2, 4 November: three pages open in a profile, its card counting 4 in
/// "Bookmarks and History" — the entries of the profile's own history — and its History window empty,
/// "Clear History…" disabled. The self-test's check had counted the entries of the store, never what
/// the window shows; this is what the window shows.
struct HistoryWindowLook: Codable, Equatable {
    /// The menu item chosen ("History › Show All History"), or why none was.
    var chosen: String
    /// Each table or outline seen: its class and how many rows it has.
    var views: [String] = []
    /// The texts in their rows (at most 200), in row order.
    var texts: [String] = []
    /// The key window's page, when a web view shows it.
    var page: String?
    /// Each item whose action clears history, with whether it can be chosen.
    var clearing: [String] = []

    /// Whether a row of the window shows `text`.
    func shows(_ text: String) -> Bool { texts.contains { $0.localizedCaseInsensitiveContains(text) } }
}

@MainActor
enum HistoryWindowReader {
    /// Chooses History › Show All History as a click on it does, waits two seconds, and reads what
    /// the windows then show.
    static func look() async -> HistoryWindowLook {
        guard let bar = NSApp.mainMenu, let (menu, index) = item(in: bar, where: isShowAllHistory) else {
            return HistoryWindowLook(chosen: "no item of the menu bar is ⌘Y")
        }
        let item = menu.items[index]
        menu.update()
        var look = HistoryWindowLook(chosen: "\(menu.title.isEmpty ? "?" : menu.title) › \(item.title)"
                                     + (item.isEnabled ? "" : " (disabled)"))
        DispatchQueue.main.async { menu.performActionForItem(at: index) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for window in NSApp.windows where window.isVisible {
            collect(window.contentView, into: &look)
        }
        if let key = NSApp.keyWindow, let webView = webView(in: key.contentView) {
            look.page = webView.url?.absoluteString
        }
        look.clearing = clearingItems(in: bar)
        return look
    }

    private static func isShowAllHistory(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == "y" && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }

    /// The first item of the menu bar, depth first, that `matches`; each menu filled as it would be
    /// when opened (History's is filled by its delegate).
    private static func item(in menu: NSMenu, where matches: (NSMenuItem) -> Bool) -> (NSMenu, Int)? {
        menu.delegate?.menuNeedsUpdate?(menu)
        for (index, entry) in menu.items.enumerated() {
            if matches(entry) { return (menu, index) }
            if let submenu = entry.submenu, let found = item(in: submenu, where: matches) { return found }
        }
        return nil
    }

    private static func clearingItems(in menu: NSMenu) -> [String] {
        var found: [String] = []
        func walk(_ menu: NSMenu) {
            menu.update()
            for entry in menu.items {
                if let action = entry.action, NSStringFromSelector(action).lowercased().contains("clearhistory") {
                    found.append("\(entry.title): \(entry.isEnabled ? "enabled" : "disabled")")
                }
                if let submenu = entry.submenu { walk(submenu) }
            }
        }
        walk(menu)
        return found
    }

    private static func collect(_ view: NSView?, into look: inout HistoryWindowLook) {
        guard let view else { return }
        if let table = view as? NSTableView {
            look.views.append("\(type(of: table)), \(table.numberOfRows) rows")
            for row in 0..<min(table.numberOfRows, 100) where look.texts.count < 200 {
                for column in 0..<table.numberOfColumns {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) {
                        look.texts += texts(in: cell)
                    } else if let cell = table.preparedCell(atColumn: column, row: row), !cell.stringValue.isEmpty {
                        look.texts.append(cell.stringValue)
                    }
                }
            }
            return
        }
        for subview in view.subviews { collect(subview, into: &look) }
    }

    private static func texts(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
        for subview in view.subviews { found += texts(in: subview) }
        return found
    }

    private static func webView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = webView(in: subview) { return found }
        }
        return nil
    }
}
