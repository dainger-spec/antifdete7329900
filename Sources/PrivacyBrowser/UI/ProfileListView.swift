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
    @Environment(\.openSettings) private var openSettings
    @State private var editing: ProfileEditorView.Target?
    @State private var passwordsFor: ProfileSummary?
    @State private var importingCookiesFor: ProfileSummary?
    @State private var warmingUp: ProfileSummary?
    @State private var whatSitesSeeFor: ProfileSummary?
    @State private var warmingUpSeveral = false
    /// The profiles the warm-up queue opens with ticked (the selection's bar).
    @State private var queuePreselection: Set<UUID> = []
    @State private var exporting: ProfileSummary?
    @State private var exportingCookies: ProfileSummary?
    @State private var importingProfile = false
    @State private var pendingDelete: ProfileSummary?
    @State private var changingPassword = false
    @State private var showingSync = false
    @State private var showingTunnel = false
    @State private var showingAutomation = false
    @State private var filter: ProfileFilter = .all
    @State private var search = ""
    /// What a profile whose proxy does not work says; "Show in Proxies" goes from it to the
    /// window's Proxies section, with that proxy selected.
    @State private var proxySheet: ProxySheet?
    /// The window's section (the profiles, or the proxy list), and the proxies selected there.
    @State private var section: ProfilesSection = .profiles
    @State private var proxySelection: Set<UUID> = []
    @State private var assigningProxies: ProxyAssignView.Request?
    /// Profiles of the selection waiting for the one confirmation that deletes them all.
    @State private var pendingBulkDelete: [UUID] = []

    var body: some View {
        screen
            .sheet(item: $editing) { target in ProfileEditorView(target: target) }
            .sheet(item: $passwordsFor) { profile in PasswordListView(profile: profile) }
            .sheet(item: $importingCookiesFor) { profile in CookieImportView(profile: profile) }
            .sheet(item: $warmingUp) { profile in WarmUpView(profile: profile) }
            .sheet(item: $whatSitesSeeFor) { profile in
                WhatSitesSeeView(name: profile.name, snapshot: WhatSitesSee(profileID: profile.id, manager: { model.manager },
                                                                            launch: { await model.launch($0) }))
            }
            .sheet(isPresented: $warmingUpSeveral) { WarmUpQueueView(preselected: queuePreselection) }
            .sheet(item: $exporting) { profile in ProfileExportView(profile: profile) }
            .sheet(item: $exportingCookies) { profile in CookieExportView(profile: profile) }
            .sheet(isPresented: $importingProfile) { ProfileImportView() }
            // "Passwords…" in a browser window's AutoFill list.
            .onReceive(model.$passwordsRequest.compactMap { $0 }) { profile in
                passwordsFor = profile
                model.passwordsRequest = nil
            }
            .sheet(isPresented: $changingPassword) { ChangePasswordView() }
            .sheet(isPresented: $showingSync) { SyncSettingsView() }
            .sheet(isPresented: $showingTunnel) { TunnelSettingsView() }
            .sheet(isPresented: $showingAutomation) { AutomationSettingsView() }
            .confirmationDialog(String(format: L("profiles.delete.title"), pendingDelete?.name ?? ""),
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { profile in
                Button(L("profiles.delete.confirm"), role: .destructive) {
                    Task { await model.deleteProfile(profile.id) }
                }
            } message: { _ in
                Text(L("profiles.delete.message"))
            }
            .sheet(item: $proxySheet, onDismiss: showProxyProblems) { _ in
                ProxyProblemView { id in showProxies(selecting: [id]) }
            }
            .onChange(of: section) { _, _ in showProxyProblems() }
            // A profile that was started with a proxy that does not work.
            .onReceive(model.$proxyProblems) { problems in
                if !problems.isEmpty, proxySheet == nil { proxySheet = .problems }
            }
            // Settings → Proxies → the list.
            .onReceive(model.$proxiesRequest) { requested in
                guard requested else { return }
                model.proxiesRequest = false
                showProxies(selecting: [])
            }
            .sheet(item: $assigningProxies) { request in ProxyAssignView(request: request) }
            // ⌘K.
            .sheet(isPresented: $model.showingPalette) {
                CommandPaletteView(commands: paletteCommands, onClose: { model.showingPalette = false })
            }
            .confirmationDialog(String(format: L("profiles.bulk.delete.title"), pendingBulkDelete.count),
                                isPresented: Binding(get: { !pendingBulkDelete.isEmpty }, set: { if !$0 { pendingBulkDelete = [] } }),
                                titleVisibility: .visible,
                                presenting: pendingBulkDelete.isEmpty ? nil : pendingBulkDelete) { ids in
                Button(L("profiles.bulk.delete.confirm"), role: .destructive) {
                    Task { await model.deleteProfiles(ids) }
                }
            } message: { ids in
                Text(String(format: L("profiles.bulk.delete.message"), names(ids)))
            }
    }

    /// What the command palette (⌘K) offers: making a profile, each profile's own commands, the
    /// proxies, the warm-up queue, Lock and Sync, each section of Settings, the short report.
    private var paletteCommands: [CommandPaletteView.Command] {
        typealias Command = CommandPaletteView.Command
        let actions = self.actions
        var commands = [Command(id: "new", title: L("palette.newProfile"), symbol: "plus", run: actions.newProfile)]
        for row in rows {
            let detail = row.paletteDetail
            switch row.activity {
            case .running:
                commands.append(Command(id: "window-\(row.id)", title: String(format: L("palette.newWindow"), row.name),
                                        detail: detail, symbol: "macwindow.badge.plus", run: { actions.newWindow(row.id) }))
                commands.append(Command(id: "stop-\(row.id)", title: String(format: L("palette.stop"), row.name),
                                        detail: detail, symbol: "stop.circle", run: { actions.stop(row.id) }))
            case .stopped:
                commands.append(Command(id: "launch-\(row.id)", title: String(format: L("palette.launch"), row.name),
                                        detail: detail, symbol: "play.circle", run: { actions.launch(row.id) }))
            case .starting, .sealing:
                break
            }
            commands.append(Command(id: "edit-\(row.id)", title: String(format: L("palette.edit"), row.name),
                                    detail: detail, symbol: "slider.horizontal.3", run: { actions.edit(row.id) }))
            commands.append(Command(id: "warm-\(row.id)", title: String(format: L("palette.warmUp"), row.name),
                                    detail: detail, symbol: "flame", run: { actions.warmUp(row.id) }))
            commands.append(Command(id: "see-\(row.id)", title: String(format: L("palette.whatSitesSee"), row.name),
                                    detail: detail, symbol: "eye", run: { actions.whatSitesSee(row.id) }))
        }
        commands.append(Command(id: "proxies", title: L("palette.proxies"), symbol: "network", run: actions.openProxies))
        commands.append(Command(id: "warmQueue", title: L("profiles.menu.warmUpSeveral"), symbol: "flame", run: actions.warmUpQueue))
        if let syncNow = actions.syncNow {
            commands.append(Command(id: "sync", title: L("palette.syncNow"), symbol: "arrow.triangle.2.circlepath", run: syncNow))
        }
        commands.append(Command(id: "lock", title: L("profiles.action.lock"), symbol: "lock", run: actions.lock))
        for section in SettingsSection.allCases {
            commands.append(Command(id: "settings-\(section.rawValue)", title: String(format: L("palette.settings"), L(section.titleKey)),
                                    symbol: section.symbol, run: {
                model.settingsSection = section
                openSettings()
            }))
        }
        commands.append(Command(id: "report", title: L("settings.diagnostics.copy"), symbol: "doc.on.doc", run: {
            Task {
                let snapshot = Diagnostics.snapshot(model: model)
                let report = Diagnostics.shortReport(snapshot, checks: await Diagnostics.checks(snapshot))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }))
        return commands
    }

    /// After the Proxies section: what profiles said about their proxies meanwhile.
    /// The next profile whose proxy does not work — not over the Proxies section that "Show in
    /// Proxies" opened: the rest come when the profiles show again.
    private func showProxyProblems() {
        if proxySheet == nil, section == .profiles, !model.proxyProblems.isEmpty { proxySheet = .problems }
    }

    /// The screen, with the sidebar's count of proxies kept current as the list changes.
    @ViewBuilder
    private var screen: some View {
        if let proxyList = model.proxyList {
            ObservingProxyList(proxies: proxyList) { list in profilesScreen(proxyCount: list.entries.count) }
        } else {
            profilesScreen(proxyCount: nil)
        }
    }

    private func profilesScreen(proxyCount: Int?) -> ProfilesScreen {
        ProfilesScreen(rows: rows, isWorking: model.isWorking, sync: syncLine,
                       filter: $filter, search: $search, actions: actions,
                       section: $section, proxyCount: proxyCount,
                       proxies: AnyView(ProxyListView(selection: $proxySelection)))
    }

    /// The window's Proxies section; with `ids`, those proxies selected (else the selection it had).
    private func showProxies(selecting ids: Set<UUID>) {
        proxySheet = nil
        if !ids.isEmpty { proxySelection = ids }
        withAnimation(Theme.appearAnimation) { section = .proxies }
    }

    /// Warm-up of several profiles (the selection's bar): the warm-up queue, with them ticked.
    private func warmUpSeveral(_ ids: [UUID]) {
        queuePreselection = Set(ids)
        warmingUpSeveral = true
    }

    /// "Northwind, Harbor, Atlas and 2 more".
    private func names(_ ids: [UUID]) -> String {
        let names = ids.compactMap { summary($0)?.name }
        guard names.count > 5 else { return names.joined(separator: ", ") }
        return String(format: L("profiles.bulk.namesAndMore"), names.prefix(5).joined(separator: ", "), names.count - 5)
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
                warmUp: warmUp.flatMap { $0.isRunning ? $0 : nil },
                warmUpQueued: model.warmUps?.isWaiting(profile.id) ?? false,
                exitUnconfirmed: model.manager?.proxyLocationUnknown.contains(profile.id) ?? false,
                tags: details?.tags ?? [], notes: details?.notes ?? "", avatar: details?.avatar)
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
            exportCookies: { id in exportingCookies = summary(id) },
            warmUp: { id in warmingUp = summary(id) },
            whatSitesSee: { id in whatSitesSeeFor = summary(id) },
            exportProfile: { id in exporting = summary(id) },
            importProfile: { importingProfile = true },
            delete: { id in pendingDelete = summary(id) },
            lock: { Task { await model.lock() } },
            openSync: { showingSync = true },
            syncNow: model.syncTarget == nil ? nil : { Task { await model.syncNow() } },
            openTunnel: { showingTunnel = true },
            openAutomation: { showingAutomation = true },
            openSettings: { openSettings() },
            changePassword: { changingPassword = true },
            warmUpQueue: { queuePreselection = []; warmingUpSeveral = true },
            openProxies: { showProxies(selecting: []) },
            launchSeveral: { ids in Task { await model.launchProfiles(ids) } },
            stopSeveral: { ids in Task { await model.stopProfiles(ids) } },
            warmUpSeveral: { ids in warmUpSeveral(ids) },
            assignProxies: { ids in assigningProxies = ProxyAssignView.Request(profileIDs: Set(ids), proxyIDs: []) },
            deleteSeveral: { ids in pendingBulkDelete = ids })
    }
}

