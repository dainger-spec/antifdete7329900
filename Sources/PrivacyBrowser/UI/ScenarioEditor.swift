import AppKit
import BrowserCore
import SwiftUI

/// A scenario being edited (docs/AUTOMATION.md, "Steps"): its settings and its steps on the
/// left — each step in words, changed in fields, moved, switched off — and its code on the
/// right. The code is what is true: the steps are read from it (`ScenarioSteps`), and every
/// change made in them is a change of its lines.
///
/// From here a scenario is recorded (what the person does in a profile's window becomes steps
/// after the chosen one), checked on one profile (the step a run failed at is marked), run on
/// many (`run`) and put on a schedule.
struct ScenarioEditor: View {
    enum Mode: String, Hashable { case steps, both, code }

    let scenario: Scenario
    let profiles: [ScenarioProfile]
    let allowed: Bool
    var sample: ScenariosSection.Sample?
    let back: () -> Void
    let run: (Scenario) -> Void
    let openRun: (UUID) -> Void
    /// "On a Schedule…": the scenario, and the profile chosen in the editor.
    let schedule: (Scenario, UUID?) -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage("scenarios.editor.mode") private var storedMode = Mode.both.rawValue
    @State private var name = ""
    @State private var source = ""
    @State private var selected: Int?
    @State private var profileID: UUID?
    @State private var starting = false
    @State private var showingValues = false
    @State private var confirmingDelete = false
    /// The check going on, or the last one: a run of one profile.
    @State private var check: UUID?
    @State private var loaded = false

