import AppKit
import ImageIO
import Vision
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
    /// How the first row of the table brought up is built: its views and what it gives
    /// accessibility (to read a list drawn by SwiftUI).
    var firstRow: String?
    /// What the table brought up shows, read from its pixels (Vision's text recognition) when its
    /// rows give no text to read otherwise: what a person's eyes get.
    var recognized: [String] = []
    /// Where on the screen what the item brought up is: each table's area in its window, or a whole
    /// window the item opened. Only that is read from the screen — never a window around it, whose
    /// tab bar names the page whatever the history shows.
    var regions: [ScreenRegion] = []
    /// What the window server's picture of those regions shows (`screencapture -l`, read by
    /// Vision): what is on the screen, whatever draws it. Taken by the app, not the profile's
    /// process (`HistoryWindowReader.readFromScreen`). macOS 27.0.1, full run 5: the profile's list
    /// was there (SwiftUIOutlineListView, 3 rows, the clearing items enabled) and its view, drawn
    /// in the process (`cacheDisplay`, its layer), gave Vision nothing to read; macOS 26.6.2 read it.
    var screen: [String] = []

    /// An area of a window, in points from the window's top left corner, with the window's size.
    struct ScreenRegion: Codable, Equatable {
        var window: Int
        var x: Double, y: Double, width: Double, height: Double
        var windowWidth: Double, windowHeight: Double
    }

    /// Whether a row of the window shows `text`: in the texts read, or — read from the pixels, the
    /// process's or the window server's — with at most `tolerance` characters misread.
    func shows(_ text: String, tolerance: Int = 0) -> Bool {
        if texts.contains(where: { $0.localizedCaseInsensitiveContains(text) }) { return true }
        let wanted = Array(text.lowercased().filter { !$0.isWhitespace })
        guard !wanted.isEmpty else { return false }
        for line in recognized + screen {
            let seen = Array(line.lowercased().filter { !$0.isWhitespace })
            guard seen.count >= wanted.count else { continue }
            for start in 0...(seen.count - wanted.count) {
                var misses = 0
                for index in 0..<wanted.count where seen[start + index] != wanted[index] {
                    misses += 1
                    if misses > tolerance { break }
                }
                if misses <= tolerance { return true }
            }
        }
        return false
    }
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
            if look.views.count == tablesBefore, !windowsBefore.contains(ObjectIdentifier(window)), let content = window.contentView {
                // A window the item brought up with no table in it (a list drawn otherwise): what
                // its views say to accessibility, and the whole window on the screen.
                let said = accessibleTexts(of: content, depth: 0)
                look.views.append("\(type(of: window)) '\(window.title)', no table: \(said.count) texts read by accessibility")
                look.texts += said.prefix(200)
                look.regions.append(region(of: content, in: window, whole: true))
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
            if let window = table.window { look.regions.append(region(of: table.enclosingScrollView ?? table, in: window, whole: false)) }
            for row in 0..<min(table.numberOfRows, 100) where look.texts.count < 200 {
                var rowTexts: [String] = []
                for column in 0..<table.numberOfColumns {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) {
                        rowTexts += texts(in: cell)
                        if rowTexts.isEmpty { rowTexts += accessibleTexts(of: cell, depth: 0) }
                        if row == 0, look.firstRow == nil { look.firstRow = anatomy(of: cell) }
                    } else if let cell = table.preparedCell(atColumn: column, row: row), !cell.stringValue.isEmpty {
                        rowTexts.append(cell.stringValue)
                    }
                }
                if rowTexts.isEmpty, let rowView = table.rowView(atRow: row, makeIfNecessary: true) {
                    rowTexts = texts(in: rowView)
                    if rowTexts.isEmpty { rowTexts = accessibleTexts(of: rowView, depth: 0) }
                    if row == 0, look.firstRow == nil { look.firstRow = anatomy(of: rowView) }
                }
                look.texts += rowTexts
            }
            // A list whose rows said nothing: what the table itself gives accessibility, row by row;
            // and what it shows, read from its pixels.
            if look.texts.isEmpty {
                for element in table.accessibilityRows() ?? [] where look.texts.count < 200 {
                    look.texts += accessibleTexts(of: element, depth: 0)
                }
            }
            if look.texts.isEmpty, table.numberOfRows > 0 {
                look.recognized += recognizedTexts(in: table.enclosingScrollView ?? table)
            }
            return
        }
        for subview in view.subviews { collect(subview, skipping: before, into: &look) }
    }

    /// Where `view` is in `window` (the whole window when `whole`), as the window server's picture
    /// of the window has it: from its top left corner.
    private static func region(of view: NSView, in window: NSWindow, whole: Bool) -> HistoryWindowLook.ScreenRegion {
        let size = window.frame.size
        let rect = whole ? CGRect(origin: .zero, size: size) : view.convert(view.bounds, to: nil)
        return HistoryWindowLook.ScreenRegion(window: window.windowNumber, x: rect.minX, y: size.height - rect.maxY,
                                              width: rect.width, height: rect.height,
                                              windowWidth: size.width, windowHeight: size.height)
    }

    /// A view's classes down to three levels, and what it gives accessibility: for the record.
    private static func anatomy(of view: NSView) -> String {
        func classes(_ view: NSView, _ depth: Int) -> String {
            let children = depth < 3 ? view.subviews.map { classes($0, depth + 1) } : []
            return "\(type(of: view))" + (children.isEmpty ? "" : "[" + children.joined(separator: ", ") + "]")
        }
        let accessible = (view.accessibilityChildren() ?? []).map { "\(type(of: $0))" }
        return classes(view, 0) + "; accessibility children: \(accessible.prefix(8).joined(separator: ", ")); "
            + "label \(view.accessibilityLabel() ?? "nil"), role \(view.accessibilityRole()?.rawValue ?? "nil")"
    }

    /// The lines of text Vision recognizes in a view as drawn: its cached display, else its layer.
    private static func recognizedTexts(in view: NSView) -> [String] {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return [] }
        var image: CGImage?
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            image = rep.cgImage
        }
        if image == nil || recognize(image).isEmpty, let layer = view.layer {
            let scale = view.window?.backingScaleFactor ?? 2
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.scaleBy(x: scale, y: scale)
                layer.render(in: context)
                image = context.makeImage()
            }
        }
        return recognize(image)
    }

    /// Each region as the window server shows it: its window's picture (`/usr/sbin/screencapture
    /// -l`, without the shadow), kept in `folder` as history-window-<number>.png, cut to the region
    /// (history-window-<number>-<index>.png), and the lines Vision reads there; with what was done,
    /// for the record. Called in the app, which may ask the window server for another process's
    /// window (the profile's process runs in a sandbox of its own).
    static func readFromScreen(regions: [HistoryWindowLook.ScreenRegion], folder: URL) -> (lines: [String], said: [String]) {
        var lines: [String] = []
        var said: [String] = []
        var pictures: [Int: CGImage] = [:]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, region) in regions.enumerated() {
            let file = folder.appendingPathComponent("history-window-\(region.window).png")
            if pictures[region.window] == nil {
                try? FileManager.default.removeItem(at: file)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(region.window), file.path]
                do { try process.run() } catch {
                    said.append("window \(region.window): screencapture could not start (\(error.localizedDescription))")
                    continue
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    said.append("window \(region.window): screencapture status \(process.terminationStatus), no picture")
                    continue
                }
                pictures[region.window] = image
            }
            guard let picture = pictures[region.window], region.windowWidth > 0, region.windowHeight > 0 else { continue }
            let scaleX = Double(picture.width) / region.windowWidth
            let scaleY = Double(picture.height) / region.windowHeight
            let cut = CGRect(x: region.x * scaleX, y: region.y * scaleY, width: region.width * scaleX, height: region.height * scaleY)
                .integral.intersection(CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
            guard !cut.isEmpty, let part = picture.cropping(to: cut) else {
                said.append("window \(region.window): the region \(Int(region.x)),\(Int(region.y)) \(Int(region.width))×\(Int(region.height)) pt is outside its picture")
                continue
            }
            let partFile = folder.appendingPathComponent("history-window-\(region.window)-\(index).png")
            if let destination = CGImageDestinationCreateWithURL(partFile as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, part, nil)
                CGImageDestinationFinalize(destination)
            }
            let read = recognize(part)
            said.append("window \(region.window) (\(picture.width)×\(picture.height) px), region \(Int(region.x)),\(Int(region.y)) "
                        + "\(Int(region.width))×\(Int(region.height)) pt: \(read.count) lines read, kept in \(partFile.path)")
            lines += read
        }
        return (lines, said)
    }

    static func recognize(_ image: CGImage?) -> [String] {
        guard let image else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
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
