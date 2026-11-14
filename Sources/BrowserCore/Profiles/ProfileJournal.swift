import Foundation

/// What happened to a profile, newest last: launched, warmed up, cookies imported, its proxy
/// changed or given a new IP, a restore point made or restored. For the person to see at a
/// glance what a profile went through before an account on it was asked questions — the inspector
/// and the restore points' sheet show it.
///
/// Kept per profile, encrypted (`journal.bin`), on this Mac only: not synced, not in a profile
/// export. At most `maximumEvents`, the oldest going first. Nothing of a page is in it — no
/// address, no title: only what the app did, and a short detail of its own (a count, a proxy's
/// name, a point's name).
public struct ProfileJournal: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var at: Date
        /// One of `Kind`'s raw values — kept as text, so that a kind a later version adds is kept
        /// and written back by this one rather than dropped (R4).
        public var kind: String
        /// A short detail: "14 pages", a proxy's name, a point's name. At most 120 characters.
        public var detail: String

        public init(id: UUID = UUID(), at: Date, kind: Kind, detail: String = "") {
            self.id = id
            self.at = at
            self.kind = kind.rawValue
            self.detail = String(detail.prefix(120))
        }

        public var known: Kind? { Kind(rawValue: kind) }
    }

    public enum Kind: String, Sendable, CaseIterable {
        case launched
        case warmedUp
        case cookiesImported
        case proxyChanged
        case ipChanged
        case restorePointMade
        case restored
        /// Made as a copy of another profile (`ProfileClone`); the detail is that one's name.
        case copied
    }

    public static let maximumEvents = 300

    public private(set) var events: [Event]

    public init(events: [Event] = []) {
        self.events = events
    }

    public mutating func add(_ event: Event) {
        events.append(event)
        if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
    }

    /// The newest first, at most `count`.
    public func latest(_ count: Int) -> [Event] { Array(events.suffix(count).reversed()) }
}

extension ProfileRepository {
    func journalURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("journal.bin") }

    func journalFile(for id: UUID) throws -> EncryptedDocumentFile<ProfileJournal> {
        EncryptedDocumentFile(url: journalURL(for: id),
                              key: try profileKey(for: id).derive(info: "journal", salt: id.rawBytes),
                              aad: "journal:v1:\(id.uuidString)")
    }

    /// The profile's journal; empty when nothing was recorded yet.
    public func journal(for id: UUID) throws -> ProfileJournal {
        try journalFile(for: id).load() ?? ProfileJournal()
    }

    /// Adds an event to the profile's journal. One that cannot be read is moved aside at this
    /// save (`EncryptedDocumentFile`), never written over; a later version's is not written at
    /// all (the event is then not recorded).
    public func record(_ kind: ProfileJournal.Kind, detail: String = "", for id: UUID, at date: Date = Date()) throws {
        let file = try journalFile(for: id)
        var journal = (try? file.load()) ?? ProfileJournal()
        journal.add(ProfileJournal.Event(at: date, kind: kind, detail: detail))
        try file.save(journal)
    }
}
