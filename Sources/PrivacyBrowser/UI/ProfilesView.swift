import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Group {
            switch model.phase {
            case .setup:
                if preferences.onboardingCompleted { SetupView() } else { OnboardingView(preferences: preferences) }
            case .locked: UnlockView()
            case .unlocked: ProfilesSplitView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil },
                                                               set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button(L("common.ok"), role: .cancel) {}
        } message: { alert in
            Text(alert.details.map { "\(alert.message)\n\n\(L("error.code")): \($0)" } ?? alert.message)
        }
    }
}

// MARK: - Split view

struct ProfilesSplitView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            ProfileSidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if let id = model.selectedProfileID, model.summary(id) != nil {
                ProfileDetailView(profileID: id)
                    .id(id)
            } else {
                EmptyProfilesView()
            }
        }
        .navigationTitle(L("window.profiles.title"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isWorking { ProgressView().controlSize(.small) }
                Menu {
                    Button(L("profiles.action.new")) { model.sheet = .newProfile }
                    Button(L("profiles.action.importProfile")) { ProfileActions.importProfile(model) }
                } label: {
                    Label(L("profiles.action.new"), systemImage: "plus")
                } primaryAction: {
                    model.sheet = .newProfile
                }
                .help(L("profiles.action.new.help"))
                Button { Task { await model.lock() } } label: { Label(L("profiles.action.lock"), systemImage: "lock") }
                    .help(L("profiles.action.lock.help"))
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newProfile: ProfileEditorView(target: .new)
            case .edit(let id): ProfileEditorView(target: .existing(id))
            case .rename(let id): RenameProfileView(profileID: id)
            case .passwords(let id): PasswordListView(profileID: id)
            case .exportProfile(let id): ExportProfileView(profileID: id)
            case .importProfile(let url): ImportProfileView(file: url)
            case .changePassword: ChangePasswordView()
            }
        }
        .confirmationDialog(String(format: L("profiles.delete.title"), model.pendingDelete.flatMap { model.summary($0) }?.name ?? ""),
                            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
                            presenting: model.pendingDelete) { id in
            Button(L("profiles.delete.confirm"), role: .destructive) {
                Task { await model.deleteProfile(id) }
            }
        } message: { _ in
            Text(L("profiles.delete.message"))
        }
    }
}

// MARK: - Sidebar

