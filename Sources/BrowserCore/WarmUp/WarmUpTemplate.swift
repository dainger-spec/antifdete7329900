import Foundation

/// A warm-up list the person made: a name, sites and searches, saved from the warm-up screen's
/// hand-written list and chosen again like the lists the app ships ("My templates").
public struct WarmUpTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var addresses: [String]
    public var searches: [String]
    public var createdAt: Date

    public static let maximumNameLength = 60

    public init(id: UUID = UUID(), name: String, addresses: [String], searches: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        self.addresses = addresses
        self.searches = searches
        self.createdAt = createdAt
    }

    /// Made from a list as written on the screen: the lines that are web addresses (each once, at
    /// most `WarmUpPlan.maximumPages`), and the searches, one per line. Nil when no line is a web
    /// address: a template is somewhere to go.
    public init?(name: String, typedAddresses: String, typedSearches: String) {
        let list = Self.typed(addresses: typedAddresses, searches: typedSearches)
        guard !list.addresses.isEmpty else { return nil }
        self.init(name: name, addresses: list.addresses, searches: list.searches)
    }

    /// How a list chosen by this template is named in a plan's choice (`WarmUpChoice.presetID`).
    public var presetID: String { "user:" + id.uuidString }

    /// The template as a list to run, beside the app's own.
    public var preset: WarmUpPreset {
        WarmUpPreset(id: presetID, name: name, group: .user, addresses: addresses, searches: searches)
    }

    /// A list as written on the screen, read the way a plan reads it (`WarmUpPlan.pages`): its web
    /// addresses as the browser writes them, each once; its searches, one per line.
    static func typed(addresses: String, searches: String) -> WarmUpPreset {
        let reading = WarmUpPlan(addresses: addresses, searchQuery: searches).pages()
        let sites = reading.pages.filter { $0.kind == .address }.map(\.url.absoluteString)
        let queries = WarmUpPlan(searchQuery: searches).searches
        return WarmUpPreset(id: "manual", name: "", group: .user, addresses: sites, searches: queries)
    }
}

/// The person's warm-up templates — `warmup-templates.bin` at the vault's root, sealed under the
/// vault's own key for it, like the proxy list and the tags' colours. The whole vault's (any
/// profile can be warmed up with them) and this Mac's: not synced, and not part of a profile's
/// export, which carries one profile and not the lists a person keeps for all of them.
public struct WarmUpTemplates: Codable, Equatable, Sendable {
    /// The newest format of `warmup-templates.bin` this version reads and writes (docs/UPDATES.md §4).
    public static let supportedFormat = 1
    public static let maximumCount = 100

    public var format: Int
    /// In the order they were made.
    public var templates: [WarmUpTemplate]

    public init(format: Int = 1, templates: [WarmUpTemplate] = []) {
        self.format = format
        self.templates = templates
    }

    /// Keeps `template`: in place of one with its id, or of one with its name (whatever the case:
    /// saving "News" again is replacing it), or at the end. False when there is no room left.
    @discardableResult
    public mutating func save(_ template: WarmUpTemplate) -> Bool {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
            return true
        }
        if let index = templates.firstIndex(where: { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }) {
            var replaced = template
            replaced.id = templates[index].id
            templates[index] = replaced
            return true
        }
        guard templates.count < Self.maximumCount else { return false }
        templates.append(template)
        return true
    }

    public mutating func remove(_ id: UUID) {
        templates.removeAll { $0.id == id }
    }

    public func template(presetID: String) -> WarmUpTemplate? {
        templates.first { $0.presetID == presetID }
    }
}

extension WarmUpTemplates {
    /// `warmup-templates.bin`. A copy that does not open is never written over: a save moves it
    /// aside first (`EncryptedDocumentFile.makeWay`).
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<WarmUpTemplates> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("warmup-templates.bin"), key: try vault.warmUpTemplatesKey,
                              aad: "warm-up-templates:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// The vault's templates; none before the first was saved. Throws for a copy that does not
    /// open, and for a newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> WarmUpTemplates {
        try file(for: vault).load() ?? WarmUpTemplates()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open (moved
    /// aside as `warmup-templates.bin.unreadable` first).
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
