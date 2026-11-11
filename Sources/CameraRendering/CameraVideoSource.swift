import AVFoundation
import CoreVideo
import Foundation

/// Decodes the chosen video for the `video` source, frame by frame, with loop, trim, speed and
/// freeze — all on the extension's single serial render queue, so no locking is needed. Headless
/// (`AVAssetReader`, not `AVPlayer`): it reads the file the app wrote to the shared app group
/// (`<group>/<videoFile>`), advances one or more frames per render tick scaled by the speed, and
/// re-opens the reader at the trim start to loop.
final class CameraVideoSource {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: CVPixelBuffer?
    /// Fractional frames carried between ticks, so a speed below 1 advances every few ticks.
    private var accumulator = 0.0
    /// What the open reader was made for; re-opened when any of it changes or the file does.
    private var openedFile: String?
    private var openedStart = 0.0
    private var openedEnd = 0.0
    private var openedDate: Date?

    /// The frame to show this tick, or nil when there is no video. `config` carries the file name
    /// and the playback settings.
    func frame(for config: CameraExtensionConfig) -> CVPixelBuffer? {
        guard let file = config.videoFile else { reader = nil; output = nil; current = nil; return nil }
        ensureReader(file: file, start: config.videoStart, end: config.videoEnd)
        guard reader != nil else { return current }
        if config.videoPaused { return current }
        accumulator += max(0.0, min(8.0, config.videoRate))
        var advanced = 0
        while accumulator >= 1, advanced < 8 {
            accumulator -= 1
            advanced += 1
            if let buffer = nextFrame() {
                current = buffer
            } else if config.videoLoop {
                reopen()
                if let buffer = nextFrame() { current = buffer } else { break }
            } else {
                break // no loop: hold the last frame
            }
        }
        return current
    }

    private func nextFrame() -> CVPixelBuffer? {
        guard let output, reader?.status == .reading, let sample = output.copyNextSampleBuffer() else { return nil }
        defer { }
        return CMSampleBufferGetImageBuffer(sample)
    }

    private func ensureReader(file: String, start: Double, end: Double) {
        let url = CameraExtensionConfig.container?.appendingPathComponent(file)
        let date = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
        if reader != nil, openedFile == file, openedStart == start, openedEnd == end, openedDate == date { return }
        openedFile = file
        openedStart = start
        openedEnd = end
        openedDate = date
        open(url: url, start: start, end: end)
    }

    /// Re-opens the same reader (a loop) at the trim start.
    private func reopen() {
        open(url: CameraExtensionConfig.container?.appendingPathComponent(openedFile ?? ""),
             start: openedStart, end: openedEnd)
    }

    private func open(url: URL?, start: Double, end: Double) {
        reader = nil
        output = nil
        guard let url else { return }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return }
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        reader.timeRange = end > start
            ? CMTimeRange(start: startTime, duration: CMTime(seconds: end - start, preferredTimescale: 600))
            : CMTimeRange(start: startTime, duration: .positiveInfinity)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }
        self.reader = reader
        self.output = output
    }
}