private struct ProfileSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section(L("sidebar.profiles")) {
                ForEach(model.profiles) { profile in
                    ProfileSidebarRow(profile: profile)
                        .tag(profile.id)
                        .contextMenu { ProfileContextMenu(profileID: profile.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.profiles.isEmpty {
                Text(L("sidebar.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}

private struct ProfileSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: ProfileSummary

    var body: some View {
        let running = model.isRunning(profile.id)
        let busy = model.isBusy(profile.id)
        let status = model.proxyState(profile.id)
        HStack(spacing: 10) {
            ProfileAvatar(name: profile.name, id: profile.id, size: 28)
                .overlay(alignment: .bottomTrailing) {
                    if running {
                        Circle().fill(Theme.runningDot)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                HStack(spacing: 4) {
                    ProxyStatusDot(status: status)
                    Text(subtitle(running: running, busy: busy, status: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.launch(profile.id) }
                } label: {
                    Image(systemName: running ? "macwindow" : "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(running ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help(running ? L("profiles.row.show.help") : L("profiles.row.launch.help"))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(running: Bool, busy: Bool, status: ProxyStatus) -> String {
        if busy { return running ? L("profiles.row.starting") : L("profiles.row.encrypting") }
        let network = model.configurations[profile.id]?.proxy.map(\.kindLabel) ?? L("proxy.none.short")
        if running { return "\(L("profiles.row.running")) · \(network)" }
        if status.isFailure { return L("proxy.status.failed") }
        return network
    }
}

/// Green (works), red (failed), gray (unchecked or no proxy), as a small dot.
struct ProxyStatusDot: View {
    let status: ProxyStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(L(status.labelKey))
            .accessibilityLabel(L(status.labelKey))
    }

    private var color: Color {
        switch status {
        case .working: return .green
        case .failed: return .red
        case .checking: return .orange
        case .unchecked: return .yellow
        case .direct: return .secondary.opacity(0.5)
        }
    }
}

struct ProfileContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let profileID: UUID

    var body: some View {
        let running = model.isRunning(profileID)
        Button(running ? L("profiles.row.show") : L("profiles.row.launch")) { Task { await model.launch(profileID) } }
        if running {
            Button(L("profiles.row.newWindow")) { model.manager?.openNewWindow(profileID) }
            Button(L("profiles.row.library")) { model.manager?.showLibrary(profileID, section: .bookmarks) }
        }
        Divider()
        Button(L("profiles.row.edit")) { model.sheet = .edit(profileID) }
        Button(L("profiles.row.rename")) { model.sheet = .rename(profileID) }
        Button(L("profiles.row.duplicate")) { model.duplicate(profileID) }
        Divider()
        Button(L("profiles.row.importCookies")) { ProfileActions.importCookies(model, profileID) }
        Menu(L("profiles.row.exportCookies")) {
            Button(L("cookies.format.netscape")) { ProfileActions.exportCookies(model, profileID, format: .netscape) }
            Button(L("cookies.format.json")) { ProfileActions.exportCookies(model, profileID, format: .json) }
        }
        Button(L("profiles.row.exportProfile")) { model.sheet = .exportProfile(profileID) }
        Button(L("profiles.row.passwords")) { model.sheet = .passwords(profileID) }
        Divider()
        Button(L("profiles.row.delete"), role: .destructive) { model.pendingDelete = profileID }
    }
}

// MARK: - Empty state

private struct EmptyProfilesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            IconBadge(symbol: "person.crop.rectangle.stack", tint: .secondary, size: 64)
            Text(L("profiles.empty.title")).font(.title2.weight(.semibold))
            Text(L("profiles.empty.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button { model.sheet = .newProfile } label: { Label(L("profiles.action.new"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button(L("profiles.action.importProfile")) { ProfileActions.importProfile(model) }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Actions with file panels

/// Import/export flows shared by the context menu, the profile page and the menu bar.
@MainActor
enum ProfileActions {
    static func importCookies(_ model: AppModel, _ id: UUID) {
        Task {
            guard let url = await FilePanels.open(titleKey: "cookies.import.title", messageKey: "cookies.import.message",
                                                  types: [.plainText, .json, .text, .data]) else { return }
            await model.importCookies(id, from: url)
        }
    }

    static func exportCookies(_ model: AppModel, _ id: UUID, format: CookieFormat) {
        let name = model.summary(id)?.name ?? "profile"
        let (ext, type): (String, UTType) = format == .json ? ("json", .json) : ("txt", .plainText)
        Task {
            guard let url = await FilePanels.save(titleKey: "cookies.export.title", messageKey: "cookies.export.message",
                                                  suggestedName: FilePanels.fileName("\(name) cookies", ext: ext),
                                                  type: type) else { return }
            await model.exportCookies(id, to: url, format: format)
        }
    }

    static func importProfile(_ model: AppModel) {
        Task {
            guard let url = await FilePanels.open(titleKey: "backup.import.title", messageKey: "backup.import.message",
                                                  types: [FilePanels.backupType]) else { return }
            model.sheet = .importProfile(url)
        }
    }
}

// MARK: - Profile page

struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    let profileID: UUID

    var body: some View {
        let summary = model.summary(profileID)
        let configuration = model.configurations[profileID]
        let running = model.isRunning(profileID)
        let busy = model.isBusy(profileID)
        Form {
            Section {
                HStack(spacing: 16) {
                    ProfileAvatar(name: summary?.name ?? "?", id: profileID, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary?.name ?? "").font(.title2.weight(.semibold)).lineLimit(1)
                        Text(statusLine(summary: summary, running: running, busy: busy))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if running {
                        Button(L("profiles.row.newWindow")) { model.manager?.openNewWindow(profileID) }
                        Button(L("profiles.row.stop")) { Task { await model.stop(profileID) } }
                        Button(L("profiles.row.show")) { Task { await model.launch(profileID) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button { Task { await model.launch(profileID) } } label: {
                            Label(L("profiles.row.launch"), systemImage: "play.fill").padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .controlSize(.large)
                .padding(.vertical, 6)
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }

            networkSection(configuration)

            Section(L("detail.section.browser")) {
                LabeledContent(L("detail.userAgent"), value: userAgentLabel(configuration))
                LabeledContent(L("detail.language"), value: configuration?.locale.map(LocaleOption.label) ?? L("detail.asSystem"))
                LabeledContent(L("detail.timeZone"), value: configuration?.timeZoneIdentifier.map(TimeZoneOption.label) ?? L("detail.asSystem"))
                LabeledContent(L("detail.startPage"), value: configuration?.startURL?.absoluteString ?? L("detail.blankPage"))
                LabeledContent(L("detail.storage"), value: configuration?.ephemeral == true ? L("detail.storage.ephemeral") : L("detail.storage.encrypted"))
                Button(L("profiles.row.edit")) { model.sheet = .edit(profileID) }
            }

            Section {
                Button(L("profiles.row.importCookies")) { ProfileActions.importCookies(model, profileID) }
                Menu(L("profiles.row.exportCookies")) {
                    Button(L("cookies.format.netscape")) { ProfileActions.exportCookies(model, profileID, format: .netscape) }
                    Button(L("cookies.format.json")) { ProfileActions.exportCookies(model, profileID, format: .json) }
                }
                .fixedSize()
                Button(L("profiles.row.exportProfile")) { model.sheet = .exportProfile(profileID) }
                Button(L("profiles.row.duplicate")) { model.duplicate(profileID) }
                Button(L("profiles.row.rename")) { model.sheet = .rename(profileID) }
                Button(L("profiles.row.passwords")) { model.sheet = .passwords(profileID) }
                if running {
                    Button(L("profiles.row.library")) { model.manager?.showLibrary(profileID, section: .bookmarks) }
                }
            } header: {
                Text(L("detail.section.data"))
            } footer: {
                Text(L("detail.data.footer")).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(L("profiles.row.delete"), role: .destructive) { model.pendingDelete = profileID }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.link)
        .disabled(busy)
        .navigationTitle(summary?.name ?? "")
        .onDisappear { model.notice = nil }
    }

    @ViewBuilder
    private func networkSection(_ configuration: ProfileConfiguration?) -> some View {
        let status = model.proxyState(profileID)
        Section {
            LabeledContent(L("detail.proxy")) {
                Text(configuration?.proxy?.displayName ?? L("proxy.none"))
                    .textSelection(.enabled)
            }
            LabeledContent(L("detail.proxyStatus")) {
                HStack(spacing: 6) {
                    if status == .checking {
                        ProgressView().controlSize(.mini)
                    } else {
                        ProxyStatusDot(status: status)
                    }
                    Text(statusText(status))
                }
            }
            if case .failed(let message) = status {
                Text(L(message.messageKey))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if configuration?.proxy != nil {
                Button(L("proxy.check")) { Task { await model.checkProxy(profileID) } }
                    .disabled(status == .checking)
            }
            if configuration?.unifiedTunnel == true {
                LabeledContent(L("detail.tunnel")) {
                    Text(L(tunnelStateKey))
                        .foregroundStyle(tunnelStateColor)
                }
            }
        } header: {
            Text(L("detail.section.network"))
        } footer: {
            Text(configuration?.proxy == nil ? L("detail.network.direct.footer") : L("detail.network.proxy.footer"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tunnelStateKey: String {
        guard ProfileTunnelController.isAvailable else { return "tunnel.state.unavailable" }
        switch model.manager?.session(for: profileID)?.tunnelController?.state {
        case .up: return "tunnel.state.up"
        case .connecting: return "tunnel.state.connecting"
        case .failed: return "tunnel.state.failed"
        default: return model.isRunning(profileID) ? "tunnel.state.down" : "tunnel.state.down"
        }
    }

    private var tunnelStateColor: Color {
        switch model.manager?.session(for: profileID)?.tunnelController?.state {
        case .up: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func statusText(_ status: ProxyStatus) -> String {
        if case .working(let ms?) = status { return String(format: L("proxy.status.workingMs"), ms) }
        return L(status.labelKey)
    }

    private func statusLine(summary: ProfileSummary?, running: Bool, busy: Bool) -> String {
        if busy { return running ? L("profiles.row.starting") : L("profiles.row.encrypting") }
        if running { return L("profiles.row.running") }
        guard let last = summary?.lastLaunchedAt else { return L("profiles.row.neverLaunched") }
        return String(format: L("profiles.row.lastUsed"), last.formatted(.relative(presentation: .named)))
    }

    private func userAgentLabel(_ configuration: ProfileConfiguration?) -> String {
        L(UserAgentOption.labelKey(configuration?.userAgentMode ?? .safariMac))
    }
}
