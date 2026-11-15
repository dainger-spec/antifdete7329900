import AppKit
import CoreGraphics
import CoreText

/// The eclipse of a virtual machine's desktop — a dark disc rising from the foot of the screen
/// with light breaking out along its edge, and "LUMEN" under the light — for the cover over its
/// start: the same picture as the machine's wallpaper (the app's `VMWallpaper` draws that one for
/// the guest; these are its numbers, line for line), so that the cover's horizon is the desktop's
/// when it goes. And the cover's light, each a layer of its own that the view moves on the GPU:
/// the haze over the rim (it breathes: its opacity) and the glint (it glides: turned about the
/// disc's centre). Both are erased where the disc is, so they lie behind it on any picture.
///
/// design/prototypes/vm-cover.html draws the same, frame by frame.
public enum MachineHorizon {
    /// Where the disc and its light are in a picture `size` (y down).
    public struct Geometry: Equatable {
        public let size: CGSize
        /// The dark disc: its radius, the y of its top, its centre far below the picture.
        public let radius: CGFloat
        public let top: CGFloat
        public let centre: CGPoint
        /// The light behind it: a disc a little smaller whose top stands a hair above the dark one's.
        public let lightRadius: CGFloat
        public let light: CGPoint

        public init(size: CGSize) {
            self.size = size
            radius = size.width * 0.78
            top = size.height * 0.54
            centre = CGPoint(x: size.width * 0.5, y: top + radius)
            lightRadius = radius * 0.992
            light = CGPoint(x: centre.x, y: centre.y - (radius - lightRadius) - radius * 0.0035)
        }

        /// Half the angle of the rim the picture shows, from its top (radians).
        public var visibleHalfAngle: CGFloat { asin(min(1, size.width / 2 / radius)) }
    }

    /// The glint's light (the prototype's GLINT): its bloom's radius (of the width) and strength,
    /// its run along the rim (σ, of the width), and its strokes — a hot core and a narrow glow.
    static let bloomRadius: CGFloat = 0.06
    static let bloom: CGFloat = 0.42
    static let glintLength: CGFloat = 0.045
    static let glintStrokes: [(width: CGFloat, alpha: CGFloat)] = [(5, 0.22), (2.2, 0.9)]

    /// The window's black, as the app's `Theme.backdrop`.
    static let backdrop: [CGFloat] = [8.0 / 255, 9.0 / 255, 11.0 / 255]

    // MARK: The layers

    /// The machine's desktop picture at `size` points, `scale` pixels a point: the backdrop, its
    /// lift toward the light, the light's glow, the dark disc, the word.
    public static func picture(size: CGSize, scale: CGFloat) -> CGImage? {
        bitmap(CGRect(origin: .zero, size: size), scale: scale) { context in
            let geometry = Geometry(size: size)
            drawBehind(in: context, geometry)
            drawDisc(in: context, geometry)
            drawWord(in: context, geometry)
        }
    }

    /// The haze over the rim at full strength (the view breathes its opacity), erased where the
    /// disc is. Soft: drawn at `scale`, which may be well under the screen's.
    public static func haze(size: CGSize, scale: CGFloat) -> CGImage? {
        bitmap(CGRect(origin: .zero, size: size), scale: scale) { context in
            let geometry = Geometry(size: size)
            let light = geometry.light, lightRadius = geometry.lightRadius
            if let wide = gradient([(0, 0), (0.04, 0.11), (0.2, 0.05), (0.5, 0.015), (1, 0)]) {
                context.drawRadialGradient(wide, startCenter: light, startRadius: lightRadius * 0.99,
                                           endCenter: light, endRadius: lightRadius * 1.12, options: [])
            }
            erase(disc: geometry, in: context)
        }
    }

    /// Where the glint's layer stands at the top of the rim, in the picture's points.
    public static func glintFrame(_ geometry: Geometry) -> CGRect {
        let width = geometry.size.width
        let run = width * glintLength * 3 + 8
        let above = width * bloomRadius + 4
        // How far the rim falls over the run, and the strokes' half widths below it.
        let fall = geometry.radius - (geometry.radius * geometry.radius - run * run).squareRoot() + 8
        return CGRect(x: geometry.centre.x - run, y: geometry.top - above, width: run * 2, height: above + fall)
    }

