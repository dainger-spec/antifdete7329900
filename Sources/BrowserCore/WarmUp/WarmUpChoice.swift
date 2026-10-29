import Foundation

/// What was chosen on the warm-up screen: a ready-made list, a list the app puts together for
/// this profile, or one written by hand — with the two dials over it (how long the run may take,
/// how thoroughly each page is read).
///
/// Kept beside the plan it produced (`WarmUpPlan.choice`), so the screen opens where it was left.
/// The run itself uses the plan; this only says where that plan came from.
public struct WarmUpChoice: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// One of the lists the app ships (`WarmUpPresets.all`).
        case preset
        /// Put together here from the profile's own country and the kinds of browsing chosen.
        case composed
        /// The addresses in the plan, as they were typed.
        case manual
    }

    public var source: Source
    /// The chosen ready-made list, for `.preset`.
    public var presetID: String
    /// The kinds of browsing mixed in, for `.composed`.
    public var interestIDs: [String]
    /// How long the run may take, in minutes: as many pages as fit are visited.
    public var minutes: Int
    public var quality: WarmUpQuality

    public static let minuteRange: ClosedRange<Int> = 5...180

    public init(source: Source = .preset, presetID: String = "general",
                interestIDs: [String] = ["media", "shopping"], minutes: Int = 20,
                quality: WarmUpQuality = .normal) {
        self.source = source
        self.presetID = presetID
        self.interestIDs = interestIDs
        self.minutes = minutes
        self.quality = quality
    }

    /// The list this choice stands for: the chosen preset, or one composed for a profile whose
    /// proxy exits in `countryCode`. Nil for a hand-written list, which is the plan's own.
    public func preset(countryCode: String?, composedName: String) -> WarmUpPreset? {
        switch source {
        case .preset:
            return WarmUpPresets.preset(id: presetID)
        case .composed:
            let interests = interestIDs.compactMap(WarmUpPresets.preset(id:))
            return WarmUpPresets.composed(countryCode: countryCode, interests: interests, name: composedName)
        case .manual:
            return nil
        }
    }

    /// The plan to run: the preset cut to fit `minutes` at this quality, with the choice kept on
    /// it. Nil for a hand-written list.
    public func plan(countryCode: String?, composedName: String = "") -> WarmUpPlan? {
        guard let preset = preset(countryCode: countryCode, composedName: composedName) else { return nil }
        var plan = WarmUpPlan.from(preset: preset, minutes: minutes, quality: quality)
        plan.choice = self
        return plan
    }
}
