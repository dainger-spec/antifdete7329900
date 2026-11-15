import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// The Profiles window's Scenarios section (docs/AUTOMATION.md): the person's scenarios, the
/// templates, the runs and the schedules — four tabs under the window's own header — and, in
/// their place, a scenario being edited or a run's table.
///
/// Built as the Profiles and Proxies lists are: rows on separators under column titles, the
/// header's title, count line, search and main button. What it shows is the model's; `sample`
/// stands in for it where there is no vault (the UI snapshots).
struct ScenariosSection: View {
    enum Tab: Hashable { case library, templates, runs, schedule }

    /// What is on screen in the tabs' place.
    enum Place: Equatable {
        case tabs
        case editor(UUID)
        case run(UUID)
    }

    /// The section's content without a vault: what the snapshots draw.
    struct Sample {
        var scenarios: [Scenario] = []
        var profiles: [ScenarioProfile] = []
        var runs: [ScenarioBatch] = []
        var tab: Tab = .library
        var place: Place = .tabs
        /// A template's form, a run's chooser, open over the screen.
        var template: String?
        var choosing = false
        var recording: [RecordedStep]?
        var editorMode: ScenarioEditor.Mode = .both
        var showsLog = false
    }

    var sample: Sample?

    var body: some View {
        ScenariosSectionBody(sample: sample)
    }
}

/// A profile as the scenario screens show it.
struct ScenarioProfile: Identifiable, Equatable {
    var id: UUID
    var name: String
    var tags: [String] = []
    var avatar: ProfileAvatarStyle?
    var isRunning = false
    /// The names it has a text for (`ScenarioValues`).
    var values: Set<String> = []
}

private struct ScenariosSectionBody: View {
    typealias Tab = ScenariosSection.Tab
    typealias Place = ScenariosSection.Place

    let sample: ScenariosSection.Sample?
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var tab: Tab = .library
    @State private var place: Place = .tabs
    @State private var search = ""
    @State private var template: ScenarioTemplate?
    @State private var choosingFor: Scenario?
    @State private var reviewing: ScenarioFile?
    @State private var pendingDelete: Scenario?
    @State private var entered = false
    /// The schedule the Schedule tab opens its form with: "On a Schedule…" of a scenario.
    @State private var proposed: ScenarioSchedule?

    private var scenarios: [Scenario] { sample?.scenarios ?? model.scenarios.sorted }
    private var allowed: Bool { sample != nil || model.allowsAutomation }
    private var profiles: [ScenarioProfile] {
        if let sample { return sample.profiles }
        return model.profiles.map { profile in
            ScenarioProfile(id: profile.id, name: profile.name, tags: model.details[profile.id]?.tags ?? [], avatar: model.details[profile.id]?.avatar,
                            isRunning: model.isRunning(profile.id),
                            values: Set(model.scenarioValues.values(of: profile.id).filter { !$0.value.isEmpty }.map(\.name)))
        }
    }

