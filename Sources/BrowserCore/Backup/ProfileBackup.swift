#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What a backup file says about itself (readable only with the backup password).
public struct ProfileBackupInfo: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var name: String
    public var createdAt: Date
    public var exportedAt: Date
    public var fileCount: Int
    public var totalBytes: UInt64
}

/// Encrypted backup of one profile in a single file, protected by its own backup password.
///
/// ```
/// file    = "PBBK" | version u8 (=1) | kdfLength u16 | KDFParameters JSON
///           | EncryptedChunkStream (key = HKDF(PBKDF2(password, salt), chunk salt, "profile-backup"))
/// payload = manifestLength u32 | manifest JSON
///           | { nameLength u16 | name | size u64 | bytes }*  | 0 u16
/// manifest = ProfileBackupInfo + the profile key + the file list
/// ```
/// The files are the profile's own encrypted files, copied as they are: `config.bin`,
/// `passwords.bin`, `history.bin`, `bookmarks.bin`, `session.bin` and `webdata.pbsa` (cookies,
/// localStorage, IndexedDB, cache). The profile key travels inside the encrypted manifest, so a
/// backup restores into any vault (another Mac, a new master password) with only the backup
/// password.
///
/// Changing any byte, truncating, or appending fails authentication, and a restore commits
/// nothing until the whole stream has authenticated. Not included: sync state and device
/// settings (device-local), files the user downloaded (saved outside the vault), and website
/// data a running profile has not sealed yet (`webdata.pbsa` is written when the profile stops,
/// so export a stopped profile to get its latest cookies).
///
/// Forward compatibility: entries this build does not know (e.g. a `downloads/` directory
/// written by a build that keeps downloads in the vault) are authenticated with the rest and
/// skipped, so such a backup still restores everything this build understands.
public enum ProfileBackup {
    public static let fileExtension = "pbbackup"
    static let magic = Data("PBBK".utf8)
    static let version: UInt8 = 1
    static let streamInfo = "profile-backup"
    static let maxIterations = 10_000_000
    static let maxKDFLength = 4096
    static let maxManifestLength = 16 << 20

    public enum RestoreMode: Sendable, Equatable {
        /// Keep the profile's ID if this vault does not have it (and never deleted it); otherwise copy.
        case automatic
        /// Overwrite the existing profile with the same ID. The profile must not be running.
        case replaceExisting
        /// Always a new profile, with a new ID and a new profile key.
        case copy
    }

    struct Manifest: Codable {
        struct File: Codable, Equatable { var name: String; var size: UInt64 }
        var format: Int
        var info: ProfileBackupInfo
        var lastLaunchedAt: Date?
        var profileKey: Data
        var files: [File]
    }

    static let webDataFile = "webdata.pbsa"

    /// Top-level files of a profile directory that belong in a backup: every ID-bound encrypted
    /// file (`ProfileFileBinding`) plus the WebKit data archive.
    static let profileFiles = ProfileFileBinding.allCases.map(\.fileName) + [webDataFile]

    /// Entries this build unpacks. Anything else is skipped (see "Forward compatibility").
    static func isBackupPath(_ path: String) -> Bool {
        profileFiles.contains(path)
    }

