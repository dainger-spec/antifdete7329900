#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A profile carried whole from one vault to another — another Mac, a backup, a colleague — as
/// one file, encrypted with a password of its own (`.pbprofile`).
///
/// WHAT IS IN IT. Everything the profile is: its name and settings (the proxy with its
/// credentials, device, language and time zone choices…), its saved passwords, history,
/// bookmarks and last warm-up plan, its website data (`webdata.pbsa`: cookies, localStorage,
/// IndexedDB, caches — what makes a warmed-up profile worth carrying) and Safari's own state of
/// it (`safarihome.pbsa`, for a profile whose window is Safari's chrome). Not what belongs to this
/// Mac: the synced-cookie record and its baseline (sync rebuilds them), cookies queued for the
/// next launch (they are applied first, when the profile next runs here), the exit IP last seen.
///
/// FILE FORMAT (integers big-endian):
/// ```
/// magic "PBPROFILE1\n" | headerLength u32 | header JSON | documentsLength u32 | documents | archive
/// header    = { format, kdf (Argon2id parameters and salt), manifest: AEAD(manifestKey, Manifest JSON) }
/// documents = AEAD(documentsKey, Documents JSON)   passwords, history, bookmarks, warm-up plan
/// archive   = EncryptedDirectoryArchive under archiveKey: roots "webdata~<label>" and "safarihome"
/// fileKey   = Argon2id(password, kdf); manifestKey, documentsKey, archiveKey = HKDF(fileKey, purpose)
/// ```
/// The manifest is sealed apart so that a file can be described (name, what it holds) before it
/// is imported, without reading the rest. Nothing of the profile is ever written in plaintext,
/// by the export or by the import: the website data and Safari's state go from one archive to the
/// other through memory (`EncryptedDirectoryArchive.transcode`), re-encrypted on the way.
///
/// The profile must be stopped while it is exported: its website data is then sealed, which is
/// the only state in which it is complete.
public enum ProfileTransfer {
    public static let fileExtension = "pbprofile"
    static let magic = Data("PBPROFILE1\n".utf8)
    static let format = 1

    /// What a file holds, readable with its password before it is imported.
    public struct Manifest: Codable, Equatable, Sendable {
        public var name: String
        public var configuration: ProfileConfiguration
        public var profileCreatedAt: Date
        public var exportedAt: Date
        public var passwordCount: Int
        public var historyCount: Int
        public var bookmarkCount: Int
        /// The file carries the profile's website data (cookies, storage).
        public var hasWebsiteData: Bool
        /// The file carries Safari's own state of the profile.
        public var hasSafariState: Bool
    }

    struct Header: Codable {
        var format: Int
        var kdf: KDFParameters
        var manifest: Data
    }

    struct Documents: Codable {
        var passwords: [PasswordEntry]
        var history: HistoryDocument?
        var bookmarks: BookmarkDocument?
        var warmUpPlan: WarmUpPlan?
    }

    private struct Keys {
        let manifest: SymmetricKey
        let documents: SymmetricKey
        let archive: SymmetricKey

        init(password: String, kdf: KDFParameters) throws {
            let file = try KeyDerivation.deriveKey(password: password, parameters: kdf)
            manifest = file.derive(info: "pbprofile-manifest", salt: kdf.salt)
            documents = file.derive(info: "pbprofile-documents", salt: kdf.salt)
            archive = file.derive(info: "pbprofile-archive", salt: kdf.salt)
        }
    }

    static let manifestAAD = "pbprofile:v1:manifest"
    static let documentsAAD = "pbprofile:v1:documents"
    static let webDataPrefix = "webdata~"
    static let safariHomeRoot = "safarihome"
    /// The root label `SafariHomeVault` seals the home directory under.
    public static let safariHomeLabel = "safari-home"

    // MARK: Export

