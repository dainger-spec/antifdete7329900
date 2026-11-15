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
    /// The profiles whose saved schedule could not be read (R1b): repeating is off for them, the
    /// warm-up screen says so, and the file is moved aside when a schedule is set, never written
    /// over.
    @Published private(set) var unreadableSchedules: Set<UUID> = []

    /// Launches the profile without a window if it is stopped and starts `plan` in it; false when
    /// that did not happen (the user was told why). In the app this is `AppModel.startWarmUp`,
    /// which also keeps the plan as the profile's last one.
    typealias Start = @MainActor (WarmUpPlan, UUID) async -> Bool

    /// How long a profile started only for its run is given to stop and seal again before the next
    /// run starts anyway (it may have been given a window meanwhile, which keeps it running).
    static var sealWait: TimeInterval = 60
    /// How often the schedule is looked at.
    static var tickInterval: TimeInterval = 60
    /// How many profiles the queue warms at once: the person's number (1–8), or — not set, the
    /// default — what this Mac's memory and processors allow (`WarmUpConcurrency.automatic`). Each
    /// runs in its own profile process.
    static let concurrencyKey = "warmup.concurrency"
    static let concurrencyRange: ClosedRange<Int> = WarmUpConcurrency.range
    /// The person's own number; nil: automatic.
    static var concurrencySetting: Int? {
        get {
            guard let stored = UserDefaults.standard.object(forKey: concurrencyKey) as? Int, stored > 0 else { return nil }
            return min(max(stored, concurrencyRange.lowerBound), concurrencyRange.upperBound)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(min(max(newValue, concurrencyRange.lowerBound), concurrencyRange.upperBound), forKey: concurrencyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: concurrencyKey)
            }
        }
    }
    static var automaticConcurrency: Int {
        WarmUpConcurrency.automatic(memoryBytes: ProcessInfo.processInfo.physicalMemory, processors: ProcessInfo.processInfo.activeProcessorCount)
    }
    static var concurrency: Int {
        get { concurrencySetting ?? automaticConcurrency }
        set { concurrencySetting = newValue }
    }
    /// Profiles of one queue do not all begin in the same second: each starts this long after the
    /// one before (seconds, drawn anew). Nil: at once (the self-test).
    static var stagger: ClosedRange<TimeInterval>? = 4...15

    /// What every warm-up's tab leaves out to spare the proxies' traffic (the person's setting on
    /// the warm-up screen; nil: nothing). Put into each plan as it starts (`AppModel.startWarmUp`),
    /// whoever starts it — the screen, a queue, the schedule.
    static let trafficSavingKey = "warmup.trafficSaving"
    static var trafficSaving: WarmUpTrafficSaving? {
        get { (UserDefaults.standard.string(forKey: trafficSavingKey)).flatMap(WarmUpTrafficSaving.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: trafficSavingKey) }
    }

    private let manager: ProfileManager
    private let repository: ProfileRepository
    private let start: Start
    /// The queue's runs going on, by entry: as many as `concurrency` at once.
    private var runners: [Int: Task<Void, Never>] = [:]
    private var ticker: Task<Void, Never>?
    /// Profiles whose warm-up was last seen running: one that is seen not running any more has
    /// ended a run, wherever it was started from.
    private var seenRunning: Set<UUID> = []
    private var isShutDown = false
    private var forwarding: AnyCancellable?
    /// A run ended and its record was stored (`WarmUpRecord`): the inspector reads it again.
    var onRecorded: ((UUID) -> Void)?
    /// The person's own lists, for a plan built from one (`AppModel` reads the vault's).
    var userTemplates: () -> [WarmUpTemplate] = { [] }
    /// Each profile's warm-ups, the newest first, read once and kept up as runs end: what the
    /// Warm-up section lists (`WarmUpHistory`).
    @Published private(set) var histories: [UUID: WarmUpHistory] = [:]
    /// When the queue last started a profile (`stagger`).
    private var lastStart: Date?
    /// When each run seen running was first seen, for a robot that does not say when it began.
    private var firstSeen: [UUID: Date] = [:]
    /// Profiles whose running warm-up the schedule started.
    private var scheduledRuns: Set<UUID> = []
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WarmUpQueue")

    init(manager: ProfileManager, repository: ProfileRepository, start: @escaping Start) {
        self.manager = manager
        self.repository = repository
        self.start = start
        var schedules: [UUID: WarmUpSchedule] = [:]
        var unreadable: Set<UUID> = []
        for profile in repository.list() {
            do {
                if let schedule = try repository.warmUpSchedule(for: profile.id) { schedules[profile.id] = schedule }
            } catch {
                log.error("Could not read the warm-up schedule of \(profile.id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                if case CoreError.newerFormat = error { continue }
                unreadable.insert(profile.id)
            }
        }
        unreadableSchedules = unreadable
        scheduler = WarmUpScheduler(schedules: schedules)
        var read: [UUID: WarmUpHistory] = [:]
        for profile in repository.list() {
            if let history = try? repository.warmUpHistory(for: profile.id), !history.runs.isEmpty { read[profile.id] = history }
        }
        histories = read
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
        for runner in runners.values { runner.cancel() }
        runners = [:]
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

    /// Holds the queue: the runs going on finish, nothing waiting starts; or lets it go on.
    func setPaused(_ paused: Bool) {
        queue.isPaused = paused
        if !paused { pump() }
    }

    /// Takes one waiting profile off the queue.
    func cancel(_ profileID: UUID) {
        guard let entry = queue.waiting.first(where: { $0.profileID == profileID }), let taken = queue.cancel(entry.id) else { return }
        if taken.source == .schedule, let schedule = scheduler.recordAttempt(profileID, at: Date()) { save(schedule, for: profileID) }
    }

    /// Makes a waiting profile the next to start.
    func startNext(_ profileID: UUID) {
        guard let entry = queue.waiting.first(where: { $0.profileID == profileID }) else { return }
        queue.moveToFront(entry.id)
    }

    /// The profile's warm-up state, from its history — or, without one yet, from the short record
    /// an older version kept.
    func warmth(of id: UUID) -> WarmUpWarmth {
        if let runs = histories[id]?.runs, let last = runs.first {
            return WarmUpWarmth(last: last, previous: runs.dropFirst().first)
        }
        return WarmUpWarmth(record: try? repository.warmUpRecord(for: id))
    }

    /// The profile's last run, when its history has one.
    func lastRun(of id: UUID) -> WarmUpRun? { histories[id]?.last }

    /// Takes the rest off the queue and stops the run going on (its profile, started for it alone,
    /// then stops and seals as after any run).
    func stopAll() {
        cancelWaiting()
        for entry in queue.running { manager.stopWarmUp(entry.profileID) }
    }

    /// Starts waiting entries while fewer than `concurrency` of the queue run.
    private func pump() {
        while !isShutDown, let entry = queue.startNext(limit: Self.concurrency) {
            runners[entry.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.run(entry)
                self.queue.finish(entry.id, as: outcome)
                self.runners[entry.id] = nil
                self.pump()
            }
        }
    }

    /// One turn of the queue: waits for any other warm-up to end, starts the run (launching the
    /// profile without a window if it is stopped), follows it to its end, and waits for a profile
    /// started for it to stop and seal again.
    private func run(_ entry: WarmUpQueue.Entry) async -> WarmUpQueue.Entry.State {
        let id = entry.profileID
        let scheduled = entry.source == .schedule
        // No more at once than the setting, runs started from the warm-up screen included.
        while runningWarmUps(besides: id) >= Self.concurrency {
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
        // Not in the same second as the profile before it.
        if let stagger = Self.stagger, let lastStart {
            let wait = lastStart.addingTimeInterval(Double.random(in: stagger)).timeIntervalSinceNow
            if wait > 0 { guard await pause(wait) else { return .cancelled } }
        }
        lastStart = Date()
        if scheduled { scheduledRuns.insert(id) }
        let begun = Date()
        let started = await start(plan, id)
        guard !Task.isCancelled, !isShutDown else { return .cancelled }
        guard started else {
            // Said in the profile's history, where it is seen among the others — not in an alert each.
            scheduledRuns.remove(id)
            keep(WarmUpRun(startedAt: begun, endedAt: Date(), result: .notStarted, scheduled: scheduled, templates: plan.choice?.templateIDs ?? [],
                           templateNames: names(of: plan), intensity: plan.choice?.source == .templates ? plan.choice?.intensity : nil,
                           countryCode: countryCode(of: id)), for: id)
            return .skipped(.notStarted)
        }
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

    /// How many profiles other than `id` run a warm-up now.
    private func runningWarmUps(besides id: UUID) -> Int {
        repository.list().filter { $0.id != id && manager.warmUpStatus(of: $0.id)?.isRunning == true }.count
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
            if let rebuilt = choice.plan(countryCode: country, composedName: L("warmup.source.composed"), templates: userTemplates()) { return rebuilt }
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
        unreadableSchedules.remove(id)
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
    /// visited pages, it is the profile's last run, for its schedule and for the inspector
    /// (`WarmUpRecord`).
    private func warmUpProgressed(_ id: UUID) {
        guard let status = manager.warmUpStatus(of: id) else { return }
        if status.isRunning {
            if seenRunning.insert(id).inserted { firstSeen[id] = Date() }
            return
        }
        guard seenRunning.remove(id) != nil else {
            // The report of a run stopped part-way comes a moment after its end: the run kept then
            // gets its sites and cookies.
            amendLastRun(with: status, for: id)
            return
        }
        let ended = Date()
        let plan = try? repository.warmUpPlan(for: id)
        if let run = WarmUpRun(status, plan: plan, startedAt: firstSeen[id] ?? ended, endedAt: ended, scheduled: scheduledRuns.contains(id),
                               countryCode: countryCode(of: id), templateNames: plan.map(names(of:)) ?? [:]) {
            keep(run, for: id)
        }
        firstSeen[id] = nil
        scheduledRuns.remove(id)
        if let record = WarmUpRecord(status, at: ended) {
            do {
                try repository.saveWarmUpRecord(record, for: id)
            } catch {
                log.error("Could not store the last warm-up of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            }
            if let schedule = scheduler.recordRun(id, at: record.endedAt) {
                save(schedule, for: id)
            }
            onRecorded?(id)
        }
    }

    /// Queues the profiles whose turn ended without a warm-up (not started, the proxy silent)
    /// again, each with the plan `plan(id)` gives.
    func retryFailed(plan: (UUID) -> WarmUpPlan) {
        enqueue(queue.failedProfiles, plan: plan)
    }

    /// Adds a run to the profile's history, in the vault and here.
    private func keep(_ run: WarmUpRun, for id: UUID) {
        do {
            try repository.addWarmUpRun(run, for: id)
        } catch {
            log.error("Could not store a warm-up of \(id.uuidString, privacy: .public) in its history: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        var history = histories[id] ?? WarmUpHistory()
        history.add(run)
        histories[id] = history
    }

    /// A run's last report came after the run was kept (stopped part-way: its cookies are counted a
    /// moment later): the kept run takes its rows and counts.
    private func amendLastRun(with status: WarmUpStatus, for id: UUID) {
        guard var history = histories[id], let last = history.runs.first, Date().timeIntervalSince(last.endedAt) < 30,
              status.sites != nil, last.sites.allSatisfy({ $0.cookies == 0 }),
              let plan = try? repository.warmUpPlan(for: id),
              var amended = WarmUpRun(status, plan: plan, startedAt: last.startedAt, endedAt: last.endedAt, scheduled: last.scheduled,
                                      countryCode: last.countryCode, templateNames: last.templateNames),
              amended.cookies > 0 else { return }
        amended.id = last.id
        history.runs[0] = amended
        histories[id] = history
        if var stored = try? repository.warmUpHistory(for: id), stored.runs.first?.id == last.id {
            stored.runs[0] = amended
            try? repository.replaceWarmUpHistory(stored, for: id)
        }
    }

    /// The country the profile's proxy last exited in.
    private func countryCode(of id: UUID) -> String? {
        (try? repository.loadConfiguration(id))?.rememberedProxyLocation?.countryCode
    }

    /// The names of the person's lists a plan was made of, as they are now.
    private func names(of plan: WarmUpPlan) -> [String: String] {
        let ids = plan.choice?.templateIDs.filter { $0.hasPrefix("user:") } ?? []
        guard !ids.isEmpty else { return [:] }
        var names: [String: String] = [:]
        for template in userTemplates() where ids.contains(template.presetID) { names[template.presetID] = template.name }
        return names
    }

    private func save(_ schedule: WarmUpSchedule, for id: UUID) {
        do {
            try repository.saveWarmUpSchedule(schedule, for: id)
        } catch {
            log.error("Could not store the warm-up schedule of \(id.uuidString, privacy: .public): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }
}