    /// Entry names any build may write: relative '/'-separated paths without "", ".", ".." or NUL
    /// components. Anything else is a corrupt or hostile backup.
    static func isSafeEntryName(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
        }
    }

    // MARK: Export

    /// Writes a backup of a profile to `destination`. The file is written in place — inside the
    /// App Sandbox a save panel grants access to that one file — and removed again if anything
    /// fails.
    ///
    /// Each file is opened before anything is written and copied from that handle. The stores
    /// replace their files with rename(2), so every file in the backup is a consistent version
    /// even if the profile is running (its website data is then the state of its last stop).
    @discardableResult
    public static func export(profile id: UUID, from repository: ProfileRepository, to destination: URL, password: String,
                              iterations: Int = KDFParameters.recommendedIterations) throws -> ProfileBackupInfo {
        guard !password.isEmpty else { throw CoreError.invalidConfiguration("empty backup password") }
        let summary = try repository.summary(for: id)
        let key = try repository.profileKey(for: id)
        let directory = repository.directory(for: id)

        var sources: [(name: String, handle: FileHandle)] = []
        defer { for source in sources { try? source.handle.close() } }
        var files: [Manifest.File] = []
        for name in profileFiles {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                sources.append((name, handle))
                let size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                files.append(Manifest.File(name: name, size: size))
            } catch {
                throw CoreError.io("read \(name): \(error)")
            }
        }
        guard files.contains(where: { $0.name == ProfileFileBinding.config.fileName }) else {
            throw CoreError.io("profile has no configuration")
        }
        // Whole seconds, as the manifest stores them, so the result equals what `inspect` reads back.
        func stored(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        let info = ProfileBackupInfo(profileID: id, name: summary.name, createdAt: stored(summary.createdAt),
                                     exportedAt: stored(Date()), fileCount: files.count,
                                     totalBytes: files.reduce(0) { $0 + $1.size })
        let manifest = Manifest(format: 1, info: info, lastLaunchedAt: summary.lastLaunchedAt,
                                profileKey: key.rawBytes, files: files)
        try write(manifest, sources: sources.map(\.handle), to: destination, password: password, iterations: iterations)
        return info
    }

    /// Writes `manifest` and the content of `sources` (one handle per `manifest.files` entry,
    /// same order, each positioned at its start) as a backup file.
    static func write(_ manifest: Manifest, sources: [FileHandle], to destination: URL, password: String,
                      iterations: Int) throws {
        precondition(sources.count == manifest.files.count)
        guard !password.isEmpty else { throw CoreError.invalidConfiguration("empty backup password") }
        let kdf = KDFParameters.generate(iterations: iterations)
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        let kdfJSON = try JSONCoding.encoder.encode(kdf)
        let manifestJSON = try JSONCoding.encoder.encode(manifest)
        guard kdfJSON.count <= maxKDFLength, manifestJSON.count <= maxManifestLength else {
            throw CoreError.invalidConfiguration("backup header too large")
        }

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CoreError.io("cannot create \(destination.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var header = magic
            header.append(version)
            header.append(bigEndian: UInt64(kdfJSON.count), bytes: 2)
            header.append(kdfJSON)
            try handle.write(contentsOf: header)

            let writer = try EncryptedChunkWriter(handle: handle, key: kek,
                                                  chunkSize: EncryptedDirectoryArchive.defaultChunkSize, info: streamInfo)
            try writer.write(Data(bigEndian: UInt64(manifestJSON.count), bytes: 4))
            try writer.write(manifestJSON)
            for (file, input) in zip(manifest.files, sources) {
                let nameBytes = Data(file.name.utf8)
                guard !nameBytes.isEmpty, nameBytes.count <= Int(UInt16.max) else {
                    throw CoreError.invalidConfiguration("backup entry name")
                }
                try writer.write(Data(bigEndian: UInt64(nameBytes.count), bytes: 2) + nameBytes
                                 + Data(bigEndian: file.size, bytes: 8))
                var remaining = file.size
                while remaining > 0 {
                    let piece = try input.read(upToCount: Int(min(remaining, UInt64(EncryptedDirectoryArchive.defaultChunkSize)))) ?? Data()
                    guard !piece.isEmpty else { throw CoreError.io("\(file.name) changed while backing up") }
                    try writer.write(piece)
                    remaining -= UInt64(piece.count)
                }
            }
            try writer.write(Data(bigEndian: 0, bytes: 2))
            try writer.finish()
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is CoreError { throw error }
            throw CoreError.io("write \(destination.lastPathComponent): \(error)")
        }
    }

    // MARK: Inspect / restore

    /// Reads the manifest. Verifies the password and the manifest, not the whole file
    /// (`restore` authenticates everything before it changes the vault).
    public static func inspect(_ url: URL, password: String) throws -> ProfileBackupInfo {
        let handle = try openForReading(url)
        defer { try? handle.close() }
        return try open(handle, password: password).manifest.info
    }

    /// Restores a backup into `repository`'s vault and returns the restored profile.
    ///
    /// Files are first unpacked (still encrypted) into a staging directory; nothing in the vault
    /// changes until the whole backup has authenticated and the configuration decrypts.
    ///
    /// The restored profile keeps the backup's ID and profile key when it takes the original's
    /// place (`automatic` into a vault without it, or `replaceExisting`). A copy gets a new ID
    /// and a new random profile key, so it shares no key with the original: every encrypted file
    /// is re-encrypted for it (`ProfileFileBinding` files; `webdata.pbsa` with its root labels
    /// renamed to the new ID). A `session.bin` that does not open under its expected binding is
    /// dropped from a copy — it only lists tabs to reopen.
    ///
    /// `replaceExisting` swaps the profile directory: the old one is moved aside first and moved
    /// back if anything fails (or by `ProfileRepository.removeOrphanedDirectories()` after a crash).
    /// The caller must make sure the profile is not running.
    @discardableResult
    public static func restore(from url: URL, password: String, into repository: ProfileRepository,
                               mode: RestoreMode = .automatic, name: String? = nil) throws -> ProfileSummary {
        let requestedName = try name.map(ProfileRepository.validatedName)
        let staging = repository.profilesDirectory
            .appendingPathComponent(ProfileRepository.restoreStagingPrefix + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try SecureFile.ensureDirectory(staging)

        let manifest: Manifest
        do {
            let handle = try openForReading(url)
            defer { try? handle.close() }
            let opened = try open(handle, password: password)
            manifest = opened.manifest
            try unpack(opened.reader, manifest: manifest, into: staging)
        }
        guard manifest.profileKey.count == 32 else { throw CoreError.corruptData("backup profile key length") }
        let original = manifest.info.profileID
        let originalKey = SymmetricKey(data: manifest.profileKey)

        let target: UUID
        switch mode {
        case .replaceExisting:
            guard repository.contains(original) else { throw CoreError.profileNotFound(original) }
            target = original
        case .automatic:
            target = repository.contains(original) || repository.wasDeleted(original) ? UUID() : original
        case .copy:
            target = UUID()
        }
        let key: SymmetricKey
        if target == original {
            key = originalKey
        } else {
            key = SymmetricKey(size: .bits256)
            try rebind(staging, from: (original, originalKey), to: (target, key))
        }

        // Sanity check before touching the vault: the configuration must open for its new home.
        let configURL = staging.appendingPathComponent(ProfileFileBinding.config.fileName)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CoreError.corruptData("backup has no configuration")
        }
        do {
            _ = try JSONCoding.decoder.decode(ProfileConfiguration.self,
                                              from: ProfileFileBinding.config.open(SecureFile.read(configURL),
                                                                                   profileID: target, profileKey: key))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.corruptData("backup configuration")
        }

        let sameProfile = target == original
        var summary = ProfileSummary(id: target, name: try requestedName ?? ProfileRepository.validatedName(manifest.info.name),
                                     createdAt: sameProfile ? manifest.info.createdAt : Date(),
                                     lastLaunchedAt: sameProfile ? manifest.lastLaunchedAt : nil, revision: 1)
        let destination = repository.directory(for: target)
        let existing = try repository.contains(target) ? repository.summary(for: target) : nil
        if let existing {
            summary.revision = existing.revision + 1 // sync sees the replacement as a change
        }
        let aside = repository.profilesDirectory.appendingPathComponent(
            "\(ProfileRepository.replacedDirectoryPrefix)\(target.uuidString)-\(UUID().uuidString)", isDirectory: true)
        let hasDirectory = FileManager.default.fileExists(atPath: destination.path)
        let keepAside = existing != nil && hasDirectory
        if keepAside {
            try move(destination, to: aside)
        } else if hasDirectory {
            try FileManager.default.removeItem(at: destination) // leftovers of a profile no longer in the index
        }
        var movedIn = false
        do {
            try move(staging, to: destination)
            movedIn = true
            try repository.installProfile(summary, key: key)
        } catch {
            if movedIn { try? FileManager.default.removeItem(at: destination) }
            if keepAside { try? move(aside, to: destination) }
            throw error
        }
        if keepAside { try? FileManager.default.removeItem(at: aside) }
        return summary
    }

    // MARK: Private

    private static func openForReading(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw CoreError.io("read \(url.lastPathComponent): \(error)")
        }
    }

    private static func open(_ handle: FileHandle, password: String) throws -> (reader: EncryptedChunkReader, manifest: Manifest) {
        let prefix = try EncryptedChunkReader.readExactly(handle, magic.count + 3, context: "backup header")
        guard prefix.prefix(magic.count) == magic else { throw CoreError.unsupportedFormat("not a profile backup") }
        guard prefix[prefix.startIndex + magic.count] == version else {
            throw CoreError.unsupportedFormat("backup version \(prefix[prefix.startIndex + magic.count])")
        }
        let kdfLength = Int(prefix.suffix(2).bigEndianValue)
        guard kdfLength > 0, kdfLength <= maxKDFLength else { throw CoreError.corruptData("backup header") }
        let kdf: KDFParameters
        do {
            kdf = try JSONCoding.decoder.decode(KDFParameters.self,
                                                from: EncryptedChunkReader.readExactly(handle, kdfLength, context: "backup header"))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.corruptData("backup KDF parameters")
        }
        // The parameters are not authenticated yet: refuse ones that would make us spin.
        guard kdf.iterations <= maxIterations else { throw CoreError.invalidConfiguration("backup KDF too expensive") }
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        let reader = try EncryptedChunkReader(handle: handle, key: kek, info: streamInfo)
        let manifestLength: Int
        do {
            manifestLength = Int(try reader.read(4).bigEndianValue)
        } catch CoreError.authenticationFailed {
            // The first chunk does not open: a wrong password (or a damaged first chunk —
            // indistinguishable by design).
            throw CoreError.wrongPassword
        }
        guard manifestLength > 0, manifestLength <= maxManifestLength else { throw CoreError.corruptData("backup manifest length") }
        let manifest: Manifest
        do {
            manifest = try JSONCoding.decoder.decode(Manifest.self, from: reader.read(manifestLength))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.corruptData("backup manifest")
        }
        guard manifest.format == 1 else { throw CoreError.unsupportedFormat("backup manifest format \(manifest.format)") }
        return (reader, manifest)
    }

    private static func unpack(_ reader: EncryptedChunkReader, manifest: Manifest, into staging: URL) throws {
        var expected = Dictionary(manifest.files.map { ($0.name, $0.size) }, uniquingKeysWith: { first, _ in first })
        guard expected.count == manifest.files.count else { throw CoreError.corruptData("backup lists a file twice") }
        while true {
            let nameLength = Int(try reader.read(2).bigEndianValue)
            if nameLength == 0 { break }
            guard let name = String(data: try reader.read(nameLength), encoding: .utf8), isSafeEntryName(name) else {
                throw CoreError.unsafeArchivePath("backup entry")
            }
            let size = try reader.read(8).bigEndianValue
            guard expected.removeValue(forKey: name) == size else { throw CoreError.corruptData("backup entry \(name)") }
            let output: FileHandle?
            if isBackupPath(name) {
                let target = staging.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CoreError.io("cannot create \(name)")
                }
                output = try FileHandle(forWritingTo: target)
            } else {
                output = nil // written by a newer build: authenticated below, then skipped
            }
            defer { try? output?.close() }
            var remaining = size
            while remaining > 0 {
                let piece = Int(min(remaining, UInt64(EncryptedDirectoryArchive.defaultChunkSize)))
                let bytes = try reader.read(piece)
                try output?.write(contentsOf: bytes)
                remaining -= UInt64(piece)
            }
        }
        try reader.finish()
        guard expected.isEmpty else { throw CoreError.corruptData("backup is missing \(expected.keys.sorted())") }
    }

    /// Re-encrypts a staged profile for a new ID and a new profile key.
    static func rebind(_ directory: URL, from old: (id: UUID, key: SymmetricKey),
                       to new: (id: UUID, key: SymmetricKey)) throws {
        for binding in ProfileFileBinding.allCases {
            let url = directory.appendingPathComponent(binding.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let resealed: Data
            do {
                resealed = try binding.reseal(SecureFile.read(url), from: old, to: new)
            } catch where binding == .session {
                // Not written under the expected binding (another build's format): the tabs to
                // reopen are not worth failing the restore for.
                try FileManager.default.removeItem(at: url)
                continue
            }
            try SecureFile.write(resealed, to: url)
        }
        let webData = directory.appendingPathComponent(webDataFile)
        if FileManager.default.fileExists(atPath: webData.path) {
            try EncryptedDirectoryArchive.reseal(from: webData, key: old.key, to: webData, newKey: new.key) {
                try WebKitDataLayout.relabel($0, from: old.id, to: new.id)
            }
        }
    }

    /// rename(2) that, unlike `SecureFile.replace`, never deletes `source` on failure: here the
    /// source can be a profile's only copy.
    private static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            let code = errno
            throw CoreError.io("rename \(source.lastPathComponent) to \(destination.lastPathComponent) failed: errno \(code)")
        }
    }
}

extension Data {
    init(bigEndian value: UInt64, bytes: Int) {
        self.init(count: bytes)
        for i in 0..<bytes { self[i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(bytes - 1 - i))) }
    }

    mutating func append(bigEndian value: UInt64, bytes: Int) {
        append(Data(bigEndian: value, bytes: bytes))
    }

    var bigEndianValue: UInt64 { reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
}
