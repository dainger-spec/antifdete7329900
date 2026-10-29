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

    func save(_ document: Document) throws {
        guard let url else { return }
        try DocumentFormat.guardOverwrite(of: url, supported: supportedFormat, what: what) {
            try AEAD.open($0, key: key, aad: aad)
        }
        try SecureFile.write(encode(document), to: url)
    }

    /// Deletes the file — never one that declares a newer format than `supportedFormat`, which
    /// is refused like a save over it.
    func remove() throws {
        guard let url else { return }
        try DocumentFormat.guardOverwrite(of: url, supported: supportedFormat, what: what) {
            try AEAD.open($0, key: key, aad: aad)
        }
        try? FileManager.default.removeItem(at: url)
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
