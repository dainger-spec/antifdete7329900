import Foundation
import VMControllerCore

enum HostInfo {
    /// Tart (Virtualization.framework macOS guests) needs Apple Silicon.
    /// True under Rosetta too, where tart itself still runs natively.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func availableDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Finding and installing tart. The app never bundles it: it uses the user's
/// own (Homebrew/PATH) or downloads the latest release on request.
enum TartSetup {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VMLauncher", isDirectory: true)
    }

    static var managedApp: URL { supportDirectory.appendingPathComponent("tart/tart.app", isDirectory: true) }
    static var managedBinary: URL { managedApp.appendingPathComponent("Contents/MacOS/tart") }

    /// The user's tart first (kept current by Homebrew), then the downloaded one.
    static func locate(searchPath: String) -> String? {
        if let path = LauncherEnvironment.findExecutable("tart", searchPath: searchPath) { return path }
        return FileManager.default.isExecutableFile(atPath: managedBinary.path) ? managedBinary.path : nil
    }

    /// Unpacks a downloaded tart.tar.gz, checks the code signature and moves
    /// tart.app into Application Support. tart must stay inside its bundle: its
    /// virtualization entitlements come with the bundle's provisioning profile.
    static func install(archive: URL, environment: [String: String]) async throws -> String {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("tart-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archive)
        }

        let untar = try await GroupProcess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path],
                                               environment: environment, timeout: 300)
        guard untar.code == 0 else {
            throw LaunchFailure.failed("Не удалось распаковать архив Tart: \(untar.lines.last ?? "ошибка tar")")
        }
        guard let app = findApp(in: staging) else {
            throw LaunchFailure.failed("В скачанном архиве нет tart.app")
        }
        let verify = try await GroupProcess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                                                environment: environment, timeout: 120)
        guard verify.code == 0 else {
            throw LaunchFailure.failed("Подпись tart.app не прошла проверку: \(verify.lines.last ?? "codesign")")
        }

        try fileManager.createDirectory(at: managedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: managedApp.path) {
            try fileManager.removeItem(at: managedApp)
        }
        try fileManager.moveItem(at: app, to: managedApp)
        guard fileManager.isExecutableFile(atPath: managedBinary.path) else {
            throw LaunchFailure.failed("В tart.app нет исполняемого файла Contents/MacOS/tart")
        }
        return managedBinary.path
    }

    private static func findApp(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("tart.app")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.map { $0.appendingPathComponent("tart.app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Downloads the latest Tart release from GitHub with byte-level progress.
final class TartDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let releaseURL = URL(string: "https://github.com/cirruslabs/tart/releases/latest/download/tart.tar.gz")!

    typealias ProgressHandler = @Sendable (_ fraction: Double?, _ received: Int64, _ expected: Int64) -> Void

    private let onProgress: ProgressHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var downloadedFile: URL?
    private var failure: Error?
    private var cancelled = false

    init(onProgress: @escaping ProgressHandler) {
        self.onProgress = onProgress
    }

    /// The path of the downloaded archive (the caller deletes it).
    func download() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
            let task = session.downloadTask(with: Self.releaseURL)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted as soon as this returns: move the file now.
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            store(LaunchFailure.failed("GitHub ответил \(response.statusCode) на \(Self.releaseURL.absoluteString)"))
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tart-\(UUID().uuidString).tar.gz")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            downloadedFile = destination
            lock.unlock()
        } catch {
            store(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let file = downloadedFile
        let stored = failure
        let wasCancelled = cancelled
        lock.unlock()

        if wasCancelled || (error as? URLError)?.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: LaunchFailure.failed("Не удалось скачать Tart: \(error.localizedDescription)"))
        } else if let stored {
            continuation?.resume(throwing: stored)
        } else if let file {
            continuation?.resume(returning: file)
        } else {
            continuation?.resume(throwing: LaunchFailure.failed("Загрузка Tart завершилась без файла"))
        }
    }

    private func store(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }
}
