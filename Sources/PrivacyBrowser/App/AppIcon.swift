import AppKit
import SwiftUI

/// The app icon, drawn from the Lumen mark's construction (LumenMark.swift) — the near-black
/// continuous-corner tile, its faint light ring and the white split disc — on macOS's icon grid:
/// the tile is 824 of 1024 pixels, centred, over a soft shadow. `scripts/build-app.sh` writes the
/// iconset with `--render-app-icon` and turns it into Contents/Resources/AppIcon.icns with
/// iconutil; a bare SwiftPM run (no bundle, so no icon file) sets it as the Dock icon at launch.
enum AppIcon {
    /// iconutil's file names and their sizes in pixels.
    static let iconset: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// Writes the iconset's PNG files into `folder` (created if needed). False on any failure.
    static func writeIconset(to folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for entry in iconset {
                guard let image = image(pixels: entry.pixels),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    print("FAIL could not draw \(entry.name)")
                    return false
                }
                try png.write(to: folder.appendingPathComponent("\(entry.name).png"))
            }
            print("WROTE \(iconset.count) icon images to \(folder.path)")
            return true
        } catch {
            print("FAIL could not write the iconset: \(error.localizedDescription)")
            return false
        }
    }

    /// The icon as the Dock shows it (512 pt, drawn at 1024 px).
    static func image() -> NSImage? {
        image(pixels: 1024).map { NSImage(cgImage: $0, size: NSSize(width: 512, height: 512)) }
    }

    /// The icon `pixels` wide. Each size is drawn from the geometry, in the cut `LumenMark` uses
    /// for a tile that many pixels wide (the 16-grid cut below 28).
    static func image(pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let unit = CGFloat(pixels) / 1024
        // The mark's paths are drawn with y pointing down, as in SwiftUI.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        let tileRect = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let tile = RoundedRectangle(cornerRadius: tileRect.width * 0.2235, style: .continuous).path(in: tileRect).cgPath

        // The tile, over the grid's shadow (shadow offsets are not flipped with the context: down is −y).
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 22 * unit, color: CGColor(gray: 0, alpha: 0.32))
        context.addPath(tile)
        context.setFillColor(NSColor(hex: 0x16181D).cgColor)
        context.fillPath()
        context.restoreGState()

        // The faint light ring just inside the tile's edge (LumenMark's strokeBorder): the stroke
        // is centred on the edge, so twice the width is stroked and the outer half clipped away.
        context.saveGState()
        context.addPath(tile)
        context.clip()
        context.addPath(tile)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        context.setLineWidth(2 * max(tileRect.width / 96, 1))
        context.strokePath()
        context.restoreGState()

        // The split disc.
        let cut = LumenMarkGeometry.cut(forTileSize: tileRect.width)
        context.addPath(LumenMarkGeometry.glyph(cut, in: tileRect).cgPath)
        context.setFillColor(NSColor(hex: 0xF4F5F7).cgColor)
        context.fillPath()
        return context.makeImage()
    }
}
