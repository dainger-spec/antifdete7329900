import BrowserCore
import Foundation

/// The check at the end of a quit before an update may be handed to its installer
/// (docs/UPDATES.md §3). It passes only if nothing runs, starts or is being sealed; no profile's
/// process had to be killed during the quit; and — looked at on disk, not taken from memory — no
/// profile of the vault has website data or a Safari home in plaintext, or a home a process still
/// holds. Profiles started only for a warm-up are covered the same way: while they run they are the
/// manager's sessions or processes like any other, and their data is on the same disk.
///
/// The vault does not need to be unlocked: profiles are found by their folders' names.
enum UpdateGate {
    struct Verdict: Equatable {
        /// What failed, in the log's words; empty when the update may be installed.
        var reasons: [String]
        var passed: Bool { reasons.isEmpty }
    }

    static func check(vaultRoot: URL, hasActivity: Bool, forcedExits: Int,
                      discover: (UUID) -> [URL] = { WebDataStoreVault.discoverDirectories(for: $0) }) -> Verdict {
        var reasons: [String] = []
        if hasActivity { reasons.append("a profile is still running, starting or being encrypted") }
        if forcedExits > 0 { reasons.append("\(forcedExits) profile process(es) had to be killed during the quit") }
        let profiles = vaultRoot.appendingPathComponent("profiles", isDirectory: true)
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []).compactMap(UUID.init(uuidString:))
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let folder = profiles.appendingPathComponent(id.uuidString, isDirectory: true)
            if !discover(id).isEmpty {
                reasons.append("profile \(id.uuidString): website data is not encrypted")
            }
            for name in ["home.noindex", "home"] where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                reasons.append("profile \(id.uuidString): Safari's home is not encrypted")
            }
            if SafariHomeVault.isHeld(lock: folder.appendingPathComponent("home.lock")) {
                reasons.append("profile \(id.uuidString): a process still holds its home")
            }
        }
        return Verdict(reasons: reasons)
    }
}