/// The proxy sheet of the Profiles window.
enum ProxySheet: Identifiable, Equatable {
    /// What profiles whose proxy does not work say (`AppModel.proxyProblems`).
    case problems

    var id: String { "problems" }
}

/// What the Profiles window's main area shows: the profiles (through a filter), or the proxy list.
enum ProfilesSection: Equatable {
    case profiles
    case proxies
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
    /// Waiting in the warm-up queue for its turn (`WarmUpCoordinator`).
    var warmUpQueued = false
    /// At its last launch no geolocation service answered through its proxy: where it exits is
    /// not confirmed (`ProfileManager.proxyLocationUnknown`).
    var exitUnconfirmed = false
    /// The person's own tags and notes for the profile, and how its glyph looks.
    var tags: [String] = []
    var notes = ""
    var avatar: ProfileAvatarStyle?

    var isRunning: Bool { activity == .running }
    var isBusy: Bool { activity == .starting || activity == .sealing }
    /// Grouped under "Running" (also while it starts or seals).
    var isActive: Bool { activity != .stopped }
    var usesProxy: Bool { if case .proxy = exit { return true } else { return false } }
    /// Under the profile's commands in the palette (⌘K): the country it exits in, then its tags.
    var paletteDetail: String {
        var parts: [String] = []
        if case let .proxy(_, code?) = exit { parts.append(CountryNames.name(for: code)) }
        return (parts + tags).joined(separator: " · ")
    }

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

enum ProfileFilter: Hashable {
    case all, running, proxied, ephemeral
    /// The profiles with this tag, whatever its case.
    case tag(String)

