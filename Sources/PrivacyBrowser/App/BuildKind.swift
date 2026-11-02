import Foundation

/// What kind of build this is, for the texts that must say what blocks a feature and what to do
/// about it: a person running Lumen as released can do nothing about how it was built, a developer
/// can. Never decides anything but which words are shown.
enum BuildKind {
    /// Made to be released (`scripts/release.sh`): the build carries its account server
    /// (`PBAccountServerURL`, which `--release-check` requires of every release). A development build
    /// (`scripts/build-app.sh` alone) carries none.
    static let madeForRelease: Bool = {
        guard let server = Bundle.main.object(forInfoDictionaryKey: "PBAccountServerURL") as? String else { return false }
        return !server.isEmpty
    }()

    /// The packet-tunnel system extension is inside this build (`NE=1`): WebRTC of a profile with a
    /// SOCKS5 proxy can go through it once the person turns it on. Without it, nothing can turn it
    /// on, and no text may ask the person to.
    @MainActor static var carriesTunnel: Bool { TunnelManager.shared.extensionIdentifier != nil }
}
