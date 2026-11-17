import BrowserCore
import SwiftUI

/// A profile's own values for scenarios (docs/AUTOMATION.md, "A profile's values"): the names a
/// scenario reads as `params.<name>` and this profile's text for each — a login, a password. The
/// plain form of it: a name and a value a row, the names the scenario on screen reads offered
/// empty. What it shows and saves is the model's (`AppModel.scenarioValues`,
/// `AppModel.saveScenarioValues`, `ScenarioValues` in BrowserCore).
struct ScenarioValuesSheet: View {
    let profileID: UUID
    let profileName: String
    /// The names the scenario on screen reads from `params`: each gets a row to fill in.
    var namesRead: [String] = []
    /// Shown without a vault (the snapshots): these values, and nothing is saved.
    var sample: [ScenarioValues.Value]?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    @State private var rows: [Row] = []
    /// Values shown as text; the others as dots.
    @State private var revealed: Set<UUID> = []

    /// What stops a save, in words: a name that cannot be read as `params.<name>`, or one used twice.
    private var problem: String? {
        var seen = Set<String>()
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                if row.value.isEmpty { continue }
                return L("scenarios.values.problem.unnamed")
            }
            guard ScenarioValues.isName(name) else { return String(format: L("scenarios.values.problem.name"), name) }
            guard seen.insert(name).inserted else { return String(format: L("scenarios.values.problem.twice"), name) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("scenarios.values.title"), profileName), subtitle: L("scenarios.values.subtitle"))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField(L("scenarios.values.name"), text: $row.name, prompt: Text(verbatim: ""))
                                .lumenField(L("scenarios.values.name"), isEmpty: row.name.isEmpty)
                                .frame(width: 170)
                            Group {
                                if revealed.contains(row.id) {
                                    TextField(L("scenarios.values.value"), text: $row.value, prompt: Text(verbatim: ""))
                                } else {
                                    SecureField(L("scenarios.values.value"), text: $row.value, prompt: Text(verbatim: ""))
                                }
                            }
                            .lumenField(L("scenarios.values.value"), isEmpty: row.value.isEmpty)
                            Button {
                                if !revealed.insert(row.id).inserted { revealed.remove(row.id) }
                            } label: { Image(systemName: revealed.contains(row.id) ? "eye.slash" : "eye") }
                                .buttonStyle(LumenIconButtonStyle())
                                .help(revealed.contains(row.id) ? L("scenarios.values.hide") : L("scenarios.values.show"))
                                .accessibilityLabel(revealed.contains(row.id) ? L("scenarios.values.hide") : L("scenarios.values.show"))
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(LumenIconButtonStyle())
                                .help(L("scenarios.values.remove"))
                                .accessibilityLabel(L("scenarios.values.remove"))
                        }
                    }
                    Button {
                        rows.append(Row(name: "", value: ""))
                    } label: { Label(L("scenarios.values.add"), systemImage: "plus") }
                        .buttonStyle(.lumenGhost)
                        .disabled(rows.count >= ScenarioValues.maximumCount)
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 340)
            SheetFooter {
                Text(L("scenarios.values.kept"))
                    .font(.lumenCaption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save"), action: save)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .sheetFrame(width: 560)
        .background(Theme.raised)
        .onAppear {
            guard rows.isEmpty else { return }
            let saved = sample ?? model.scenarioValues.values(of: profileID)
            rows = saved.map { Row(name: $0.name, value: $0.value) }
            // What the scenario reads and this profile has no row for: offered empty.
            let known = Set(saved.map(\.name))
            rows += namesRead.filter { !known.contains($0) }.map { Row(name: $0, value: "") }
            if rows.isEmpty { rows = [Row(name: "", value: "")] }
        }
    }

    /// A row left without text is not kept: an offered name nobody filled in is not a value.
    private func save() {
        guard sample == nil else {
            dismiss()
            return
        }
        let values = rows.filter { !$0.value.isEmpty }
            .map { ScenarioValues.Value(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), value: $0.value) }
        if model.saveScenarioValues(values, for: profileID) { dismiss() }
    }
}
