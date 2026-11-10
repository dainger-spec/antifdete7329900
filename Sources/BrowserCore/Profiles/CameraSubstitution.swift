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
/// still tell a drawn frame from a camera's. What is replaced is replaced the way the engine
/// defines it (native-looking methods, per-origin-salted device ids, sensor-like grain so frames
/// are not frozen); see `PrivacyScripts.patchCamera`.
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
}
