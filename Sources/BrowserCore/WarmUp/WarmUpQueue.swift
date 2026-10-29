import Foundation

/// Warm-ups that take turns: the profiles the user picked to warm up with one plan, and the runs
/// the schedule finds due. One runs at a time; the rest wait.
///
/// This is only the bookkeeping — who is next, how far along the queue is ("profile 2 of 5"),
/// what each run came to — so that it can be tested; the app's `WarmUpCoordinator` does the
/// launching and waiting.
public struct WarmUpQueue: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public enum Source: String, Equatable, Sendable {
            /// Picked by the user, to warm up with the plan chosen for all of them.
            case user
            /// Found due by the schedule; runs the profile's saved plan.
            case schedule
        }

        public enum State: Equatable, Sendable {
            case waiting
            case running
            /// The run is over: what it last reported (nil when nothing came back).
            case done(WarmUpStatus?)
            /// Its turn came and it was not run.
            case skipped(SkipReason)
            /// Taken off the queue before its turn ("cancel the rest", Lock).
            case cancelled
        }

        public enum SkipReason: String, Equatable, Sendable {
            /// The profile is running: it is in use, and a scheduled run does not start under the
            /// user's hands (the schedule tries again later).
            case inUse
            /// The profile, or its run, did not start; the reason was shown.
            case notStarted
            /// Nothing to visit: no saved plan, or one without a single page.
            case noPlan
            /// The profile was deleted meanwhile.
            case profileGone
        }

        /// Unique in the queue: the same profile can be in it again later.
        public let id: Int
        public let profileID: UUID
        public let source: Source
        /// The plan to run; nil for the profile's saved plan, read when its turn comes.
        public let plan: WarmUpPlan?
        public fileprivate(set) var state: State

        public var isPending: Bool { state == .waiting || state == .running }
    }

    public private(set) var entries: [Entry] = []
    private var lastID = 0

    public init() {}

    /// Something is running or waiting.
    public var isActive: Bool { entries.contains(where: \.isPending) }
    public var current: Entry? { entries.first { $0.state == .running } }
    public var waiting: [Entry] { entries.filter { $0.state == .waiting } }

    /// The profile is waiting in the queue, or its turn is now.
    public func isQueued(_ profileID: UUID) -> Bool {
        entries.contains { $0.profileID == profileID && $0.isPending }
    }

    /// The running entry's place in the queue, counted from 1, and how many the queue holds —
    /// "profile 2 of 5". Entries cancelled before their turn do not count: once the rest is
    /// cancelled, the run going on is the last of the queue. Nil while nothing runs.
    public var position: (number: Int, count: Int)? {
        let counted = entries.filter { $0.state != .cancelled }
        guard let index = counted.firstIndex(where: { $0.state == .running }) else { return nil }
        return (index + 1, counted.count)
    }

    /// Adds a profile at the end. Not when it is already waiting or running (a scheduled run of a
    /// profile the user just queued is that run). A queue whose runs are all over is cleared first:
    /// the next one begins from 1 again.
    @discardableResult
    public mutating func add(_ profileID: UUID, plan: WarmUpPlan?, source: Entry.Source) -> Bool {
        if !isActive { entries.removeAll() }
        guard !isQueued(profileID) else { return false }
        lastID += 1
        entries.append(Entry(id: lastID, profileID: profileID, source: source, plan: plan, state: .waiting))
        return true
    }

    /// The next waiting entry, now running. Nil when one is already running (one at a time) or
    /// none is waiting.
    public mutating func startNext() -> Entry? {
        guard current == nil, let index = entries.firstIndex(where: { $0.state == .waiting }) else { return nil }
        entries[index].state = .running
        return entries[index]
    }

    /// Ends the running entry `id` as `state` (done or skipped). Nothing for an entry that is not
    /// running: one cancelled meanwhile stays cancelled.
    public mutating func finish(_ id: Int, as state: Entry.State) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .running,
              state != .waiting, state != .running else { return }
        entries[index].state = state
    }

    /// Takes every waiting entry off the queue; the one running goes on. Returns those taken off.
    @discardableResult
    public mutating func cancelWaiting() -> [Entry] {
        var cancelled: [Entry] = []
        for index in entries.indices where entries[index].state == .waiting {
            entries[index].state = .cancelled
            cancelled.append(entries[index])
        }
        return cancelled
    }

    /// The running entry, cancelled too (Lock: the coordinator is going, and nothing will finish
    /// it).
    public mutating func cancelAll() {
        cancelWaiting()
        for index in entries.indices where entries[index].state == .running {
            entries[index].state = .cancelled
        }
    }
}
