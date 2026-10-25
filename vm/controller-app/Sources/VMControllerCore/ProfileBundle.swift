import Foundation

/// What an exported profile carries, besides its VM: enough to recreate it on
/// another machine, without anything host-specific (no id — import mints a new
/// one).
public struct ProfileManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var proxy: String?
    public var baseImage: String
    public var clipboardShared: Bool
    public var cookieCount: Int
    public var exportedAt: Date

    public init(from profile: Profile, exportedAt: Date = Date()) {
        version = Self.currentVersion
        name = profile.name
        proxy = profile.proxy
        baseImage = profile.baseImage
        clipboardShared = profile.clipboardShared
        cookieCount = profile.cookieCount
        self.exportedAt = exportedAt
    }
}

public enum ProfileBundleError: Error, CustomStringConvertible {
    case tarFailed(String)
    case badArchive(String)

    public var description: String {
        switch self {
        case .tarFailed(let m): "tar failed: \(m)"
        case .badArchive(let m): "not a valid profile archive: \(m)"
        }
    }
}

/// Export a profile (settings + cookies + its Tart VM) to one portable
/// `.tar.gz`, and import such an archive on another machine. Uses `tar` (on
/// both macOS and Linux) through GroupProcess, so it is testable off a Mac with
/// a stub VM directory.
public enum ProfileBundle {
    static let manifestName = "manifest.json"
    static let cookiesName = "cookies.json"

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Write `profile` to `destination` (.tar.gz). Includes the VM directory if
    /// present; always includes the manifest and, when present, the cookies.
    public static func export(profile: Profile, store: ProfileStore, vmsDirectory: URL,
                              to destination: URL, timeout: TimeInterval = 1800) async throws {
        // Use the store's current copy, so a stale caller-held Profile (e.g. an
        // out-of-date cookieCount) can't put wrong data in the manifest.
        let profile = (try? store.get(profile.id)) ?? profile
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("pb-export-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try encoder().encode(ProfileManifest(from: profile)).write(to: staging.appendingPathComponent(manifestName))

        var stagedFiles = [manifestName]
        let cookies = store.cookiesURL(for: profile)
        if fm.fileExists(atPath: cookies.path) {
            try fm.copyItem(at: cookies, to: staging.appendingPathComponent(cookiesName))
            stagedFiles.append(cookiesName)
        }

        var args = ["-czf", destination.path, "-C", staging.path] + stagedFiles
        let vmDir = vmsDirectory.appendingPathComponent(profile.vmName)
        if fm.fileExists(atPath: vmDir.path) {
            // Second -C root: adds the VM under its own name without a big copy.
            args += ["-C", vmsDirectory.path, profile.vmName]
        }
        let result = try await GroupProcess.run("/usr/bin/tar", args, environment: processEnv(), timeout: timeout)
        guard result.code == 0 else { throw ProfileBundleError.tarFailed(result.lines.last ?? "exit \(result.code ?? -1)") }
    }

    /// Import `archive` into `store`, placing the VM under `vmsDirectory`.
    /// Returns the new profile (with a fresh id and a non-clashing name).
    @discardableResult
    public static func importArchive(_ archive: URL, store: ProfileStore, vmsDirectory: URL,
                                     timeout: TimeInterval = 1800) async throws -> Profile {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("pb-import-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let extract = try await GroupProcess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", temp.path],
                                                 environment: processEnv(), timeout: timeout)
        guard extract.code == 0 else { throw ProfileBundleError.tarFailed(extract.lines.last ?? "extract failed") }

        let manifestURL = temp.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder().decode(ProfileManifest.self, from: data) else {
            throw ProfileBundleError.badArchive("missing or unreadable \(manifestName)")
        }

        let profile = try addWithUniqueName(manifest, store: store)

        // Cookies, if the archive carried them.
        let cookiesSrc = temp.appendingPathComponent(cookiesName)
        if fm.fileExists(atPath: cookiesSrc.path) {
            let dir = store.directory(for: profile)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: store.cookiesURL(for: profile))
            try fm.copyItem(at: cookiesSrc, to: store.cookiesURL(for: profile))
            try store.update(profile.id) { $0.cookieCount = manifest.cookieCount }
        }

        // The VM directory is the one extracted entry that isn't the manifest or
        // cookies file; move it under the new profile's VM name.
        let entries = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        if let vmSrc = entries.first(where: { ![manifestName, cookiesName].contains($0.lastPathComponent) }) {
            try fm.createDirectory(at: vmsDirectory, withIntermediateDirectories: true)
            let dest = vmsDirectory.appendingPathComponent(profile.vmName)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: vmSrc, to: dest)
        }
        return try store.get(profile.id) ?? profile
    }

    /// Add the manifest's profile, suffixing the name if it's already taken.
    private static func addWithUniqueName(_ manifest: ProfileManifest, store: ProfileStore) throws -> Profile {
        for attempt in 0..<100 {
            let name = attempt == 0 ? manifest.name : "\(manifest.name) (импорт \(attempt))"
            do {
                return try store.add(Profile(name: name, proxy: manifest.proxy,
                                             baseImage: manifest.baseImage,
                                             clipboardShared: manifest.clipboardShared))
            } catch ProfileError.duplicateName {
                continue
            }
        }
        throw ProfileBundleError.badArchive("could not find a free name for \(manifest.name)")
    }

    private static func processEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LauncherEnvironment.searchPath(env["PATH"])
        return env
    }
}
