import CoreImage
import Foundation

/// The adjustments the extension draws over the frame (the same set the in-page shim applies as one
/// canvas-filter pass): brightness, contrast, saturation, blur, hue, sepia, invert, opacity and
/// black-and-white. Read from the `filters` object of `camera.json`.
struct CameraFiltersConfig: Equatable {
    var brightness = 1.0
    var contrast = 1.0
    var saturation = 1.0
    var blur = 0.0
    var hueRotate = 0.0
    var sepia = 0.0
    var invert = 0.0
    var opacity = 1.0
    var grayscale = false

    static let none = CameraFiltersConfig()

    var isIdentity: Bool {
        brightness == 1 && contrast == 1 && saturation == 1 && blur == 0 && hueRotate == 0
            && sepia == 0 && invert == 0 && opacity == 1 && !grayscale
    }

    init() {}

    init?(_ object: [String: Any]?) {
        guard let object else { return nil }
        func d(_ key: String, _ fallback: Double) -> Double { (object[key] as? NSNumber)?.doubleValue ?? fallback }
        brightness = d("brightness", 1)
        contrast = d("contrast", 1)
        saturation = d("saturation", 1)
        blur = d("blur", 0)
        hueRotate = d("hueRotate", 0)
        sepia = d("sepia", 0)
        invert = d("invert", 0)
        opacity = d("opacity", 1)
        grayscale = (object["grayscale"] as? NSNumber)?.boolValue ?? false
    }
}

/// The CoreImage chain that matches the shim's CSS filters, in the same order. Each CSS filter maps
/// to a CoreImage one; `brightness`, `invert` (partial) and `opacity` are colour matrices
/// (`x·(1−2a)+a` is CSS `invert(a)` exactly), `grayscale` folds into the saturation.
enum CameraFilterChain {
    static let context = CIContext()

    static func apply(_ filters: CameraFiltersConfig, to source: CIImage) -> CIImage {
        let extent = source.extent
        var image = source
        if filters.brightness != 1 { image = multiplyRGB(image, filters.brightness) }
        let saturation = filters.grayscale ? 0 : filters.saturation
        if filters.contrast != 1 || saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": filters.contrast, "inputSaturation": saturation, "inputBrightness": 0.0])
        }
        if filters.blur > 0 {
            image = image.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": filters.blur]).cropped(to: extent)
        }
        if filters.hueRotate != 0 {
            image = image.applyingFilter("CIHueAdjust", parameters: ["inputAngle": filters.hueRotate * .pi / 180.0])
        }
        if filters.sepia > 0 {
            image = image.applyingFilter("CISepiaTone", parameters: ["inputIntensity": filters.sepia])
        }
        if filters.invert > 0 {
            let scale = 1 - 2 * filters.invert, bias = filters.invert
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        if filters.opacity != 1 { image = multiplyRGB(image, filters.opacity) }
        return image.cropped(to: extent)
    }

    private static func multiplyRGB(_ image: CIImage, _ factor: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
}
