import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// What the virtual camera shows, read from the JSON the app writes to the shared app group
/// (`<group>/camera.json`), with the image (for the `image` source) in `<group>/camera-image.bin`.
/// Absent or unreadable → a default test pattern, so the device always has a live feed. The app
/// group's identifier is in the extension's Info.plist (`PBCameraAppGroup`).
struct CameraExtensionConfig {
    /// "color", "bars" or "image" (video and filters are drawn by the in-page shim for now).
    var source: String
    var colorHex: String
    var width: Int
    var height: Int
    var frameRate: Int
    /// "cover", "contain" or "stretch".
    var fit: String
    var mirror: Bool
    /// A sub-rectangle of the image (normalised 0…1), or nil for the whole image.
    var crop: (x: Double, y: Double, width: Double, height: Double)?

    /// The fixed CoreMediaIO device name (the shim's sentinel). Matches
    /// `CameraSubstitution.systemDeviceName` in BrowserCore; kept as a literal here so the
    /// extension needs no BrowserCore dependency.
    static let deviceName = "Lumen Camera"
    static let imageFileName = "camera-image.bin"

    static let fallback = CameraExtensionConfig(source: "bars", colorHex: "#1E2130",
                                                width: 1280, height: 720, frameRate: 30,
                                                fit: "cover", mirror: false, crop: nil)

    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "PBCameraAppGroup") as? String
    }

    static var container: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func current() -> CameraExtensionConfig {
        guard let url = container?.appendingPathComponent("camera.json"), let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return fallback }
        func string(_ key: String, _ fallback: String) -> String { (object[key] as? String) ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { (object[key] as? NSNumber)?.intValue ?? fallback }
        var crop: (x: Double, y: Double, width: Double, height: Double)?
        if let c = object["crop"] as? [String: Any], (c["enabled"] as? NSNumber)?.boolValue == true {
            func d(_ key: String, _ fb: Double) -> Double { (c[key] as? NSNumber)?.doubleValue ?? fb }
            crop = (d("x", 0), d("y", 0), d("width", 1), d("height", 1))
        }
        return CameraExtensionConfig(source: string("source", fallback.source),
                                     colorHex: string("color", fallback.colorHex),
                                     width: int("width", fallback.width), height: int("height", fallback.height),
                                     frameRate: int("frameRate", fallback.frameRate),
                                     fit: string("fit", fallback.fit),
                                     mirror: (object["mirror"] as? NSNumber)?.boolValue ?? false,
                                     crop: crop)
    }
}

/// Draws one frame into a BGRA pixel buffer. The pattern moves with `sequence`, and faint grain is
/// laid over it, so the feed is never a frozen image — as the in-page shim does.
enum CameraFrameRenderer {
    private static let bars: [(r: Double, g: Double, b: Double)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0.0), (0.0, 0.75, 0.75), (0.0, 0.75, 0.0),
        (0.75, 0.0, 0.75), (0.75, 0.0, 0.0), (0.0, 0.0, 0.75),
    ]

    // The loaded image, cached and reloaded only when the file changes (one serial timer queue).
    private static var cachedImage: CGImage?
    private static var cachedImageDate: Date?

    static func render(into pixelBuffer: CVPixelBuffer, config: CameraExtensionConfig, sequence: UInt64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else { return }

        let (br, bg, bb) = color(config.colorHex)
        if config.source == "bars" {
            drawBars(context, width: width, height: height, background: (br, bg, bb), sequence: sequence)
        } else if config.source == "image", let image = loadImage() {
            context.setFillColor(red: br, green: bg, blue: bb, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))
            drawImage(context, image: image, width: width, height: height, config: config)
        } else {
            context.setFillColor(red: br, green: bg, blue: bb, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))
        }

        grain(context, width: width, height: height)
    }

    private static func drawBars(_ context: CGContext, width: Int, height: Int,
                                 background: (Double, Double, Double), sequence: UInt64) {
        let band = Double(width) / Double(bars.count)
        for (index, bar) in bars.enumerated() {
            context.setFillColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1)
            context.fill(CGRect(x: Double(index) * band, y: Double(height) * 0.28, width: band + 1, height: Double(height) * 0.72))
        }
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height) * 0.28))
        let t = Double(sequence % 120) / 120.0
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.65)
        context.fill(CGRect(x: t * Double(width), y: Double(height) * 0.28,
                            width: max(3, Double(width) * 0.012), height: Double(height) * 0.72))
    }

    private static func drawImage(_ context: CGContext, image: CGImage, width: Int, height: Int, config: CameraExtensionConfig) {
        // Crop a sub-rectangle of the source (image coordinates are top-left origin).
        let imageWidth = Double(image.width), imageHeight = Double(image.height)
        var source = image
        if let crop = config.crop {
            let rect = CGRect(x: crop.x * imageWidth, y: crop.y * imageHeight,
                              width: max(1, crop.width * imageWidth), height: max(1, crop.height * imageHeight))
            source = image.cropping(to: rect) ?? image
        }
        let sourceWidth = Double(source.width), sourceHeight = Double(source.height)
        let frameWidth = Double(width), frameHeight = Double(height)
        var destinationWidth = frameWidth, destinationHeight = frameHeight
        if config.fit != "stretch" {
            let scale = config.fit == "contain"
                ? min(frameWidth / sourceWidth, frameHeight / sourceHeight)
                : max(frameWidth / sourceWidth, frameHeight / sourceHeight)
            destinationWidth = sourceWidth * scale
            destinationHeight = sourceHeight * scale
        }
        let destination = CGRect(x: (frameWidth - destinationWidth) / 2, y: (frameHeight - destinationHeight) / 2,
                                 width: destinationWidth, height: destinationHeight)
        context.saveGState()
        // Flip to a top-left origin so the image is upright in the pixel buffer's rows, and mirror.
        context.translateBy(x: 0, y: frameHeight)
        context.scaleBy(x: 1, y: -1)
        if config.mirror {
            context.translateBy(x: frameWidth, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.interpolationQuality = .high
        context.draw(source, in: destination)
        context.restoreGState()
    }

    private static func loadImage() -> CGImage? {
        guard let url = CameraExtensionConfig.container?.appendingPathComponent(CameraExtensionConfig.imageFileName) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let cachedImage, cachedImageDate == date { return cachedImage }
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cachedImage = image
        cachedImageDate = date
        return image
    }

    /// Faint sensor-like grain, enough to keep the frames changing.
    private static func grain(_ context: CGContext, width: Int, height: Int) {
        let count = max(24, (width * height) / 4096)
        for _ in 0..<count {
            let value = Double(UInt8.random(in: 0...255)) / 255.0
            context.setFillColor(red: value, green: value, blue: value, alpha: 0.05)
            context.fill(CGRect(x: Double(Int.random(in: 0..<width)), y: Double(Int.random(in: 0..<height)), width: 2, height: 2))
        }
    }

    private static func color(_ hex: String) -> (Double, Double, Double) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return (0.12, 0.13, 0.19) }
        return (Double((value >> 16) & 0xFF) / 255.0, Double((value >> 8) & 0xFF) / 255.0, Double(value & 0xFF) / 255.0)
    }
}
