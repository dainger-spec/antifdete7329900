import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches Apple's restore image — the macOS a virtual machine is installed from, some twenty-five
/// gigabytes — from Apple's own servers into the machines' library, over several connections at
/// once.
///
/// One connection was all a download had (the owners' users, 14 November: the setup's download
/// from Apple was slow). A network that gives each connection only so much — far from Apple's
/// servers, through a VPN, under a provider's shaping — gives several connections several times
/// that. So the file is fetched in chunks (`VMChunkMap`), each a `Range` request of its own, up to
/// `connections` of them at a time, each on a URLSession of its own: one session would carry them
/// all on one HTTP/2 connection, which is no faster than one request.
///
/// What was fetched is kept, chunk by chunk: a download that was paused, cut off, or met the app's
/// quit goes on with the chunks that are not here yet (`VMDownloadState.chunks`). Every chunk is
/// asked for under `If-Range` with the file's validator: a file Apple replaced meanwhile comes back
/// whole (200) instead of in parts, and the download starts over rather than glue two files
/// together. A partial file of one stream (a download from before) counts the chunks it holds
/// whole. A server that has no ranges gets one stream for the whole file.
///
/// The file is checked by what installs it: Apple's installer verifies the image and has Apple
/// sign the installation for this machine; a file that is not Apple's does not install.
public final class VMImageFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Progress: Equatable, Sendable {
        public var have: Int64
        public var total: Int64?
        /// Bytes a second over the last few seconds; nil until known.
        public var speed: Double?
        /// Connections at work now.
        public var connections: Int

