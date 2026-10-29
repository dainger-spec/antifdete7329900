import AppKit
import BrowserCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .setup: SetupView().transition(.opacity)
            case .locked: UnlockView().transition(.opacity)
            case .unlocked: ProfileListView().transition(.opacity)
            }
        }
        .animation(Theme.appearAnimation, value: model.phase)
        .frame(minWidth: ProfilesScreen.minimumWindowWidth, minHeight: 560)
        .background(Theme.surface)
        .tint(Theme.accentFill)
        .alert(L("common.error"), isPresented: Binding(get: { model.errorMessage != nil },
                                                       set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The Profiles window once unlocked: builds `ProfilesScreen`'s rows from the app model and owns
/// the sheets its actions open.
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
    @State private var filter: ProfileFilter = .all
    @State private var search = ""

    var body: some View {
        ProfilesScreen(rows: rows, isWorking: model.isWorking, sync: syncLine,
                       filter: $filter, search: $search, actions: actions)
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

    private var rows: [ProfileRowItem] {
        model.profiles.map { profile in
            let running = model.isRunning(profile.id)
            let busy = model.isBusy(profile.id)
            let details = model.details[profile.id]
            let activity: ProfileRowItem.Activity = busy ? (running ? .starting : .sealing) : (running ? .running : .stopped)
            let warmUp = model.manager?.warmUpStatus(of: profile.id)
            return ProfileRowItem(
                id: profile.id, name: profile.name, activity: activity,
                exit: details?.proxyEndpoint.map { ProfileExit.proxy(endpoint: $0, countryCode: details?.exitCountryCode) } ?? .direct,
                ephemeral: details?.ephemeral ?? false,
                appearsAs: ProfileRowItem.appearsAs(details?.deviceGeneration ?? DeviceGenerations.resolved(id: nil)),
                lastUsed: profile.lastLaunchedAt,
                warmUp: warmUp.flatMap { $0.isRunning ? $0 : nil })
        }
    }

    private var syncLine: SyncLine {
        if model.isSyncInProgress { return .syncing }
        guard model.syncTarget != nil else { return .off }
        guard let status = model.lastSyncStatus else { return .notYet }
        return status.error == nil ? .synced(status.date) : .failed
    }

    private func summary(_ id: UUID) -> ProfileSummary? { model.profiles.first { $0.id == id } }

    private var actions: ProfileActions {
        ProfileActions(
            newProfile: { editing = .new },
            launch: { id in Task { await model.launch(id) } },
            stop: { id in Task { await model.stop(id) } },
            newWindow: { id in model.manager?.openNewWindow(id) },
            library: { id in model.manager?.showLibrary(id, section: .bookmarks) },
            edit: { id in
                if let profile = summary(id) { editing = .existing(profile) }
            },
            passwords: { id in passwordsFor = summary(id) },
            importCookies: { id in importingCookiesFor = summary(id) },
            warmUp: { id in warmingUp = summary(id) },
            delete: { id in pendingDelete = summary(id) },
            lock: { Task { await model.lock() } },
            openSync: { showingSync = true },
            syncNow: model.syncTarget == nil ? nil : { Task { await model.syncNow() } },
            openTunnel: { showingTunnel = true },
            changePassword: { changingPassword = true })
    }
}

// MARK: - What the screen shows

/// One profile, as its row shows it.
struct ProfileRowItem: Identifiable {
    enum Activity: Equatable { case stopped, starting, running, sealing }

    let id: UUID
    var name: String
    var activity: Activity
    var exit: ProfileExit
    var ephemeral: Bool
    var appearsAs: String
    var lastUsed: Date?
    /// The warm-up of this profile while one runs, as the profile's process last reported it.
    var warmUp: WarmUpStatus?

    var isRunning: Bool { activity == .running }
    var isBusy: Bool { activity == .starting || activity == .sealing }
    /// Grouped under "Running" (also while it starts or seals).
    var isActive: Bool { activity != .stopped }
    var usesProxy: Bool { if case .proxy = exit { return true } else { return false } }

    /// "Mac · Safari 26", "iPhone · Safari 26": the device the profile presents as.
    static func appearsAs(_ generation: DeviceGeneration) -> String {
        let device: String
        switch generation.platform {
        case .macOS: device = L("profiles.device.mac")
        case .iOS: device = L("profiles.device.iphone")
        case .iPadOS: device = L("profiles.device.ipad")
        }
        return String(format: L("profiles.appearsAs"), device, generation.osVersionLabel)
    }
}

/// Where a profile's traffic leaves for the web.
enum ProfileExit: Equatable {
    case direct
    /// Through a proxy; its exit country once a lookup through it found one.
    case proxy(endpoint: String, countryCode: String?)
}

enum ProfileFilter: Hashable, CaseIterable {
    case all, running, proxied, ephemeral

    var titleKey: String {
        switch self {
        case .all: return "profiles.filter.all"
        case .running: return "profiles.filter.running"
        case .proxied: return "profiles.filter.proxied"
        case .ephemeral: return "profiles.filter.ephemeral"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "person.2"
        case .running: return "play.circle"
        case .proxied: return "network"
        case .ephemeral: return "hourglass"
        }
    }

    func includes(_ row: ProfileRowItem) -> Bool {
        switch self {
        case .all: return true
        case .running: return row.isActive
        case .proxied: return row.usesProxy
        case .ephemeral: return row.ephemeral
        }
    }
}

/// The sidebar's sync line.
enum SyncLine: Equatable {
    case off, notYet, syncing, failed
    case synced(Date)
}

/// What the screen's controls do (closures, so previews can pass none).
struct ProfileActions {
    var newProfile: () -> Void = {}
    var launch: (UUID) -> Void = { _ in }
    var stop: (UUID) -> Void = { _ in }
    var newWindow: (UUID) -> Void = { _ in }
    var library: (UUID) -> Void = { _ in }
    var edit: (UUID) -> Void = { _ in }
    var passwords: (UUID) -> Void = { _ in }
    var importCookies: (UUID) -> Void = { _ in }
    var warmUp: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var lock: () -> Void = {}
    var openSync: () -> Void = {}
    /// Nil while no sync target is set.
    var syncNow: (() -> Void)?
    var openTunnel: () -> Void = {}
    var changePassword: () -> Void = {}
}

// MARK: - The screen

/// The Profiles window: a sidebar (lockup, filters, sync state, Lock) and a table of profiles in
/// two groups — running ones first, then the ones ready to launch. Pure presentation: everything
/// it shows comes in `rows`, everything it does goes out through `actions`.
struct ProfilesScreen: View {
    let rows: [ProfileRowItem]
    var isWorking = false
    var sync: SyncLine = .off
    @Binding var filter: ProfileFilter
    @Binding var search: String
    var actions = ProfileActions()

    static let sidebarWidth: CGFloat = 208
    /// The table's columns drop "Appears as", then "Last used", below these content widths.
    static let minimumWindowWidth: CGFloat = 920

    var body: some View {
        HStack(spacing: 0) {
            ProfilesSidebar(rows: rows, sync: sync, filter: $filter, actions: actions)
                .frame(width: Self.sidebarWidth)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.divider).frame(height: 1)
                content
            }
            .background(Theme.surface)
        }
        .background(Theme.surface)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.colorScheme, .dark)
    }

    private var visibleRows: [ProfileRowItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            filter.includes(row) && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    title
                    Text(countLine)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                title
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if isWorking {
                ProgressView().controlSize(.small).transition(.opacity)
            }
            LumenSearchField(text: $search, prompt: L("profiles.search"))
                .frame(width: 200)
            Menu {
                Button(L("profiles.menu.sync"), action: actions.openSync)
                Button(L("profiles.menu.syncNow")) { actions.syncNow?() }
                    .disabled(actions.syncNow == nil)
                Divider()
                Button(L("profiles.menu.tunnel"), action: actions.openTunnel)
                Divider()
                Button(L("profiles.menu.changePassword"), action: actions.changePassword)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.textSecondary)
            .fixedSize()
            .frame(width: 28, height: 28)
            .hoverHighlight(cornerRadius: Theme.controlRadius)
            .help(L("profiles.menu.more"))
            .accessibilityLabel(L("profiles.menu.more"))
            Button(action: actions.newProfile) {
                Label(L("profiles.action.new"), systemImage: "plus")
            }
            .buttonStyle(.lumenPrimary)
            .keyboardShortcut("n")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(Theme.surface)
        .animation(Theme.hoverAnimation, value: isWorking)
    }

    private var title: some View {
        Text(L("profiles.title"))
            .font(.lumenTitle)
            .kerning(-0.2)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize()
    }

    private var countLine: String {
        let running = rows.filter(\.isActive).count
        return running > 0
            ? String(format: L("profiles.countRunning"), rows.count, running)
            : String(format: L("profiles.count"), rows.count)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            EmptyProfilesView(onNew: actions.newProfile)
        } else if visibleRows.isEmpty {
            NoMatchesView {
                withAnimation(Theme.appearAnimation) {
                    filter = .all
                    search = ""
                }
            }
        } else {
            GeometryReader { geometry in
                let columns = ProfileColumns(contentWidth: geometry.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        columnHeader(columns)
                        let active = visibleRows.filter(\.isActive)
                        let ready = visibleRows.filter { !$0.isActive }
                        if !active.isEmpty { group(L("profiles.group.running"), active, columns) }
                        if !ready.isEmpty { group(L("profiles.group.ready"), ready, columns) }
                        footnote
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.automatic)
                .animation(Theme.appearAnimation, value: visibleRows.filter(\.isActive).map(\.id))
            }
            .transition(.opacity)
        }
    }

    private func columnHeader(_ columns: ProfileColumns) -> some View {
        HStack(spacing: ProfileColumns.gap) {
            Text(L("profiles.column.name")).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ProfileColumns.nameInset)
            Text(L("profiles.column.exit")).frame(width: ProfileColumns.exit, alignment: .leading)
            if columns.showsAppearsAs {
                Text(L("profiles.column.appearsAs")).frame(width: ProfileColumns.appearsAs, alignment: .leading)
            }
            if columns.showsLastUsed {
                Text(L("profiles.column.lastUsed")).frame(width: ProfileColumns.lastUsed, alignment: .leading)
            }
            Color.clear.frame(width: ProfileColumns.actions, height: 1)
        }
        .font(.lumenColumn)
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, ProfileColumns.rowPadding)
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .padding(.top, 8)
    }

    private func group(_ title: String, _ rows: [ProfileRowItem], _ columns: ProfileColumns) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                Text(verbatim: "\(rows.count)").font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            .padding(.horizontal, ProfileColumns.rowPadding)
            .frame(height: 36, alignment: .bottomLeading)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                ProfileRow(row: row, columns: columns, actions: actions)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, ProfileColumns.nameInset + ProfileColumns.rowPadding)
                    }
            }
        }
    }

    private var footnote: some View {
        Label(L("profiles.footnote.sealed"), systemImage: "lock")
            .font(.lumenSecondary)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, ProfileColumns.rowPadding)
            .padding(.top, 16)
    }
}

