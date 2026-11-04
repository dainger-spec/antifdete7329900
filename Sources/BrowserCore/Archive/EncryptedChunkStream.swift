#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Streaming authenticated encryption for large payloads (WebKit data directories
/// can be hundreds of MB, so they are never held in memory as a whole).
///
/// File format (all integers big-endian):
/// ```
/// header  = magic "PBSA" | version u8 (=1) | chunkSize u32 | salt [32]
/// chunk*  = sealedLength u32 | ciphertext [sealedLength-16] | tag [16]
/// ```
/// * Per-archive key: HKDF-SHA256(profileKey, salt: header.salt, info: "webdata-archive").
///   A fresh random salt per archive means the key is never reused across archives,
///   so nonces can be deterministic.
/// * Nonce of chunk i: `00 00 00 00 || u64(i)`.
/// * AAD of chunk i:   `header || u64(i) || finalFlag u8`.
/// The final chunk is flagged (and may be empty); a reader rejects a stream that ends
/// without a final chunk (truncation), has data after it (extension), or has
/// reordered/duplicated chunks (index is bound into nonce + AAD).
enum EncryptedChunkStream {
    static let magic = Data("PBSA".utf8)
    static let version: UInt8 = 1
    static let saltLength = 32
    static let tagLength = 16
    static let headerLength = 4 + 1 + 4 + saltLength
    static let maxChunkSize = 16 << 20

    static func archiveKey(_ key: SymmetricKey, salt: Data) -> SymmetricKey {
        key.derive(info: "webdata-archive", salt: salt)
    }

    /// Throws `CoreError.newerFormat` when `url` holds an archive of a newer version than this one
    /// writes: it is never replaced (docs/UPDATES.md §4). Anything else there — no file, not an
    /// archive, an archive of this version — is left to the writer as before.
    static func guardOverwrite(of url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.count + 1), head.count == magic.count + 1,
              head.prefix(magic.count) == magic else { return }
        let found = head[head.startIndex + magic.count]
        guard found <= version else {
            throw CoreError.newerFormat(what: url.lastPathComponent, found: Int(found), supported: Int(version))
        }
    }

    static func nonce(_ index: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: index.bigEndian) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func aad(header: Data, index: UInt64, final: Bool) -> Data {
        var aad = header
        withUnsafeBytes(of: index.bigEndian) { aad.append(contentsOf: $0) }
        aad.append(final ? 1 : 0)
        return aad
    }
}

final class EncryptedChunkWriter {
    private let handle: FileHandle
    private let key: SymmetricKey
    private let header: Data
    private let chunkSize: Int
    private var buffer = Data()
    private var index: UInt64 = 0
    private var finished = false

    init(handle: FileHandle, key: SymmetricKey, chunkSize: Int) throws {
        precondition(chunkSize > 0 && chunkSize <= EncryptedChunkStream.maxChunkSize)
        self.handle = handle
        self.chunkSize = chunkSize
        let salt = secureRandomBytes(EncryptedChunkStream.saltLength)
        var header = EncryptedChunkStream.magic
        header.append(EncryptedChunkStream.version)
        withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { header.append(contentsOf: $0) }
        header.append(salt)
        self.header = header
        self.key = EncryptedChunkStream.archiveKey(key, salt: salt)
        try handle.write(contentsOf: header)
    }

    func write(_ data: Data) throws {
        precondition(!finished)
        buffer.append(data)
        while buffer.count > chunkSize {
            try emit(Data(buffer.prefix(chunkSize)), final: false)
            buffer = Data(buffer.dropFirst(chunkSize))
        }
    }

    func finish() throws {
        precondition(!finished)
        try emit(buffer, final: true)
        buffer = Data()
        finished = true
    }

    private func emit(_ plaintext: Data, final: Bool) throws {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: EncryptedChunkStream.nonce(index),
                                   authenticating: EncryptedChunkStream.aad(header: header, index: index, final: final))
        var record = Data()
        withUnsafeBytes(of: UInt32(box.ciphertext.count + EncryptedChunkStream.tagLength).bigEndian) {
            record.append(contentsOf: $0)
        }
        record.append(box.ciphertext)
        record.append(box.tag)
        try handle.write(contentsOf: record)
        index += 1
    }
}

