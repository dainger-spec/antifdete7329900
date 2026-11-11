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

    private var selected: Scenario? { sample ?? selection.flatMap { model.scenarios.scenario($0) } }
    private var listed: [Scenario] { sample.map { [$0] } ?? model.scenarios.sorted }
    private var edited: Bool { selected.map { $0.name != name || $0.source != source } ?? false }
    private var run: ProfileManager.ScenarioRunState? { profileID.flatMap { model.scenarioRun(of: $0) } }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 240)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.divider).frame(width: 1)
            Group {
                if selected != nil { editor } else { empty }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if let sample {
                selection = sample.id
                name = sample.name
                source = sample.source
            } else if selection == nil {
                select(model.scenarios.sorted.first?.id)
            }
            if profileID == nil { profileID = model.profiles.first?.id }
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
                .buttonStyle(.lumenGhost)
                .help(L("scenarios.new"))
                .accessibilityLabel(L("scenarios.new"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 38)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(listed) { scenario in
                        Button { select(scenario.id) } label: {
                            Text(scenario.name.isEmpty ? L("scenarios.untitled") : scenario.name)
                                .font(.lumenBody)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(selection == scenario.id ? Theme.rowSelected : Color.clear))
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

    private func footLink(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.lumenSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text(L("scenarios.empty.title"))
                .font(.lumenHeading)
                .foregroundStyle(Theme.textPrimary)
            Text(L("scenarios.empty.detail"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
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
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.lumenGhost)
                    .help(L("scenarios.delete"))
                    .accessibilityLabel(L("scenarios.delete"))
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
                CodeEditor(text: $source)
                    .background(Theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.fieldBorder))
                if showsCommands { commands }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 220)
            runBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            RunLog(run: run)
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
            Picker(L("scenarios.profile"), selection: $profileID) {
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .frame(maxWidth: 320)
            Spacer()
            if let run, run.isRunning {
                Text(L("scenarios.running"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.running)
                Button(L("scenarios.stop")) { if let profileID { model.stopScenario(on: profileID) } }
                    .buttonStyle(.lumenSecondary)
            } else {
                Button(L("scenarios.run"), action: startRun)
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

    private func startRun() {
        if edited { save() }
        guard let scenario = selected, let profileID else { return }
        starting = true
        Task { @MainActor in
            _ = await model.runScenario(scenario, on: profileID)
            starting = false
        }
    }
}

/// The run's log: each line with its time, commands plain, the script's own lines brighter, errors
/// and the end in their colours; kept at its end while it grows.
private struct RunLog: View {
    let run: ProfileManager.ScenarioRunState?

    var body: some View {
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
                    } else {
                        Text(L("scenarios.log.empty"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .onChange(of: run?.lines.count ?? 0) { _, count in
                if count > 0 { reader.scrollTo(count - 1, anchor: .bottom) }
            }
        }
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
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.string = text
        view.setAccessibilityLabel(L("scenarios.code"))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
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
