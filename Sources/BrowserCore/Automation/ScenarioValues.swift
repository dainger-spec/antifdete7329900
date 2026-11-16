import Foundation

/// A profile's own values for scenarios (docs/AUTOMATION.md, "A profile's values"): a login, a
/// password, a city — whatever a scenario reads as `params.<name>`. One scenario then signs in on
/// fifty profiles, each with its own: the recorder writes `params.password` for every password it
/// does not record, and a run started from the editor or by the clock had nothing to put there.
///
/// `scenario-values.bin` at the vault's root, sealed under the scenarios' key — a file of its own,
/// as the schedules' is, so that a version from before it reads and writes `scenarios.bin` as it
/// did and never sees this one. This Mac's; not synced, not part of a profile's export.
public struct ScenarioValues: Codable, Equatable, Sendable {
    public static let supportedFormat = 1
    /// What one profile may hold: more than a form has fields.
    public static let maximumCount = 64
    public static let maximumNameLength = 64
    public static let maximumValueLength = 4096

    /// One value: `params.<name>` in a scenario run on its profile.
    public struct Value: Codable, Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// A profile's values, in the order they were written.
    public struct OfProfile: Codable, Equatable, Sendable {
        public var profileID: UUID
        public var values: [Value]

        public init(profileID: UUID, values: [Value]) {
            self.profileID = profileID
            self.values = values
        }
    }

    public var format: Int
    public var profiles: [OfProfile]

    public init(format: Int = 1, profiles: [OfProfile] = []) {
        self.format = format
        self.profiles = profiles
    }

    /// Whether `text` can be read as `params.<text>`: a letter or `_`, then letters, digits and
    /// `_` (Latin: what JavaScript takes after a dot in every keyboard layout), at most
    /// `maximumNameLength`. `__proto__` is not a name: in an object's text it is not a value.
    public static func isName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumNameLength, text != "__proto__" else { return false }
        let scalars = Array(text.unicodeScalars)
        func letter(_ scalar: Unicode.Scalar) -> Bool {
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
        }
        guard letter(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { letter($0) || ($0 >= "0" && $0 <= "9") }
    }

    /// What is kept of `values`: names without the spaces around them; one whose name is not a
    /// name (`isName`) left out, and a second of the same name; a value cut to `maximumValueLength`;
    /// `maximumCount` at most. The editor refuses what this would drop before it comes here.
    public static func cleaned(_ values: [Value]) -> [Value] {
        var seen = Set<String>()
        var kept: [Value] = []
        for value in values {
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isName(name), seen.insert(name).inserted, kept.count < maximumCount else { continue }
            kept.append(Value(name: name, value: String(value.value.prefix(maximumValueLength))))
        }
        return kept
    }

    /// The values of profile `id`; none when it has none.
    public func values(of id: UUID) -> [Value] {
        profiles.first { $0.profileID == id }?.values ?? []
    }

    /// Puts `values` (cleaned) in place of profile `id`'s; none removes the profile from the file.
    public mutating func set(_ values: [Value], for id: UUID) {
        let kept = Self.cleaned(values)
        profiles.removeAll { $0.profileID == id }
        if !kept.isEmpty { profiles.append(OfProfile(profileID: id, values: kept)) }
    }

    /// Values of profiles that are gone go with them. True when any did.
    @discardableResult
    public mutating func keep(profiles ids: Set<UUID>) -> Bool {
        let count = profiles.count
        profiles.removeAll { !ids.contains($0.profileID) }
        return profiles.count != count
    }

    /// A run's parameters as JSON text: profile `id`'s values, each as text, under what the run was
    /// given itself (`given`: a JSON object's text — the API's `params` — whose names win). What
    /// is not an object's text counts as none.
    public func parametersJSON(for id: UUID, over given: String = "{}") -> String {
        var merged: [String: Any] = [:]
        for value in values(of: id) { merged[value.name] = value.value }
        if let own = (try? JSONSerialization.jsonObject(with: Data(given.utf8))) as? [String: Any] {
            for (name, value) in own { merged[name] = value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The names a scenario's text reads from `params` — `params.name`, `params['name']` — in the
    /// order they come, each once: what the editor offers to fill in for a profile. A name in a
    /// comment counts too (the recorder's own line names `params.password` in one).
    public static func namesRead(by source: String) -> [String] {
        let pattern = #"\bparams\s*(?:\.\s*([A-Za-z_][A-Za-z0-9_]*)|\[\s*(?:'([A-Za-z_][A-Za-z0-9_]*)'|"([A-Za-z_][A-Za-z0-9_]*)")\s*\])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        var names: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                let name = text.substring(with: match.range(at: group))
                if isName(name), seen.insert(name).inserted { names.append(name) }
            }
        }
        return names
    }

    /// Of `names` (what a scenario reads), those profile `id` has no text for: none written, or an
    /// empty one.
    public func missing(_ names: [String], for id: UUID) -> [String] {
        let filled = Set(values(of: id).filter { !$0.value.isEmpty }.map(\.name))
        return names.filter { !filled.contains($0) }
    }
}

extension ScenarioValues {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<ScenarioValues> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("scenario-values.bin"), key: try vault.scenariosKey,
                              aad: "scenario-values:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// This Mac's values; none before the first. Throws for a copy that does not open, and for a
    /// newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> ScenarioValues {
        try file(for: vault).load() ?? ScenarioValues()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open (moved
    /// aside as `scenario-values.bin.unreadable` first).
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
