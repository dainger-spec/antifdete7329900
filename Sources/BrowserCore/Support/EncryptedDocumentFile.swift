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
struct EncryptedDocumentFile<Document: Codable> {
    let url: URL?
    let key: SymmetricKey
    let aad: String

    func load() throws -> Document? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(SecureFile.read(url))
    }

    func save(_ document: Document) throws {
        guard let url else { return }
        try SecureFile.write(encode(document), to: url)
    }

    func encode(_ document: Document) throws -> Data {
        try AEAD.seal(JSONCoding.encoder.encode(document), key: key, aad: aad)
    }

    func decode(_ sealed: Data) throws -> Document {
        try JSONCoding.decoder.decode(Document.self, from: AEAD.open(sealed, key: key, aad: aad))
    }
}

extension UUID {
    var rawBytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}
