import Foundation

/// Where a profile's cookie snapshots and its running mark are kept (docs/COOKIE_RECOVERY.md).
///
/// `profiles/<uuid>/cookie-snapshots.bin`: `AEAD(HKDF(profileKey, "cookie-snapshots"), CookieSnapshots
/// JSON)`, AAD `cookie-snapshots:v1:<uuid>` — inside the profile's folder, sealed with the profile's
/// own key, which only the manager and that profile's own process hold (`ProfileGrant`): another
/// profile's process can read its bytes, as it can every file of the vault, and open none of them.
/// Written whole through a temporary file and a rename: a crash leaves the old copy or the new one.
/// This Mac only: not synced, not in a profile export (`ProfileTransfer`), copied into a restore
/// point with the website data it goes with.
///
/// `profiles/<uuid>/cookies-running`: an empty file, there from a launch's start to its clean stop.
/// Found at a launch, the run before did not stop cleanly (a crash, a kill, a forced quit), and the
/// newest snapshot may be older than the store's last state (`CookieRecovery.RunEnd`).
extension ProfileRepository {
    func cookieSnapshotsURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookie-snapshots.bin") }
    func cookieRunMarkURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("cookies-running") }

    func cookieSnapshotsFile(for id: UUID) throws -> EncryptedDocumentFile<CookieSnapshots> {
        EncryptedDocumentFile(url: cookieSnapshotsURL(for: id),
                              key: try profileKey(for: id).derive(info: "cookie-snapshots", salt: id.rawBytes),
                              aad: "cookie-snapshots:v1:\(id.uuidString)")
    }

    /// The profile's snapshots, oldest first; none before the first was taken. Throws when the file
    /// does not open (damaged, another key's) or a newer version wrote it.
    public func cookieSnapshots(for id: UUID) throws -> CookieSnapshots {
        try cookieSnapshotsFile(for: id).load() ?? CookieSnapshots()
    }

    /// Adds `snapshot` as the newest, the oldest beyond `CookieSnapshots.kept` going; returns them.
    /// Snapshots that do not open are begun anew — the file moved aside first as
    /// `cookie-snapshots.bin.unreadable`, never written over (docs/DESTRUCTIVE_PATHS.md); a newer
    /// version's are not written at all.
    @discardableResult
    public func addCookieSnapshot(_ snapshot: CookieSnapshot, for id: UUID) throws -> CookieSnapshots {
        let file = try cookieSnapshotsFile(for: id)
        var snapshots: CookieSnapshots
        do {
            snapshots = try file.load() ?? CookieSnapshots()
        } catch {
            if case CoreError.newerFormat = error { throw error }
            snapshots = CookieSnapshots()
        }
        snapshots.add(snapshot)
        try file.save(snapshots)
        return snapshots
    }

    /// Snapshots turned off for the profile, or the profile made ephemeral: none kept, and no mark.
    /// One that does not open is moved aside rather than deleted; a newer version's stays.
    public func removeCookieSnapshots(for id: UUID) throws {
        try? FileManager.default.removeItem(at: cookieRunMarkURL(for: id))
        try cookieSnapshotsFile(for: id).remove()
    }

    /// A run of the profile with a live cookie store has begun.
    public func markCookieRunStarted(for id: UUID) throws {
        try SecureFile.write(Data(), to: cookieRunMarkURL(for: id))
    }

    /// The run stopped cleanly, its store copied as it stopped.
    public func markCookieRunEnded(for id: UUID) throws {
        let url = cookieRunMarkURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// How the profile's last run ended: unclean while its mark is there.
    public func lastCookieRunEnd(for id: UUID) -> CookieRecovery.RunEnd {
        FileManager.default.fileExists(atPath: cookieRunMarkURL(for: id).path) ? .unclean : .clean
    }
}