    /// The glint at the top of the rim at full strength, erased where the disc is: turned about the
    /// disc's centre by an angle, it is the glint there (the rim is a circle about that centre).
    /// Its place in the picture is `glintFrame`.
    public static func glint(size: CGSize, scale: CGFloat) -> CGImage? {
        let geometry = Geometry(size: size)
        return bitmap(glintFrame(geometry), scale: scale) { context in
            let width = geometry.size.width
            let r = geometry.radius + 0.5
            let point = CGPoint(x: geometry.centre.x, y: geometry.centre.y - r)
            // Light added to light, as the prototype's "lighter".
            context.setBlendMode(.plusLighter)
            if let bloomGradient = gradient([(0, bloom), (0.12, 0.62 * bloom), (0.3, 0.3 * bloom), (0.55, 0.1 * bloom),
                                             (0.8, 0.025 * bloom), (1, 0)]) {
                context.drawRadialGradient(bloomGradient, startCenter: point, startRadius: 0, endCenter: point,
                                           endRadius: width * bloomRadius, options: [])
            }
            // Along the rim the strokes' light falls away as a bell (σ: glintLength of the width);
            // over so short a run the rim is near level, and the bell is drawn across x.
            let sigma = width * glintLength
            let circle = CGPath(ellipseIn: CGRect(x: geometry.centre.x - r, y: geometry.centre.y - r, width: r * 2, height: r * 2),
                                transform: nil)
            for stroke in glintStrokes {
                var stops: [(location: CGFloat, alpha: CGFloat)] = []
                for k in -12...12 {
                    let x = CGFloat(k) / 12 * 3 * sigma
                    stops.append((location: CGFloat(k + 12) / 24, alpha: stroke.alpha * exp(-(x * x) / (2 * sigma * sigma))))
                }
                guard let bell = gradient(stops) else { continue }
                context.saveGState()
                context.addPath(circle)
                context.setLineWidth(stroke.width)
                context.replacePathWithStrokedPath()
                context.clip()
                context.drawLinearGradient(bell, start: CGPoint(x: point.x - 3 * sigma, y: 0), end: CGPoint(x: point.x + 3 * sigma, y: 0),
                                           options: [])
                context.restoreGState()
            }
            erase(disc: geometry, in: context)
        }
    }

    // MARK: Drawing — VMWallpaper's, line for line

    /// White (or the backdrop) at each stop's alpha.
    static func gradient(_ stops: [(location: CGFloat, alpha: CGFloat)], white: Bool = true) -> CGGradient? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var components: [CGFloat] = []
        for stop in stops {
            components += white ? [1, 1, 1, stop.alpha] : [backdrop[0], backdrop[1], backdrop[2], stop.alpha]
        }
        let locations = stops.map { $0.location }
        return CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: stops.count)
    }

    /// The backdrop, a little lighter toward the light, and the light's glow along the rim.
    static func drawBehind(in context: CGContext, _ geometry: Geometry) {
        let width = geometry.size.width, height = geometry.size.height
        context.setFillColor(CGColor(srgbRed: backdrop[0], green: backdrop[1], blue: backdrop[2], alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let lift = gradient([(0, 0.045), (1, 0)]) {
            let centre = CGPoint(x: width * 0.5, y: height * 0.62)
            context.drawRadialGradient(lift, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: width * 0.75, options: [])
        }
        let from: CGFloat = 0.90, to: CGFloat = 1.22
        func at(_ fraction: CGFloat) -> CGFloat { (fraction - from) / (to - from) }
        if let glow = gradient([(0, 0), (at(0.985), 0), (at(0.9995), 0.95), (at(1.0), 0.62), (at(1.006), 0.34),
                                (at(1.02), 0.17), (at(1.06), 0.07), (at(1.13), 0.022), (1, 0)]) {
            context.drawRadialGradient(glow, startCenter: geometry.light, startRadius: geometry.lightRadius * from,
                                       endCenter: geometry.light, endRadius: geometry.lightRadius * to, options: [])
        }
    }

    /// The dark disc over the light, its edge soft over a pixel or two.
    static func drawDisc(in context: CGContext, _ geometry: Geometry) {
        if let disc = gradient([(0, 1), (0.999, 1), (1, 0)], white: false) {
            context.drawRadialGradient(disc, startCenter: geometry.centre, startRadius: geometry.radius * 0.9,
                                       endCenter: geometry.centre, endRadius: geometry.radius, options: [.drawsBeforeStartLocation])
        }
    }

    /// What is drawn so far, taken away where the disc is (its soft edge too).
    static func erase(disc geometry: Geometry, in context: CGContext) {
        context.setBlendMode(.destinationOut)
        drawDisc(in: context, geometry)
        context.setBlendMode(.normal)
    }

    /// The word, letter-spaced, under the light.
    static func drawWord(in context: CGContext, _ geometry: Geometry) {
        let width = geometry.size.width
        let size = (width * 0.0125).rounded()
        let spacing = width * 0.0085
        // By Core Text's own names for the attributes: the line is drawn by it, not by AppKit.
        let text = NSAttributedString(string: "LUMEN", attributes: [ // l10n: not text
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: .semibold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: 244.0 / 255, green: 244.0 / 255, blue: 245.0 / 255, alpha: 0.42),
            NSAttributedString.Key(kCTKernAttributeName as String): NSNumber(value: Double(spacing)),
        ])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        // The kern stands after the last letter too: not part of the word's width.
        let wordWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - spacing
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: geometry.centre.x - wordWidth / 2, y: geometry.top + geometry.size.height * 0.11)
        CTLineDraw(line, context)
    }

    /// A bitmap of the picture's points in `rect`, `scale` pixels a point, drawn with y down.
    static func bitmap(_ rect: CGRect, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let pixelsWide = Int((rect.width * scale).rounded(.up)), pixelsHigh = Int((rect.height * scale).rounded(.up))
        guard scale > 0, pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 16_384, pixelsHigh <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        draw(context)
        return context.makeImage()
    }
}
