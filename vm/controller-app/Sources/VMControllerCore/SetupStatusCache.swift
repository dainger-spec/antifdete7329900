import Foundation

/// A remembered result of the environment check (is Tart installed? is the base
/// image already pulled?), so a repeat launch can show "ready" immediately and
/// verify in the background instead of blocking on `tart list` every time.
///
/// It's only a hint: the model still revalidates, and a stale/wrong cache just
/// means one slower launch, never a broken one.
public struct SetupStatus: Codable, Equatable, Sendable {
    public var tartPath: String?
    public var tartVersion: String?
    public var baseImage: String
    public var baseImagePresent: Bool
    /// The registry digest of the base image when it was last pulled, so a later
    /// check can tell whether the tag has moved. nil = unknown (never recorded).
    public var baseImageDigest: String?
    public var checkedAt: Date

    public init(tartPath: String? = nil, tartVersion: String? = nil,
                baseImage: String = LauncherDefaults.baseImage,
                baseImagePresent: Bool = false, baseImageDigest: String? = nil,
                checkedAt: Date = Date()) {
        self.tartPath = tartPath
        self.tartVersion = tartVersion
        self.baseImage = baseImage
        self.baseImagePresent = baseImagePresent
        self.baseImageDigest = baseImageDigest
        self.checkedAt = checkedAt
    }

    /// True if this check is recent enough to trust for the optimistic display.
    public func isFresh(within ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(checkedAt) < ttl
    }

    /// Good enough to skip straight toward launch: Tart was found and the image
    /// for `baseImage` was present, recently.
    public func canFastPath(for baseImage: String, ttl: TimeInterval, now: Date = Date()) -> Bool {
        tartPath != nil && baseImagePresent && self.baseImage == baseImage && isFresh(within: ttl, now: now)
    }
}

public final class SetupStatusCache {
    /// Image presence changes rarely (the VM sits on disk), so a day is plenty;
    /// the background revalidation corrects it sooner if it's wrong.
    public static let defaultTTL: TimeInterval = 24 * 60 * 60

    public let url: URL
    private let lock = NSLock()

    public static func defaultURL() -> URL {
        ProfileStore.defaultURL().deletingLastPathComponent().appendingPathComponent("setup-status.json")
    }

    public init(url: URL = SetupStatusCache.defaultURL()) {
        self.url = url
    }

    public func load() -> SetupStatus? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SetupStatus.self, from: data)
    }

    public func save(_ status: SetupStatus) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
