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
    /// This version of the login, made anew at every change of what it holds (a fill only notes
    /// `lastUsedAt`). Nil in a login saved before `passwords.bin` had versions (format 1): its
    /// version is then derived from what it holds (`currentVersion`), the same on every device.
    public var version: UUID?
    /// Every version this one was made from (sorted, so that two devices write them alike): how a
    /// merge tells a later change of the login from one made on another device at the same time.
    public var ancestors: [UUID]?
    /// Set on a version of the login `conflictOf` that another device changed at the same time:
    /// kept beside it until the person chooses (`PasswordVault.keepConflictVersion`, or deleting
    /// it), and never offered to a page.
    public var conflictOf: UUID?
    /// The device this version was made on (its name, `PasswordVault.deviceName`), so that the
    /// password manager can say where a version kept after a conflict came from. Nil in a version
    /// made before it was written, or where no name was known.
    public var device: String?
    /// What makes the login's one-time codes (two-step sign-in), when the person added it. A file
    /// that holds one is format 3: a version from before codes would write the login back without
    /// it (docs/UPDATES.md §4, R4). A login may be a code alone, with an empty password.
    public var totp: OneTimeCode?

    public init(id: UUID = UUID(), origin: String, username: String, password: String,
                note: String? = nil, updatedAt: Date = Date(), lastUsedAt: Date? = nil,
                version: UUID? = nil, ancestors: [UUID]? = nil, conflictOf: UUID? = nil, device: String? = nil,
                totp: OneTimeCode? = nil) {
        self.id = id
        self.origin = origin
        self.username = username
        self.password = password
        self.note = note
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.version = version
        self.ancestors = ancestors
        self.conflictOf = conflictOf
        self.device = device
        self.totp = totp
    }

    /// The version a merge goes by: `version`, or for a login saved before versions, one derived
    /// from what it holds — two devices holding the same such login agree on it.
    public var currentVersion: UUID {
        if let version { return version }
        // A login without a code derives what it always did; versions were written long before
        // codes, so one with a code and no version is only met in a file put together by hand.
        let text = ([id.uuidString, origin, username, password, note ?? "",
                     String(updatedAt.timeIntervalSinceReferenceDate)] + (totp.map { [$0.fingerprint] } ?? []))
            .joined(separator: "\u{1F}")
        let d = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    /// A version another device made at the same time as the one kept (`conflictOf`).
    public var isConflictVersion: Bool { conflictOf != nil }

    /// `https://Example.com:443/path` → `https://example.com`. Returns nil for non-http(s) URLs.
    public static func normalizedOrigin(for url: URL) -> String? {
        WebOrigin(url: url)?.serialized
    }

    /// The host the login belongs to, for display.
    public var host: String { WebOrigin(origin)?.host ?? origin }
}

/// A login deleted: the versions of it the deletion took away — the one it saw and every one
/// before it. A version of the same login not among them (changed on another device at the same
/// time as the deletion) is kept, and the deletion goes.
public struct PasswordTombstone: Codable, Equatable, Sendable {
    public var id: UUID
    public var versions: [UUID]
    public var deletedAt: Date
}

/// The JSON of `passwords.bin`. Format 1 was the logins alone, as an array, with no record of what
/// was deleted: sync could only push one device's file over another's. Format 2 keeps deletions
/// (`deleted`) and each login's versions, and two copies are merged login by login (`merge`).
/// Format 3 is format 2 with a one-time code's generator in a login (`PasswordEntry.totp`): written
/// only once a login has one, so a profile without codes stays readable to the versions before
/// them, and one with codes is refused by them whole instead of being written back without.
struct PasswordDocument: Codable, Equatable {
    var format = 2
    var entries: [PasswordEntry] = []
    var deleted: [PasswordTombstone] = []

    /// The format this document is written as: the lowest that says everything it holds.
    var writtenFormat: Int { entries.contains { $0.totp != nil } ? 3 : 2 }

