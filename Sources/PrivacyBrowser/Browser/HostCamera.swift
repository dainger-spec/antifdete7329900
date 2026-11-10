import AVFoundation
import Foundation

/// This Mac's own built-in camera, read for the "Match this Mac" action so a substituted camera can
/// report exactly what the real one does — on a modern Mac that is a model name like
/// "Камера (MacBook Air)" at 1920×1080, not the old "FaceTime HD Camera" at 1280×720. Only the
/// device's name and its formats are read (enumeration), which needs no camera permission and opens
/// no capture session; nothing is recorded.
enum HostCamera {
    struct Builtin {
        var name: String
        var width: Int
        var height: Int
    }

    /// The built-in camera's name and its largest format, or nil when there is no built-in camera.
    static func builtin() -> Builtin? {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                         mediaType: .video, position: .unspecified)
        // The built-in one if present, else the first camera the Mac has.
        let device = discovery.devices.first { $0.deviceType == .builtInWideAngleCamera } ?? discovery.devices.first
        guard let device else { return nil }
        var best = (width: 0, height: 0)
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dimensions.width), h = Int(dimensions.height)
            if w * h > best.width * best.height { best = (w, h) }
        }
        guard best.width > 0, best.height > 0 else {
            return Builtin(name: device.localizedName, width: 1280, height: 720)
        }
        return Builtin(name: device.localizedName, width: best.width, height: best.height)
    }
}
