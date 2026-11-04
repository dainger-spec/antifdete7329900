import Foundation

/// "Warm this profile up every N hours with its saved plan." Kept per profile, encrypted
/// (`warmup-schedule.bin`), on this Mac only, together with when it last ran.
///
/// Like the plan it is not synced; unlike the plan it is not carried by a profile export either.
/// It is this Mac's timer: another Mac should not start launching a profile in the background
/// because this one was told to.
public struct WarmUpSchedule: Codable, Equatable, Sendable {
    /// Off keeps the interval and the times, so turning it back on asks nothing again.
    public var isEnabled: Bool
    public var everyHours: Int
    /// When repeating was turned on. The first run is one interval after it rather than at once:
    /// the warm-up screen's Start is there for a run now, and a profile starting in the background
    /// the moment a switch is flipped is a surprise.
    public var since: Date
    /// When a run of the profile last ended having visited at least one page — started by the
    /// schedule, a queue or the warm-up screen alike: any of them warms the profile.
    public var lastRunAt: Date?
    /// When the schedule last started a run of the profile, or tried to and could not (the launch
    /// failed, the plan has no page, the run visited nothing). Counted as a run, so that a profile
    /// whose proxy is down is not launched again every few minutes, each time with an error.
    public var lastAttemptAt: Date?

    public static let hourRange: ClosedRange<Int> = 1...168

    public init(isEnabled: Bool = true, everyHours: Int = 24, since: Date = Date(),
                lastRunAt: Date? = nil, lastAttemptAt: Date? = nil) {
        self.isEnabled = isEnabled
        self.everyHours = everyHours
        self.since = since
        self.lastRunAt = lastRunAt
        self.lastAttemptAt = lastAttemptAt
    }

    /// The interval in seconds, its hours kept to `hourRange`.
    public var interval: TimeInterval {
        TimeInterval(min(max(everyHours, Self.hourRange.lowerBound), Self.hourRange.upperBound)) * 3600
    }

    /// The latest of the times a run is counted from.
    public var countedFrom: Date {
        [since, lastRunAt, lastAttemptAt].compactMap { $0 }.max() ?? since
    }

    /// When the next run is due: one interval after the latest of `since`, the last run and the
    /// last attempt. A Mac that slept through several intervals runs once when it wakes, not once
    /// per interval missed: the profile wants warming, not catching up.
    public var nextRun: Date { countedFrom.addingTimeInterval(interval) }

    public func isDue(at now: Date) -> Bool { isEnabled && nextRun <= now }

    /// The schedule with every time later than `now` taken as `now`. A clock set back would
    /// otherwise leave the profile waiting until the clock catches up with a time it already went
    /// past, and then an interval more.
    public func clamped(to now: Date) -> WarmUpSchedule {
        var schedule = self
        schedule.since = min(since, now)
        schedule.lastRunAt = lastRunAt.map { min($0, now) }
        schedule.lastAttemptAt = lastAttemptAt.map { min($0, now) }
        return schedule
    }
}

/// Which profiles' warm-ups are due, and when — what the manager's timer asks while the app is
/// unlocked. A run found due goes into the warm-up queue, where runs take turns, one at a time.
///
/// A profile that is in use when its run is due — running, so its windows are the user's — is put
/// off for `retryDelay` and tried again then, not left until its next interval: the schedule
/// wants it warmed, just not under the user's hands. Being put off lives here, in memory only; a
/// relaunched app simply finds the run due again.
public struct WarmUpScheduler: Equatable, Sendable {
    public private(set) var schedules: [UUID: WarmUpSchedule]
    /// Due runs put off, and until when.
    public private(set) var postponedUntil: [UUID: Date] = [:]

    public static let retryDelay: TimeInterval = 10 * 60

    public init(schedules: [UUID: WarmUpSchedule] = [:]) {
        self.schedules = schedules
    }

    /// Sets (or, nil, removes) a profile's schedule; a run put off is no longer.
    public mutating func set(_ schedule: WarmUpSchedule?, for id: UUID) {
        schedules[id] = schedule
        postponedUntil[id] = nil
    }

    /// Forgets the schedules of profiles that are not in `ids` (deleted since).
    public mutating func keep(only ids: Set<UUID>) {
        for id in Array(schedules.keys) where !ids.contains(id) {
            schedules[id] = nil
            postponedUntil[id] = nil
        }
    }

    /// The profiles whose run is due at `now` and not put off, the longest overdue first. Takes a
    /// clock set back into account first (`WarmUpSchedule.clamped`), which is why it mutates.
    public mutating func due(at now: Date) -> [UUID] {
        for (id, schedule) in schedules {
            let clamped = schedule.clamped(to: now)
            if clamped != schedule { schedules[id] = clamped }
        }
        struct Due {
            var id: UUID
            var at: Date
        }
        let due: [Due] = schedules.compactMap { id, schedule in
            guard schedule.isDue(at: now) else { return nil }
            if let until = postponedUntil[id], until > now { return nil }
            return Due(id: id, at: schedule.nextRun)
        }
        return due.sorted { a, b in a.at != b.at ? a.at < b.at : a.id.uuidString < b.id.uuidString }.map(\.id)
    }

    /// The run of `id` could not happen now (the profile was in use): tried again `retryDelay`
    /// after `now`.
    public mutating func postpone(_ id: UUID, at now: Date) {
        guard schedules[id] != nil else { return }
        postponedUntil[id] = now.addingTimeInterval(Self.retryDelay)
    }

    /// A run of `id` ended having visited pages, whoever started it. Returns the schedule to
    /// store; nil when the profile has none.
    @discardableResult
    public mutating func recordRun(_ id: UUID, at date: Date) -> WarmUpSchedule? {
        guard var schedule = schedules[id] else { return nil }
        schedule.lastRunAt = date
        schedules[id] = schedule
        postponedUntil[id] = nil
        return schedule
    }

    /// The schedule started a run of `id`, or tried to: whatever came of it, the next is one
    /// interval later. Returns the schedule to store; nil when the profile has none.
    @discardableResult
    public mutating func recordAttempt(_ id: UUID, at date: Date) -> WarmUpSchedule? {
        guard var schedule = schedules[id] else { return nil }
        schedule.lastAttemptAt = date
        schedules[id] = schedule
        postponedUntil[id] = nil
        return schedule
    }

    /// When the profile's next run is to start, as far as the schedule goes: when it is due, or
    /// later when it was put off (a run already due shows as now). Nil without a schedule, or
    /// with one that is off.
    public func nextRun(of id: UUID, now: Date) -> Date? {
        guard let schedule = schedules[id]?.clamped(to: now), schedule.isEnabled else { return nil }
        var next = max(schedule.nextRun, now)
        if let until = postponedUntil[id], until > next { next = until }
        return next
    }

    /// The earliest next run of all, for the timer to know when to look again.
    public func nextCheck(now: Date) -> Date? {
        schedules.keys.compactMap { nextRun(of: $0, now: now) }.min()
    }
}
