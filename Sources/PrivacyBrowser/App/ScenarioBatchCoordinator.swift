import BrowserCore
import Foundation
import os

/// A scenario run on many profiles (docs/AUTOMATION.md, "On many profiles"): starts the runs — so
/// many at once, a pause between starts — through the app's own `runScenario`, watches each to
/// its end, and keeps what happened (`ScenarioRunHistory`, sealed in the vault). The bookkeeping
/// is BrowserCore's `ScenarioBatch`; this is what looks at the clock and at the profiles.
///
/// A profile the run started is stopped again when its scenario has ended, if the run was asked
/// to. Nothing of a profile's values is kept with a run: only how it ended, what the scenario
/// returned, and the last lines of the log of one that failed.
@MainActor
final class ScenarioBatchCoordinator: ObservableObject {
    static var tickInterval: TimeInterval = 0.5

    /// The runs, newest first; one still going is among them.
    @Published private(set) var history = ScenarioRunHistory()
    /// `scenario-runs.bin` is a newer version's or does not open: nothing is kept this time.
    @Published private(set) var isRefused = false

    private weak var model: AppModel?
    private var vault: UnlockedVault?
    /// The scenario a run going on is of, as it was when the run began.
    private var scenarios: [UUID: Scenario] = [:]
    /// The engine's run of each profile of a run going on.
    private var runIDs: [UUID: [UUID: UUID]] = [:]
    /// Profiles whose start has been asked for and not answered yet.
    private var starting: [UUID: Set<UUID>] = [:]
    private var nextStart: [UUID: Date] = [:]
    /// The log of each profile's run, while the app runs: a run's table opens it.
    private var logs: [UUID: [UUID: [ScenarioRunner.Line]]] = [:]
    private var ticker: Task<Void, Never>?
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "Scenario")

    init(model: AppModel) {
        self.model = model
    }

    // MARK: The vault

    func load(from vault: UnlockedVault) {
        self.vault = vault
        do {
            var loaded = try ScenarioRunHistory.load(from: vault)
            // A run the app did not see the end of: it quit, or the vault was locked, meanwhile.
            loaded.closeUnfinished()
            history = loaded
            isRefused = false
        } catch {
            Self.log.error("scenario-runs.bin could not be read: \(error.logKind, privacy: .public); kept as it is")
            history = ScenarioRunHistory()
            isRefused = true
        }
    }

    /// The vault is locked: what is going is stopped, and nothing is held.
    func reset() {
        ticker?.cancel()
        ticker = nil
        vault = nil
        history = ScenarioRunHistory()
        isRefused = false
        scenarios = [:]
        runIDs = [:]
        starting = [:]
        nextStart = [:]
        logs = [:]
    }

    private func save() {
        guard let vault, !isRefused else { return }
        do {
            try history.save(to: vault)
        } catch {
            Self.log.error("scenario-runs.bin could not be written: \(error.logKind, privacy: .public)")
        }
    }

    // MARK: A run

    /// Starts `scenario` on `profiles` (in this order). `skipped`: profiles that are not run, each
    /// with why (it has no text for a value the scenario reads). The run's id.
    @discardableResult
    func start(_ scenario: Scenario, on profiles: [(id: UUID, name: String)], skipped: [UUID: String] = [:], limit: Int = ScenarioBatch.defaultLimit,
               pause: ClosedRange<Double>? = nil, stopsProfiles: Bool = true, origin: ScenarioBatch.Origin = .manual) -> UUID {
        var entries = profiles.map { ScenarioBatch.Entry(profileID: $0.id, name: $0.name) }
        let now = Date()
        for index in entries.indices {
            if let reason = skipped[entries[index].profileID] {
                entries[index].state = .skipped(reason: reason)
                entries[index].endedAt = now
            }
        }
        let batch = ScenarioBatch(scenarioID: scenario.id, scenarioName: scenario.name, entries: entries, startedAt: now, origin: origin,
                                  limit: limit, pause: pause, stopsProfiles: stopsProfiles)
        scenarios[batch.id] = scenario
        history.put(batch)
        // All skipped: the run has nothing to do, and is over.
        if entries.allSatisfy(\.state.hasEnded) { update(batch.id) { $0.stop(at: now); $0.endedAt = $0.endedAt ?? now } }
        save()
        wake()
        return batch.id
    }

    /// The profiles of `run` whose scenario failed or was stopped, run again as a run of its own.
    @discardableResult
    func runFailedAgain(of run: UUID) -> UUID? {
        guard let batch = history.runs.first(where: { $0.id == run }), let model,
              let scenario = model.scenarios.scenario(batch.scenarioID) else { return nil }
        let again = Set(batch.unsuccessful)
        let profiles = batch.entries.filter { again.contains($0.profileID) }.compactMap { entry in
            model.profiles.first { $0.id == entry.profileID }.map { (id: $0.id, name: $0.name) }
        }
        guard !profiles.isEmpty else { return nil }
        return start(scenario, on: profiles, limit: batch.limit, pause: batch.pause, stopsProfiles: batch.stopsProfiles, origin: batch.origin)
    }

    func stop(_ run: UUID) {
        guard let batch = history.runs.first(where: { $0.id == run }), batch.isRunning else { return }
        update(run) { $0.stop() }
        for entry in batch.entries {
            if case .running = entry.state { model?.stopScenario(on: entry.profileID) }
        }
        save()
        wake()
    }

    /// The log of `profile`'s run in `run`: the lines seen while the app runs.
    func lines(of profile: UUID, in run: UUID) -> [ScenarioRunner.Line] { logs[run]?[profile] ?? [] }

    func run(_ id: UUID) -> ScenarioBatch? { history.runs.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout ScenarioBatch) -> Void) {
        guard var batch = history.runs.first(where: { $0.id == id }) else { return }
        change(&batch)
        history.put(batch)
    }

    // MARK: The clock

    private func wake() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.tick() else { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
            self?.ticker = nil
        }
    }

    /// Looks at every run going on; false when none is.
    private func tick() -> Bool {
        guard let model else { return false }
        let going = history.runs.filter(\.isRunning)
        for batch in going {
            var changed = false
            // Those at work: has its scenario ended?
            for entry in batch.entries {
                guard case .running = entry.state, starting[batch.id]?.contains(entry.profileID) != true else { continue }
                let state = model.scenarioRun(of: entry.profileID)
                guard let state, state.runID == runIDs[batch.id]?[entry.profileID] else {
                    // The run is not the profile's any more (another took its place), or was never made.
                    update(batch.id) { $0.ended(entry.profileID, .failed(reason: L("scenarios.run.lost"), line: nil)) }
                    changed = true
                    continue
                }
                logs[batch.id, default: [:]][entry.profileID] = state.lines
                guard let outcome = state.outcome else { continue }
                let kept = state.lines.suffix(ScenarioBatch.keptLogLines).map { line in
                    String(format: "%7.1f  ", max(0, line.at.timeIntervalSince(state.startedAt))) + line.text
                }
                let end: ScenarioBatch.State
                switch outcome {
                case .finished: end = .finished
                case .failed(let reason): end = .failed(reason: reason, line: Self.line(in: reason))
                case .stopped: end = .stopped
                }
                update(batch.id) { $0.ended(entry.profileID, end, result: state.result, log: kept) }
                changed = true
                if batch.stopsProfiles, entry.startedProfile == true {
                    Task { @MainActor [weak model] in await model?.stop(entry.profileID) }
                }
            }
            // The next to start: one at a time, the pause between them.
            if let current = run(batch.id), let profile = current.next().first, (nextStart[batch.id] ?? .distantPast) <= Date(),
               let scenario = scenarios[batch.id] {
                let runID = UUID()
                let wasRunning = model.isRunning(profile)
                runIDs[batch.id, default: [:]][profile] = runID
                starting[batch.id, default: []].insert(profile)
                update(batch.id) { $0.began(profile, startedProfile: !wasRunning) }
                if let pause = batch.pause { nextStart[batch.id] = Date().addingTimeInterval(Double.random(in: pause)) }
                changed = true
                Task { @MainActor [weak self, weak model] in
                    let started = await model?.runScenario(scenario, on: profile, runID: runID) ?? false
                    guard let self else { return }
                    self.starting[batch.id]?.remove(profile)
                    if !started {
                        self.update(batch.id) { $0.ended(profile, .skipped(reason: L("scenarios.run.notStarted"))) }
                        self.save()
                    }
                }
            }
            if changed { save() }
        }
        // What a run that has ended needed is let go; its log stays for its table.
        for batch in going where run(batch.id)?.isRunning == false {
            scenarios[batch.id] = nil
            runIDs[batch.id] = nil
            starting[batch.id] = nil
            nextStart[batch.id] = nil
        }
        return history.runs.contains(where: \.isRunning)
    }

    /// The scenario's line an error names ("… (line 12)").
    static func line(in reason: String) -> Int? {
        guard let open = reason.range(of: "(line ", options: .backwards), let close = reason[open.upperBound...].firstIndex(of: ")") else { return nil }
        return Int(reason[open.upperBound..<close])
    }
}
