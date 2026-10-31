import Foundation

/// An earlier sandboxed build's data, moved to where an unsandboxed build of the same bundle
/// identifier keeps it — the reverse of `container-migration.plist`, which macOS itself performs
/// the first time a sandboxed build starts.
///
/// WHY. Hosting Safari's chrome needs a build without the App Sandbox (`SANDBOX=0`, see
/// docs/SAFARI_PROCESS.md §9), and an unsandboxed build looks for its vault in
/// `~/Library/Application Support`, not in the container a sandboxed build of the same app used.
/// Without this, switching builds shows the "create a master password" screen and leaves every
/// profile behind in the container.
///
/// WHAT MOVES. The vault folder (everything the app keeps — encrypted profiles, settings,
/// passwords, history, bookmarks, the sealed WebKit data and Safari home archives), and WebKit
/// data a crash left unsealed in the container, which is put where this build's layout has it
/// (`WebKitDataLayout` translates the paths) so that it is found and sealed at the next unlock,
/// as any crash residue is. Moved, not copied: two vaults of the same profiles would part ways at
/// the first change. Only when this build has no vault of its own, so nothing is ever replaced.
public enum UnsandboxedMigration {
    public struct Move: Equatable, Sendable {
        public let from: URL
        public let to: URL
    }

    /// What would move from a sandboxed build's container (`containerLibrary`, i.e.
    /// `~/Library/Containers/<bundle id>/Data/Library`) into `library` (`~/Library`). Empty when
    /// the container has no vault, or `library` already has one.
    public static func plan(containerLibrary: URL, library: URL, bundleID: String) -> [Move] {
        let containerVault = vaultFolder(in: containerLibrary)
        let localVault = vaultFolder(in: library)
        guard MasterVault.exists(in: containerVault), !MasterVault.exists(in: localVault) else { return [] }
        // An empty or leftover local folder (no vault in it) is not overwritten: the vault goes in
        // only where there is nothing at all.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: localVault.path), !contents.isEmpty {
            return []
        }
        var moves = [Move(from: containerVault, to: localVault)]
        let sandboxed = WebKitDataLayout(library: containerLibrary, bundleID: bundleID, sandboxed: true)
        let local = WebKitDataLayout(library: library, bundleID: bundleID, sandboxed: false)
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: containerVault.appendingPathComponent("profiles").path)) ?? []
        for id in profiles.compactMap(UUID.init(uuidString:)).sorted(by: { $0.uuidString < $1.uuidString }) {
            for directory in sandboxed.discoverDirectories(for: id) {
                guard let label = try? sandboxed.label(for: directory),
                      let destination = try? local.destination(forLabel: label, profileID: id),
                      !FileManager.default.fileExists(atPath: destination.path) else { continue }
                moves.append(Move(from: directory, to: destination))
            }
        }
        return moves
    }

    /// Carries out `plan`, in order: the vault first, so that an interruption leaves at worst
    /// residue in the container, which the sandboxed build seals as before.
    public static func perform(_ moves: [Move]) throws {
        for move in moves {
            try FileManager.default.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: move.to.path) {
                // Only an empty folder can be in the way (`plan` refuses anything else).
                try FileManager.default.removeItem(at: move.to)
            }
            try FileManager.default.moveItem(at: move.from, to: move.to)
        }
    }

    public static func vaultFolder(in library: URL) -> URL {
        library.appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PrivacyBrowser", isDirectory: true)
    }
}
