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
    @State private var importingCookiesFor: ProfileSummary?
    @State private var warmingUp: ProfileSummary?
    @State private var pendingDelete: ProfileSummary?
    @State private var changingPassword = false
    @State private var showingSync = false
    @State private var showingTunnel = false

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
                    Button(L("profiles.menu.tunnel")) { showingTunnel = true }
                    Divider()
                    Button(L("profiles.menu.changePassword")) { changingPassword = true }
                } label: { Label(L("profiles.menu.more"), systemImage: "ellipsis.circle") }
                Button { Task { await model.lock() } } label: { Label(L("profiles.action.lock"), systemImage: "lock") }
                    .help(L("profiles.action.lock.help"))
            }
        }
        .sheet(item: $editing) { target in ProfileEditorView(target: target) }
        .sheet(item: $passwordsFor) { profile in PasswordListView(profile: profile) }
        .sheet(item: $importingCookiesFor) { profile in CookieImportView(profile: profile) }
        .sheet(item: $warmingUp) { profile in WarmUpView(profile: profile) }
        // "Passwords…" in a browser window's AutoFill list.
        .onReceive(model.$passwordsRequest.compactMap { $0 }) { profile in
            passwordsFor = profile
            model.passwordsRequest = nil
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
        .sheet(isPresented: $showingSync) { SyncSettingsView() }
        .sheet(isPresented: $showingTunnel) { TunnelSettingsView() }
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
                                   warmUp: model.manager?.isWarmingUp(profile.id) == true
                                       ? model.manager?.warmUpRobot(for: profile.id) : nil,
                                   onLaunch: { Task { await model.launch(profile.id) } },
                                   onStop: { Task { await model.stop(profile.id) } },
                                   onNewWindow: { model.manager?.openNewWindow(profile.id) },
                                   onLibrary: { model.manager?.showLibrary(profile.id, section: .bookmarks) },
                                   onEdit: { editing = .existing(profile) },
                                   onPasswords: { passwordsFor = profile },
                                   onImportCookies: { importingCookiesFor = profile },
                                   onWarmUp: { warmingUp = profile },
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
    /// Its warm-up robot, while one runs.
    let warmUp: WarmUpRobot?
    let onLaunch: () -> Void
    let onStop: () -> Void
    let onNewWindow: () -> Void
    let onLibrary: () -> Void
    let onEdit: () -> Void
    let onPasswords: () -> Void
    let onImportCookies: () -> Void
    let onWarmUp: () -> Void
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
                Button(L("profiles.row.importCookies"), action: onImportCookies)
                Button(L("profiles.row.warmUp"), action: onWarmUp)
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
        if let warmUp {
            return String(format: L("profiles.row.warmingUp"), max(warmUp.visits.count, 1), warmUp.pageCount)
        }
        if running { return L("profiles.row.running") }
        guard let last = profile.lastLaunchedAt else { return L("profiles.row.neverLaunched") }
        return String(format: L("profiles.row.lastUsed"), last.formatted(.relative(presentation: .named)))
    }
}
