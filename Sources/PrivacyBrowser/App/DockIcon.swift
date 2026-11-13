import AppKit
import SwiftUI

/// A profile in a process of its own is an app of its own in the Dock. Its icon carries the first
/// letters of the profile's name (Settings → Behavior), so that the profiles can be told apart
/// there, and the flag of the country its proxy exits in, as the app's windows show it; with
/// neither, it is the app's icon as it is.
@MainActor
enum DockIcon {
    /// What the tile shows now: so many letters of the name, and where the proxy exits (ISO code).
    private static var initials = 0
    private static var name = ""
    private static var country: String?

    /// Shows the icon for `name` with `initials` letters of it on this process's Dock tile.
    static func show(initials: Int, of name: String) {
        self.initials = initials
        self.name = name
        apply()
    }

    /// Where the profile's proxy exits, once its process knows (the launch's lookup, or what was
    /// remembered for the proxy): its flag beside the letters. Nil — a direct profile, or no country
    /// known — shows none.
    static func showExit(country: String?) {
        self.country = country
        apply()
    }

    private static func apply() {
        // Nil: the bundle's own icon.
        NSApp.applicationIconImage = image(initials: initials, of: name, country: country)
    }

    /// The letters shown: the first `count` of the name that are not spaces.
    static func letters(_ count: Int, of name: String) -> String {
        String(name.filter { !$0.isWhitespace }.prefix(max(0, count)))
    }

    /// The app's icon with a band across its lower part — the exit country's flag, then the
    /// letters, together in its middle; nil with neither.
    static func image(initials: Int, of name: String, country: String? = nil) -> NSImage? {
        let shown = letters(initials, of: name)
        let flag = country.flatMap(flagImage)
        guard !shown.isEmpty || flag != nil, let base = AppIcon.image() else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            // The band is laid out in the icon's tile (AppIcon's: 824 of 1024, centred) and clipped
            // to it: laid out in the whole image its corners stuck out past the tile's, and at 92 %
            // the disc showed through it.
            let unit = rect.width / 1024
            let tile = NSRect(x: rect.minX + 100 * unit, y: rect.minY + 100 * unit, width: 824 * unit, height: 824 * unit)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2235, yRadius: tile.width * 0.2235).addClip()
            let band = NSRect(x: tile.minX + tile.width * 0.06, y: tile.minY + tile.height * 0.05,
                              width: tile.width * 0.88, height: tile.height * 0.34)
            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: band, xRadius: band.height * 0.3, yRadius: band.height * 0.3).fill()
            let font = NSFont.systemFont(ofSize: band.height * (shown.count > 2 ? 0.5 : 0.62), weight: .bold)
            let text = shown.isEmpty ? nil : NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: NSColor.white])
            let textSize = text?.size() ?? .zero
            let flagSide = flag == nil ? 0 : band.height * 0.62
            let gap = flag != nil && text != nil ? band.height * 0.2 : 0
            var x = band.midX - (flagSide + gap + textSize.width) / 2
            if let flag {
                flag.draw(in: NSRect(x: x, y: band.midY - flagSide / 2, width: flagSide, height: flagSide))
                x += flagSide + gap
            }
            text?.draw(at: NSPoint(x: x, y: band.midY - textSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// The country's flag as the app's windows draw it (`CountryFlag`: a flat circle, its ring);
    /// nil for a code that is not a country's — no globe on the tile.
    private static func flagImage(_ code: String) -> NSImage? {
        guard CountryFlag.emoji(for: code) != nil else { return nil }
        let renderer = ImageRenderer(content: CountryFlag(code: code, size: 64))
        renderer.scale = 4
        return renderer.nsImage
    }
}