    var title: String {
        switch self {
        case .all: return L("profiles.filter.all")
        case .running: return L("profiles.filter.running")
        case .proxied: return L("profiles.filter.proxied")
        case .ephemeral: return L("profiles.filter.ephemeral")
        case .tag(let tag): return tag
        }
    }

    var symbol: String {
        switch self {
        case .all: return "person.2"
        case .running: return "play.circle"
        case .proxied: return "network"
        case .ephemeral: return "hourglass"
        case .tag: return "tag"
        }
    }

    func includes(_ row: ProfileRowItem) -> Bool {
        switch self {
        case .all: return true
        case .running: return row.isActive
        case .proxied: return row.usesProxy
        case .ephemeral: return row.ephemeral
        case .tag(let tag): return ProfileTags.contains(row.tags, tag)
        }
    }

    /// The tags of `rows`, each once whatever its case, in alphabetical order.
    static func tags(of rows: [ProfileRowItem]) -> [String] {
        var seen = Set<String>()
        return rows.flatMap(\.tags)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
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
    var exportCookies: (UUID) -> Void = { _ in }
    var warmUp: (UUID) -> Void = { _ in }
    /// What a page measures in the profile next to Safari (`WhatSitesSeeView`).
    var whatSitesSee: (UUID) -> Void = { _ in }
    var exportProfile: (UUID) -> Void = { _ in }
    var importProfile: () -> Void = {}
    var delete: (UUID) -> Void = { _ in }
    var lock: () -> Void = {}
    var openSync: () -> Void = {}
    /// Nil while no sync target is set.
    var syncNow: (() -> Void)?
    var openTunnel: () -> Void = {}
    /// The local automation API's settings (`AutomationSettingsView`).
    var openAutomation: () -> Void = {}
    var openSettings: () -> Void = {}
    var changePassword: () -> Void = {}
    /// Several profiles warmed up one after the other (`WarmUpQueueView`).
    var warmUpQueue: () -> Void = {}
    /// The proxy list (import, checks, assignment).
    var openProxies: () -> Void = {}
    // Several selected profiles at once (`ProfileBulkBar`), in the order the list shows them.
    var launchSeveral: ([UUID]) -> Void = { _ in }
    var stopSeveral: ([UUID]) -> Void = { _ in }
    /// The hook a warm-up queue takes the selection through.
    var warmUpSeveral: ([UUID]) -> Void = { _ in }
    /// Proxies of the list for these profiles, in turn.
    var assignProxies: ([UUID]) -> Void = { _ in }
    /// Asks once, naming how many, before deleting.
    var deleteSeveral: ([UUID]) -> Void = { _ in }
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
    /// The proxy list as a section of the window (the sidebar's Proxies, `proxies`), and how
    /// many proxies it holds; nil: no such section.
    var section: Binding<ProfilesSection> = .constant(.profiles)
    var proxyCount: Int?
    var proxies: AnyView?
    /// Rows selected with ⌘- and ⇧-click; with two or more, `ProfileBulkBar` acts on them all.
    @State private var selection = ProfileSelection()

    static let sidebarWidth: CGFloat = 208
    /// The table's columns drop "Appears as", then "Last used", below these content widths.
    static let minimumWindowWidth: CGFloat = 920

    var body: some View {
        HStack(spacing: 0) {
            ProfilesSidebar(rows: rows, sync: sync, filter: $filter, section: section, proxyCount: proxyCount, actions: actions)
                .frame(width: Self.sidebarWidth)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            if section.wrappedValue == .proxies, let proxies {
                proxies
            } else {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    if selectedRows.count >= 2 {
                        ProfileBulkBar(rows: selectedRows, visibleCount: displayOrder.count, actions: actions,
                                       selectAll: { selection.select(displayOrder.map(\.id)) },
                                       clear: { selection.clear() })
                            .transition(.opacity)
                    }
                    content
                }
                .background(Theme.surface)
                .animation(Theme.hoverAnimation, value: selectedRows.count >= 2)
            }
        }
        .background(Theme.surface)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: rows.map(\.id)) { _, ids in selection.keep(only: Set(ids)) }
    }

