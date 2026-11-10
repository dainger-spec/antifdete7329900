import AppKit
import AVFoundation
import BrowserCore
import CoreImage
import ImageIO
import QuartzCore
import SwiftUI

/// Draws one frame of what a page would be handed for a `CameraSubstitution`, for the editor's live
/// preview — the same pipeline the system-camera extension and the in-page shim draw (source, crop,
/// fit, mirror, the adjustments), so the preview matches the real feed. A video source is played and
/// looped so the preview moves like the real feed.
enum CameraPreview {
    private static let ciContext = CIContext()
    private static let bars: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0.0), (0.0, 0.75, 0.75), (0.0, 0.75, 0.0),
        (0.75, 0.0, 0.75), (0.75, 0.0, 0.0), (0.0, 0.0, 0.75),
    ]
    private static var cachedVideoFrame: (key: Int, image: CGImage?)?
    // A looping player for the live video preview, keyed by the video's bytes.
    private static var livePlayer: (key: Int, player: AVPlayer, output: AVPlayerItemVideoOutput, last: CGImage?)?

    static func frame(for camera: CameraSubstitution, width: Int, height: Int, sequence: UInt64) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        drawBase(context, camera: camera, width: width, height: height, sequence: sequence)
        guard let base = context.makeImage() else { return nil }
        guard !camera.filters.isIdentity else { return base }
        let source = CIImage(cgImage: base)
        let filtered = applyFilters(camera.filters, to: source)
        return ciContext.createCGImage(filtered, from: source.extent) ?? base
    }

    static func nsImage(for camera: CameraSubstitution, width: Int, height: Int, sequence: UInt64) -> NSImage? {
        guard let frame = frame(for: camera, width: width, height: height, sequence: sequence) else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: width, height: height))
    }

    /// The whole source — the chosen image, or a video's first frame — for the crop tool to drag a
    /// rectangle over; nil for a colour or the test pattern (there is nothing to crop).
    static func sourceImage(for camera: CameraSubstitution) -> NSImage? {
        let cgImage: CGImage?
        switch camera.source {
        case .image: cgImage = camera.imageData.flatMap(decode)
        case .video: cgImage = videoFrame(for: camera)
        case .color, .bars: cgImage = nil
        }
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func drawBase(_ context: CGContext, camera: CameraSubstitution, width: Int, height: Int, sequence: UInt64) {
        let bg = color(camera.colorHex)
        context.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        switch camera.source {
        case .color:
            break
        case .bars:
            drawBars(context, width: width, height: height, background: bg, sequence: sequence)
        case .image:
            if let data = camera.imageData, let image = decode(data) {
                drawImage(context, image: image, camera: camera, width: width, height: height)
            }
        case .video:
            if let image = videoFrame(for: camera) {
                drawImage(context, image: image, camera: camera, width: width, height: height)
            }
        }
    }

    private static func drawBars(_ context: CGContext, width: Int, height: Int, background: (r: CGFloat, g: CGFloat, b: CGFloat), sequence: UInt64) {
        let band = CGFloat(width) / CGFloat(bars.count)
        for (index, bar) in bars.enumerated() {
            context.setFillColor(red: bar.r, green: bar.g, blue: bar.b, alpha: 1)
            context.fill(CGRect(x: CGFloat(index) * band, y: CGFloat(height) * 0.28, width: band + 1, height: CGFloat(height) * 0.72))
        }
        context.setFillColor(red: background.r, green: background.g, blue: background.b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.28))
        let t = CGFloat(sequence % 120) / 120.0
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.65)
        context.fill(CGRect(x: t * CGFloat(width), y: CGFloat(height) * 0.28, width: max(3, CGFloat(width) * 0.012), height: CGFloat(height) * 0.72))
    }

    private static func drawImage(_ context: CGContext, image: CGImage, camera: CameraSubstitution, width: Int, height: Int) {
        let imageWidth = CGFloat(image.width), imageHeight = CGFloat(image.height)
        var source = image
        if camera.crop.enabled {
            let rect = CGRect(x: camera.crop.x * imageWidth, y: camera.crop.y * imageHeight,
                              width: max(1, camera.crop.width * imageWidth), height: max(1, camera.crop.height * imageHeight))
            source = image.cropping(to: rect) ?? image
        }
        let sourceWidth = CGFloat(source.width), sourceHeight = CGFloat(source.height)
        let frameWidth = CGFloat(width), frameHeight = CGFloat(height)
        var destinationWidth = frameWidth, destinationHeight = frameHeight
        if camera.fit != .stretch {
            let scale = camera.fit == .contain
                ? min(frameWidth / sourceWidth, frameHeight / sourceHeight)
                : max(frameWidth / sourceWidth, frameHeight / sourceHeight)
            destinationWidth = sourceWidth * scale
            destinationHeight = sourceHeight * scale
        }
        let destination = CGRect(x: (frameWidth - destinationWidth) / 2, y: (frameHeight - destinationHeight) / 2,
                                 width: destinationWidth, height: destinationHeight)
        context.saveGState()
        if camera.mirror { context.translateBy(x: frameWidth, y: 0); context.scaleBy(x: -1, y: 1) }
        context.interpolationQuality = .high
        context.draw(source, in: destination)
        context.restoreGState()
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The live frame of the chosen video, played and looped, for the preview; falls back to the
    /// first frame until the player has one.
    private static func videoFrame(for camera: CameraSubstitution) -> CGImage? {
        guard let data = camera.videoData else { return nil }
        let key = data.count
        if livePlayer?.key != key {
            livePlayer?.player.pause()
            livePlayer = nil
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pb-cam-live.mov")
            if (try? data.write(to: url)) != nil {
                let item = AVPlayerItem(url: url)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.play()
                livePlayer = (key, player, output, firstVideoFrame(for: camera))
            }
        }
        guard var state = livePlayer else { return firstVideoFrame(for: camera) }
        let time = state.output.itemTime(forHostTime: CACurrentMediaTime())
        if state.output.hasNewPixelBuffer(forItemTime: time),
           let pixelBuffer = state.output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            state.last = ciContext.createCGImage(ci, from: ci.extent) ?? state.last
            livePlayer = state
        }
        if let item = state.player.currentItem, item.duration.isNumeric,
           CMTimeGetSeconds(state.player.currentTime()) >= CMTimeGetSeconds(item.duration) - 0.05 {
            state.player.seek(to: .zero)
        }
        return livePlayer?.last
    }

    /// The first frame of the chosen video (cached), via a temporary file.
    private static func firstVideoFrame(for camera: CameraSubstitution) -> CGImage? {
        guard let data = camera.videoData else { return nil }
        let key = data.count
        if let cachedVideoFrame, cachedVideoFrame.key == key { return cachedVideoFrame.image }
        var image: CGImage?
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pb-cam-preview-\(key).mov")
        if (try? data.write(to: url)) != nil {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: max(0, camera.playback.startOffset), preferredTimescale: 600)
            image = try? generator.copyCGImage(at: time, actualTime: nil)
            try? FileManager.default.removeItem(at: url)
        }
        cachedVideoFrame = (key, image)
        return image
    }

    private static func applyFilters(_ filters: CameraSubstitution.Filters, to source: CIImage) -> CIImage {
        let extent = source.extent
        var image = source
        if filters.brightness != 1 { image = multiplyRGB(image, filters.brightness) }
        let saturation = filters.grayscale ? 0 : filters.saturation
        if filters.contrast != 1 || saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": filters.contrast, "inputSaturation": saturation, "inputBrightness": 0.0])
        }
        if filters.blur > 0 { image = image.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": filters.blur]).cropped(to: extent) }
        if filters.hueRotate != 0 { image = image.applyingFilter("CIHueAdjust", parameters: ["inputAngle": filters.hueRotate * .pi / 180.0]) }
        if filters.sepia > 0 { image = image.applyingFilter("CISepiaTone", parameters: ["inputIntensity": filters.sepia]) }
        if filters.invert > 0 {
            let scale = 1 - 2 * filters.invert, bias = filters.invert
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        if filters.opacity != 1 { image = multiplyRGB(image, filters.opacity) }
        return image.cropped(to: extent)
    }

    private static func multiplyRGB(_ image: CIImage, _ factor: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    private static func color(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return (0.12, 0.13, 0.19) }
        return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
    }
}

/// Carries the camera settings to the separate preview window, so it updates live as the editor
/// changes them (a `Binding` snapshot would not).
@MainActor
final class CameraMirror: ObservableObject {
    @Published var camera: CameraSubstitution = .off
}

/// A live preview of what a page would get, redrawn a few times a second so motion (the test
/// pattern) and every edit (source, crop, fit, mirror, the adjustments) show at once.
struct CameraPreviewView: View {
    let camera: CameraSubstitution
    var height: CGFloat = 150

    @State private var sequence: UInt64 = 0
    private let timer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    /// The preview renders at a small, fixed size; the real feed uses the configured resolution.
    private var previewSize: (width: Int, height: Int) {
        let aspect = camera.height > 0 ? Double(camera.width) / Double(camera.height) : 16.0 / 9.0
        let h = 240
        return (max(16, Int(Double(h) * aspect)), h)
    }

    var body: some View {
        let size = previewSize
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black)
            if let image = CameraPreview.nsImage(for: camera, width: size.width, height: size.height, sequence: sequence) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onReceive(timer) { _ in sequence &+= 1 }
    }
}
