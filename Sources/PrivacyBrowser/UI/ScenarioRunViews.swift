import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Why a run failed, in the interface's language (`ScenarioFailureReason`): the runner's reason is
/// English, as a script's `catch` and the automation API see it, and a Russian interface showed it
/// as it was. A reason of the script's own is shown as written; the scenario's line, when named,
/// stays at the end.
enum ScenarioFailureText {
    static func text(_ reason: String) -> String {
        let parsed = ScenarioFailureReason.parse(reason)
        let words = self.words(parsed.reason)
        guard let line = parsed.line else { return words }
        return String(format: L("scenarios.failure.line"), words, line)
    }

    private static func words(_ reason: ScenarioFailureReason) -> String {
        switch reason {
        case .noWindow: return L("scenarios.failure.noWindow")
        case .timedOut(let wait):
            switch wait {
            case .element(let selector, let state): return String(format: L("scenarios.failure.wait.\(state)"), selector)
            case .load: return L("scenarios.failure.wait.load")
            case .address(let pattern): return String(format: L("scenarios.failure.wait.address"), pattern)
            case .opening(let address): return String(format: L("scenarios.failure.wait.opening"), address)
            case .back: return L("scenarios.failure.wait.back")
            case .forward: return L("scenarios.failure.wait.forward")
            case .reload: return L("scenarios.failure.wait.reload")
            case .profile: return L("scenarios.failure.wait.profile")
            case .other(let what): return String(format: L("scenarios.failure.wait.other"), what)
            }
        case .notFound(let selector): return String(format: L("scenarios.failure.notFound"), selector)
        case .notVisible(let selector): return String(format: L("scenarios.failure.notVisible"), selector)
        case .covered(let selector, let by?): return String(format: L("scenarios.failure.covered"), selector, by)
        case .covered(let selector, nil): return String(format: L("scenarios.failure.moving"), selector)
        case .disabled(let selector): return String(format: L("scenarios.failure.disabled"), selector)
        case .untypeable(let character): return String(format: L("scenarios.failure.untypeable"), character)
        case .nothingToGoBackTo: return L("scenarios.failure.noBack")
        case .nothingToGoForwardTo: return L("scenarios.failure.noForward")
        case .notWebAddress: return L("scenarios.failure.notWebAddress")
        case .navigation(let message): return String(format: L("scenarios.failure.navigation"), message)
        case .script(let message): return String(format: L("scenarios.failure.script"), message)
        case .couldNotStart: return L("scenarios.failure.couldNotStart")
        case .notAwaited(let count): return String(format: L("scenarios.failure.notAwaited"), count)
        case .other(let text): return text
        }
    }
}

/// What a run on many profiles is asked for (`ScenarioRunChooser`).
struct ScenarioBatchRequest {
    var profiles: [(id: UUID, name: String)]
    /// Profiles not run, each with why.
    var skipped: [UUID: String]
    var limit: Int
    var pause: ClosedRange<Double>?
    var stopsProfiles: Bool
}

/// Choosing the profiles a scenario runs on: by search, by tag, one by one; which of them have
/// no text for a value the scenario reads; how many at once, the pause between starts, whether
/// the profiles the run starts are stopped again.
struct ScenarioRunChooser: View {
    let scenario: Scenario
    let profiles: [ScenarioProfile]
    /// The profiles chosen as it opens (those selected in the Profiles list).
    var initial: Set<UUID> = []
    let start: (ScenarioBatchRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tagColors) private var tagColors
    @State private var chosen: Set<UUID> = []
    @State private var search = ""
    @State private var limit = ScenarioBatch.defaultLimit
    @State private var pause = 1
    @State private var stopsProfiles = true
    @State private var skipsMissing = true

    private static let pauses: [ClosedRange<Double>?] = [nil, 5...20, 30...90]

