import Foundation

/// A copy of a stopped profile's browsing state, to go back to: its website data (cookies, local
/// storage, IndexedDB, caches: `webdata.pbsa`), Safari's own state (`safarihome.pbsa`), its history,
/// its synced cookies and their baseline, and the tabs it left open. Not its settings, passwords,
/// bookmarks or one-time codes — those are what the person set up, and a restore that took a saved
/// password away would be a loss, not a way back.
///
/// Made before a step that may go wrong — a registration, a warm-up, a cookie import — so that the
/// profile can be put back as it was. The files are copied as they are on disk, still encrypted
/// under the profile's key (on APFS the copy is a clone: it costs no room until one of them
/// changes). Kept in `profiles/<uuid>/restore-points/<point>/`, with a description `point.bin`
/// sealed under the profile's key; this Mac only — not synced, not in a profile export.
///
/// A restore keeps the state it replaces as a point of its own first (`Kind.beforeRestore`): a
/// restore can always be undone, and nothing of the profile is lost by one.
public struct RestorePoint: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Made by the person.
        case manual
        /// The state a restore replaced, kept by it.
        case beforeRestore
    }

    public var id: UUID
    /// The person's name for it; empty: shown by its date.
    public var name: String
    public var createdAt: Date
    public var kind: Kind
    /// The files of `ProfileRepository.restorePointFiles` the profile had then, copied into the
    /// point. Those it did not have, it did not have: a restore removes them.
    public var files: [String]
    /// The size of the copies, as the files were (a clone takes less room on disk).
    public var bytes: Int64

    public init(id: UUID = UUID(), name: String, createdAt: Date, kind: Kind, files: [String], bytes: Int64) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.kind = kind
        self.files = files
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey { case id, name, createdAt, kind, files, bytes }

    /// Tolerant of a kind a later version added: read as the person's own.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .manual
        files = try c.decode([String].self, forKey: .files)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
    }
}

/// Why a restore point was not made, restored or removed.
public enum RestorePointProblem: Error, Equatable, Sendable {
    /// The profile has `ProfileRepository.maximumRestorePoints` already: one is to go first.
    case full(Int)
    /// No such point (removed meanwhile), or one of its copies is missing.
    case notFound
    case damaged
}

extension ProfileRepository {
    /// The files a restore point holds: the profile's browsing state, nothing it was set up with.
    public static let restorePointFiles = ["webdata.pbsa", "safarihome.pbsa", "history.bin", "cookies.bin",
                                           "cookies-baseline.bin", "tabs.bin"]
    /// At most this many per profile: each holds the profile's whole website data.
    public static let maximumRestorePoints = 20

    func restorePointsDirectory(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("restore-points", isDirectory: true)
    }

    func restorePointDirectory(_ point: UUID, for id: UUID) -> URL {
        restorePointsDirectory(for: id).appendingPathComponent(point.uuidString, isDirectory: true)
    }

    func restorePointFile(_ point: UUID, for id: UUID) throws -> EncryptedDocumentFile<RestorePoint> {
        EncryptedDocumentFile(url: restorePointDirectory(point, for: id).appendingPathComponent("point.bin"),
                              key: try profileKey(for: id).derive(info: "restore-point", salt: id.rawBytes),
                              aad: "restore-point:v1:\(id.uuidString):\(point.uuidString)")
    }

    /// The profile's restore points, newest first. A folder whose description does not open — damaged,
    /// another key's, a later version's — is not listed, and left as it is.
    public func restorePoints(for id: UUID) -> [RestorePoint] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: restorePointsDirectory(for: id).path)) ?? []
        return names.compactMap { name -> RestorePoint? in
            guard let point = UUID(uuidString: name), let read = try? restorePointFile(point, for: id).load(),
                  read.id == point else { return nil }
            return read
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Copies the profile's browsing state (`restorePointFiles`, those it has) into a new point.
    /// The caller makes sure the profile is stopped and its data sealed: the files on disk are then
    /// the whole of it. A point that could not be made whole is taken back, nothing of the profile
    /// touched.
    @discardableResult
    public func createRestorePoint(for id: UUID, name: String, kind: RestorePoint.Kind = .manual,
                                   at date: Date = Date()) throws -> RestorePoint {
        guard restorePoints(for: id).count < Self.maximumRestorePoints else {
            throw RestorePointProblem.full(Self.maximumRestorePoints)
        }
        let pointID = UUID()
        let folder = restorePointDirectory(pointID, for: id)
        try SecureFile.ensureDirectory(folder)
        do {
            var files: [String] = []
            var bytes: Int64 = 0
            for file in Self.restorePointFiles {
                let source = directory(for: id).appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(file))
                files.append(file)
                bytes += Self.size(of: source)
            }
            let point = RestorePoint(id: pointID, name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
                                     createdAt: date, kind: kind, files: files, bytes: bytes)
            try restorePointFile(pointID, for: id).save(point)
            return point
        } catch {
            // The point made a moment before, and nothing else.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Puts the profile's browsing state back as point `pointID` holds it, once the state it
    /// replaces is kept as a point of its own (`beforeRestore`, returned): a restore can be undone.
    /// Each file the point has replaces the profile's (atomically, one by one); a file of
    /// `restorePointFiles` the point did not have is removed — its copy is in the point just made.
    /// The caller makes sure the profile is stopped and sealed, and stays so meanwhile.
    @discardableResult
    public func restore(_ pointID: UUID, for id: UUID, at date: Date = Date()) throws -> RestorePoint {
        guard let point = restorePoints(for: id).first(where: { $0.id == pointID }) else { throw RestorePointProblem.notFound }
        let folder = restorePointDirectory(pointID, for: id)
        // Every copy is there before anything changes.
        for file in point.files where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
            throw RestorePointProblem.damaged
        }
        let kept = try createRestorePoint(for: id, name: "", kind: .beforeRestore, at: date)
        for file in Self.restorePointFiles {
            let current = directory(for: id).appendingPathComponent(file)
            if point.files.contains(file) {
                let copy = directory(for: id).appendingPathComponent(".\(file).\(UUID().uuidString).restoring")
                try FileManager.default.copyItem(at: folder.appendingPathComponent(file), to: copy)
                try SecureFile.replace(current, with: copy)
            } else if FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.removeItem(at: current)
            }
        }
        return kept
    }

    /// Removes point `pointID` — the person's choice, from its confirmation. The profile's own
    /// files are not touched.
    public func removeRestorePoint(_ pointID: UUID, for id: UUID) throws {
        let folder = restorePointDirectory(pointID, for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw RestorePointProblem.notFound }
        try FileManager.default.removeItem(at: folder)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
