import XCTest
@testable import BrowserCore

/// Runs by the clock: when the next one is, that its random part stays within what was asked, and
/// what becomes of a run found late.
final class ScenarioScheduleTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 12 November 2026, 08:00 UTC.
    private let morning = Date(timeIntervalSince1970: 1_794_470_400)
    private let profile = UUID()

    private func daily(_ hour: Int, _ minute: Int, jitter: Int = 0) -> ScenarioSchedule {
        ScenarioSchedule(action: .warmUp, profileID: profile, when: .daily(hour: hour, minute: minute), jitterMinutes: jitter)
    }

    func testTheNextDailyRunIsTodayOrTomorrow() {
        XCTAssertEqual(utc.component(.hour, from: morning), 8, "the fixture is 08:00 UTC")
        let today = daily(10, 0).nextRun(after: morning, calendar: utc)
        XCTAssertEqual(today.timeIntervalSince(morning), 2 * 3600)
        let tomorrow = daily(7, 30).nextRun(after: morning, calendar: utc)
        XCTAssertEqual(tomorrow.timeIntervalSince(morning), 23.5 * 3600)
        // At the very minute: the next one, not this one again.
        XCTAssertEqual(daily(8, 0).nextRun(after: morning, calendar: utc).timeIntervalSince(morning), 24 * 3600)
    }

    func testTheRandomPartStaysWithinTheJitterEitherWay() {
        let schedule = daily(10, 0, jitter: 15)
        let base = morning.addingTimeInterval(2 * 3600)
        XCTAssertEqual(schedule.nextRun(after: morning, calendar: utc) { $0.lowerBound }, base.addingTimeInterval(-15 * 60))
        XCTAssertEqual(schedule.nextRun(after: morning, calendar: utc) { $0.upperBound }, base.addingTimeInterval(15 * 60))
        for _ in 0..<200 {
            let run = schedule.nextRun(after: morning, calendar: utc)
            XCTAssertLessThanOrEqual(abs(run.timeIntervalSince(base)), 15 * 60)
        }
        // A run made early (09:50 for 10:00) plans tomorrow's, not "today at 10:00" ten minutes on.
        let early = base.addingTimeInterval(-10 * 60)
        XCTAssertEqual(schedule.nextRun(after: early, calendar: utc) { _ in 0 }, base.addingTimeInterval(24 * 3600))
        // Never in the past, never at once.
        let soon = daily(8, 1, jitter: 180).nextRun(after: morning, calendar: utc) { $0.lowerBound }
        XCTAssertGreaterThanOrEqual(soon.timeIntervalSince(morning), 60)
    }

    func testEveryHoursAndTheLimits() {
        let every = ScenarioSchedule(action: .warmUp, profileID: profile, when: .every(hours: 6), jitterMinutes: 0)
        XCTAssertEqual(every.nextRun(after: morning, calendar: utc).timeIntervalSince(morning), 6 * 3600)
        let odd = ScenarioSchedule(action: .warmUp, profileID: profile, when: .every(hours: 0), jitterMinutes: 999).clamped
        XCTAssertEqual(odd.when, .every(hours: 1))
        XCTAssertEqual(odd.jitterMinutes, 180)
        XCTAssertEqual(daily(25, 70).clamped.when, .daily(hour: 23, minute: 59))
    }

    func testWhatIsDueWhatIsLateAndWhatARunLeaves() {
        var schedules = ScenarioSchedules()
        let scenario = UUID()
        var run = ScenarioSchedule(action: .scenario(scenario), profileID: profile, when: .daily(hour: 10, minute: 0), jitterMinutes: 0)
        schedules.put(run, at: morning, calendar: utc)
        run = schedules.schedules[0]
        XCTAssertEqual(run.nextRunAt, morning.addingTimeInterval(2 * 3600), "planned when it was added")
        XCTAssertTrue(schedules.due(at: morning).run.isEmpty)

        let atTen = morning.addingTimeInterval(2 * 3600 + 30)
        XCTAssertEqual(schedules.due(at: atTen).run.map(\.id), [run.id])
        // Found five hours late it still runs; found the next morning it does not.
        XCTAssertEqual(schedules.due(at: atTen.addingTimeInterval(5 * 3600)).run.count, 1)
        let nextMorning = atTen.addingTimeInterval(20 * 3600)
        XCTAssertTrue(schedules.due(at: nextMorning).run.isEmpty)
        XCTAssertEqual(schedules.due(at: nextMorning).missed.map(\.id), [run.id])

        schedules.record(run.id, .started, at: atTen, calendar: utc)
        XCTAssertEqual(schedules.schedules[0].lastRunAt, atTen)
        XCTAssertEqual(schedules.schedules[0].lastResult, .started)
        XCTAssertEqual(schedules.schedules[0].nextRunAt, morning.addingTimeInterval(26 * 3600), "tomorrow at ten")
        XCTAssertTrue(schedules.due(at: atTen).run.isEmpty, "not twice")

        // A miss plans the next run and is not a run.
        schedules.record(run.id, .missed, at: nextMorning, calendar: utc)
        XCTAssertEqual(schedules.schedules[0].lastRunAt, atTen)
        XCTAssertEqual(schedules.schedules[0].lastResult, .missed)

        // Turned off, it is never due; a change of its time plans it anew; busy, it waits.
        var off = schedules.schedules[0]
        off.isEnabled = false
        off.nextRunAt = morning
        schedules.put(off, at: morning, calendar: utc)
        XCTAssertTrue(schedules.due(at: nextMorning.addingTimeInterval(86_400)).run.isEmpty)
        off.isEnabled = true
        off.when = .every(hours: 2)
        schedules.put(off, at: morning, calendar: utc)
        XCTAssertEqual(schedules.schedules[0].nextRunAt, morning.addingTimeInterval(2 * 3600))
        schedules.postpone(run.id, until: morning.addingTimeInterval(600))
        XCTAssertEqual(schedules.schedules[0].nextRunAt, morning.addingTimeInterval(600))

        // Its scenario deleted, or its profile: the schedule goes with it.
        XCTAssertFalse(schedules.keep(profiles: [profile], scenarios: [scenario]))
        XCTAssertTrue(schedules.keep(profiles: [profile], scenarios: []))
        XCTAssertTrue(schedules.schedules.isEmpty)
    }

    func testTheFileIsItsOwnAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-schedules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try MasterVault.create(in: root, password: "pw", iterations: 1_000)
        XCTAssertEqual(try ScenarioSchedules.load(from: vault), ScenarioSchedules())
        var schedules = ScenarioSchedules()
        schedules.put(daily(10, 0, jitter: 20), at: morning, calendar: utc)
        schedules.put(ScenarioSchedule(action: .scenario(UUID()), profileID: profile, when: .every(hours: 12)), at: morning, calendar: utc)
        try schedules.save(to: vault)
        XCTAssertEqual(try ScenarioSchedules.load(from: vault), schedules)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("scenario-schedules.bin").path))
        XCTAssertEqual(try ScenarioLibrary.load(from: vault), ScenarioLibrary(), "the scenarios' own file is not touched")
    }
}
