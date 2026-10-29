import BrowserCore
import SwiftUI

/// Warm-up of several profiles, one after the other, with one plan: tick the profiles, choose
/// what to visit as for one profile, Start.
///
/// Each profile takes its turn: started without a window when it is stopped, warmed up out of
/// sight, stopped and sealed again, then the next. A profile already open is warmed up where it
/// runs and stays open. The card on the right says which profile is on ("2 of 5"), how its run
/// goes and what each run came to; the rest can be cancelled at any time. Runs the schedule finds
/// due join the same queue (`WarmUpCoordinator`), so they show here too.
struct WarmUpQueueView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let manager = model.manager, let warmUps = model.warmUps {
            WarmUpQueuePanel(manager: manager, warmUps: warmUps)
        }
    }
}

private struct WarmUpQueuePanel: View {
    @ObservedObject var manager: ProfileManager
    @ObservedObject var warmUps: WarmUpCoordinator
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    @State private var choice = WarmUpChoice()
    @State private var manualPlan = WarmUpPlan()
    /// The list a ready-made choice produces, for the estimate. For a composed choice each profile
    /// gets its own when the queue is filled (its proxy's country).
    @State private var builtPlan = WarmUpPlan()
    @State private var loaded = false

    private var queue: WarmUpQueue { warmUps.queue }
    private var plan: WarmUpPlan { choice.source == .manual ? manualPlan : builtPlan }
    private var hasPages: Bool { !plan.pages().pages.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("warmupQueue.title"), subtitle: L("warmupQueue.explanation"))
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        profilePicker
                        WarmUpPlanChooser(choice: $choice, manualPlan: $manualPlan, plan: plan, countryCode: nil,
                                          forSeveralProfiles: true)
                        total
                    }
                    .padding(.trailing, 2)
                }
                .frame(width: 360)
                progress
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter(leading: { footerStatus }, buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if queue.isActive {
                    Button(L("warmupQueue.cancelRest")) { warmUps.cancelWaiting() }
                        .buttonStyle(.lumenSecondary)
                        .disabled(queue.waiting.isEmpty)
                    Button(L("warmupQueue.stopAll")) { warmUps.stopAll() }
                        .buttonStyle(.lumenSecondary)
                }
                Button(queue.isActive ? L("warmupQueue.add") : L("warmupQueue.start")) { start() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || !hasPages)
            })
        }
        .frame(width: 880, height: 640)
        .background(Theme.raised)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            rebuild()
        }
        .onChange(of: choice) { _, _ in rebuild() }
    }

    private func rebuild() {
        guard choice.source != .manual else { return }
        builtPlan = choice.plan(countryCode: nil, composedName: L("warmup.source.composed")) ?? WarmUpPlan()
    }

    // MARK: Which profiles

    private var selectable: [ProfileSummary] {
        model.profiles.filter { !warmUps.queue.isQueued($0.id) }
    }

    /// The ticked profiles that are not in the queue already: those Start adds.
    private var picked: [UUID] {
        selectable.map(\.id).filter { selected.contains($0) }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("warmupQueue.profiles")).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
                Spacer()
                let all = Set(selectable.map(\.id))
                Button(!all.isEmpty && all.isSubset(of: selected) ? L("warmupQueue.selectNone") : L("warmupQueue.selectAll")) {
                    selected = all.isSubset(of: selected) ? [] : all
                }
                .buttonStyle(.lumenGhost)
                .disabled(all.isEmpty)
            }
            if model.profiles.isEmpty {
                Text(L("warmupQueue.noProfiles")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.profiles) { profile in profileRow(profile) }
                }
                .card(padding: 4, fill: Theme.raisedInset)
            }
        }
    }

    private func profileRow(_ profile: ProfileSummary) -> some View {
        let queued = warmUps.queue.isQueued(profile.id)
        let isOn = selected.contains(profile.id) && !queued
        return Button {
            if isOn { selected.remove(profile.id) } else { selected.insert(profile.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                ProfileAvatar(name: profile.name, id: profile.id, size: 20)
                Text(profile.name).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                if queued {
                    Text(L("warmupQueue.inQueue")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                } else if model.isRunning(profile.id) {
                    Text(L("warmupQueue.open")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                }
                if let code = model.details[profile.id]?.exitCountryCode {
                    CountryFlag(code: code, size: 12)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.controlRadius)
        .disabled(queued)
        .help(model.isRunning(profile.id) && !queued ? L("warmupQueue.open.help") : "")
    }

    /// How many profiles, and how long all of them take.
    private var total: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.number").foregroundStyle(Theme.textTertiary)
                Text(String(format: L("warmupQueue.total"), picked.count,
                            WarmUpFormat.duration(plan.estimatedSeconds * Double(max(picked.count, 1)))))
                    .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
            }
            Text(L("warmupQueue.note")).font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() {
        // Built here, not read back from the screen's state (as on the warm-up screen of one
        // profile): a hand-written list as written, a ready-made one per profile.
        let choice = self.choice
        let written: WarmUpPlan?
        if choice.source == .manual {
            manualPlan = manualPlan.normalized
            var plan = manualPlan
            plan.choice = choice
            written = plan
        } else {
            written = nil
        }
        let ids = picked
        let details = model.details
        warmUps.enqueue(ids) { id in
            if let written { return written }
            return choice.plan(countryCode: details[id]?.exitCountryCode, composedName: L("warmup.source.composed")) ?? WarmUpPlan()
        }
        selected = []
    }

    // MARK: How the queue goes

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            currentRun
            Divider().overlay(Theme.divider)
            entryList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card(padding: 14, fill: Theme.raisedInset)
    }

    @ViewBuilder private var currentRun: some View {
        if let current = queue.current, let position = queue.position {
            let status = manager.warmUpStatus(of: current.profileID)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: L("warmupQueue.position"), position.number, position.count, name(of: current.profileID)))
                        .font(.lumenSheetTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                GeometryReader { geometry in
                    LumenProgressBar(fraction: status?.isRunning == true ? (status?.fraction ?? 0) : 0, width: geometry.size.width)
                }
                .frame(height: 2)
                Text(runLine(status)).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
                Text(L("warmup.invisible")).font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(queue.entries.isEmpty ? L("warmupQueue.idle") : L("warmupQueue.over"))
                    .font(.lumenSheetTitle).foregroundStyle(Theme.textPrimary)
                Text(L("warmupQueue.idle.detail")).font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The running profile's run: starting, or which page of how many and the cookies so far.
    private func runLine(_ status: WarmUpStatus?) -> String {
        guard let status, status.isRunning else { return L("warmupQueue.starting") }
        return String(format: L("warmupQueue.page"), status.currentPage, status.total, status.cookies)
    }

    @ViewBuilder private var entryList: some View {
        if queue.entries.isEmpty {
            Text(L("warmupQueue.empty")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(queue.entries) { entry in
                        entryRow(entry)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: WarmUpQueue.Entry) -> some View {
        HStack(spacing: 8) {
            entryIcon(entry.state).frame(width: 16)
            ProfileAvatar(name: name(of: entry.profileID), id: entry.profileID, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name(of: entry.profileID)).font(.lumenLabel).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if entry.source == .schedule {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .help(L("warmupQueue.scheduled"))
                    }
                }
                Text(describe(entry)).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if case let .done(status?) = entry.state, status.cookies > 0 {
                Text(verbatim: "+\(status.cookies)")
                    .font(.lumenSecondary.weight(.semibold)).foregroundStyle(Theme.accent).monospacedDigit()
                    .help(L("warmupQueue.cookies.help"))
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private func entryIcon(_ state: WarmUpQueue.Entry.State) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "hourglass").foregroundStyle(Theme.textTertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case let .done(status):
            if status?.phase == .finished {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.running)
            } else {
                Image(systemName: "stop.circle").foregroundStyle(Theme.textSecondary)
            }
        case .skipped:
            Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(Theme.warning)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(Theme.textTertiary)
        }
    }

    private func describe(_ entry: WarmUpQueue.Entry) -> String {
        switch entry.state {
        case .waiting:
            return L("warmupQueue.state.waiting")
        case .running:
            return runLine(manager.warmUpStatus(of: entry.profileID))
        case let .done(status):
            guard let status else { return L("warmupQueue.state.noReport") }
            if status.phase == .finished {
                return String(format: L("warmupQueue.state.finished"), status.visited, status.failed,
                              status.sites?.filter { $0.added > 0 }.count ?? 0)
            }
            return String(format: L("warmupQueue.state.stopped"), status.visited, status.total)
        case let .skipped(reason):
            switch reason {
            case .inUse: return L("warmupQueue.skipped.inUse")
            case .notStarted: return L("warmupQueue.skipped.notStarted")
            case .noPlan: return L("warmupQueue.skipped.noPlan")
            case .profileGone: return L("warmupQueue.skipped.profileGone")
            }
        case .cancelled:
            return L("warmupQueue.state.cancelled")
        }
    }

    private func name(of id: UUID) -> String {
        model.profiles.first { $0.id == id }?.name ?? L("warmupQueue.deletedProfile")
    }

    @ViewBuilder private var footerStatus: some View {
        if queue.isActive {
            Text(String(format: L("warmupQueue.status.waiting"), queue.waiting.count))
                .font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
    }
}
