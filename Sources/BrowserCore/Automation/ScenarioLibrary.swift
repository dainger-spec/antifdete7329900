import Foundation

/// A scenario (docs/AUTOMATION.md): JavaScript that acts on a profile's pages through the core
/// commands (`page.goto`, `page.click`…), written in the app's editor.
public struct Scenario: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, source: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// The vault's scenarios — `scenarios.bin` at the vault's root, sealed under the vault's own key for
/// it. This Mac's: not synced in this version (a scenario may name this Mac's files and profiles).
public struct ScenarioLibrary: Codable, Equatable, Sendable {
    /// The newest format of `scenarios.bin` this version reads and writes (docs/UPDATES.md §4).
    public static let supportedFormat = 1

    public var format: Int
    public var scenarios: [Scenario]

    public init(format: Int = 1, scenarios: [Scenario] = []) {
        self.format = format
        self.scenarios = scenarios
    }

    /// By name, as a person looks for one (case and accents aside), then by when it was made.
    public var sorted: [Scenario] {
        scenarios.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }

    public func scenario(_ id: UUID) -> Scenario? { scenarios.first { $0.id == id } }

    /// Adds `scenario`, or replaces the one with its id (its time of change moved on).
    public mutating func put(_ scenario: Scenario, at date: Date = Date()) {
        var changed = scenario
        changed.updatedAt = date
        if let index = scenarios.firstIndex(where: { $0.id == scenario.id }) {
            scenarios[index] = changed
        } else {
            scenarios.append(changed)
        }
    }

    public mutating func remove(_ id: UUID) {
        scenarios.removeAll { $0.id == id }
    }

    /// A name not yet taken: `base`, else "base 2", "base 3"…
    public func freeName(_ base: String) -> String {
        let taken = Set(scenarios.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

extension ScenarioLibrary {
    /// `scenarios.bin`, sealed under the vault's own key for it. A copy that does not open is never
    /// written over: a save moves it aside first (`EncryptedDocumentFile.makeWay`).
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<ScenarioLibrary> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("scenarios.bin"), key: try vault.scenariosKey,
                              aad: "scenarios:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// The vault's scenarios; none before the first. Throws for a copy that does not open, and for a
    /// newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> ScenarioLibrary {
        try file(for: vault).load() ?? ScenarioLibrary()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open (moved aside
    /// as `scenarios.bin.unreadable` first).
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
