import Foundation

/// Where the virtual machines are on disk, and what state the base system is in.
///
/// ```
/// <library>/
///   base.json                 VMBaseInfo: which macOS, and how far its setup got
///   base/                     the installed macOS every profile's machine is a clone of
///     disk.img                the system's disk (sparse)
///     aux.img                 the machine's firmware variables (Apple's auxiliary storage)
///     hardware-model.bin      the virtual Mac model the system was installed for
///     machine-id.bin          the base's own identifier (a profile's machine gets another)
///     share/                  the folder the guest sees during setup: the tools' installer, its status
///   machines/<profile id>/    one per profile: disk.img (a copy-on-write clone), aux.img,
///                             hardware-model.bin, machine-id.bin, share/ (settings in, status out)
///   downloads/
///     restore.ipsw.partial    Apple's restore image while it is fetched; restore.ipsw when whole
///     restore.json            VMDownloadState: what is being fetched, and how to go on with it
/// ```
///
/// Beside the vault, not in it: the disks are tens of gigabytes that macOS in the guest writes all
/// the time, and are **not** encrypted by the vault (docs/VM.md: what that means, and FileVault in
/// the guest as the way to have it). The profiles' own settings — names, proxies — are in the vault
/// (`VMProfiles`). The library is left out of Time Machine by the app.
public struct VMLibrary: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<vault folder>/VirtualMachines`.
    public init(vaultDirectory: URL) {
        root = vaultDirectory.appendingPathComponent("VirtualMachines", isDirectory: true)
    }

    public var baseInfoURL: URL { root.appendingPathComponent("base.json") }
    public var baseDirectory: URL { root.appendingPathComponent("base", isDirectory: true) }
    public var machinesDirectory: URL { root.appendingPathComponent("machines", isDirectory: true) }
    public var downloadsDirectory: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var restoreImageURL: URL { downloadsDirectory.appendingPathComponent("restore.ipsw") }
    public var partialRestoreImageURL: URL { downloadsDirectory.appendingPathComponent("restore.ipsw.partial") }
    public var downloadStateURL: URL { downloadsDirectory.appendingPathComponent("restore.json") }

    public func machineDirectory(for id: UUID) -> URL {
        machinesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The files of a machine (the base's, or a profile's), by what they are.
    public struct MachineFiles: Equatable, Sendable {
        public let directory: URL
        public var disk: URL { directory.appendingPathComponent("disk.img") }
        public var auxiliaryStorage: URL { directory.appendingPathComponent("aux.img") }
        public var hardwareModel: URL { directory.appendingPathComponent("hardware-model.bin") }
        public var machineIdentifier: URL { directory.appendingPathComponent("machine-id.bin") }
        public var share: URL { directory.appendingPathComponent("share", isDirectory: true) }
        public var settings: URL { share.appendingPathComponent(VMGuestSettings.fileName) }
        public var status: URL { share.appendingPathComponent(VMGuestSettings.statusFileName) }

        /// Everything a machine needs to start is there.
        public var isComplete: Bool {
            [disk, auxiliaryStorage, hardwareModel, machineIdentifier].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    public var base: MachineFiles { MachineFiles(directory: baseDirectory) }
    public func machine(for id: UUID) -> MachineFiles { MachineFiles(directory: machineDirectory(for: id)) }

    // MARK: The base's state

    /// What is known of the base system; nil before anything was installed. A file that does not
    /// read is taken as none — the base then has to be set up again, which loses no profile (each
    /// machine has its own disk).
    public func baseInfo() -> VMBaseInfo? {
        guard let data = try? Data(contentsOf: baseInfoURL) else { return nil }
        return try? JSONCoding.decoder.decode(VMBaseInfo.self, from: data)
    }

    public func saveBaseInfo(_ info: VMBaseInfo) throws {
        try SecureFile.ensureDirectory(root)
        try SecureFile.write(try JSONCoding.encoder.encode(info), to: baseInfoURL)
    }

    /// How far the setup of the machines has got on this Mac, from what is on disk.
    public func setupState() -> VMSetupState {
        if let info = baseInfo(), base.isComplete {
            return info.stage == .ready ? .ready(info) : .needsGuestSetup(info)
        }
        if FileManager.default.fileExists(atPath: restoreImageURL.path) { return .downloaded }
        if let state = downloadState() {
            let have = Self.fileSize(partialRestoreImageURL)
            return .downloading(have: have, of: state.expectedLength)
        }
        return .none
    }

    // MARK: The download's state

    public func downloadState() -> VMDownloadState? {
        guard let data = try? Data(contentsOf: downloadStateURL) else { return nil }
        return try? JSONCoding.decoder.decode(VMDownloadState.self, from: data)
    }

    public func saveDownloadState(_ state: VMDownloadState) throws {
        try SecureFile.ensureDirectory(downloadsDirectory)
        try SecureFile.write(try JSONCoding.encoder.encode(state), to: downloadStateURL)
    }

    // MARK: Sizes

    /// The file's length as the guest sees it; 0 when it is not there.
    public static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// What the files under `directory` take on disk — for a sparse disk, what was written, not
    /// its length — where the system says (`totalFileAllocatedSize`); their lengths elsewhere.
    public static func allocatedSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            #if canImport(Darwin)
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
            #else
            total += fileSize(url)
            #endif
        }
        return total
    }
}

/// The base system: which macOS it is, and whether its one-time setup inside the guest is done.
public struct VMBaseInfo: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        /// macOS is installed; the person has not finished its first-run setup and the tools yet.
        case installed
        /// Set up: profiles' machines are cloned from it.
        case ready
    }

    public var stage: Stage
    /// "26.1", "25B78".
    public var version: String
    public var build: String
    public var installedAt: Date
    /// The guest tools' version the setup installed (`VMGuestTools.version`).
    public var toolsVersion: Int?

    public init(stage: Stage, version: String, build: String, installedAt: Date = Date(), toolsVersion: Int? = nil) {
        self.stage = stage
        self.version = version
        self.build = build
        self.installedAt = installedAt
        self.toolsVersion = toolsVersion
    }
}

/// Where the setup of the machines stands on this Mac.
public enum VMSetupState: Equatable, Sendable {
    /// Nothing yet.
    case none
    /// The restore image is partly fetched (`of`: its whole length, when known).
    case downloading(have: Int64, of: Int64?)
    /// The restore image is whole; macOS is not installed yet.
    case downloaded
    /// macOS is installed; its first-run setup and the tools are still to do, in the guest.
    case needsGuestSetup(VMBaseInfo)
    case ready(VMBaseInfo)
}

/// The version of the tools the setup puts into the guest (Resources/VMGuest). Raised when the
/// boot script changes in a way an installed copy must follow.
public enum VMGuestTools {
    public static let version = 1
}