    private var mode: Mode { sample?.editorMode ?? Mode(rawValue: storedMode) ?? .both }
    private var edited: Bool { scenario.name != name || scenario.source != source }
    private var cut: ScenarioSteps { ScenarioSteps(source) }
    private var settings: [ScenarioSettings.Setting] { ScenarioSettings(source).settings }
    private var template: ScenarioTemplate? { scenario.templateID.flatMap { ScenarioTemplate.template($0) } }
    private var isRecording: Bool { sample?.recording != nil || (model.recordingProfile != nil && model.recordingScenario == scenario.id) }
    private var recordedSteps: [RecordedStep] { sample?.recording ?? model.recorded.steps }
    /// Another scenario is being recorded: this one waits.
    private var recordingElsewhere: Bool { sample == nil && model.recordingProfile != nil && model.recordingScenario != scenario.id }
    private var recordingStopped: Bool {
        guard sample == nil, isRecording, let id = model.recordingProfile else { return false }
        return !model.isRunning(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 0) {
                if mode != .code {
                    stepsPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if mode != .steps {
                    if mode == .both { Rectangle().fill(Theme.divider).frame(width: 1) }
                    CodeEditor(text: $source)
                        .frame(width: mode == .both ? 480 : nil)
                        .frame(maxWidth: mode == .code ? .infinity : nil, maxHeight: .infinity)
                        .lumenFrost()
                        .disabled(isRecording)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = scenario.name
            source = scenario.source
            profileID = model.recordingProfile ?? profiles.first?.id
            // A recording whose profile stopped while this was not on screen ends now.
            if recordingStopped { stopRecording() }
        }
        // Edits not saved yet are kept on the way out — not those of a scenario just deleted (`save`).
        .onDisappear { if sample == nil, edited { save() } }
        .onChange(of: profiles.map(\.id)) { _, ids in
            if let profileID, !ids.contains(profileID) { self.profileID = ids.first }
            if profileID == nil { profileID = ids.first }
        }
        // The profile a recording goes on in has stopped: the recording ends with what it has.
        .onChange(of: recordingStopped) { _, stopped in if stopped { stopRecording() } }
        .sheet(isPresented: $showingValues) {
            if let profileID {
                ScenarioValuesSheet(profileID: profileID, profileName: profiles.first { $0.id == profileID }?.name ?? "",
                                    namesRead: ScenarioValues.namesRead(by: source))
            }
        }
        .confirmationDialog(String(format: L("scenarios.delete.question"), scenario.name), isPresented: $confirmingDelete) {
            Button(L("scenarios.delete"), role: .destructive) {
                if model.saveScenario(scenario, remove: true) { back() }
            }
        }
    }

    // MARK: The header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if sample == nil, edited { save() }
                back()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(scenario.folder.map { L("scenarios.title") + " · " + $0 } ?? L("scenarios.title")).font(.lumenSecondary)
                }
            }
            .buttonStyle(.lumenGhost)
            .padding(.leading, -11)
            .disabled(isRecording)
            HStack(spacing: 8) {
                TextField(L("scenarios.name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.lumenHeading)
                    .tracking(-0.44)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 360)
                Spacer(minLength: 8)
                if isRecording {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text(String(format: L("scenarios.record.going"), recordedSteps.count))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    Button(action: stopRecording) { Label(L("scenarios.record.stop"), systemImage: "stop.fill") }
                        .buttonStyle(.lumenPrimary)
                } else {
                    controls
                }
            }
            HStack(spacing: 8) {
                Text(ScenarioWords.summary(Scenario(name: name, source: source)))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // The profile a recording and a check are made in.
                Text(L("scenarios.editor.profile")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                Picker(L("scenarios.profile"), selection: $profileID) {
                    ForEach(profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(isRecording || starting || profiles.isEmpty)
                Button { showingValues = true } label: { Text(L("scenarios.values.short")) }
                    .buttonStyle(.lumenGhost)
                    .help(L("scenarios.values.open"))
                    .disabled(profileID == nil || isRecording || sample != nil)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, ProfilesScreen.headerTrailing)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var controls: some View {
        LumenSegmented(selection: Binding(get: { mode }, set: { storedMode = $0.rawValue }), options: [
            (value: Mode.steps, title: L("scenarios.editor.steps")), (value: Mode.both, title: L("scenarios.editor.both")), (value: Mode.code, title: L("scenarios.editor.code")),
        ])
        .accessibilityLabel(L("scenarios.editor.mode"))
        if edited {
            Button(L("scenarios.save"), action: save)
                .buttonStyle(.lumenGhost)
                .keyboardShortcut("s")
        }
        MoreMenu {
            Button(L("scenarios.schedule.this")) { if edited { save() }; schedule(scenario, profileID) }
            Button(L("scenarios.duplicate")) { if edited { save() }; model.saveScenario(model.scenarios.copy(of: Scenario(name: name, source: source, folder: scenario.folder, templateID: scenario.templateID))) }
            Divider()
            Button(L("scenarios.delete"), role: .destructive) { confirmingDelete = true }
        }
        if starting { ProgressView().controlSize(.small) }
        Button(action: startRecording) {
            HStack(spacing: 6) {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
                Text(L("scenarios.record"))
            }
        }
        .buttonStyle(.lumenSecondary)
        .disabled(!allowed || profileID == nil || starting || recordingElsewhere)
        .help(L("scenarios.record.help"))
        Button(L("scenarios.check"), action: startCheck)
            .buttonStyle(.lumenSecondary)
            .disabled(!canRun || profileID == nil)
            .help(L("scenarios.check.help"))
        Button {
            if edited { save() }
            run(Scenario(id: scenario.id, name: name, source: source, createdAt: scenario.createdAt, folder: scenario.folder, note: scenario.note, templateID: scenario.templateID))
        } label: { Label(L("scenarios.run.on"), systemImage: "play.fill") }
            .buttonStyle(.lumenPrimary)
            .disabled(!canRun)
            .keyboardShortcut("r")
    }

    private var canRun: Bool {
        allowed && !starting && !recordingElsewhere && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: The steps

    private var stepsPane: some View {
        ScenarioRunsReader(sample: sample?.runs) { runs, _ in
            let checked = check.flatMap { id in runs.first { $0.id == id } }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isRecording {
                        recordingSteps
                    } else {
                        if let checked { checkBar(checked) }
                        settingsRows
                        stepRows(failedLine: failedLine(checked), finished: checked.map { !$0.isRunning && $0.finished == 1 } ?? false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
    }

    /// The line the check's run failed at, when it names one.
    private func failedLine(_ run: ScenarioBatch?) -> (line: Int?, reason: String)? {
        guard let entry = run?.entries.first, case .failed(let reason, let line) = entry.state else { return nil }
        return (line, reason)
    }

    @ViewBuilder private var settingsRows: some View {
        let list = settings
        if !list.isEmpty {
            caption(L("scenarios.editor.settings"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(list, id: \.name) { setting in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(setting.label.isEmpty ? setting.name : setting.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 190, alignment: .leading)
                        ScenarioSettingField(field: template?.parameters.first { $0.name == setting.name }?.field,
                                             value: Binding(get: { setting.value }, set: { source = ScenarioSettings.setting(setting.name, to: $0, in: source) }))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, ProfileColumns.rowPadding)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private func stepRows(failedLine: (line: Int?, reason: String)?, finished: Bool) -> some View {
        let cut = self.cut
        let steps = cut.steps
        let list = settings
        // The step the check failed at: by the error's line; without one, nothing is marked.
        let failedAt = failedLine?.line.flatMap { cut.step(atLine: $0)?.index }
        caption(steps.isEmpty ? L("scenarios.editor.steps.none") : String(format: L("scenarios.steps.count"), steps.count))
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            let state = mark(index, failedAt: failedAt, reason: failedLine?.reason ?? "", finished: finished)
            VStack(alignment: .leading, spacing: 0) {
                ScenarioStepLine(number: index + 1, step: step, settings: list, state: state)
                if selected == index, cut.isCut { stepEditor(index, step) }
            }
            .padding(.horizontal, ProfileColumns.rowPadding)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(selected == index ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { selected = selected == index ? nil : index }
        }
        if cut.isCut {
            HStack(spacing: 4) {
                Menu {
                    ForEach(Self.addable, id: \.self) { kind in
                        Button(L("scenarios.step.\(kind.rawValue)")) { add(kind) }
                    }
                } label: {
                    Label(L("scenarios.step.add"), systemImage: "plus").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: Theme.controlHeight)
            }
            .padding(.top, 6)
        } else {
            Text(L("scenarios.editor.uncut"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(ProfileColumns.rowPadding)
        }
    }

    private func mark(_ index: Int, failedAt: Int?, reason: String, finished: Bool) -> ScenarioStepLine.Mark {
        if finished { return .passed }
        guard let failedAt else { return .plain }
        if index < failedAt { return .passed }
        return index == failedAt ? .failed(reason) : .plain
    }

    private static let addable: [ScenarioSteps.Kind] = [.open, .click, .type, .press, .waitFor, .waitLoad, .scroll, .pause, .result]

    /// A chosen step's fields — what it is given, where that is text written out — and what is
    /// done with the step as a whole.
    private func stepEditor(_ index: Int, _ step: ScenarioSteps.Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !step.isOff, ScenarioSteps.statement(step.kind, step.arguments) != nil {
                ForEach(Array(step.arguments.enumerated()), id: \.offset) { place, argument in
                    if case .text(let text) = argument {
                        HStack(spacing: 10) {
                            Text(ScenarioStepWords.argumentName(step.kind, place))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 150, alignment: .leading)
                            TextField("", text: Binding(get: { text }, set: { typed in
                                var arguments = step.arguments
                                arguments[place] = .text(typed)
                                if let line = ScenarioSteps.statement(step.kind, arguments) { source = ScenarioSteps(source).rewriting(index, statement: line).source }
                            }), prompt: Text(verbatim: ""))
                                .lumenField(height: 28)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Button(L("scenarios.step.up")) { move(index, to: index - 1) }.disabled(index == 0)
                Button(L("scenarios.step.down")) { move(index, to: index + 2) }.disabled(index >= cut.steps.count - 1)
                Button(L("scenarios.step.recordHere")) { startRecording() }.disabled(!allowed || profileID == nil || starting || recordingElsewhere)
                Spacer()
                Toggle(L("scenarios.step.on"), isOn: Binding(get: { !step.isOff }, set: { _ in source = ScenarioSteps(source).toggling(index).source }))
                    .toggleStyle(.lumenSwitch)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                Button(L("common.delete"), role: .destructive) {
                    source = ScenarioSteps(source).removing(index).source
                    selected = nil
                }
                .buttonStyle(.lumenDestructive)
            }
            .buttonStyle(.lumenGhost)
        }
        .padding(.leading, 30)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func move(_ index: Int, to destination: Int) {
        source = ScenarioSteps(source).moving(index, to: destination).source
        selected = destination > index ? destination - 1 : destination
    }

    private func add(_ kind: ScenarioSteps.Kind) {
        let arguments: [ScenarioSteps.Argument]
        switch kind {
        case .open: arguments = [.text("https://")]
        case .type: arguments = [.text(""), .text("")]
        case .press: arguments = [.text("Enter")]
        case .scroll: arguments = [.raw("600")]
        case .pause: arguments = [.raw("1000")]
        case .waitLoad: arguments = []
        default: arguments = [.text("")]
        }
        guard let line = ScenarioSteps.statement(kind, arguments) else { return }
        let before = ScenarioSteps(source)
        source = before.inserting(line, after: selected).source
        selected = selected.map { $0 + 1 } ?? before.steps.count
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.lumenLabel)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, ProfileColumns.rowPadding)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    // MARK: A check on one profile

    private func checkBar(_ run: ScenarioBatch) -> some View {
        HStack(spacing: 8) {
            if run.isRunning { ProgressView().controlSize(.small) }
            Text(String(format: L("scenarios.check.on"), run.entries.first?.name ?? "")).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
            if let entry = run.entries.first { ScenarioEntryState(entry: entry, steps: cut) }
            Spacer(minLength: 8)
            if run.isRunning {
                Button(L("scenarios.stop")) { model.scenarioBatches.stop(run.id) }.buttonStyle(.lumenSecondary)
            } else {
                Button(L("scenarios.check.log")) { openRun(run.id) }.buttonStyle(.lumenGhost)
                Button { check = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(LumenIconButtonStyle(size: 24))
                    .accessibilityLabel(L("common.close"))
            }
        }
        .padding(.horizontal, ProfileColumns.rowPadding)
        .padding(.bottom, 12)
    }

    private func startCheck() {
        guard sample == nil, let profileID, let profile = profiles.first(where: { $0.id == profileID }) else { return }
        if edited { save() }
        selected = nil
        check = model.scenarioBatches.start(Scenario(id: scenario.id, name: name, source: source), on: [(id: profile.id, name: profile.name)],
                                            limit: 1, stopsProfiles: false, origin: .check)
    }

    // MARK: Recording

    /// What has been recorded so far, in words, as the steps the scenario will get.
    @ViewBuilder private var recordingSteps: some View {
        let lines = recordedSteps.map { ScenarioRecording.line(for: $0, passwordNote: L("scenarios.record.password")) }
        let steps = ScenarioSteps(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).steps
        Text(L("scenarios.record.empty"))
            .font(.lumenSecondary)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, ProfileColumns.rowPadding)
            .padding(.bottom, 12)
        caption(String(format: L("scenarios.record.count"), steps.count))
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            ScenarioStepLine(number: index + 1, step: step, settings: [])
                .padding(.horizontal, ProfileColumns.rowPadding)
        }
    }

    private func startRecording() {
        guard sample == nil, let profileID else { return }
        if edited { save() }
        starting = true
        Task { @MainActor in
            let started = await model.startRecording(on: profileID, for: scenario.id)
            starting = false
            if !started, model.errorMessage == nil { model.showError(L("scenarios.start.failed")) }
        }
    }

    /// The recording's steps become lines after the chosen step (at the end when none is
    /// chosen). A scenario that is still the example, or empty, is replaced by them.
    private func stopRecording() {
        guard sample == nil else { return }
        let steps = model.stopRecording()
        guard !steps.isEmpty else { return }
        let lines = steps.map { ScenarioRecording.line(for: $0, passwordNote: L("scenarios.record.password")) }.joined(separator: "\n") + "\n"
        let untouched = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source == L("scenarios.template")
        source = untouched ? lines : ScenarioSteps(source).inserting(lines, after: selected).source
        selected = nil
        save()
    }

    /// Writes the name and the text as they are on screen — only while the scenario is still in
    /// the library: one deleted from here (or gone with the vault) leaves the editor with its edits
    /// unsaved, and its `onDisappear` must not put it back.
    private func save() {
        guard model.scenarios.scenario(scenario.id) != nil else { return }
        var changed = scenario
        changed.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("scenarios.untitled") : name
        changed.source = source
        model.saveScenario(changed)
    }
}

/// A step in words: its number, a sign of its kind, what it does and with what; how a run went
/// through it, when one did. A block's steps under it, set in.
struct ScenarioStepLine: View {
    enum Mark: Equatable { case plain, passed, failed(String) }

    let number: Int?
    let step: ScenarioSteps.Step
    let settings: [ScenarioSettings.Setting]
    var compact = false
    var state: Mark = .plain
    var time: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: number.map { String($0) } ?? "")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ScenarioStepWords.title(step))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(step.isOff ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(step.isOff, color: Theme.textTertiary)
                        .lineLimit(2)
                    if let detail = ScenarioStepWords.detail(step, settings: settings) {
                        Text(detail)
                            .font(.lumenSecondary)
                            .foregroundStyle(step.isOff ? Theme.textDisabled : Theme.textSecondary)
                            .lineLimit(compact ? 2 : 3)
                    }
                    if case .failed(let reason) = state, !reason.isEmpty {
                        Text(reason)
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                if let time { Text(time).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit() }
                switch state {
                case .passed: Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Theme.running).accessibilityLabel(L("scenarios.step.passed"))
                case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.danger).accessibilityLabel(L("scenarios.step.failed"))
                case .plain: EmptyView()
                }
            }
            .padding(.vertical, compact ? 5 : 8)
            ForEach(Array(step.children.enumerated()), id: \.offset) { _, child in
                ScenarioStepLine(number: nil, step: child, settings: settings, compact: true)
                    .padding(.leading, 20)
            }
        }
    }
}

/// A step's words: what it does (its own comment, or the command's name) and with what.
enum ScenarioStepWords {
    static func title(_ step: ScenarioSteps.Step) -> String {
        if let title = step.title { return title }
        if step.kind == .code { return step.code.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }
        return L("scenarios.step.\(step.kind.rawValue)")
    }

    static func detail(_ step: ScenarioSteps.Step, settings: [ScenarioSettings.Setting]) -> String? {
        if step.kind == .code {
            let lines = step.code.split(whereSeparator: \.isNewline).count
            return step.title == nil ? (lines > 1 ? String(format: L("scenarios.step.code.lines"), lines) : nil) : String(format: L("scenarios.step.code.lines"), lines)
        }
        let parts = step.arguments.map { argument -> String in
            switch argument {
            case .text(let text): return text
            case .setting(let name):
                if case .text(let text)? = settings.first(where: { $0.name == name })?.value, !text.isEmpty { return text }
                if let value = settings.first(where: { $0.name == name })?.value, case .number = value { return value.code }
                return settings.first { $0.name == name }?.label ?? name
            case .profile(let name): return String(format: L("scenarios.step.profileValue"), name)
            case .raw(let code): return code
            }
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What a command's argument is, for its field.
    static func argumentName(_ kind: ScenarioSteps.Kind, _ place: Int) -> String {
        switch (kind, place) {
        case (.open, _), (.waitURL, _): return L("scenarios.step.argument.address")
        case (.type, 1), (.select, 1), (.result, _), (.log, _): return L("scenarios.step.argument.text")
        case (.press, _): return L("scenarios.step.argument.key")
        default: return L("scenarios.step.argument.element")
        }
    }
}

/// A plain-text editor for code: a fixed-width font, no smart quotes, dashes or replacements (they
/// would break JavaScript), no spelling.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

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
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.string = text
        view.setAccessibilityLabel(L("scenarios.code"))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        // Text added at the end (a recording, a step added) is brought into view: in a scenario
        // longer than the editor it would land below the fold, and nothing would show.
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
