import Foundation

/// What an exported profile carries, besides its VM: enough to recreate it on
/// another machine, without anything host-specific (no id — import mints a new
/// one).
public struct ProfileManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var name: String
    public var proxy: String?
    public var baseImage: String
    public var clipboardShared: Bool
    public var cookieCount: Int
    public var exportedAt: Date
    // Version 2. Missing in older archives (decoded as nil).
    /// Without it an `.offline` profile — or `.proxy` with no usable proxy —
    /// would come back as `.direct`, i.e. open internet.
    public var network: NetworkMode?
    public var timeZone: String?
    public var language: String?
    public var uniqueIdentity: Bool?

    public init(from profile: Profile, exportedAt: Date = Date()) {
        version = Self.currentVersion
        name = profile.name
        proxy = profile.proxy
        baseImage = profile.baseImage
        clipboardShared = profile.clipboardShared
        cookieCount = profile.cookieCount
        self.exportedAt = exportedAt
        network = profile.network
        timeZone = profile.timeZone
        language = profile.language
        uniqueIdentity = profile.uniqueIdentity
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
    ///
    /// The archive is untrusted: only regular files are taken (a symlinked
    /// cookies.json would make the launch send a host file into the VM), the
    /// cookies are re-parsed and recounted, and the VM is the directory that
    /// holds a config.json. On any failure nothing is left behind. The VM
    /// keeps its source's MAC address; give it a new one before running it
    /// next to the source (`tart set <vm> --random-mac`).
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

        // Validate everything before touching the store.
        let cookiesSrc = temp.appendingPathComponent(cookiesName)
        var cookies: Data?
        var cookieCount = 0
        if fm.fileExists(atPath: cookiesSrc.path) || isSymlink(cookiesSrc) {
            guard isRegularFile(cookiesSrc), let text = try? String(contentsOf: cookiesSrc, encoding: .utf8),
                  let parsed = try? CookieImport.parse(text) else {
                throw ProfileBundleError.badArchive("\(cookiesName) is not a regular cookie file")
            }
            cookies = try CookieImport.serialize(parsed)
            cookieCount = parsed.count
        }
        let entries = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        let vmCandidates = entries.filter {
            ![manifestName, cookiesName].contains($0.lastPathComponent) && !isSymlink($0)
                && isRegularFile($0.appendingPathComponent("config.json"))
        }
        guard vmCandidates.count <= 1 else { throw ProfileBundleError.badArchive("more than one VM") }

        let profile = try addWithUniqueName(manifest, store: store)
        var movedVM: URL?
        do {
            if let cookies {
                try fm.createDirectory(at: store.directory(for: profile), withIntermediateDirectories: true)
                try cookies.write(to: store.cookiesURL(for: profile), options: .atomic)
            }
            try store.update(profile.id) { $0.cookieCount = cookies == nil ? 0 : cookieCount }
            if let vmSrc = vmCandidates.first {
                try fm.createDirectory(at: vmsDirectory, withIntermediateDirectories: true)
                let dest = vmsDirectory.appendingPathComponent(profile.vmName)
                guard !fm.fileExists(atPath: dest.path) else {
                    throw ProfileBundleError.badArchive("a VM named \(profile.vmName) already exists")
                }
                try fm.moveItem(at: vmSrc, to: dest)
                movedVM = dest
            }
        } catch {
            // Roll back: no profile without its VM, no stray files.
            if let movedVM { try? fm.removeItem(at: movedVM) }
            try? store.remove(profile.id)
            throw error
        }
        return try store.get(profile.id) ?? profile
    }

    /// lstat-based: a symlink is neither a regular file nor followed.
    static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Add the manifest's profile, suffixing the name if it's already taken.
    private static func addWithUniqueName(_ manifest: ProfileManifest, store: ProfileStore) throws -> Profile {
        for attempt in 0..<100 {
            let name = attempt == 0 ? manifest.name : "\(manifest.name) (импорт \(attempt))"
            do {
                return try store.add(Profile(name: name, proxy: manifest.proxy,
                                             baseImage: manifest.baseImage,
                                             clipboardShared: manifest.clipboardShared,
                                             network: manifest.network, timeZone: manifest.timeZone,
                                             language: manifest.language, uniqueIdentity: manifest.uniqueIdentity))
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
