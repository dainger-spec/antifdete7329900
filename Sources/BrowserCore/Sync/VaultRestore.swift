import Foundation

/// A vault that is already somewhere — kept by the Lumen account, in a sync folder, on a server of
/// one's own — brought to a Mac that has none: a new Mac, an erased disk, or a second Mac that joins
/// the vault another one still syncs (docs/SYNC_FORMAT.md, "A Mac without a vault").
///
/// What it holds to:
/// - **Nothing here is written over.** It works only where there is no vault (`vault.json`), and
///   refuses when the vault's folder holds files a vault is made of (`Problem.filesInTheWay`).
/// - **Nothing there is written at all.** The sync location is read through `ReadOnlySyncTransport`:
///   a restore changes no object of the account's, the folder's or the server's copy. What the
///   engine would have written goes with the first ordinary sync.
/// - **Never half a vault.** The vault is built in a folder of its own inside the vault's folder
///   (`restore-staging/<vault id>/`), by the engine's own run, and moved into place only once all of
///   it is there — by renames written down first (`move.json`), `vault.json` the last: a move cut
///   short is finished at the app's next start (`finishInterruptedMoves`), before it looks for a vault.
/// - **Not from the beginning again.** The folder keeps the engine's own records (`sync-state.bin`):
///   the same restore asked again — after a lost connection, after the app was quit — fetches only
///   what is not here yet. What was brought goes only by the person's own Discard
///   (`discardStagingBecauseThePersonAsked`, docs/DESTRUCTIVE_PATHS.md).
/// - **This Mac goes on with that vault.** The place is kept as this Mac's sync target in the
///   restored `settings.bin`, and the records — with the server's generation they are of (the Lumen
///   server's CONTRACT §16.2) — in its `sync-state.bin`: the next sync continues the vault, where a
///   vault made anew would have gone up beside it as another one.
public enum VaultRestore {
    // MARK: What can stop it, as states

    public enum Problem: Error, Equatable, Sendable {
        /// The place holds no vault: no `vault-header` there.
        case noVaultThere
        /// A newer version of the app wrote the vault there — its header, or a file met while it was
        /// brought (`what`): this Mac needs that version first (docs/UPDATES.md §4).
        case newerApp(what: String)
        /// What the place gave is not the header of the vault asked for.
        case notThisVault
        case wrongPassword
        /// This Mac has a vault: nothing is brought over it.
        case vaultHere
        /// The vault's folder holds these, with no `vault.json`: a vault's files, never written over.
        case filesInTheWay([String])
        /// The disk has `free` bytes; to begin, `needed`.
        case notEnoughSpace(free: Int64, needed: Int64)
        /// The disk filled while the vault was brought. What is here is kept.
        case diskFull
        /// The vault at the place changed under the run — its data deleted, or put back from a copy —
        /// and what the run brought is not all of it. What is here is kept; the next run goes on.
        case changedMeanwhile
        /// The person stopped it. What is here is kept.
        case stopped
    }

    // MARK: Where it is built

    static let stagingName = "restore-staging"
    static let journalName = "move.json"

    /// `restore-staging` in the vault's folder: one folder per vault being brought.
    public static func stagingRoot(in root: URL) -> URL {
        root.appendingPathComponent(stagingName, isDirectory: true)
    }

    public static func stagingDirectory(for vaultID: UUID, in root: URL) -> URL {
        stagingRoot(in: root).appendingPathComponent(vaultID.uuidString.lowercased(), isDirectory: true)
    }

    // MARK: 1. The header, before the master password

    /// The header the place holds — plaintext, nothing secret: when the vault was made, how many times
    /// its master password was changed. `expecting`: the vault asked for (one of the account's list,
    /// the ID typed for a server of one's own); nil for a folder, which holds one vault.
    public static func header(at transport: SyncTransport, expecting vaultID: UUID? = nil) async throws -> VaultHeader {
        guard let blob = try await transport.fetch(objectID: SyncEngine.vaultHeaderObjectID) else { throw Problem.noVaultThere }
        let header: VaultHeader
        do {
            header = try VaultHeader.decodeChecked(blob)
        } catch CoreError.newerFormat(let what, _, _) {
            throw Problem.newerApp(what: what)
        } catch {
            throw Problem.notThisVault
        }
        // A place that gives another vault's header under this one's ID is not believed.
        if let vaultID, header.vaultID != vaultID { throw Problem.notThisVault }
        return header
    }

