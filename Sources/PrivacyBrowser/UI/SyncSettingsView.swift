import AppKit
import BrowserCore
import SwiftUI

/// Choose where this device syncs to and run a sync.
///
/// Folder = local-only transport (works today, no server). Server = client for
/// docs/SYNC_SERVER_API.md (ready for a future server; none is included).
struct SyncSettingsView: View {
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
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("sync.title"))
            Form {
                Picker(L("sync.to"), selection: $mode) {
                    ForEach(Mode.allCases) { Text(L($0.labelKey)).tag($0) }
                }
                .onChange(of: mode) { _, newValue in
                    if newValue == .off, model.syncTarget != nil { model.clearSyncTarget() }
                }

                switch mode {
                case .off:
                    Text(L("sync.off.note")).foregroundStyle(.secondary)
                case .folder:
                    LabeledContent(L("sync.folder.label")) {
                        HStack {
                            Text(folderPath ?? L("sync.folder.none")).lineLimit(1).truncationMode(.middle)
                            Button(L("sync.folder.choose"), action: chooseFolder)
                        }
                    }
                    Text(L("sync.folder.note")).font(.caption).foregroundStyle(.secondary)
                case .server:
                    TextField(L("sync.server.url"), text: $serverURL, prompt: Text(verbatim: "https://sync.example.com"))
                    SecureField(L("sync.server.token"), text: $token)
                    Button(L("sync.server.save")) { model.setSyncServer(baseURL: serverURL, token: token) }
                        .disabled(serverURL.isEmpty)
                    Text(L("sync.server.note")).font(.caption).foregroundStyle(.secondary)
                }

                Section(L("sync.status")) {
                    Text(statusText).foregroundStyle(model.lastSyncStatus?.error == nil ? Color.secondary : Theme.danger)
                    HStack {
                        Button(L("sync.now")) { Task { await model.syncNow() } }
                            .disabled(model.syncTarget == nil || model.isWorking || model.hasRunningProfiles)
                        if model.isWorking { ProgressView().controlSize(.small) }
                        if model.hasRunningProfiles {
                            Text(L("sync.stopFirst")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(L("sync.footer")).font(.caption).foregroundStyle(.secondary)
            }
            .lumenForm()
            SheetFooter {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 540)
        .background(Theme.raised)
        .onAppear(perform: load)
    }

    private var folderPath: String? {
        if case let .folder(_, path) = model.syncTarget { return path }
        return nil
    }

    private var statusText: String {
        guard let status = model.lastSyncStatus else { return L("sync.status.never") }
        let when = status.date.formatted(date: .abbreviated, time: .shortened)
        if let error = status.error { return String(format: L("sync.status.failed"), when, error) }
        var parts = [String(format: L("sync.status.uploaded"), status.pushed),
                     String(format: L("sync.status.downloaded"), status.pulled)]
        if status.merged > 0 { parts.append(String(format: L("sync.status.merged"), status.merged)) }
        if status.conflicts > 0 { parts.append(String(format: L("sync.status.conflicts"), status.conflicts)) }
        if status.deferred > 0 { parts.append(String(format: L("sync.status.deferred"), status.deferred)) }
        return String(format: L("sync.status.ok"), when, parts.joined(separator: ", "))
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
