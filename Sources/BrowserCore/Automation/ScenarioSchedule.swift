import Foundation

/// Something run on a profile by the clock: a scenario, or the profile's warm-up — "every day at
/// 10:00, give or take a quarter of an hour", or every so many hours. While the app is running and
/// its vault is open: nothing wakes the Mac or starts the app (docs/AUTOMATION.md, "By the clock").
public struct ScenarioSchedule: Codable, Equatable, Sendable, Identifiable {
    public enum Action: Codable, Hashable, Sendable {
        case scenario(UUID)
        /// The profile's own warm-up plan (`WarmUpPlan`), as its Warm Up button runs it.
        case warmUp
    }

    public enum When: Codable, Equatable, Sendable {
        /// Once a day, at this time of this Mac's clock.
        case daily(hour: Int, minute: Int)
        /// Again this many hours after the last run.
        case every(hours: Int)
    }

    public static let jitterAllowed = 0...180
    public static let hoursAllowed = 1...168
    /// A run this late is not made any more (the Mac slept through it, or the app was closed): the
    /// next one is waited for instead. A daily run at 10:00 found at 15:00 is still made; found the
    /// next morning, it is not made twice.
    public static let tooLate: TimeInterval = 6 * 3600

    public var id: UUID
    public var action: Action
    public var profileID: UUID
    public var when: When
    /// The run is moved by a random time within this many minutes either way, anew each time: a
    /// run at 10:00 sharp every day is a robot's.
    public var jitterMinutes: Int
    public var isEnabled: Bool
    /// When it runs next, with that run's random part already in it (so that it does not move
    /// every time it is looked at). Nil: not planned yet.
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    /// How the last run that came due went.
    public var lastResult: Result?

    public enum Result: String, Codable, Sendable {
        case started
        /// The profile did not start, or the scenario is gone.
        case failed
        /// Found too late to make (`tooLate`).
        case missed
        /// The plan has no automation.
        case notInPlan
    }

    public init(id: UUID = UUID(), action: Action, profileID: UUID, when: When, jitterMinutes: Int = 15, isEnabled: Bool = true) {
        self.id = id
        self.action = action
        self.profileID = profileID
        self.when = when
        self.jitterMinutes = jitterMinutes
        self.isEnabled = isEnabled
    }

    /// Held to what can run: an hour and a minute of a day, a whole number of hours, a bounded jitter.
    public var clamped: ScenarioSchedule {
        var schedule = self
        switch when {
        case let .daily(hour, minute): schedule.when = .daily(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59))
        case let .every(hours): schedule.when = .every(hours: min(max(hours, Self.hoursAllowed.lowerBound), Self.hoursAllowed.upperBound))
        }
        schedule.jitterMinutes = min(max(jitterMinutes, Self.jitterAllowed.lowerBound), Self.jitterAllowed.upperBound)
        return schedule
    }

    /// The run after `date`: the next time of day (or `date` plus the hours), moved by a random
    /// number of minutes within the jitter — and never sooner than a minute from `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current,
                        random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> Date {
        let schedule = clamped
        let base: Date
        switch schedule.when {
        case let .daily(hour, minute):
            // From the jitter's width before `date` on: a run made a little early (its random part
            // was negative) must not find "today, at the same time" as its next.
            let from = date.addingTimeInterval(Double(schedule.jitterMinutes) * 60)
            base = calendar.nextDate(after: from, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                     matchingPolicy: .nextTime) ?? from.addingTimeInterval(86_400)
        case let .every(hours):
            base = date.addingTimeInterval(Double(hours) * 3600)
        }
        let moved = schedule.jitterMinutes == 0 ? 0 : random(-schedule.jitterMinutes...schedule.jitterMinutes)
        return max(base.addingTimeInterval(Double(moved) * 60), date.addingTimeInterval(60))
    }
}

/// The schedules of this Mac — `scenario-schedules.bin` at the vault's root, sealed under the
/// scenarios' key. A file of its own, so that a version from before schedules reads and writes
/// `scenarios.bin` as it did and never sees this one.
public struct ScenarioSchedules: Codable, Equatable, Sendable {
    public static let supportedFormat = 1

    public var format: Int
    public var schedules: [ScenarioSchedule]

    public init(format: Int = 1, schedules: [ScenarioSchedule] = []) {
        self.format = format
        self.schedules = schedules
    }

    /// The enabled schedules whose time has come: those to run now, and those found too late.
    public func due(at now: Date) -> (run: [ScenarioSchedule], missed: [ScenarioSchedule]) {
        let arrived = schedules.filter { $0.isEnabled && ($0.nextRunAt.map { $0 <= now } ?? false) }
        return (arrived.filter { now.timeIntervalSince($0.nextRunAt ?? now) <= ScenarioSchedule.tooLate },
                arrived.filter { now.timeIntervalSince($0.nextRunAt ?? now) > ScenarioSchedule.tooLate })
    }

    /// Adds `schedule`, or replaces the one with its id; an enabled one is planned from `now` when
    /// it has no time yet, or when what decides its time changed.
    public mutating func put(_ schedule: ScenarioSchedule, at now: Date = Date(), calendar: Calendar = .current,
                             random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) {
        var changed = schedule.clamped
        let before = schedules.first { $0.id == schedule.id }
        if changed.nextRunAt == nil || before?.when != changed.when || before?.jitterMinutes != changed.jitterMinutes {
            changed.nextRunAt = changed.nextRun(after: now, calendar: calendar, random: random)
        }
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = changed
        } else {
            schedules.append(changed)
        }
    }

    public mutating func remove(_ id: UUID) {
        schedules.removeAll { $0.id == id }
    }

    /// A due schedule dealt with at `now`: how it went, and its next run planned from now. A run
    /// that was started counts as the last run.
    public mutating func record(_ id: UUID, _ result: ScenarioSchedule.Result, at now: Date, calendar: Calendar = .current,
                                random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].lastResult = result
        if result == .started { schedules[index].lastRunAt = now }
        schedules[index].nextRunAt = schedules[index].nextRun(after: now, calendar: calendar, random: random)
    }

    /// Its profile is busy now (running a scenario, starting, being sealed): looked at again then.
    public mutating func postpone(_ id: UUID, until date: Date) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].nextRunAt = date
    }

    /// Schedules of profiles and scenarios that are gone go with them. True when any did.
    @discardableResult
    public mutating func keep(profiles: Set<UUID>, scenarios: Set<UUID>) -> Bool {
        let count = schedules.count
        schedules.removeAll { schedule in
            if !profiles.contains(schedule.profileID) { return true }
            if case let .scenario(id) = schedule.action { return !scenarios.contains(id) }
            return false
        }
        return schedules.count != count
    }
}

extension ScenarioSchedules {
    static func file(for vault: UnlockedVault) throws -> EncryptedDocumentFile<ScenarioSchedules> {
        EncryptedDocumentFile(url: vault.root.appendingPathComponent("scenario-schedules.bin"), key: try vault.scenariosKey,
                              aad: "scenario-schedules:v1:\(vault.vaultID.uuidString)", supportedFormat: supportedFormat)
    }

    /// This Mac's schedules; none before the first. Throws for a copy that does not open, and for a
    /// newer version's (`CoreError.newerFormat`).
    public static func load(from vault: UnlockedVault) throws -> ScenarioSchedules {
        try file(for: vault).load() ?? ScenarioSchedules()
    }

    /// Writes them — never over a newer version's copy, nor over one that does not open.
    public func save(to vault: UnlockedVault) throws {
        try Self.file(for: vault).save(self)
    }
}