    /// Written with `writtenFormat`, whatever `format` it was read with.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(writtenFormat, forKey: .format)
        try container.encode(entries, forKey: .entries)
        try container.encode(deleted, forKey: .deleted)
    }

    /// Format 1 (an array), 2 or 3; a newer one is refused (docs/UPDATES.md §4).
    static func decode(_ plaintext: Data) throws -> PasswordDocument {
        try DocumentFormat.check(plaintext, supported: PasswordVault.supportedFormat, what: "passwords.bin")
        let first = plaintext.first { !$0.isASCIIWhitespace }
        if first == UInt8(ascii: "[") {
            return PasswordDocument(entries: try JSONCoding.decoder.decode([PasswordEntry].self, from: plaintext))
        }
        return try JSONCoding.decoder.decode(PasswordDocument.self, from: plaintext)
    }

    /// As written: format 2, every login with its version, in an order of its own (two devices that
    /// hold the same logins write the same bytes, and sync has nothing to send).
    func normalized() -> PasswordDocument {
        var document = PasswordDocument()
        document.entries = entries.map { entry in
            var entry = entry
            entry.version = entry.currentVersion
            entry.ancestors = Self.sortedUnique(entry.ancestors ?? [])
            return entry
        }.sorted(by: Self.order)
        document.deleted = deleted.map { PasswordTombstone(id: $0.id, versions: Self.sortedUnique($0.versions), deletedAt: $0.deletedAt) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return document
    }

    /// Two copies of the file, login by login. A login one copy changed after the other's version
    /// (its versions include the other's) is taken as it is there. One changed on both devices at
    /// the same time keeps both: the later change stays, the other is kept beside it as a version
    /// of its own (`conflictOf`), under an id made from its version — the same on every device, so
    /// that merging again adds nothing. A deletion takes the versions it saw; a version it did not
    /// see survives it. The same whichever copy is which, and merging a copy with itself changes
    /// nothing.
    static func merge(_ a: PasswordDocument, _ b: PasswordDocument) -> PasswordDocument {
        var tombstones: [UUID: PasswordTombstone] = [:]
        for tombstone in a.deleted + b.deleted {
            if let seen = tombstones[tombstone.id] {
                tombstones[tombstone.id] = PasswordTombstone(id: tombstone.id, versions: sortedUnique(seen.versions + tombstone.versions),
                                                             deletedAt: max(seen.deletedAt, tombstone.deletedAt))
            } else {
                tombstones[tombstone.id] = tombstone
            }
        }
        var logins: [UUID: PasswordEntry] = [:]
        var kept: [PasswordEntry] = []
        for entry in a.entries + b.entries {
            guard let other = logins[entry.id] else {
                logins[entry.id] = entry
                continue
            }
            let (winner, conflict) = resolve(other, entry)
            logins[entry.id] = winner
            if let conflict { kept.append(conflict) }
        }
        for conflict in kept {
            if let other = logins[conflict.id] { logins[conflict.id] = resolve(other, conflict).winner } else { logins[conflict.id] = conflict }
        }
        for (id, tombstone) in tombstones {
            guard let entry = logins[id] else { continue }
            if tombstone.versions.contains(entry.currentVersion) {
                logins[id] = nil
            } else {
                tombstones[id] = nil
            }
        }
        return foldingDuplicates(PasswordDocument(entries: Array(logins.values), deleted: Array(tombstones.values))).normalized()
    }

    /// Logins for the same website and user name that two devices made apart, each with an id of
    /// its own (the merge above goes by id, and would keep both as logins: a page offered two for
    /// one account, and an edit of either refused as a duplicate). One stays the login: the one
    /// changed last by the devices' clocks — a hint for which to show first, never a reason to drop
    /// the other; ties by id. Each other one is folded into it:
    /// - what it holds is kept beside the login as a version of its own (`conflictOf`), unless it
    ///   holds the same password and note (then it adds nothing, but when it was last used);
    /// - its id is tombstoned with the versions it had, so that a device still holding it does not
    ///   bring it back as a login (a change made there since, which that tombstone did not see,
    ///   does come back, and is folded in again);
    /// - the versions kept beside it go with the login it was folded into.
    /// The same whichever copy is which, as the merge: the result depends only on the logins.
    static func foldingDuplicates(_ document: PasswordDocument) -> PasswordDocument {
        var document = document
        let live = document.entries.filter { !$0.isConflictVersion }
        let groups = Dictionary(grouping: live) { [$0.origin, $0.username] }
        for group in groups.values where group.count > 1 {
            guard let login = group.max(by: { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }) else { continue }
            for other in group where other.id != login.id {
                let versions = sortedUnique((other.ancestors ?? []) + [other.currentVersion])
                if let seen = document.deleted.firstIndex(where: { $0.id == other.id }) {
                    document.deleted[seen].versions = sortedUnique(document.deleted[seen].versions + versions)
                    document.deleted[seen].deletedAt = max(document.deleted[seen].deletedAt, other.updatedAt)
                } else {
                    // Its own time, not this device's clock: two devices folding it write the same.
                    document.deleted.append(PasswordTombstone(id: other.id, versions: versions, deletedAt: other.updatedAt))
                }
                document.entries.removeAll { $0.id == other.id }
                for index in document.entries.indices where document.entries[index].conflictOf == other.id {
                    document.entries[index].conflictOf = login.id
                }
                if let index = document.entries.firstIndex(where: { $0.id == login.id }), let used = other.lastUsedAt {
                    document.entries[index].lastUsedAt = max(document.entries[index].lastUsedAt ?? used, used)
                }
                guard other.password != login.password || (other.note ?? "") != (login.note ?? "") || other.totp != login.totp else { continue }
                let beside = kept(other, beside: login.id)
                if !document.entries.contains(where: { $0.id == beside.id }) { document.entries.append(beside) }
            }
        }
        return document
    }

    /// A `passwords.bin.conflict` taken in: the copy a sync before format 2 set aside when both
    /// devices had changed the file — out of the app's reach, and written over by the next such
    /// sync. Each version it holds that this file neither has nor descends from, nor deleted, is
    /// kept beside its login as a version of its own (`conflictOf`; one whose login is not here
    /// is kept beside its own id, and choosing it makes it a login): the password manager shows it,
    /// and the person chooses. Nil when it adds nothing.
    static func takingIn(_ copy: PasswordDocument, into document: PasswordDocument) -> PasswordDocument? {
        var result = document
        for entry in copy.entries {
            let version = entry.currentVersion
            let login = entry.conflictOf ?? entry.id
            let had = result.entries.contains { candidate in
                (candidate.id == entry.id || candidate.id == login || candidate.conflictOf == login)
                    && (candidate.currentVersion == version || (candidate.ancestors ?? []).contains(version))
            }
            let deleted = result.deleted.contains { ($0.id == entry.id || $0.id == login) && $0.versions.contains(version) }
            guard !had, !deleted, !result.entries.contains(where: { $0.id == conflictID(of: version) }) else { continue }
            result.entries.append(kept(entry, beside: login))
        }
        return result == document ? nil : result.normalized()
    }

    /// Two versions of one login.
    private static func resolve(_ x: PasswordEntry, _ y: PasswordEntry) -> (winner: PasswordEntry, conflict: PasswordEntry?) {
        let vx = x.currentVersion, vy = y.currentVersion
        let history = sortedUnique((x.ancestors ?? []) + (y.ancestors ?? []))
        let lastUsed = [x.lastUsedAt, y.lastUsedAt].compactMap { $0 }.max()
        func taking(_ entry: PasswordEntry, adding more: [UUID] = []) -> PasswordEntry {
            var entry = entry
            entry.version = entry.currentVersion
            entry.ancestors = sortedUnique(history + more)
            entry.lastUsedAt = lastUsed
            return entry
        }
        if vx == vy { return (taking(x.updatedAt >= y.updatedAt ? x : y), nil) }
        if (y.ancestors ?? []).contains(vx) { return (taking(y), nil) }
        if (x.ancestors ?? []).contains(vy) { return (taking(x), nil) }
        // Changed on both devices at the same time: the later change stays, the other beside it.
        let xIsLater = x.updatedAt != y.updatedAt ? x.updatedAt > y.updatedAt : vx.uuidString > vy.uuidString
        let (later, earlier) = xIsLater ? (x, y) : (y, x)
        return (taking(later, adding: [earlier.currentVersion]), kept(earlier, beside: later.conflictOf ?? later.id))
    }

    /// `version` kept beside the login `login` after a conflict: its own id (made from the version)
    /// and what it holds — no history, no last use. A version that was the login for a while
    /// carries the history it took from others then; kept that way, the same version would be
    /// written differently depending on the order the copies met in, and two devices would never
    /// agree. The login keeps the history; the kept version is what it says.
    static func kept(_ version: PasswordEntry, beside login: UUID) -> PasswordEntry {
        var kept = version
        kept.id = conflictID(of: version.currentVersion)
        kept.version = version.currentVersion
        kept.ancestors = []
        kept.lastUsedAt = nil
        kept.conflictOf = login
        return kept
    }

    /// The id of the version kept beside a login after a conflict: made from that version.
    static func conflictID(of version: UUID) -> UUID {
        let d = Array(SHA256.hash(data: Data("password-conflict:\(version.uuidString)".utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    static func sortedUnique(_ versions: [UUID]) -> [UUID] {
        Array(Set(versions)).sorted { $0.uuidString < $1.uuidString }
    }

    static func order(_ x: PasswordEntry, _ y: PasswordEntry) -> Bool {
        (x.origin, x.username, x.id.uuidString) < (y.origin, y.username, y.id.uuidString)
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
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
/// and re-encrypted on every change. The same file can be open in two processes at once (the
/// manager's password window and the profile's own process, which saves a login when the user
/// signs in): every read first notices a file the other process rewrote and reads it again, and
/// every change is made under a lock both processes take (`FileLock`), on what the file holds at
/// that moment — so neither process's change is lost to the other's.
///
/// LIMITATION: WKWebView has no public password-autofill integration on macOS 26 (Safari's
/// AutoFill and the iCloud Keychain "Passwords" provider are not exposed to third-party
/// WKWebView hosts). The app layer detects sign-ins and fills logins with a script in an isolated
/// JavaScript world (`PasswordAutoFill`), and answers HTTP Basic/Digest challenges from this vault.
public final class PasswordVault: @unchecked Sendable {
    /// This device's name, written on every version of a login made here (`PasswordEntry.device`).
    /// Set by the app first thing in each of its processes; nil (tests, or no name known): the
    /// versions made here carry none.
    nonisolated(unsafe) public static var deviceName: String?

    private let fileURL: URL
    private let profileID: UUID
    private let key: SymmetricKey
    private let lock = NSLock()
    private var stored: PasswordDocument
    /// `FileLock.stamp` of the file `stored` was read from (or written as).
    private var loadedStamp: String?

    init(fileURL: URL, profileID: UUID, profileKey: SymmetricKey) throws {
        self.fileURL = fileURL
        self.profileID = profileID
        self.key = Self.fileKey(profileID: profileID, profileKey: profileKey)
        self.stored = PasswordDocument()
        try reloadIfChanged()
        takeInTheCopyAnEarlierSyncSetAside()
    }

    /// `passwords.bin.conflict`, which a sync before `passwords.bin` format 2 wrote beside the file
    /// when both devices had changed it (the other device's copy won, this one's went there): its
    /// versions are taken into the file as versions kept after a conflict (`PasswordDocument.
    /// takingIn`), where the password manager shows them. The copy is removed only once the file,
    /// read back, holds every one of them; one that cannot be read, or taken in, stays as it is.
    private func takeInTheCopyAnEarlierSyncSetAside() {
        let copyURL = fileURL.appendingPathExtension("conflict")
        guard FileManager.default.fileExists(atPath: copyURL.path),
              let copy = try? PasswordDocument.decode(AEAD.open(SecureFile.read(copyURL), key: key, aad: aad)) else { return }
        do {
            try change { PasswordDocument.takingIn(copy, into: $0) }
            let written = try PasswordDocument.decode(AEAD.open(SecureFile.read(fileURL), key: key, aad: aad))
            guard PasswordDocument.takingIn(copy, into: written) == nil else { return }
            try FileManager.default.removeItem(at: copyURL)
        } catch {
            // Kept: taken in at the next opening.
        }
    }

    /// The logins as the file holds them now, the versions kept after a conflict among them. Call
    /// with `lock` held.
    private var entries: [PasswordEntry] {
        try? reloadIfChanged()
        return stored.entries
    }

    /// The logins a page is offered or a sign-in is matched against: not the versions kept after a
    /// conflict. Call with `lock` held.
    private var liveEntries: [PasswordEntry] { entries.filter { !$0.isConflictVersion } }

    /// Reads the file again when another process has replaced it since it was last read here.
    /// A file that cannot be read keeps what was read before (the next change still writes on
    /// top of the newest readable state) — and so does a file that has gone since it was read: a
    /// missing file is not an empty one, and the next change writes what was read back. Call with
    /// `lock` held (or from `init`).
    private func reloadIfChanged() throws {
        let stamp = FileLock.stamp(of: fileURL)
        guard stamp != loadedStamp else { return }
        if stamp != nil {
            // An array is format 1; a newer version's file is refused, and with it every change.
            stored = try PasswordDocument.decode(AEAD.open(SecureFile.read(fileURL), key: key, aad: aad))
        }
        loadedStamp = stamp
    }

    /// A change: under the lock both processes take, on the file as it is now.
    private func change(_ body: (PasswordDocument) throws -> PasswordDocument?) throws {
        try lock.withLock {
            try FileLock.withExclusiveLock(on: fileURL) {
                try reloadIfChanged()
                guard let updated = try body(stored)?.normalized() else { return }
                try persist(updated)
                stored = updated
                loadedStamp = FileLock.stamp(of: fileURL)
            }
        }
    }

    private var aad: String { Self.aad(profileID: profileID) }

    /// The newest format of `passwords.bin` this version reads and writes (docs/UPDATES.md §4):
    /// 2 keeps deletions and each login's versions, which sync merges by; 3 is 2 with a one-time
    /// code's generator in a login, written only once there is one (`PasswordDocument.writtenFormat`).
    static let supportedFormat = 3

    static func aad(profileID: UUID) -> String { "passwords:v1:\(profileID.uuidString)" }

    static func fileKey(profileID: UUID, profileKey: SymmetricKey) -> SymmetricKey {
        profileKey.derive(info: "passwords", salt: withUnsafeBytes(of: profileID.uuid) { Data($0) })
    }

    /// The JSON of a sealed `passwords.bin` (sync checks a remote copy's format before using it).
    static func open(_ sealed: Data, profileID: UUID, profileKey: SymmetricKey) throws -> Data {
        try AEAD.open(sealed, key: fileKey(profileID: profileID, profileKey: profileKey), aad: aad(profileID: profileID))
    }

    /// Two sealed copies of `passwords.bin` merged login by login (`PasswordDocument.merge`), sealed
    /// again: what sync does when both devices changed the file.
    static func merge(_ local: Data, _ remote: Data, profileID: UUID, profileKey: SymmetricKey) throws -> Data {
        let merged = try PasswordDocument.merge(PasswordDocument.decode(open(local, profileID: profileID, profileKey: profileKey)),
                                                PasswordDocument.decode(open(remote, profileID: profileID, profileKey: profileKey)))
        return try AEAD.seal(JSONCoding.encoder.encode(merged), key: fileKey(profileID: profileID, profileKey: profileKey),
                             aad: aad(profileID: profileID))
    }

    /// Posted after every change, with the profile's id as `userInfo["profileID"]` (the password
    /// manager refreshes when the browser saves a login meanwhile).
    public static let didChangeNotification = Notification.Name("PasswordVaultDidChange")

    public func allEntries() -> [PasswordEntry] {
        lock.withLock { entries.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) } }
    }

    /// Logins saved on exactly this origin (HTTP authentication).
    public func entries(for url: URL) -> [PasswordEntry] {
        guard let origin = PasswordEntry.normalizedOrigin(for: url) else { return [] }
        return lock.withLock { liveEntries.filter { $0.origin == origin } }
    }

    /// The saved login that HTTP authentication (Basic, Digest) is answered with by itself, with
    /// nothing asked: one of exactly `url`'s origin that has a password — a login that is a
    /// one-time code alone has none to send — and only over https. Over plain http the password
    /// would cross the network as the request does (Basic: readable by anyone on the way), so
    /// there the person is asked, as for a site with nothing saved. Nil: ask.
    public func httpAuthenticationEntry(for url: URL) -> PasswordEntry? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        return entries(for: url).first { !$0.password.isEmpty }
    }

    /// Logins a page of `origin` is offered, best first (`PasswordMatching.candidates`).
    /// A login that is a one-time code alone (no password) is not among them: it has nothing for
    /// a password's field.
    public func candidates(for origin: WebOrigin) -> [PasswordEntry] {
        PasswordMatching.candidates(lock.withLock { liveEntries }, for: origin).filter { !$0.password.isEmpty }
    }

    /// What a sign-in on `origin` means for the saved logins (`PasswordMatching.decision`).
    public func saveDecision(username: String, password: String, at origin: WebOrigin) -> PasswordMatching.SaveDecision {
        PasswordMatching.decision(username: username, password: password, at: origin, entries: lock.withLock { liveEntries })
    }

    /// Logins with a one-time code a page of `origin` is offered for a code's field, best first.
    public func codeCandidates(for origin: WebOrigin) -> [PasswordEntry] {
        PasswordMatching.candidates(lock.withLock { liveEntries }, for: origin).filter { $0.totp != nil }
    }

    /// The versions kept after a conflict (another device changed the same login at the same time).
    public func conflictVersions() -> [PasswordEntry] {
        lock.withLock { entries.filter(\.isConflictVersion) }
    }

    public func entry(id: UUID) -> PasswordEntry? {
        lock.withLock { entries.first { $0.id == id } }
    }

    /// Replaces the login with `entry.id` (an edit): fails rather than silently merging when
    /// another login already has the same website and user name.
    public func update(_ entry: PasswordEntry) throws {
        try change { document in
            guard let index = document.entries.firstIndex(where: { $0.id == entry.id }) else { throw PasswordVaultError.notFound }
            guard !document.entries.contains(where: {
                $0.id != entry.id && !$0.isConflictVersion && $0.origin == entry.origin && $0.username == entry.username
            }) else {
                throw PasswordVaultError.duplicate
            }
            var updated = document
            updated.entries[index] = Self.edited(document.entries[index], to: entry)
            return updated
        }
    }

    /// Notes that the login was just filled into a page (it is offered first next time). Not a
    /// change of the login: its version stays.
    public func markUsed(id: UUID, at date: Date = Date()) throws {
        try change { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = document
            updated.entries[index].lastUsedAt = date
            return updated
        }
    }

    /// Saves `entry`: as a change of the login with its id, else of the login saved for the same
    /// website and user name, else as a new login. (Never of a version kept after a conflict.)
    /// A save that carries no one-time code keeps the login's: a page that saves a changed
    /// password knows nothing of it. Taking a code away is an edit (`update`).
    public func upsert(_ entry: PasswordEntry) throws {
        try change { document in
            var updated = document
            if let index = document.entries.firstIndex(where: { $0.id == entry.id }) {
                var replacing = entry
                replacing.totp = entry.totp ?? document.entries[index].totp
                updated.entries[index] = Self.edited(document.entries[index], to: replacing)
            } else if let index = document.entries.firstIndex(where: {
                !$0.isConflictVersion && $0.origin == entry.origin && $0.username == entry.username
            }) {
                var replacing = entry
                replacing.id = document.entries[index].id
                replacing.totp = entry.totp ?? document.entries[index].totp
                updated.entries[index] = Self.edited(document.entries[index], to: replacing)
            } else {
                var added = entry
                added.updatedAt = Date()
                added.version = UUID()
                added.ancestors = []
                added.conflictOf = nil
                added.device = Self.deviceName
                updated.entries.append(added)
            }
            return updated
        }
    }

    public func remove(id: UUID) throws {
        try change { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = document
            let removed = updated.entries.remove(at: index)
            let versions = (removed.ancestors ?? []) + [removed.currentVersion]
            if let seen = updated.deleted.firstIndex(where: { $0.id == id }) {
                updated.deleted[seen].versions += versions
                updated.deleted[seen].deletedAt = Date()
            } else {
                updated.deleted.append(PasswordTombstone(id: id, versions: versions, deletedAt: Date()))
            }
            return updated
        }
    }

    /// The version kept after a conflict (`id`) chosen: its password and note become the login's
    /// (a change of it), and the kept version goes. A version whose login is gone becomes a login.
    public func keepConflictVersion(_ id: UUID) throws {
        try change { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id }), let of = document.entries[index].conflictOf else {
                throw PasswordVaultError.notFound
            }
            var updated = document
            let chosen = document.entries[index]
            // Its login, or (folded into another since) the login for the same website and user name.
            if let original = document.entries.firstIndex(where: { $0.id == of })
                ?? document.entries.firstIndex(where: { !$0.isConflictVersion && $0.origin == chosen.origin && $0.username == chosen.username }) {
                var replacing = document.entries[original]
                replacing.password = chosen.password
                replacing.note = chosen.note
                // The codes' generator goes with the version chosen; one that has none (made
                // before the code was added) does not take the login's away.
                replacing.totp = chosen.totp ?? replacing.totp
                updated.entries[original] = Self.edited(document.entries[original], to: replacing,
                                                        alsoFrom: [chosen.currentVersion] + (chosen.ancestors ?? []))
                let gone = updated.entries.remove(at: index)
                updated.deleted.append(PasswordTombstone(id: gone.id, versions: (gone.ancestors ?? []) + [gone.currentVersion],
                                                         deletedAt: Date()))
            } else {
                var login = Self.edited(chosen, to: chosen)
                login.conflictOf = nil
                updated.entries[index] = login
            }
            return updated
        }
    }

    /// Every login of a profile being imported, as the export holds them (versions and versions kept
    /// after a conflict included), into this vault, which must hold none yet.
    public func importEntries(_ imported: [PasswordEntry]) throws {
        try change { document in
            guard document.entries.isEmpty else { throw CoreError.invalidConfiguration("the profile's password vault is not empty") }
            var updated = document
            updated.entries = imported
            return updated
        }
    }

    /// `old` changed into `new` (same id): a new version, made from `old`'s.
    private static func edited(_ old: PasswordEntry, to new: PasswordEntry, alsoFrom more: [UUID] = []) -> PasswordEntry {
        var stamped = new
        stamped.id = old.id
        stamped.updatedAt = Date()
        stamped.version = UUID()
        stamped.ancestors = (old.ancestors ?? []) + [old.currentVersion] + more
        stamped.conflictOf = old.conflictOf
        stamped.device = deviceName
        // A change keeps when the login was last used.
        stamped.lastUsedAt = new.lastUsedAt ?? old.lastUsedAt
        return stamped
    }

    private func persist(_ document: PasswordDocument) throws {
        let plaintext = try JSONCoding.encoder.encode(document)
        try SecureFile.write(AEAD.seal(plaintext, key: key, aad: aad), to: fileURL)
        // Later, on the main queue: never to an observer while the lock is held.
        let profileID = self.profileID
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: ["profileID": profileID])
        }
    }
}
