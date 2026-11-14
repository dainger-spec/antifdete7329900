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
///                             hardware-model.bin, machine-id.bin, share/ (settings in, status out),
///                             tools/ (the boot script, shared read-only)
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

        public init(directory: URL) {
            self.directory = directory
        }

        public var disk: URL { directory.appendingPathComponent("disk.img") }
        public var auxiliaryStorage: URL { directory.appendingPathComponent("aux.img") }
        public var hardwareModel: URL { directory.appendingPathComponent("hardware-model.bin") }
        public var machineIdentifier: URL { directory.appendingPathComponent("machine-id.bin") }
        public var share: URL { directory.appendingPathComponent("share", isDirectory: true) }
        public var settings: URL { share.appendingPathComponent(VMGuestSettings.fileName) }
        public var status: URL { share.appendingPathComponent(VMGuestSettings.statusFileName) }
        /// The folder the machine is given read-only (`VMGuestSettings.toolsShareTag`): the boot
        /// script a machine takes a newer copy of itself from. The guest cannot write it, as it
        /// can the share — and what is taken from it runs as root in the guest.
        public var tools: URL { directory.appendingPathComponent("tools", isDirectory: true) }

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
    ///
    /// `ownOnly`: only what removing the folder would give back. A profile's disk is a clone of the
    /// base's and shares most of its blocks with it; counted whole, every machine would seem to
    /// take the base's twenty gigabytes again.
    public static func allocatedSize(of directory: URL, ownOnly: Bool = false) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            #if canImport(Darwin)
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                let allocated = Int64(values.totalFileAllocatedSize ?? 0)
                total += ownOnly ? min(allocated, privateSize(of: url) ?? allocated) : allocated
            }
            #else
            total += fileSize(url)
            #endif
        }
        return total
    }

    #if canImport(Darwin)
    /// The file's blocks that no other file shares — what deleting it would free (APFS keeps a
    /// clone's unchanged blocks once for both files). Nil where the volume does not say.
    static func privateSize(of url: URL) -> Int64? {
        // What `getattrlist` writes for this request: its length, which attributes it returned,
        // then the size — each aligned to four bytes, which is how these three lie anyway.
        struct Reply {
            var length: UInt32 = 0
            var returned = attribute_set_t()
            var size: off_t = 0
        }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var reply = Reply()
        let status = getattrlist(url.path, &request, &reply, MemoryLayout<Reply>.size, UInt32(FSOPT_ATTR_CMN_EXTENDED))
        guard status == 0, reply.returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0, reply.size >= 0 else { return nil }
        return Int64(reply.size)
    }
    #endif
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
///
/// 2: the appearance, the accent colour, the computer's own name, Safari not opened; and the boot
/// script takes a newer copy of itself from the shared folder, so that later versions need no
/// visit to the base system.
///
/// 3: Lumen's desktop picture.
///
/// 4: the picture is looked at again while a machine's first start settles, and what came of it
/// is said back in the status file.
///
/// 5: the clock and the week's first day, the Dock, the scroll bars, more pages at start.
///
/// 6: the shared folder is told from a folder of its name left behind, and handed on to a newer
/// copy of the script; what the system prints beside the wallpaper's answer is not the answer.
///
/// 7: a newer copy of the script is taken only from the tools' folder, which the Mac shares
/// read-only (`VMGuestSettings.toolsShareTag`), not from the shared folder, which anything in
/// the machine can write; the pictures are kept in a folder of root's; what the script writes into
/// the shared folder is moved into place, and a picture there is read as the person.
public enum VMGuestTools {
    public static let version = 7
    /// From this version on an installed boot script takes a newer copy of itself at a machine's
    /// start: a base with tools this new needs nothing done to it for a later version's settings.
    public static let updatesItselfFrom = 2

    /// Whether a base whose tools are `installed` must have them installed again (Install Lumen
    /// Tools, in the base) before the settings the boot script applies work in its machines.
    public static func mustBeInstalledAgain(_ installed: Int?) -> Bool {
        (installed ?? version) < updatesItselfFrom
    }
}
