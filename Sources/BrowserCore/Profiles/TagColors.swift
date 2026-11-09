import Foundation

/// The colours the person gave their tags — `labels.bin` at the vault's root: one choice per tag,
/// whatever its case, for the whole vault, so that every profile with the tag shows it. It is not
/// part of any profile's settings: a profile's own model is unchanged (the owner, 1 November). It is
/// synced as an object of its own ("labels", docs/SYNC_FORMAT.md) and merged tag by tag — the later
/// choice wins, taking a colour away included — so a version of the app that does not know the
/// object never reads it, nor writes it back without what it did not know.
///
/// Its place beside a profile's glyph (the owner): tags group by meaning, a profile's glyph tells
/// profiles apart within a group. The same eight colours (`ProfileAvatarStyle.colorCount`), told
/// apart by their form: a tag's is a dot, a profile's a circle (docs/DESIGN.md).
public struct TagColors: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        /// An index into the palette; nil: the colour was taken away.
        public var color: Int?
        /// When it was made: of two devices' choices for one tag, the later is kept.
        public var chosenAt: Date

        public init(color: Int?, chosenAt: Date) {
            self.color = color
            self.chosenAt = chosenAt
        }
    }

    /// The newest format of `labels.bin` this version reads and writes (docs/UPDATES.md §4).
    public static let supportedFormat = 1

    public var format: Int
    /// By the tag's name in lower case: tags are one whatever their case (`ProfileTags`).
    public var choices: [String: Choice]

    public init(format: Int = 1, choices: [String: Choice] = [:]) {
        self.format = format
        self.choices = choices
    }

    /// The colour `tag` has, whatever its case; nil: none.
    public func color(of tag: String) -> Int? {
        choices[Self.key(tag)]?.color
    }

    /// Gives `tag` a colour of the palette, or takes its colour away (nil). A colour outside the
    /// palette counts as none. Taking away a colour a tag never had leaves nothing behind.
    public mutating func set(_ color: Int?, for tag: String, at date: Date = Date()) {
        let key = Self.key(tag)
        guard !key.isEmpty else { return }
        let valid = color.flatMap { (0..<ProfileAvatarStyle.colorCount).contains($0) ? $0 : nil }
        if valid == nil, choices[key] == nil { return }
        choices[key] = Choice(color: valid, chosenAt: date)
    }

    /// The key a tag's choice is kept under.
    public static func key(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Sync merge, tag by tag: the later choice; at the same moment, one with a colour over none,
    /// then the lower colour — so that whichever device merges, the result is the same. Idempotent
    /// and commutative (TagColorsTests).
    public static func merge(_ a: TagColors, _ b: TagColors) -> TagColors {
        var merged = a.choices
        for (key, theirs) in b.choices {
            guard let mine = merged[key] else {
                merged[key] = theirs
                continue
            }
            if wins(theirs, over: mine) { merged[key] = theirs }
        }
        return TagColors(format: supportedFormat, choices: merged)
    }

    private static func wins(_ a: Choice, over b: Choice) -> Bool {
        if a.chosenAt != b.chosenAt { return a.chosenAt > b.chosenAt }
        switch (a.color, b.color) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(x), .some(y)): return x < y
        }
    }
}

extension TagColors {
    /// `labels.bin`, sealed under the vault's own key for it. A copy that does not open is never
    /// written over: a save moves it aside first (`EncryptedDocumentFile.makeWay`).
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<TagColors> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("labels.bin"), key: try vault.labelsKey,
                              aad: "profile-labels:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// The vault's tag colours; none before the first was chosen. Throws for a copy that does not
    /// open, and for a newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> TagColors {
        try file(for: vault).load() ?? TagColors()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open (moved aside
    /// as `labels.bin.unreadable` first).
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