    private var names: [String] { ScenarioValues.namesRead(by: scenario.source) }
    private var shown: [ScenarioProfile] { profiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) } } }
    private var tags: [String] { Array(Set(profiles.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private func missing(_ profile: ScenarioProfile) -> [String] { names.filter { !profile.values.contains($0) } }
    private var picked: [ScenarioProfile] { profiles.filter { chosen.contains($0.id) } }
    private var lacking: [ScenarioProfile] { picked.filter { !missing($0).isEmpty } }
    private var runCount: Int { picked.count - (skipsMissing ? lacking.count : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("scenarios.choose.title"), scenario.name), subtitle: L("scenarios.choose.subtitle"))
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                list
                options
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.raisedInset)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
            }
            SheetFooter {
                Text(summary).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit().lineLimit(2)
            } buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    var skipped: [UUID: String] = [:]
                    if skipsMissing { for profile in lacking { skipped[profile.id] = String(format: L("scenarios.run.skipped.values"), missing(profile).joined(separator: ", ")) } }
                    start(ScenarioBatchRequest(profiles: picked.map { (id: $0.id, name: $0.name) }, skipped: skipped, limit: limit,
                                             pause: Self.pauses[pause], stopsProfiles: stopsProfiles))
                } label: { Label(runCount > 0 ? String(format: L("scenarios.choose.run"), runCount) : L("scenarios.run"), systemImage: "play.fill") }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(runCount == 0)
            }
        }
        .sheetFrame(width: 880, height: 660)
        .background(Theme.raised)
        .onAppear { if chosen.isEmpty { chosen = initial.intersection(Set(profiles.map(\.id))) } }
    }

    private var summary: String {
        guard !picked.isEmpty else { return L("scenarios.choose.none") }
        let skipped = picked.count - runCount
        return skipped > 0 ? String(format: L("scenarios.choose.summary.skipped"), runCount, skipped) : String(format: L("scenarios.choose.summary"), runCount)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            LumenSearchField(text: $search, prompt: L("scenarios.choose.search"))
                .padding(.horizontal, 24)
                .padding(.top, 14)
            // A tag chooses every profile that has it; pressed again, takes them out.
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            let ids = Set(profiles.filter { $0.tags.contains(tag) }.map(\.id))
                            let isOn = !ids.isEmpty && ids.isSubset(of: chosen)
                            Button {
                                if isOn { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                            } label: {
                                HStack(spacing: 5) {
                                    if let color = tagColors.color(of: tag) { TagDot(color: color, size: 6) }
                                    Text(tag)
                                    Text(verbatim: "\(ids.count)").foregroundStyle(Theme.textTertiary).monospacedDigit()
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(isOn ? Theme.accentTintStrong : Color.clear))
                                .overlay(Capsule().strokeBorder(isOn ? Theme.edge : Theme.strongBorder, lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 10)
            }
            HStack(spacing: 10) {
                let all = Set(shown.map(\.id))
                Toggle(String(format: L("scenarios.choose.count"), chosen.count, profiles.count), isOn: Binding(get: { !all.isEmpty && all.isSubset(of: chosen) },
                                                                                                             set: { on in if on { chosen.formUnion(all) } else { chosen.subtract(all) } }))
                    .toggleStyle(.lumenCheckbox)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                Spacer()
                if !names.isEmpty { Text(L("scenarios.choose.values")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.horizontal, 24)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .padding(.top, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { profile in
                        let lacks = missing(profile)
                        Button {
                            if chosen.contains(profile.id) { chosen.remove(profile.id) } else { chosen.insert(profile.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Toggle("", isOn: .constant(chosen.contains(profile.id))).toggleStyle(LumenCheckboxStyle(showsLabel: false)).allowsHitTesting(false)
                                ProfileAvatar(name: profile.name, id: profile.id, size: 22, style: profile.avatar, running: profile.isRunning)
                                Text(profile.name).font(.lumenLabel).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                TagLine.text(profile.tags, colors: tagColors).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                Spacer(minLength: 8)
                                if !lacks.isEmpty {
                                    Label(String(format: L("scenarios.choose.lacks"), lacks.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                                        .font(.lumenSecondary)
                                        .foregroundStyle(Theme.warning)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 24)
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .accessibilityAddTraits(chosen.contains(profile.id) ? .isSelected : [])
                    }
                    if shown.isEmpty {
                        Text(profiles.isEmpty ? L("scenarios.noProfiles") : L("scenarios.search.none")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).padding(24)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lacking.isEmpty {
                Label(String(format: L("scenarios.choose.missing"), lacking.count, names.joined(separator: ", ")), systemImage: "exclamationmark.triangle.fill")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("scenarios.choose.skip"), isOn: $skipsMissing)
                    .toggleStyle(.lumenCheckbox)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
            }
            option(L("scenarios.choose.atOnce"), note: L("scenarios.choose.atOnce.note")) {
                LumenSegmented(selection: $limit, options: ScenarioBatch.limits.map { (value: $0, title: String($0)) })
                    .accessibilityLabel(L("scenarios.choose.atOnce"))
            }
            option(L("scenarios.choose.pause"), note: L("scenarios.choose.pause.note")) {
                LumenSegmented(selection: $pause, options: [(value: 0, title: L("scenarios.choose.pause.none")), (value: 1, title: L("scenarios.choose.pause.short")),
                                                           (value: 2, title: L("scenarios.choose.pause.long"))])
                    .accessibilityLabel(L("scenarios.choose.pause"))
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("scenarios.choose.stop")).font(.lumenLabel).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(L("scenarios.choose.stop.note")).font(.lumenCaption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Toggle(L("scenarios.choose.stop"), isOn: $stopsProfiles).toggleStyle(LumenSwitchStyle(showsLabel: false))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func option<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.lumenLabel).foregroundStyle(Theme.textSecondary)
            content()
            Text(note).font(.lumenCaption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }
}

/// How one profile's run stands: a sign and its words — waiting, at work, done, failed at which
/// step and why, stopped, skipped and why.
struct ScenarioEntryState: View {
    let entry: ScenarioBatch.Entry
    /// The scenario's steps, to name the one an error's line is in.
    var steps: ScenarioSteps?

    var body: some View {
        HStack(spacing: 7) {
            switch entry.state {
            case .waiting:
                Image(systemName: "circle.dashed").foregroundStyle(Theme.textDisabled)
                Text(L("scenarios.state.waiting")).foregroundStyle(Theme.textTertiary)
            case .running:
                ProgressView().controlSize(.mini)
                Text(L("scenarios.state.running")).foregroundStyle(Theme.textPrimary)
            case .finished:
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.running)
                Text(L("scenarios.state.finished")).foregroundStyle(Theme.textPrimary)
            case .failed(let reason, let line):
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                // The inspector says the reason on lines of its own: no dash left hanging after the title.
                (Text(Self.failedTitle(line: line, steps: steps)).foregroundColor(Theme.danger).fontWeight(.medium)
                    + Text(verbatim: reason.isEmpty ? "" : " — " + ScenarioFailureText.text(reason)).foregroundColor(Theme.textSecondary))
            case .stopped:
                Image(systemName: "stop.circle").foregroundStyle(Theme.textSecondary)
                Text(L("scenarios.state.stopped")).foregroundStyle(Theme.textSecondary)
            case .skipped(let reason):
                Image(systemName: "minus.circle").foregroundStyle(Theme.textTertiary)
                Text(String(format: L("scenarios.state.skipped"), reason)).foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// "Failed at step 5", or "Failed" when the error names no line of a step.
    static func failedTitle(line: Int?, steps: ScenarioSteps?) -> String {
        guard let line, let found = steps?.step(atLine: line) else { return L("scenarios.state.failed") }
        return String(format: L("scenarios.state.failedAt"), found.index + 1)
    }

    /// A state in words alone: the table as text, CSV.
    static func words(_ state: ScenarioBatch.State) -> String {
        switch state {
        case .waiting: return L("scenarios.state.waiting")
        case .running: return L("scenarios.state.running")
        case .finished: return L("scenarios.state.finished")
        case .failed(let reason, _): return L("scenarios.state.failed") + ": " + ScenarioFailureText.text(reason)
        case .stopped: return L("scenarios.state.stopped")
        case .skipped(let reason): return String(format: L("scenarios.state.skipped"), reason)
        }
    }
}

/// A run's table: a row a profile — how its run stands, how long it took, what the scenario
/// returned — under one line that counts them; beside it, the chosen profile's steps or log.
struct ScenarioRunTable: View {
    let run: ScenarioBatch
    let scenario: Scenario?
    let profiles: [ScenarioProfile]
    let batches: ScenarioBatchCoordinator?
    var showsLog = false
    let back: () -> Void
    let again: () -> Void
    let open: (UUID) -> Void
    @State private var selected: UUID?
    @State private var logShown = false
    @State private var entered = false

    private var steps: ScenarioSteps? { scenario.map { ScenarioSteps($0.source) } }
    private var header: [String] { [L("scenarios.column.profile"), L("scenarios.column.state"), L("scenarios.column.seconds"), L("scenarios.column.result")] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                top
                ScenarioColumns(titles: [(L("scenarios.column.profile"), 220), (L("scenarios.column.state"), nil), (L("scenarios.column.time"), 96), (L("scenarios.column.result"), 170)])
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(run.entries.enumerated()), id: \.element.id) { index, entry in
                            ScenarioRow(isFirst: index == 0, isSelected: selected == entry.profileID, action: { selected = selected == entry.profileID ? nil : entry.profileID }) { _ in
                                HStack(spacing: 10) {
                                    let profile = profiles.first { $0.id == entry.profileID }
                                    ProfileAvatar(name: entry.name, id: entry.profileID, size: 24, style: profile?.avatar, running: { if case .running = entry.state { return true } else { return false } }())
                                    Text(entry.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                }
                                .frame(width: 220, alignment: .leading)
                                ScenarioEntryState(entry: entry, steps: steps).frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.duration.map { ScenarioWords.length($0) } ?? "").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).monospacedDigit().frame(width: 96, alignment: .leading)
                                Text(entry.result.map { Self.shown($0) } ?? "—").font(.system(size: 12.5)).foregroundStyle(entry.result == nil ? Theme.textDisabled : Theme.textPrimary).lineLimit(1)
                                    .frame(width: 170, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            if let entry = run.entries.first(where: { $0.profileID == selected }) {
                inspector(entry)
                    .frame(width: ProfilesScreen.inspectorWidth)
                    .lumenFrost()
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear {
            guard !entered else { return }
            entered = true
            logShown = showsLog
            // One that failed is what a person opens a run for.
            if run.entries.count == 1 || showsLog || !run.isRunning { selected = run.entries.first { if case .failed = $0.state { return true } else { return false } }?.profileID ?? (run.entries.count == 1 ? run.entries.first?.profileID : nil) }
        }
    }

    /// What a scenario returned, as a person reads it: a text without its quotes, anything else as JSON.
    static func shown(_ json: String) -> String {
        if let data = json.data(using: .utf8), let text = try? JSONDecoder().decode(String.self, from: data) { return text }
        return json
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: back) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(L("scenarios.tab.runs")).font(.lumenSecondary)
                }
            }
            .buttonStyle(.lumenGhost)
            .padding(.leading, -11)
            HStack(spacing: 8) {
                Text(run.scenarioName.isEmpty ? L("scenarios.untitled") : run.scenarioName)
                    .lumenHeadingTitle()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(L("scenarios.run.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.table(header: header, words: ScenarioEntryState.words), forType: .string)
                }
                .buttonStyle(.lumenGhost)
                Button(L("scenarios.run.csv"), action: saveCSV).buttonStyle(.lumenGhost)
                if run.isRunning {
                    Button(L("scenarios.run.stopAll")) { batches?.stop(run.id) }.buttonStyle(.lumenSecondary).disabled(run.isStopping)
                } else {
                    if !run.unsuccessful.isEmpty {
                        Button(String(format: L("scenarios.run.failedAgain"), run.unsuccessful.count)) {
                            if let id = batches?.runFailedAgain(of: run.id) { open(id) }
                        }
                        .buttonStyle(.lumenSecondary)
                    }
                    Button(L("scenarios.run.again"), action: again).buttonStyle(.lumenSecondary).disabled(scenario == nil)
                }
            }
            Text(line)
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if run.isRunning {
                LumenProgressBar(fraction: run.entries.isEmpty ? 0 : Double(run.ended) / Double(run.entries.count), width: 220)
                    .padding(.top, 4)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, ProfilesScreen.headerTrailing)
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    /// The run in one line: when and how it was started, and how its profiles stand.
    private var line: String {
        var parts = [String(format: L("scenarios.run.started.\(run.origin.rawValue)"), ScenarioWords.when(run.startedAt))]
        parts.append(String(format: L("scenarios.run.counts.done"), run.finished, run.entries.count))
        if run.failed > 0 { parts.append(String(format: L("scenarios.run.counts.failed"), run.failed)) }
        if run.skipped > 0 { parts.append(String(format: L("scenarios.run.counts.skipped"), run.skipped)) }
        if run.stopped > 0 { parts.append(String(format: L("scenarios.run.counts.stopped"), run.stopped)) }
        if run.isRunning {
            parts.append(String(format: L("scenarios.run.counts.working"), run.working, run.waiting))
        } else if let ended = run.endedAt {
            parts.append(String(format: L("scenarios.run.counts.took"), ScenarioWords.length(ended.timeIntervalSince(run.startedAt))))
        }
        return parts.joined(separator: " · ")
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = run.scenarioName + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? SecureFile.writeOwnerOnly(Data(run.csv(header: header, words: ScenarioEntryState.words).utf8), over: url)
    }

    // MARK: One profile's run

    private func inspector(_ entry: ScenarioBatch.Entry) -> some View {
        let live = batches?.lines(of: entry.profileID, in: run.id) ?? []
        let kept: [String] = live.isEmpty ? (entry.log ?? []) : live.map { String(format: "%7.1f  ", max(0, $0.at.timeIntervalSince(live[0].at))) + $0.text }
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: ProfilesScreen.inspectorTop)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name).lumenHeadingTitle().foregroundStyle(Theme.textPrimary).lineLimit(1)
                ScenarioEntryState(entry: ScenarioBatch.Entry(profileID: entry.profileID, name: entry.name, state: Self.short(entry.state)), steps: steps)
                if let duration = entry.duration {
                    Text(ScenarioWords.length(duration)).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit()
                }
                if case .failed(let reason, _) = entry.state {
                    Text(ScenarioFailureText.text(reason)).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                LumenSegmented(selection: $logShown, options: [(value: false, title: L("scenarios.editor.steps")), (value: true, title: L("scenarios.run.log"))])
                    .accessibilityLabel(L("scenarios.run.log"))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(kept.joined(separator: "\n") + "\n", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(LumenIconButtonStyle(size: 26))
                    .help(L("scenarios.log.copy"))
                    .accessibilityLabel(L("scenarios.log.copy"))
                    .disabled(kept.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if logShown {
                        if kept.isEmpty {
                            Text(L("scenarios.run.log.none")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(kept.enumerated()), id: \.offset) { _, text in
                            Text(verbatim: text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 1.5)
                        }
                    } else if let steps, steps.isCut {
                        let settings = scenario.map { ScenarioSettings($0.source).settings } ?? []
                        let failedAt: Int? = { if case .failed(_, let line) = entry.state { return line.flatMap { steps.step(atLine: $0)?.index } } else { return nil } }()
                        ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                            ScenarioStepLine(number: index + 1, step: step, settings: settings, compact: true, state: Self.mark(index, entry: entry, failedAt: failedAt))
                        }
                    } else {
                        Text(L("scenarios.editor.uncut")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The state without its reason: the inspector says the reason on lines of its own.
    private static func short(_ state: ScenarioBatch.State) -> ScenarioBatch.State {
        if case .failed(_, let line) = state { return .failed(reason: "", line: line) }
        return state
    }

    private static func mark(_ index: Int, entry: ScenarioBatch.Entry, failedAt: Int?) -> ScenarioStepLine.Mark {
        if entry.state == .finished { return .passed }
        guard let failedAt else { return .plain }
        if index < failedAt { return .passed }
        if index == failedAt, case .failed(let reason, _) = entry.state { return .failed(reason) }
        return .plain
    }
}

/// The runs kept, newest first: when, which scenario, how it was started, on how many profiles,
/// how it ended, how long it took.
struct ScenarioRunList: View {
    let runs: [ScenarioBatch]
    let search: String
    let open: (UUID) -> Void

    var body: some View {
        let shown = runs.filter { search.isEmpty || $0.scenarioName.localizedCaseInsensitiveContains(search) }
        VStack(spacing: 0) {
            ScenarioColumns(titles: [(L("scenarios.column.when"), 150), (L("scenarios.column.scenario"), nil), (L("scenarios.column.started"), 150),
                                     (L("scenarios.column.profiles"), 80), (L("scenarios.column.outcome"), 300), (L("scenarios.column.took"), 96)])
            if shown.isEmpty {
                LumenEmptyHint(symbol: "list.bullet.rectangle", text: L(runs.isEmpty ? "scenarios.runs.none" : "scenarios.search.none"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, run in
                            ScenarioRow(isFirst: index == 0, action: { open(run.id) }) { _ in
                                Text(ScenarioWords.when(run.startedAt)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1).frame(width: 150, alignment: .leading)
                                Text(run.scenarioName.isEmpty ? L("scenarios.untitled") : run.scenarioName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(L("scenarios.run.origin.\(run.origin.rawValue)")).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(width: 150, alignment: .leading)
                                Text(verbatim: run.entries.count == 1 ? run.entries[0].name : "\(run.entries.count)").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1)
                                    .frame(width: 80, alignment: .leading)
                                ScenarioOutcomeLabel(run: run).frame(width: 300, alignment: .leading)
                                Text(run.endedAt.map { ScenarioWords.length($0.timeIntervalSince(run.startedAt)) } ?? "").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                    .frame(width: 96, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}
