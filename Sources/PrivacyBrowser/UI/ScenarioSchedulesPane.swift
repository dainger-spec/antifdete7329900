import BrowserCore
import SwiftUI

/// Runs by the clock (the scenario editor's "Schedule"): a row a schedule — what runs, on which
/// profile, when, its next time and how the last one went — with a switch, and a form that adds
/// or changes one. Scenarios and a profile's warm-up alike; with the plan's automation only.
struct ScenarioSchedulesPane: View {
    @EnvironmentObject private var model: AppModel
    /// The schedule in the form: a new one, or one being changed.
    @State private var draft: ScenarioSchedule?
    /// The schedule whose deletion is being asked about.
    @State private var pendingDelete: ScenarioSchedule?
    /// Shown without a vault (the snapshots): these schedules, and the names they need.
    var sample: Sample?
    /// A schedule to open the form with: "On a Schedule…" of the scenario editor.
    var proposed: ScenarioSchedule?

    struct Sample {
        var schedules: [ScenarioSchedule]
        var scenarios: [Scenario]
        var profiles: [(id: UUID, name: String)]
        var editing: ScenarioSchedule?
    }

    private var schedules: [ScenarioSchedule] { sample?.schedules ?? model.scenarioSchedules.schedules }
    private var scenarios: [Scenario] { sample?.scenarios ?? model.scenarios.sorted }
    private var profiles: [(id: UUID, name: String)] { sample?.profiles ?? model.profiles.map { ($0.id, $0.name) } }
    private var allowed: Bool { sample != nil || model.allowsAutomation }
    /// The schedules' file is a newer version's or does not open: none is shown and none can be saved.
    private var refused: Bool { sample == nil && model.scenarioSchedulesRefused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("schedule.title"))
                    .font(.lumenHeading)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    draft = newSchedule()
                } label: { Label(L("schedule.add"), systemImage: "plus") }
                    .buttonStyle(.lumenPrimary)
                    .disabled(!allowed || refused || profiles.isEmpty || draft != nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 6)
            Text(L("schedule.subtitle"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            if !allowed {
                Text(L("schedule.notInPlan"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.warningTint))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.warningLine))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            // Said, not shown as "no schedules yet" with a Save that ends in an alert.
            if refused {
                Label(L("schedule.unreadable"), systemImage: "exclamationmark.triangle.fill")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let draft, !schedules.contains(where: { $0.id == draft.id }) { form(draft) }
                    // Only where one can be added: in a plan without automation, or with a file
                    // that does not open, the note above stands alone.
                    if schedules.isEmpty, draft == nil, allowed, !refused { empty }
                    ForEach(schedules) { schedule in
                        if draft?.id == schedule.id, let draft { form(draft) } else { row(schedule) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            // The snapshots' form; else the one the scenario editor asked for, where it can be saved.
            // One that is saved already is not opened again over what the list has of it.
            if let editing = sample?.editing {
                draft = editing
            } else if allowed, !refused, let proposed, !schedules.contains(where: { $0.id == proposed.id }) {
                draft = proposed
            }
        }
        .confirmationDialog(L("schedule.delete.title"),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { schedule in
            Button(L("common.delete"), role: .destructive) {
                if model.saveSchedule(schedule, remove: true), draft?.id == schedule.id { draft = nil }
            }
        } message: { schedule in
            Text(String(format: L("schedule.delete.message"), title(schedule.action), profileName(schedule.profileID)))
        }
    }

    /// No schedule yet: what one is for, and the button that adds the first.
    private var empty: some View {
        VStack(spacing: 0) {
            IconBadge(symbol: "clock", tint: Theme.textTertiary, size: 44)
                .padding(.bottom, 12)
            Text(L("schedule.empty.title"))
                .font(.lumenSheetTitle)
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)
            Text(profiles.isEmpty ? L("schedule.empty.noProfiles") : L("schedule.empty"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.bottom, 20)
            if !profiles.isEmpty {
                Button {
                    draft = newSchedule()
                } label: { Label(L("schedule.add"), systemImage: "plus") }
                    .buttonStyle(.lumenPrimary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: A schedule

    private func row(_ schedule: ScenarioSchedule) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol(schedule.action))
                .font(.system(size: 15))
                .foregroundStyle(schedule.isEnabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(schedule.action))
                    .font(.lumenRowTitle)
                    .foregroundStyle(schedule.isEnabled ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Text(String(format: L("schedule.row.onProfile"), profileName(schedule.profileID), Self.whenText(schedule)))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // How the last run that came due went. One that could not be made is a warning; one
                // the Mac slept through is not a fault, and is said plainly.
                if schedule.isEnabled, let problem = problemText(schedule) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else if schedule.isEnabled, schedule.lastResult == .missed {
                    Text(L("schedule.state.missed"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if schedule.isEnabled, schedule.lastResult == .started, let last = schedule.lastRunAt {
                    Text(String(format: L("schedule.state.last"), Self.shownRun(last)))
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            // When it runs next: the row's fact, at its right edge.
            VStack(alignment: .trailing, spacing: 2) {
                Text(nextRunText(schedule))
                    .font(.lumenLabel)
                    .monospacedDigit()
                    .foregroundStyle(schedule.isEnabled ? Theme.textPrimary : Theme.textTertiary)
                if schedule.isEnabled {
                    Text(L("schedule.row.next"))
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .fixedSize()
            // In a plan without automation a schedule cannot be changed, and does not run: it can
            // be deleted, and switched off (not on).
            if allowed {
                Button(L("passwords.edit")) { draft = schedule }
                    .buttonStyle(.lumenGhost)
                    .disabled(draft != nil)
            } else {
                Button(L("common.delete"), role: .destructive) { pendingDelete = schedule }
                    .buttonStyle(.lumenDestructive)
            }
            Toggle(L("schedule.enabled"), isOn: Binding(get: { schedule.isEnabled }, set: { on in
                var changed = schedule
                changed.isEnabled = on
                // Turned on again, it is planned from now: not run at once for the time it was off.
                if on { changed.nextRunAt = nil }
                model.saveSchedule(changed)
            }))
            .toggleStyle(.lumenSwitch)
            .labelsHidden()
            .disabled(sample != nil || (!allowed && !schedule.isEnabled))
        }
        .card(padding: 14)
        .contextMenu {
            Button(L("passwords.edit")) { draft = schedule }
                .disabled(!allowed || draft != nil)
            Button(L("common.delete"), role: .destructive) { pendingDelete = schedule }
        }
    }

    private func symbol(_ action: ScenarioSchedule.Action) -> String {
        if case .warmUp = action { return "flame" }
        return "play.rectangle"
    }

    private func title(_ action: ScenarioSchedule.Action) -> String {
        switch action {
        case .warmUp: return L("schedule.action.warmUp")
        case let .scenario(id):
            let name = scenarios.first { $0.id == id }?.name ?? ""
            return String(format: L("schedule.action.scenario"), name.isEmpty ? L("scenarios.untitled") : name)
        }
    }

    private func profileName(_ id: UUID) -> String { profiles.first { $0.id == id }?.name ?? "—" }

    /// "every day at 10:00, within 15 min" or "every 6 h".
    static func whenText(_ schedule: ScenarioSchedule) -> String {
        let base: String
        switch schedule.when {
        case let .daily(hour, minute): base = String(format: L("schedule.when.daily"), String(format: "%02d:%02d", hour, minute))
        case let .every(hours): base = String(format: L("schedule.when.every"), hours)
        }
        return schedule.jitterMinutes == 0 ? base : base + String(format: L("schedule.when.jitter"), schedule.jitterMinutes)
    }

    /// "Thu, 12 Nov, 10:07": a run's time without the year. On one line: check_localization.py
    /// looks for the interface's locale on the line of `.formatted(`.
    private static func shownRun(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Localization.locale)) }

    /// When the schedule runs next, as its row says it: the time, a dash until one is planned, or
    /// that it is switched off.
    private func nextRunText(_ schedule: ScenarioSchedule) -> String {
        guard schedule.isEnabled else { return L("schedule.state.off") }
        return schedule.nextRunAt.map { Self.shownRun($0) } ?? "—"
    }

    /// What stopped the last run that came due, in words; nil when nothing did.
    private func problemText(_ schedule: ScenarioSchedule) -> String? {
        switch schedule.lastResult {
        case .failed?: return L("schedule.state.failed")
        case .notInPlan?: return L("schedule.state.notInPlan")
        case .missed?, .started?, nil: return nil
        }
    }

    // MARK: The form

    private func newSchedule() -> ScenarioSchedule {
        ScenarioSchedule(action: scenarios.first.map { .scenario($0.id) } ?? .warmUp, profileID: profiles.first?.id ?? UUID(),
                         when: .daily(hour: 10, minute: 0), jitterMinutes: 15)
    }

    private func form(_ initial: ScenarioSchedule) -> some View {
        let binding = Binding(get: { draft ?? initial }, set: { draft = $0 })
        let isNew = !schedules.contains { $0.id == initial.id }
        return VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("schedule.form.new") : L("schedule.form.edit"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
            field(L("schedule.form.what")) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(L("schedule.form.what"), selection: binding.action) {
                        ForEach(scenarios) { scenario in
                            Text(String(format: L("schedule.action.scenario"), scenario.name.isEmpty ? L("scenarios.untitled") : scenario.name))
                                .tag(ScenarioSchedule.Action.scenario(scenario.id))
                        }
                        Text(L("schedule.action.warmUp")).tag(ScenarioSchedule.Action.warmUp)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    actionNotes(binding.wrappedValue)
                }
            }
            field(L("scenarios.profile")) {
                Picker(L("scenarios.profile"), selection: binding.profileID) {
                    ForEach(profiles, id: \.id) { profile in Text(profile.name).tag(profile.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }
            field(L("schedule.form.when")) {
                VStack(alignment: .leading, spacing: 10) {
                    LumenSegmented(selection: Binding(get: { Self.isDaily(binding.wrappedValue) }, set: { daily in
                        // A click on the segment that is chosen keeps the time set under it.
                        guard daily != Self.isDaily(binding.wrappedValue) else { return }
                        binding.wrappedValue.when = daily ? .daily(hour: 10, minute: 0) : .every(hours: 6)
                    }), options: [(value: true, title: L("schedule.form.daily")), (value: false, title: L("schedule.form.every"))])
                    timeChoice(binding)
                    if binding.wrappedValue.isEnabled {
                        Text(String(format: L("schedule.form.first"), firstRun(of: binding.wrappedValue).shown(date: .abbreviated, time: .shortened)))
                            .font(.lumenCaption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            field(L("schedule.form.jitter")) {
                VStack(alignment: .leading, spacing: 6) {
                    LumenSegmented(selection: binding.jitterMinutes, options: [0, 5, 15, 30, 60].map { minutes in
                        (value: minutes, title: minutes == 0 ? L("schedule.form.jitter.none") : String(format: L("schedule.form.jitter.minutes"), minutes))
                    })
                    Text(L("schedule.form.jitter.note"))
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if !isNew {
                    // Asked first, as a scenario's deletion is; the question names the schedule
                    // as it is saved, not the form's changes.
                    Button(L("common.delete"), role: .destructive) {
                        pendingDelete = schedules.first { $0.id == initial.id } ?? initial
                    }
                    .buttonStyle(.lumenDestructive)
                }
                Spacer()
                Button(L("common.cancel")) { draft = nil }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                // The switch is the row's: a schedule that was off stays off when its time is changed.
                Button(L("common.save")) {
                    if model.saveSchedule(binding.wrappedValue) { draft = nil }
                }
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(sample != nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raisedInset))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder, lineWidth: 1))
    }

    /// Under "What to run": why the menu holds the warm-up only, and what a warm-up by the clock
    /// runs — or that the profile's own repeating warm-up would run beside it.
    @ViewBuilder private func actionNotes(_ value: ScenarioSchedule) -> some View {
        if scenarios.isEmpty {
            Text(L("schedule.form.what.noScenarios"))
                .font(.lumenCaption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if value.action == .warmUp {
            // The Warm Up window's own "Repeat on a schedule" (WarmUpView) and this one would both run.
            if let own = model.warmUps?.schedule(for: value.profileID), own.isEnabled {
                Label(String(format: L("schedule.form.warmUp.twice"), own.everyHours), systemImage: "exclamationmark.triangle.fill")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("schedule.form.warmUp.note"))
                    .font(.lumenCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The time of day, or the hours between runs: menus, as the warm-up's "every N h".
    @ViewBuilder private func timeChoice(_ binding: Binding<ScenarioSchedule>) -> some View {
        switch binding.wrappedValue.when {
        case let .daily(hour, minute):
            HStack(spacing: 6) {
                Text(L("schedule.form.at")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                Picker(L("schedule.form.hour"), selection: Binding(get: { hour }, set: { binding.wrappedValue.when = .daily(hour: $0, minute: minute) })) {
                    ForEach(0..<24, id: \.self) { value in
                        Text(verbatim: String(format: "%02d", value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Text(verbatim: ":").foregroundStyle(Theme.textSecondary)
                Picker(L("schedule.form.minute"), selection: Binding(get: { minute }, set: { binding.wrappedValue.when = .daily(hour: hour, minute: $0) })) {
                    ForEach(Self.choices(Array(stride(from: 0, to: 60, by: 5)), including: minute), id: \.self) { value in
                        Text(verbatim: String(format: "%02d", value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        case let .every(hours):
            HStack(spacing: 6) {
                Text(L("schedule.form.everyHours")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                Picker(L("schedule.form.every"), selection: Binding(get: { hours }, set: { binding.wrappedValue.when = .every(hours: $0) })) {
                    ForEach(Self.choices([1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168], including: hours), id: \.self) { value in
                        Text(String(format: L("warmup.schedule.hours"), value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    /// The values a menu offers, and the schedule's own if it is another.
    private static func choices(_ list: [Int], including value: Int) -> [Int] {
        list.contains(value) ? list : (list + [value]).sorted()
    }

    /// When the schedule in the form runs next: its own planned time while what decides it is as
    /// saved, else planned from now, without the random part.
    private func firstRun(of value: ScenarioSchedule) -> Date {
        if let saved = schedules.first(where: { $0.id == value.id }), saved.isEnabled, saved.when == value.when,
           saved.jitterMinutes == value.jitterMinutes, let planned = saved.nextRunAt, planned > Date() { return planned }
        return value.nextRun(after: Date()) { _ in 0 }
    }

    private static func isDaily(_ schedule: ScenarioSchedule) -> Bool {
        if case .daily = schedule.when { return true }
        return false
    }

    /// A row of the form: its name on the left, the control on the right.
    private func field<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name)
                .font(.lumenLabel)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
