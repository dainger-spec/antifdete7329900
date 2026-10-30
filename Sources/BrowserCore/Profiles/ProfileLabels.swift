import Foundation

/// A profile's tags (`ProfileConfiguration.tags`): the person's own labels, which the Profiles
/// list shows on each row and filters by.
public enum ProfileTags {
    public static let maximumCount = 20
    public static let maximumLength = 32

    /// Each tag trimmed (spaces and new lines inside one become a single space), cut to
    /// `maximumLength` characters; empty ones dropped; of tags that differ only in case, the
    /// first kept; at most `maximumCount`, in the order given.
    public static func normalized(_ tags: [String]) -> [String] {
        var kept: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let words = tag.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            let cleaned = String(words.joined(separator: " ").prefix(maximumLength))
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            kept.append(cleaned)
            if kept.count == maximumCount { break }
        }
        return kept
    }

    /// Tags written in one field, separated by commas or new lines.
    public static func parse(_ text: String) -> [String] {
        normalized(text.components(separatedBy: CharacterSet(charactersIn: ",\n")))
    }

    /// Whether `tags` has `tag`, whatever the case.
    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

/// How a profile's glyph looks (`ProfileConfiguration.avatar`): a colour of the app's palette,
/// and up to two characters of its own instead of the first letter of the name.
public struct ProfileAvatarStyle: Codable, Equatable, Sendable {
    /// How many colours the palette has.
    public static let colorCount = 8
    public static let maximumLetters = 2

    /// An index into the palette; nil: the colour the profile's id gives.
    public var color: Int?
    /// Shown instead of the first letter of the name; nil: that letter.
    public var letters: String?

    public init(color: Int? = nil, letters: String? = nil) {
        self.color = color
        self.letters = letters
    }

    /// Held to what the app can show — a colour of the palette, at most two characters that are
    /// not spaces — and nil when it says nothing (the default look).
    public var normalized: ProfileAvatarStyle? {
        let color = self.color.flatMap { (0..<Self.colorCount).contains($0) ? $0 : nil }
        let shown = (self.letters ?? "").filter { !$0.isWhitespace && !$0.isNewline }.prefix(Self.maximumLetters)
        let letters = shown.isEmpty ? nil : String(shown)
        guard color != nil || letters != nil else { return nil }
        return ProfileAvatarStyle(color: color, letters: letters)
    }
}