    var body: some View {
        ScenarioRunsReader(sample: sample?.runs) { runs, batches in
            content(runs: runs, batches: batches)
        }
        .onAppear {
            // A recording going on is of its own scenario: the section shown again shows that one,
            // where Stop is — not the list.
            if sample == nil, model.recordingProfile != nil {
                if let recording = model.recordingScenario, model.scenarios.scenario(recording) != nil {
                    place = .editor(recording)
                } else {
                    // Its scenario is gone: there is nowhere for its steps to go, and no Stop to press.
                    _ = model.stopRecording()
                }
            }
            guard !entered, let sample else { return }
            entered = true
            tab = sample.tab
            place = sample.place
            template = sample.template.flatMap { ScenarioTemplate.template($0) }
            if sample.choosing { choosingFor = sample.scenarios.first }
        }
        // A scenario that is gone (deleted, the vault locked) is not left on screen.
        .onChange(of: scenarios.map(\.id)) { _, ids in
            if case .editor(let id) = place, !ids.contains(id) { place = .tabs }
        }
        .sheet(item: $template) { template in
            ScenarioTemplateForm(template: template, taken: scenarios.map(\.name)) { scenario in
                self.template = nil
                if sample == nil, model.saveScenario(scenario) { place = .editor(scenario.id) }
            }
        }
        .sheet(item: $choosingFor) { scenario in
            ScenarioRunChooser(scenario: scenario, profiles: profiles, initial: Set(sample == nil ? model.scenarioProfilesRequest : [])) { request in
                choosingFor = nil
                guard sample == nil else { return }
                model.scenarioProfilesRequest = []
                let id = model.scenarioBatches.start(scenario, on: request.profiles, skipped: request.skipped, limit: request.limit,
                                                    pause: request.pause, stopsProfiles: request.stopsProfiles)
                place = .run(id)
            }
        }
        .sheet(item: $reviewing) { file in
            ScenarioImportReview(file: file) {
                reviewing = nil
                let scenario = Scenario(name: model.scenarios.freeName(file.name.isEmpty ? L("scenarios.untitled") : file.name), source: file.source, note: file.note)
                if model.saveScenario(scenario) { place = .editor(scenario.id) }
            }
        }
        .confirmationDialog(String(format: L("scenarios.delete.question"), pendingDelete?.name ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { scenario in
            Button(L("scenarios.delete"), role: .destructive) { model.saveScenario(scenario, remove: true) }
        }
    }

    @ViewBuilder
    private func content(runs: [ScenarioBatch], batches: ScenarioBatchCoordinator?) -> some View {
        switch place {
        case .editor(let id):
            if let scenario = scenarios.first(where: { $0.id == id }) {
                ScenarioEditor(scenario: scenario, profiles: profiles, allowed: allowed, sample: sample,
                               back: { place = .tabs }, run: { choosingFor = $0 }, openRun: { place = .run($0) },
                               schedule: { scheduled, profile in
                                   // One that is there already is in the list, with its Edit: a second form would add its twin.
                                   let action = ScenarioSchedule.Action.scenario(scheduled.id)
                                   let exists = profile.map { id in model.scenarioSchedules.schedules.contains { $0.action == action && $0.profileID == id } } ?? true
                                   proposed = exists ? nil : profile.map { ScenarioSchedule(action: action, profileID: $0, when: .daily(hour: 10, minute: 0), jitterMinutes: 15) }
                                   tab = .schedule
                                   place = .tabs
                               })
                    .id(id)
            }
        case .run(let id):
            if let run = runs.first(where: { $0.id == id }) {
                ScenarioRunTable(run: run, scenario: scenarios.first { $0.id == run.scenarioID }, profiles: profiles, batches: batches,
                                 showsLog: sample?.showsLog ?? false, back: { tab = .runs; place = .tabs },
                                 again: { if let scenario = scenarios.first(where: { $0.id == run.scenarioID }) { choosingFor = scenario } },
                                 open: { place = .run($0) })
                    .id(id)
            }
        case .tabs:
            VStack(spacing: 0) {
                header(runs: runs)
                tabs(runs: runs)
                if !allowed {
                    LumenBanner(tone: .warning) {
                        Text(L("scenarios.notInPlan")).font(.lumenBody).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 10)
                }
                // Profiles selected in the Profiles list for a scenario: said, until one is run on them.
                if sample == nil, !model.scenarioProfilesRequest.isEmpty {
                    HStack(spacing: 8) {
                        Text(String(format: L("scenarios.forProfiles"), model.scenarioProfilesRequest.count))
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button(L("common.cancel")) { model.scenarioProfilesRequest = [] }.buttonStyle(.lumenGhost)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
                }
                switch tab {
                case .library:
                    if scenarios.isEmpty { ScenariosFirstOpen(choose: begin, take: { template = $0 }) } else { library(runs: runs) }
                case .templates:
                    ScenarioTemplateChooser(search: search, use: { template = $0 }, openCode: { taken in
                        guard sample == nil else { return }
                        let scenario = Scenario(name: model.scenarios.freeName(L(taken.titleKey)), source: taken.source { L(ScenarioTemplate.wordKey($0)) }, templateID: taken.id)
                        if model.saveScenario(scenario) { place = .editor(scenario.id) }
                    }, record: { begin(.record) })
                case .runs: ScenarioRunList(runs: runs, search: search) { place = .run($0) }
                case .schedule: ScenarioSchedulesPane(sample: scheduleSample, proposed: proposed, embedded: true)
                }
            }
        }
    }

    private var scheduleSample: ScenarioSchedulesPane.Sample? {
        guard let sample else { return nil }
        return ScenarioSchedulesPane.Sample(schedules: [], scenarios: sample.scenarios, profiles: sample.profiles.map { profile in (id: profile.id, name: profile.name) }, editing: nil)
    }

    // MARK: The header and the tabs

    private func header(runs: [ScenarioBatch]) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("scenarios.title"))
                    .lumenPageTitle()
                    .foregroundStyle(Theme.textPrimary)
                Text(countLine(runs: runs))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 12)
            if tab != .schedule, !(tab == .library && scenarios.isEmpty) {
                LumenSearchField(text: $search, prompt: L("scenarios.search"))
                    .frame(maxWidth: 280)
            }
            MoreMenu {
                Button(L("scenarios.import")) { importFile() }
                Divider()
                Button(L("settings.section.automation")) { model.settingsSection = .automation; openSettings() }
                Button(L("scenarios.help.how")) { model.helpTopic = .scenarios; openWindow(id: "help") }
            }
            Menu {
                Button(L("scenarios.new.template")) { tab = .templates }
                Button(L("scenarios.new.record")) { begin(.record) }
                Button(L("scenarios.new.empty")) { begin(.empty) }
            } label: {
                ScenarioMenuLabel(title: L("scenarios.new"), symbol: "plus", isMain: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: ProfilesScreen.headerHeight)
        .padding(.leading, 28)
        .padding(.trailing, ProfilesScreen.headerTrailing)
        .padding(.top, ProfilesScreen.headerTop)
        .padding(.bottom, 16)
    }

    private func countLine(runs: [ScenarioBatch]) -> String {
        guard !scenarios.isEmpty else { return L("scenarios.count.none") }
        var parts = [String(format: L("scenarios.count"), scenarios.count)]
        let scheduled = Set((sample == nil ? model.scenarioSchedules.schedules : []).compactMap { schedule -> UUID? in
            if case .scenario(let id) = schedule.action, schedule.isEnabled { return id }
            return nil
        }).count
        if scheduled > 0 { parts.append(String(format: L("scenarios.count.scheduled"), scheduled)) }
        let going = runs.filter(\.isRunning).count
        if going > 0 { parts.append(String(format: L("scenarios.count.running"), going)) }
        return parts.joined(separator: " · ")
    }

    private func tabs(runs: [ScenarioBatch]) -> some View {
        HStack(spacing: 10) {
            LumenSegmented(selection: $tab, options: [
                (value: Tab.library, title: L("scenarios.tab.library")), (value: Tab.templates, title: L("scenarios.tab.templates")),
                (value: Tab.runs, title: L("scenarios.tab.runs")), (value: Tab.schedule, title: L("schedule.title")),
            ], large: true)
            .accessibilityLabel(L("scenarios.title"))
            if runs.contains(where: \.isRunning) {
                HStack(spacing: 6) {
                    RunningDot()
                    Text(L("scenarios.running")).font(.lumenSecondary).foregroundStyle(Theme.running)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    // MARK: Мои сценарии

    private func library(runs: [ScenarioBatch]) -> some View {
        let shown = scenarios.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.folder ?? "").localizedCaseInsensitiveContains(search) }
        let folders = Array(Set(shown.map { $0.folder ?? "" })).sorted { $0.isEmpty ? false : ($1.isEmpty ? true : $0.localizedStandardCompare($1) == .orderedAscending) }
        return VStack(spacing: 0) {
            ScenarioColumns(titles: [(L("scenarios.column.name"), nil), (L("scenarios.column.lastRun"), 300), (L("schedule.title"), 230), ("", 64)])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(folders, id: \.self) { folder in
                        if folders.count > 1 || !folder.isEmpty {
                            Text(folder.isEmpty ? L("scenarios.folder.none") : folder)
                                .font(.lumenLabel)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, ProfileColumns.rowPadding)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                        }
                        let rows = shown.filter { ($0.folder ?? "") == folder }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, scenario in
                            ScenarioLibraryRow(scenario: scenario, last: runs.first { $0.scenarioID == scenario.id }, schedule: scheduleText(scenario),
                                               folders: model.scenarios.folders, isFirst: index == 0,
                                               open: { place = .editor(scenario.id) }, run: { choosingFor = scenario },
                                               duplicate: { model.saveScenario(model.scenarios.copy(of: scenario)) },
                                               move: { folder in var moved = scenario; moved.folder = folder; model.saveScenario(moved) },
                                               export: { exportFile(scenario) }, delete: { pendingDelete = scenario })
                        }
                    }
                    if shown.isEmpty {
                        Text(L("scenarios.search.none")).font(.lumenBody).foregroundStyle(Theme.textTertiary).padding(ProfileColumns.rowPadding).padding(.top, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    /// "daily at 10:00 · 12 profiles": the scenario's schedules that are on, as one line.
    private func scheduleText(_ scenario: Scenario) -> String? {
        guard sample == nil else { return nil }
        let own = model.scenarioSchedules.schedules.filter { $0.action == .scenario(scenario.id) && $0.isEnabled }
        guard let first = own.first else { return nil }
        let when = ScenarioSchedulesPane.whenText(first)
        return own.count > 1 ? String(format: L("scenarios.schedule.several"), when, own.count) : when
    }

    // MARK: A new scenario, a file

    enum Beginning { case record, empty }

    private func begin(_ how: Beginning) {
        guard sample == nil else { return }
        let scenario = Scenario(name: model.scenarios.freeName(L("scenarios.untitled")), source: how == .empty ? L("scenarios.template") : "")
        if model.saveScenario(scenario) { place = .editor(scenario.id) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ScenarioFile.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= ScenarioFile.maximumBytes,
              let data = try? Data(contentsOf: url) else {
            model.showError(L("scenarios.import.refused.notAScenario"))
            return
        }
        switch ScenarioFile.read(data) {
        case .success(let file): reviewing = file
        case .failure(.newer): model.showError(L("scenarios.import.refused.newer"))
        case .failure: model.showError(L("scenarios.import.refused.notAScenario"))
        }
    }

    private func exportFile(_ scenario: Scenario) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = scenario.name + "." + ScenarioFile.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try SecureFile.writeOwnerOnly(try ScenarioFile(scenario).data(), over: url)
        } catch {
            model.showError(String(format: L("scenarios.export.failed"), error.localizedDescription))
        }
    }
}

extension ScenarioFile: Identifiable {
    public var id: String { name + "\u{1F}" + String(source.count) }
}

/// The runs: the coordinator's (observed, so a run's rows change as it goes), or the sample's.
struct ScenarioRunsReader<Content: View>: View {
    let sample: [ScenarioBatch]?
    @ViewBuilder let content: ([ScenarioBatch], ScenarioBatchCoordinator?) -> Content
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let sample {
            content(sample, nil)
        } else {
            Observed(batches: model.scenarioBatches, content: content)
        }
    }

    private struct Observed: View {
        @ObservedObject var batches: ScenarioBatchCoordinator
        let content: ([ScenarioBatch], ScenarioBatchCoordinator?) -> Content
        var body: some View { content(batches.history.runs, batches) }
    }
}

/// A menu's label drawn as the design's contour button (a menu takes no button style of ours).
struct ScenarioMenuLabel: View {
    let title: String
    var symbol: String?
    var isMain = false

    var body: some View {
        let height: CGFloat = isMain ? Theme.buttonHeight : Theme.controlHeight
        let shape = RoundedRectangle(cornerRadius: isMain ? Theme.cornerRadius : Theme.controlRadius, style: .continuous)
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(isMain ? Font.lumenLabel : Font.system(size: 12.5, weight: .medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, isMain ? 14 : 11)
        .frame(height: height)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
        .contentShape(shape)
    }
}

/// A list's column titles, as the Profiles list has them: capitals, a separator under them. A
/// column without a width takes what is left.
struct ScenarioColumns: View {
    let titles: [(String, CGFloat?)]

    var body: some View {
        HStack(spacing: ProfileColumns.gap) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, column in
                Text(column.0)
                    .lumenCaps()
                    .lineLimit(1)
                    .frame(width: column.1, alignment: .leading)
                    .frame(maxWidth: column.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, ProfileColumns.rowPadding)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .padding(.horizontal, 20)
    }
}

/// A row of a scenario list: its cells on a separator, the tone of a row under the pointer.
struct ScenarioRow<Content: View>: View {
    var height: CGFloat = 44
    var isFirst = false
    var isSelected = false
    var action: (() -> Void)?
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: ProfileColumns.gap) { content(hovered) }
            .padding(.horizontal, ProfileColumns.rowPadding)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(isSelected ? Theme.rowSelected : (hovered ? Theme.rowHover : Color.clear)))
            .overlay(alignment: .top) {
                if !isFirst, !hovered, !isSelected { Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, ProfileColumns.rowPadding) }
            }
            .contentShape(Rectangle())
            .onTapGesture { action?() }
            .onHover { hovered = $0 }
            .animation(Motion.hover(hovered), value: hovered)
    }
}

