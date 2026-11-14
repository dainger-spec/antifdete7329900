import BrowserCore
import Foundation

/// What a session's name, description and tags may be: the Mac's own limits for a profile, kept for
/// every session here. A session made from the Mac's vault sends its name, description and tags to
/// the Mac (step 5), and the Mac refuses a longer name (`ProfileRepository`), cuts a longer
/// description (`ProfileConfiguration.maximumNotesLength`) and holds tags to its rules
/// (`ProfileTags`): written here within them, an edit is never refused there, nor cut on its way
/// back.
public enum SessionLimits {
    /// A name: 1–128 characters, as the Mac's profile names.
    public static let nameLength = 128
    /// A description, at most.
    public static let notesLength = ProfileConfiguration.maximumNotesLength
    /// Tags: at most this many, each at most `tagLength` characters.
    public static let tagCount = ProfileTags.maximumCount
    public static let tagLength = ProfileTags.maximumLength

    /// The name trimmed and cut to `nameLength` (empty: no name given).
    public static func name(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(nameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The description cut to `notesLength`.
    public static func notes(_ notes: String) -> String {
        String(notes.prefix(notesLength))
    }

    /// "work, Ads ,work" → ["work", "Ads"]: split at commas and new lines, each trimmed, no empty
    /// ones, no repeats (ignoring case), each cut to `tagLength`, at most `tagCount` — the Mac's
    /// `ProfileTags.normalized`.
    public static func tags(_ tags: [String]) -> [String] {
        ProfileTags.normalized(tags.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",\n")) })
    }
}
