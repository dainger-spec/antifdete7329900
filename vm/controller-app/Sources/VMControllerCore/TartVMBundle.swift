import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A Tart VM directory (~/.tart/vms/<name>/), read so the app can run the VM
/// itself with Virtualization.framework and show its display in its own
/// window. Only what running needs is parsed; Tart stays the owner of the
/// format (clone/set/pull/ip keep using `tart`).
///
/// Layout: config.json, disk.img, nvram.bin ("standalone"). A "stacked" VM
/// (`tart clone --stacked`: manifest.json + overlay.asif) is not supported
/// here; the app runs those with `tart run` instead.
public struct TartVMBundle: Equatable, Sendable {
    public let directory: URL
    public let config: TartVMConfig

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var diskURL: URL { directory.appendingPathComponent("disk.img") }
    public var nvramURL: URL { directory.appendingPathComponent("nvram.bin") }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .missing(let what): "VM is incomplete: \(what) is missing"
            case .unsupported(let why): "VM can't run inside the app: \(why)"
            }
        }
    }

    public static func load(name: String, vmsDirectory: URL) throws -> TartVMBundle {
        try load(directory: vmsDirectory.appendingPathComponent(name, isDirectory: true))
    }

    /// Reads config.json and checks the files a standalone macOS VM needs.
    public static func load(directory: URL) throws -> TartVMBundle {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else { throw LoadError.missing("config.json") }
        let config: TartVMConfig
        do {
            config = try JSONDecoder().decode(TartVMConfig.self, from: data)
        } catch {
            throw LoadError.unsupported("config.json: \(error)")
        }
        let bundle = TartVMBundle(directory: directory, config: config)
        let files = FileManager.default
        if files.fileExists(atPath: bundle.manifestURL.path) { throw LoadError.unsupported("stacked disk") }
        guard config.os == "darwin" else { throw LoadError.unsupported("not a macOS VM (\(config.os))") }
        guard config.ecidData != nil, config.hardwareModelData != nil else {
            throw LoadError.unsupported("no machine identifier / hardware model")
        }
        for (url, name) in [(bundle.diskURL, "disk.img"), (bundle.nvramURL, "nvram.bin")]
        where !files.fileExists(atPath: url.path) {
            throw LoadError.missing(name)
        }
        return bundle
    }
}

/// The parts of Tart's config.json the app uses.
public struct TartVMConfig: Decodable, Equatable, Sendable {
    public struct Display: Decodable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// "pt" or "px"; nil means points for macOS VMs.
        public var unit: String?
    }

    public var version: Int
    public var os: String
    public var cpuCount: Int
    public var memorySize: UInt64
    public var macAddress: String
    public var display: Display
    /// Base64 of VZMacMachineIdentifier.dataRepresentation.
    public var ecid: String?
    /// Base64 of VZMacHardwareModel.dataRepresentation.
    public var hardwareModel: String?
    public var diskFormat: String

    enum CodingKeys: String, CodingKey {
        case version, os, cpuCount, memorySize, macAddress, display, ecid, hardwareModel, diskFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        os = try container.decodeIfPresent(String.self, forKey: .os) ?? "darwin"
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memorySize = try container.decode(UInt64.self, forKey: .memorySize)
        macAddress = try container.decode(String.self, forKey: .macAddress)
        display = try container.decodeIfPresent(Display.self, forKey: .display)
            ?? Display(width: 1024, height: 768, unit: nil)
        ecid = try container.decodeIfPresent(String.self, forKey: .ecid)
        hardwareModel = try container.decodeIfPresent(String.self, forKey: .hardwareModel)
        diskFormat = try container.decodeIfPresent(String.self, forKey: .diskFormat) ?? "raw"
    }

    public var ecidData: Data? { ecid.flatMap { Data(base64Encoded: $0) } }
    public var hardwareModelData: Data? { hardwareModel.flatMap { Data(base64Encoded: $0) } }
}

