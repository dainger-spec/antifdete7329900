import AppKit
import BrowserCore
import SwiftUI

/// Choose where this device syncs to and run a sync.
///
/// Folder = local-only transport (works today, no server). Server = client for
/// docs/SYNC_SERVER_API.md (ready for a future server; none is included).
struct SyncSettingsView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off"
        case folder = "Folder (local-only)"
        case server = "Server"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .off
    @State private var serverURL = ""
    @State private var token = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Picker("Sync to", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: mode) { _, newValue in
                if newValue == .off, model.syncTarget != nil { model.clearSyncTarget() }
            }

            switch mode {
            case .off:
                Text("Sync is off. Nothing leaves this Mac.").foregroundStyle(.secondary)
            case .folder:
                LabeledContent("Folder") {
                    HStack {
                        Text(folderPath ?? "None chosen").lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Encrypted blobs are written to this folder (a NAS share, an external disk). Use one folder per vault. Concurrent writes from two Macs through a file-syncing service can produce conflict copies, which are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            case .server:
                TextField("Server URL", text: $serverURL, prompt: Text("https://sync.example.com"))
                SecureField("Access token", text: $token)
                Button("Save Server") { model.setSyncServer(baseURL: serverURL, token: token) }
                    .disabled(serverURL.isEmpty)
                Text("Client for the API in docs/SYNC_SERVER_API.md. No server is included in this project; HTTPS is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(statusText).foregroundStyle(model.lastSyncStatus?.error == nil ? Color.secondary : Color.red)
                HStack {
                    Button("Sync Now") { Task { await model.syncNow() } }
                        .disabled(model.syncTarget == nil || model.isWorking || model.hasRunningProfiles)
                    if model.isWorking { ProgressView().controlSize(.small) }
                    if model.hasRunningProfiles {
                        Text("Stop all profiles first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Synced, end-to-end encrypted: profile list, settings, saved passwords, bookmarks, history. Not synced: website data (cookies, storage, cache). The sync location can see object counts, sizes, timing, and the vault header needed to unlock with the master password.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear(perform: load)
    }

    private var folderPath: String? {
        if case let .folder(_, path) = model.syncTarget { return path }
        return nil
    }

    private var statusText: String {
        guard let status = model.lastSyncStatus else { return "Never synced." }
        let when = status.date.formatted(date: .abbreviated, time: .shortened)
        if let error = status.error { return "Last attempt \(when) failed: \(error)" }
        var parts = ["\(status.pushed) uploaded", "\(status.pulled) downloaded"]
        if status.merged > 0 { parts.append("\(status.merged) merged") }
        if status.conflicts > 0 { parts.append("\(status.conflicts) conflicts (remote kept, local copy saved)") }
        if status.deferred > 0 { parts.append("\(status.deferred) deferred to next sync") }
        return "Last sync \(when): " + parts.joined(separator: ", ")
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
        panel.message = "Choose a folder to use as the encrypted sync store."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setSyncFolder(url)
    }
}
