#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct PasswordEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Normalised origin, `scheme://host[:port]`. Matching is exact-origin only
    /// (no subdomain or eTLD+1 matching) to avoid filling credentials into the wrong site.
    public var origin: String
    public var username: String
    public var password: String
    public var note: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), origin: String, username: String, password: String,
                note: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.origin = origin
        self.username = username
        self.password = password
        self.note = note
        self.updatedAt = updatedAt
    }

    /// `https://Example.com:443/path` → `https://example.com`. Returns nil for non-http(s) URLs.
    public static func normalizedOrigin(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

/// Per-profile credential store.
///
/// Key: HKDF(profileKey, "passwords") — the profile key is itself only reachable via the
/// vault master key, which is only reachable via the user's master password (PBKDF2).
/// The file is one AEAD blob; it is decrypted into memory when the vault is opened
/// and re-encrypted on every change.
///
/// LIMITATION: WKWebView has no public password-autofill integration (Safari's
/// AutoFill and the iCloud Keychain "Passwords" provider are not exposed to
/// third-party WKWebView hosts on macOS). The app layer offers explicit
/// "Fill" via JavaScript and answers HTTP Basic/Digest challenges from this vault.
public final class PasswordVault: @unchecked Sendable {
    private let fileURL: URL
    private let profileID: UUID
    private let key: SymmetricKey
    private let lock = NSLock()
    private var entries: [PasswordEntry]

    init(fileURL: URL, profileID: UUID, profileKey: SymmetricKey) throws {
        self.fileURL = fileURL
        self.profileID = profileID
        self.key = Self.fileKey(profileID: profileID, profileKey: profileKey)
        self.entries = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let plaintext = try AEAD.open(SecureFile.read(fileURL), key: key, aad: aad)
            entries = try JSONCoding.decoder.decode([PasswordEntry].self, from: plaintext)
        }
    }

    private var aad: String { Self.aad(profileID) }

    static func fileKey(profileID: UUID, profileKey: SymmetricKey) -> SymmetricKey {
        profileKey.derive(info: "passwords", salt: profileID.rawBytes)
    }

    static func aad(_ profileID: UUID) -> String { "passwords:v1:\(profileID.uuidString)" }

    public func allEntries() -> [PasswordEntry] {
        lock.withLock { entries.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) } }
    }

    public func entries(for url: URL) -> [PasswordEntry] {
        guard let origin = PasswordEntry.normalizedOrigin(for: url) else { return [] }
        return lock.withLock { entries.filter { $0.origin == origin } }
    }

    /// Inserts or replaces (same origin + username) an entry.
    public func upsert(_ entry: PasswordEntry) throws {
        try lock.withLock {
            var updated = entries.filter { !($0.origin == entry.origin && $0.username == entry.username) && $0.id != entry.id }
            var stamped = entry
            stamped.updatedAt = Date()
            updated.append(stamped)
            try persist(updated)
            entries = updated
        }
    }

    public func remove(id: UUID) throws {
        try lock.withLock {
            let updated = entries.filter { $0.id != id }
            try persist(updated)
            entries = updated
        }
    }

    private func persist(_ entries: [PasswordEntry]) throws {
        let plaintext = try JSONCoding.encoder.encode(entries)
        try SecureFile.write(AEAD.seal(plaintext, key: key, aad: aad), to: fileURL)
    }
}
