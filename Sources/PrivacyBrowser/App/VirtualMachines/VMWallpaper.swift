import AppKit
import CoreText
import Foundation

/// Lumen's desktop picture for a virtual machine: the eclipse — a dark disc rising from the foot
/// of the screen with light breaking out along its edge — and the word under it. Drawn here for
/// the machine's own screen, pixel for pixel (no image is carried in the app), and handed to the
/// guest through the folder it shares with the app, where the boot script sets it
/// (Resources/VMGuest/lumen-guest.sh).
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

        let backdrop: [CGFloat] = [8.0 / 255, 9.0 / 255, 11.0 / 255]
        context.setFillColor(CGColor(srgbRed: backdrop[0], green: backdrop[1], blue: backdrop[2], alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func gradient(_ stops: [(location: CGFloat, alpha: CGFloat)], white: Bool = true) -> CGGradient? {
            var components: [CGFloat] = []
            for stop in stops {
                components += white ? [1, 1, 1, stop.alpha] : [backdrop[0], backdrop[1], backdrop[2], stop.alpha]
            }
            let locations = stops.map { $0.location }
            return CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: stops.count)
        }

        // The backdrop is a little lighter toward the light.
        if let lift = gradient([(0, 0.045), (1, 0)]) {
            let centre = CGPoint(x: width * 0.5, y: height * 0.62)
            context.drawRadialGradient(lift, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: width * 0.75, options: [])
        }

        // The dark disc: its top at 54 % of the height, its centre far below the screen.
        let radius = width * 0.78
        let top = height * 0.54
        let centre = CGPoint(x: width * 0.5, y: top + radius)
        // The light behind it: a disc a little smaller whose top stands a hair above the dark
        // one's — so the light is a line at the top and thins out along the sides.
        let lightRadius = radius * 0.992
        let light = CGPoint(x: centre.x, y: centre.y - (radius - lightRadius) - radius * 0.0035)
        let from: CGFloat = 0.90, to: CGFloat = 1.22
        func at(_ fraction: CGFloat) -> CGFloat { (fraction - from) / (to - from) }
        if let glow = gradient([(0, 0), (at(0.985), 0), (at(0.9995), 0.95), (at(1.0), 0.62), (at(1.006), 0.34),
                                (at(1.02), 0.17), (at(1.06), 0.07), (at(1.13), 0.022), (1, 0)]) {
            context.drawRadialGradient(glow, startCenter: light, startRadius: lightRadius * from,
                                       endCenter: light, endRadius: lightRadius * to, options: [])
        }
        // The dark disc over it, its edge soft over a pixel or two.
        if let disc = gradient([(0, 1), (0.999, 1), (1, 0)], white: false) {
            context.drawRadialGradient(disc, startCenter: centre, startRadius: radius * 0.9, endCenter: centre, endRadius: radius,
                                       options: [.drawsBeforeStartLocation])
        }

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
    @discardableResult
    static func place(for display: VMDisplay, in share: URL) -> Bool {
        let picture = share.appendingPathComponent(VMGuestSettings.wallpaperFileName)
        let marker = share.appendingPathComponent(".lumen-wallpaper-size")
        let wanted = "\(display.pixelsWide)x\(display.pixelsHigh)"
        if FileManager.default.fileExists(atPath: picture.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == wanted {
            return true
        }
        guard let data = png(pixelsWide: display.pixelsWide, pixelsHigh: display.pixelsHigh),
              (try? data.write(to: picture, options: .atomic)) != nil else { return false }
        try? Data(wanted.utf8).write(to: marker, options: .atomic)
        return true
    }
}
