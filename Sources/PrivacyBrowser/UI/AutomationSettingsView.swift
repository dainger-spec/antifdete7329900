import AppKit
import BrowserCore
import SwiftUI

/// The local automation API (`AutomationServer`): on or off, its port, its token, and a command
/// to try it with. Off until turned on here.
struct AutomationSettingsView: View {
    /// Shown as a section of Settings: the page alone, without the sheet's title and Done.
    var embedded = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var enabled = false
    @State private var port = ""
    @State private var revealed = false
    @State private var loaded = false

    var body: some View {
        if embedded {
            SettingsPage(title: L("settings.section.automation"), subtitle: L("settings.automation.subtitle")) {
                rows
            }
            .onAppear(perform: load)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: L("automation.title"), subtitle: L("settings.automation.subtitle"))
                ScrollView {
                    rows
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
                SheetFooter {
                    Button(L("common.done")) { dismiss() }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .sheetFrame(width: 620, height: 640)
            // Esc closes it as well: Done was Return only.
            .onExitCommand { dismiss() }
            .background(Theme.raised)
            .onAppear(perform: load)
        }
    }

    /// The design's page: the switch with what it allows, then its port, its token, its state, where
    /// Selenium's address is, and a command to try it with. The same actions as ever.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if AutomationServer.isAvailable {
                SettingRow(L("automation.enabled"), detail: L("automation.note"), effect: .now) {
                    SettingSwitch(isOn: $enabled, label: L("automation.enabled"))
                }
                .onChange(of: enabled) { _, on in apply(enabled: on) }
                if !model.allowsAutomation {
                    Text(L("automation.notInPlan"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.warningTint))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.warningLine))
                        .padding(.vertical, 8)
                }
                SettingCustomRow(L("automation.port")) {
                    Text(L("automation.port.detail"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if portValue == nil {
                        Text(String(format: L("automation.error.port.range"), AutomationSettings.ports.lowerBound, AutomationSettings.ports.upperBound))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.danger)
                    }
                } control: {
                    HStack(spacing: 8) {
                        TextField(L("automation.port"), text: $port, prompt: Text(verbatim: ""))
                            .lumenField(error: portValue == nil)
                            .frame(width: 90)
                            .onSubmit { apply(enabled: enabled) }
                        Button(L("automation.port.apply")) { apply(enabled: enabled) }
                            .buttonStyle(.lumenSecondary)
                            .disabled(portValue == nil || portValue == settings?.port)
                    }
                }
                tokenRow
                SettingRow(L("automation.state"), detail: nil, effect: nil) {
                    Text(stateText)
                        .font(.lumenBody)
                        .foregroundStyle(stateColor)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
                // Selenium drives a profile through this API (docs/AUTOMATION.md, "WebDriver"): where a
                // profile's address for it is found, and Help's page on connecting it.
                SettingRow(L("automation.webDriver"), detail: L("automation.webDriver.detail"), effect: nil) {
                    Button(L("automation.webDriver.how")) {
                        model.helpTopic = .webdriver
                        openWindow(id: "help")
                    }
                    .buttonStyle(.lumenGhost)
                }
                SettingsCaption(L("automation.example"))
                // The command shows the token as the token's row does: as dots until Show is pressed.
                Text(verbatim: exampleCommand(token: revealed ? (settings?.token ?? "") : String(repeating: "•", count: 8))) // l10n: not text
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
                HStack(alignment: .center, spacing: 16) {
                    Text(L("automation.docs"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("automation.docs.open")) {
                        model.helpTopic = .api
                        openWindow(id: "help")
                    }
                    .buttonStyle(.lumenGhost)
                    // The whole command, with the token, whatever the line above shows.
                    LumenCopyButton(text: exampleCommand(token: settings?.token ?? ""), title: L("automation.example.copy"))
                        // With the vault locked there is no token: nothing to copy, and nothing to say "Copied" of.
                        .disabled(settings == nil)
                }
                .padding(.top, 10)
            } else {
                Label(L("automation.error.sandboxed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.lumenBody)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warningTint))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warningLine, lineWidth: 1))
            }
        }
    }

    private var settings: AutomationSettings? { model.automationSettings }

    private var tokenRow: some View {
        SettingCustomRow(L("automation.token")) {
            Text(verbatim: revealed ? (settings?.token ?? "") : String(repeating: "•", count: 24)) // l10n: not text
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(L(revealed ? "automation.token" : "automation.token.hidden"))
        } control: {
            HStack(spacing: 6) {
                Button(L(revealed ? "automation.token.hide" : "automation.token.show")) { revealed.toggle() }
                    .buttonStyle(.lumenGhost)
                LumenCopyButton(text: settings?.token ?? "", title: L("automation.token.copy"))
                    .disabled(settings == nil)
                Button(L("automation.token.renew")) { model.renewAutomationToken() }
                    .buttonStyle(.lumenSecondary)
                    .help(L("automation.token.renew.note"))
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

    /// A command to try the API with, carrying `token`: the real one to copy, dots to show while
    /// the token is hidden.
    private func exampleCommand(token: String) -> String {
        "curl -s -H 'Authorization: Bearer \(token)' http://127.0.0.1:\(listeningPort)/v1/profiles"
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
        case .stopped: return Theme.textSecondary
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
}
