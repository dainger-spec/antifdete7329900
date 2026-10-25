import Foundation

/// The on-disk list of profiles, as JSON. Small enough to rewrite whole on
/// every change; writes are atomic (temp file + rename) so a crash never
/// leaves a half-written list.
public final class ProfileStore {
    public struct Document: Codable, Equatable, Sendable {
        public var version: Int
        public var profiles: [Profile]
        public init(version: Int = 1, profiles: [Profile] = []) {
            self.version = version
            self.profiles = profiles
        }
    }

    public let url: URL
    private let lock = NSLock()

    /// Default location: ~/Library/Application Support/VMLauncher/profiles.json.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VMLauncher/profiles.json")
    }

    public init(url: URL = ProfileStore.defaultURL()) {
        self.url = url
    }

    /// Where a profile's own files live on the host (cookies, exported bundles):
    /// ~/Library/Application Support/VMLauncher/profiles/<id>/.
    public func directory(for profile: Profile) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("profiles/\(profile.id)", isDirectory: true)
    }

    public func cookiesURL(for profile: Profile) -> URL {
        directory(for: profile).appendingPathComponent("cookies.json")
    }

    // MARK: Load / save

    public func load() throws -> Document {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked()
    }

    private func loadLocked() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return Document() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Document.self, from: data)
    }

    private func saveLocked(_ document: Document) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        // `.atomic` writes to a temp file and renames into place, so a crash
        // mid-write never leaves a truncated profiles.json.
        try data.write(to: url, options: .atomic)
    }

    // MARK: Mutations (read-modify-write under the lock)

    @discardableResult
    public func mutate<T>(_ body: (inout Document) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var document = try loadLocked()
        let result = try body(&document)
        try saveLocked(document)
        return result
    }

    public func list() throws -> [Profile] {
        try load().profiles.sorted { $0.createdAt < $1.createdAt }
    }

    public func get(_ id: String) throws -> Profile? {
        try load().profiles.first { $0.id == id }
    }

    /// Adds a profile. Throws if the name is blank or already taken.
    @discardableResult
    public func add(_ profile: Profile) throws -> Profile {
        try mutate { document in
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ProfileError.invalidName }
            guard !document.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ProfileError.duplicateName(name)
            }
            var stored = profile
            stored.name = name
            document.profiles.append(stored)
            return stored
        }
    }

    /// Applies `change` to the profile with `id` (updating `updatedAt`).
    @discardableResult
    public func update(_ id: String, _ change: (inout Profile) -> Void) throws -> Profile {
        try mutate { document in
            guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileError.notFound(id)
            }
            change(&document.profiles[index])
            document.profiles[index].updatedAt = Date()
            return document.profiles[index]
        }
    }

    public func remove(_ id: String) throws {
        try mutate { document in
            guard document.profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound(id) }
            document.profiles.removeAll { $0.id == id }
        }
    }
}

public enum ProfileError: Error, Equatable, CustomStringConvertible {
    case invalidName
    case duplicateName(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalidName: "profile name must not be empty"
        case .duplicateName(let name): "a profile named \"\(name)\" already exists"
        case .notFound(let id): "no profile with id \(id)"
        }
    }
}