/// Column widths, and which optional columns fit (the name column takes what is left).
struct ProfileColumns {
    static let gap: CGFloat = 12
    static let rowPadding: CGFloat = 12
    /// The status dot's slot plus the avatar: where names start.
    static let nameInset: CGFloat = 7 + 8 + 28 + 10
    static let exit: CGFloat = 184
    static let appearsAs: CGFloat = 128
    static let lastUsed: CGFloat = 96
    static let actions: CGFloat = 236
    static let minimumName: CGFloat = 200

    let showsAppearsAs: Bool
    let showsLastUsed: Bool

    init(contentWidth: CGFloat) {
        // 20 pt page margins and the rows' own padding on both sides.
        let fixed = 2 * 20 + 2 * Self.rowPadding + Self.exit + Self.actions + 2 * Self.gap + Self.minimumName
        showsLastUsed = contentWidth >= fixed + Self.lastUsed + Self.gap
        showsAppearsAs = contentWidth >= fixed + Self.lastUsed + Self.appearsAs + 2 * Self.gap
    }
}

// MARK: - Sidebar

private struct ProfilesSidebar: View {
    let rows: [ProfileRowItem]
    let sync: SyncLine
    @Binding var filter: ProfileFilter
    let actions: ProfileActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's traffic lights sit in this band.
            Color.clear.frame(height: 40)
            LumenLockup.sidebar
                .padding(.leading, 10)
                .padding(.bottom, 22)
            item(.all)
            item(.running)
            Text(L("profiles.filters"))
                .font(.lumenColumn)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 10)
                .padding(.top, 18)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            item(.proxied)
            item(.ephemeral)
            Spacer(minLength: 16)
            SyncStatusButton(sync: sync, action: actions.openSync)
                .padding(.bottom, 8)
            Button(action: actions.lock) {
                Label(L("profiles.action.lock"), systemImage: "lock")
            }
            .buttonStyle(LumenButtonStyle(kind: .secondary, fullWidth: true))
            .help(L("profiles.action.lock.help"))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func item(_ value: ProfileFilter) -> some View {
        let count = rows.filter(value.includes).count
        let selected = filter == value
        return Button {
            withAnimation(Theme.appearAnimation) { filter = value }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: value.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(L(value.titleKey))
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(count)")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(selected ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.controlRadius, isOn: !selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SyncStatusButton: View {
    let sync: SyncLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(sync == .failed ? Theme.warning : Theme.textTertiary)
                    .frame(width: 18)
                Text(text)
                    .font(.lumenSecondary)
                    .foregroundStyle(sync == .failed ? Theme.warning : Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.controlRadius)
        .help(L("profiles.menu.sync"))
    }

    private var symbol: String {
        switch sync {
        case .off: return "arrow.triangle.2.circlepath"
        case .notYet, .synced: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var text: String {
        switch sync {
        case .off: return L("profiles.sync.off")
        case .notYet: return L("profiles.sync.notYet")
        case .syncing: return L("profiles.sync.syncing")
        case .failed: return L("profiles.sync.failed")
        case .synced(let date):
            return String(format: L("profiles.sync.synced"), date.formatted(.relative(presentation: .named)))
        }
    }
}

// MARK: - Row

private struct ProfileRow: View {
    let row: ProfileRowItem
    let columns: ProfileColumns
    let actions: ProfileActions

    var body: some View {
        HStack(spacing: ProfileColumns.gap) {
            nameCell.frame(maxWidth: .infinity, alignment: .leading)
            ExitLabel(exit: row.exit).frame(width: ProfileColumns.exit, alignment: .leading)
            if columns.showsAppearsAs {
                Text(row.appearsAs)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: ProfileColumns.appearsAs, alignment: .leading)
            }
            if columns.showsLastUsed {
                Text(lastUsed)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: ProfileColumns.lastUsed, alignment: .leading)
            }
            actionsCell.frame(width: ProfileColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, ProfileColumns.rowPadding)
        .frame(height: 48)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: Theme.controlRadius)
        .opacity(row.activity == .sealing ? 0.6 : 1)
        .contextMenu { ProfileMenuItems(row: row, actions: actions) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(row.name))
    }

    private var nameCell: some View {
        HStack(spacing: 0) {
            ZStack {
                if row.isRunning { RunningDot().transition(.opacity) }
            }
            .frame(width: 7)
            .padding(.trailing, 8)
            ProfileAvatar(name: row.name, id: row.id, size: 28)
                .padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitle
            }
        }
        .animation(Theme.hoverAnimation, value: row.activity)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch row.activity {
        case .starting:
            busyLine(L("profiles.row.starting"))
        case .sealing:
            busyLine(L("profiles.row.encrypting"))
        case .running:
            if let warmUp = row.warmUp {
                WarmUpLine(status: warmUp)
            } else {
                secondaryLine(L("profiles.row.running"))
            }
        case .stopped:
            if row.ephemeral { secondaryLine(L("profiles.row.ephemeral")) }
        }
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            secondaryLine(text)
        }
    }

    private var lastUsed: String {
        if row.isActive { return L("profiles.lastUsed.now") }
        guard let date = row.lastUsed else { return L("profiles.lastUsed.never") }
        return date.formatted(.relative(presentation: .named))
    }

    private var actionsCell: some View {
        HStack(spacing: 8) {
            switch row.activity {
            case .running:
                Button(L("profiles.row.newWindow")) { actions.newWindow(row.id) }
                    .buttonStyle(.lumenGhost)
                Button(L("profiles.row.stop")) { actions.stop(row.id) }
                    .buttonStyle(.lumenSecondary)
            case .stopped:
                Button(L("profiles.row.launch")) { actions.launch(row.id) }
                    .buttonStyle(.lumenSecondary)
            case .starting, .sealing:
                EmptyView()
            }
            Menu {
                ProfileMenuItems(row: row, actions: actions)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.textSecondary)
            .fixedSize()
            .frame(width: 28, height: 28)
            .hoverHighlight(cornerRadius: Theme.controlRadius)
            .disabled(row.isBusy)
            .accessibilityLabel(String(format: L("profiles.row.moreFor"), row.name))
        }
    }
}

