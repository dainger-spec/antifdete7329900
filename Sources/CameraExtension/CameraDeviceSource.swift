import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// The virtual camera device and its one output stream. Frames are generated here from the shared
/// config (`CameraExtensionConfig`) — a colour, the test pattern, an image or a video, with crop,
/// fit, mirror and the adjustments (`CameraFrameRenderer`) — and sent to the stream while a client
/// is reading. Like a built-in MacBook camera it offers several sizes (`sizes`), and the frames are
/// drawn at the one the client picked.
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CameraStreamSource!
    private let timerQueue = DispatchQueue(label: "io.lumenbrowser.camera.frames", qos: .userInteractive)
    // Read and changed on `timerQueue` only.
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var activeFormatIndex = 0
    private var timer: DispatchSourceTimer?
    private var sequence: UInt64 = 0
    private var config = CameraExtensionConfig.current()

    /// The sizes a built-in MacBook camera (FaceTime HD, 1080p) offers, the first the default: a
    /// page's constraints pick among them as they would on the real camera, and its capabilities
    /// read the same range (up to 1920×1080), not one fixed size.
    static let sizes: [(width: Int, height: Int)] = [(1280, 720), (1920, 1080), (640, 480)]
    /// At most 30 frames a second, as the built-in camera.
    static let maxFrameRate = 30
    /// One identity across restarts and updates, as a real device keeps: a site that remembers the
    /// camera it was given (its deviceId, which pages see only hashed per site) finds it again — a
    /// new one at every start (`UUID()`, until 0.1.8) was a camera no real Mac has.
    private static let deviceID = UUID(uuidString: "5A3F0C2E-8B1D-4E6A-9F47-2C81D6B0E953")!

    init(localizedName: String) {
        super.init()
        let deviceID = Self.deviceID
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID,
                                     legacyDeviceID: deviceID.uuidString, source: self)
        let formats = Self.sizes.map { size -> CMIOExtensionStreamFormat in
            var formatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                           width: Int32(size.width), height: Int32(size.height), extensions: nil,
                                           formatDescriptionOut: &formatDescription)
            guard let formatDescription else { fatalError("the camera format could not be made") }
            return CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                             maxFrameDuration: CMTime(value: 1, timescale: 1),
                                             minFrameDuration: CMTime(value: 1, timescale: Int32(Self.maxFrameRate)),
                                             validFrameDurations: nil)
        }
        streamSource = CameraStreamSource(localizedName: "\(localizedName) Stream", streamID: UUID(),
                                          streamFormats: formats, device: device)
        streamSource.deviceSource = self
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("the camera stream could not be added: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let properties = CMIOExtensionDeviceProperties(dictionary: [:])
        properties.model = "Lumen Camera"
        return properties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    /// The size a client picked (`CameraStreamSource.setStreamProperties`): the frames are drawn at
    /// it from the next one on.
    func useFormat(at index: Int) {
        guard Self.sizes.indices.contains(index) else { return }
        timerQueue.async { self.activeFormatIndex = index }
    }

    /// A client (a browser, an app) started reading the stream: read the latest config and begin
    /// producing frames.
    func startStreaming() {
        timerQueue.async {
            guard self.timer == nil else { return }
            self.config = CameraExtensionConfig.current()
            let fps = max(1, min(Self.maxFrameRate, self.config.frameRate))
            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    func stopStreaming() {
        timerQueue.async {
            self.timer?.cancel()
            self.timer = nil
            self.pixelBufferPool = nil
        }
    }

    /// One frame, on `timerQueue`: drawn at the picked size (a new pool when the size changed).
    private func emitFrame() {
        let size = Self.sizes[activeFormatIndex]
        if pixelBufferPool == nil || poolSize.width != size.width || poolSize.height != size.height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            pixelBufferPool = pool
            poolSize = size
        }
        guard let pool = pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        sequence &+= 1
        CameraFrameRenderer.render(into: pixelBuffer, config: config, sequence: sequence)

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                      formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let fps = max(1, min(Self.maxFrameRate, config.frameRate))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)),
                                        presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        streamSource.stream.send(sampleBuffer, discontinuity: [],
                                 hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
    }
}

/// The device's one output stream; it hands start/stop, and the size a client picks, to the device
/// source.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    weak var deviceSource: CameraDeviceSource?
    private let streamFormats: [CMIOExtensionStreamFormat]
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, streamFormats: [CMIOExtensionStreamFormat], device: CMIOExtensionDevice) {
        self.streamFormats = streamFormats
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(CameraDeviceSource.maxFrameRate))
        }
        return streamProperties
    }

    /// A client picks one of the sizes (AVFoundation's active format — WebKit sets it for a page's
    /// constraints): the frames are drawn at it from then on.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, streamFormats.indices.contains(index) {
            activeFormatIndex = index
            deviceSource?.useFormat(at: index)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { deviceSource?.startStreaming() }

    func stopStream() throws { deviceSource?.stopStreaming() }
}