/// How a run ended, in a line: a sign for the state and its words.
struct ScenarioOutcomeLabel: View {
    let run: ScenarioBatch

    var body: some View {
        HStack(spacing: 7) {
            if run.isRunning {
                RunningDot()
                Text(String(format: L("scenarios.run.going"), run.ended, run.entries.count)).foregroundStyle(Theme.running)
            } else if run.failed > 0 {
                Image(systemName: run.finished > 0 ? "exclamationmark.triangle" : "xmark.circle").foregroundStyle(run.finished > 0 ? Theme.warning : Theme.danger)
                Text(String(format: L("scenarios.run.someFailed"), run.finished, run.entries.count, run.failed)).foregroundStyle(Theme.textPrimary)
            } else if run.stopped > 0 {
                Image(systemName: "stop.circle").foregroundStyle(Theme.textSecondary)
                Text(String(format: L("scenarios.run.wasStopped"), run.finished, run.entries.count)).foregroundStyle(Theme.textPrimary)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.running)
                Text(String(format: L("scenarios.run.done"), run.finished, run.entries.count)).foregroundStyle(Theme.textPrimary)
            }
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .lineLimit(1)
    }
}

enum ScenarioWords {
    /// "today, 12:04" or "12 Nov, 16:40". On one line: check_localization.py looks for the interface's locale on the line of `.formatted(`.
    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(format: L("scenarios.when.today"), date.formatted(.dateTime.hour().minute().locale(Localization.locale))) }
        if Calendar.current.isDateInYesterday(date) { return String(format: L("scenarios.when.yesterday"), date.formatted(.dateTime.hour().minute().locale(Localization.locale))) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Localization.locale))
    }

    /// "38 s", "6 min 40 s".
    static func length(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? String(format: L("scenarios.length.seconds"), whole) : String(format: L("scenarios.length.minutes"), whole / 60, whole % 60)
    }

    /// A scenario's line under its name: "6 steps · takes login, password".
    static func summary(_ scenario: Scenario) -> String {
        let cut = ScenarioSteps(scenario.source)
        var parts = [cut.isCut ? String(format: L("scenarios.steps.count"), cut.steps.count) : L("scenarios.steps.code")]
        let names = ScenarioValues.namesRead(by: scenario.source)
        if !names.isEmpty { parts.append(String(format: L("scenarios.takes"), names.joined(separator: ", "))) }
        return parts.joined(separator: " · ")
    }
}

