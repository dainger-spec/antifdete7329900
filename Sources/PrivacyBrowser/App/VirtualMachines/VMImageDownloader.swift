import BrowserCore
import Foundation
import os

/// Fetches Apple's restore image — the macOS a virtual machine is installed from, some fifteen
/// gigabytes — from Apple's own servers into the machines' library, so that none of it is in the
/// app's download. What was fetched is kept: a download that was paused, or cut off, or met the
/// app's quit goes on from where it stopped (`VMDownload`: a Range request under If-Range, so a
/// file Apple replaced meanwhile starts over rather than being stitched from two).
///
/// The file is checked by what installs it: Apple's installer verifies the image and has Apple
/// sign the installation for this machine; a file that is not Apple's does not install.
final class VMImageDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        var have: Int64
        var total: Int64?
        /// Bytes a second over the last few seconds; nil until known.
        var speed: Double?
    }

    enum Failure: LocalizedError {
        case refused(Int)
        case incomplete
        case notFetchable

        var errorDescription: String? {
            switch self {
            case .refused(let status): return String(format: L("vm.download.error.refused"), status)
            case .incomplete: return L("vm.download.error.incomplete")
            case .notFetchable: return L("vm.download.error.notFetchable")
            }
        }
    }

    private let library: VMLibrary
    private let image: VMRestoreImage
    private let onProgress: @Sendable (Progress) -> Void
    private let onFinish: @Sendable (Result<Void, Error>) -> Void

    /// Everything below is touched on `queue` only (the session's delegate queue is on it).
    private let queue = DispatchQueue(label: "io.lumenbrowser.vm.download")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var request = VMDownload.Request.whole
    private var state: VMDownloadState
    private var have: Int64 = 0
    private var cancelled = false
    private var finished = false
    /// Attempts in a row that brought nothing: a connection that keeps failing is given up on.
    private var emptyAttempts = 0
    private var receivedThisAttempt = false
    private var lastReport = Date.distantPast
    private var speedMark: (at: Date, have: Int64)?
    private var speed: Double?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "VirtualMachines")

    static let maximumEmptyAttempts = 6

    init(library: VMLibrary, image: VMRestoreImage, onProgress: @escaping @Sendable (Progress) -> Void,
         onFinish: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.library = library
        self.image = image
        self.onProgress = onProgress
        self.onFinish = onFinish
        state = VMDownloadState(image: image)
    }

    func start() {
        queue.async { self.begin() }
    }

    /// Stops the download; what was fetched stays for the next start.
    func pause() {
        queue.async {
            guard !self.finished else { return }
            self.cancelled = true
            self.task?.cancel()
            self.close()
            self.session?.invalidateAndCancel()
            self.session = nil
            self.finished = true
        }
    }

    // MARK: One attempt

    private func begin() {
        guard !cancelled, !finished else { return }
        guard image.isFetchable else { return finish(.failure(Failure.notFetchable)) }
        do {
            try SecureFile.ensureDirectory(library.downloadsDirectory)
        } catch {
            return finish(.failure(error))
        }
        let partial = library.partialRestoreImageURL
        have = VMLibrary.fileSize(partial)
        request = VMDownload.request(state: library.downloadState(), image: image, have: have)
        if let known = library.downloadState(), known.image == image { state = known }
        switch request {
        case .nothing:
            return complete()
        case .whole:
            have = 0
            state = VMDownloadState(image: image)
            try? FileManager.default.removeItem(at: partial)
            try? library.saveDownloadState(state)
        case .rest:
            break
        }
        var urlRequest = URLRequest(url: image.url)
        for (name, value) in VMDownload.headers(for: request) { urlRequest.setValue(value, forHTTPHeaderField: name) }
        // The file as it is: a transfer encoding would make its ranges another file's.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if session == nil {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 14 * 24 * 3600
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        }
        receivedThisAttempt = false
        speedMark = nil
        task = session?.dataTask(with: urlRequest)
        task?.resume()
        report(force: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let answer = VMDownload.answer(to: request, status: http.statusCode,
                                       contentRange: http.value(forHTTPHeaderField: "Content-Range"), contentLength: length)
        let partial = library.partialRestoreImageURL
        do {
            switch answer {
            case .append(let total):
                if let total { state.expectedLength = total }
            case .restart(let total):
                // The whole file (again): what was there is another file's beginning.
                have = 0
                try? FileManager.default.removeItem(at: partial)
                state = VMDownloadState(image: image, expectedLength: total,
                                        validator: VMDownload.validator(etag: http.value(forHTTPHeaderField: "ETag"),
                                                                        lastModified: http.value(forHTTPHeaderField: "Last-Modified")))
            case .refused(let status):
                if status == 416 {
                    // What is here is longer than the file: not this file's. From the start, next attempt.
                    try? FileManager.default.removeItem(at: partial)
                    try? FileManager.default.removeItem(at: library.downloadStateURL)
                }
                pendingRefusal = status
                return completionHandler(.cancel)
            }
            try library.saveDownloadState(state)
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            self.handle = handle
            completionHandler(.allow)
        } catch {
            pendingError = error
            completionHandler(.cancel)
        }
    }

    private var pendingRefusal: Int?
    private var pendingError: Error?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, !cancelled else { return }
        do {
            try handle.write(contentsOf: data)
            have += Int64(data.count)
            receivedThisAttempt = true
            report(force: false)
        } catch {
            // The disk is full, or gone: no attempt after this one would do better.
            pendingError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        close()
        guard !cancelled, !finished else { return }
        if let pendingError {
            return finish(.failure(pendingError))
        }
        if let status = pendingRefusal {
            pendingRefusal = nil
            if status == 416 { return retry(after: Failure.refused(status)) }
            return finish(.failure(Failure.refused(status)))
        }
        if let error {
            return retry(after: error)
        }
        if let expected = state.expectedLength, have != expected {
            return retry(after: Failure.incomplete)
        }
        complete()
    }

    /// A connection that broke is taken up again from where it stopped; one that keeps bringing
    /// nothing is given up on, with what is on disk kept for the person's next try.
    private func retry(after error: Error) {
        emptyAttempts = receivedThisAttempt ? 0 : emptyAttempts + 1
        guard emptyAttempts < Self.maximumEmptyAttempts else { return finish(.failure(error)) }
        log.notice("The restore image's download broke off (\(error.logKind, privacy: .public)); going on in a moment")
        queue.asyncAfter(deadline: .now() + .seconds(min(30, 3 * (emptyAttempts + 1)))) { self.begin() }
    }

    private func complete() {
        do {
            let whole = library.restoreImageURL
            try? FileManager.default.removeItem(at: whole)
            try FileManager.default.moveItem(at: library.partialRestoreImageURL, to: whole)
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

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        close()
        session?.invalidateAndCancel()
        session = nil
        onFinish(result)
    }

    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.5 else { return }
        lastReport = now
        if let mark = speedMark {
            let elapsed = now.timeIntervalSince(mark.at)
            if elapsed >= 3 {
                speed = Double(have - mark.have) / elapsed
                speedMark = (now, have)
            }
        } else {
            speedMark = (now, have)
        }
        onProgress(Progress(have: have, total: state.expectedLength, speed: speed))
    }
}
