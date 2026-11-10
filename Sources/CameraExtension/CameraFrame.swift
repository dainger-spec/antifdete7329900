import CoreGraphics
import CoreVideo
import Foundation

/// What the virtual camera shows, read from the JSON the app writes to the shared app group
/// (`<group>/camera.json`). Absent or unreadable → a default test pattern, so the device always
/// has a live feed. The app group's identifier is in the extension's Info.plist (`PBCameraAppGroup`).
struct CameraExtensionConfig {
    /// "color" or "bars" in this stage (docs/CAMERA.md).
    var source: String
    var colorHex: String
    var width: Int
    var height: Int
    var frameRate: Int

    /// The fixed CoreMediaIO device name (the shim's sentinel). Matches
    /// `CameraSubstitution.systemDeviceName` in BrowserCore; kept as a literal here so the
    /// extension needs no BrowserCore dependency.
    static let deviceName = "Lumen Camera"

    static let fallback = CameraExtensionConfig(source: "bars", colorHex: "#1E2130",
                                                width: 1280, height: 720, frameRate: 30)

    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "PBCameraAppGroup") as? String
    }

    static var configURL: URL? {
        guard let appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        return container.appendingPathComponent("camera.json")
    }

    static func current() -> CameraExtensionConfig {
        guard let url = configURL, let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return fallback }
        func string(_ key: String, _ fallback: String) -> String { (object[key] as? String) ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { (object[key] as? NSNumber)?.intValue ?? fallback }
        return CameraExtensionConfig(source: string("source", fallback.source),
                                     colorHex: string("color", fallback.colorHex),
                                     width: int("width", fallback.width), height: int("height", fallback.height),
                                     frameRate: int("frameRate", fallback.frameRate))
    }
}

/// Draws one frame into a BGRA pixel buffer. The pattern moves with `sequence`, and faint grain is
/// laid over it, so the feed is never a frozen image — as the in-page shim does.
enum CameraFrameRenderer {
    private static let bars: [(r: Double, g: Double, b: Double)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0.0), (0.0, 0.75, 0.75), (0.0, 0.75, 0.0),
        (0.75, 0.0, 0.75), (0.75, 0.0, 0.0), (0.0, 0.0, 0.75),
    ]

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
            let band = Double(width) / Double(bars.count)
            for (index, bar) in bars.enumerated() {
                context.setFillColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1)
                context.fill(CGRect(x: Double(index) * band, y: Double(height) * 0.28, width: band + 1, height: Double(height) * 0.72))
            }
            context.setFillColor(red: br, green: bg, blue: bb, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height) * 0.28))
            // A sweeping bar, so the frames differ even before the grain.
            let t = Double(sequence % 120) / 120.0
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.65)
            context.fill(CGRect(x: t * Double(width), y: Double(height) * 0.28,
                                width: max(3, Double(width) * 0.012), height: Double(height) * 0.72))
        } else {
            context.setFillColor(red: br, green: bg, blue: bb, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))
        }

        grain(context, width: width, height: height)
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
