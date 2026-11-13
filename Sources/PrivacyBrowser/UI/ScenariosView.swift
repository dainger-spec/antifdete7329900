import AppKit
import BrowserCore
import SwiftUI

/// The scenario editor (docs/AUTOMATION.md): the vault's scenarios on the left; the chosen one's
/// name and JavaScript on the right, a profile to run it on, Run and Stop, and the run's log.
struct ScenariosView: View {
    /// A scenario shown as the chosen one without a vault (the snapshots).
    var sample: Scenario?
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// The commands beside the code, as the person left them.
    @AppStorage("scenarios.commands") private var showsCommands = true
    @State private var selection: UUID?
    @State private var name = ""
    @State private var source = ""
    @State private var profileID: UUID?
    @State private var confirmingDelete = false
    @State private var starting = false
    /// The right side shows the runs by the clock instead of a scenario.
    @State private var showingSchedules: Bool
    /// The schedule that side opens its form with: "On a Schedule…" of the scenario on screen.
    @State private var proposedSchedule: ScenarioSchedule?
    /// Steps shown as being recorded without a profile (the snapshots).
    var sampleRecording: [RecordedStep]?
    /// Lumen's light at entry (Settings → Appearance): the still eclipse behind the window.
    @ObservedObject private var appearance = AppearancePreferences.shared

    init(sample: Scenario? = nil, sampleRecording: [RecordedStep]? = nil, showingSchedules: Bool = false) {
        self.sample = sample
        self.sampleRecording = sampleRecording
        _showingSchedules = State(initialValue: showingSchedules)
    }

    /// A recording is going on, in the profile chosen here or in another.
    private var isRecording: Bool { sampleRecording != nil || model.recordingProfile != nil }
    /// A recording is going on, and its profile no longer runs.
    private var recordingStopped: Bool {
        guard let id = model.recordingProfile else { return false }
        return !model.isRunning(id)
    }
    private var recordedSteps: [RecordedStep] { sampleRecording ?? model.recorded.steps }

    private var selected: Scenario? { sample ?? selection.flatMap { model.scenarios.scenario($0) } }
    private var listed: [Scenario] { sample.map { [$0] } ?? model.scenarios.sorted }
    private var edited: Bool { selected.map { $0.name != name || $0.source != source } ?? false }
    private var run: ProfileManager.ScenarioRunState? { profileID.flatMap { model.scenarioRun(of: $0) } }

