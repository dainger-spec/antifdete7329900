import AppKit
import BrowserCore
import SwiftUI

/// Choose where this device syncs to and run a sync.
///
/// Folder = local-only transport (works today, no server). Server = client for
/// docs/SYNC_SERVER_API.md (ready for a future server; none is included).
struct SyncSettingsView: View {
    /// Shown as a section of Settings: the page alone, without the sheet's title and Done.
    var embedded = false
    enum Mode: String, CaseIterable, Identifiable {
        case off, folder, server
        var id: String { rawValue }
        var labelKey: String {
            switch self {
            case .off: return "sync.mode.off"
            case .folder: return "sync.mode.folder"
            case .server: return "sync.mode.server"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .off
    @State private var serverURL = ""
    @State private var token = ""
    @State private var loaded = false

    var body: some View {
        if embedded {
            SettingsPage(title: L("settings.section.sync"), subtitle: L("settings.sync.subtitle")) {
                rows
            }
            .onAppear(perform: load)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: L("sync.title"), subtitle: L("settings.sync.subtitle"))
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

    /// The design's page: where to (off, a folder, a server) and its place, the last sync with
    /// "Sync now", and what is synced. The same actions as ever.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(L("sync.to"), detail: modeDetail, effect: .now) {
                LumenSegmented(selection: $mode, options: Mode.allCases.map { (value: $0, title: L($0.labelKey)) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("sync.to"))
            }
            .onChange(of: mode) { _, newValue in
                if newValue == .off, model.syncTarget != nil { model.clearSyncTarget() }
            }

            switch mode {
            case .off:
                EmptyView()
            case .folder:
                SettingsCaption(L("sync.folder.label"))
                SettingRow(L("sync.folder.row"), detail: L("sync.folder.row.detail"), effect: nil) {
                    HStack(spacing: 10) {
                        Text(folderPath ?? L("sync.folder.none"))
                            .font(.lumenBody)
                            .foregroundStyle(folderPath == nil ? Theme.textTertiary : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .help(folderPath ?? "")
                        Button(L("sync.folder.choose"), action: chooseFolder)
                            .buttonStyle(.lumenSecondary)
                    }
                }
                Text(L("sync.folder.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            case .server:
                SettingsCaption(L("sync.mode.server"))
                SettingRow(L("sync.server.url"), detail: nil, effect: nil) {
                    TextField(L("sync.server.url"), text: $serverURL, prompt: Text(verbatim: ""))
                        .lumenField("https://sync.example.com", isEmpty: serverURL.isEmpty) // l10n: not text
                        .frame(width: 280)
                }
                SettingRow(L("sync.server.token"), detail: nil, effect: nil) {
                    SecureField(L("sync.server.token"), text: $token, prompt: Text(verbatim: ""))
                        .lumenField()
                        .frame(width: 280)
                }
                HStack(alignment: .top, spacing: 16) {
                    Text(L("sync.server.note"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("sync.server.save")) { model.setSyncServer(baseURL: serverURL, token: token) }
                        .buttonStyle(.lumenSecondary)
                        .disabled(serverURL.isEmpty)
                }
                .padding(.bottom, 6)
            }

            SettingsCaption(L("sync.status"))
            SettingCustomRow(statusTitle) {
                if let statusText {
                    Text(statusText)
                        .font(.lumenBody)
                        .foregroundStyle(model.lastSyncStatus?.error == nil ? Theme.textSecondary : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.hasRunningProfiles {
                    Text(L("sync.stopFirst"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
            } control: {
                HStack(spacing: 8) {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Button(L("sync.now")) { Task { await model.syncNow() } }
                        .buttonStyle(.lumenSecondary)
                        .disabled(model.syncTarget == nil || model.isWorking || model.hasRunningProfiles)
                }
            }

            SettingsCaption(L("sync.what"))
            SettingRow(L("sync.what.row"), detail: L("sync.footer"), effect: nil) { EmptyView() }
        }
    }

    /// What the chosen place is, under "Sync to".
    private var modeDetail: String {
        switch mode {
        case .off: return L("sync.off.note")
        case .folder: return L("sync.to.folder.detail")
        case .server: return L("sync.to.server.detail")
        }
    }

    private var folderPath: String? {
        if case let .folder(_, path) = model.syncTarget { return path }
        return nil
    }

    /// The last sync as the row's title, as the sidebar says it ("Synced 4 minutes ago").
    private var statusTitle: String {
        guard let status = model.lastSyncStatus else { return L("profiles.sync.notYet") }
        if status.error != nil { return L("profiles.sync.failed") }
        return String(format: L("profiles.sync.synced"), status.date.shownRelative)
    }

    /// Under it: what went and came, or when and why it failed; and with whose master password a
    /// new device joins.
    private var statusText: String? {
        guard let status = model.lastSyncStatus else { return nil }
        let when = status.date.shown(date: .abbreviated, time: .shortened)
        if let error = status.error { return String(format: L("sync.status.failed"), when, error) }
        var parts = [String(format: L("sync.status.uploaded"), status.pushed),
                     String(format: L("sync.status.downloaded"), status.pulled)]
        if status.merged > 0 { parts.append(String(format: L("sync.status.merged"), status.merged)) }
        if status.conflicts > 0 { parts.append(String(format: L("sync.status.conflicts"), status.conflicts)) }
        if status.deferred > 0 { parts.append(String(format: L("sync.status.deferred"), status.deferred)) }
        let synced = parts.joined(separator: " · ")
        // Whose master password a new device joins with (SyncReport.PasswordHeader).
        switch status.passwordHeader {
        case .published?: return synced + "\n" + L("sync.status.passwordPublished")
        case .newerElsewhere?: return synced + "\n" + L("sync.status.passwordNewerElsewhere")
        case .differentElsewhere?: return synced + "\n" + L("sync.status.passwordDifferentElsewhere")
        case .same?, nil: return synced
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch model.syncTarget {
        case .none: mode = .off
        case .folder: mode = .folder
        case let .server(url, savedToken):
            mode = .server
            serverURL = url.absoluteString
            token = savedToken
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = L("sync.folder.panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setSyncFolder(url)
    }
}
