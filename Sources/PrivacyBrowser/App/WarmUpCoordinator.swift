import BrowserCore
import Combine
import Foundation
import os

/// The warm-up queue and the warm-up schedule of one unlock.
///
/// The queue: several profiles warmed up one after the other with one plan. Each is started
/// without a window when it is stopped — as a warm-up from the sheet is — and stopped and sealed
/// again once its run is over (the manager does that for a profile that has no window: see
/// `ProfileManager.warmUpRobot(for:)` and `ProfileSessionHost`); only then does the next begin.
/// A profile the user already has open is warmed up where it runs and left running.
///
/// The schedule: "every N hours" per profile (`WarmUpSchedule`, encrypted beside the plan). A
/// timer looks once a minute while the app is unlocked and puts the runs that are due into the
/// same queue, so a scheduled run never runs beside another. A profile that is running when its
/// run comes up is the user's — its windows are open — and is left alone: the run is put off and
/// tried again a little later (`WarmUpScheduler.retryDelay`).
///
/// What is due and who is next is decided in BrowserCore (`WarmUpScheduler`, `WarmUpQueue`), where
/// it is tested; this does the launching and the waiting. It lives as long as the unlock: Lock
/// takes everything off the queue and stops the timer before the profiles are stopped and sealed.
@MainActor
final class WarmUpCoordinator: ObservableObject {
    @Published private(set) var queue = WarmUpQueue()
    @Published private(set) var scheduler = WarmUpScheduler()

    /// Launches the profile without a window if it is stopped and starts `plan` in it; false when
    /// that did not happen (the user was told why). In the app this is `AppModel.startWarmUp`,
    /// which also keeps the plan as the profile's last one.
    typealias Start = @MainActor (WarmUpPlan, UUID) async -> Bool

    /// How long a profile started only for its run is given to stop and seal again before the next
    /// run starts anyway (it may have been given a window meanwhile, which keeps it running).
    static var sealWait: TimeInterval = 60
    /// How often the schedule is looked at.
    static var tickInterval: TimeInterval = 60

    private let manager: ProfileManager
    private let repository: ProfileRepository
    private let start: Start
    private var runner: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// Profiles whose warm-up was last seen running: one that is seen not running any more has
    /// ended a run, wherever it was started from.
    private var seenRunning: Set<UUID> = []
    private var isShutDown = false
    private var forwarding: AnyCancellable?
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WarmUpQueue")

    init(manager: ProfileManager, repository: ProfileRepository, start: @escaping Start) {
        self.manager = manager
        self.repository = repository
        self.start = start
        var schedules: [UUID: WarmUpSchedule] = [:]
        for profile in repository.list() {
            do {
                if let schedule = try repository.warmUpSchedule(for: profile.id) { schedules[profile.id] = schedule }
            } catch {
                log.error("Could not read the warm-up schedule of \(profile.id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            }
        }
        scheduler = WarmUpScheduler(schedules: schedules)
        // Every run that ends counts for the schedule — one from the warm-up screen too: a profile
        // warmed an hour ago by hand is not due again because its timer says so.
        let previous = manager.onWarmUpProgress
        manager.onWarmUpProgress = { [weak self] id in
            previous?(id)
            self?.warmUpProgressed(id)
        }
    }

    /// Makes `model` tell its views when the queue or a schedule changes (the profile list shows
    /// who is waiting).
    func forwardChanges(to model: AppModel) {
        forwarding = objectWillChange.sink { [weak model] _ in model?.objectWillChange.send() }
    }

    /// Starts the timer that looks at the schedule: now, then every `tickInterval`.
    func begin() {
        guard ticker == nil, !isShutDown else { return }
        let interval = Self.tickInterval
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if self == nil { return }
            }
        }
    }

    /// Lock: nothing more starts, what waits is taken off, the timer stops. The run going on is
    /// left to the manager, which stops it with its profile.
    func shutDown() {
        isShutDown = true
        ticker?.cancel()
        ticker = nil
        runner?.cancel()
        runner = nil
        queue.cancelAll()
        forwarding = nil
    }

