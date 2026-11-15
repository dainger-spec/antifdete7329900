#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// A restore image the person already has — Lumen's download from another Mac, a colleague's, one
/// fetched by a download manager — taken into the machines' library in the download's place, so
/// that the setup installs from it as it would from its own.
///
/// What the file is, is told by what installs it: before this the helper loads it with Apple's
/// framework and says which macOS it holds and whether it runs on this Mac (`inspect`), and Apple's
/// installer verifies it as it does a downloaded one. Here only what can be told of a file without
/// Apple: that it is one, large enough to be a restore image, and a ZIP archive, as every `.ipsw` is.
///
/// The file is cloned where it can be (APFS, the same volume: no room taken, at once), copied
/// otherwise — into a file of its own beside the download, put in the image's place only when it is
/// whole. The person's own file is never moved or changed. A download paused before is set aside
/// once the copy is whole: the person chose their file instead.
public final class VMImageImport: @unchecked Sendable {
    public enum Problem: Error, Equatable {
        /// Not a file (a folder, or nothing there).
        case notAFile
        /// Far smaller than any restore image.
        case tooSmall(Int64)
        /// Not a ZIP archive, which every `.ipsw` is.
        case notARestoreImage
        case unreadable
        /// Not room enough for a copy (the file is on another volume).
        case notEnoughSpace(needed: Int64, free: Int64)
    }

    /// No restore image of macOS for Apple silicon is smaller than this.
    public static let minimumLength: Int64 = 1 << 30
    /// What is copied at a time.
    static let block = 8 << 20

    /// What can be told of `url` without Apple: nil when it may be a restore image.
    public static func problem(with url: URL, minimumLength: Int64 = minimumLength) -> Problem? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .notAFile
        }
        let length = VMLibrary.fileSize(url)
        guard length >= minimumLength else { return .tooSmall(length) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return .unreadable }
        // A ZIP archive's first record: "PK", 3, 4.
        guard head == Data([0x50, 0x4B, 0x03, 0x04]) else { return .notARestoreImage }
        return nil
    }

    private let source: URL
    private let library: VMLibrary
    private let onProgress: @Sendable (VMImageFetch.Progress) -> Void
    private let onFinish: @Sendable (Result<Void, Error>) -> Void
    /// Clones are tried before copies; the tests turn them off to see a copy where the volume
    /// would clone.
    var clones = true
    private let lock = NSLock()
    private var cancelled = false

    public init(source: URL, library: VMLibrary, onProgress: @escaping @Sendable (VMImageFetch.Progress) -> Void,
                onFinish: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.source = source
        self.library = library
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    /// Where the copy is made, until it is whole.
    public var staging: URL { library.downloadsDirectory.appendingPathComponent("restore.ipsw.importing") }

    public func start() {
        let thread = Thread { [self] in
            let result = Result { try run() }
            if case .failure = result { try? FileManager.default.removeItem(at: staging) }
            guard !isCancelled else { return }
            onFinish(result)
        }
        thread.name = "io.lumenbrowser.vm.import"
        thread.start()
    }

    /// Stops the copy; what was copied so far is removed. Nothing is said after this.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run() throws {
        let manager = FileManager.default
        try SecureFile.ensureDirectory(library.downloadsDirectory)
        try? manager.removeItem(at: staging)
        let total = VMLibrary.fileSize(source)
        onProgress(VMImageFetch.Progress(have: 0, total: total, speed: nil))
        if !(clones && clone()) {
            try ensureRoom(for: total)
            try copy(total: total)
        }
        guard !isCancelled else { throw CancellationError() }
        guard VMLibrary.fileSize(staging) == total else { throw VMImageFetch.Failure.incomplete }
        // Whole: the person's file is the image now, and a download of Lumen's own is set aside.
        for url in [library.partialRestoreImageURL, library.downloadStateURL, library.restoreImageURL] {
            try? manager.removeItem(at: url)
        }
        try manager.moveItem(at: staging, to: library.restoreImageURL)
        onProgress(VMImageFetch.Progress(have: total, total: total, speed: nil))
    }

    /// A clone of the file on the same APFS volume: no room taken, at once.
    private func clone() -> Bool {
        #if canImport(Darwin)
        return clonefile(source.path, staging.path, 0) == 0
        #else
        return false
        #endif
    }

    private func ensureRoom(for length: Int64) throws {
        #if os(macOS)
        let values = try? library.downloadsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < length {
            throw Problem.notEnoughSpace(needed: length, free: free)
        }
        #endif
    }

    private func copy(total: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        var have: Int64 = 0
        var lastReport = Date.distantPast
        var mark: (at: Date, have: Int64) = (Date(), 0)
        var speed: Double?
        while true {
            guard !isCancelled else { throw CancellationError() }
            guard let data = try input.read(upToCount: Self.block), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            have += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.25 {
                lastReport = now
                let elapsed = now.timeIntervalSince(mark.at)
                if elapsed >= 2 {
                    speed = Double(have - mark.have) / elapsed
                    mark = (now, have)
                }
                onProgress(VMImageFetch.Progress(have: have, total: total, speed: speed))
            }
        }
        try output.synchronize()
    }
}
