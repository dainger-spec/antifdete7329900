#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where a vault keeps each profile's files. Naming them needs no key.
public struct ProfileFileLocations: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var profilesDirectory: URL { root.appendingPathComponent("profiles", isDirectory: true) }

    public func directory(for id: UUID) -> URL {
        profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func webDataArchiveURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("webdata.pbsa") }
    func configURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("config.bin") }
    func passwordsURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("passwords.bin") }
    func historyURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("history.bin") }
    func bookmarksURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("bookmarks.bin") }
}

/// One profile's files, opened with that profile's key alone: what a profile's own process may
/// read and write (docs/PROCESS_PER_PROFILE.md). The vault key, the index (profile names) and the
/// other profiles stay out of its reach.
public struct SingleProfileFiles {
    public let locations: ProfileFileLocations
    public let profileID: UUID
    private let key: SymmetricKey

    public init(root: URL, profileID: UUID, key: SymmetricKey) {
        self.locations = ProfileFileLocations(root: root)
        self.profileID = profileID
        self.key = key
    }

    public var webDataArchiveURL: URL { locations.webDataArchiveURL(for: profileID) }

    /// The stored configuration; another profile's key does not open it.
    public func loadConfiguration() throws -> ProfileConfiguration {
        let sealed = try SecureFile.read(locations.configURL(for: profileID))
        let plaintext = try AEAD.open(sealed, key: key, aad: ProfileRepository.configAAD(profileID))
        return try JSONCoding.decoder.decode(ProfileConfiguration.self, from: plaintext)
    }

    /// As `ProfileRepository.historyStore(for:key:policy:persistent:)`.
    public func historyStore(policy: HistoryStore.Policy = .init(), persistent: Bool = true) throws -> HistoryStore {
        try HistoryStore(file: HistoryStore.file(url: persistent ? locations.historyURL(for: profileID) : nil,
                                                 profileID: profileID, profileKey: key),
                         policy: policy)
    }

    public func bookmarkStore() throws -> BookmarkStore {
        try BookmarkStore(file: BookmarkStore.file(url: locations.bookmarksURL(for: profileID), profileID: profileID, profileKey: key))
    }

    public func passwordVault() throws -> PasswordVault {
        try PasswordVault(fileURL: locations.passwordsURL(for: profileID), profileID: profileID, profileKey: key)
    }
}
