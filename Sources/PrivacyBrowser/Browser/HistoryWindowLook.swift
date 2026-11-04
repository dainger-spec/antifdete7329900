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
    /// the windows then show: the tables and outlines that were not on screen before — Safari's own
    /// sidebar or a list already open are not the window the item brought up.
    static func look() async -> HistoryWindowLook {
        guard let bar = NSApp.mainMenu, let (menu, index) = item(in: bar, where: HistoryMenuRoute.showsAllHistory) else {
            return HistoryWindowLook(chosen: "no item of the menu bar is ⌘Y")
        }
        var before = Set<ObjectIdentifier>()
        var windowsBefore = Set<ObjectIdentifier>()
        for window in NSApp.windows where window.isVisible {
            tables(in: window.contentView, into: &before)
            windowsBefore.insert(ObjectIdentifier(window))
        }
        let item = menu.items[index]
        menu.update()
        var look = HistoryWindowLook(chosen: "\(menu.title.isEmpty ? "?" : menu.title) › \(item.title)"
                                     + (item.isEnabled ? "" : " (disabled)"))
        DispatchQueue.main.async { menu.performActionForItem(at: index) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for window in NSApp.windows where window.isVisible {
            let tablesBefore = look.views.count
            collect(window.contentView, skipping: before, into: &look)
            // A window the item brought up with no table in it (a list drawn otherwise): what its
            // views say to accessibility.
            if look.views.count == tablesBefore, !windowsBefore.contains(ObjectIdentifier(window)), let content = window.contentView {
                let said = accessibleTexts(of: content, depth: 0)
                look.views.append("\(type(of: window)) '\(window.title)', no table: \(said.count) texts read by accessibility")
                look.texts += said.prefix(200)
            }
        }
        if let key = NSApp.keyWindow, let webView = webView(in: key.contentView) {
            look.page = webView.url?.absoluteString
        }
        look.clearing = clearingItems(in: bar)
        return look
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
                if HistoryMenuRoute.clearsHistory(entry) {
                    found.append("\(entry.title): \(entry.isEnabled ? "enabled" : "disabled")")
                }
                if let submenu = entry.submenu { walk(submenu) }
            }
        }
        walk(menu)
        return found
    }

    private static func tables(in view: NSView?, into found: inout Set<ObjectIdentifier>) {
        guard let view else { return }
        if view is NSTableView { found.insert(ObjectIdentifier(view)) }
        for subview in view.subviews { tables(in: subview, into: &found) }
    }

    /// Every table or outline not in `before`, with the texts of its rows: a text field's, a cell's,
    /// or — in a SwiftUI list, whose rows draw their own text — what each row says to accessibility.
    private static func collect(_ view: NSView?, skipping before: Set<ObjectIdentifier>, into look: inout HistoryWindowLook) {
        guard let view else { return }
        if let table = view as? NSTableView {
            guard !before.contains(ObjectIdentifier(table)) else { return }
            look.views.append("\(type(of: table)), \(table.numberOfRows) rows")
            for row in 0..<min(table.numberOfRows, 100) where look.texts.count < 200 {
                var rowTexts: [String] = []
                for column in 0..<table.numberOfColumns {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) {
                        rowTexts += texts(in: cell)
                    } else if let cell = table.preparedCell(atColumn: column, row: row), !cell.stringValue.isEmpty {
                        rowTexts.append(cell.stringValue)
                    }
                }
                if rowTexts.isEmpty, let rowView = table.rowView(atRow: row, makeIfNecessary: true) {
                    rowTexts = texts(in: rowView)
                    if rowTexts.isEmpty { rowTexts = accessibleTexts(of: rowView, depth: 0) }
                }
                look.texts += rowTexts
            }
            return
        }
        for subview in view.subviews { collect(subview, skipping: before, into: &look) }
    }

    private static func texts(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
        for subview in view.subviews { found += texts(in: subview) }
        return found
    }

    /// The labels and values an element and its children give accessibility (in this process: no
    /// right is needed to ask one's own views).
    private static func accessibleTexts(of element: Any, depth: Int) -> [String] {
        guard depth < 12, let object = element as? NSObject else { return [] }
        var found: [String] = []
        for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let text = object.perform(selector)?.takeUnretainedValue() as? String,
                  !text.isEmpty, !found.contains(text) else { continue }
            found.append(text)
        }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        if object.responds(to: childrenSelector), let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
            for child in children where found.count < 300 {
                found += accessibleTexts(of: child, depth: depth + 1)
            }
        }
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
