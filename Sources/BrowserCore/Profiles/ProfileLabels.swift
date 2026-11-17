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

    /// `tags` after a change made to several profiles at once (`ProfileRepository.changeTags`):
    /// those of `removing` taken away, whatever their case, then those of `adding` the profile
    /// does not have yet put after its own, in the order given. A profile holds at most
    /// `maximumCount`: the tags there was no room for are `notAdded` — said, never dropped
    /// silently. A tag in both lists is added: the removal is of what the profile had.
    public static func changing(_ tags: [String], adding: [String], removing: [String]) -> (tags: [String], notAdded: [String]) {
        let dropped = normalized(removing)
        let kept = normalized(tags).filter { !contains(dropped, $0) }
        let wanted = normalized(adding).filter { !contains(kept, $0) }
        let room = max(0, maximumCount - kept.count)
        return (kept + wanted.prefix(room), Array(wanted.dropFirst(room)))
    }
}

/// How a profile's glyph looks (`ProfileConfiguration.avatar`): a colour of the app's palette,
/// and up to two characters of its own instead of the first letter of the name.
public struct ProfileAvatarStyle: Codable, Equatable, Sendable {
    /// How many colours the palette has.
    public static let colorCount = 8
    public static let maximumLetters = 2

    /// How many of the palette's colours a profile's id picks among (as before there was a choice).
    public static let idColorCount = 5

    /// The colour a profile's id gives when none was chosen: an index into the palette, the same at
    /// every launch (from the id's bytes; `hashValue` is seeded per launch).
    public static func color(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } } % idColorCount
    }

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

/// The title of a profile's browser window: the profile's name before the page's, so that the
/// window is told from another profile's wherever the system lists windows by title — the Window
/// menu, the Dock's menu, Mission Control — in a window of ours and in Safari's alike.
public enum ProfileWindowTitle {
    /// The profile's name as a title begins with it.
    public static func mark(of profile: String) -> String {
        "[\(profile.trimmingCharacters(in: .whitespacesAndNewlines))]"
    }

    /// `title` with the profile's name before it; one that has it already stays as it is, and a
    /// window with no page yet is titled with the name alone. A profile without a name marks nothing.
    public static func marked(_ title: String, profile: String) -> String {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        let name = mark(of: profile)
        if title == name || title.hasPrefix(name + " ") { return title }
        return title.isEmpty ? name : name + " " + title
    }

    /// `title` without the profile's name before it, as the browser gave it.
    public static func unmarked(_ title: String, profile: String) -> String {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        let name = mark(of: profile)
        if title == name { return "" }
        return title.hasPrefix(name + " ") ? String(title.dropFirst(name.count + 1)) : title
    }
}
