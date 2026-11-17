import AppKit
import BrowserCore
import CoreText
import Foundation

/// Lumen's desktop picture for a virtual machine: the eclipse — a dark disc rising from the foot
/// of the screen with light breaking out along its edge (LumenHorizon, the launch screen's too) —
/// and the word under it. Drawn here for the machine's own screen, pixel for pixel (no image is
/// carried in the app), and handed to the guest through the folder it shares with the app, where
/// the boot script sets it (Resources/VMGuest/lumen-guest.sh).
enum VMWallpaper {
    /// The picture as a PNG, `pixelsWide` × `pixelsHigh`; nil where a picture cannot be made.
    static func png(pixelsWide: Int, pixelsHigh: Int) -> Data? {
        guard (640...8192).contains(pixelsWide), (400...8192).contains(pixelsHigh),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let width = CGFloat(pixelsWide), height = CGFloat(pixelsHigh)
        // Drawn with y pointing down, as the design's numbers are.
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)

        // The horizon, as the launch screen has it too (LumenHorizon).
        let horizon = LumenHorizon.draw(in: context, width: width, height: height)
        let centre = horizon.centre, top = horizon.top

        // The word, letter-spaced, under the light.
        let size = (width * 0.0125).rounded()
        let spacing = width * 0.0085
        // By Core Text's own names for the attributes: the line is drawn by it, not by AppKit.
        let text = NSAttributedString(string: "LUMEN", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: .semibold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 244.0 / 255, green: 244.0 / 255, blue: 245.0 / 255, alpha: 0.42),
            NSAttributedString.Key(kCTKernAttributeName as String): NSNumber(value: Double(spacing)),
        ])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        // The kern stands after the last letter too: not part of the word's width.
        let wordWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - spacing
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: centre.x - wordWidth / 2, y: top + height * 0.11)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Puts the picture for `display` into `share`, as the guest's boot script looks for it — once:
    /// a picture already there for that screen is left. Returns whether one is there.
    ///
    /// The share is written by the guest too: the marker is read as a file of the guest's
    /// (`VMShareFile`: no link followed, no pipe waited on, a few bytes at most), and a picture or
    /// a marker that is not a plain file is removed (a link itself, not what it points to) and
    /// written anew. Not for the main thread.
    @discardableResult
    static func place(for display: VMDisplay, in share: URL) -> Bool {
        let picture = share.appendingPathComponent(VMGuestSettings.wallpaperFileName)
        let marker = share.appendingPathComponent(".lumen-wallpaper-size")
        let wanted = "\(display.pixelsWide)x\(display.pixelsHigh)"
        if VMShareFile.isRegularFile(picture), (try? VMShareFile.read(marker, maximumBytes: 64).get()) == wanted {
            return true
        }
        for file in [picture, marker] where !VMShareFile.isRegularFile(file) { try? FileManager.default.removeItem(at: file) }
        guard let data = png(pixelsWide: display.pixelsWide, pixelsHigh: display.pixelsHigh),
              (try? data.write(to: picture, options: .atomic)) != nil else { return false }
        try? Data(wanted.utf8).write(to: marker, options: .atomic)
        return true
    }
}
