#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct PasswordEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Normalised origin the login was saved on, `scheme://host[:port]` (`WebOrigin.serialized`).
    /// It is offered on that origin and on the rest of its site (`PasswordMatching`); HTTP
    /// authentication uses exact-origin matches only.
    public var origin: String
    /// Empty for a password saved without one (shown as "Saved password", as Safari does).
    public var username: String
    public var password: String
    public var note: String?
    public var updatedAt: Date
    /// When it was last filled into a page: the most recently used login is offered first. Nil
    /// for one never filled, or saved by an older build (which leaves the field out when it
    /// rewrites the file).
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), origin: String, username: String, password: String,
                note: String? = nil, updatedAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.origin = origin
        self.username = username
        self.password = password
        self.note = note
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    /// `https://Example.com:443/path` → `https://example.com`. Returns nil for non-http(s) URLs.
    public static func normalizedOrigin(for url: URL) -> String? {
        WebOrigin(url: url)?.serialized
    }

    /// The host the login belongs to, for display.
    public var host: String { WebOrigin(origin)?.host ?? origin }
}

public enum PasswordVaultError: Error, Equatable, Sendable {
    /// Another saved login has the same website and user name.
    case duplicate
    /// The login was deleted meanwhile.
    case notFound
}

/// Per-profile credential store.
///
/// Key: HKDF(profileKey, "passwords") — the profile key is itself only reachable via the
/// vault master key, which is only reachable via the user's master password (Argon2id).
/// The file is one AEAD blob; it is decrypted into memory when the vault is opened
/// and re-encrypted on every change.
///
/// LIMITATION: WKWebView has no public password-autofill integration on macOS 26 (Safari's
/// AutoFill and the iCloud Keychain "Passwords" provider are not exposed to third-party
/// WKWebView hosts). The app layer detects sign-ins and fills logins with a script in an isolated
/// JavaScript world (`PasswordAutoFill`), and answers HTTP Basic/Digest challenges from this vault.
public final class PasswordVault: @unchecked Sendable {
    private let fileURL: URL
    private let profileID: UUID
    private let key: SymmetricKey
    private let lock = NSLock()
    private var entries: [PasswordEntry]

    init(fileURL: URL, profileID: UUID, profileKey: SymmetricKey) throws {
        self.fileURL = fileURL
        self.profileID = profileID
        self.key = profileKey.derive(info: "passwords", salt: withUnsafeBytes(of: profileID.uuid) { Data($0) })
        self.entries = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let plaintext = try AEAD.open(SecureFile.read(fileURL), key: key, aad: aad)
            entries = try JSONCoding.decoder.decode([PasswordEntry].self, from: plaintext)
        }
    }

    private var aad: String { "passwords:v1:\(profileID.uuidString)" }

    /// Posted after every change, with the profile's id as `userInfo["profileID"]` (the password
    /// manager refreshes when the browser saves a login meanwhile).
    public static let didChangeNotification = Notification.Name("PasswordVaultDidChange")

    public func allEntries() -> [PasswordEntry] {
        lock.withLock { entries.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) } }
    }

    /// Logins saved on exactly this origin (HTTP authentication).
    public func entries(for url: URL) -> [PasswordEntry] {
        guard let origin = PasswordEntry.normalizedOrigin(for: url) else { return [] }
        return lock.withLock { entries.filter { $0.origin == origin } }
    }

    /// Logins a page of `origin` is offered, best first (`PasswordMatching.candidates`).
    public func candidates(for origin: WebOrigin) -> [PasswordEntry] {
        PasswordMatching.candidates(lock.withLock { entries }, for: origin)
    }

    /// What a sign-in on `origin` means for the saved logins (`PasswordMatching.decision`).
    public func saveDecision(username: String, password: String, at origin: WebOrigin) -> PasswordMatching.SaveDecision {
        PasswordMatching.decision(username: username, password: password, at: origin, entries: lock.withLock { entries })
    }

    public func entry(id: UUID) -> PasswordEntry? {
        lock.withLock { entries.first { $0.id == id } }
    }

    /// Replaces the login with `entry.id` (an edit): fails rather than silently merging when
    /// another login already has the same website and user name.
    public func update(_ entry: PasswordEntry) throws {
        try lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { throw PasswordVaultError.notFound }
            guard !entries.contains(where: { $0.id != entry.id && $0.origin == entry.origin && $0.username == entry.username }) else {
                throw PasswordVaultError.duplicate
            }
            var updated = entries
            var stamped = entry
            stamped.updatedAt = Date()
            updated[index] = stamped
            try persist(updated)
            entries = updated
        }
    }

    /// Notes that the login was just filled into a page (it is offered first next time).
    public func markUsed(id: UUID, at date: Date = Date()) throws {
        try lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            var updated = entries
            updated[index].lastUsedAt = date
            try persist(updated)
            entries = updated
        }
    }

    /// Inserts or replaces (same origin + username) an entry.
    public func upsert(_ entry: PasswordEntry) throws {
        try lock.withLock {
            var updated = entries.filter { !($0.origin == entry.origin && $0.username == entry.username) && $0.id != entry.id }
            var stamped = entry
            stamped.updatedAt = Date()
            // Replacing a login keeps when it was last used.
            stamped.lastUsedAt = stamped.lastUsedAt ?? entries.first {
                $0.id == entry.id || ($0.origin == entry.origin && $0.username == entry.username)
            }?.lastUsedAt
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
        // Later, on the main queue: never to an observer while the lock is held.
        let profileID = self.profileID
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: ["profileID": profileID])
        }
    }
}
