import AppKit

/// A profile in a process of its own is an app of its own in the Dock. Its icon carries the first
/// letters of the profile's name (Settings → Behavior), so that the profiles can be told apart
/// there; with none asked for, it is the app's icon as it is.
@MainActor
enum DockIcon {
    /// Shows the icon for `name` with `initials` letters of it on this process's Dock tile.
    static func show(initials: Int, of name: String) {
        // Nil: the bundle's own icon.
        NSApp.applicationIconImage = image(initials: initials, of: name)
    }

    /// The letters shown: the first `count` of the name that are not spaces.
    static func letters(_ count: Int, of name: String) -> String {
        String(name.filter { !$0.isWhitespace }.prefix(max(0, count)))
    }

    /// The app's icon with the letters on a band across its lower part; nil without letters.
    static func image(initials: Int, of name: String) -> NSImage? {
        let shown = letters(initials, of: name)
        guard !shown.isEmpty, let base = AppIcon.image() else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let band = NSRect(x: rect.width * 0.14, y: rect.height * 0.09, width: rect.width * 0.72, height: rect.height * 0.28)
            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: band, xRadius: band.height * 0.3, yRadius: band.height * 0.3).fill()
            let font = NSFont.systemFont(ofSize: band.height * (shown.count > 2 ? 0.5 : 0.62), weight: .bold)
            let text = NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2))
            return true
        }
    }
}