private struct ScenarioLibraryRow: View {
    let scenario: Scenario
    let last: ScenarioBatch?
    let schedule: String?
    let folders: [String]
    let isFirst: Bool
    let open: () -> Void
    let run: () -> Void
    let duplicate: () -> Void
    let move: (String?) -> Void
    let export: () -> Void
    let delete: () -> Void
    @State private var naming = false
    @State private var folderName = ""

    var body: some View {
        ScenarioRow(height: 48, isFirst: isFirst, action: open) { hovered in
            HStack(spacing: 10) {
                Text(scenario.name.isEmpty ? L("scenarios.untitled") : scenario.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(ScenarioWords.summary(scenario))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let last {
                    HStack(spacing: 6) {
                        ScenarioOutcomeLabel(run: last)
                        if !last.isRunning { Text("· " + ScenarioWords.when(last.startedAt)).font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                    }
                } else {
                    Text(L("scenarios.run.never")).font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 300, alignment: .leading)
            Text(schedule ?? "—")
                .font(.system(size: 12.5))
                .foregroundStyle(schedule == nil ? Theme.textDisabled : Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 230, alignment: .leading)
            HStack(spacing: 2) {
                Button(action: run) { Image(systemName: "play.fill") }
                    .buttonStyle(LumenIconButtonStyle(size: 28))
                    .help(L("scenarios.run.on"))
                    .accessibilityLabel(L("scenarios.run.on"))
                MoreMenu(side: 28) { menu }
            }
            .frame(width: 64, alignment: .trailing)
            .opacity(hovered ? 1 : 0.35)
        }
        .contextMenu { menu }
        .alert(L("scenarios.folder.new"), isPresented: $naming) {
            TextField(L("scenarios.folder.name"), text: $folderName)
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.save")) {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { move(String(name.prefix(60))) }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(L("scenarios.run.on"), action: run)
        Button(L("scenarios.open"), action: open)
        Divider()
        Button(L("scenarios.duplicate"), action: duplicate)
        Menu(L("scenarios.folder.move")) {
            ForEach(folders, id: \.self) { folder in
                Button(folder) { move(folder) }.disabled(folder == scenario.folder)
            }
            if !folders.isEmpty { Divider() }
            Button(L("scenarios.folder.new")) { folderName = ""; naming = true }
            if scenario.folder != nil { Button(L("scenarios.folder.out")) { move(nil) } }
        }
        Button(L("scenarios.export"), action: export)
        Divider()
        Button(L("scenarios.delete"), role: .destructive, action: delete)
    }
}

// MARK: - The first opening

/// No scenario yet: what one is, in two sentences, and the ways to the first — rows, as the lists are.
private struct ScenariosFirstOpen: View {
    let choose: (ScenariosSectionBody.Beginning) -> Void
    let take: (ScenarioTemplate) -> Void
    private static let first = ["signin", "signedin", "feed", "collect"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("scenarios.first.text"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, ProfileColumns.rowPadding)
                    .padding(.bottom, 14)
                caption(L("scenarios.first.ways"))
                way(L("scenarios.first.record"), L("scenarios.first.record.text"), isFirst: true) { choose(.record) }
                way(L("scenarios.first.code"), L("scenarios.first.code.text")) { choose(.empty) }
                caption(L("scenarios.first.templates"))
                ForEach(Array(Self.first.compactMap { ScenarioTemplate.template($0) }.enumerated()), id: \.element.id) { index, template in
                    way(L(template.titleKey), L(template.textKey), isFirst: index == 0) { take(template) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.lumenLabel).foregroundStyle(Theme.textSecondary).padding(.horizontal, ProfileColumns.rowPadding).padding(.top, 14).padding(.bottom, 4)
    }

    private func way(_ title: String, _ text: String, isFirst: Bool = false, action: @escaping () -> Void) -> some View {
        ScenarioRow(isFirst: isFirst, action: action) { _ in
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).frame(width: 300, alignment: .leading)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Templates

/// The templates as a chooser: on the left their names by kind, on the right the chosen one
/// itself — what it does, its real steps in words, what it asks for and what it takes from each
/// profile — so that a person sees what will happen before taking it.
struct ScenarioTemplateChooser: View {
    let search: String
    /// The template shown at first (the snapshots); nil: the first of the list.
    var initial: String?
    let use: (ScenarioTemplate) -> Void
    let openCode: (ScenarioTemplate) -> Void
    let record: () -> Void
    @State private var chosenID: String?
    @FocusState private var listFocused: Bool

    private var shown: [ScenarioTemplate] {
        ScenarioTemplate.Group.allCases.flatMap { group in
            ScenarioTemplate.all.filter { $0.group == group && (search.isEmpty || L($0.titleKey).localizedCaseInsensitiveContains(search) || L($0.textKey).localizedCaseInsensitiveContains(search)) }
        }
    }
    private var chosen: ScenarioTemplate? { shown.first { $0.id == chosenID } ?? shown.first }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                list
                    .frame(width: 320)
                Rectangle().fill(Theme.divider).frame(width: 1)
                if let chosen {
                    detail(chosen)
                } else {
                    LumenEmptyHint(symbol: "magnifyingglass", text: L("scenarios.search.none"))
                }
            }
        }
        .onAppear { if chosenID == nil { chosenID = initial } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ScenarioTemplate.Group.allCases, id: \.self) { group in
                    let rows = shown.filter { $0.group == group }
                    if !rows.isEmpty {
                        Text(L("scenarios.template.group.\(group.rawValue)"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(rows) { template in
                            let isOn = template.id == chosen?.id
                            Button { chosenID = template.id } label: {
                                Text(L(template.titleKey))
                                    .font(.system(size: 15))
                                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isOn ? Theme.rowSelected : Color.clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(cornerRadius: 9, isOn: !isOn)
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                }
                // Nothing fits: the way to a scenario of one's own.
                Button(action: record) {
                    Text(L("scenarios.template.none"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 9)
                .padding(.top, 12)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        // The arrow keys move the choice, as in a list.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = shown
            guard let index = all.firstIndex(where: { $0.id == chosen?.id }) else { return }
            if direction == .down, index + 1 < all.count { chosenID = all[index + 1].id }
            if direction == .up, index > 0 { chosenID = all[index - 1].id }
        }
        .onAppear { listFocused = true }
    }

    private func detail(_ template: ScenarioTemplate) -> some View {
        let source = template.source { L(ScenarioTemplate.wordKey($0)) }
        let settings = ScenarioSettings(source).settings
        let steps = ScenarioSteps(source).steps
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L(template.titleKey))
                        .lumenHeadingTitle()
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("scenarios.template.\(template.id).about"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    caption(L("scenarios.editor.steps"))
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        ScenarioStepLine(number: index + 1, step: step, settings: [], compact: true)
                    }
                    caption(L("scenarios.template.asks"))
                    ForEach(template.parameters.filter { !$0.isAdvanced }, id: \.name) { parameter in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(settings.first { $0.name == parameter.name }?.label ?? parameter.name)
                                .font(.lumenBody)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 250, alignment: .leading)
                            Text(L(parameter.isOptional ? "scenarios.template.optional" : "scenarios.template.required"))
                                .font(.lumenBody)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 5)
                    }
                    if !template.takes.isEmpty {
                        caption(L("scenarios.column.takes"))
                        Text(String(format: L("scenarios.template.takes"), template.takes.joined(separator: ", ")))
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("scenarios.template.code")) { openCode(template) }
                    .buttonStyle(.lumenGhost)
                Button(L("scenarios.template.use")) { use(template) }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, ProfilesScreen.headerTrailing)
            .padding(.vertical, 14)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.lumenLabel).foregroundStyle(Theme.textSecondary).padding(.top, 24).padding(.bottom, 6)
    }
}

/// A template being filled in: its questions on the left, the steps the scenario will have on
/// the right, as they are answered.
struct ScenarioTemplateForm: View {
    let template: ScenarioTemplate
    /// The names taken already: the new scenario gets a free one.
    let taken: [String]
    let create: (Scenario) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var values: [String: ScenarioSettings.Value] = [:]
    @State private var namesFields = false

    /// The scenario's text with the form's answers.
    private var source: String { template.source(settings: values) { L(ScenarioTemplate.wordKey($0)) } }
    private var settings: [ScenarioSettings.Setting] { ScenarioSettings(source).settings }
    private var hasAdvanced: Bool { template.parameters.contains(where: \.isAdvanced) }

    /// What stops Create, in words: an address that is not one, a question left unanswered.
    private var problem: String? {
        for parameter in template.parameters where !parameter.isOptional && (!parameter.isAdvanced || namesFields) {
            guard let setting = settings.first(where: { $0.name == parameter.name }) else { continue }
            switch (parameter.field, setting.value) {
            case (.address, .text(let text)):
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else {
                    return String(format: L("scenarios.form.problem.address"), setting.label)
                }
            case (_, .text(let text)) where text.trimmingCharacters(in: .whitespaces).isEmpty:
                return String(format: L("scenarios.form.problem.empty"), setting.label)
            case (_, .list(let items)) where items.isEmpty:
                return String(format: L("scenarios.form.problem.empty"), setting.label)
            default: break
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: L(template.titleKey), subtitle: L(template.textKey))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            row(L("scenarios.name")) {
                                TextField(L("scenarios.name"), text: $name, prompt: Text(verbatim: "")).lumenField()
                            }
                            ForEach(template.parameters.filter { !$0.isAdvanced || namesFields }, id: \.name) { parameter in
                                if let setting = settings.first(where: { $0.name == parameter.name }) {
                                    row(setting.label) {
                                        ScenarioSettingField(field: parameter.field, value: Binding(get: { setting.value }, set: { values[parameter.name] = $0 }))
                                        if let hint = hint(parameter) {
                                            Text(hint).font(.lumenCaption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                            if hasAdvanced {
                                Toggle(L("scenarios.form.nameFields"), isOn: $namesFields)
                                    .toggleStyle(.lumenCheckbox)
                                    .font(.lumenBody)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.leading, 182)
                            }
                            if !template.takes.isEmpty {
                                Text(String(format: L("scenarios.form.takes"), template.takes.joined(separator: ", ")))
                                    .font(.lumenSecondary)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("scenarios.form.steps"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 8)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let steps = ScenarioSteps(source).steps
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                ScenarioStepLine(number: index + 1, step: step, settings: settings, compact: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .frame(width: 320)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.raisedInset)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
            }
            SheetFooter {
                if let problem {
                    Text(problem).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            } buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("scenarios.form.create")) {
                    let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    create(Scenario(name: ScenarioLibrary(scenarios: taken.map { Scenario(name: $0, source: "") }).freeName(base.isEmpty ? L(template.titleKey) : base),
                                    source: source, templateID: template.id))
                }
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .sheetFrame(width: 900, height: 640)
        .background(Theme.raised)
        .onAppear { if name.isEmpty { name = L(template.titleKey) } }
    }

    private func hint(_ parameter: ScenarioTemplate.Parameter) -> String? {
        switch parameter.field {
        case .selector: return L(parameter.isOptional ? "scenarios.form.hint.selector.optional" : "scenarios.form.hint.selector")
        case .lines: return L("scenarios.form.hint.lines.\(parameter.name)")
        default: return nil
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.lumenLabel)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 168, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A setting's field: a line of text, a number, lines of text, a choice.
struct ScenarioSettingField: View {
    var field: ScenarioTemplate.Field?
    @Binding var value: ScenarioSettings.Value

    var body: some View {
        switch value {
        case .text(let text):
            if case .choice(let options)? = field {
                Picker("", selection: Binding(get: { text }, set: { value = .text($0) })) {
                    ForEach(options.contains(text) ? options : options + [text], id: \.self) { option in
                        Text(verbatim: URL(string: option)?.host ?? option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            } else {
                TextField("", text: Binding(get: { text }, set: { value = .text($0) }), prompt: Text(verbatim: ""))
                    .lumenField()
                    .font(isCode ? .lumenMono : .lumenBody)
            }
        case .number(let number):
            TextField("", text: Binding(get: { ScenarioSettings.Value.number(number).code }, set: { typed in
                guard let parsed = Double(typed.replacingOccurrences(of: ",", with: ".")), parsed.isFinite else { return }
                if case .number(let range)? = field { value = .number(min(max(parsed.rounded(), Double(range.lowerBound)), Double(range.upperBound))) } else { value = .number(parsed) }
            }), prompt: Text(verbatim: ""))
                .lumenField()
                .monospacedDigit()
                .frame(width: 90)
        case .flag(let flag):
            Toggle("", isOn: Binding(get: { flag }, set: { value = .flag($0) }))
                .toggleStyle(LumenSwitchStyle(showsLabel: false))
        case .list(let items):
            TextField("", text: Binding(get: { items.joined(separator: "\n") }, set: { typed in
                value = .list(typed.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }), prompt: Text(verbatim: ""), axis: .vertical)
                .lineLimit(3...8)
                .lumenField(height: nil)
        }
    }

    private var isCode: Bool {
        if case .selector? = field { return true }
        return false
    }
}

/// What a scenario from someone else will do, before it is added: its steps, the sites it names,
/// the profile's values it reads.
struct ScenarioImportReview: View {
    let file: ScenarioFile
    let add: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cut = ScenarioSteps(file.source)
        let names = ScenarioValues.namesRead(by: file.source)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("scenarios.import.title"), file.name), subtitle: L("scenarios.import.subtitle"))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    fact(L("scenarios.import.sites"), file.hosts.isEmpty ? L("scenarios.import.sites.none") : file.hosts.joined(separator: ", "))
                    fact(L("scenarios.import.values"), names.isEmpty ? "—" : names.joined(separator: ", "))
                    Text(cut.isCut ? String(format: L("scenarios.steps.count"), cut.steps.count) : L("scenarios.steps.code"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                    if cut.isCut {
                        let settings = ScenarioSettings(file.source).settings
                        ForEach(Array(cut.steps.enumerated()), id: \.offset) { index, step in
                            ScenarioStepLine(number: index + 1, step: step, settings: settings, compact: true)
                        }
                    } else {
                        Text(verbatim: String(file.source.prefix(4000))).font(.lumenMono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("scenarios.import.add"), action: add)
                    .buttonStyle(.lumenPrimary)
            }
        }
        .sheetFrame(width: 620, height: 600)
        .background(Theme.raised)
    }

    private func fact(_ name: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name).font(.lumenLabel).foregroundStyle(Theme.textSecondary).frame(width: 168, alignment: .leading)
            Text(text).font(.lumenBody).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