    // MARK: The queue

    /// Puts `profiles` at the end of the queue, in that order, each with the plan `plan(id)` gives
    /// for it (a list composed for the profile's own country is built per profile). A profile
    /// already waiting keeps its place and its plan.
    func enqueue(_ profiles: [UUID], plan: (UUID) -> WarmUpPlan) {
        guard !isShutDown else { return }
        for id in profiles where !queue.isQueued(id) {
            queue.add(id, plan: plan(id), source: .user)
        }
        log.notice("Warm-up queue: \(profiles.count, privacy: .public) profiles added, \(self.queue.waiting.count, privacy: .public) waiting")
        pump()
    }

    /// The profile waits in the queue for its turn (not the one running).
    func isWaiting(_ id: UUID) -> Bool {
        queue.waiting.contains { $0.profileID == id }
    }

    /// Takes the profiles still waiting off the queue; the run going on goes on. A scheduled run
    /// taken off counts as tried: it comes again after its interval, not a minute later.
    func cancelWaiting() {
        let now = Date()
        for entry in queue.cancelWaiting() where entry.source == .schedule {
            if let schedule = scheduler.recordAttempt(entry.profileID, at: now) { save(schedule, for: entry.profileID) }
        }
    }

    /// Takes the rest off the queue and stops the run going on (its profile, started for it alone,
    /// then stops and seals as after any run).
    func stopAll() {
        cancelWaiting()
        if let current = queue.current { manager.stopWarmUp(current.profileID) }
    }

