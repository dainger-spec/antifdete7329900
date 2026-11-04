import Foundation

/// What the app hands the installer helper, and what the helper leaves for the app: two small files
/// in the update's staging folder, next to the archive (docs/UPDATES.md §3). Nothing else passes
/// between them — a sandboxed app cannot give a program it launches arguments, and the helper takes
/// none anyway.
public enum UpdateStaging {
    /// `Library/Caches/<bundle id>.update` in the user's real home: the one folder outside its
    /// container the sandboxed build may write (a temporary exception for exactly this path), so that
    /// the helper, outside the sandbox, never reads inside the app's container.
    public static func folder(bundleIdentifier: String, home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/\(bundleIdentifier).update", isDirectory: true)
    }

    public static let requestName = "request.json"
    public static let outcomeName = "outcome.json"

    /// A file name the staging folder may hold an archive under: no path, nothing hidden.
    public static func isArchiveName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.hasPrefix(".") && name.hasSuffix(".zip")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

/// The app's request to install one release, written at quit once every profile is sealed.
public struct UpdateRequest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    /// The app to replace. The helper refuses any but the bundle it is in.
    public var appPath: String
    /// The archive's file name in the staging folder.
    public var archive: String
    /// The release, as the app checked it; the helper checks it again.
    public var item: AppcastItem
    public var requestedAt: Date

    public init(appPath: String, archive: String, item: AppcastItem, requestedAt: Date) {
        format = Self.currentFormat
        self.appPath = appPath
        self.archive = archive
        self.item = item
        self.requestedAt = requestedAt
    }

    public static func read(from folder: URL) throws -> UpdateRequest {
        let json = try Data(contentsOf: folder.appendingPathComponent(UpdateStaging.requestName))
        try DocumentFormat.check(json, supported: currentFormat, what: UpdateStaging.requestName)
        let request = try JSONCoding.decoder.decode(UpdateRequest.self, from: json)
        guard UpdateStaging.isArchiveName(request.archive) else { throw UpdateError.invalidItem("archive name \(request.archive)") }
        return request
    }

    public func write(to folder: URL) throws {
        try SecureFile.write(JSONCoding.encoder.encode(self), to: folder.appendingPathComponent(UpdateStaging.requestName))
    }
}

/// What came of a request: left by the helper, shown by the app at its next launch.
public struct UpdateOutcome: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        /// The new build is in place and was started.
        case installed
        /// The new build was put in place but could not be started: the old one is back.
        case rolledBack
        /// A check failed: nothing was replaced.
        case refused
        /// The app, or a process running from it, did not go away: nothing was replaced, nothing killed.
        case gaveUp
    }

    public static let currentFormat = 1

    public var format: Int
    public var result: Result
    /// Why, in English (the log's words); the app says it in its own.
    public var detail: String
    public var fromBuild: String
    public var toBuild: String
    public var version: String
    public var at: Date

    public init(result: Result, detail: String, fromBuild: String, toBuild: String, version: String, at: Date) {
        format = Self.currentFormat
        self.result = result
        self.detail = detail
        self.fromBuild = fromBuild
        self.toBuild = toBuild
        self.version = version
        self.at = at
    }

    /// The outcome in `folder`, if any (one of a newer format is not read).
    public static func read(from folder: URL) -> UpdateOutcome? {
        guard let json = try? Data(contentsOf: folder.appendingPathComponent(UpdateStaging.outcomeName)),
              (try? DocumentFormat.check(json, supported: currentFormat, what: UpdateStaging.outcomeName)) != nil else { return nil }
        return try? JSONCoding.decoder.decode(UpdateOutcome.self, from: json)
    }

    public func write(to folder: URL) throws {
        try SecureFile.write(JSONCoding.encoder.encode(self), to: folder.appendingPathComponent(UpdateStaging.outcomeName))
    }
}
