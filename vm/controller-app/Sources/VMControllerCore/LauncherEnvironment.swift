import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host-side lookups shared by the CLI and the app.
public enum LauncherEnvironment {
    /// Where Homebrew puts `tart` (Apple Silicon, then Intel). GUI apps start
    /// with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which has neither.
    public static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// `existing` PATH with `prepending` in front and the Homebrew and system
    /// directories guaranteed present; duplicates removed, order kept.
    public static func searchPath(_ existing: String?, prepending: [String] = []) -> String {
        var seen = Set<String>()
        let candidates = prepending
            + (existing ?? "").split(separator: ":").map(String.init)
            + homebrewDirectories
            + systemDirectories
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    public static func findExecutable(_ name: String, searchPath: String) -> String? {
        for directory in searchPath.split(separator: ":") {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Where `vm/controller/tart-prototype.sh` may be, most specific first:
    /// $PB_TART_SCRIPT, the app bundle's Resources, the repo root or
    /// vm/controller-app as working directory, and relative to an executable
    /// in vm/controller-app/.build/<config>/.
    public static func scriptCandidates(environment: [String: String], resourceDirectory: URL?,
                                        currentDirectory: String, executablePath: String) -> [String] {
        var candidates: [String] = []
        if let override = environment["PB_TART_SCRIPT"], !override.isEmpty {
            candidates.append(override)
        }
        if let resourceDirectory {
            candidates.append(resourceDirectory.appendingPathComponent("vm/controller/tart-prototype.sh").path)
        }
        candidates.append(currentDirectory + "/vm/controller/tart-prototype.sh")
        candidates.append(currentDirectory + "/../controller/tart-prototype.sh")
        let executable = URL(fileURLWithPath: executablePath,
                             relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
        candidates.append(executable.deletingLastPathComponent()
            .appendingPathComponent("../../../controller/tart-prototype.sh").path)
        var seen = Set<String>()
        return candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
    }

    public static func locateScript(in candidates: [String]) -> String? {
        candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Where Tart keeps its VMs: $TART_HOME/vms, else ~/.tart/vms.
    public static func tartVMsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["TART_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".tart")
        return home.appendingPathComponent("vms", isDirectory: true)
    }

    /// The agent files tart-prototype.sh copies into the VM (from ../agent).
    public static let agentFiles = ["pbagent.py", "binarycookies.py", "install.sh",
                                    "com.privacybrowser.agent.plist.template"]

    /// Agent files missing next to `script` (empty when the layout is intact).
    public static func missingAgentFiles(forScript script: String) -> [String] {
        let agentDirectory = URL(fileURLWithPath: script).deletingLastPathComponent()
            .appendingPathComponent("../agent").standardizedFileURL
        return agentFiles.filter {
            !FileManager.default.isReadableFile(atPath: agentDirectory.appendingPathComponent($0).path)
        }
    }

    /// The in-guest scripts tart-prototype.sh pipes over SSH (from ..).
    public static let guestScripts = ["identity.sh", "guest-proxy.sh", "guest-kiosk.sh"]

    /// Guest scripts missing next to `script` (empty when the layout is intact).
    public static func missingGuestScripts(forScript script: String) -> [String] {
        let directory = URL(fileURLWithPath: script).deletingLastPathComponent()
            .appendingPathComponent("..").standardizedFileURL
        return guestScripts.filter {
            !FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// A free TCP port on 127.0.0.1 for the host end of the SSH tunnel.
    public static func freeLocalPort() -> UInt16? {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Writes an SSH_ASKPASS helper that answers ssh's password prompt with
    /// $SSHPASS (tart-prototype.sh exports it, default "admin"). A GUI app has
    /// no terminal for ssh to prompt on, and sshpass is usually not installed.
    public static func writeAskPass(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ssh-askpass.sh")
        let script = """
        #!/bin/sh
        # Answers ssh's password prompt for the VM (see LauncherEnvironment.writeAskPass).
        printf '%s\\n' "${SSHPASS:-admin}"

        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// What tart-prototype.sh sets inside the guest for a profile.
    public struct GuestIdentity: Equatable, Sendable {
        /// Seeds the hostname (identity.sh); the profile id, not its name, so
        /// nothing personal shows up on the network.
        public var seed: String
        public var timeZone: String?
        public var language: String?

        public init(seed: String, timeZone: String? = nil, language: String? = nil) {
            self.seed = seed
            self.timeZone = timeZone
            self.language = language
        }

        public init(profile: Profile) {
            self.init(seed: profile.id, timeZone: profile.timeZone, language: profile.language)
        }
    }

    /// Environment for running tart-prototype.sh without a terminal.
    ///
    /// `network` picks TART_NET/SOFTNET_ALLOW: a profile with a proxy runs
    /// fail-closed over softnet; the plain dev launch (nil) uses shared NAT so
    /// `tart ip` resolves and the host can reach the VM. `cookiesFile`, when
    /// set, is POSTed to the agent's /cookies before navigating. `showWindow`
    /// false (the default) runs the VM headless, so the guest desktop never
    /// pops up on the host. `externalVM`: the app already runs the VM in its
    /// own window (VM_EXTERNAL=1). `kiosk`: hide the guest's desktop around
    /// Safari. `identity`: hostname / time zone / language for the guest.
    public static func scriptEnvironment(base: [String: String], tartPath: String, askPass: URL,
                                         localPort: UInt16?, network: NetworkPolicy? = nil,
                                         cookiesFile: String? = nil, showWindow: Bool = false,
                                         proxyURL: String? = nil, identity: GuestIdentity? = nil,
                                         kiosk: Bool = false, externalVM: Bool = false) -> [String: String] {
        var environment = base
        let tartDirectory = URL(fileURLWithPath: tartPath).deletingLastPathComponent().path
        environment["PATH"] = searchPath(base["PATH"], prepending: [tartDirectory])
        let (tartNet, softnetAllow) = (network ?? .openNAT).controllerEnv
        environment["TART_NET"] = tartNet
        if let softnetAllow { environment["SOFTNET_ALLOW"] = softnetAllow } else { environment["SOFTNET_ALLOW"] = nil }
        environment["SSH_ASKPASS"] = askPass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        if let localPort { environment["LOCAL_PORT"] = String(localPort) }
        if let cookiesFile { environment["COOKIES_FILE"] = cookiesFile } else { environment["COOKIES_FILE"] = nil }
        environment["VM_HEADLESS"] = showWindow ? "0" : "1"
        // Set as the guest's system proxy (vm/guest-proxy.sh); without it the
        // fail-closed VM reaches nothing. Never inherited from the app's env.
        environment["PROXY_URL"] = proxyURL
        environment["SOFTNET_FAIL_CLOSED"] = nil
        environment["IDENTITY_PROFILE"] = identity?.seed
        environment["IDENTITY_TIMEZONE"] = identity?.timeZone
        environment["IDENTITY_LANGUAGE"] = identity?.language
        environment["KIOSK"] = kiosk ? "1" : nil
        environment["VM_EXTERNAL"] = externalVM ? "1" : nil
        // These only make sense for a terminal user.
        environment["KEEP_VM"] = nil
        environment["SHOT"] = nil
        return environment
    }
}
