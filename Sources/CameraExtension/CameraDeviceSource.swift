import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// The virtual camera device and its one output stream. Frames are generated here from the shared
/// config (`CameraExtensionConfig`), at a fixed published format, and sent to the stream while a
/// client is reading. This first stage renders a solid colour or a moving test pattern; the rich
/// sources (an image, a video, filters, crop — the same pixels the in-page shim draws) are the
/// next stage (docs/CAMERA.md).
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CameraStreamSource!
    private var pixelBufferPool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "io.lumenbrowser.camera.frames", qos: .userInteractive)
    private var sequence: UInt64 = 0
    private var config = CameraExtensionConfig.current()

    // The device publishes one fixed format; the config's size scales into it when it differs.
    private let width = 1280
    private let height = 720

    init(localizedName: String) {
        super.init()
        let deviceID = UUID()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID,
                                     legacyDeviceID: deviceID.uuidString, source: self)
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(width), height: Int32(height), extensions: nil,
                                       formatDescriptionOut: &formatDescription)
        guard let formatDescription else { fatalError("the camera format could not be made") }
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                                     maxFrameDuration: CMTime(value: 1, timescale: 1),
                                                     minFrameDuration: CMTime(value: 1, timescale: 60),
                                                     validFrameDurations: nil)
        streamSource = CameraStreamSource(localizedName: "\(localizedName) Stream", streamID: UUID(),
                                          streamFormat: streamFormat, device: device)
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

    /// A client (a browser, an app) started reading the stream: read the latest config and begin
    /// producing frames.
    func startStreaming() {
        guard pixelBufferPool == nil else { return }
        config = CameraExtensionConfig.current()
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        pixelBufferPool = pool
        let fps = max(1, min(60, config.frameRate))
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        self.timer = timer
        timer.resume()
    }

    func stopStreaming() {
        timer?.cancel()
        timer = nil
        pixelBufferPool = nil
    }

    private func emitFrame() {
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(max(1, config.frameRate))),
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

/// The device's one output stream; it hands start/stop to the device source.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    weak var deviceSource: CameraDeviceSource?
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let properties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.activeFormatIndex == nil { properties.activeFormatIndex = 0 }
        properties.frameDuration = CMTime(value: 1, timescale: 30)
        return properties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { deviceSource?.startStreaming() }

    func stopStream() throws { deviceSource?.stopStreaming() }
}
