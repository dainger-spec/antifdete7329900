import CoreGraphics

/// Lumen's horizon: a dark disc rising from the foot of the picture with light breaking out along
/// its edge, on the window's black — the eclipse a virtual machine's desktop shows (VMWallpaper)
/// and the launch screen stands on (WelcomeSplash). Drawn with Core Graphics' radial gradients, no
/// image carried in the app.
enum LumenHorizon {
    /// Where the disc is in a picture `width` × `height` (y down): its radius, the y of its top and
    /// its centre, far below the picture.
    struct Geometry {
        let radius: CGFloat
        let top: CGFloat
        let centre: CGPoint

        init(width: CGFloat, height: CGFloat) {
            radius = width * 0.78
            top = height * 0.54
            centre = CGPoint(x: width * 0.5, y: top + radius)
        }

        /// A disc of `radius` whose top stands at `top`, centred in a picture `width` wide: the
        /// lock screen's, which places the rim under its heading (`LockHorizon`).
        init(width: CGFloat, top: CGFloat, radius: CGFloat) {
            self.radius = radius
            self.top = top
            centre = CGPoint(x: width * 0.5, y: top + radius)
        }
    }

    /// The window's black, as Theme.backdrop.
    static let backdrop: [CGFloat] = [8.0 / 255, 9.0 / 255, 11.0 / 255]

    /// Draws the horizon into `context`, whose y points down, over the whole `width` × `height`.
    /// `haze`: the launch screen's own, a wider glow over the rim (the owner's mock); the virtual
    /// machine's picture has none. `placed`: the disc elsewhere than the picture's own place for it;
    /// `lift` off: the backdrop keeps its one tone away from the rim (a picture that is a part of a
    /// larger black, where a lighter field would show its edges).
    @discardableResult
    static func draw(in context: CGContext, width: CGFloat, height: CGFloat, haze: Bool = false,
                     placed: Geometry? = nil, lift: Bool = true) -> Geometry {
        let geometry = placed ?? Geometry(width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return geometry }
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
        if lift, let lift = gradient([(0, 0.045), (1, 0)]) {
            let centre = CGPoint(x: width * 0.5, y: height * 0.62)
            context.drawRadialGradient(lift, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: width * 0.75, options: [])
        }

        // The dark disc: its top at 54 % of the height, its centre far below the picture.
        let radius = geometry.radius
        let centre = geometry.centre
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
        if haze, let wide = gradient([(0, 0), (0.04, 0.11), (0.2, 0.05), (0.5, 0.015), (1, 0)]) {
            context.drawRadialGradient(wide, startCenter: light, startRadius: lightRadius * 0.99,
                                       endCenter: light, endRadius: lightRadius * 1.12, options: [])
        }
        // The dark disc over it, its edge soft over a pixel or two.
        if let disc = gradient([(0, 1), (0.999, 1), (1, 0)], white: false) {
            context.drawRadialGradient(disc, startCenter: centre, startRadius: radius * 0.9, endCenter: centre, endRadius: radius,
                                       options: [.drawsBeforeStartLocation])
        }
        return geometry
    }

    /// The horizon as an image of `size` points at `scale` pixels a point, with the launch screen's
    /// haze; nil where a bitmap cannot be made.
    static func image(size: CGSize, scale: CGFloat) -> CGImage? {
        let pixelsWide = Int((size.width * scale).rounded()), pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 16_384, pixelsHigh <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Drawn with y pointing down, in points.
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context, width: size.width, height: size.height, haze: true)
        return context.makeImage()
    }
}
