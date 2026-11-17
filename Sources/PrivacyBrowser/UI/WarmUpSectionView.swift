import BrowserCore
import SwiftUI

/// The Warm-up section with the app's own data: the profiles, each with the state its warm-ups
/// left it in (`WarmUpCoordinator`: the queue, the histories, the schedules) or the run going on
/// (`ProfileManager.warmUpStatus`), and what the section's buttons do.
struct WarmUpSectionView: View {
    /// "New warm-up" opened from elsewhere (the Profiles list's selection, a profile's menu): the
    /// profiles to tick. Taken once and cleared.
    @Binding var request: WarmUpNewRequest?
    var openProxies: () -> Void = {}
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let manager = model.manager, let warmUps = model.warmUps {
            WarmUpSectionContent(manager: manager, warmUps: warmUps, request: $request, openProxies: openProxies)
        }
    }
}

private struct WarmUpSectionContent: View {
    @ObservedObject var manager: ProfileManager
    @ObservedObject var warmUps: WarmUpCoordinator
    @Binding var request: WarmUpNewRequest?
    let openProxies: () -> Void
    @EnvironmentObject private var model: AppModel
    /// The person's lists, read when the section opens and after each change of them.
    @State private var templates: [WarmUpTemplate] = []
    @State private var loaded = false

    var body: some View {
        WarmUpScreen(profiles: items, queue: queueSummary, templates: templates, actions: actions, incoming: $request)
            .environment(\.tagColors, model.tagColors)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                templates = model.warmUpTemplates()
            }
    }

    private var items: [WarmUpProfileItem] {
        let nextWaiting = warmUps.queue.waiting.first?.profileID
        return model.profiles.map { profile in
            let details = model.details[profile.id]
            let history = warmUps.histories[profile.id]?.runs ?? []
            let state: WarmUpProfileItem.State
            if let status = manager.warmUpStatus(of: profile.id), status.isRunning {
                state = .running(status)
            } else if warmUps.isWaiting(profile.id) {
                state = .waiting(next: profile.id == nextWaiting)
            } else {
                switch warmUps.warmth(of: profile.id) {
                case .never: state = .never
                case .warmed(let date): state = .warmed(history.first, date)
                case .partly(let date): state = history.first.map { WarmUpProfileItem.State.partly($0) } ?? .warmed(nil, date)
                case .attention(let date): state = history.first.map { WarmUpProfileItem.State.attention($0) } ?? .warmed(nil, date)
                }
            }
            let schedule = warmUps.schedule(for: profile.id)
            return WarmUpProfileItem(id: profile.id, name: profile.name, avatar: details?.avatar, tags: details?.tags ?? [],
                                     countryCode: details?.exitCountryCode, state: state, history: history,
                                     repeatHours: schedule?.isEnabled == true ? schedule?.everyHours : nil,
                                     nextRun: warmUps.nextRun(of: profile.id))
        }
    }

    /// The queue as the bar says it; nil when nothing of it runs or waits and none of it failed.
    private var queueSummary: WarmUpQueueSummary? {
        let queue = warmUps.queue
        let counted = queue.entries.filter { $0.state != .cancelled }
        let failed = queue.failedProfiles.count
        guard queue.isActive || failed > 0, !counted.isEmpty else { return nil }
        let done = counted.filter { !$0.isPending }.count
        var left: TimeInterval = 0
        for entry in queue.running { left += manager.warmUpStatus(of: entry.profileID)?.secondsRemaining ?? entry.plan?.estimatedSeconds ?? 0 }
        let atOnce = WarmUpCoordinator.concurrency
        left += queue.waiting.reduce(0) { $0 + ($1.plan?.estimatedSeconds ?? 1_200) } / Double(max(1, atOnce))
        return WarmUpQueueSummary(done: done, total: counted.count, paused: queue.isPaused, atOnce: atOnce,
                                  automatic: WarmUpCoordinator.concurrencySetting == nil,
                                  secondsLeft: queue.isActive ? left : nil, failed: queue.isActive ? 0 : failed)
    }

    private var actions: WarmUpActions {
        WarmUpActions(
            start: { ids, choice, repeatHours in
                model.warmUp(ids, with: choice)
                guard let repeatHours else { return }
                for id in ids {
                    guard let plan = choice.plan(countryCode: model.details[id]?.exitCountryCode, templates: templates) else { continue }
                    do {
                        try warmUps.setSchedule(enabled: true, everyHours: repeatHours, plan: plan, for: id)
                    } catch {
                        model.showError(model.named(errorText(error), for: id))
                        break
                    }
                }
            },
            stop: { model.stopWarmUp($0) },
            cancel: { warmUps.cancel($0) },
            startNext: { warmUps.startNext($0) },
            setPaused: { warmUps.setPaused($0) },
            stopAll: { warmUps.stopAll() },
            setConcurrency: { count in
                WarmUpCoordinator.concurrencySetting = count
                warmUps.settingsChanged()
            },
            retryFailed: { warmUps.retryFailed() },
            stopRepeating: { id in
                guard let schedule = warmUps.schedule(for: id) else { return }
                do {
                    try warmUps.setSchedule(enabled: false, everyHours: schedule.everyHours, plan: model.warmUpPlan(for: id).plan, for: id)
                } catch {
                    model.showError(model.named(errorText(error), for: id))
                }
            },
            saveTemplate: { template in
                let saved = model.saveWarmUpTemplate(template)
                if saved { templates = model.warmUpTemplates() }
                return saved
            },
            deleteTemplate: { id in
                model.deleteWarmUpTemplate(id)
                templates = model.warmUpTemplates()
            },
            checkProxy: { _ in openProxies() })
    }
}
