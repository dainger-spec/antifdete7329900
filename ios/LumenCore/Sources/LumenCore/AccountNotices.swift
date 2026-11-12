import Foundation

/// The two notices of the account the iPhone adds in the release (CONTRACT.md §8.5, §17.4):
/// `period.ending` — the paid period ends within seven days, and again within the last day, until
/// the person closes it; `clock.skew` — the iPhone's clock is more than ten minutes off the server's
/// (§8.3). The words are the contract's, "Mac" read as "iPhone".
public enum AccountNotices {
    /// The two times the period's end is said: seven days before, and once more in its last day.
    public enum EndingStage: String, Sendable { case week, day }

    /// The stage of `period.ending` now; nil: not within seven days, already over, or no paid period running.
    public static func periodEnding(_ entitlement: Entitlement?, now: Date) -> EndingStage? {
        guard !Faults.isActive(.periodEndingSilent), let entitlement, entitlement.status == .active,
              let end = entitlement.periodEndsAt else { return nil }
        let left = end.timeIntervalSince(now)
        guard left > 0, left < 7 * 86400 else { return nil }
        return left < 86400 ? .day : .week
    }

    public static func periodEndingText(_ end: Date, dateText: (Date) -> String) -> String {
        L("Оплаченный период заканчивается %@.", dateText(end))
    }

    /// `clock.skew`: nil within ten minutes.
    public static func clockSkew(_ skew: TimeInterval) -> String? {
        guard abs(skew) > 600 else { return nil }
        return L("Часы iPhone расходятся со временем сервера на %@. Исправьте дату и время в Настройках.", duration(abs(skew)))
    }

    /// "15 мин", "3 ч", "2 дн." — the largest whole unit.
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 86400 { return L("%@ дн.", "\(Int(seconds / 86400))") }
        if seconds >= 3600 { return L("%@ ч", "\(Int(seconds / 3600))") }
        return L("%@ мин", "\(max(1, Int(seconds / 60)))")
    }
}
