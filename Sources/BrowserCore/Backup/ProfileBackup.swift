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
/// `passwords.bin`, `history.bin`, `bookmarks.bin`, `webdata.pbsa` (cookies, localStorage, …) and
/// `downloads/`. The profile key travels inside the encrypted manifest, so a backup restores into
/// any vault (another Mac, a new master password) with only the backup password.
///
/// Changing any byte, truncating, or appending fails authentication, and a restore commits
/// nothing until the whole stream has authenticated. Not included: sync state, device settings
/// and quick unlock (all device-local), and the WebKit data of a running profile (backups
/// are made while the profile is stopped).
public enum ProfileBackup {
    public static let fileExtension = "pbbackup"
    static let magic = Data("PBBK".utf8)
    static let version: UInt8 = 1
    static let streamInfo = "profile-backup"
    static let maxIterations = 10_000_000

    public enum RestoreMode: Sendable, Equatable {
        /// Keep the profile's ID if this vault does not have it (and never deleted it); otherwise copy.
        case automatic
        /// Overwrite the existing profile with the same ID. The profile must not be running.
        case replaceExisting
        /// Always a new profile with a new ID (and therefore a new canvas identity).
        case copy
    }

    private struct Manifest: Codable {
        struct File: Codable { var name: String; var size: UInt64 }
        var format: Int
        var info: ProfileBackupInfo
        var lastLaunchedAt: Date?
        var profileKey: Data
        var files: [File]
    }

    /// Top-level files of a profile directory that belong in a backup.
    static let profileFiles = ["config.bin", "passwords.bin", "history.bin", "bookmarks.bin", "webdata.pbsa"]

    static func isBackupPath(_ path: String) -> Bool {
        if profileFiles.contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "downloads" else { return false }
        let name = String(parts[1])
        if name == "index.bin" { return true }
        let suffix = "." + DownloadVault.fileExtension
        return name.hasSuffix(suffix) && UUID(uuidString: String(name.dropLast(suffix.count))) != nil
    }

    // MARK: Export

    /// Writes a backup of a (stopped) profile to `destination`. The file is written in place —
    /// inside the App Sandbox a save panel grants access to that one file — and removed again
    /// if anything fails.
    @discardableResult
    public static func export(profile id: UUID, from repository: ProfileRepository, to destination: URL, password: String,
                              iterations: Int = KDFParameters.recommendedIterations) throws -> ProfileBackupInfo {
        guard !password.isEmpty else { throw CoreError.invalidConfiguration("empty backup password") }
        let summary = try repository.summary(for: id)
        let key = try repository.profileKey(for: id)
        let directory = repository.directory(for: id)
        var files: [Manifest.File] = []
        for name in try listFiles(in: directory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            files.append(Manifest.File(name: name, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0))
        }
        // Whole seconds, as the manifest stores them, so the result equals what `inspect` reads back.
        func stored(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        let info = ProfileBackupInfo(profileID: id, name: summary.name, createdAt: stored(summary.createdAt), exportedAt: stored(Date()),
                                     fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
        let manifest = Manifest(format: 1, info: info, lastLaunchedAt: summary.lastLaunchedAt,
                                profileKey: key.rawBytes, files: files)

        let kdf = KDFParameters.generate(iterations: iterations)
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        let kdfJSON = try JSONCoding.encoder.encode(kdf)
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
            let manifestJSON = try JSONCoding.encoder.encode(manifest)
            try writer.write(Data(bigEndian: UInt64(manifestJSON.count), bytes: 4))
            try writer.write(manifestJSON)
            for file in files {
                let nameBytes = Data(file.name.utf8)
                try writer.write(Data(bigEndian: UInt64(nameBytes.count), bytes: 2) + nameBytes
                                 + Data(bigEndian: file.size, bytes: 8))
                let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(file.name))
                defer { try? input.close() }
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
            throw error
        }
        return info
    }

    // MARK: Inspect / restore

    /// Reads the manifest (verifies the password and the manifest chunk, not the whole file).
    public static func inspect(_ url: URL, password: String) throws -> ProfileBackupInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try open(handle, password: password).manifest.info
    }

    /// Restores a backup into `repository`'s vault and returns the restored profile.
    ///
    /// Files are first unpacked (still encrypted) into a staging directory; nothing in the vault
    /// changes until the whole backup has authenticated and the configuration decrypts.
    /// A copy gets a new ID: the profile's ID-bound files (config, passwords, history, bookmarks,
    /// download index) are re-encrypted for it; WebKit data and download files are not bound to
    /// the ID and are kept as they are.
    @discardableResult
    public static func restore(from url: URL, password: String, into repository: ProfileRepository,
                               mode: RestoreMode = .automatic, name: String? = nil) throws -> ProfileSummary {
        let staging = repository.profilesDirectory.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try SecureFile.ensureDirectory(staging)

        let manifest: Manifest
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let opened = try open(handle, password: password)
            manifest = opened.manifest
            try unpack(opened.reader, manifest: manifest, into: staging)
        }
        guard manifest.profileKey.count == 32 else { throw CoreError.corruptData("backup profile key length") }
        let key = SymmetricKey(data: manifest.profileKey)
        let original = manifest.info.profileID

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
        if target != original {
            try rebind(staging, from: original, to: target, key: key)
        }
        // Sanity check before touching the vault: the configuration must open for its new home.
        let configURL = staging.appendingPathComponent("config.bin")
        _ = try JSONCoding.decoder.decode(ProfileConfiguration.self,
                                          from: AEAD.open(SecureFile.read(configURL), key: key,
                                                          aad: ProfileRepository.configAAD(target)))

