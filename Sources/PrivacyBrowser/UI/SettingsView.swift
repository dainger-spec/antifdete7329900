import AppKit
import BrowserCore
import SwiftUI

/// Settings window (⌘,): appearance, security, sync, log.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        TabView {
            GeneralSettingsTab(preferences: preferences)
                .tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }
            SecuritySettingsTab()
                .tabItem { Label(L("settings.tab.security"), systemImage: "lock.shield") }
            LogView()
                .tabItem { Label(L("settings.tab.log"), systemImage: "doc.text.magnifyingglass") }
        }
        .frame(width: 620, height: 460)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Picker(L("settings.appearance"), selection: $preferences.appearance) {
                    ForEach(AppPreferences.Appearance.allCases) { Text(L($0.labelKey)).tag($0) }
                }
                .pickerStyle(.inline)
            } footer: {
                Text(L("settings.appearance.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(L("settings.language"), value: Localization.languageCode == "ru" ? "Русский" : "English")
            } footer: {
                Text(L("settings.language.footer")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SecuritySettingsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent(L("settings.vault.location")) {
                    Text(model.root.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if model.phase == .unlocked {
                    Button(L("profiles.menu.changePassword")) { model.sheet = .changePassword; model.activateProfilesWindow() }
                    Button(L("profiles.action.lock")) { Task { await model.lock() } }
                } else {
                    Text(L("settings.unlockFirst")).foregroundStyle(.secondary)
                }
            } header: {
                Text(L("settings.section.vault"))
            } footer: {
                Text(L("settings.vault.footer")).font(.caption).foregroundStyle(.secondary)
            }
            if model.phase == .unlocked {
                Section {
                    SyncSettingsSummary()
                } header: {
                    Text(L("sync.title"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Sync is optional and advanced; the full form stays a separate sheet.
private struct SyncSettingsSummary: View {
    @EnvironmentObject private var model: AppModel
    @State private var showing = false

    var body: some View {
        LabeledContent(L("sync.to")) {
            Text(targetDescription).foregroundStyle(.secondary)
        }
        if let last = model.lastSyncStatus {
            LabeledContent(L("settings.sync.last")) {
                Text(last.error ?? last.date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(last.error == nil ? Color.secondary : Color.red)
            }
        }
        HStack {
            Button(L("profiles.menu.sync")) { showing = true }
            Button(L("profiles.menu.syncNow")) { Task { await model.syncNow() } }
                .disabled(model.syncTarget == nil)
        }
        .sheet(isPresented: $showing) { SyncSettingsView().environmentObject(model) }
    }

    private var targetDescription: String {
        switch model.syncTarget {
        case nil: return L("sync.mode.off")
        case .folder(_, let path)?: return path
        case .server(let url, _)?: return url.host ?? url.absoluteString
        }
    }
}

/// The app's log file (Settings ▸ Log, and Help ▸ Show Log). It holds lifecycle events and error
/// codes, never page addresses, cookies or passwords (see `Log`).
struct LogView: View {
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? L("log.empty") : text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack {
                Text(L("log.footer")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("log.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button(L("log.reveal")) {
                    if let url = AppLog.shared?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button(L("log.refresh"), action: reload)
            }
            .padding(10)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        text = AppLog.shared?.tail() ?? ""
    }
}
