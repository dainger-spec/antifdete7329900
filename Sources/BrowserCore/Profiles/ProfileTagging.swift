import Foundation

/// What changing the tags of several profiles at once did.
public struct TagChangeOutcome: Equatable, Sendable {
    /// Profiles whose tags are now other ones (saved as an edit: synced like one).
    public var changed: [UUID] = []
    /// Profiles that already had every tag to add and none of those to remove: nothing was written.
    public var unchanged: [UUID] = []
    /// Profiles that hold `ProfileTags.maximumCount` tags and had no room for every tag to add:
    /// they got the ones there was room for (they may be among `changed`, or `unchanged`).
    public var full: [UUID] = []
    /// Profiles that could not be changed, with why (their settings do not read, …).
    public var failed: [UUID: String] = [:]

    public init(changed: [UUID] = [], unchanged: [UUID] = [], full: [UUID] = [], failed: [UUID: String] = [:]) {
        self.changed = changed
        self.unchanged = unchanged
        self.full = full
        self.failed = failed
    }
}

extension ProfileRepository {
    /// Adds tags to, and removes tags from, each of `ids` (`ProfileTags.changing`) — what the
    /// Profiles list does for a selection, where the editor does it for one profile. Each profile's
    /// settings are read, changed in their tags alone and saved as the editor saves an edit
    /// (`savingEdit(over:)`: what the browser keeps for itself stays, and sync carries the change);
    /// a profile that already stands as asked is not written. Settings that do not read are never
    /// written over (R1): that profile is in `failed`, and the others are still changed.
    @discardableResult
    public func changeTags(of ids: [UUID], adding: [String], removing: [String], at time: Date = Date()) -> TagChangeOutcome {
        var outcome = TagChangeOutcome()
        for id in ids {
            do {
                let stored = try loadConfiguration(id)
                let change = ProfileTags.changing(stored.tags, adding: adding, removing: removing)
                if !change.notAdded.isEmpty { outcome.full.append(id) }
                guard change.tags != stored.tags else {
                    outcome.unchanged.append(id)
                    continue
                }
                var edited = stored
                edited.tags = change.tags
                try saveConfiguration(edited.savingEdit(over: stored, at: time), for: id)
                outcome.changed.append(id)
            } catch {
                outcome.failed[id] = error.localizedDescription
            }
        }
        return outcome
    }
}
