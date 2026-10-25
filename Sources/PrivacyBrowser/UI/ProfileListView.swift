import AppKit
import BrowserCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .setup: SetupView()
            case .locked: UnlockView()
            case .unlocked: ProfileListView()
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil },
                                             set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ProfileListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProfileEditorView.Target?
    @State private var passwordsFor: ProfileSummary?
    @State private var pendingDelete: ProfileSummary?
    @State private var changingPassword = false

    var body: some View {
        List {
            ForEach(model.profiles) { profile in
                ProfileRow(profile: profile,
                           running: model.isRunning(profile.id),
                           busy: model.isBusy(profile.id),
                           onLaunch: { Task { await model.launch(profile.id) } },
                           onStop: { Task { await model.stop(profile.id) } },
                           onNewWindow: { model.manager?.openNewWindow(profile.id) },
                           onEdit: { editing = .existing(profile) },
                           onPasswords: { passwordsFor = profile },
                           onDelete: { pendingDelete = profile })
            }
        }
        .overlay {
            if model.profiles.isEmpty {
                Text("No profiles yet. Create one with ＋.").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isWorking { ProgressView().controlSize(.small) }
                Button { editing = .new } label: { Label("New Profile", systemImage: "plus") }
                Menu {
                    Button("Sync with Folder…", action: chooseSyncFolder)
                    Button("Change Master Password…") { changingPassword = true }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                Button { Task { await model.lock() } } label: { Label("Lock", systemImage: "lock") }
                    .help("Stop all profiles, encrypt their data, and forget all keys")
            }
        }
        .sheet(item: $editing) { target in ProfileEditorView(target: target) }
        .sheet(item: $passwordsFor) { profile in PasswordListView(profile: profile) }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .confirmationDialog("Delete profile “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { profile in
            Button("Delete Profile and All Its Data", role: .destructive) {
                Task { await model.deleteProfile(profile.id) }
            }
        } message: { _ in
            Text("Cookies, site data, cache, settings and saved passwords of this profile are deleted.")
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder used as the encrypted sync store (e.g. on a NAS or external disk)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.sync(withFolder: url) }
    }
}

private struct ProfileRow: View {
    let profile: ProfileSummary
    let running: Bool
    let busy: Bool
    let onLaunch: () -> Void
    let onStop: () -> Void
    let onNewWindow: () -> Void
    let onEdit: () -> Void
    let onPasswords: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(running ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if running {
                Button("New Window", action: onNewWindow)
                Button("Stop", action: onStop).disabled(busy)
            } else {
                Button("Launch", action: onLaunch).disabled(busy)
            }
            Menu {
                Button("Edit…", action: onEdit)
                Button("Passwords…", action: onPasswords)
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if busy { return running ? "Starting…" : "Encrypting data…" }
        if running { return "Running" }
        guard let last = profile.lastLaunchedAt else { return "Never launched" }
        return "Last used " + last.formatted(.relative(presentation: .named))
    }
}

struct PasswordListView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PasswordEntry] = []
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved passwords — \(profile.name)").font(.headline)
            List {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.origin)
                            Text(entry.username.isEmpty ? "(no username)" : entry.username)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 180)
            HStack {
                TextField("https://site.example", text: $origin)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Button("Add", action: add).disabled(password.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 420)
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            entries = try model.passwordVault(for: profile.id).allEntries()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespaces)),
              let normalized = PasswordEntry.normalizedOrigin(for: url) else {
            error = "Origin must be an http(s) URL"
            return
        }
        do {
            try model.passwordVault(for: profile.id).upsert(PasswordEntry(origin: normalized, username: username, password: password))
            origin = ""; username = ""; password = ""; error = nil
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ entry: PasswordEntry) {
        do {
            try model.passwordVault(for: profile.id).remove(id: entry.id)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
