import Foundation

/// What a profile downloaded in this run, for its window's Show Downloads: each file's name,
/// where it went and how it ended, oldest first, and how many ended since the list was last
/// looked at (the number on the profile's Dock icon).
///
/// Of this run only, in memory: the files themselves are outside the profile's encrypted storage,
/// where the person had them saved, and a list of their names kept in the vault would outlive them.
public struct DownloadLog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public enum State: Equatable, Sendable {
            /// Coming in; `fraction` of it is here, when the server said how much there is.
            case running(fraction: Double?)
            case finished(bytes: Int64?)
            case failed(String)
        }

        public let id: UUID
        public var name: String
        /// The folder it is saved in.
        public var folder: String
        public var state: State

        public var hasEnded: Bool {
            if case .running = state { return false }
            return true
        }
    }

    /// At most this many are listed: the oldest that ended go first.
    public static let maximumEntries = 200

    public private(set) var entries: [Entry] = []
    /// Downloads that finished or failed since `markSeen`.
    public private(set) var unseen = 0

    public init() {}

    public var isRunning: Bool { entries.contains { !$0.hasEnded } }

    /// A download whose destination is decided.
    @discardableResult
    public mutating func begin(name: String, folder: String, id: UUID = UUID()) -> UUID {
        entries.append(Entry(id: id, name: name, folder: folder, state: .running(fraction: nil)))
        while entries.count > Self.maximumEntries, let oldest = entries.firstIndex(where: \.hasEnded) {
            entries.remove(at: oldest)
        }
        return id
    }

    /// How much of a running download is here: 0…1, or nil when the server did not say its size.
    public mutating func progress(_ id: UUID, fraction: Double?) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].hasEnded else { return }
        entries[index].state = .running(fraction: fraction.map { min(max($0, 0), 1) })
    }

    public mutating func finish(_ id: UUID, bytes: Int64?) {
        end(id, .finished(bytes: bytes))
    }

    public mutating func fail(_ id: UUID, reason: String) {
        end(id, .failed(reason))
    }

    /// Cancelled before anything was kept (the save panel's Cancel): it was never a download.
    public mutating func cancel(_ id: UUID) {
        entries.removeAll { $0.id == id && !$0.hasEnded }
    }

    /// The list was shown: nothing in it is new any more.
    public mutating func markSeen() {
        unseen = 0
    }

    /// The downloads that ended leave the list; the files stay where they are.
    public mutating func clearEnded() {
        entries.removeAll(where: \.hasEnded)
        unseen = 0
    }

    /// A download ends once.
    private mutating func end(_ id: UUID, _ state: Entry.State) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].hasEnded else { return }
        entries[index].state = state
        unseen += 1
    }
}

/// Whether a response is a file to save rather than a page to show, as Safari decides it.
public enum DownloadPolicy {
    /// `Content-Disposition` names an attachment. As WebKit reads the header: its first part is the
    /// disposition; "inline" is none, and neither is a first part that is no token at all — sites
    /// send `filename="x"` alone, or `; filename="x"` — while any other token ("attachment", or one
    /// nobody knows: RFC 2183, 2.8) is an attachment.
    public static func isAttachment(contentDisposition: String?) -> Bool {
        guard let header = contentDisposition, !header.isEmpty else { return false }
        let type = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard isToken(type) else { return false }
        return type.lowercased() != "inline"
    }

    /// A response the engine cannot show, or one its server says to save, is a download.
    public static func isDownload(canShow: Bool, contentDisposition: String?) -> Bool {
        !canShow || isAttachment(contentDisposition: contentDisposition)
    }

    /// An HTTP token (RFC 7230): one or more of the characters a header's names are made of.
    static func isToken(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let others = Set("!#$%&'*+-.^_`|~".unicodeScalars)
        return text.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) || others.contains(scalar)
        }
    }
}
