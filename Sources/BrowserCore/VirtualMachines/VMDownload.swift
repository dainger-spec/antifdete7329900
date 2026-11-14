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

    public init(image: VMRestoreImage, expectedLength: Int64? = nil, validator: String? = nil) {
        self.image = image
        self.expectedLength = expectedLength
        self.validator = validator
    }
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
