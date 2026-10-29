import Foundation

/// Where a warm-up run has got to, as one value: the profile list and the warm-up screen show
/// this, and nothing else about the run.
///
/// It has to be one value because the run happens in the profile's own process. The robot is
/// there, the screen is in the manager, and this is what crosses between them (`ProfileEvent`),
/// line by line, as the run goes on. A run in the manager's own process (`PB_PROFILE_PROCESS=0`)
/// builds the same value from its robot, so the screen does not know, or care, which it is
/// looking at.
public struct WarmUpStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case running
        /// Every page of the plan was visited.
        case finished
        /// Ended before that (the user, the profile stopped, its tab closed, a page asking).
        case stopped
    }

    public var phase: Phase
    /// Pages whose visit is over, and pages the plan has.
    public var visited: Int
    public var total: Int
    /// Of `visited`, those that did not load.
    public var failed: Int
    /// Cookies the profile has gained since this run began — what a warm-up is for.
    public var cookies: Int
    /// Roughly how much of the run is left, from what the pages so far actually took. Nil when
    /// the run is over, or before the first page is done.
    public var secondsRemaining: TimeInterval?
    /// The page being visited now, as a host name, for the screen to name.
    public var currentHost: String?

    public init(phase: Phase, visited: Int, total: Int, failed: Int = 0, cookies: Int = 0,
                secondsRemaining: TimeInterval? = nil, currentHost: String? = nil) {
        self.phase = phase
        self.visited = visited
        self.total = total
        self.failed = failed
        self.cookies = cookies
        self.secondsRemaining = secondsRemaining
        self.currentHost = currentHost
    }

    public var isRunning: Bool { phase == .running }
    /// The page being visited, counted from 1 — "page 4 of 12" — never past the last.
    public var currentPage: Int { total > 0 ? min(visited + 1, total) : 0 }
    /// 0…1, for a progress bar.
    public var fraction: Double { total > 0 ? min(1, Double(visited) / Double(total)) : 0 }
}