    /// Writes profile `id` of `repository` to `destination`, encrypted with `password`. The profile
    /// must not be running. `kdf` is the key derivation for the file (Argon2id by default; tests
    /// pass a fast one).
    @discardableResult
    public static func export(_ id: UUID, from repository: ProfileRepository, to destination: URL, password: String,
                              kdf: KDFParameters = .recommended(), now: Date = Date()) throws -> Manifest {
        guard !password.isEmpty else { throw CoreError.invalidConfiguration("an export needs a password") }
        let key = try repository.profileKey(for: id)
        let summary = try repository.summary(for: id)
        let configuration = try repository.loadConfiguration(id, key: key)
        let documents = Documents(
            passwords: try repository.passwordVault(for: id).allEntries(),
            history: try HistoryStore.file(url: repository.historyURL(for: id), profileID: id, profileKey: key).load(),
            bookmarks: try BookmarkStore.file(url: repository.bookmarksURL(for: id), profileID: id, profileKey: key).load(),
            warmUpPlan: try repository.warmUpPlan(for: id))

        let webData = repository.webDataArchiveURL(for: id)
        let safariHome = repository.safariHomeArchiveURL(for: id)
        var sources: [EncryptedDirectoryArchive.TranscodeSource] = []
        var kinds: [String] = []
        if FileManager.default.fileExists(atPath: webData.path) {
            sources.append(.init(url: webData, key: key))
            kinds.append(webDataPrefix)
        }
        if FileManager.default.fileExists(atPath: safariHome.path) {
            sources.append(.init(url: safariHome, key: key))
            kinds.append(safariHomeRoot)
        }
        let manifest = Manifest(name: summary.name, configuration: configuration, profileCreatedAt: summary.createdAt,
                                exportedAt: now, passwordCount: documents.passwords.count,
                                historyCount: documents.history?.entries.count ?? 0,
                                bookmarkCount: documents.bookmarks?.bookmarks.count ?? 0,
                                hasWebsiteData: kinds.contains(webDataPrefix), hasSafariState: kinds.contains(safariHomeRoot))
        let keys = try Keys(password: password, kdf: kdf)
        let header = Header(format: format, kdf: kdf,
                            manifest: try AEAD.seal(JSONCoding.encoder.encode(manifest), key: keys.manifest, aad: manifestAAD))
        let sealedDocuments = try AEAD.seal(JSONCoding.encoder.encode(documents), key: keys.documents, aad: documentsAAD)
        var prefix = magic
        try appendLengthPrefixed(JSONCoding.encoder.encode(header), to: &prefix)
        try appendLengthPrefixed(sealedDocuments, to: &prefix)

        try EncryptedDirectoryArchive.transcode(
            sources: sources, to: [.init(url: destination, key: keys.archive, prefix: prefix)]) { source, label in
            kinds[source] == webDataPrefix ? (destination: 0, label: webDataPrefix + label) : (destination: 0, label: safariHomeRoot)
        }
        // A profile with no website data at all still makes a complete file: the archive part is
        // then empty, and written here.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try EncryptedDirectoryArchive.seal(roots: [:], to: destination.appendingPathExtension("archive"), key: keys.archive)
            defer { try? FileManager.default.removeItem(at: destination.appendingPathExtension("archive")) }
            var file = prefix
            file.append(try Data(contentsOf: destination.appendingPathExtension("archive")))
            try SecureFile.write(file, to: destination)
        }
        return manifest
    }

    // MARK: Reading

    /// The file's manifest, with its password. Throws `CoreError.authenticationFailed` for a
    /// wrong password, and a format error for a file that is not a profile export.
    public static func manifest(of url: URL, password: String) throws -> Manifest {
        let parsed = try parse(url)
        let keys = try Keys(password: password, kdf: parsed.header.kdf)
        return try JSONCoding.decoder.decode(Manifest.self, from: AEAD.open(parsed.header.manifest, key: keys.manifest, aad: manifestAAD))
    }

    // MARK: Import

    /// Makes a new profile in `repository` from the file: a new identity (its own id and key — the
    /// file can be imported more than once, or into the vault it came from), named `name` or as in
    /// the file. Returns it; on any failure nothing of it is left behind.
    @discardableResult
    public static func importProfile(from url: URL, password: String, into repository: ProfileRepository,
                                     name: String? = nil) throws -> ProfileSummary {
        let parsed = try parse(url)
        let keys = try Keys(password: password, kdf: parsed.header.kdf)
        let manifest = try JSONCoding.decoder.decode(Manifest.self, from: AEAD.open(parsed.header.manifest, key: keys.manifest, aad: manifestAAD))
        let documents = try JSONCoding.decoder.decode(Documents.self, from: AEAD.open(parsed.documents, key: keys.documents, aad: documentsAAD))

        var configuration = manifest.configuration
        // What was learnt about the proxy on the other Mac is not this one's to trust.
        configuration.lastProxyLocation?.exitIP = nil
        configuration.webRTCRelay = nil
        let summary = try repository.create(name: name ?? manifest.name, configuration: configuration)
        let id = summary.id
        do {
            let key = try repository.profileKey(for: id)
            let vault = try repository.passwordVault(for: id)
            for entry in documents.passwords { try vault.upsert(entry) }
            if let history = documents.history {
                try HistoryStore.file(url: repository.historyURL(for: id), profileID: id, profileKey: key).save(history)
            }
            if let bookmarks = documents.bookmarks {
                try BookmarkStore.file(url: repository.bookmarksURL(for: id), profileID: id, profileKey: key).save(bookmarks)
            }
            if let plan = documents.warmUpPlan { try repository.saveWarmUpPlan(plan, for: id) }
            // The website data and Safari's state, re-encrypted under the new profile's key, the
            // website data's roots renamed after the new profile (WebKit names its directories
            // after the store's identifier, and the archive's labels follow them).
            try EncryptedDirectoryArchive.transcode(
                sources: [.init(url: url, offset: parsed.archiveOffset, key: keys.archive)],
                to: [.init(url: repository.webDataArchiveURL(for: id), key: key),
                     .init(url: repository.safariHomeArchiveURL(for: id), key: key)]) { _, label in
                if label == safariHomeRoot { return (destination: 1, label: safariHomeLabel) }
                guard label.hasPrefix(webDataPrefix) else { return nil }
                return (destination: 0, label: try relabel(String(label.dropFirst(webDataPrefix.count)), to: id))
            }
        } catch {
            try? repository.delete(id)
            throw error
        }
        return summary
    }

    /// A website-data label (`WebKit|<bundle>|WebsiteDataStore|<uuid>`) with its last component —
    /// the store's identifier — replaced by `id`, in the same letter case.
    static func relabel(_ label: String, to id: UUID) throws -> String {
        var components = label.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let last = components.last, UUID(uuidString: last) != nil, components.count >= 3 else {
            throw CoreError.unsafeArchivePath(label)
        }
        components[components.count - 1] = last == last.lowercased() ? id.uuidString.lowercased() : id.uuidString
        return components.joined(separator: "|")
    }

    // MARK: File structure

    private struct Parsed {
        let header: Header
        let documents: Data
        let archiveOffset: UInt64
    }

    private static func parse(_ url: URL) throws -> Parsed {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard (try handle.read(upToCount: magic.count) ?? Data()) == magic else {
            throw CoreError.unsupportedFormat("not a PrivacyBrowser profile export")
        }
        let headerData = try readLengthPrefixed(handle)
        let header = try JSONCoding.decoder.decode(Header.self, from: headerData)
        guard header.format == format else { throw CoreError.unsupportedFormat("profile export format \(header.format)") }
        let documents = try readLengthPrefixed(handle)
        return Parsed(header: header, documents: documents, archiveOffset: try handle.offset())
    }

    private static let maxSectionLength = 512 << 20

    private static func appendLengthPrefixed(_ data: Data, to output: inout Data) throws {
        guard data.count <= maxSectionLength else { throw CoreError.invalidConfiguration("section too large") }
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { output.append(contentsOf: $0) }
        output.append(data)
    }

    private static func readLengthPrefixed(_ handle: FileHandle) throws -> Data {
        let length = try EncryptedChunkReader.readExactly(handle, 4, context: "section length").reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxSectionLength else { throw CoreError.corruptData("section length \(length)") }
        return try EncryptedChunkReader.readExactly(handle, length, context: "section")
    }
}
