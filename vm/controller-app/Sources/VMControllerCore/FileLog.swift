import Foundation

/// A small append-only log file on the host: launches, errors, VM IPs. Capped
/// in size (old lines drop from the front at a line boundary), thread-safe, and
/// best-effort — logging never throws into the caller. The app's "Show log"
/// reads it with `tail`.
public final class FileLog {
    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public static func defaultURL() -> URL {
        ProfileStore.defaultURL().deletingLastPathComponent().appendingPathComponent("launcher.log")
    }

    public init(url: URL = FileLog.defaultURL(), maxBytes: Int = 512 * 1024) {
        self.url = url
        self.maxBytes = max(maxBytes, 8 * 1024)
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public func append(_ message: String, level: String = "info", date: Date = Date()) {
        let line = "\(Self.stamp.string(from: date)) [\(level)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(Data(line.utf8))
        if data.count > maxBytes {
            data = Self.trimmed(data, to: maxBytes / 2)
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Drop whole lines from the front until `data` fits in `limit` bytes.
    static func trimmed(_ data: Data, to limit: Int) -> Data {
        guard data.count > limit else { return data }
        let start = data.count - limit
        // Advance to just after the next newline so we never keep a partial line.
        if let nl = data[start...].firstIndex(of: 0x0A) {
            return data[(nl + 1)...]
        }
        return data[start...]
    }

    /// The last `maxBytes` of the log, as text (for display).
    public func tail(maxBytes: Int = 64 * 1024) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let slice = data.count > maxBytes ? Self.trimmed(data, to: maxBytes) : data
        return String(decoding: slice, as: UTF8.self)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