        public init(have: Int64, total: Int64?, speed: Double?, connections: Int = 0) {
            self.have = have
            self.total = total
            self.speed = speed
            self.connections = connections
        }
    }

    public enum Failure: Error, Equatable {
        /// The server said no, with this status.
        case refused(Int)
        /// The file did not come whole.
        case incomplete
        /// The image's address is not one to fetch (only https is).
        case notFetchable
        /// The file changed under the download again and again.
        case keepsChanging
    }

    public static let defaultConnections = 6
    public static let defaultChunkSize: Int64 = 32 << 20
    /// Attempts in a row that brought nothing, per connection: a network that keeps failing is
    /// given up on, with what is on disk kept for the person's next try.
    public static let maximumEmptyAttempts = 6
    static let maximumRestarts = 2

    private let library: VMLibrary
    private let image: VMRestoreImage
    private let connections: Int
    private let chunkSize: Int64
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let onProgress: @Sendable (Progress) -> Void
    private let onFinish: @Sendable (Result<Void, Error>) -> Void

    /// Everything below is touched on `queue` only: the sessions' delegate queue, one at a time.
    private let queue: OperationQueue

    private struct Work {
        let task: URLSessionDataTask
        let slot: Int
        /// The chunk; nil for the first request, which asks for chunk 0 and learns the file.
        var chunk: Int?
        /// Where the next byte goes.
        var next: Int64
        /// The last byte this answer may carry (inclusive); nil for one stream of unknown length.
        var last: Int64?
        var received: Int64 = 0
        var accepted = false
        var failed = false
    }

    /// The tests' local server speaks plain http on loopback; nothing else is fetched but https.
    var acceptsLoopbackHTTP = false

    private var state: VMDownloadState
    private var map: VMChunkMap?
    /// The server has no ranges: one stream, the whole file.
    private var single = false
    private var handle: FileHandle?
    private var sessions: [Int: URLSession] = [:]
    private var works: [ObjectIdentifier: Work] = [:]
    private var inFlight: Set<Int> = []
    /// Bytes of chunks under way, not counted done yet.
    private var inFlightBytes: Int64 = 0
    private var emptyFailures = 0
    private var restarts = 0
    private var waiting = false
    private var cancelled = false
    private var finished = false
    private var lastSaved = Date.distantPast
    private var lastReport = Date.distantPast
    private var speedMark: (at: Date, have: Int64)?
    private var speed: Double?

    /// `configuration`: each connection's session settings; the system's own by default (its
    /// proxy and VPN, as any app's download has them), no cookies, no cache.
    public init(library: VMLibrary, image: VMRestoreImage, connections: Int = VMImageFetch.defaultConnections,
                chunkSize: Int64 = VMImageFetch.defaultChunkSize,
                configuration: (@Sendable () -> URLSessionConfiguration)? = nil,
                onProgress: @escaping @Sendable (Progress) -> Void,
                onFinish: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.library = library
        self.image = image
        self.connections = max(1, connections)
        self.chunkSize = max(64 << 10, chunkSize)
        self.makeConfiguration = configuration ?? { VMImageFetch.standardConfiguration() }
        self.onProgress = onProgress
        self.onFinish = onFinish
        state = VMDownloadState(image: image)
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "io.lumenbrowser.vm.download"
        super.init()
    }

    static func standardConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        #if canImport(Darwin)
        // Offline for a while (a Mac between networks): waited for, not counted as a failure.
        configuration.waitsForConnectivity = true
        #endif
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 14 * 24 * 3600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    public func start() {
        queue.addOperation { self.begin() }
    }

    /// Stops the download; what was fetched stays for the next start.
    public func pause() {
        queue.addOperation {
            guard !self.finished else { return }
            self.cancelled = true
            for work in self.works.values { work.task.cancel() }
            self.works.removeAll()
            self.inFlight.removeAll()
            self.inFlightBytes = 0
            self.saveState(force: true)
            self.close()
            self.endSessions()
            self.finished = true
        }
    }

    // MARK: - Where it starts

    private func begin() {
        guard !cancelled, !finished else { return }
        let loopback = acceptsLoopbackHTTP && image.url.scheme == "http" && image.url.host == "127.0.0.1"
        guard image.isFetchable || loopback else { return finish(.failure(Failure.notFetchable)) }
        do {
            try SecureFile.ensureDirectory(library.downloadsDirectory)
        } catch {
            return finish(.failure(error))
        }
        let partial = library.partialRestoreImageURL
        let have = VMLibrary.fileSize(partial)
        if let saved = library.downloadState(), saved.image == image, let total = saved.expectedLength, total > 0,
           saved.validator != nil, have > 0 {
            if let chunks = saved.chunks, chunks.total == total, have == total {
                // Chunks of several connections: the partial file has the whole length.
                state = saved
                map = chunks
            } else if saved.chunks == nil, have <= total {
                // One stream's beginning (a download from before): its whole chunks are here.
                state = saved
                map = VMChunkMap(chunkSize: chunkSize, total: total, contiguous: have)
            }
        }
        guard let map else { return startOver() }
        state.chunks = map
        if map.isComplete { return complete() }
        do {
            let handle = try FileHandle(forUpdating: partial)
            if VMLibrary.fileSize(partial) != map.total { try handle.truncate(atOffset: UInt64(map.total)) }
            self.handle = handle
        } catch {
            return finish(.failure(error))
        }
        saveState(force: true)
        report(force: true)
        fill()
    }

    /// From nothing: the first chunk is asked for, and its answer says the file's length and
    /// whether the server has ranges at all.
    private func startOver() {
        close()
        let partial = library.partialRestoreImageURL
        try? FileManager.default.removeItem(at: partial)
        map = nil
        single = false
        inFlight.removeAll()
        inFlightBytes = 0
        state = VMDownloadState(image: image)
        try? library.saveDownloadState(state)
        do {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forUpdating: partial)
        } catch {
            return finish(.failure(error))
        }
        report(force: true)
        var request = URLRequest(url: image.url)
        request.setValue("bytes=0-\(chunkSize - 1)", forHTTPHeaderField: "Range")
        launch(request, slot: 0, chunk: nil, from: 0, last: chunkSize - 1)
    }

    // MARK: - The chunks

    /// Every free connection takes the next chunk not here and not under way.
    private func fill() {
        guard !cancelled, !finished, !waiting, !single, let map else { return }
        let busy = Set(works.values.map(\.slot))
        var free = (0..<connections).filter { !busy.contains($0) }
        guard !free.isEmpty else { return }
        for index in map.missing where !inFlight.contains(index) {
            guard let slot = free.first else { break }
            free.removeFirst()
            let bytes = map.bytes(of: index)
            var request = URLRequest(url: image.url)
            request.setValue("bytes=\(bytes.first)-\(bytes.last)", forHTTPHeaderField: "Range")
            if let validator = state.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
            inFlight.insert(index)
            launch(request, slot: slot, chunk: index, from: bytes.first, last: bytes.last)
        }
        if works.isEmpty, map.isComplete { complete() }
    }

    private func launch(_ request: URLRequest, slot: Int, chunk: Int?, from: Int64, last: Int64?) {
        var request = request
        // The file as it is: a transfer encoding would make its ranges another file's.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpShouldHandleCookies = false
        let task = session(slot).dataTask(with: request)
        works[ObjectIdentifier(task)] = Work(task: task, slot: slot, chunk: chunk, next: from, last: last)
        task.resume()
    }

    /// Each connection's own session: one session would put every request on one HTTP/2
    /// connection, which is no faster than one request.
    private func session(_ slot: Int) -> URLSession {
        if let session = sessions[slot] { return session }
        let session = URLSession(configuration: makeConfiguration(), delegate: self, delegateQueue: queue)
        sessions[slot] = session
        return session
    }

    // MARK: - The answers

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !cancelled, !finished, var work = works[ObjectIdentifier(dataTask)], let http = response as? HTTPURLResponse else {
            return completionHandler(.cancel)
        }
        let status = http.statusCode
        let range = VMDownload.contentRange(http.value(forHTTPHeaderField: "Content-Range"))
        let validator = VMDownload.validator(etag: http.value(forHTTPHeaderField: "ETag"),
                                             lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        switch (work.chunk, status) {
        case (nil, 206):
            // The first chunk, and with it the file: its length, and what tells it from a later one.
            guard let range, range.first == 0, let total = range.total, total > 0,
                  range.last == min(chunkSize, total) - 1 else {
                return refuse(dataTask, work: &work, completionHandler)
            }
            do {
                try handle?.truncate(atOffset: UInt64(total))
            } catch {
                return fail(error, completionHandler)
            }
            let map = VMChunkMap(chunkSize: chunkSize, total: total)
            state.expectedLength = total
            state.validator = validator
            state.chunks = map
            self.map = map
            saveState(force: true)
            work.chunk = 0
            work.last = range.last
            inFlight.insert(0)
        case (nil, 200):
            // No ranges here: one stream, the whole file, from the start.
            single = true
            let length = http.expectedContentLength
            state.expectedLength = length > 0 ? length : nil
            state.validator = validator
            state.chunks = nil
            saveState(force: true)
            work.last = length > 0 ? length - 1 : nil
        case (.some(let index), 206):
            guard let map, let range, range.total == map.total else { return refuse(dataTask, work: &work, completionHandler) }
            let bytes = map.bytes(of: index)
            guard range.first == bytes.first, range.last == bytes.last else { return refuse(dataTask, work: &work, completionHandler) }
        case (.some, 200), (.some, 416):
            // The file is not the one the chunks here are of (If-Range did not hold, or it is
            // shorter now): what is here is another file's, and it starts over.
            completionHandler(.cancel)
            return fileChanged()
        default:
            completionHandler(.cancel)
            works[ObjectIdentifier(dataTask)] = nil
            if let index = work.chunk { inFlight.remove(index) }
            // A server's own trouble, or too many requests: tried again. Anything else is a no.
            if status >= 500 || status == 408 || status == 429 {
                return attemptFailed(received: 0, error: Failure.refused(status))
            }
            return finish(.failure(Failure.refused(status)))
        }
        work.accepted = true
        works[ObjectIdentifier(dataTask)] = work
        completionHandler(.allow)
        if work.chunk == 0, !single { fill() }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = ObjectIdentifier(dataTask)
        guard !cancelled, !finished, var work = works[key], work.accepted, !work.failed, let handle else { return }
        var bytes = data
        if let last = work.last, work.next + Int64(bytes.count) > last + 1 {
            // More than was asked for: not this chunk's.
            bytes = bytes.prefix(Int(max(0, last + 1 - work.next)))
            work.failed = true
        }
        do {
            try handle.seek(toOffset: UInt64(work.next))
            try handle.write(contentsOf: bytes)
        } catch {
            // The disk is full, or gone: no attempt after this one would do better.
            for other in works.values { other.task.cancel() }
            return finish(.failure(error))
        }
        work.next += Int64(bytes.count)
        work.received += Int64(bytes.count)
        if work.chunk != nil, !single { inFlightBytes += Int64(bytes.count) }
        emptyFailures = 0
        works[key] = work
        if work.failed { dataTask.cancel() }
        report(force: false)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        guard let work = works.removeValue(forKey: key) else { return }
        guard !cancelled, !finished else { return }
        if single {
            if error == nil, !work.failed, state.expectedLength.map({ work.next == $0 }) ?? true {
                state.expectedLength = work.next
                return complete()
            }
            // One stream cannot go on where it stopped: from the start, after a moment.
            return attemptFailed(received: work.received, error: error ?? Failure.incomplete)
        }
        guard let index = work.chunk, let map else {
            // The first answer did not come: from the start, after a moment.
            return attemptFailed(received: work.received, error: error ?? Failure.incomplete)
        }
        inFlight.remove(index)
        if !single { inFlightBytes -= work.received }
        let bytes = map.bytes(of: index)
        guard error == nil, !work.failed, work.next == bytes.last + 1 else {
            return attemptFailed(received: work.received, error: error ?? Failure.incomplete)
        }
        var updated = map
        updated.markDone(index)
        self.map = updated
        state.chunks = updated
        saveState(force: updated.isComplete)
        report(force: false)
        fill()
    }

    // MARK: - When something is not as it should be

    private func refuse(_ task: URLSessionDataTask, work: inout Work, _ completionHandler: (URLSession.ResponseDisposition) -> Void) {
        work.failed = true
        works[ObjectIdentifier(task)] = work
        completionHandler(.cancel)
    }

    private func fail(_ error: Error, _ completionHandler: (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        finish(.failure(error))
    }

    /// One answer did not bring its chunk: the chunk is asked for again after a moment; a network
    /// that brings nothing again and again is given up on.
    private func attemptFailed(received: Int64, error: Error) {
        if received == 0 { emptyFailures += 1 }
        // One connection at a time until the file is laid out in chunks; several after.
        let streams = map == nil || single ? 1 : connections
        guard emptyFailures < Self.maximumEmptyAttempts * streams else { return finish(.failure(error)) }
        guard !waiting else { return }
        waiting = true
        let delay = min(30.0, 3.0 * Double(emptyFailures / streams + 1))
        let queue = self.queue
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            queue.addOperation { [weak self] in self?.retry() }
        }
    }

    private func retry() {
        guard !cancelled, !finished else { return }
        waiting = false
        // Nothing laid out yet (the first answer did not come), or one stream, which cannot go on
        // where it stopped: from the start.
        if map == nil || single {
            if works.isEmpty { startOver() }
            return
        }
        fill()
    }

    /// The file changed under the download: what is here is dropped and it starts over — not
    /// forever.
    private func fileChanged() {
        for work in works.values { work.task.cancel() }
        works.removeAll()
        restarts += 1
        guard restarts <= Self.maximumRestarts else { return finish(.failure(Failure.keepsChanging)) }
        startOver()
    }

    // MARK: - The end

    private func complete() {
        close()
        let partial = library.partialRestoreImageURL
        if let total = state.expectedLength, VMLibrary.fileSize(partial) != total {
            return finish(.failure(Failure.incomplete))
        }
        saveState(force: true)
        do {
            let whole = library.restoreImageURL
            try? FileManager.default.removeItem(at: whole)
            try FileManager.default.moveItem(at: partial, to: whole)
            report(force: true)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    private func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    private func endSessions() {
        for session in sessions.values { session.invalidateAndCancel() }
        sessions.removeAll()
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        for work in works.values { work.task.cancel() }
        works.removeAll()
        if map != nil { saveState(force: true) }
        close()
        endSessions()
        onFinish(result)
    }

    /// The chunks that are here, written down — every chunk at most once a second, and at once at
    /// the end or a pause.
    private func saveState(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSaved) >= 1 else { return }
        lastSaved = now
        try? library.saveDownloadState(state)
    }

    private var have: Int64 {
        if single { return works.values.first?.next ?? 0 }
        return (map?.doneBytes ?? 0) + inFlightBytes
    }

    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.5 else { return }
        lastReport = now
        let have = self.have
        if let mark = speedMark {
            let elapsed = now.timeIntervalSince(mark.at)
            if elapsed >= 3 {
                speed = Double(max(0, have - mark.have)) / elapsed
                speedMark = (now, have)
            }
        } else {
            speedMark = (now, have)
        }
        onProgress(Progress(have: have, total: state.expectedLength, speed: speed, connections: works.count))
    }
}
