import AppKit
import BrowserCore
import SwiftUI

/// The local automation API (`AutomationServer`): on or off, its port, its token, and a command
/// to try it with. Off until turned on here.
struct AutomationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var port = ""
    @State private var revealed = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("automation.title"))
            Form {
                Text(L("automation.note")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if AutomationServer.isAvailable {
                    Toggle(L("automation.enabled"), isOn: $enabled)
                        .onChange(of: enabled) { _, on in apply(enabled: on) }
                    LabeledContent(L("automation.port")) {
                        HStack {
                            TextField(L("automation.port"), text: $port)
                                .labelsHidden()
                                .frame(width: 90)
                                .onSubmit { apply(enabled: enabled) }
                            Button(L("automation.port.apply")) { apply(enabled: enabled) }
                                .disabled(portValue == nil || portValue == settings?.port)
                        }
                    }
                    if portValue == nil {
                        Text(String(format: L("automation.error.port.range"), AutomationSettings.ports.lowerBound, AutomationSettings.ports.upperBound))
                            .font(.caption).foregroundStyle(Theme.danger)
                    }
                    tokenRow
                    Section(L("automation.state")) {
                        Text(stateText).foregroundStyle(stateColor)
                    }
                    Section(L("automation.example")) {
                        Text(verbatim: exampleCommand) // l10n: not text
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("automation.example.copy")) { Self.copy(exampleCommand, concealed: true) }
                        Text(L("automation.docs")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("automation.error.sandboxed")).foregroundStyle(Theme.warning)
                }
            }
            .lumenForm()
            SheetFooter {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
        .background(Theme.raised)
        .onAppear(perform: load)
    }

    private var settings: AutomationSettings? { model.automationSettings }

    private var tokenRow: some View {
        LabeledContent(L("automation.token")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: revealed ? (settings?.token ?? "") : String(repeating: "•", count: 24)) // l10n: not text
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(L(revealed ? "automation.token" : "automation.token.hidden"))
                HStack {
                    Button(L(revealed ? "automation.token.hide" : "automation.token.show")) { revealed.toggle() }
                    Button(L("automation.token.copy")) { Self.copy(settings?.token ?? "", concealed: true) }
                    Button(L("automation.token.renew")) { model.renewAutomationToken() }
                        .help(L("automation.token.renew.note"))
                }
            }
        }
    }

    private var portValue: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), AutomationSettings.ports.contains(value) else { return nil }
        return value
    }

    private var listeningPort: Int {
        if case .listening(let port) = model.automationState { return port }
        return settings?.port ?? AutomationSettings.defaultPort
    }

    private var exampleCommand: String {
        "curl -s -H 'Authorization: Bearer \(settings?.token ?? "")' http://127.0.0.1:\(listeningPort)/v1/profiles"
    }

    private var stateText: String {
        switch model.automationState {
        case .stopped: return L("automation.state.stopped")
        case .listening(let port): return String(format: L("automation.state.listening"), port)
        case .failed(let reason): return String(format: L("automation.state.failed"), reason)
        }
    }

    private var stateColor: Color {
        switch model.automationState {
        case .stopped: return .secondary
        case .listening: return Theme.running
        case .failed: return Theme.danger
        }
    }

    private func load() {
        guard !loaded else { return }
        model.ensureAutomationSettings()
        enabled = settings?.isEnabled ?? false
        port = String(settings?.port ?? AutomationSettings.defaultPort)
        loaded = true
    }

    private func apply(enabled: Bool) {
        guard loaded else { return }
        let chosen = portValue ?? settings?.port ?? AutomationSettings.defaultPort
        guard enabled != settings?.isEnabled || chosen != settings?.port else { return }
        model.setAutomation(enabled: enabled, port: chosen)
    }

    /// The token, and the command that holds it, are marked concealed: clipboard managers skip them.
    private static func copy(_ value: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        if concealed { pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }
}