    var body: some View {
        HStack(spacing: 0) {
            // 80 % of the sidebar's tone, as the Profiles window's: the eclipse at the bottom-leading
            // corner shows through it, all but gone, instead of being hidden.
            list
                .frame(width: 240)
                .lumenFrost()
            Rectangle().fill(Theme.divider).frame(width: 1)
            Group {
                if showingSchedules {
                    ScenarioSchedulesPane(proposed: proposedSchedule)
                } else if selected != nil {
                    editor
                } else {
                    empty
                }
            }
            // No fill of its own: the window's (below) is the same black, with the light in it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        // The design's eclipse, still and at 30 %: the editor's geometry for this lower window.
        .background {
            ZStack {
                Theme.backdrop
                if appearance.entryLight {
                    EclipseLight(place: .settings, brightness: 0.3)
                }
            }
            .ignoresSafeArea()
        }
        // With the vault locked there are no scenarios to show and none can be written: said, not
        // an empty editor whose buttons do nothing.
        .overlay {
            if sample == nil, model.phase != .unlocked {
                VStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)
                    Text(L("scenarios.locked"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
            }
        }
        // What was typed is kept when the window closes, as when another scenario is chosen.
        .onDisappear { if sample == nil, edited { save() } }
        // The profile to run on is one that is there: the first, when the chosen one was deleted.
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            if let profileID, !ids.contains(profileID) { self.profileID = ids.first }
            if profileID == nil { profileID = ids.first }
        }
        // The profile a recording goes on in has stopped — its window was closed, or its process
        // ended: the recording ends there, with the lines it has.
        .onChange(of: recordingStopped) { _, stopped in
            if stopped { stopRecording() }
        }
        .onAppear {
            if let sample {
                selection = sample.id
                name = sample.name
                source = sample.source
            } else if selection == nil {
                select(model.scenarios.sorted.first?.id)
            }
            if profileID == nil { profileID = model.profiles.first?.id }
            // A recording going on is of its own profile: the window opened again names that one.
            if let recording = model.recordingProfile { profileID = recording }
            // One whose profile stopped while this window was closed ends now.
            if recordingStopped { stopRecording() }
        }
        .confirmationDialog(String(format: L("scenarios.delete.question"), selected?.name ?? ""), isPresented: $confirmingDelete) {
            Button(L("scenarios.delete"), role: .destructive) { delete() }
        }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("scenarios.title"))
                    .font(.lumenSection)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: create) {
                    Image(systemName: "plus")
                }
                .buttonStyle(LumenIconButtonStyle(size: 28))
                .help(L("scenarios.new"))
                .accessibilityLabel(L("scenarios.new"))
            }
            // 18: the title starts on the rows' text edge (8 + 10).
            .padding(.horizontal, 18)
            .padding(.top, 38)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(listed) { scenario in
                        Button {
                            showingSchedules = false
                            select(scenario.id)
                        } label: {
                            Text(scenario.name.isEmpty ? L("scenarios.untitled") : scenario.name)
                                .font(.lumenBody)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(selection == scenario.id && !showingSchedules ? Theme.rowSelected : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            // The rest of automation, from where scenarios are written: the local API's settings
            // and the app's help.
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                // Scenarios and warm-ups by the clock: the right side becomes their list. The number
                // is of those switched on.
                footLink("clock", L("schedule.title"), chosen: showingSchedules,
                         count: model.scenarioSchedules.schedules.filter(\.isEnabled).count) {
                    if edited { save() }
                    proposedSchedule = nil
                    showingSchedules = true
                }
                footLink("terminal", L("settings.section.automation")) {
                    model.settingsSection = .automation
                    openSettings()
                }
                footLink("book", L("sidebar.help")) { openHelp(.scenarios) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    /// A link at the list's foot; `count`, when not zero, at its right edge, as the sidebar's rows
    /// carry theirs.
    private func footLink(_ symbol: String, _ title: String, chosen: Bool = false, count: Int = 0,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.lumenSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(chosen ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// No scenario yet: the app's one empty-state recipe (`LumenEmptyState`), as the Schedules pane
    /// of this window; the symbol is the Scenarios' own (the Profiles sidebar's, the help's).
    private var empty: some View {
        LumenEmptyState(symbol: "play.rectangle", title: L("scenarios.empty.title"), text: L("scenarios.empty.detail")) {
            Button(L("scenarios.new"), action: create)
                .buttonStyle(.lumenPrimary)
            Button(L("scenarios.help.how")) { openHelp(.scenarios) }
                .buttonStyle(.lumenGhost)
        }
    }

    // MARK: The editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("scenarios.name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.lumenHeading)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                // What a scenario may say, with examples: the app's help, at its commands.
                Button { showsCommands.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(LumenIconButtonStyle(size: 28, isOn: showsCommands))
                    .help(L("scenarios.commands.toggle"))
                    .accessibilityLabel(L("scenarios.commands.toggle"))
                if edited {
                    Button(L("scenarios.save"), action: save)
                        .buttonStyle(.lumenSecondary)
                        .keyboardShortcut("s")
                }
                // Not while a recording goes on: with the last scenario deleted there would be no
                // Stop anywhere.
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(LumenIconButtonStyle(size: 28))
                    .help(L("scenarios.delete"))
                    .accessibilityLabel(L("scenarios.delete"))
                    .disabled(isRecording)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 12)
            if !model.allowsAutomation {
                Text(L("scenarios.notInPlan"))
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
            HStack(alignment: .top, spacing: 12) {
                // The code takes the cursor, not the name (which opened selected in the system's highlight).
                CodeEditor(text: $source, takesFocus: true)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Theme.fieldBorder, lineWidth: 1))
                if showsCommands { commands }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 220)
            runBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Group {
                // While a recording goes on, its steps as they come; otherwise the last run's log.
                if isRecording { RecordingLog(steps: recordedSteps) } else { RunLog(run: run) }
            }
            .frame(minHeight: 140, maxHeight: 260)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    /// What a scenario may say, to hand: a click adds the command at the scenario's end, to be
    /// changed there. The whole list, with what each takes, is the help's.
    private static let snippets: [(name: String, code: String)] = [
        ("goto", "await page.goto('https://example.com/');"),
        ("waitFor", "await page.waitFor('h1');"),
        ("click", "await page.click('#button');"),
        ("type", "await page.type('#field', 'text');"),
        ("press", "await page.press('Enter');"),
        ("scroll", "await page.scroll(600);"),
        ("read", "log(await page.textContent('h1'));"),
        ("sleep", "await sleep(1000);"),
    ]

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("scenarios.commands.title"))
                .lumenCaps()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 2)
            Text(L("scenarios.commands.hint"))
                .font(.lumenCaption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.snippets, id: \.name) { snippet in
                        Button { insert(snippet.code) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("scenarios.snippet.\(snippet.name)"))
                                    .font(.lumenSecondary)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(verbatim: snippet.code)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 7)
                    }
                }
                .padding(.horizontal, 4)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            Button { openHelp(.commands) } label: { Label(L("scenarios.commands.all"), systemImage: "book") }
                .buttonStyle(.lumenGhost)
                .padding(6)
        }
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
    }

    /// The command on a line of its own at the scenario's end.
    private func insert(_ code: String) {
        source += (source.isEmpty || source.hasSuffix("\n") ? "" : "\n") + code + "\n"
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            // No profiles: no empty popup, but what to do and the action that does it.
            if model.profiles.isEmpty {
                Text(L("scenarios.noProfiles"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                // As File › New Profile: the Profiles window, its new profile.
                Button(L("profiles.action.new")) {
                    if model.profilesWindow == nil { openWindow(id: "profiles") }
                    model.activateProfilesWindow()
                    model.newProfileRequest = true
                }
                .buttonStyle(.lumenSecondary)
            } else {
                Picker(L("scenarios.profile"), selection: $profileID) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                // At most 260 and free to shrink: a long profile name is cut inside the popup, not
                // the action buttons' labels, nor the bar pushed past the column.
                .frame(maxWidth: 260, alignment: .leading)
                // A recording belongs to the profile it began in, and a start to the one it was asked
                // for: the picker must not name another meanwhile.
                .disabled(isRecording || starting)
            }
            Spacer(minLength: 12)
            if isRecording {
                // What the person does in the profile's window becomes the scenario's lines.
                HStack(spacing: 7) {
                    // Breathes while it records; still under Reduce Motion and in the snapshots. The
                    // words beside it say the state, not the dot alone.
                    LiveDot(tone: Theme.danger, active: isRecording)
                    Text(String(format: L("scenarios.record.going"), recordedSteps.count))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                Button(action: stopRecording) { Label(L("scenarios.record.stop"), systemImage: "stop.fill") }
                    .buttonStyle(.lumenPrimary)
            } else if let run, run.isRunning {
                // The same shape as a recording: the state by its dot and words, Stop the main action.
                HStack(spacing: 7) {
                    Circle().fill(Theme.greenDot).frame(width: 8, height: 8)
                    Text(L("scenarios.running"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textPrimary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    if let profileID { model.stopScenario(on: profileID) }
                } label: {
                    Label(L("scenarios.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.lumenPrimary)
            } else {
                // Record and Run start a stopped profile first, which takes a while: said, not
                // only two dimmed buttons.
                if starting {
                    ProgressView().controlSize(.small)
                    Text(L("scenarios.starting"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                // The scenario on screen by the clock: the schedule's form, filled in with it and
                // the chosen profile. Open in a plan without automation too: the pane says why
                // nothing can be added there.
                Button(action: scheduleThis) { Label(L("scenarios.schedule.this"), systemImage: "clock") }
                    .buttonStyle(.lumenGhost)
                    .disabled(profileID == nil || starting)
                    .help(L("scenarios.schedule.this.help"))
                Button(action: startRecording) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text(L("scenarios.record"))
                    }
                }
                .buttonStyle(.lumenSecondary)
                .disabled(!model.allowsAutomation || profileID == nil || starting)
                .help(L("scenarios.record.help"))
                Button(action: startRun) { Label(L("scenarios.run"), systemImage: "play.fill") }
                    .buttonStyle(.lumenPrimary)
                    .disabled(!model.allowsAutomation || profileID == nil || starting || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut("r")
            }
        }
    }

    // MARK: Actions

    private func openHelp(_ topic: HelpTopic) {
        model.helpTopic = topic
        openWindow(id: "help")
    }

    private func select(_ id: UUID?) {
        if edited { save() }
        selection = id
        name = selected?.name ?? ""
        source = selected?.source ?? ""
    }

    private func create() {
        if edited { save() }
        let scenario = Scenario(name: model.scenarios.freeName(L("scenarios.untitled")), source: L("scenarios.template"))
        if model.saveScenario(scenario) { select(scenario.id) }
    }

    private func save() {
        guard var scenario = selected else { return }
        scenario.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("scenarios.untitled") : name
        scenario.source = source
        model.saveScenario(scenario)
    }

    private func delete() {
        guard let scenario = selected else { return }
        if model.saveScenario(scenario, remove: true) {
            selection = nil
            select(model.scenarios.sorted.first?.id)
        }
    }

    private func startRecording() {
        guard let profileID else { return }
        if edited { save() }
        starting = true
        Task { @MainActor in
            let started = await model.startRecording(on: profileID)
            starting = false
            // A launch that failed has said why; a refusal nobody said is said here.
            if !started, model.errorMessage == nil { model.showError(L("scenarios.start.failed")) }
        }
    }

    /// The recording's steps go to the scenario's end, as lines to be changed there.
    private func stopRecording() {
        let steps = model.stopRecording()
        guard !steps.isEmpty else { return }
        let lines = steps.map { ScenarioRecording.line(for: $0, passwordNote: L("scenarios.record.password")) }
        // A scenario that is still the example, or empty, is replaced: a first recording must not
        // open example.com first.
        let untouched = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source == L("scenarios.template")
        let before = untouched ? "" : source + (source.hasSuffix("\n") ? "" : "\n")
        source = before + lines.joined(separator: "\n") + "\n"
    }

    private func startRun() {
        if edited { save() }
        guard let scenario = selected, let profileID else { return }
        starting = true
        Task { @MainActor in
            let started = await model.runScenario(scenario, on: profileID)
            starting = false
            if !started, model.errorMessage == nil { model.showError(L("scenarios.start.failed")) }
        }
    }

    /// Opens the schedules with a form for this scenario on the chosen profile: every day at
    /// 10:00, give or take a quarter of an hour, to be changed there.
    private func scheduleThis() {
        guard let scenario = selected, let profileID else { return }
        if edited { save() }
        // One that is there already is in the list, with its Edit: a second form would add its twin.
        let action = ScenarioSchedule.Action.scenario(scenario.id)
        let scheduled = model.scenarioSchedules.schedules.contains { $0.action == action && $0.profileID == profileID }
        proposedSchedule = scheduled ? nil : ScenarioSchedule(action: action, profileID: profileID,
                                                              when: .daily(hour: 10, minute: 0), jitterMinutes: 15)
        showingSchedules = true
    }
}

/// A recording as it goes: each step as the line the scenario will get, the newest at the end;
/// before the first, what to do.
private struct RecordingLog: View {
    let steps: [RecordedStep]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if steps.isEmpty {
                        Text(L("scenarios.record.empty"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Text(verbatim: ScenarioRecording.line(for: step, passwordNote: L("scenarios.record.password")))
                            .font(.lumenMono)
                            .foregroundStyle(step.kind == .note ? Theme.textTertiary : Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: steps.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .strokeBorder(Theme.dangerLine, lineWidth: 1))
    }
}

/// The run's log: each line with its time, commands plain, the script's own lines brighter, errors
/// and the end in their colours; kept at its end while it grows.
private struct RunLog: View {
    let run: ProfileManager.ScenarioRunState?

    var body: some View {
        Group {
            // No run yet: said in the middle of the box, not as one small line at its corner.
            if run == nil {
                LumenEmptyHint(symbol: "text.alignleft", text: L("scenarios.log.empty"))
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if let run {
                                ForEach(Array(run.lines.enumerated()), id: \.offset) { index, line in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(line.at.formatted(.dateTime.hour().minute().second().locale(Localization.locale)))
                                            .foregroundStyle(Theme.textTertiary)
                                        Text(line.text)
                                            .foregroundStyle(color(line.kind))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.system(size: 12, design: .monospaced))
                                    .id(index)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: run?.lines.count ?? 0) { _, count in
                        if count > 0 { reader.scrollTo(count - 1, anchor: .bottom) }
                    }
                    // A log shown at once with its lines (another profile chosen) opens at its end
                    // too: the reader is new then, and its onChange sees no change.
                    .onAppear {
                        let count = run?.lines.count ?? 0
                        if count > 0 { DispatchQueue.main.async { reader.scrollTo(count - 1, anchor: .bottom) } }
                    }
                }
            }
        }
        // The code editor's box: the three code boxes of the window are drawn one way.
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .strokeBorder(Theme.fieldBorder, lineWidth: 1))
    }

    private func color(_ kind: ScenarioRunner.Line.Kind) -> Color {
        switch kind {
        case .command: return Theme.textSecondary
        case .script: return Theme.textPrimary
        case .error: return Theme.danger
        case .outcome: return run?.outcome == .finished ? Theme.running : Theme.warning
        }
    }
}

/// A plain-text editor for code: a fixed-width font, no smart quotes, dashes or replacements (they
/// would break JavaScript), no spelling.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// The cursor starts here when it appears: one field per screen, as `LockPasswordField.takesFocus`.
    var takesFocus = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.textColor = NSColor(Theme.textPrimary)
        view.insertionPointColor = NSColor(Theme.textPrimary)
        view.drawsBackground = false
        // 7 + the line's own 5 pt padding: the text starts 12 pt in, as in the logs under it.
        view.textContainerInset = NSSize(width: 7, height: 10)
        view.string = text
        view.setAccessibilityLabel(L("scenarios.code"))
        if takesFocus {
            // Once the view is in its window: before, there is no window to make it first responder of.
            DispatchQueue.main.async { [weak view] in
                if let view, let window = view.window { window.makeFirstResponder(view) }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        // Text added at the end (a recording, a command of the panel) is brought into view: in a
        // scenario longer than the editor it would land below the fold, and nothing would show.
        let appended = !view.string.isEmpty && text.hasPrefix(view.string)
        view.string = text
        if appended { view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