    /// The rows in the order the list shows them: running ones first, then the others.
    private var displayOrder: [ProfileRowItem] {
        visibleRows.filter(\.isActive) + visibleRows.filter { !$0.isActive }
    }

    /// The selected rows the list shows (a row the filter or the search hides is never acted on unseen).
    private var selectedRows: [ProfileRowItem] {
        displayOrder.filter { selection.contains($0.id) }
    }

    private var visibleRows: [ProfileRowItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            filter.includes(row) && (query.isEmpty || Self.matches(row, query))
        }
    }

    /// The search finds a profile by its name, one of its tags or its notes.
    static func matches(_ row: ProfileRowItem, _ query: String) -> Bool {
        row.name.localizedCaseInsensitiveContains(query)
            || row.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            || row.notes.localizedCaseInsensitiveContains(query)
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
            // Only what is done rarely, in groups: the proxies are in the sidebar, Settings is ⌘,
            // in the app's menu, and warming up several profiles is the selection's (and ⌘K's).
            Menu {
                Button(L("profiles.menu.import"), action: actions.importProfile)
                Divider()
                Button(L("profiles.menu.sync"), action: actions.openSync)
                Button(L("profiles.menu.syncNow")) { actions.syncNow?() }
                    .disabled(actions.syncNow == nil)
                Divider()
                Button(L("profiles.menu.tunnel"), action: actions.openTunnel)
                Button(L("profiles.menu.automation"), action: actions.openAutomation)
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
                ProfileRow(row: row, columns: columns, actions: actions, isSelected: selection.contains(row.id),
                           onClick: { click in selection.click(row.id, click, order: displayOrder.map(\.id)) })
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
    @Binding var section: ProfilesSection
    /// Nil: the window has no Proxies section (no list model).
    let proxyCount: Int?
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
            if let proxyCount { proxiesItem(proxyCount) }
            Text(L("profiles.filters"))
                .font(.lumenColumn)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 10)
                .padding(.top, 18)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            item(.proxied)
            item(.ephemeral)
            let tags = ProfileFilter.tags(of: rows)
            if !tags.isEmpty {
                Text(L("profiles.tags"))
                    .font(.lumenColumn)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 10)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tags, id: \.self) { tag in item(.tag(tag)) }
                    }
                }
                .scrollIndicators(.automatic)
                // Eight rows, then the rest scrolls.
                .frame(height: CGFloat(min(tags.count, 8)) * 28)
            }
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
        sidebarButton(symbol: value.symbol, title: value.title, count: rows.filter(value.includes).count,
                      selected: section == .profiles && filter == value) {
            filter = value
            section = .profiles
        }
    }

    /// The proxy list: a section of the window, beside the profiles.
    private func proxiesItem(_ count: Int) -> some View {
        sidebarButton(symbol: "network", title: L("proxies.title"), count: count, selected: section == .proxies) {
            section = .proxies
        }
    }

    private func sidebarButton(symbol: String, title: String, count: Int, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Theme.appearAnimation) { choose() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
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
    var isSelected = false
    /// A click on the row itself (not on its buttons or menu): selects it (`ProfileSelection`).
    var onClick: (ProfileSelection.Click) -> Void = { _ in }

    var body: some View {
        HStack(spacing: ProfileColumns.gap) {
            nameCell.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ExitLabel(exit: row.exit)
                if row.exitUnconfirmed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .help(L("profiles.exit.lookupFailed"))
                        .accessibilityLabel(L("profiles.exit.lookupFailed"))
                }
            }
            .frame(width: ProfileColumns.exit, alignment: .leading)
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
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(isSelected ? Theme.rowSelected : .clear))
        .contentShape(Rectangle())
        // The row's buttons and ⋯ menu take their own clicks; a click anywhere else selects.
        .onTapGesture { onClick(.current) }
        .hoverHighlight(cornerRadius: Theme.controlRadius)
        .opacity(row.activity == .sealing ? 0.6 : 1)
        .contextMenu { ProfileMenuItems(row: row, actions: actions) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(row.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var nameCell: some View {
        HStack(spacing: 0) {
            ZStack {
                if row.isRunning { RunningDot().transition(.opacity) }
            }
            .frame(width: 7)
            .padding(.trailing, 8)
            ProfileAvatar(name: row.name, id: row.id, size: 28, style: row.avatar)
                .padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if !row.notes.isEmpty {
                        Image(systemName: "note.text")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel(L("profiles.row.hasNotes"))
                    }
                    TagChips(tags: row.tags, limit: 3)
                }
                subtitle
            }
        }
        .help(row.notes)
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
            } else if row.warmUpQueued {
                secondaryLine(L("profiles.row.warmUpQueued"))
            } else {
                secondaryLine(L("profiles.row.running"))
            }
        case .stopped:
            if row.warmUpQueued {
                secondaryLine(L("profiles.row.warmUpQueued"))
            } else if row.ephemeral {
                secondaryLine(L("profiles.row.ephemeral"))
            }
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
        Button(L("profiles.row.exportCookies")) { actions.exportCookies(row.id) }
        Button(L("profiles.row.warmUp")) { actions.warmUp(row.id) }
        Button(L("profiles.row.whatSitesSee")) { actions.whatSitesSee(row.id) }
        Divider()
        Button(L("profiles.row.export")) { actions.exportProfile(row.id) }
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
        // As much as the name column has room for, never more: a line wider than the column
        // pushed the row's other columns out of line and its buttons past the window's edge. The
        // bar goes first, then the cookie count.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pages; bar; cookies }
            HStack(spacing: 8) { pages; cookies }
            HStack(spacing: 8) { pages; bar }
            pages
        }
        .help(String(format: L("profiles.row.warmingUp"), status.currentPage, status.total))
    }

    private var pages: some View {
        Text(String(format: L("profiles.row.warmUpShort"), status.currentPage, status.total))
            .font(.lumenSecondary)
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .monospacedDigit()
            .fixedSize()
    }

    private var bar: some View {
        LumenProgressBar(fraction: status.fraction, width: 48)
    }

    @ViewBuilder
    private var cookies: some View {
        if status.cookies > 0 {
            Text(String(format: L("profiles.row.warmUpCookies"), status.cookies))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .monospacedDigit()
                .fixedSize()
        }
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
