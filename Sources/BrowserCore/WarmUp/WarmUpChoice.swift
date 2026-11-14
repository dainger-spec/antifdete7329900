import Foundation

/// What was chosen on the warm-up screen: a ready-made list (one the app ships, or one of the
/// person's own templates), a list the app puts together for this profile, or one written by
/// hand — with the two dials over it (how long the run may take, how thoroughly each page is read).
///
/// Kept beside the plan it produced (`WarmUpPlan.choice`), so the screen opens where it was left
/// and a scheduled run builds its list anew. The run itself uses the plan; this only says where
/// that plan came from.
public struct WarmUpChoice: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// One of the lists the app ships (`WarmUpPresets.all`), or one of the person's own
        /// (`WarmUpTemplate`, by `presetID` "user:<id>").
        case preset
        /// Put together here from the profile's own country and the kinds of browsing chosen.
        case composed
        /// Sites and searches written (or edited) by hand: `manualAddresses`, `manualSearches`.
        case manual
    }

    public var source: Source
    /// The chosen ready-made list, for `.preset`: a shipped one's id, or `WarmUpTemplate.presetID`.
    /// A version that does not know the person's templates finds no such list and runs the plan
    /// as it was saved.
    public var presetID: String
    /// The kinds of browsing mixed in, for `.composed`.
    public var interestIDs: [String]
    /// How long the run may take, in minutes: as many pages as fit are visited, then deeper.
    public var minutes: Int
    public var quality: WarmUpQuality
    /// For `.manual`: the sites and the searches as written, one per line. Nil in a choice saved
    /// before hand-written lists ran under the two dials: such a plan runs as it was saved.
    public var manualAddresses: String?
    public var manualSearches: String?

    public static let minuteRange: ClosedRange<Int> = 5...180

    public init(source: Source = .preset, presetID: String = "general",
                interestIDs: [String] = ["media", "shopping"], minutes: Int = 20,
                quality: WarmUpQuality = .normal, manualAddresses: String? = nil, manualSearches: String? = nil) {
        self.source = source
        self.presetID = presetID
        self.interestIDs = interestIDs
        self.minutes = minutes
        self.quality = quality
        self.manualAddresses = manualAddresses
        self.manualSearches = manualSearches
    }

    /// The list this choice stands for: the chosen preset (shipped, or one of `templates`), one
    /// composed for a profile whose proxy exits in `countryCode`, or the one written by hand. Nil
    /// when there is none to build from (a template deleted since, a hand-written list from
    /// before): the plan's own then runs.
    public func preset(countryCode: String?, composedName: String, templates: [WarmUpTemplate] = []) -> WarmUpPreset? {
        switch source {
        case .preset:
            return WarmUpPresets.preset(id: presetID) ?? templates.first { $0.presetID == presetID }?.preset
        case .composed:
            let interests = interestIDs.compactMap(WarmUpPresets.preset(id:))
            return WarmUpPresets.composed(countryCode: countryCode, interests: interests, name: composedName)
        case .manual:
            guard let manualAddresses else { return nil }
            return WarmUpTemplate.typed(addresses: manualAddresses, searches: manualSearches ?? "")
        }
    }

    /// The plan to run: the list fitted to `minutes` at this quality, its sites in an order of
    /// their own (a composed list and one written by hand keep theirs: the first leads with the
    /// profile's country, the second is the person's), with the choice kept on it. Nil when there
    /// is no list to build from.
    public func plan(countryCode: String?, composedName: String = "", templates: [WarmUpTemplate] = [],
                     using generator: inout some RandomNumberGenerator) -> WarmUpPlan? {
        guard let preset = preset(countryCode: countryCode, composedName: composedName, templates: templates) else { return nil }
        var plan = WarmUpPlan.from(preset: preset, minutes: minutes, quality: quality,
                                   keepingOrder: source != .preset, using: &generator)
        plan.choice = self
        return plan
    }

    /// The same, with the system's generator: a run of its own each time.
    public func plan(countryCode: String?, composedName: String = "", templates: [WarmUpTemplate] = []) -> WarmUpPlan? {
        var generator = SystemRandomNumberGenerator()
        return plan(countryCode: countryCode, composedName: composedName, templates: templates, using: &generator)
    }
}