    // MARK: 2. The master password

    /// The vault opened with its master password, in its staging folder.
    public struct Staged: @unchecked Sendable {
        public let vault: UnlockedVault
        /// A restore of this vault was begun before: what it brought is here, and is not fetched again.
        public let continued: Bool
    }

    /// Opens `header` with `password` (one key derivation: call it off the main thread) and makes the
    /// staging folder for it. A wrong password leaves nothing on disk. Refuses where this Mac has a
    /// vault, or files of one.
    public static func open(_ header: VaultHeader, password: String, root: URL) throws -> Staged {
        guard !MasterVault.exists(in: root) else { throw Problem.vaultHere }
        let inTheWay = filesInTheWay(in: root)
        guard inTheWay.isEmpty else { throw Problem.filesInTheWay(inTheWay) }
        let directory = stagingDirectory(for: header.vaultID, in: root)
        let vault: UnlockedVault
        do {
            vault = try MasterVault.unlock(header: header, root: directory, password: password)
        } catch CoreError.wrongPassword {
            throw Problem.wrongPassword
        }
        // Only now, the password known to open it, is anything written.
        let url = MasterVault.headerURL(in: directory)
        let continued = FileManager.default.fileExists(atPath: url.path)
        if continued {
            // The header as the place has it now: the master password may have been changed on
            // another device since this restore began (the same key, wrapped anew).
            let encoded = try JSONCoding.encoder.encode(header)
            if (try? SecureFile.read(url)) != encoded { try SecureFile.write(encoded, to: url) }
        } else {
            try MasterVault.createHeader(header, in: directory)
        }
        return Staged(vault: vault, continued: continued)
    }

    /// The names in the vault's folder that a restored vault would have to be written over: a vault's
    /// own files left without their `vault.json`. An empty `profiles` folder is in no one's way.
    static let vaultFileNames = ["index.bin", "labels.bin", "settings.bin", "sync-state.bin", "profiles"]

    public static func filesInTheWay(in root: URL) -> [String] {
        vaultFileNames.filter { blocks(root.appendingPathComponent($0)) }
    }

