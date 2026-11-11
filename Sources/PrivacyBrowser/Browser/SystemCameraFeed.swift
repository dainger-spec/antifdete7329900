import AVFoundation
import BrowserCore
import CameraRendering
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

/// Feeds the system camera its frames (docs/CAMERA.md). The camera extension runs as macOS's own
/// camera user (`_cmiodalassistants`), whose app group container is not the person's: the settings
/// and the media the app writes there (`SystemCamera.writeRenderConfig`) never reach it, and it drew
/// its fallback test pattern instead of the chosen video (0.1.8, the owner's Mac). So the app draws
/// the frames itself — with the extension's own renderer (`CameraRendering`), from the files it
/// wrote — and writes them into the device's sink stream, the way Apple's camera extensions take
/// frames from their app. The extension asks for one only while a page or an app reads the camera;
/// while nobody does, the sink's one-frame queue stays full and nothing is drawn here.
///
/// It runs while a profile set to the system camera runs (`use`, `keep(only:)`), in the app's own
/// process only — a profile's own process cannot read the app group either.
final class SystemCameraFeed {
    static let shared = SystemCameraFeed()

    /// What the app draws and sends; the extension scales it to the size its client picked.
    static let width = 1280
    static let height = 720
    static let frameRate = 30

    private let queue = DispatchQueue(label: "io.lumenbrowser.camera.feed", qos: .userInteractive)
    private let log = Logger(subsystem: "PrivacyBrowser", category: "SystemCameraFeed")
    // Read and changed on `queue` only.
    private var users: Set<UUID> = []
    private var timer: DispatchSourceTimer?
    private var config = CameraExtensionConfig.current()
    private var deviceID = CMIOObjectID(0)
    private var sinkStreamID = CMIOStreamID(0)
    private var sinkQueue: CMSimpleQueue?
    private var pool: CVPixelBufferPool?
    private var sequence: UInt64 = 0
    private var lastAttempt = Date.distantPast
    private var accessAsked = false

    /// A profile set to the system camera started (its settings were just written): the frames
    /// follow them from now on.
    func use(for profileID: UUID) {
        queue.async {
            self.users.insert(profileID)
            self.config = CameraExtensionConfig.current()
            self.askAccessOnce()
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(Self.frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// The profiles running now: feeding stops when none of those set to the camera is among them.
    func keep(only running: Set<UUID>) {
        queue.async {
            guard !self.users.isEmpty else { return }
            self.users.formIntersection(running)
            guard self.users.isEmpty else { return }
            self.timer?.cancel()
            self.timer = nil
            self.disconnect()
        }
    }

    /// The device came back (an install, a replacement, a restart of the extension): the old sink is
    /// gone, so the next frame looks for it again.
    func reconnect() {
        queue.async { self.disconnect() }
    }

    /// The sink is a stream of a camera device: macOS may ask the person once whether Lumen may use
    /// the camera before it lets the app write into it.
    private func askAccessOnce() {
        guard !accessAsked else { return }
        accessAsked = true
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                SystemCameraFeed.shared.accessAnswered(granted)
            }
        }
    }

    private func accessAnswered(_ granted: Bool) {
        queue.async {
            self.log.notice("camera access for the feed: \(granted ? "yes" : "no", privacy: .private)")
            self.lastAttempt = .distantPast
        }
    }

    private func tick() {
        guard let sinkQueue = connectedQueue(), let pool else { return }
        // Full: the extension has not taken the last one (nobody reads the camera now).
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        sequence &+= 1
        CameraFrameRenderer.render(into: pixelBuffer, config: config, sequence: sequence)
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                      formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(Self.frameRate)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        // The queue holds the buffer retained; the extension's side releases it.
        let element = Unmanaged.passRetained(sampleBuffer)
        if CMSimpleQueueEnqueue(sinkQueue, element: element.toOpaque()) != noErr {
            element.release()
            log.error("the camera's sink did not take a frame: looked for again")
            disconnect()
        }
    }

    /// The sink's queue, connected once the device is there (looked for at most once a second).
    private func connectedQueue() -> CMSimpleQueue? {
        if let sinkQueue { return sinkQueue }
        guard Date().timeIntervalSince(lastAttempt) >= 1 else { return nil }
        lastAttempt = Date()
        guard let device = Self.device(), let sink = Self.sinkStream(of: device) else { return nil }
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let copied = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
        guard copied == noErr, let queue = unmanagedQueue?.takeRetainedValue() else {
            log.error("the camera's sink queue could not be had: \(Int(copied), privacy: .public)")
            return nil
        }
        let started = CMIODeviceStartStream(device, sink)
        guard started == noErr else {
            log.error("the camera's sink did not start: \(Int(started), privacy: .public)")
            return nil
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
            // Shared memory: the frame crosses into the extension's process.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
        deviceID = device
        sinkStreamID = sink
        sinkQueue = queue
        pool = newPool
        log.notice("feeding the system camera")
        return queue
    }

    private func disconnect() {
        if sinkQueue != nil { CMIODeviceStopStream(deviceID, sinkStreamID) }
        sinkQueue = nil
        pool = nil
        lastAttempt = .distantPast
    }

    // MARK: Finding the device and its sink (CoreMediaIO)

    /// The virtual camera's CoreMediaIO device: found by name in AVFoundation's list, then by its
    /// unique ID among CoreMediaIO's devices.
    private static func device() -> CMIOObjectID? {
        let name = CameraSubstitution.systemDeviceName
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let uid = discovery.devices.first(where: { $0.localizedName == name || $0.modelID == name })?.uniqueID else {
            return nil
        }
        let devices = objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject),
                                selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        return devices.first { self.uid(of: $0) == uid }
    }

    /// The device's sink: the second of its streams (the extension adds the output stream first).
    private static func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        let streams = objectIDs(of: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        return streams.count >= 2 ? streams[1] : nil
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objectIDs(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var address = Self.address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func uid(of device: CMIOObjectID) -> String? {
        var address = Self.address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
