import BrowserCore
import SwiftUI

/// Session warm-up for one profile.
///
/// Three ways to say what to visit — one of the lists the app ships, a list it puts together from
/// the profile's own country and the kinds of browsing chosen, or addresses written by hand — and
/// two dials over them: how long the run may take and how thoroughly each page is read. Start
/// launches the profile when it is stopped and runs the robot in a window of the profile placed
/// off every screen, so nothing opens in front of the user. Below the choice, the same plan can be
/// repeated every few hours (`WarmUpSchedule`, run by `WarmUpCoordinator`).
///
/// What it shows while it runs — the page it is on, how much is left, how many cookies the profile
/// has gained — comes from `ProfileManager.warmUpStatus`, which is the same whether the robot runs
/// in the manager's process or in the profile's own; and so does the report once the run is over:
/// the profile's cookies per site, and which of them the run added.
struct WarmUpView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let manager = model.manager, let warmUps = model.warmUps {
            WarmUpPanel(profile: profile, manager: manager, warmUps: warmUps)
        }
    }
}

private struct WarmUpPanel: View {
    let profile: ProfileSummary
    @ObservedObject var manager: ProfileManager
    @ObservedObject var warmUps: WarmUpCoordinator
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var choice = WarmUpChoice()
    /// The hand-written plan, kept while a ready-made list is chosen so that switching back does
    /// not lose it.
    @State private var manualPlan = WarmUpPlan()
    /// The list the ready-made choice produced, built when the choice changes: what the screen
    /// counts and what Start runs, so the two cannot disagree.
    @State private var builtPlan = WarmUpPlan()
    @State private var loaded = false
    @State private var starting = false
    /// After a run: its pages instead of the sites it left cookies on.
    @State private var showingPages = false

