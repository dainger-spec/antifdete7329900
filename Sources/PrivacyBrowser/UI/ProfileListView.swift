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
        .frame(minWidth: 680, minHeight: 480)
        .alert(L("common.error"), isPresented: Binding(get: { model.errorMessage != nil },
                                                       set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
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
    @State private var showingSync = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.pageBackground)
        .toolbar {
            ToolbarItemGroup {
                if model.isWorking { ProgressView().controlSize(.small) }
                Menu {
                    Button(L("profiles.menu.sync")) { showingSync = true }
                    Button(L("profiles.menu.syncNow")) { Task { await model.syncNow() } }
                        .disabled(model.syncTarget == nil)
                    Divider()
                    Button(L("profiles.menu.changePassword")) { changingPassword = true }
                } label: { Label(L("profiles.menu.more"), systemImage: "ellipsis.circle") }
                Button { Task { await model.lock() } } label: { Label(L("profiles.action.lock"), systemImage: "lock") }
                    .help(L("profiles.action.lock.help"))
            }
        }
        .sheet(item: $editing) { target in ProfileEditorView(target: target) }
        .sheet(item: $passwordsFor) { profile in PasswordListView(profile: profile) }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .sheet(isPresented: $showingSync) { SyncSettingsView() }
        .confirmationDialog(String(format: L("profiles.delete.title"), pendingDelete?.name ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { profile in
            Button(L("profiles.delete.confirm"), role: .destructive) {
                Task { await model.deleteProfile(profile.id) }
            }
        } message: { _ in
            Text(L("profiles.delete.message"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "person.2.fill", size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("profiles.title")).font(.title2.bold())
                Text(String(format: L("profiles.count"), model.profiles.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = .new } label: {
                Label(L("profiles.action.new"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Theme.cardBackground)
    }

    @ViewBuilder
    private var content: some View {
        if model.profiles.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.profiles) { profile in
                        ProfileRow(profile: profile,
                                   running: model.isRunning(profile.id),
                                   busy: model.isBusy(profile.id),
                                   onLaunch: { Task { await model.launch(profile.id) } },
                                   onStop: { Task { await model.stop(profile.id) } },
                                   onNewWindow: { model.manager?.openNewWindow(profile.id) },
                                   onLibrary: { model.manager?.showLibrary(profile.id, section: .bookmarks) },
                                   onEdit: { editing = .existing(profile) },
                                   onPasswords: { passwordsFor = profile },
                                   onDelete: { pendingDelete = profile })
                    }
                }
                .padding(20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            IconBadge(symbol: "person.crop.circle.badge.plus", tint: .secondary, size: 64)
            Text(L("profiles.empty.title")).font(.title3.weight(.semibold))
            Text(L("profiles.empty.subtitle"))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { editing = .new } label: { Label(L("profiles.action.new"), systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileRow: View {
    let profile: ProfileSummary
    let running: Bool
    let busy: Bool
    let onLaunch: () -> Void
    let onStop: () -> Void
    let onNewWindow: () -> Void
    let onLibrary: () -> Void
    let onEdit: () -> Void
    let onPasswords: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                IconBadge(symbol: "globe", tint: running ? Theme.accent : .secondary, size: 40)
                if running {
                    Circle().fill(Theme.runningDot)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Theme.cardBackground, lineWidth: 2))
                        .offset(x: 15, y: 15)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if running {
                Button(L("profiles.row.newWindow"), action: onNewWindow).controlSize(.large)
                Button(L("profiles.row.stop"), action: onStop).controlSize(.large).disabled(busy)
            } else {
                Button(L("profiles.row.launch"), action: onLaunch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy)
            }
            Menu {
                if running {
                    Button(L("profiles.row.library"), action: onLibrary)
                }
                Button(L("profiles.row.edit"), action: onEdit)
                Button(L("profiles.row.passwords"), action: onPasswords)
                Divider()
                Button(L("profiles.row.delete"), role: .destructive, action: onDelete)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
        }
        .padding(14)
        .card(padding: 0)
        .overlay(alignment: .leading) {
            if running {
                RoundedRectangle(cornerRadius: 2).fill(Theme.runningDot)
                    .frame(width: 3, height: 28).padding(.leading, 1)
            }
        }
    }

    private var subtitle: String {
        if busy { return running ? L("profiles.row.starting") : L("profiles.row.encrypting") }
        if running { return L("profiles.row.running") }
        guard let last = profile.lastLaunchedAt else { return L("profiles.row.neverLaunched") }
        return String(format: L("profiles.row.lastUsed"), last.formatted(.relative(presentation: .named)))
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
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L("passwords.title"), profile.name)).font(.title3.bold())
            List {
                ForEach(entries) { entry in
                    HStack {
                        IconBadge(symbol: "key.fill", size: 28)
                        VStack(alignment: .leading) {
                            Text(entry.origin)
                            Text(entry.username.isEmpty ? L("passwords.noUsername") : entry.username)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { remove(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.fieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .frame(minHeight: 200)
            HStack {
                TextField(L("passwords.placeholder.origin"), text: $origin)
                TextField(L("passwords.placeholder.username"), text: $username)
                SecureField(L("passwords.placeholder.password"), text: $password)
                Button(L("passwords.add"), action: add).disabled(password.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .background(Theme.pageBackground)
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
            error = L("passwords.error.origin")
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
