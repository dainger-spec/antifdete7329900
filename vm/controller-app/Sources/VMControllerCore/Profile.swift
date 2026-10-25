import Foundation

/// How a profile's VM reaches the internet.
public enum NetworkMode: String, Codable, CaseIterable, Sendable {
    /// Only through `proxy`, fail-closed (softnet default-deny). An empty or
    /// unusable proxy means no internet, never a direct connection.
    case proxy
    /// Straight out through the host's NAT: sites see the host's IP.
    case direct
    /// No internet at all.
    case offline
}

/// A saved browsing profile: one macOS VM, cloned from a base image, with its
/// own persistent disk (the "snapshot"), proxy, cookies and settings.
///
/// Tart has no `snapshot` command — a clone *is* a snapshot, and a VM's disk
/// persists across run/stop. So a profile is simply its own cloned VM: running
/// it resumes its last state, and stopping it keeps the new state. See
/// docs/PROFILES.md.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    /// Proxy URL the VM must egress through, e.g. "socks5://user:pass@host:1080"
    /// or "http://host:8080". Used when `network` is `.proxy`.
    public var proxy: String?
    /// Stored as optional so profiles saved before this field decode; read
    /// `network` instead.
    var networkMode: NetworkMode?
    /// Guest time zone, e.g. "Europe/Berlin" (nil = leave as is). Match it to
    /// the proxy's region.
    public var timeZone: String?
    /// Guest language, e.g. "de-DE" (nil = leave as is).
    public var language: String?
    /// True once this profile's VM got its own serial number and MAC
    /// (`tart set --random-serial --random-mac`). `tart clone` copies the base
    /// image's machine identifier, so without this every profile is the same
    /// "Mac". nil/false for profiles created before this existed.
    public var uniqueIdentity: Bool?
    /// The Tart VM's name, fixed when the profile is created. Older profiles
    /// have none and derive it from the name — so a rename used to cut a
    /// profile off its VM; ProfileStore pins it before the first rename.
    var vm: String?
    /// When cookies.json was last imported, and when a launch last put it into
    /// the VM's Safari. Sending them on every launch would overwrite fresher
    /// cookies (a rotated session) with the imported ones each time.
    public var cookiesImportedAt: Date?
    public var cookiesAppliedAt: Date?
    public var lastURL: String?
    /// Base image this profile was cloned from (for base-update migration).
    public var baseImage: String
    /// Whether the host↔VM clipboard is shared. Off by default so nothing is
    /// pasted into the VM by accident.
    public var clipboardShared: Bool
    /// Cookies imported for this profile, normalized; applied by the agent.
    public var cookieCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = Profile.newID(),
                name: String,
                proxy: String? = nil,
                lastURL: String? = nil,
                baseImage: String = LauncherDefaults.baseImage,
                clipboardShared: Bool = false,
                cookieCount: Int = 0,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                network: NetworkMode? = nil,
                timeZone: String? = nil,
                language: String? = nil,
                uniqueIdentity: Bool? = nil) {
        self.id = id
        self.name = name
        self.proxy = proxy
        self.networkMode = network
        self.timeZone = timeZone
        self.language = language
        self.uniqueIdentity = uniqueIdentity
        self.lastURL = lastURL
        self.baseImage = baseImage
        self.clipboardShared = clipboardShared
        self.cookieCount = cookieCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The network mode. Profiles saved before modes existed: with a proxy →
    /// `.proxy`; without → `.direct` (they used to get no internet at all,
    /// which nobody expected).
    public var network: NetworkMode {
        get { networkMode ?? (proxy?.trimmingCharacters(in: .whitespaces).isEmpty == false ? .proxy : .direct) }
        set { networkMode = newValue }
    }

    /// The host-enforced network policy for this profile's VM.
    public var networkPolicy: NetworkPolicy {
        switch network {
        case .proxy: NetworkPolicy.failClosed(proxy: proxy)
        case .direct: .openNAT
        case .offline: .isolated
        }
    }

    /// Whether the next launch should send the imported cookies to the VM.
    public var needsCookieApply: Bool {
        guard cookieCount > 0 else { return false }
        guard let applied = cookiesAppliedAt else { return true }
        // Stored with whole-second precision: same second → send again (safe side).
        return (cookiesImportedAt ?? .distantPast) >= applied
    }

    /// The proxy the guest should use: only when softnet lets traffic reach it.
    public var guestProxy: String? {
        if case .proxyOnly = networkPolicy { return proxy }
        return nil
    }

    /// 8 hex chars, enough to disambiguate VM names without being unwieldy.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// The Tart VM name for this profile: a filesystem/OCI-safe slug of the
    /// name plus the id, so two profiles called "Work" never collide and the
    /// name stays human-readable in `tart list`.
    public var vmName: String {
        vm ?? Profile.vmName(name: name, id: id)
    }

    static func vmName(name: String, id: String) -> String {
        "pb-\(Profile.slug(name))-\(id)"
    }

    public static func slug(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { scalar -> Character in
            (scalar.properties.isAlphabetic && scalar.isASCII) || ("0"..."9").contains(Character(scalar))
                ? Character(scalar) : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = collapsed.prefix(24)
        return trimmed.isEmpty ? "profile" : String(trimmed)
    }
}
