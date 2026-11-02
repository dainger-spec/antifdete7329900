import AppKit
import SwiftUI

/// The picture behind the disk image's window (`scripts/make_dmg.sh`, `--render-dmg-background`):
/// the app's dark backdrop with its mark and name at the top, Lumen on the left, the link to
/// Applications on the right, an arrow from the one to the other — what to do, without a word to
/// read, so one picture serves both languages (the owner, 2 November: dark, our mark, no text but
/// perhaps the name).
///
/// Finder writes the icons' names itself, black in the light appearance and white in the dark,
/// and the picture cannot know which: each name sits on a plate of middle grey, legible in both
/// (CI captured the window in both, 1 November). The plates' place follows Finder's layout for the
/// icon size and positions below, which `make_dmg.sh` sets.
enum DiskImageBackground {
    /// The window's content, in points.
    static let size = CGSize(width: 660, height: 400)
    /// The icons' size and centres, in points from the window's top left (make_dmg.sh's layout).
    static let iconSize: CGFloat = 128
    static let appCentre = CGPoint(x: 170, y: 210)
    static let applicationsCentre = CGPoint(x: 490, y: 210)
    /// Where Finder writes an icon's name: under the icon, about this far below its centre.
    static let labelCentreBelow: CGFloat = 84
    static let labelPlate = CGSize(width: 136, height: 24)

    /// Writes `background.png` (1×) and `background@2x.png` into `folder`. False on any failure.
    static func write(to folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for scale in [1, 2] {
                guard let image = image(scale: CGFloat(scale)),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    print("FAIL could not draw the disk image's background at \(scale)x")
                    return false
                }
                try png.write(to: folder.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
            }
            print("WROTE the disk image's background to \(folder.path)")
            return true
        } catch {
            print("FAIL \(error)")
            return false
        }
    }

    static func image(scale: CGFloat) -> CGImage? {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Points from the top left, as Finder places the icons.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        // The backdrop: the lock screen's near black.
        context.setFillColor(NSColor(hex: 0x0B0C0F).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        // An eclipse's light in the top right corner, as the lock screen has it: a soft glow and the
        // thin rim of a disc that is mostly outside the window.
        let disc = CGPoint(x: size.width + 40, y: -70)
        if let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 236 / 255, green: 240 / 255, blue: 248 / 255, alpha: 0.14),
                                                               CGColor(red: 236 / 255, green: 240 / 255, blue: 248 / 255, alpha: 0)] as CFArray,
                                 locations: [0, 1]) {
            context.drawRadialGradient(glow, startCenter: disc, startRadius: 150, endCenter: disc, endRadius: 330, options: [])
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.2))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: disc.x - 190, y: disc.y - 190, width: 380, height: 380))

        // The mark and the name, together, centred at the top: the one word, the app's own.
        let markSide: CGFloat = 30
        let name = NSAttributedString(string: "Lumen", attributes: [ // l10n: not text — the app's name
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ])
        let nameSize = name.size()
        let gap: CGFloat = 10
        let left = (size.width - (markSide + gap + nameSize.width)) / 2
        let top: CGFloat = 52
        let mark = CGRect(x: left, y: top - markSide / 2, width: markSide, height: markSide)
        context.addPath(LumenMarkGeometry.glyph(LumenMarkGeometry.large, in: mark).cgPath)
        context.setFillColor(NSColor(hex: 0xF4F5F7).cgColor)
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        name.draw(at: CGPoint(x: mark.maxX + gap, y: top - nameSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        // The arrow from Lumen to Applications.
        let from = CGPoint(x: appCentre.x + iconSize / 2 + 28, y: appCentre.y)
        let to = CGPoint(x: applicationsCentre.x - iconSize / 2 - 28, y: applicationsCentre.y)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: from)
        context.addLine(to: to)
        context.move(to: CGPoint(x: to.x - 11, y: to.y - 9))
        context.addLine(to: to)
        context.addLine(to: CGPoint(x: to.x - 11, y: to.y + 9))
        context.strokePath()

        // The plates under the icons' names (see above).
        context.setFillColor(NSColor(hex: 0x6E6E76).cgColor)
        for centre in [appCentre, applicationsCentre] {
            let plate = CGRect(x: centre.x - labelPlate.width / 2, y: centre.y + labelCentreBelow - labelPlate.height / 2,
                               width: labelPlate.width, height: labelPlate.height)
            context.addPath(CGPath(roundedRect: plate, cornerWidth: labelPlate.height / 2, cornerHeight: labelPlate.height / 2,
                                   transform: nil))
            context.fillPath()
        }
        return context.makeImage()
    }
}