/// Tart's "this VM is running" marker: a POSIX write lock (fcntl F_SETLK) on
/// config.json, held by `tart run` for the VM's lifetime. `tart ip`, `tart list`
/// and `tart run` check it, so holding it while the app runs the VM keeps
/// them working (and stops a second `tart run` of the same VM).
///
/// POSIX locks belong to the process and are dropped when ANY descriptor of
/// the file in this process is closed — read config.json before locking and
/// never open it again while the lock is held.
public final class VMRunLock: @unchecked Sendable {
    public let url: URL
    private let fd: Int32
    private var held = false

    public init(url: URL) throws {
        self.url = url
        fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    deinit {
        if held { _ = unlock() }
        close(fd)
    }

    /// Takes the lock; false if another process (e.g. `tart run`) holds it.
    public func tryLock() throws -> Bool {
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        if fcntl(fd, F_SETLK, &lock) == 0 {
            held = true
            return true
        }
        if errno == EAGAIN || errno == EACCES { return false }
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    @discardableResult
    public func unlock() -> Bool {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        held = false
        return fcntl(fd, F_SETLK, &lock) == 0
    }

    /// PID of another process holding the lock, or nil (own locks don't count).
    public func holder() -> pid_t? {
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }
}

/// The softnet helper as the app starts it for an in-app VM — the same CLI
/// Tart uses: the VM's end of a datagram socketpair on stdin.
public enum SoftnetCommand {
    /// Arguments for `softnet` (after the executable), or nil when the policy
    /// doesn't use softnet (NAT).
    public static func arguments(macAddress: String, policy: NetworkPolicy) -> [String]? {
        let base = ["--vm-fd", "0", "--vm-mac-address", macAddress]
        // Default deny, the proxy's /32 back (longest prefix wins), and only
        // host→VM connections (SSH) — see NetworkPolicy and docs/PROFILES.md.
        switch policy {
        case .proxyOnly(let cidr):
            return base + ["--block", "0.0.0.0/0", "--allow", "\(cidr),\(NetworkPolicy.hostInbound)"]
        case .isolated:
            return base + ["--block", "0.0.0.0/0", "--allow", NetworkPolicy.hostInbound]
        case .openNAT:
            return nil
        }
    }
}

/// Whether softnet can enforce a fail-closed policy on this host.
public enum SoftnetReadiness: Equatable, Sendable {
    case ready(path: String)
    case missing
    /// Neither setuid-root nor runnable with passwordless sudo.
    case needsRoot(path: String)
    /// No stateful "in TARGET" rules (softnet < 0.22).
    case tooOld(path: String)

    /// A user-facing (Russian) explanation, nil when ready.
    public var problem: String? {
        switch self {
        case .ready: nil
        case .missing:
            "Для профиля с прокси или без интернета нужен softnet: brew install cirruslabs/cli/softnet"
        case .needsRoot(let path):
            "softnet нужны права root. Один раз выполните в Терминале: "
                + "sudo sh -c 'chown root \"\(path)\" && chmod u+s \"\(path)\"'"
        case .tooOld:
            "softnet слишком старый для сети «только через прокси» (нужен 0.22+): brew upgrade cirruslabs/cli/softnet"
        }
    }

    /// Checks PATH for softnet, that it runs as root, and that it knows
    /// stateful rules (its --help mentions "in TARGET").
    public static func check(searchPath: String, environment: [String: String]) async -> SoftnetReadiness {
        guard let found = LauncherEnvironment.findExecutable("softnet", searchPath: searchPath) else { return .missing }
        let path = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let setuidRoot = owner == 0 && mode & Int(S_ISUID) != 0
        if !setuidRoot {
            let sudo = LauncherEnvironment.findExecutable("sudo", searchPath: searchPath) ?? "/usr/bin/sudo"
            let viaSudo = try? await GroupProcess.run(sudo, ["-n", path, "--help"], environment: environment, timeout: 15)
            if viaSudo?.code != 0 { return .needsRoot(path: path) }
        }
        let help = try? await GroupProcess.run(path, ["--help"], environment: environment, timeout: 15)
        guard (help?.lines ?? []).contains(where: { $0.contains("in TARGET") }) else { return .tooOld(path: path) }
        return .ready(path: path)
    }
}
