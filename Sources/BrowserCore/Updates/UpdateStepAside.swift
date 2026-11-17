import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The three steps of an install as the update's window shows them (docs/UPDATES.md §7): the
/// release checked — the app's processes waited for first —, the bundles swapped, the new version
/// started. The app shows the first while it stops its profiles; the installer helper the rest.
public enum UpdateInstallStep: String, Codable, CaseIterable, Sendable {
    case checking
    case installing
    case relaunching
}

/// What the installer helper keeps in the staging folder while it works (`installing.json`): its
/// pid, the app it replaces, the step it is at, and when it last said so. A Lumen opened during an
/// install finds it and steps aside (`UpdateStepAside`) instead of ending the install: 0.1.18's
/// tester reopened Lumen while the installer checked the release, and got "the app was started
/// again before it could be replaced" — in English, as an error, on the lock screen.
public struct UpdateInstallMarker: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var pid: Int32
    /// The app being replaced (standardized path).
    public var appPath: String
    /// The release being installed.
    public var version: String
    public var step: UpdateInstallStep
    public var startedAt: Date
    /// Rewritten at every step and while the installer waits: a marker that stopped changing is
    /// an installer that is gone.
    public var updatedAt: Date

    public init(pid: Int32, appPath: String, version: String, step: UpdateInstallStep, startedAt: Date, updatedAt: Date) {
        format = Self.currentFormat
        self.pid = pid
        self.appPath = appPath
        self.version = version
        self.step = step
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public static func read(from folder: URL) -> UpdateInstallMarker? {
        guard let json = try? Data(contentsOf: folder.appendingPathComponent(UpdateStaging.markerName)),
              (try? DocumentFormat.check(json, supported: currentFormat, what: UpdateStaging.markerName)) != nil else { return nil }
        return try? JSONCoding.decoder.decode(UpdateInstallMarker.self, from: json)
    }

    public func write(to folder: URL) throws {
        try SecureFile.write(JSONCoding.encoder.encode(self), to: folder.appendingPathComponent(UpdateStaging.markerName))
    }

    public static func remove(from folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(UpdateStaging.markerName))
    }
}

/// A Lumen opened during an install, which stepped aside, leaves this (`relaunch.json`): the person
/// wants Lumen, so the installer starts it at the end whatever came of the install — the new
/// version when it is in place (as always), the one there was when it is not — and brings its own
/// window to the front meanwhile.
public struct UpdateRelaunchWish: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var at: Date

    public init(at: Date) {
        format = Self.currentFormat
        self.at = at
    }

    public static func read(from folder: URL) -> UpdateRelaunchWish? {
        guard let json = try? Data(contentsOf: folder.appendingPathComponent(UpdateStaging.relaunchName)),
              (try? DocumentFormat.check(json, supported: currentFormat, what: UpdateStaging.relaunchName)) != nil else { return nil }
        return try? JSONCoding.decoder.decode(UpdateRelaunchWish.self, from: json)
    }

    public func write(to folder: URL) throws {
        try SecureFile.write(JSONCoding.encoder.encode(self), to: folder.appendingPathComponent(UpdateStaging.relaunchName))
    }

    public static func remove(from folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(UpdateStaging.relaunchName))
    }
}

/// What a Lumen being opened does about an install under way (docs/UPDATES.md §3): an app opened
/// while the installer works would end the install (the installer never swaps a bundle a process
/// runs from). So, before anything else of it runs, it looks in the staging folder: an installer
/// alive and at work for this very app — its marker fresh, its pid alive — and the app steps aside:
/// it asks for Lumen to be started at the end and exits. The installer's window says what is
/// happening, and the version installed is the one that opens.
///
/// Never on a stale word: a marker whose pid is gone, that has not changed for `heartbeatLimit`,
/// or whose installer has been at it longer than `longest` (something holds it — the app starts and
/// the installer gives up as before); never for another copy of the app; never in the version being
/// installed.
public enum UpdateStepAside {
    public enum Decision: Equatable, Sendable {
        /// Start as usual.
        case start
        /// An installer is at work for this app: ask for a relaunch, and exit.
        case stepAside
        /// A request this recent and no marker yet: its installer is starting. Look again in a
        /// moment (`waitForMarker`), then decide on what is there.
        case waitForInstaller
    }

    /// A marker not rewritten for this long belongs to an installer that is gone (it rewrites it
    /// at every step and every few seconds while it waits).
    public static let heartbeatLimit: TimeInterval = 120
    /// An installer at it longer than this is held by something (a process of the app that does not
    /// end): the app is not kept from the person any longer.
    public static let longest: TimeInterval = 180
    /// A request at most this old, without a marker yet: the helper the quit started is starting.
    public static let requestWindow: TimeInterval = 60
    /// How long an app waits for that helper's marker before it starts as usual.
    public static let waitForMarker: TimeInterval = 5

    public static func decide(marker: UpdateInstallMarker?, request: UpdateRequest?, appPath: String, build: BuildVersion,
                              now: Date, isAlive: (Int32) -> Bool) -> Decision {
        let path = URL(fileURLWithPath: appPath).standardizedFileURL.path
        func same(_ other: String) -> Bool { URL(fileURLWithPath: other).standardizedFileURL.path == path }
        let request = request.flatMap { same($0.appPath) ? $0 : nil }
        // This build is the release being installed, or newer: nothing to step aside for.
        if let request, let target = BuildVersion(request.item.build), target <= build { return .start }
        if let marker, same(marker.appPath) {
            let quiet = now.timeIntervalSince(marker.updatedAt)
            let working = now.timeIntervalSince(marker.startedAt)
            guard marker.pid > 0, quiet > -5, quiet < heartbeatLimit, working > -5, working < longest, isAlive(marker.pid) else {
                return .start
            }
            return .stepAside
        }
        if let request {
            let age = now.timeIntervalSince(request.requestedAt)
            if age > -5, age < requestWindow { return .waitForInstaller }
        }
        return .start
    }

    /// Whether a process `pid` exists. EPERM — it exists, and this process may not signal it (the
    /// sandbox) — counts as alive.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
