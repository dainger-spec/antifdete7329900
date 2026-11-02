import Foundation

/// The system's notifications that the subscription is ending, for an account signed in with a key
/// alone: it has no email, so no letter can say it (the owner, 2 November). What is decided here:
/// when they are offered, and when they come.
///
/// Offered once — right after a key connected this Mac, or when the first warning before the
/// period's end appears — never at the first launch, and never again by itself after an answer,
/// whatever it was; Settings › Account offers them again. Refused, nothing changes: the banner stays.
public enum ExpiryReminders {
    /// The two moments the offer may be made at.
    public enum Moment: Equatable, Sendable {
        /// A key has just connected this Mac.
        case activatedWithKey
        /// The license's state changed (a refresh, the minute's tick): the offer is made when the
        /// first warning before the period's end is among the banners.
        case stateChanged
    }

    /// Whether the app's line, then the system's question, are shown now.
    /// `signedInWithKey`: this Mac is signed in, with a key. `alreadyOffered`: the offer was made on
    /// this Mac before, whatever the answer. `periodEnding`: a banner warns of the period's end.
    public static func shouldOffer(at moment: Moment, signedInWithKey: Bool, alreadyOffered: Bool, periodEnding: Bool) -> Bool {
        guard signedInWithKey, !alreadyOffered else { return false }
        switch moment {
        case .activatedWithKey: return true
        case .stateChanged: return periodEnding
        }
    }

    /// One reminder: a week before the period's end, or a day before — the banners' two warnings
    /// (`LicenseBanners.periodEndingWarning`, `periodEndingFinalWarning`).
    public struct Reminder: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case week
            case day
        }

        public var kind: Kind
        public var at: Date
        public var periodEndsAt: Date
    }

    /// The reminders for a period ending at `end`, those still ahead of `now`; none without a period.
    public static func reminders(periodEndsAt end: Date?, now: Date) -> [Reminder] {
        guard let end, end > now else { return [] }
        let before: [(Reminder.Kind, TimeInterval)] = [(.week, LicenseBanners.periodEndingWarning),
                                                        (.day, LicenseBanners.periodEndingFinalWarning)]
        return before
            .map { Reminder(kind: $0.0, at: end.addingTimeInterval(-$0.1), periodEndsAt: end) }
            .filter { $0.at > now }
    }
}