        let destination = repository.directory(for: target)
        var summary = ProfileSummary(id: target, name: try validatedName(name ?? manifest.info.name),
                                     createdAt: target == original ? manifest.info.createdAt : Date(),
                                     lastLaunchedAt: target == original ? manifest.lastLaunchedAt : nil, revision: 1)
        if repository.contains(target) {
            let existing = try repository.summary(for: target)
            summary.revision = existing.revision + 1
            let old = repository.profilesDirectory.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
            let hadDirectory = FileManager.default.fileExists(atPath: destination.path)
            if hadDirectory { try SecureFile.replace(old, with: destination) }
            do {
                try SecureFile.replace(destination, with: staging)
            } catch {
                if hadDirectory { try? SecureFile.replace(destination, with: old) }
                throw error
            }
            try? FileManager.default.removeItem(at: old)
        } else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination) // orphaned leftovers
            }
            try SecureFile.replace(destination, with: staging)
        }
        try repository.installProfile(summary, key: key)
        return summary
    }

    // MARK: Private

    private static func listFiles(in directory: URL) throws -> [String] {
        var names = profileFiles.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: downloads.path) {
            names += contents.sorted().map { "downloads/\($0)" }.filter(isBackupPath)
        }
        guard names.contains("config.bin") else { throw CoreError.io("profile has no configuration") }
        return names
    }

    private static func open(_ handle: FileHandle, password: String) throws -> (reader: EncryptedChunkReader, manifest: Manifest) {
        let prefix = try EncryptedChunkReader.readExactly(handle, magic.count + 3, context: "backup header")
        guard prefix.prefix(magic.count) == magic else { throw CoreError.unsupportedFormat("not a profile backup") }
        guard prefix[prefix.startIndex + magic.count] == version else {
            throw CoreError.unsupportedFormat("backup version \(prefix[prefix.startIndex + magic.count])")
        }
        let kdfLength = Int(prefix.suffix(2).bigEndianValue)
        guard kdfLength > 0, kdfLength <= 4096 else { throw CoreError.corruptData("backup header") }
        let kdf: KDFParameters
        do {
            kdf = try JSONCoding.decoder.decode(KDFParameters.self,
                                                from: EncryptedChunkReader.readExactly(handle, kdfLength, context: "backup header"))
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.corruptData("backup KDF parameters")
        }
        guard kdf.iterations <= maxIterations else { throw CoreError.invalidConfiguration("backup KDF too expensive") }
        let kek = try KeyDerivation.deriveKey(password: password, parameters: kdf)
        let reader = try EncryptedChunkReader(handle: handle, key: kek, info: streamInfo)
        let manifestLength: Int
        do {
            manifestLength = Int(try reader.read(4).bigEndianValue)
        } catch CoreError.authenticationFailed {
            throw CoreError.wrongPassword
        }
        guard manifestLength > 0, manifestLength <= 16 << 20 else { throw CoreError.corruptData("backup manifest length") }
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
        while true {
            let nameLength = Int(try reader.read(2).bigEndianValue)
            if nameLength == 0 { break }
            guard let name = String(data: try reader.read(nameLength), encoding: .utf8), isBackupPath(name) else {
                throw CoreError.unsafeArchivePath("backup entry")
            }
            let size = try reader.read(8).bigEndianValue
            guard expected.removeValue(forKey: name) == size else { throw CoreError.corruptData("backup entry \(name)") }
            let target = staging.appendingPathComponent(name)
            try SecureFile.ensureDirectory(target.deletingLastPathComponent())
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CoreError.io("cannot create \(name)")
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var remaining = size
            while remaining > 0 {
                let piece = Int(min(remaining, UInt64(EncryptedDirectoryArchive.defaultChunkSize)))
                try output.write(contentsOf: try reader.read(piece))
                remaining -= UInt64(piece)
            }
        }
        try reader.finish()
        guard expected.isEmpty else { throw CoreError.corruptData("backup is missing \(expected.keys.sorted())") }
    }

    /// Re-encrypts the ID-bound files of a staged profile for `newID` (same profile key).
    private static func rebind(_ directory: URL, from oldID: UUID, to newID: UUID, key: SymmetricKey) throws {
        func reseal(_ name: String, _ transform: (Data) throws -> Data) throws {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try SecureFile.write(transform(SecureFile.read(url)), to: url)
        }
        func document<D: Codable>(_ make: @escaping (UUID) -> EncryptedDocumentFile<D>) -> (Data) throws -> Data {
            { try make(newID).encode(make(oldID).decode($0)) }
        }
        try reseal("config.bin") {
            try AEAD.seal(AEAD.open($0, key: key, aad: ProfileRepository.configAAD(oldID)),
                          key: key, aad: ProfileRepository.configAAD(newID))
        }
        try reseal("passwords.bin") {
            try AEAD.seal(AEAD.open($0, key: PasswordVault.fileKey(profileID: oldID, profileKey: key), aad: PasswordVault.aad(oldID)),
                          key: PasswordVault.fileKey(profileID: newID, profileKey: key), aad: PasswordVault.aad(newID))
        }
        try reseal("history.bin", document { HistoryStore.file(url: nil, profileID: $0, profileKey: key) })
        try reseal("bookmarks.bin", document { BookmarkStore.file(url: nil, profileID: $0, profileKey: key) })
        try reseal("downloads/index.bin", document { DownloadVault.indexFile(url: nil, profileID: $0, profileKey: key) })
    }

    private static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            throw CoreError.invalidConfiguration("profile name must be 1–128 characters")
        }
        return trimmed
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
