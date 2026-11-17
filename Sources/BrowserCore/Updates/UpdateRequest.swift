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
    /// Kept by the installer while it works (`UpdateInstallMarker`).
    public static let markerName = "installing.json"
    /// Left by a Lumen opened during an install, which stepped aside (`UpdateRelaunchWish`).
    public static let relaunchName = "relaunch.json"

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
    /// The words of the installer's window, in the app's interface language (`UpdateProgressTexts`
    /// keys): the helper has none of its own. Absent from requests of builds before 0.1.19.
    public var texts: [String: String]?

    public init(appPath: String, archive: String, item: AppcastItem, requestedAt: Date, texts: [String: String]? = nil) {
        format = Self.currentFormat
        self.appPath = appPath
        self.archive = archive
        self.item = item
        self.requestedAt = requestedAt
        self.texts = texts
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

    /// Why, as the app says it (`updates.outcome.<reason>`): `detail` is the log's, in English, and
    /// never shown. Written by installers from 0.1.19; for an earlier one's outcome it is told from
    /// the detail (`kind`).
    public enum Reason: String, Codable, CaseIterable, Sendable {
        /// Installed and started.
        case installed
        /// Lumen was opened again, and stayed open, before the swap.
        case startedAgain
        /// A process of the app did not end within the installer's patience.
        case stillRunning
        /// The request was not from the quit that started the installer.
        case staleRequest
        /// The request named another copy of the app.
        case otherApp
        /// There was no request (or it could not be read).
        case noRequest
        /// The installed app's own signature or keys do not hold: nothing is trusted.
        case untrustedApp
        /// The release is not newer than the installed build, or not for this macOS.
        case notApplicable
        /// The archive or the app in it did not pass a check (length, hash, signature, identifier,
        /// versions, code signature).
        case badRelease
        /// The bundles could not be swapped; the installed app is untouched.
        case swapFailed
        /// The new version was put in place but did not check there or did not start.
        case didNotStart
        case unknown
    }

    public static let currentFormat = 1

    public var format: Int
    public var result: Result
    /// Why, in English (the log's words); the app says it in its own (`kind`), and never shows this.
    public var detail: String
    /// `Reason`'s raw value; a string, so that a newer installer's reason does not make the whole
    /// outcome unreadable.
    public var reason: String?
    public var fromBuild: String
    public var toBuild: String
    public var version: String
    public var at: Date

    public init(result: Result, detail: String, fromBuild: String, toBuild: String, version: String, at: Date,
                reason: Reason? = nil) {
        format = Self.currentFormat
        self.result = result
        self.detail = detail
        self.reason = reason?.rawValue
        self.fromBuild = fromBuild
        self.toBuild = toBuild
        self.version = version
        self.at = at
    }

    /// Why, for the app's words: the installer's reason, or — from an installer before 0.1.19 —
    /// told from its English detail.
    public var kind: Reason {
        if let reason, let known = Reason(rawValue: reason) { return known }
        switch result {
        case .installed: return .installed
        case .rolledBack: return .didNotStart
        case .gaveUp:
            return detail.contains("started again") ? .startedAgain : .stillRunning
        case .refused:
            if detail.hasPrefix("no request") { return .noRequest }
            if detail.contains("not from this quit") { return .staleRequest }
            if detail.hasPrefix("the request is for") { return .otherApp }
            if detail.contains("the swap failed") { return .swapFailed }
            if detail.contains("does not check in place") { return .didNotStart }
            if detail.hasPrefix("the installed app") { return .untrustedApp }
            if detail.contains("archive") || detail.contains("signature") || detail.contains("release says") { return .badRelease }
            return .unknown
        }
    }

    /// The key of the app's sentence for this outcome (a `%@` for the version).
    public var noticeKey: String { "updates.outcome.\(kind.rawValue)" }

    /// The archive is still in the staging folder: the next quit — or Install Now — installs it
    /// without downloading it again.
    public var archiveKept: Bool {
        switch kind {
        case .startedAgain, .stillRunning, .staleRequest, .otherApp: return result != .installed
        default: return false
        }
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
