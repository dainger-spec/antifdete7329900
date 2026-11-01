#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A small Codable document persisted as a single AEAD blob (`AEAD(key, JSON)`), written
/// atomically with mode 0600. Used by the per-profile history and bookmark stores.
///
/// `url == nil` makes the document memory-only (ephemeral profiles): `save` is a no-op.
///
/// The format rule of the vault's files (`DocumentFormat`, docs/UPDATES.md §4): a document that
/// declares a format newer than `supportedFormat` is refused when read, and never written over.
/// And the owner's rule (docs/DESTRUCTIVE_PATHS.md): a document that does not open is never
/// deleted or written over — a save or a removal moves it aside first (`makeWay`).
struct EncryptedDocumentFile<Document: Codable> {
    let url: URL?
    let key: SymmetricKey
    let aad: String
    /// The newest format this version reads and writes of this document.
    var supportedFormat = 1

    /// The file's name, for a refusal's message.
    private var what: String { url?.lastPathComponent ?? "an encrypted document" }

    func load() throws -> Document? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(SecureFile.read(url))
    }

    /// Writes `document` — never over a newer version's file, nor over one that does not open
    /// (moved aside first, `makeWay`).
    func save(_ document: Document) throws {
        guard let url else { return }
        try makeWay(at: url)
        try SecureFile.write(encode(document), to: url)
    }

    /// Deletes the file — never a newer version's, which is refused like a save over it, nor one
    /// that does not open, which is moved aside instead (`makeWay`).
    func remove() throws {
        guard let url else { return }
        guard try makeWay(at: url) == nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Before a write or a removal, the file there: a newer version's refuses it
    /// (`CoreError.newerFormat`, docs/UPDATES.md §4); one that does not open — damaged, cut short,
    /// another key's — is moved aside as `<file>.unreadable` (then `-2`, …): nothing unreadable is
    /// ever deleted or written over (docs/DESTRUCTIVE_PATHS.md). Returns where it went, when it was
    /// moved. "Opens" is decrypted with this key: what decrypts but no longer decodes would only be
    /// a writer's bug, and is not told apart here.
    @discardableResult
    func makeWay(at url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let sealed = try? SecureFile.read(url), let json = try? AEAD.open(sealed, key: key, aad: aad) else {
            return try SecureFile.moveAside(url, suffix: "unreadable")
        }
        try DocumentFormat.check(json, supported: supportedFormat, what: what)
        return nil
    }

    /// The JSON of a sealed copy, undecoded (sync looks at a remote copy's format first).
    func open(_ sealed: Data) throws -> Data {
        try AEAD.open(sealed, key: key, aad: aad)
    }

    func encode(_ document: Document) throws -> Data {
        try AEAD.seal(JSONCoding.encoder.encode(document), key: key, aad: aad)
    }

    func decode(_ sealed: Data) throws -> Document {
        let json = try AEAD.open(sealed, key: key, aad: aad)
        try DocumentFormat.check(json, supported: supportedFormat, what: what)
        return try JSONCoding.decoder.decode(Document.self, from: json)
    }
}

extension UUID {
    var rawBytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}