/// The ⋯ menu and the row's context menu.
private struct ProfileMenuItems: View {
    let row: ProfileRowItem
    let actions: ProfileActions

    var body: some View {
        if row.isRunning {
            Button(L("profiles.row.library")) { actions.library(row.id) }
        }
        Button(L("profiles.row.edit")) { actions.edit(row.id) }
        Button(L("profiles.row.passwords")) { actions.passwords(row.id) }
        Button(L("profiles.row.importCookies")) { actions.importCookies(row.id) }
        Button(L("profiles.row.warmUp")) { actions.warmUp(row.id) }
        Divider()
        Button(L("profiles.row.delete"), role: .destructive) { actions.delete(row.id) }
    }
}

/// Where a profile exits: the proxy's country with its flag, the proxy's address while its
/// country is unknown, or "Direct".
struct ExitLabel: View {
    let exit: ProfileExit
    var flagSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            switch exit {
            case .direct:
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: flagSize)
                Text(L("profiles.exit.direct"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
            case let .proxy(endpoint, code?):
                CountryFlag(code: code, size: flagSize)
                Text(CountryNames.name(for: code))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .help(String(format: L("profiles.exit.viaProxy"), endpoint))
            case let .proxy(endpoint, nil):
                Image(systemName: "network")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: flagSize)
                Text(endpoint)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .truncationMode(.middle)
                    .help(L("profiles.exit.unknownCountry"))
            }
        }
        .lineLimit(1)
    }
}

