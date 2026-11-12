import BrowserCore
import Foundation
import os

/// Runs by the clock (`ScenarioSchedule`): once a minute, while the vault is open, the schedules
/// whose time has come are run — a scenario on its profile, or the profile's warm-up — and each
/// plans its next time. A profile that is busy is looked at again ten minutes on; a run found too
/// late is not made; without automation in the plan nothing is run, and the schedule says so.
///
/// Nothing wakes the Mac and nothing starts the app: a schedule is the app's own, while it runs.
@MainActor
final class ScenarioScheduleCoordinator {
    struct Actions {
        var allowsAutomation: () -> Bool
        var profiles: () -> Set<UUID>
        var scenario: (UUID) -> Scenario?
        var scenarios: () -> Set<UUID>
        /// The profile is starting, being sealed, or running a scenario already.
        var isBusy: (UUID) -> Bool
        var runScenario: (Scenario, UUID) async -> Bool
        /// Puts the profile's warm-up in the warm-up queue; false when there is no queue.
        var warmUp: (UUID) -> Bool
    }

    static var tickInterval: TimeInterval = 60
    static let retryDelay: TimeInterval = 600

    private(set) var schedules = ScenarioSchedules()
    /// The file is a newer version's, or does not open: shown as none, and nothing is written.
    private(set) var isRefused = false
    var onChange: ((ScenarioSchedules) -> Void)?
    private let vault: UnlockedVault
    private let actions: Actions
    private var loop: Task<Void, Never>?
    private var isShutDown = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "ScenarioSchedules")

    init(vault: UnlockedVault, actions: Actions) {
        self.vault = vault
        self.actions = actions
        do {
            schedules = try ScenarioSchedules.load(from: vault)
        } catch {
            isRefused = true
            log.error("scenario-schedules.bin could not be read: \(error.logKind, privacy: .public); kept as it is, nothing runs by the clock")
        }
    }

    func begin() {
        guard loop == nil, !isRefused else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isShutDown else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    /// At lock: nothing more is run.
    func shutDown() {
        isShutDown = true
        loop?.cancel()
        loop = nil
    }

    /// Adds or changes a schedule (or removes it). False when it could not be written.
    @discardableResult
    func save(_ schedule: ScenarioSchedule, remove: Bool = false) -> Bool {
        change { if remove { $0.remove(schedule.id) } else { $0.put(schedule) } }
    }

    @discardableResult
    private func change(_ body: (inout ScenarioSchedules) -> Void) -> Bool {
        guard !isRefused else { return false }
        var next = schedules
        body(&next)
        guard next != schedules else { return true }
        do {
            try next.save(to: vault)
            schedules = next
            // After a lock the app has put its copy away: a run that was starting then is written
            // down, and the app is not handed the schedules again.
            if !isShutDown { onChange?(next) }
            return true
        } catch {
            log.error("scenario-schedules.bin could not be written: \(error.logKind, privacy: .public)")
            return false
        }
    }

    /// One look at the clock.
    func tick(now: Date = Date()) async {
        guard !isShutDown, !isRefused else { return }
        // Schedules of profiles and scenarios deleted since go with them.
        change { $0.keep(profiles: actions.profiles(), scenarios: actions.scenarios()) }
        let due = schedules.due(at: now)
        for missed in due.missed {
            log.notice("A scheduled run was found too late and is not made")
            change { $0.record(missed.id, .missed, at: now) }
        }
        for schedule in due.run {
            guard !isShutDown else { return }
            // One removed, switched off or changed while an earlier one's profile was starting is
            // not run as it was: the next look at the clock takes it as it is now.
            guard schedules.schedules.contains(schedule) else { continue }
            guard actions.allowsAutomation() else {
                change { $0.record(schedule.id, .notInPlan, at: now) }
                continue
            }
            if actions.isBusy(schedule.profileID) {
                change { $0.postpone(schedule.id, until: now.addingTimeInterval(Self.retryDelay)) }
                continue
            }
            let started: Bool
            switch schedule.action {
            case let .scenario(id):
                if let scenario = actions.scenario(id) {
                    started = await actions.runScenario(scenario, schedule.profileID)
                } else {
                    started = false
                }
            case .warmUp:
                started = actions.warmUp(schedule.profileID)
            }
            if started { log.notice("A scheduled run started") } else { log.notice("A scheduled run did not start") }
            change { $0.record(schedule.id, started ? .started : .failed, at: Date()) }
        }
    }
}
