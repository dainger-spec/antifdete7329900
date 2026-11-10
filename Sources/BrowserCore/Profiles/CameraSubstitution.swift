import Foundation

/// Per-profile camera (and, with it, microphone) substitution: what a page of the profile is
/// handed when it calls `navigator.mediaDevices.getUserMedia({video: …})`, instead of this Mac's
/// real camera.
///
/// APPROXIMATION, like the rest of `PrivacyScripts`: this is a JavaScript shim over the media
/// capture APIs, not a system capture device. It runs wherever the profile's scripts run — a
/// window of Safari's as well as the app's own (`ProfileNetworkGuard` injects them into every web
/// view Safari builds) — but only in a secure context, where `navigator.mediaDevices` exists at
/// all (https, or a loopback origin). The engine underneath is this Mac's WebKit: the stream is a
/// real `canvas.captureStream()` track, and the page reads real frames from it, but a test that
/// correlates the frames with a live sensor (focus hunting, exposure changes, the user moving) can
/// still tell a drawn frame from a camera's. The one path that is indistinguishable at the
/// JavaScript layer is a system virtual camera (a CMIO Camera Extension), which feeds the OS
/// capture pipeline so WebKit builds the frames its own way; that is a separate, signed system
/// extension (docs/CAMERA.md). The frame pipeline here — source, crop, filters, playback — is the
/// same pixels such an extension would push, so it is built once.
///
/// `mode == .off` changes nothing — the page reaches the real camera through WebKit's own capture
/// path (the window still asks the person for the camera, as before). The field is written only
/// when it is not `.off`, so a profile that never used it is stored as before.
public struct CameraSubstitution: Codable, Equatable, Sendable {
    /// What a page's request for the camera is answered with.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// The real camera, through WebKit. Default: nothing is substituted.
        case off
        /// No camera exists: `getUserMedia({video})` rejects with `NotFoundError` and
        /// `enumerateDevices` lists no `videoinput`, as on a Mac with every camera unplugged.
        case block
        /// A synthetic video stream from the chosen `source`.
        case substitute
    }

    /// What the synthetic stream shows.
    public enum Source: String, Codable, CaseIterable, Sendable {
        /// A solid colour (`colorHex`).
        case color
        /// A moving test pattern (colour bars with a sweeping bar and a running clock), so the
        /// frames change even without a chosen image.
        case bars
        /// A still image the person chose (`imageData`), drawn each frame with faint grain.
        case image
        /// A video the person chose (`videoData`), looped.
        case video
    }

    /// How the source is placed in the frame when its shape is not the frame's.
    public enum Fit: String, Codable, CaseIterable, Sendable {
        /// Fill the frame, cropping the overflow (what a webcam preview does). Default.
        case cover
        /// Fit the whole source, letterboxing the rest with `colorHex`.
        case contain
        /// Stretch to the frame, ignoring the shape.
        case stretch
    }

    /// What `getSettings().facingMode` and the track report; a built-in Mac camera is `user`.
    public enum Facing: String, Codable, CaseIterable, Sendable {
        case user
        case environment
        /// Report none (an external webcam reports no facing mode).
        case unset
    }

    /// Whether the microphone is substituted along with the camera, when a page asks for audio.
    public enum Audio: String, Codable, CaseIterable, Sendable {
        /// Pass the real microphone through (WebKit asks the person, as before). Default.
        case real
        /// A real but silent audio track (WebAudio): the page gets audio that is quiet.
        case silent
        /// No audio track even when the page asks for one.
        case off
    }

    /// A rectangle of the source taken into the frame (normalised 0…1 of the source's own size),
    /// before `fit` places it. Disabled: the whole source.
    public struct Crop: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(enabled: Bool = false, x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
            self.enabled = enabled; self.x = x; self.y = y; self.width = width; self.height = height
        }

        public static let none = Crop()

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let d = Crop()
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
            x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? d.x
            y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? d.y
            width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? d.width
            height = (try? c.decodeIfPresent(Double.self, forKey: .height)) ?? d.height
        }
        private enum Key: String, CodingKey { case enabled, x, y, width, height }
    }

    /// A camera look drawn over the source: identity (all 1/0/false) leaves it untouched. Applied
    /// with the canvas filter the engine already has (brightness/contrast/saturate/blur/hue-rotate/
    /// grayscale), so it is one pass, not a pixel loop.
    public struct Filters: Codable, Equatable, Sendable {
        /// 1 = unchanged; 0…4.
        public var brightness: Double
        public var contrast: Double
        public var saturation: Double
        /// Blur radius, in pixels (0…40).
        public var blur: Double
        /// Hue rotation, in degrees (0…360).
        public var hueRotate: Double
        /// Sepia amount, 0…1.
        public var sepia: Double
        /// Colour inversion, 0…1.
        public var invert: Double
        /// Overall opacity, 0…1 (1 = opaque).
        public var opacity: Double
        public var grayscale: Bool

        public init(brightness: Double = 1, contrast: Double = 1, saturation: Double = 1,
                    blur: Double = 0, hueRotate: Double = 0, sepia: Double = 0, invert: Double = 0,
                    opacity: Double = 1, grayscale: Bool = false) {
            self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
            self.blur = blur; self.hueRotate = hueRotate; self.sepia = sepia; self.invert = invert
            self.opacity = opacity; self.grayscale = grayscale
        }

        public static let none = Filters()

        public var isIdentity: Bool {
            brightness == 1 && contrast == 1 && saturation == 1 && blur == 0 && hueRotate == 0
                && sepia == 0 && invert == 0 && opacity == 1 && !grayscale
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let d = Filters()
            brightness = (try? c.decodeIfPresent(Double.self, forKey: .brightness)) ?? d.brightness
            contrast = (try? c.decodeIfPresent(Double.self, forKey: .contrast)) ?? d.contrast
            saturation = (try? c.decodeIfPresent(Double.self, forKey: .saturation)) ?? d.saturation
            blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? d.blur
            hueRotate = (try? c.decodeIfPresent(Double.self, forKey: .hueRotate)) ?? d.hueRotate
            sepia = (try? c.decodeIfPresent(Double.self, forKey: .sepia)) ?? d.sepia
            invert = (try? c.decodeIfPresent(Double.self, forKey: .invert)) ?? d.invert
            opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? d.opacity
            grayscale = (try? c.decodeIfPresent(Bool.self, forKey: .grayscale)) ?? d.grayscale
        }
        private enum Key: String, CodingKey {
            case brightness, contrast, saturation, blur, hueRotate, sepia, invert, opacity, grayscale
        }
    }

    /// Playback of the `.video` source: loop, freeze the picture, speed, and the part played.
    public struct Playback: Codable, Equatable, Sendable {
        public var loop: Bool
        /// Freeze the picture (the sensor grain goes on, so the stream keeps emitting frames).
        public var paused: Bool
        public var rate: Double
        /// Where the clip starts, in seconds.
        public var startOffset: Double
        /// Where the clip ends, in seconds; 0 = to the end.
        public var endOffset: Double

        public init(loop: Bool = true, paused: Bool = false, rate: Double = 1,
                    startOffset: Double = 0, endOffset: Double = 0) {
            self.loop = loop; self.paused = paused; self.rate = rate
            self.startOffset = startOffset; self.endOffset = endOffset
        }

        public static let standard = Playback()

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let d = Playback()
            loop = (try? c.decodeIfPresent(Bool.self, forKey: .loop)) ?? d.loop
            paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? d.paused
            rate = (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? d.rate
            startOffset = (try? c.decodeIfPresent(Double.self, forKey: .startOffset)) ?? d.startOffset
            endOffset = (try? c.decodeIfPresent(Double.self, forKey: .endOffset)) ?? d.endOffset
        }
        private enum Key: String, CodingKey { case loop, paused, rate, startOffset, endOffset }
    }

    public var mode: Mode
    public var source: Source
    /// The frame's pixel size the track reports and draws at.
    public var width: Int
    public var height: Int
    /// Frames per second the track reports and the stream is captured at.
    public var frameRate: Int
    public var facing: Facing
    public var fit: Fit
    /// Mirror the source left-to-right, as a front camera's self-view is mirrored.
    public var mirror: Bool
    /// What `enumerateDevices` labels the camera (after the page is granted it); empty: a default.
    public var deviceLabel: String
    /// "#RRGGBB" for the `.color` source and the letterboxing of `.contain`.
    public var colorHex: String
    public var audio: Audio
    /// Substitute `getDisplayMedia` (screen sharing) with the same stream, too.
    public var alsoScreenShare: Bool
    /// A rectangle of the source taken into the frame; the whole source by default.
    public var crop: Crop
    /// A camera look over the source; none by default.
    public var filters: Filters
    /// Playback of the `.video` source.
    public var playback: Playback
    /// A random secret kept with the profile, from which the shim derives a stable, per-origin
    /// `deviceId`/`groupId` (a real browser salts them per origin). Empty until substitution is
    /// first turned on, when the editor fills it.
    public var deviceSecret: String
    /// The still image for `.image` (its bytes); nil when none was chosen.
    public var imageData: Data?
    /// The image's MIME type, e.g. "image/jpeg".
    public var imageType: String?
    /// The looping video for `.video` (its bytes); nil when none was chosen.
    public var videoData: Data?
    /// The video's MIME type, e.g. "video/mp4".
    public var videoType: String?

    public static let minDimension = 16
    public static let maxDimension = 3840
    public static let minFrameRate = 1
    public static let maxFrameRate = 60
    public static let maxDeviceLabelLength = 120
    /// The embedded media travels with the profile (it is kept and synced with the settings), so
    /// it is capped: a still photo and a short loop, not a film.
    public static let maxImageBytes = 4 * 1024 * 1024
    public static let maxVideoBytes = 12 * 1024 * 1024

    public init(mode: Mode = .off,
                source: Source = .bars,
                width: Int = 1280,
                height: Int = 720,
                frameRate: Int = 30,
                facing: Facing = .user,
                fit: Fit = .cover,
                mirror: Bool = false,
                deviceLabel: String = "",
                colorHex: String = "#1E2130",
                audio: Audio = .real,
                alsoScreenShare: Bool = false,
                crop: Crop = .none,
                filters: Filters = .none,
                playback: Playback = .standard,
                deviceSecret: String = "",
                imageData: Data? = nil,
                imageType: String? = nil,
                videoData: Data? = nil,
                videoType: String? = nil) {
        self.mode = mode
        self.source = source
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.facing = facing
        self.fit = fit
        self.mirror = mirror
        self.deviceLabel = String(deviceLabel.prefix(Self.maxDeviceLabelLength))
        self.colorHex = colorHex
        self.audio = audio
        self.alsoScreenShare = alsoScreenShare
        self.crop = crop
        self.filters = filters
        self.playback = playback
        self.deviceSecret = deviceSecret
        self.imageData = imageData
        self.imageType = imageType
        self.videoData = videoData
        self.videoType = videoType
    }

    /// Nothing is substituted.
    public static let off = CameraSubstitution()

    /// The feature is on for this profile.
    public var isActive: Bool { mode != .off }

    /// A fresh random secret for `deviceSecret` (32 hex characters).
    public static func newDeviceSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A "#RRGGBB" colour, upper- or lower-case.
    public static func isColorHex(_ value: String) -> Bool {
        guard value.hasPrefix("#"), value.count == 7 else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    public func validate() throws {
        guard mode != .off else { return }
        guard (Self.minDimension...Self.maxDimension).contains(width),
              (Self.minDimension...Self.maxDimension).contains(height) else {
            throw CoreError.invalidConfiguration("camera resolution must be \(Self.minDimension)–\(Self.maxDimension) pixels each side")
        }
        guard (Self.minFrameRate...Self.maxFrameRate).contains(frameRate) else {
            throw CoreError.invalidConfiguration("camera frame rate must be \(Self.minFrameRate)–\(Self.maxFrameRate) per second")
        }
        guard Self.isColorHex(colorHex) else {
            throw CoreError.invalidConfiguration("camera colour must be written like #1E2130")
        }
        if crop.enabled {
            let parts = [crop.x, crop.y, crop.width, crop.height]
            guard parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }), crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= 1.0001, crop.y + crop.height <= 1.0001 else {
                throw CoreError.invalidConfiguration("the camera crop must be inside the source")
            }
        }
        let f = filters
        guard [f.brightness, f.contrast, f.saturation].allSatisfy({ $0.isFinite && (0...4).contains($0) }),
              f.blur.isFinite, (0...40).contains(f.blur), f.hueRotate.isFinite, (0...360).contains(f.hueRotate),
              [f.sepia, f.invert, f.opacity].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw CoreError.invalidConfiguration("a camera filter is out of range")
        }
        let p = playback
        guard p.rate.isFinite, (0.1...8).contains(p.rate), p.startOffset.isFinite, p.startOffset >= 0,
              p.endOffset.isFinite, p.endOffset >= 0, p.endOffset == 0 || p.endOffset > p.startOffset else {
            throw CoreError.invalidConfiguration("the camera playback is out of range")
        }
        if let imageData, imageData.count > Self.maxImageBytes {
            throw CoreError.invalidConfiguration("the camera image is larger than \(Self.maxImageBytes / (1024 * 1024)) MB")
        }
        if let videoData, videoData.count > Self.maxVideoBytes {
            throw CoreError.invalidConfiguration("the camera video is larger than \(Self.maxVideoBytes / (1024 * 1024)) MB")
        }
        if mode == .substitute, source == .image, imageData == nil {
            throw CoreError.invalidConfiguration("the camera is set to an image but none was chosen")
        }
        if mode == .substitute, source == .video, videoData == nil {
            throw CoreError.invalidConfiguration("the camera is set to a video but none was chosen")
        }
    }

    /// A data: URL for the chosen image, for the shim to draw; nil when there is none.
    public var imageDataURL: String? { Self.dataURL(imageData, imageType ?? "image/jpeg") }

    /// A data: URL for the chosen video; nil when there is none.
    public var videoDataURL: String? { Self.dataURL(videoData, videoType ?? "video/mp4") }

    private static func dataURL(_ data: Data?, _ type: String) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    // Tolerant decoding (as `ProfileConfiguration`): a field a later build added and this one does
    // not know falls back to its default, so a stored substitution keeps decoding; a nested object
    // that is absent is its default. Written compactly: the media and anything not at its default.
    private enum CodingKeys: String, CodingKey {
        case mode, source, width, height, frameRate, facing, fit, mirror, deviceLabel, colorHex,
             audio, alsoScreenShare, crop, filters, playback, deviceSecret, imageData, imageType,
             videoData, videoType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraSubstitution()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? d.source
        width = (try? c.decodeIfPresent(Int.self, forKey: .width)) ?? d.width
        height = (try? c.decodeIfPresent(Int.self, forKey: .height)) ?? d.height
        frameRate = (try? c.decodeIfPresent(Int.self, forKey: .frameRate)) ?? d.frameRate
        facing = (try? c.decodeIfPresent(Facing.self, forKey: .facing)) ?? d.facing
        fit = (try? c.decodeIfPresent(Fit.self, forKey: .fit)) ?? d.fit
        mirror = (try? c.decodeIfPresent(Bool.self, forKey: .mirror)) ?? d.mirror
        deviceLabel = String(((try? c.decodeIfPresent(String.self, forKey: .deviceLabel)) ?? "").prefix(Self.maxDeviceLabelLength))
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? d.colorHex
        audio = (try? c.decodeIfPresent(Audio.self, forKey: .audio)) ?? d.audio
        alsoScreenShare = (try? c.decodeIfPresent(Bool.self, forKey: .alsoScreenShare)) ?? d.alsoScreenShare
        crop = (try? c.decodeIfPresent(Crop.self, forKey: .crop)) ?? d.crop
        filters = (try? c.decodeIfPresent(Filters.self, forKey: .filters)) ?? d.filters
        playback = (try? c.decodeIfPresent(Playback.self, forKey: .playback)) ?? d.playback
        deviceSecret = (try? c.decodeIfPresent(String.self, forKey: .deviceSecret)) ?? d.deviceSecret
        imageData = (try? c.decodeIfPresent(Data.self, forKey: .imageData)) ?? nil
        imageType = (try? c.decodeIfPresent(String.self, forKey: .imageType)) ?? nil
        videoData = (try? c.decodeIfPresent(Data.self, forKey: .videoData)) ?? nil
        videoType = (try? c.decodeIfPresent(String.self, forKey: .videoType)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let d = CameraSubstitution()
        try c.encode(mode, forKey: .mode)
        try c.encode(source, forKey: .source)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(frameRate, forKey: .frameRate)
        if facing != d.facing { try c.encode(facing, forKey: .facing) }
        if fit != d.fit { try c.encode(fit, forKey: .fit) }
        if mirror { try c.encode(mirror, forKey: .mirror) }
        if !deviceLabel.isEmpty { try c.encode(deviceLabel, forKey: .deviceLabel) }
        if colorHex != d.colorHex { try c.encode(colorHex, forKey: .colorHex) }
        if audio != d.audio { try c.encode(audio, forKey: .audio) }
        if alsoScreenShare { try c.encode(alsoScreenShare, forKey: .alsoScreenShare) }
        if crop != d.crop { try c.encode(crop, forKey: .crop) }
        if filters != d.filters { try c.encode(filters, forKey: .filters) }
        if playback != d.playback { try c.encode(playback, forKey: .playback) }
        if !deviceSecret.isEmpty { try c.encode(deviceSecret, forKey: .deviceSecret) }
        try c.encodeIfPresent(imageData, forKey: .imageData)
        try c.encodeIfPresent(imageType, forKey: .imageType)
        try c.encodeIfPresent(videoData, forKey: .videoData)
        try c.encodeIfPresent(videoType, forKey: .videoType)
    }
}