    private var countryCode: String? { model.details[profile.id]?.exitCountryCode }
    private var status: WarmUpStatus? { manager.warmUpStatus(of: profile.id) }
    private var isRunning: Bool { status?.isRunning ?? false }
    private var plan: WarmUpPlan { choice.source == .manual ? manualPlan : builtPlan }
    private var reading: (pages: [WarmUpPlan.Page], problems: [WarmUpPlan.Problem]) { plan.pages() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("warmup.title"), profile.name), subtitle: L("warmup.explanation"))
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WarmUpPlanChooser(choice: $choice, manualPlan: $manualPlan, plan: plan, countryCode: countryCode)
                            .disabled(isRunning || starting)
                        scheduleSection
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
                if isRunning {
                    Button(L("warmup.stop")) { model.stopWarmUp(profile.id) }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("warmup.start")) { start() }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(starting || reading.pages.isEmpty || model.isBusy(profile.id))
                }
            })
        }
        .sheetFrame(width: 880, height: 640)
        .background(Theme.raised)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let saved = model.warmUpPlan(for: profile.id)
            manualPlan = saved
            choice = saved.choice ?? (saved.addresses.isEmpty ? WarmUpChoice() : WarmUpChoice(source: .manual))
            rebuild()
        }
        .onChange(of: choice) { _, _ in rebuild() }
    }

    /// Builds the plan a ready-made choice stands for. Done on every change of the choice, and not
    /// at Start, so that what the screen says — the pages, the estimate — is what runs.
    private func rebuild() {
        guard choice.source != .manual else { return }
        builtPlan = choice.plan(countryCode: countryCode, composedName: L("warmup.source.composed")) ?? WarmUpPlan()
    }

    /// The plan to run or repeat, built here rather than read back from the screen's state, which
    /// SwiftUI may not have written yet; the screen is set to it.
    private func runnablePlan() -> WarmUpPlan {
        var plan: WarmUpPlan
        if choice.source == .manual {
            manualPlan = manualPlan.normalized
            plan = manualPlan
        } else {
            plan = choice.plan(countryCode: countryCode, composedName: L("warmup.source.composed")) ?? WarmUpPlan()
            builtPlan = plan
        }
        plan.choice = choice
        return plan
    }

    // MARK: Repeating

    private var schedule: WarmUpSchedule? { warmUps.schedule(for: profile.id) }
    private var repeats: Bool { schedule?.isEnabled ?? false }
    private var repeatHours: Int { schedule?.everyHours ?? 24 }

    /// "Repeat every N hours": the plan the screen shows, run by the schedule while the app is
    /// unlocked. Changing it keeps that plan as the profile's.
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            Toggle(isOn: Binding(get: { repeats }, set: { setSchedule(enabled: $0, hours: repeatHours) })) {
                Text(L("warmup.schedule.repeat")).font(.lumenLabel).foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(reading.pages.isEmpty && !repeats)
            if repeats {
                HStack {
                    Text(L("warmup.schedule.every")).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("", selection: Binding(get: { repeatHours }, set: { setSchedule(enabled: true, hours: $0) })) {
                        ForEach(Self.hourChoices(including: repeatHours), id: \.self) { hours in
                            Text(String(format: L("warmup.schedule.hours"), hours)).tag(hours)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Text(scheduleLine).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(repeats ? L("warmup.schedule.note") : L("warmup.schedule.explanation"))
                .font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Last: 3 hours ago · next: in 3 hours".
    private var scheduleLine: String {
        let lastRun: Date? = schedule?.lastRunAt
        let nextRun: Date? = warmUps.nextRun(of: profile.id)
        let last = lastRun.map { $0.formatted(.relative(presentation: .named)) } ?? L("warmup.schedule.never")
        let next = nextRun.map { $0.formatted(.relative(presentation: .named)) } ?? "—"
        return String(format: L("warmup.schedule.times"), last, next)
    }

    /// The intervals offered, and the profile's own if it is another (set before, or elsewhere).
    static func hourChoices(including hours: Int) -> [Int] {
        let choices = [1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 168]
        return choices.contains(hours) ? choices : (choices + [hours]).sorted()
    }

    private func setSchedule(enabled: Bool, hours: Int) {
        do {
            try warmUps.setSchedule(enabled: enabled, everyHours: hours, plan: runnablePlan(), for: profile.id)
        } catch {
            model.showError(error.localizedDescription)
        }
    }

    // MARK: How it is going

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            counters
            Divider().overlay(Theme.divider)
            details
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card(padding: 14, fill: Theme.raisedInset)
    }

    @ViewBuilder private var counters: some View {
        let status = self.status
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline(status)).font(.lumenSheetTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                if status?.isRunning == true { ProgressView().controlSize(.small) }
            }
            GeometryReader { geometry in
                LumenProgressBar(fraction: status?.fraction ?? 0, width: geometry.size.width)
            }
            .frame(height: 2)
            HStack(spacing: 18) {
                counter(L("warmup.counter.cookies"), value: "\(status?.cookies ?? 0)", accent: true)
                counter(L("warmup.counter.pages"), value: "\(status?.visited ?? 0)/\(status?.total ?? reading.pages.count)")
                counter(L("warmup.counter.remaining"), value: remaining(status))
            }
            if let host = status?.currentHost, status?.isRunning == true {
                Text(String(format: L("warmup.progress.current"), host))
                    .font(.lumenSecondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Text(L("warmup.invisible")).font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func counter(_ label: String, value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                .foregroundStyle(accent ? Theme.accent : Theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func headline(_ status: WarmUpStatus?) -> String {
        guard let status else { return L("warmup.progress.idle") }
        switch status.phase {
        case .running: return String(format: L("warmup.progress.page"), status.currentPage, status.total)
        case .finished: return String(format: L("warmup.progress.finished"), status.visited, status.failed)
        case .stopped: return String(format: L("warmup.progress.stopped"), status.visited, status.total)
        }
    }

    private func remaining(_ status: WarmUpStatus?) -> String {
        guard let status, status.isRunning else { return "—" }
        guard let seconds = status.secondsRemaining else { return WarmUpFormat.duration(plan.estimatedSeconds) }
        return WarmUpFormat.duration(seconds)
    }

    /// Under the counters: once a run is over, the sites it left cookies on (and, when the run
    /// was in this process, its pages one by one on the other tab); before and while it runs, the
    /// pages.
    @ViewBuilder private var details: some View {
        if let sites = status.flatMap({ $0.isRunning ? nil : $0.sites }) {
            VStack(alignment: .leading, spacing: 10) {
                if !manager.warmUpVisits(of: profile.id).isEmpty {
                    Picker("", selection: $showingPages) {
                        Text(L("warmup.report.tab.sites")).tag(false)
                        Text(L("warmup.report.tab.pages")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if showingPages {
                    visitList
                } else {
                    WarmUpSiteList(sites: sites)
                }
            }
        } else {
            visitList
        }
    }

    /// The pages of a run in the manager's own process, which is the only place the screen can see
    /// them one by one; a profile in its own process reports the counters above instead.
    @ViewBuilder private var visitList: some View {
        let visits = manager.warmUpVisits(of: profile.id)
        if visits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("warmup.pagesToVisitTitle")).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
                ForEach(Array(reading.pages.prefix(12).enumerated()), id: \.offset) { index, page in
                    Text(verbatim: "\(index + 1). " + (page.kind == .search ? L("warmup.page.search") : (page.url.host ?? page.url.absoluteString)))
                        .font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                if reading.pages.count > 12 {
                    Text(String(format: L("warmup.pages.more"), reading.pages.count - 12))
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(visits) { visit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        icon(for: visit, visits: visits)
                        Text(visit.url.host ?? visit.url.absoluteString).font(.callout.bold()).lineLimit(1)
                        Text(visit.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if !visit.title.isEmpty { Text(visit.title).font(.caption).lineLimit(1) }
                    Text(detail(of: visit)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .scrollContentBackground(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder private func icon(for visit: WarmUpVisit, visits: [WarmUpVisit]) -> some View {
        switch visit.outcome {
        case nil:
            if isRunning && visit.id == visits.last?.id { ProgressView().controlSize(.mini) }
            else { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
        case .loaded?: Image(systemName: "checkmark.circle").foregroundStyle(Theme.running)
        case .timedOut?: Image(systemName: "clock").foregroundStyle(Theme.warning)
        case .failed?: Image(systemName: "xmark.circle").foregroundStyle(Theme.danger)
        }
    }

    private func detail(of visit: WarmUpVisit) -> String {
        var parts: [String] = []
        switch visit.outcome {
        case let .failed(message)?: parts.append(String(format: L("warmup.visit.failed"), message))
        case .timedOut?: parts.append(L("warmup.visit.timedOut"))
        default: break
        }
        if visit.dwell > 0 { parts.append(String(format: L("warmup.visit.stayed"), Int(visit.dwell.rounded()), visit.scrolls)) }
        if let followed = visit.followed {
            let outcome: String
            switch visit.followedOutcome {
            case let .failed(message)?: outcome = String(format: L("warmup.visit.failed"), message)
            case .timedOut?: outcome = L("warmup.visit.timedOut")
            default: outcome = ""
            }
            parts.append(String(format: L("warmup.visit.followed"), followed.absoluteString) + (outcome.isEmpty ? "" : " — " + outcome))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var footerStatus: some View {
        if starting {
            Text(L("warmup.status.starting")).font(.lumenSecondary)
        } else if let status, status.isRunning {
            Text(String(format: L("warmup.status.running"), status.currentPage, status.total))
                .font(.lumenSecondary).monospacedDigit()
        } else if warmUps.isWaiting(profile.id) {
            Label(L("warmup.status.queued"), systemImage: "hourglass")
                .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
        } else if let status, status.phase == .finished {
            Label(String(format: L("warmup.status.finished"), status.visited, status.failed), systemImage: "checkmark.circle")
                .font(.lumenSecondary).foregroundStyle(Theme.running)
        } else if let status, status.phase == .stopped, status.visited > 0 {
            Label(L("warmup.status.stopped"), systemImage: "stop.circle")
                .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Actions

    private func start() {
        let plan = runnablePlan()
        starting = true
        showingPages = false
        Task {
            _ = await model.startWarmUp(plan, for: profile.id)
            starting = false
        }
    }
}

// MARK: - What to visit

/// What to visit and how: one of the lists the app ships, one it puts together from the proxy's
/// country and the kinds of browsing chosen, or addresses written by hand — and, over a list, the
/// two dials. The warm-up screen of one profile and the one for several share it; for several,
/// a composed list is put together for each profile's own country when its turn comes.
struct WarmUpPlanChooser: View {
    @Binding var choice: WarmUpChoice
    @Binding var manualPlan: WarmUpPlan
    /// The plan as it stands (the one built for a ready-made choice): what the estimate counts.
    let plan: WarmUpPlan
    /// The country the profile's proxy exits in; nil when it is unknown, or for several profiles.
    let countryCode: String?
    var forSeveralProfiles = false

    private var reading: (pages: [WarmUpPlan.Page], problems: [WarmUpPlan.Problem]) { plan.pages() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $choice.source) {
                Text(L("warmup.source.preset")).tag(WarmUpChoice.Source.preset)
                Text(L("warmup.source.composed")).tag(WarmUpChoice.Source.composed)
                Text(L("warmup.source.manual")).tag(WarmUpChoice.Source.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch choice.source {
            case .preset: presetChooser
            case .composed: composedChooser
            case .manual: manualEditor
            }
            if choice.source != .manual { dials }
            estimate
        }
    }

    private var presetChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(WarmUpPreset.Group.allCases, id: \.self) { group in
                let presets = WarmUpPresets.all.filter { $0.group == group }
                if !presets.isEmpty {
                    Text(L("warmup.group." + group.rawValue)).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
                    FlowRows(items: presets.map(\.id)) { id in
                        if let preset = WarmUpPresets.preset(id: id) {
                            presetChip(preset)
                        }
                    }
                }
            }
            if let preset = WarmUpPresets.preset(id: choice.presetID) {
                Text(WarmUpFormat.sites(of: preset)).font(.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func presetChip(_ preset: WarmUpPreset) -> some View {
        let selected = choice.presetID == preset.id
        return Button { choice.presetID = preset.id } label: {
            HStack(spacing: 5) {
                if preset.group == .country { CountryFlag(code: preset.id, size: 12) }
                Text(WarmUpFormat.name(of: preset)).font(.lumenSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.accentFill : Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 1))
            .foregroundStyle(selected ? Color.white : Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private var composedChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("warmup.composed.explanation")).font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if forSeveralProfiles {
                    Image(systemName: "globe").foregroundStyle(Theme.textTertiary)
                    Text(L("warmup.composed.eachCountry")).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let code = countryCode, let preset = WarmUpPresets.country(code) {
                    CountryFlag(code: code, size: 14)
                    Text(String(format: L("warmup.composed.country"), WarmUpFormat.name(of: preset))).font(.lumenSecondary)
                } else if let code = countryCode {
                    CountryFlag(code: code, size: 14)
                    Text(String(format: L("warmup.composed.countryUnknown"), CountryNames.name(for: code.uppercased())))
                        .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                } else {
                    Image(systemName: "globe").foregroundStyle(Theme.textTertiary)
                    Text(L("warmup.composed.noCountry")).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(L("warmup.composed.interests")).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
            FlowRows(items: WarmUpPresets.all.filter { $0.group == .interest }.map(\.id)) { id in
                if let preset = WarmUpPresets.preset(id: id) { interestChip(preset) }
            }
            Text(WarmUpFormat.sites(of: WarmUpPresets.composed(
                countryCode: countryCode,
                interests: choice.interestIDs.compactMap(WarmUpPresets.preset(id:)),
                name: "", shuffle: { $0 })))
                .font(.caption).foregroundStyle(Theme.textTertiary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func interestChip(_ preset: WarmUpPreset) -> some View {
        let selected = choice.interestIDs.contains(preset.id)
        return Button {
            if selected { choice.interestIDs.removeAll { $0 == preset.id } } else { choice.interestIDs.append(preset.id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                Text(WarmUpFormat.name(of: preset)).font(.lumenSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.accentFill : Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 1))
            .foregroundStyle(selected ? Color.white : Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: The two dials

    private var dials: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("warmup.minutes")).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(WarmUpFormat.duration(TimeInterval(choice.minutes) * 60)).font(.lumenSecondary).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(choice.minutes) }, set: { choice.minutes = Int($0) }),
                       in: Double(WarmUpChoice.minuteRange.lowerBound)...Double(WarmUpChoice.minuteRange.upperBound),
                       step: 5)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("warmup.quality")).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
                Picker("", selection: $choice.quality) {
                    ForEach(WarmUpQuality.allCases, id: \.self) { quality in
                        Text(L("warmup.quality." + quality.rawValue)).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(L("warmup.quality." + choice.quality.rawValue + ".detail"))
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var estimate: some View {
        let pages = reading.pages.count
        let seconds = plan.estimatedSeconds
        return HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(Theme.textTertiary)
            Text(String(format: forSeveralProfiles ? L("warmup.estimate.each") : L("warmup.estimate"), pages, WarmUpFormat.duration(seconds)))
                .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: A list written by hand

    private var manualEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("warmup.addresses")).font(.lumenLabel).foregroundStyle(Theme.textPrimary)
            TextEditor(text: $manualPlan.addresses)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 130)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.fieldBorder, lineWidth: 1))
            problems
            TextField(L("warmup.search"), text: $manualPlan.searchQuery, prompt: Text(verbatim: ""))
                .lumenField(L("warmup.searchPrompt"), isEmpty: manualPlan.searchQuery.isEmpty)
            HStack {
                Text(L("warmup.dwell"))
                Spacer()
                secondsField($manualPlan.minimumDwell)
                Text(verbatim: "–")
                secondsField($manualPlan.maximumDwell)
                Text(L("warmup.seconds")).foregroundStyle(.secondary)
            }
            Toggle(L("warmup.scroll"), isOn: $manualPlan.scroll)
                .toggleStyle(.switch).controlSize(.small)
            Toggle(L("warmup.followLinks"), isOn: $manualPlan.followLinks)
                .toggleStyle(.switch).controlSize(.small)
            Text(L("warmup.note")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func secondsField(_ value: Binding<TimeInterval>) -> some View {
        TextField("", value: Binding(get: { Int(value.wrappedValue) }, set: { value.wrappedValue = TimeInterval($0) }),
                  format: .number)
            .multilineTextAlignment(.trailing)
            .lumenField(height: 28)
            .frame(width: 56)
            .onSubmit { manualPlan = manualPlan.normalized }
    }

    @ViewBuilder private var problems: some View {
        let problems = reading.problems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(problems.prefix(4).enumerated()), id: \.offset) { _, problem in
                    Text(String(format: L("warmup.problem"), problem.line, WarmUpFormat.describe(problem.reason)))
                        .lineLimit(1).truncationMode(.middle)
                }
                if problems.count > 4 { Text(String(format: L("warmup.problems.more"), problems.count - 4)) }
            }
            .font(.caption).foregroundStyle(Theme.warning)
        }
    }
}

// MARK: - The report

/// What a run left behind: the profile's cookies per site (registrable domain) and how many of
/// them the run added, the sites it added to first. Counted in the profile's own cookie store when
/// the run ended (`WarmUpStatus.sites`).
struct WarmUpSiteList: View {
    let sites: [WarmUpCookieSite]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("warmup.report.site")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("warmup.report.cookies")).frame(width: 64, alignment: .trailing)
                Text(L("warmup.report.added")).frame(width: 52, alignment: .trailing)
            }
            .font(.lumenColumn)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            if sites.isEmpty {
                Text(L("warmup.report.empty")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sites) { site in
                            HStack(spacing: 8) {
                                Text(verbatim: site.site)
                                    .font(.lumenSecondary).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: "\(site.cookies)")
                                    .font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                    .frame(width: 64, alignment: .trailing)
                                Text(verbatim: site.added > 0 ? "+\(site.added)" : "—")
                                    .font(.lumenSecondary.weight(site.added > 0 ? .semibold : .regular))
                                    .foregroundStyle(site.added > 0 ? Theme.accent : Theme.textTertiary).monospacedDigit()
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .frame(height: 24)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
                        }
                    }
                }
                let added = sites.filter { $0.added > 0 }
                Text(String(format: L("warmup.report.summary"), added.reduce(0) { $0 + $1.added }, added.count))
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Names and times

/// The words and numbers both warm-up screens show.
enum WarmUpFormat {
    /// A preset's name: the app's own for the lists it ships, the country's name for a country.
    static func name(of preset: WarmUpPreset) -> String {
        if preset.group == .country {
            let name = CountryNames.name(for: preset.id.uppercased())
            if !name.isEmpty { return name }
        }
        let key = "warmup.preset." + preset.id
        let localized = L(key)
        return localized == key ? preset.name : localized
    }

    static func sites(of preset: WarmUpPreset) -> String {
        preset.addresses.prefix(8).joined(separator: " · ")
    }

    /// "20 мин", "1 ч 10 мин", "40 с".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: L("warmup.duration.seconds"), max(total, 1)) }
        let minutes = (total + 29) / 60
        if minutes < 60 { return String(format: L("warmup.duration.minutes"), minutes) }
        return String(format: L("warmup.duration.hours"), minutes / 60, minutes % 60)
    }

    static func describe(_ reason: WarmUpPlan.Problem.Reason) -> String {
        switch reason {
        case .notAWebAddress: return L("warmup.reason.notAWebAddress")
        case let .unsupportedScheme(scheme): return String(format: L("warmup.reason.unsupportedScheme"), scheme)
        case .duplicate: return L("warmup.reason.duplicate")
        case .tooMany: return String(format: L("warmup.reason.tooMany"), WarmUpPlan.maximumPages)
        }
    }
}

/// Chips laid out in rows, wrapping to the next when a row is full — the preset and interest
/// pickers, which have more items than a row holds and no fixed number of them.
private struct FlowRows<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            rows(perRow: items.count)
            rows(perRow: 4)
            rows(perRow: 3)
            rows(perRow: 2)
        }
    }

    private func rows(perRow: Int) -> some View {
        let chunks = stride(from: 0, to: items.count, by: max(1, perRow)).map { start in
            Array(items[start..<min(start + max(1, perRow), items.count)])
        }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                HStack(spacing: 5) {
                    ForEach(chunk, id: \.self) { content($0) }
                }
            }
        }
    }
}
