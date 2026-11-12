import BrowserCore
import SwiftUI

/// Runs by the clock (the scenario editor's "Schedule"): a row a schedule — what runs, on which
/// profile, when, its next time and how the last one went — with a switch, and a form that adds
/// or changes one. Scenarios and a profile's warm-up alike; with the plan's automation only.
struct ScenarioSchedulesPane: View {
    @EnvironmentObject private var model: AppModel
    /// The schedule in the form: a new one, or one being changed.
    @State private var draft: ScenarioSchedule?
    /// Shown without a vault (the snapshots): these schedules, and the names they need.
    var sample: Sample?

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
                    .buttonStyle(.lumenSecondary)
                    .disabled(!allowed || profiles.isEmpty || draft != nil)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let draft, !schedules.contains(where: { $0.id == draft.id }) { form(draft) }
                    if schedules.isEmpty, draft == nil {
                        LumenEmptyHint(symbol: "clock", text: L(profiles.isEmpty ? "schedule.empty.noProfiles" : "schedule.empty"))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }
                    ForEach(schedules) { schedule in
                        if draft?.id == schedule.id, let draft { form(draft) } else { row(schedule) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear { if let editing = sample?.editing { draft = editing } }
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
                Text(state(schedule))
                    .font(.lumenCaption)
                    .foregroundStyle(stateColor(schedule))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(L("passwords.edit")) { draft = schedule }
                .buttonStyle(.lumenGhost)
                .disabled(!allowed || draft != nil)
            Toggle(L("schedule.enabled"), isOn: Binding(get: { schedule.isEnabled }, set: { on in
                var changed = schedule
                changed.isEnabled = on
                // Turned on again, it is planned from now: not run at once for the time it was off.
                if on { changed.nextRunAt = nil }
                model.saveSchedule(changed)
            }))
            .toggleStyle(.lumenSwitch)
            .labelsHidden()
            .disabled(!allowed || sample != nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raisedInset))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
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

    /// The next run, and how the last one that came due went.
    private func state(_ schedule: ScenarioSchedule) -> String {
        guard schedule.isEnabled else { return L("schedule.state.off") }
        var parts: [String] = []
        if let next = schedule.nextRunAt {
            parts.append(String(format: L("schedule.state.next"), next.shown(date: .abbreviated, time: .shortened)))
        }
        if let result = schedule.lastResult {
            switch result {
            case .started:
                if let last = schedule.lastRunAt {
                    parts.append(String(format: L("schedule.state.last"), last.shown(date: .abbreviated, time: .shortened)))
                }
            case .failed: parts.append(L("schedule.state.failed"))
            case .missed: parts.append(L("schedule.state.missed"))
            case .notInPlan: parts.append(L("schedule.state.notInPlan"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ schedule: ScenarioSchedule) -> Color {
        guard schedule.isEnabled, let result = schedule.lastResult else { return Theme.textTertiary }
        return result == .failed || result == .notInPlan ? Theme.warning : Theme.textTertiary
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
            Text(L(isNew ? "schedule.form.new" : "schedule.form.edit"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
            field(L("schedule.form.what")) {
                Picker(L("schedule.form.what"), selection: binding.action) {
                    ForEach(scenarios) { scenario in
                        Text(String(format: L("schedule.action.scenario"), scenario.name.isEmpty ? L("scenarios.untitled") : scenario.name))
                            .tag(ScenarioSchedule.Action.scenario(scenario.id))
                    }
                    Text(L("schedule.action.warmUp")).tag(ScenarioSchedule.Action.warmUp)
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
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
                        binding.wrappedValue.when = daily ? .daily(hour: 10, minute: 0) : .every(hours: 6)
                    }), options: [(value: true, title: L("schedule.form.daily")), (value: false, title: L("schedule.form.every"))])
                    switch binding.wrappedValue.when {
                    case let .daily(hour, minute):
                        HStack(spacing: 6) {
                            Text(L("schedule.form.at")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                            number(hour, in: 0...23, pad: true) { binding.wrappedValue.when = .daily(hour: $0, minute: minute) }
                            Text(verbatim: ":").foregroundStyle(Theme.textSecondary)
                            number(minute, in: 0...59, step: 5, pad: true) { binding.wrappedValue.when = .daily(hour: hour, minute: $0) }
                        }
                    case let .every(hours):
                        HStack(spacing: 6) {
                            Text(L("schedule.form.everyHours")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                            number(hours, in: ScenarioSchedule.hoursAllowed) { binding.wrappedValue.when = .every(hours: $0) }
                            Text(L("schedule.form.hours")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                        }
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
                    Button(L("common.delete"), role: .destructive) {
                        if model.saveSchedule(initial, remove: true) { draft = nil }
                    }
                    .buttonStyle(.lumenDestructive)
                }
                Spacer()
                Button(L("common.cancel")) { draft = nil }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save")) {
                    var saved = binding.wrappedValue
                    saved.isEnabled = true
                    if model.saveSchedule(saved) { draft = nil }
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

    /// A whole number with − and + beside it.
    private func number(_ value: Int, in range: ClosedRange<Int>, step: Int = 1, pad: Bool = false, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Button { set(value - step < range.lowerBound ? range.upperBound - (range.upperBound % step) : value - step) } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel(L("schedule.form.less"))
            Text(verbatim: pad ? String(format: "%02d", value) : String(value))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 30)
            Button { set(value + step > range.upperBound ? range.lowerBound : value + step) } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel(L("schedule.form.more"))
        }
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
    }
}