final class EncryptedChunkReader {
    private let handle: FileHandle
    private let key: SymmetricKey
    private let header: Data
    private let chunkSize: Int
    private var buffer = Data()
    private var index: UInt64 = 0
    private var sawFinal = false

    /// `name`: the archive's file name, for a refusal's message.
    init(handle: FileHandle, key: SymmetricKey, name: String = "a PBSA archive") throws {
        self.handle = handle
        let header = try Self.readExactly(handle, EncryptedChunkStream.headerLength, context: "header")
        guard header.prefix(4) == EncryptedChunkStream.magic else { throw CoreError.unsupportedFormat("not a PBSA archive") }
        let version = header[header.startIndex + 4]
        // A newer version's archive is refused before anything is read from it (docs/UPDATES.md §4).
        guard version <= EncryptedChunkStream.version else {
            throw CoreError.newerFormat(what: name, found: Int(version), supported: Int(EncryptedChunkStream.version))
        }
        guard version == EncryptedChunkStream.version else { throw CoreError.unsupportedFormat("PBSA version \(version)") }
        let chunkSize = header.subdata(in: (header.startIndex + 5)..<(header.startIndex + 9))
            .reduce(0) { ($0 << 8) | Int($1) }
        guard chunkSize > 0, chunkSize <= EncryptedChunkStream.maxChunkSize else {
            throw CoreError.corruptData("chunk size \(chunkSize)")
        }
        let salt = header.suffix(EncryptedChunkStream.saltLength)
        self.header = header
        self.chunkSize = chunkSize
        self.key = EncryptedChunkStream.archiveKey(key, salt: Data(salt))
    }

    /// Returns exactly `count` plaintext bytes or throws.
    func read(_ count: Int) throws -> Data {
        while buffer.count < count {
            guard !sawFinal else { throw CoreError.corruptData("archive payload ended early") }
            try readChunk()
        }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }

    /// Verifies the stream ended cleanly: final chunk seen, all plaintext consumed, no trailing bytes.
    func finish() throws {
        while !sawFinal { try readChunk() }
        guard buffer.isEmpty else { throw CoreError.corruptData("unconsumed archive payload") }
        let trailing = try handle.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else { throw CoreError.corruptData("data after final chunk") }
    }

    private func readChunk() throws {
        let lengthBytes = try Self.readExactly(handle, 4, context: "chunk length")
        let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        guard length >= EncryptedChunkStream.tagLength, length <= chunkSize + EncryptedChunkStream.tagLength else {
            throw CoreError.corruptData("chunk length \(length)")
        }
        let sealed = try Self.readExactly(handle, length, context: "chunk")
        let ciphertext = sealed.prefix(length - EncryptedChunkStream.tagLength)
        let tag = sealed.suffix(EncryptedChunkStream.tagLength)
        let nonce = try EncryptedChunkStream.nonce(index)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        // The final flag is not stored in the clear: try "not final" first, then "final".
        // Exactly one can authenticate, so an attacker cannot flip it.
        let plaintext: Data
        if let opened = try? AES.GCM.open(box, using: key,
                                          authenticating: EncryptedChunkStream.aad(header: header, index: index, final: false)) {
            plaintext = opened
        } else if let opened = try? AES.GCM.open(box, using: key,
                                                 authenticating: EncryptedChunkStream.aad(header: header, index: index, final: true)) {
            plaintext = opened
            sawFinal = true
        } else {
            throw CoreError.authenticationFailed
        }
        buffer.append(plaintext)
        index += 1
    }

    static func readExactly(_ handle: FileHandle, _ count: Int, context: String) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let piece = try handle.read(upToCount: count - result.count), !piece.isEmpty else {
                throw CoreError.corruptData("truncated archive (\(context))")
            }
            result.append(piece)
        }
        return result
    }
}
