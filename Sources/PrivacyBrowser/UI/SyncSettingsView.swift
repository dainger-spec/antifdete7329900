import AppKit
import BrowserCore
import SwiftUI

/// Choose where this device syncs to and run a sync.
///
/// Lumen account = the account server, with this Mac's device token (`AccountSync`; offered while this
/// Mac is signed in). Folder = local-only transport (no server). Own server = client for
/// docs/SYNC_SERVER_API.md, its address and token typed in.
struct SyncSettingsView: View {
    /// Shown as a section of Settings: the page alone, without the sheet's title and Done.
    var embedded = false
    enum Mode: String, CaseIterable, Identifiable {
        case off, account, folder, server
        var id: String { rawValue }
        var labelKey: String {
            switch self {
            case .off: return "sync.mode.off"
            case .account: return "sync.mode.account"
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
    @State private var confirmingOff = false

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
                    Button(L("common.done")) {
                        // A server typed and not saved is saved: Return closed the sheet without it.
                        if mode == .server, serverChanged, !serverURL.isEmpty { saveServer() }
                        dismiss()
                    }
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
                LumenSegmented(selection: $mode, options: modes.map { (value: $0, title: L($0.labelKey)) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("sync.to"))
            }
            .onChange(of: mode) { oldValue, newValue in
                // Off forgets the folder or the server and its token: asked first.
                if newValue == .off, model.syncTarget != nil {
                    mode = oldValue
                    confirmingOff = true
                }
            }
            .confirmationDialog(L("sync.off.title"), isPresented: $confirmingOff, titleVisibility: .visible) {
                Button(L("sync.off.confirm"), role: .destructive) {
                    model.clearSyncTarget()
                    mode = .off
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("sync.off.message"))
            }

            switch mode {
            case .off:
                EmptyView()
            case .account:
                SettingsCaption(L("sync.mode.account"))
                SettingRow(L("sync.account.row"), detail: accountRowDetail, effect: nil) {
                    if model.syncTarget == .account {
                        Label(L("sync.account.on"), systemImage: "checkmark")
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.running)
                    } else {
                        Button(L("sync.account.turnOn")) { model.setSyncThroughAccount() }
                            .buttonStyle(.lumenSecondary)
                            .disabled(!model.accountSyncOffered)
                    }
                }
                Text(L("sync.account.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
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
                        .onSubmit(saveServer)
                }
                SettingRow(L("sync.server.token"), detail: nil, effect: nil) {
                    SecureField(L("sync.server.token"), text: $token, prompt: Text(verbatim: ""))
                        .lumenField()
                        .frame(width: 280)
                        .onSubmit(saveServer)
                }
                HStack(alignment: .top, spacing: 16) {
                    Text(L("sync.server.note"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !serverChanged, !serverURL.isEmpty {
                        Label(L("sync.server.saved"), systemImage: "checkmark")
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.running)
                    }
                    Button(L("sync.server.save"), action: saveServer)
                        .buttonStyle(.lumenSecondary)
                        .disabled(serverURL.isEmpty || !serverChanged)
                }
                .padding(.bottom, 6)
            }

            SettingsCaption(L("sync.status"))
            SettingCustomRow(statusTitle) {
                if let statusText {
                    Text(statusText)
                        .font(.lumenBody)
                        .foregroundStyle(model.lastSyncStatus?.error == nil || isHeld ? Theme.textSecondary : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.hasRunningProfiles {
                    Text(L("sync.stopFirst"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                }
                // The plan's sync space full: how much is used is on the account page (§16.1).
                if model.syncTarget == .account, (model.lastSyncStatus?.overQuota ?? 0) > 0, let page = accountPage {
                    Button(L("sync.account.openPage")) { SystemOpen.openWebsite(page) }
                        .buttonStyle(.lumenSecondary)
                        .padding(.top, 4)
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

    /// The places offered: the Lumen account while this Mac is signed in to one — or while it is the
    /// place chosen, so that it shows what it is and why it waits.
    private var modes: [Mode] {
        Mode.allCases.filter { $0 != .account || model.accountSyncOffered || model.syncTarget == .account }
    }

    /// What the chosen place is, under "Sync to".
    private var modeDetail: String {
        switch mode {
        case .off: return L("sync.off.note")
        case .account: return L("sync.to.account.detail")
        case .folder: return L("sync.to.folder.detail")
        case .server: return L("sync.to.server.detail")
        }
    }

    /// Under "Sync through the account": why it does not go when this Mac is not signed in.
    private var accountRowDetail: String {
        model.accountSyncOffered ? L("sync.account.row.detail")
            : String(format: L("sync.account.signedOut"), L("settings.section.account"))
    }

    /// The account page on the site (its quota and what is used, and "delete sync data").
    private var accountPage: URL? { model.license.configuration?.site("/account") }

    private var folderPath: String? {
        if case let .folder(_, path) = model.syncTarget { return path }
        return nil
    }

    /// The Lumen server holds sync on this device for now (`sync_on_hold`): no sync is tried before.
    private var isHeld: Bool {
        guard let held = model.lastSyncStatus?.heldUntil else { return false }
        return held > Date()
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
        // Held by the server until a date (`sync_on_hold`): what it said, not a failure of its own.
        if isHeld { return AccountSyncText.onHold(status.heldUntil) }
        if let error = status.error { return String(format: L("sync.status.failed"), when, error) }
        var parts = [String(format: L("sync.status.uploaded"), status.pushed),
                     String(format: L("sync.status.downloaded"), status.pulled)]
        if status.merged > 0 { parts.append(String(format: L("sync.status.merged"), status.merged)) }
        if status.conflicts > 0 { parts.append(String(format: L("sync.status.conflicts"), status.conflicts)) }
        if status.deferred > 0 { parts.append(String(format: L("sync.status.deferred"), status.deferred)) }
        if let overQuota = status.overQuota { parts.append(String(format: L("sync.status.overQuota"), overQuota)) }
        if let tooLarge = status.tooLarge { parts.append(String(format: L("sync.status.tooLarge"), tooLarge)) }
        var synced = parts.joined(separator: " · ")
        // The plan's sync space full: said in words, under the counts (§16.1).
        if status.overQuota != nil { synced += "\n" + L("sync.account.overQuota") }
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
        case .account: mode = .account
        case .folder: mode = .folder
        case let .server(url, savedToken):
            mode = .server
            serverURL = url.absoluteString
            token = savedToken
        }
    }

    /// What is typed is not what is saved.
    private var serverChanged: Bool {
        guard case let .server(url, savedToken)? = model.syncTarget else { return true }
        return url.absoluteString != serverURL.trimmingCharacters(in: .whitespaces) || savedToken != token
    }

    private func saveServer() {
        guard !serverURL.isEmpty else { return }
        model.setSyncServer(baseURL: serverURL, token: token)
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