/// A warm-up's progress in the profile's row: which page of how many, a bar, and how many cookies
/// the run has collected so far — the number the whole thing is for.
private struct WarmUpLine: View {
    let status: WarmUpStatus

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: L("profiles.row.warmUpShort"), status.currentPage, status.total))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .monospacedDigit()
                .fixedSize()
            LumenProgressBar(fraction: status.fraction, width: 48)
            if status.cookies > 0 {
                Text(String(format: L("profiles.row.warmUpCookies"), status.cookies))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .help(String(format: L("profiles.row.warmingUp"), status.currentPage, status.total))
    }
}

// MARK: - Empty states

private struct EmptyProfilesView: View {
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LumenGlyph(size: 44, color: Theme.textTertiary.opacity(0.55))
                .padding(.bottom, 20)
            Text(L("profiles.empty.title"))
                .font(.lumenSheetTitle)
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)
            Text(L("profiles.empty.subtitle"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.bottom, 20)
            Button(action: onNew) { Label(L("profiles.action.new"), systemImage: "plus") }
                .buttonStyle(.lumenPrimary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoMatchesView: View {
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)
            Text(L("profiles.noMatches"))
                .font(.lumenLabel)
                .foregroundStyle(Theme.textSecondary)
            Button(L("profiles.showAll"), action: onShowAll)
                .buttonStyle(.lumenGhost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A search field in Lumen's field style, with its magnifier and a clear button.
struct LumenSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField(text: $text, prompt: Text(verbatim: "")) {
                Text(prompt)
            }
            .textFieldStyle(.plain)
            .font(.lumenBody)
            .focused($focused)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    // Lumen's placeholder: macOS draws an unfocused field's prompt almost as bright as text.
                    Text(prompt)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel(L("profiles.search.clear"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .strokeBorder(focused ? Theme.accent : Theme.fieldBorder, lineWidth: 1))
        .animation(Theme.hoverAnimation, value: focused)
    }
}