    /// Something is at `url` that a rename may not replace: anything but an empty folder.
    private static func blocks(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return true }
        return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]).isEmpty
    }

    // MARK: What is in it, before anything is brought

    /// The profiles the vault at the place lists — its index, read with the vault's key; nothing is
    /// written anywhere. Empty: the place holds the vault's header and no profile yet.
    public static func profiles(of staged: UnlockedVault, at transport: SyncTransport) async throws -> [ProfileSummary] {
        do {
            let codec = try SyncCodec(vault: staged)
            guard let blob = try await transport.fetch(objectID: codec.objectID(for: "index")) else { return [] }
            let decoded = try codec.decode(blob)
            try DocumentFormat.check(decoded.payload.data, supported: ProfileRepository.indexFormat, what: "index.bin")
            let index = try JSONCoding.decoder.decode(ProfileIndex.self, from: decoded.payload.data)
            return index.entries.map(\.summary).sorted { $0.createdAt < $1.createdAt }
        } catch {
            throw translate(error, at: staged.root)
        }
    }

    // MARK: 3. Bringing it

    public struct Progress: Equatable, Sendable {
        /// The objects the place lists for the vault.
        public var listed: Int
        /// Fetched by this run, and their bytes.
        public var fetched: Int
        public var bytes: Int64
        /// Files a restore begun before had brought: not fetched again.
        public var alreadyHere: Int

        public init(listed: Int, fetched: Int, bytes: Int64, alreadyHere: Int) {
            self.listed = listed
            self.fetched = fetched
            self.bytes = bytes
            self.alreadyHere = alreadyHere
        }

        /// How far it is, 0…1; nil before the place has listed anything.
        public var fraction: Double? {
            guard listed > 0 else { return nil }
            return min(1, Double(fetched + alreadyHere) / Double(listed))
        }
    }

    public struct Outcome: Sendable {
        /// The profiles the vault lists, as they are here now.
        public var profiles: [ProfileSummary]
        /// Of them, those whose settings the place does not hold — they never reached it (refused as
        /// too large, or the Mac that made them has not synced since). Listed, and they do not start.
        public var withoutSettings: [ProfileSummary]
        /// What this run fetched.
        public var bytes: Int64
        /// What the engine would have written to the place, withheld: it goes with the first sync.
        public var withheld: Int
    }

    /// Brings the vault into its staging folder: the engine's own run, through a transport that writes
    /// nothing. `target`: the place as this Mac's sync target, kept in the staged vault's
    /// `settings.bin` (encrypted) from the start. Throws `Problem` for what it knows by name, and any
    /// other error as it came (a refusal of the server's, no connection); either way what was brought
    /// stays, and the same call goes on from it.
    public static func download(into staged: UnlockedVault, from transport: SyncTransport,
                                target: DeviceSettings.SyncTarget?,
                                progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Outcome {
        do {
            let repository = try ProfileRepository(vault: staged)
            if let target {
                var settings = (try? DeviceSettings.load(from: staged)) ?? DeviceSettings()
                if settings.syncTarget != target {
                    settings.syncTarget = target
                    try settings.save(to: staged)
                }
            }
            let readOnly = ReadOnlySyncTransport(transport)
            let here = syncedFilesHere(repository)
            readOnly.onProgress = { counts in
                progress?(Progress(listed: counts.listed, fetched: counts.fetched, bytes: counts.bytes, alreadyHere: here))
            }
            var report = try await SyncEngine(repository: repository, transport: readOnly).sync()
            var look = try whatIsNotHere(repository, listed: readOnly.lastListed)
            if look.missing > 0 {
                // Listed and not here after a whole run: the place changed under it. Once more, from
                // its list as it is now.
                report = try await SyncEngine(repository: repository, transport: readOnly).sync()
                look = try whatIsNotHere(repository, listed: readOnly.lastListed)
                guard look.missing == 0 else { throw Problem.changedMeanwhile }
            }
            // The run as this Mac's last sync — without what was withheld, which the place refused nothing of.
            var shown = report
            shown.deferred = []
            var settings = (try? DeviceSettings.load(from: staged)) ?? DeviceSettings()
            settings.lastSync = DeviceSettings.SyncStatus(report: shown)
            if let target { settings.syncTarget = target }
            try settings.save(to: staged)
            return Outcome(profiles: repository.list(), withoutSettings: look.withoutSettings,
                           bytes: readOnly.counts.bytes, withheld: readOnly.withheld.count)
        } catch {
            throw translate(error, at: staged.root)
        }
    }

    /// How many of the vault's synced files are in the staging already (a restore begun before).
    private static func syncedFilesHere(_ repository: ProfileRepository) -> Int {
        var count = FileManager.default.fileExists(atPath: repository.indexURL.path) ? 1 : 0
        for id in repository.profileFolderIDs() {
            for file in ProfileSyncFile.allCases where FileManager.default.fileExists(atPath: repository.url(of: file, for: id).path) {
                count += 1
            }
        }
        return count
    }

    /// After a run: the files the place lists for the index's profiles that are not here (`missing`),
    /// and the profiles whose settings the place does not list at all.
    private static func whatIsNotHere(_ repository: ProfileRepository,
                                      listed: [RemoteObjectInfo]) throws -> (missing: Int, withoutSettings: [ProfileSummary]) {
        let codec = try SyncCodec(vault: repository.vault)
        let there = Set(listed.map(\.objectID))
        var missing = 0
        var withoutSettings: [ProfileSummary] = []
        for summary in repository.list() {
            for file in ProfileSyncFile.allCases {
                let isThere = there.contains(codec.objectID(for: "profile/\(summary.id.uuidString)/\(file.rawValue)"))
                let isHere = FileManager.default.fileExists(atPath: repository.url(of: file, for: summary.id).path)
                if isThere, !isHere { missing += 1 }
                if file.isNeededToStart, !isThere, !isHere { withoutSettings.append(summary) }
            }
        }
        return (missing, withoutSettings)
    }

    /// An error of the run as the state it is, when it is one of `Problem`; else the error itself.
    static func translate(_ error: Error, at directory: URL) -> Error {
        if error is Problem { return error }
        if error is CancellationError { return Problem.stopped }
        guard let core = error as? CoreError else { return error }
        switch core {
        case .newerFormat(let what, _, _):
            return Problem.newerApp(what: what)
        case .unsupportedFormat(let what):
            // A record in an envelope this version does not read: a newer version's.
            return Problem.newerApp(what: what)
        case .io:
            if let free = freeBytes(at: directory), free < diskFullBelow { return Problem.diskFull }
            return error
        default:
            return error
        }
    }

    // MARK: 4. Into place

    struct Journal: Codable, Equatable {
        var format = 1
        /// What is moved, in this order; `vault.json` the last — with it there, this Mac has the vault.
        var names: [String]
    }

    /// Moves the staged vault into the vault's folder and gives it back open there. Refuses, before
    /// anything is moved, where a vault is, or where anything the staging holds has a namesake in the
    /// vault's folder: the staging then stays whole, to be moved once the way is clear.
    public static func moveIntoPlace(_ staged: UnlockedVault, root: URL) throws -> UnlockedVault {
        guard !MasterVault.exists(in: root) else { throw Problem.vaultHere }
        let directory = staged.root
        var names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0 != journalName && !$0.hasPrefix(".") }.sorted()
        guard names.contains(vaultFileName) else { throw CoreError.vaultNotFound }
        names.removeAll { $0 == vaultFileName }
        names.append(vaultFileName)
        let inTheWay = names.filter { blocks(root.appendingPathComponent($0)) }
        guard inTheWay.isEmpty else { throw Problem.filesInTheWay(inTheWay) }
        try SecureFile.write(JSONEncoder().encode(Journal(names: names)), to: directory.appendingPathComponent(journalName))
        try carryOut(names, from: directory, to: root)
        return try staged.moved(to: root)
    }

    private static let vaultFileName = "vault.json"

    /// At the app's start, before it looks for a vault: a move into place that was cut short — the
    /// app quit or the Mac lost power between two renames — is finished, as its journal says. A
    /// journal means the vault was all there and its move begun; nothing else is ever moved. Where
    /// something stands in the way the rest stays as it is. Returns whether a move was finished.
    @discardableResult
    public static func finishInterruptedMoves(in root: URL) -> Bool {
        let stagings = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot(in: root).path)) ?? []
        var finished = false
        for name in stagings.sorted() where UUID(uuidString: name) != nil {
            let directory = stagingRoot(in: root).appendingPathComponent(name, isDirectory: true)
            guard let data = try? SecureFile.read(directory.appendingPathComponent(journalName)),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.format == 1,
                  journal.names.last == vaultFileName,
                  journal.names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.hasPrefix(".") }) else { continue }
            // The staging's own header still here while the vault's folder has one: another vault's,
            // made since. Left alone.
            let stagedHeader = FileManager.default.fileExists(atPath: MasterVault.headerURL(in: directory).path)
            if MasterVault.exists(in: root), stagedHeader { continue }
            if (try? carryOut(journal.names, from: directory, to: root)) != nil { finished = true }
        }
        return finished
    }

    /// The renames, in the journal's order. One already made (its name gone from the staging) is
    /// passed over; an empty folder in the way gives way, anything else stops the move where it is.
    private static func carryOut(_ names: [String], from directory: URL, to root: URL) throws {
        try SecureFile.ensureDirectory(root)
        for name in names {
            let source = directory.appendingPathComponent(name), destination = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard rmdir(destination.path) == 0 else { throw Problem.filesInTheWay([name]) }
            }
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                throw CoreError.io("move \(name) into the vault's folder: \(error)")
            }
        }
        // All of it is in place. What is left is the journal and, at most, temporary files an
        // interrupted write of this restore left (`SecureFile`): the restore's own, holding nothing
        // that is not in place. The folders go only when empty.
        unlink(directory.appendingPathComponent(journalName).path)
        for leftover in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where leftover.hasPrefix(".") && leftover.hasSuffix(".tmp") {
            unlink(directory.appendingPathComponent(leftover).path)
        }
        rmdir(directory.path)
        rmdir(stagingRoot(in: root).path)
    }

    // MARK: Restores that were not finished

    public struct Unfinished: Equatable, Sendable, Identifiable {
        public var vaultID: UUID
        /// When the vault was made, by its header.
        public var createdAt: Date
        /// What was brought so far, on disk.
        public var bytes: Int64
        public var id: UUID { vaultID }

        public init(vaultID: UUID, createdAt: Date, bytes: Int64) {
            self.vaultID = vaultID
            self.createdAt = createdAt
            self.bytes = bytes
        }
    }

    /// The restores begun on this Mac and not finished: for the person to continue (the same restore
    /// again goes on from them) or discard.
    public static func unfinished(in root: URL) -> [Unfinished] {
        let stagings = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot(in: root).path)) ?? []
        return stagings.sorted().compactMap { name in
            let directory = stagingRoot(in: root).appendingPathComponent(name, isDirectory: true)
            guard let id = UUID(uuidString: name), let header = try? MasterVault.readHeader(in: directory), header.vaultID == id else { return nil }
            return Unfinished(vaultID: id, createdAt: header.createdAt, bytes: bytes(in: directory))
        }
    }

    /// The person's own Discard of a restore that was not finished, and nothing else: the folder it
    /// was built in goes, with the copies it brought — of what the sync location holds, never opened
    /// on this Mac. Nothing at the sync location is touched, and nothing of a vault this Mac has.
    /// Never one whose move into place has begun (it is finished instead, `finishInterruptedMoves`).
    public static func discardStagingBecauseThePersonAsked(_ vaultID: UUID, in root: URL) throws {
        let restoreStaging = stagingDirectory(for: vaultID, in: root)
        guard FileManager.default.fileExists(atPath: restoreStaging.path) else { return }
        guard !FileManager.default.fileExists(atPath: restoreStaging.appendingPathComponent(journalName).path) else {
            throw CoreError.io("this restore is being moved into place; it is finished at the next start, not discarded")
        }
        do {
            // The one removal of a restore's staging (scripts/check_deletion_paths.py).
            try FileManager.default.removeItem(at: restoreStaging)
        } catch {
            throw CoreError.io("remove the unfinished restore: \(error)")
        }
        rmdir(stagingRoot(in: root).path)
    }

    // MARK: Room on the disk

    /// What a restore asks for beyond the vault's own size before it begins.
    public static let spareBytes: Int64 = 64 * 1024 * 1024
    /// A write that failed with less than this free is the disk being full.
    static let diskFullBelow: Int64 = 8 * 1024 * 1024

    /// Free bytes on the volume `url` is on (the nearest folder above it that exists); nil when the
    /// system does not say.
    public static func freeBytes(at url: URL) -> Int64? {
        var folder = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/", !folder.path.isEmpty {
            folder = folder.deletingLastPathComponent()
        }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: folder.path),
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    /// Whether there is room to begin: the vault's size where the place says it (`known`: a folder's
    /// files), and `spareBytes`. The Lumen server and a server of one's own say no size before the
    /// objects come, so there only the spare is asked for, and a disk that fills during the run is
    /// said then (`Problem.diskFull`). Nil: room enough, or the system does not say how much is free.
    public static func spaceProblem(free: Int64?, known: Int64?) -> Problem? {
        guard let free else { return nil }
        let needed = max(0, known ?? 0) + spareBytes
        return free < needed ? .notEnoughSpace(free: free, needed: needed) : nil
    }

    /// The bytes of the files in `folder` and below it.
    public static func bytes(in folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// What a restore reads the sync location through (`VaultRestore`): every read as the transport
/// makes it, and no write at all — a write the engine asks for is withheld and left for the first
/// ordinary sync, as after a lost compare-and-swap; one of the vault's header means the place no
/// longer holds the header the restore began with (`Problem.changedMeanwhile`). It counts what the
/// run lists and fetches, and stops between two objects when the task is cancelled.
///
/// It names the server's generation as the transport it reads through does, so the engine keeps it
/// with the records the restore leaves (`SyncEngine.sync`); one that reads a folder names none.
public final class ReadOnlySyncTransport: ServerGenerationTransport, @unchecked Sendable {
    public struct Counts: Equatable, Sendable {
        public var listed = 0
        public var fetched = 0
        public var bytes: Int64 = 0
    }

    let inner: SyncTransport
    private let lock = NSLock()
    private var current = Counts()
    private var listed: [RemoteObjectInfo] = []
    private var withheldIDs: [String] = []
    /// Called after each list and fetch, on whatever thread the run is on. Set before the run.
    var onProgress: (@Sendable (Counts) -> Void)?

    public init(_ inner: SyncTransport) {
        self.inner = inner
    }

    public var generationScope: String { (inner as? ServerGenerationTransport)?.generationScope ?? "" }
    public var serverGeneration: String? { (inner as? ServerGenerationTransport)?.serverGeneration }

    public var counts: Counts { lock.withLock { current } }
    /// The objects the engine asked to write, never sent.
    public var withheld: [String] { lock.withLock { withheldIDs } }
    /// The place's list as the last run read it.
    var lastListed: [RemoteObjectInfo] { lock.withLock { listed } }

    public func listObjects() async throws -> [RemoteObjectInfo] {
        try Task.checkCancellation()
        let objects = try await inner.listObjects()
        let now: Counts = lock.withLock {
            listed = objects
            current.listed = objects.count
            return current
        }
        onProgress?(now)
        return objects
    }

    public func fetch(objectID: String) async throws -> Data? {
        try Task.checkCancellation()
        let data = try await inner.fetch(objectID: objectID)
        let now: Counts = lock.withLock {
            current.fetched += 1
            current.bytes += Int64(data?.count ?? 0)
            return current
        }
        onProgress?(now)
        return data
    }

    public func store(objectID: String, revision: Int, data: Data, expectedRevision: Int?) async throws {
        lock.withLock { withheldIDs.append(objectID) }
        if objectID == SyncEngine.vaultHeaderObjectID { throw VaultRestore.Problem.changedMeanwhile }
        throw CoreError.syncConflict(objectID: objectID, remoteRevision: expectedRevision ?? 0)
    }
}

extension VaultRestore.Problem: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noVaultThere: return "No vault at the sync location"
        case .newerApp(let what): return "The vault at the sync location was written by a newer version of Lumen (\(what)); nothing was brought"
        case .notThisVault: return "The sync location did not give the header of the vault asked for"
        case .wrongPassword: return "Wrong master password for the vault at the sync location"
        case .vaultHere: return "This Mac has a vault; nothing is brought over it"
        case .filesInTheWay(let names): return "The vault's folder holds a vault's files (\(names.joined(separator: ", "))); nothing is written over them"
        case .notEnoughSpace(let free, let needed): return "Not enough free space to bring the vault (\(free) bytes free, \(needed) needed)"
        case .diskFull: return "The disk is full; what was brought is kept"
        case .changedMeanwhile: return "The vault at the sync location changed while it was being brought; what was brought is kept"
        case .stopped: return "Stopped; what was brought is kept"
        }
    }
}

extension VaultRestore.Problem: LocalizedError {
    public var errorDescription: String? { CoreErrorText.translate?(self) ?? description }
}
