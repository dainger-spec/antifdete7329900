import Foundation

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
    /// or "http://host:8080". nil means no proxy — and, fail-closed, no internet.
    public var proxy: String?
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
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.proxy = proxy
        self.lastURL = lastURL
        self.baseImage = baseImage
        self.clipboardShared = clipboardShared
        self.cookieCount = cookieCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 8 hex chars, enough to disambiguate VM names without being unwieldy.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// The Tart VM name for this profile: a filesystem/OCI-safe slug of the
    /// name plus the id, so two profiles called "Work" never collide and the
    /// name stays human-readable in `tart list`.
    public var vmName: String {
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
