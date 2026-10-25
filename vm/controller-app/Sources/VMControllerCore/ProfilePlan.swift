import Foundation

/// How a profile's VM reaches the network.
///
/// Fail-closed: the VM gets internet ONLY through its proxy. Implemented with
/// Tart's softnet backend (`--net-softnet`) plus an egress allowlist
/// (`--net-softnet-allow <CIDR>`) restricted to the proxy. With no proxy the
/// allowlist is loopback-only, so the VM has no route off the host at all —
/// it fails closed rather than open. Bridged/NAT (no allowlist) is NOT
/// fail-closed and is only for development. See docs/PROFILES.md.
public enum NetworkPolicy: Equatable, Sendable {
    /// Egress only to the proxy (fail-closed). `allowCIDR` is the proxy's IP/CIDR.
    case proxyOnly(allowCIDR: String)
    /// No egress at all (fail-closed, no proxy configured).
    case isolated
    /// Tart's default NAT — open internet. Development only.
    case openNAT

    /// `tart run` network flags for this policy.
    public var runArgs: [String] {
        switch self {
        case .proxyOnly(let cidr): ["--net-softnet", "--net-softnet-allow", cidr]
        case .isolated: ["--net-softnet", "--net-softnet-allow", "127.0.0.1/32"]
        case .openNAT: []
        }
    }

    /// How tart-prototype.sh takes this policy: (TART_NET, SOFTNET_ALLOW?).
    public var controllerEnv: (tartNet: String, softnetAllow: String?) {
        switch self {
        case .proxyOnly(let cidr): ("softnet", cidr)
        case .isolated: ("softnet", "127.0.0.1/32")
        case .openNAT: ("shared", nil)
        }
    }

    /// The fail-closed policy for a profile's proxy string. A proxy given as an
    /// IP becomes a /32 allow; a hostname can't go in softnet's IP allowlist, so
    /// callers must resolve it first (ProxyEndpoint.allowCIDR is nil then).
    public static func failClosed(proxy: String?) -> NetworkPolicy {
        // No proxy, an unparseable proxy, or a hostname proxy that isn't yet
        // resolved to an IP: all fail closed (no egress) rather than open.
        guard let proxy, let cidr = ProxyEndpoint(proxy)?.allowCIDR else { return .isolated }
        return .proxyOnly(allowCIDR: cidr)
    }
}

/// A parsed proxy URL: scheme://[user:pass@]host[:port].
public struct ProxyEndpoint: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init?(_ raw: String) {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h", "socks4"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = components.port
    }

    public var isIPv4: Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { 0...255 ~= $0 } ?? false }
    }

    /// The softnet allow CIDR for this proxy, or nil if the host is a name that
    /// must be resolved to an IP first.
    public var allowCIDR: String? { isIPv4 ? "\(host)/32" : nil }
}

/// Maps profile lifecycle steps to exact `tart` argument vectors (without the
/// leading executable). Pure, so the sequences can be unit-tested; the app/CLI
/// runs them with GroupProcess. Snapshots are clones — Tart has no snapshot
/// command, and a VM's disk persists across run/stop (that IS the saved state).
public enum ProfilePlan {
    /// Create a profile: clone the base image into the profile's own VM.
    public static func create(_ profile: Profile) -> [String] {
        ["clone", profile.baseImage, profile.vmName]
    }

    /// Pull the latest of a base image into Tart's cache.
    public static func pullBase(_ image: String) -> [String] {
        ["pull", image]
    }

    /// Size the VM (while stopped).
    public static func size(_ profile: Profile, memoryMiB: Int, cpu: Int) -> [String] {
        ["set", profile.vmName, "--memory", String(memoryMiB), "--cpu", String(cpu)]
    }

    /// Run the profile from its persistent disk (= "from the snapshot").
    public static func run(_ profile: Profile, headless: Bool = false, extra: [String] = []) -> [String] {
        var args = ["run", profile.vmName]
        args += NetworkPolicy.failClosed(proxy: profile.proxy).runArgs
        if headless { args.append("--no-graphics") }
        args += extra
        return args
    }

    /// An explicit restore point: clone the profile VM to a timestamped backup.
    /// (Closing a VM already persists its disk; this is for rollback.)
    public static func backup(_ profile: Profile, label: String) -> [String] {
        ["clone", profile.vmName, "\(profile.vmName)--\(ProfilePlan.safeLabel(label))"]
    }

    public static func stop(_ profile: Profile) -> [String] { ["stop", profile.vmName] }

    /// Delete a profile's VM (and, pass each backup name, its backups).
    public static func delete(vmName: String) -> [String] { ["delete", vmName] }

    static func safeLabel(_ label: String) -> String {
        let mapped = label.map { ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0) ? $0 : "-" }
        return String(String(mapped).prefix(32))
    }
}
