import Foundation

/// How the profile's last warm-up went — "warmed 2 days ago, 14 pages, 37 cookies" — kept per
/// profile, encrypted (`warmup-last.bin`), on this Mac only, like the schedule.
///
/// Written when a run ends having visited at least one page, whoever started it (the warm-up
/// screen, a queue, the schedule). The inspector shows it, so that a profile that was never
/// warmed, or not for a month, is told apart from one warmed this morning without opening it.
public struct WarmUpRecord: Codable, Equatable, Sendable {
    public var endedAt: Date
    /// Pages that loaded: visited and not failed.
    public var pages: Int
    /// Pages the plan had.
    public var total: Int
    /// Cookies the profile gained in the run (`WarmUpStatus.cookies`).
    public var cookies: Int
    /// Every page of the plan was visited.
    public var finished: Bool

    public init(endedAt: Date, pages: Int, total: Int, cookies: Int, finished: Bool) {
        self.endedAt = endedAt
        self.pages = pages
        self.total = total
        self.cookies = cookies
        self.finished = finished
    }

    /// The record of a run that is over, as its last status has it; nil while it runs or when it
    /// visited nothing — a run that loaded no page warmed nothing worth telling.
    public init?(_ status: WarmUpStatus, at date: Date) {
        guard !status.isRunning, status.visited > 0 else { return nil }
        self.init(endedAt: date, pages: max(0, status.visited - status.failed), total: status.total,
                  cookies: status.cookies, finished: status.phase == .finished)
    }
}
