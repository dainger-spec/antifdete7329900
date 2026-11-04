#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What a profile's own process is given to run that profile, and no more: the profile's entry in
/// the index (its name, dates and revision) and the profile's key.
///
/// Not the vault master key. A process holding that can decrypt every profile of the vault, this
/// Mac's settings, the proxy list and the sync keys, and a profile's process is the one that loads
/// websites and, with Safari's chrome, Safari's own frameworks: it gets the one profile it runs.
/// Not the index key either, which would show it the other profiles' names. A vault opened with a
/// grant (`MasterVault.open(in:grant:)`) refuses everything else with `CoreError.notGranted`.
///
/// Handed over on a pipe as one binary record (`encoded()`, `read(_:)`), never on a command line,
/// in the environment or on disk.
///
/// `@unchecked`: `SymmetricKey` is immutable but not marked Sendable in swift-crypto.
public struct ProfileGrant: @unchecked Sendable {
    public let summary: ProfileSummary
    let key: SymmetricKey

    public var profileID: UUID { summary.id }

    init(summary: ProfileSummary, key: SymmetricKey) {
        self.summary = summary
        self.key = key
    }

    static let magic = Data("PBG1".utf8)
    static let maximumSummaryLength = 64 * 1024

    /// The record: `PBG1`, the profile key (32 bytes), the summary's length (4 bytes, big-endian)
    /// and the summary (JSON). It holds the key in the clear: wipe it once it is written (`erase`).
    public func encoded() throws -> Data {
        let summaryData = try JSONCoding.encoder.encode(summary)
        var record = Self.magic
        record.append(key.rawBytes)
        withUnsafeBytes(of: UInt32(summaryData.count).bigEndian) { record.append(contentsOf: $0) }
        record.append(summaryData)
        return record
    }

    /// Reads one record from a stream. `next(n)` returns up to `n` bytes, or nothing at the end of
    /// the stream. Exactly the record is read and nothing after it: what follows on the same
    /// stream is the caller's.
    public static func read(_ next: (Int) -> Data?) throws -> ProfileGrant {
        func exactly(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let chunk = next(count - data.count), !chunk.isEmpty else {
                    throw CoreError.corruptData("profile grant ends after \(data.count) of \(count) bytes")
                }
                data.append(chunk)
            }
            return data
        }
        guard try exactly(magic.count) == magic else { throw CoreError.unsupportedFormat("not a profile grant") }
        var raw = try exactly(32)
        defer { wipe(&raw) }
        let length = Int(try exactly(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length > 0, length <= maximumSummaryLength else {
            throw CoreError.corruptData("profile grant summary length \(length)")
        }
        let summary = try JSONCoding.decoder.decode(ProfileSummary.self, from: exactly(length))
        return ProfileGrant(summary: summary, key: SymmetricKey(data: raw))
    }

    /// Overwrites a record (`encoded()`) once it has been written where it was going.
    public static func erase(_ record: inout Data) {
        wipe(&record)
    }
}
