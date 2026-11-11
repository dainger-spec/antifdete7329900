import CameraRendering
import CoreGraphics
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// The virtual camera device: its output stream, which pages and apps read, and a sink stream, which
/// the app writes its frames into (`SystemCameraFeed`). The extension runs as macOS's camera user
/// (`_cmiodalassistants`), whose app group container is not the person's, so it cannot read the
/// settings and the media the app wrote (0.1.8, the owner's Mac: the test pattern instead of the
/// chosen video). The app draws the frames — the source with crop, fit, mirror and the adjustments —
/// and this passes them on, scaled to the size the client picked. With no frame from the app for a
/// second (Lumen not running, or no profile set to the camera) it draws its own fallback.
/// Like a built-in MacBook camera it offers several sizes (`sizes`).
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CameraStreamSource!
    private var sinkSource: CameraSinkStreamSource!
    private let timerQueue = DispatchQueue(label: "io.lumenbrowser.camera.frames", qos: .userInteractive)
    private let ciContext = CIContext()
    // Read and changed on `timerQueue` only.
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var activeFormatIndex = 0
    private var timer: DispatchSourceTimer?
    private var sequence: UInt64 = 0
    private var config = CameraExtensionConfig.current()
    /// The app writing into the sink stream, while it does.
    private var sinkClient: CMIOExtensionClient?
    /// A frame asked of the sink and not answered yet.
    private var consuming = false
    /// The app's latest frame and when it came (`DispatchTime` nanoseconds).
    private var latestFrame: CVPixelBuffer?
    private var latestFrameAt: UInt64 = 0

    /// The size the app draws at and sends to the sink.
    static let sinkSize = (width: 1280, height: 720)

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
        var sinkDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(Self.sinkSize.width), height: Int32(Self.sinkSize.height),
                                       extensions: nil, formatDescriptionOut: &sinkDescription)
        guard let sinkDescription else { fatalError("the sink format could not be made") }
        let sinkFormat = CMIOExtensionStreamFormat(formatDescription: sinkDescription,
                                                   maxFrameDuration: CMTime(value: 1, timescale: 1),
                                                   minFrameDuration: CMTime(value: 1, timescale: Int32(Self.maxFrameRate)),
                                                   validFrameDurations: nil)
        sinkSource = CameraSinkStreamSource(localizedName: "\(localizedName) Sink", streamID: UUID(),
                                            streamFormat: sinkFormat)
        sinkSource.deviceSource = self
        do {
            // The output stream first, then the sink: the app finds the sink as the second.
            try device.addStream(streamSource.stream)
            try device.addStream(sinkSource.stream)
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

    /// The app started writing into the sink stream.
    func startSink(client: CMIOExtensionClient) {
        timerQueue.async {
            self.sinkClient = client
            self.consuming = false
        }
    }

    func stopSink() {
        timerQueue.async {
            self.sinkClient = nil
            self.consuming = false
            self.latestFrame = nil
        }
    }

    /// Asks the sink for the app's next frame, one at a time and only while a client reads the
    /// output (the app draws nothing while its queue is full, so an unread camera costs nothing).
    private func requestSinkFrame() {
        guard let client = sinkClient, !consuming else { return }
        consuming = true
        sinkSource.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, _ in
            guard let self else { return }
            var image: CVPixelBuffer?
            if let sampleBuffer {
                image = CMSampleBufferGetImageBuffer(sampleBuffer)
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                          hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                self.sinkSource.stream.notifyScheduledOutputChanged(output)
            }
            let frame = image
            self.timerQueue.async {
                self.consuming = false
                if let frame {
                    self.latestFrame = frame
                    self.latestFrameAt = DispatchTime.now().uptimeNanoseconds
                }
            }
        }
    }

    /// The app's frame, scaled to fill `output` (centred; a 4:3 size crops the sides, as a camera
    /// would).
    private func draw(_ frame: CVPixelBuffer, into output: CVPixelBuffer) {
        let width = Double(CVPixelBufferGetWidth(output)), height = Double(CVPixelBufferGetHeight(output))
        let frameWidth = Double(CVPixelBufferGetWidth(frame)), frameHeight = Double(CVPixelBufferGetHeight(frame))
        guard frameWidth > 0, frameHeight > 0 else { return }
        let scale = max(width / frameWidth, height / frameHeight)
        let image = CIImage(cvPixelBuffer: frame)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (width - frameWidth * scale) / 2,
                                               y: (height - frameHeight * scale) / 2))
        ciContext.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func drawBlack(into output: CVPixelBuffer) {
        let bounds = CGRect(x: 0, y: 0, width: Double(CVPixelBufferGetWidth(output)), height: Double(CVPixelBufferGetHeight(output)))
        ciContext.render(CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds), to: output,
                         bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    /// One frame, on `timerQueue`: drawn at the picked size (a new pool when the size changed).
    private func emitFrame() {
        requestSinkFrame()
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
        let fresh = DispatchTime.now().uptimeNanoseconds &- latestFrameAt < 1_000_000_000
        if let frame = latestFrame, sinkClient != nil || fresh {
            // The app's frame — the last one while the next is on its way (a page that just turned
            // the camera on gets the last picture, never the fallback pattern for a moment).
            draw(frame, into: pixelBuffer)
        } else if sinkClient != nil {
            // The app is there but has not sent a frame yet: black, as a camera that is starting.
            drawBlack(into: pixelBuffer)
        } else {
            CameraFrameRenderer.render(into: pixelBuffer, config: config, sequence: sequence)
        }

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

/// The sink stream the app writes its frames into (`SystemCameraFeed`); consumed by the device
/// source while its output is read.
final class CameraSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    weak var deviceSource: CameraDeviceSource?
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat) {
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { streamProperties.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(CameraDeviceSource.maxFrameRate))
        }
        // One frame queued at a time: what is shown is never older than a frame behind the app.
        if properties.contains(.streamSinkBufferQueueSize) { streamProperties.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { streamProperties.sinkBuffersRequiredForStartup = 1 }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        if let client { deviceSource?.startSink(client: client) }
    }

    func stopStream() throws { deviceSource?.stopSink() }
}
