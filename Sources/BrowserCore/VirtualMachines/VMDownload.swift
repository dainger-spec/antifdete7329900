import Foundation

/// Apple's restore image for the machines (an `.ipsw`, the file a Mac is restored from): where it
/// is, and which macOS it holds. Fetched from Apple's own servers by the app, never part of the
/// app's download.
public struct VMRestoreImage: Codable, Equatable, Sendable {
    public var url: URL
    /// "26.1", "25B78".
    public var version: String
    public var build: String

    public init(url: URL, version: String, build: String) {
        self.url = url
        self.version = version
        self.build = build
    }

    /// Only an https address is fetched.
    public var isFetchable: Bool { url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty }
}

/// A download that can go on where it stopped: what is being fetched and what the server said of
/// it, kept beside the partial file (`restore.json`).
public struct VMDownloadState: Codable, Equatable, Sendable {
    public var image: VMRestoreImage
    /// The whole file's length, once the server said it.
    public var expectedLength: Int64?
    /// What tells this very file from a later one at the same address (the `ETag`, else
    /// `Last-Modified`): sent back as `If-Range`, so that a changed file starts again instead of
    /// being glued to the old one's beginning.
    public var validator: String?
    /// The file in chunks, and which of them are here (`VMImageFetch`, several connections at
    /// once). Nil in a state of one stream (a download from before, or from a server that has no
    /// ranges): what is here is then the file's beginning, as long as the partial file is.
    public var chunks: VMChunkMap?

    public init(image: VMRestoreImage, expectedLength: Int64? = nil, validator: String? = nil, chunks: VMChunkMap? = nil) {
        self.image = image
        self.expectedLength = expectedLength
        self.validator = validator
        self.chunks = chunks
    }
}

/// A file fetched in chunks of one size (the last one shorter), several at once and in any order,
/// and which of them are here: the partial file has the file's whole length from the start, and
/// a chunk counts only once every byte of it was written.
public struct VMChunkMap: Codable, Equatable, Sendable {
    public var chunkSize: Int64
    public var total: Int64
    /// The chunks that are here, as runs of indexes `[first, last]`, in order and not touching.
    public private(set) var done: [[Int]]

    public init(chunkSize: Int64, total: Int64, done: [[Int]] = []) {
        self.chunkSize = max(1, chunkSize)
        self.total = max(0, total)
        self.done = []
        for run in done where run.count == 2 && run[0] <= run[1] {
            for index in run[0]...run[1] { markDone(index) }
        }
    }

    /// The chunks a file of one stream holds whole: its first `have` bytes.
    public init(chunkSize: Int64, total: Int64, contiguous have: Int64) {
        self.init(chunkSize: chunkSize, total: total)
        let whole = have >= total ? count : Int(max(0, have) / self.chunkSize)
        if whole > 0 { done = [[0, whole - 1]] }
    }

    public var count: Int { total == 0 ? 0 : Int((total + chunkSize - 1) / chunkSize) }

    /// The bytes of chunk `index`: its first and its last (inclusive).
    public func bytes(of index: Int) -> (first: Int64, last: Int64) {
        let first = Int64(index) * chunkSize
        return (first, min(first + chunkSize, total) - 1)
    }

    public func isDone(_ index: Int) -> Bool {
        done.contains { $0[0] <= index && index <= $0[1] }
    }

    public mutating func markDone(_ index: Int) {
        guard index >= 0, index < count, !isDone(index) else { return }
        var runs = done + [[index, index]]
        runs.sort { $0[0] < $1[0] }
        var merged: [[Int]] = []
        for run in runs {
            if let last = merged.last, last[1] + 1 >= run[0] {
                merged[merged.count - 1][1] = max(last[1], run[1])
            } else {
                merged.append(run)
            }
        }
        done = merged
    }

    /// The chunks not here yet, in order.
    public var missing: [Int] {
        var missing: [Int] = []
        var next = 0
        for run in done {
            if next < run[0] { missing += Array(next..<run[0]) }
            next = run[1] + 1
        }
        if next < count { missing += Array(next..<count) }
        return missing
    }

    public var doneBytes: Int64 {
        done.reduce(Int64(0)) { sum, run in
            let first = bytes(of: run[0]).first
            let last = bytes(of: run[1]).last
            return sum + (last - first + 1)
        }
    }

    public var isComplete: Bool { done == (count == 0 ? [] : [[0, count - 1]]) }
}

/// The rules of the resumable download, apart from the network: what to ask for, and what an
/// answer means for the partial file.
public enum VMDownload {
    /// What to ask the server for, with `have` bytes of the file here already.
    public enum Request: Equatable, Sendable {
        /// The whole file.
        case whole
        /// The rest: `Range: bytes=<from>-`, with `If-Range` when the file's validator is known.
        case rest(from: Int64, ifRange: String?)
        /// Nothing: the file is whole.
        case nothing
    }

    public static func request(state: VMDownloadState?, image: VMRestoreImage, have: Int64) -> Request {
        // Another image than the partial file is of (a newer macOS since): from the start.
        guard let state, state.image == image, have > 0 else { return .whole }
        if let expected = state.expectedLength, have >= expected { return have == expected ? .nothing : .whole }
        // Without a validator a changed file could not be told: from the start.
        guard let validator = state.validator else { return .whole }
        return .rest(from: have, ifRange: validator)
    }

    /// The headers of `request`.
    public static func headers(for request: Request) -> [String: String] {
        guard case let .rest(from, ifRange) = request else { return [:] }
        var headers = ["Range": "bytes=\(from)-"]
        if let ifRange { headers["If-Range"] = ifRange }
        return headers
    }

    /// What to do with the answer's body.
    public enum Answer: Equatable, Sendable {
        /// Write it after what is here (`total`: the whole file's length).
        case append(total: Int64?)
        /// The server sent the whole file: drop what is here and write from the start.
        case restart(total: Int64?)
        /// Not a file to write: the status, for the person.
        case refused(status: Int)
    }

    /// `status`, `Content-Range` and `Content-Length` of the answer to `request`.
    public static func answer(to request: Request, status: Int, contentRange: String?, contentLength: Int64?) -> Answer {
        switch status {
        case 206:
            guard case let .rest(from, _) = request, let range = parseContentRange(contentRange), range.first == from else {
                return .refused(status: status)
            }
            return .append(total: range.total)
        case 200:
            return .restart(total: contentLength)
        default:
            return .refused(status: status)
        }
    }

    /// "bytes 100-999/1000" → (100, 999, 1000); the total is nil for "/*".
    public static func contentRange(_ header: String?) -> (first: Int64, last: Int64, total: Int64?)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let first = Int64(parts[0][..<dash]),
              let last = Int64(parts[0][parts[0].index(after: dash)...]), first <= last else { return nil }
        return (first, last, parts[1] == "*" ? nil : Int64(parts[1]))
    }

    /// "bytes 100-999/1000" → (100, 1000); the total is nil for "/*".
    static func parseContentRange(_ header: String?) -> (first: Int64, total: Int64?)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let first = Int64(parts[0][..<dash]) else { return nil }
        return (first, Int64(parts[1]))
    }

    /// The validator of an answer: its `ETag` when it is a strong one, else `Last-Modified`.
    public static func validator(etag: String?, lastModified: String?) -> String? {
        if let etag, !etag.isEmpty, !etag.hasPrefix("W/") { return etag }
        if let lastModified, !lastModified.isEmpty { return lastModified }
        return nil
    }
}