    /// Starts the next waiting entry when nothing of the queue runs.
    private func pump() {
        guard runner == nil, !isShutDown, let entry = queue.startNext() else { return }
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.run(entry)
            self.queue.finish(entry.id, as: outcome)
            self.runner = nil
            self.pump()
        }
    }

    /// One turn of the queue: waits for any other warm-up to end, starts the run (launching the
    /// profile without a window if it is stopped), follows it to its end, and waits for a profile
    /// started for it to stop and seal again.
    private func run(_ entry: WarmUpQueue.Entry) async -> WarmUpQueue.Entry.State {
        let id = entry.profileID
        let scheduled = entry.source == .schedule
        // One at a time, a run started from the warm-up screen included.
        while isAnyWarmUpRunning {
            guard await pause(1) else { return .cancelled }
        }
        guard repository.list().contains(where: { $0.id == id }) else { return .skipped(.profileGone) }
        // Repeating was turned off while the run waited.
        if scheduled, scheduler.schedules[id]?.isEnabled != true { return .cancelled }
        let wasRunning = manager.isRunning(id) || manager.busyProfileIDs.contains(id)
        if scheduled, wasRunning {
            // Running means in use: the user's windows are open. Not under their hands — later.
            scheduler.postpone(id, at: Date())
            log.notice("Scheduled warm-up of \(id.uuidString, privacy: .public) put off: the profile is in use")
            return .skipped(.inUse)
        }
        if scheduled, let schedule = scheduler.recordAttempt(id, at: Date()) { save(schedule, for: id) }
        guard let plan = entry.plan ?? savedPlan(for: id), !plan.pages().pages.isEmpty else { return .skipped(.noPlan) }
        let started = await start(plan, id)
        guard !Task.isCancelled, !isShutDown else { return .cancelled }
        guard started else { return .skipped(.notStarted) }
        var last = manager.warmUpStatus(of: id)
        while let status = manager.warmUpStatus(of: id), status.isRunning {
            last = status
            guard await pause(0.5) else { return .cancelled }
        }
        if !wasRunning {
            // Started for this run alone, it stops and seals by itself now; the next profile waits
            // for that, unless it was given a window meanwhile (it then stays, the user's).
            let deadline = Date().addingTimeInterval(Self.sealWait)
            while manager.isRunning(id) || manager.busyProfileIDs.contains(id), Date() < deadline {
                if manager.session(for: id)?.hasVisibleWindow == true { break }
                guard await pause(0.5) else { return .cancelled }
            }
        }
        // Read again: a run stopped part-way reports its sites a moment after it ends.
        return .done(manager.warmUpStatus(of: id) ?? last)
    }

    /// A warm-up runs in some profile.
    private var isAnyWarmUpRunning: Bool {
        repository.list().contains { manager.warmUpStatus(of: $0.id)?.isRunning == true }
    }

    /// Sleeps; false when the coordinator is going (Lock) and the caller should give up.
    private func pause(_ seconds: TimeInterval) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled && !isShutDown
    }

    /// The plan a scheduled run uses: the profile's saved one. A ready-made or composed choice is
    /// built again, as the warm-up screen builds it — the list cut and shuffled anew, for the
    /// country the profile's proxy exits in now; a list written by hand runs as it was written.
    private func savedPlan(for id: UUID) -> WarmUpPlan? {
        guard let saved = try? repository.warmUpPlan(for: id) else { return nil }
        if let choice = saved.choice, choice.source != .manual {
            let country = (try? repository.loadConfiguration(id))?.rememberedProxyLocation?.countryCode
            if let rebuilt = choice.plan(countryCode: country, composedName: L("warmup.source.composed")) { return rebuilt }
        }
        return saved
    }

    // MARK: The schedule

    /// The profile's schedule, on or off; nil when none was ever set.
    func schedule(for id: UUID) -> WarmUpSchedule? { scheduler.schedules[id] }

    /// When the profile's next scheduled run is to start; nil when it does not repeat.
    func nextRun(of id: UUID) -> Date? { scheduler.nextRun(of: id, now: Date()) }

    /// Turns repeating on or off for the profile, or changes how often, and keeps `plan` as the
    /// plan it repeats — the one the warm-up screen shows. Turned on, the first run is one
    /// interval from now.
    func setSchedule(enabled: Bool, everyHours: Int, plan: WarmUpPlan, for id: UUID) throws {
        try repository.saveWarmUpPlan(plan, for: id)
        var schedule = scheduler.schedules[id] ?? WarmUpSchedule(isEnabled: false, everyHours: everyHours)
        if enabled, !schedule.isEnabled { schedule.since = Date() }
        schedule.isEnabled = enabled
        schedule.everyHours = min(max(everyHours, WarmUpSchedule.hourRange.lowerBound), WarmUpSchedule.hourRange.upperBound)
        try repository.saveWarmUpSchedule(schedule, for: id)
        scheduler.set(schedule, for: id)
        log.notice("Warm-up schedule of \(id.uuidString, privacy: .public): \(enabled ? schedule.everyHours : 0, privacy: .public) h (0: off)")
    }

    /// Puts the runs the schedule finds due into the queue, and starts the next when nothing of
    /// the queue runs. Called by the timer.
    func tick() {
        guard !isShutDown else { return }
        let now = Date()
        var scheduler = self.scheduler
        scheduler.keep(only: Set(repository.list().map(\.id)))
        for id in scheduler.due(at: now) where !queue.isQueued(id) {
            // Running: its windows are the user's (or another run has it). Tried again later.
            if manager.isRunning(id) || manager.busyProfileIDs.contains(id) {
                scheduler.postpone(id, at: now)
                continue
            }
            queue.add(id, plan: nil, source: .schedule)
            log.notice("Scheduled warm-up of \(id.uuidString, privacy: .public) is due")
        }
        if scheduler != self.scheduler { self.scheduler = scheduler }
        pump()
    }

    /// A warm-up moved on somewhere. A run seen running before and over now has ended: when it
    /// visited pages, it is the profile's last run as far as its schedule goes.
    private func warmUpProgressed(_ id: UUID) {
        guard let status = manager.warmUpStatus(of: id) else { return }
        if status.isRunning {
            seenRunning.insert(id)
        } else if seenRunning.remove(id) != nil, status.visited > 0,
                  let schedule = scheduler.recordRun(id, at: Date()) {
            save(schedule, for: id)
        }
    }

    private func save(_ schedule: WarmUpSchedule, for id: UUID) {
        do {
            try repository.saveWarmUpSchedule(schedule, for: id)
        } catch {
            log.error("Could not store the warm-up schedule of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }
}
