import AppKit
import BrowserCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    /// The Profiles window comes in a moment after the vault opens: "Vault open" shows meanwhile,
    /// while the eclipses part (the design's unlock). No click is asked for; any key or click goes
    /// on at once, and under Reduce Motion (or with the animations off) it is not shown at all
    /// (the owner, 1 November: a second twenty times a day is a price too).
    @State private var showsProfiles = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let minimumHeight: CGFloat = 560
    /// How long "Vault open" shows before the profiles.
    static let openPause: UInt64 = 400_000_000

    var body: some View {
        ZStack {
            if model.phase == .unlocked && showsProfiles {
                ProfileListView().transition(.opacity)
            } else {
                // One backdrop for setup, unlock and "open": its eclipses close in while the
                // password is checked and part when the vault opens.
                LockBackdrop(phase: lockPhase) {
                    switch model.phase {
                    case .setup: SetupView().transition(.opacity)
                    case .locked: UnlockView().transition(.opacity)
                    case .unlocked: VaultOpenView().transition(.opacity)
                    }
                }
                .transition(.opacity)
                .overlay {
                    // "Vault open": a key or a click goes on to the profiles at once.
                    if model.phase == .unlocked && !showsProfiles {
                        SkipLayer(skip: { showProfiles() })
                    }
                }
            }
        }
        .animation(Theme.appearAnimation, value: model.phase)
        .animation(.easeOut(duration: 0.25), value: showsProfiles)
        .onAppear { showsProfiles = model.phase == .unlocked }
        .onChange(of: model.phase) { _, phase in
            guard phase == .unlocked else {
                showsProfiles = false
                return
            }
            guard !Motion.isReduced(reduceMotion) else {
                showsProfiles = true
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.openPause)
                if model.phase == .unlocked { showProfiles() }
            }
        }
        .frame(minWidth: ProfilesScreen.minimumWindowWidth, minHeight: Self.minimumHeight)
        .background(Theme.surface)
        // Every sheet of the window takes the size it asks for, but never more than this room.
        .providesSheetRoom()
        .tint(Theme.accentFill)
        .alert(L("common.error"), isPresented: Binding(get: { model.errorMessage != nil },
                                                       set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var lockPhase: EclipseLight.Phase {
        if model.phase == .unlocked { return .open }
        return model.isWorking ? .busy : .idle
    }

    private func showProfiles() {
        if model.phase == .unlocked { showsProfiles = true }
    }
}

/// Over "Vault open": any key or click calls `skip`. It takes the keyboard's focus while it is
/// there, without a focus ring; VoiceOver does not meet it (the moment is short and goes on alone).
private struct SkipLayer: View {
    let skip: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: skip)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { _ in
                skip()
                return .handled
            }
            .onAppear { focused = true }
            .accessibilityHidden(true)
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
    /// A kept deleted profile (R3) the person asked to remove for good: confirmed first.
    @State private var removingDeleted: ProfileRepository.KeptDeletedProfile?
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
    /// The inspector at the window's right, as the person left it.
    @AppStorage("profiles.inspector") private var showsInspector = true
    @ObservedObject private var tunnel = TunnelManager.shared

    var body: some View {
        screen
            .environment(\.tagColors, model.tagColors)
            .sheet(item: $editing) { target in ProfileEditorView(target: target).environment(\.tagColors, model.tagColors) }
            .sheet(item: $passwordsFor) { profile in PasswordListView(profile: profile) }
            .sheet(item: $importingCookiesFor) { profile in CookieImportView(profile: profile) }
            .sheet(item: $warmingUp) { profile in WarmUpView(profile: profile) }
            .sheet(item: $whatSitesSeeFor) { profile in
                WhatSitesSeeView(name: profile.name, snapshot: WhatSitesSee(profileID: profile.id, manager: { model.manager },
                                                                            launch: { await model.launch($0) }),
                                 mobileView: (model.details[profile.id]?.deviceGeneration.platform ?? .macOS) != .macOS)
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
            } message: { profile in
                Text(Self.deletionMessage(L("profiles.delete.message"), unreadable: model.unreadableFiles(for: profile.id)))
            }
            .confirmationDialog(removingDeleted.map(KeptDeletedBox.removeTitle) ?? "",
                                isPresented: Binding(get: { removingDeleted != nil }, set: { if !$0 { removingDeleted = nil } }),
                                presenting: removingDeleted) { profile in
                Button(profile.broughtBack ? L("profiles.kept.removeOld") : L("profiles.kept.removeConfirm"), role: .destructive) {
                    model.removeDeletedProfileForGood(profile.id)
                }
            } message: { profile in
                Text(Self.deletionMessage(profile.broughtBack ? L("profiles.kept.removeMessage.broughtBack") : L("profiles.kept.removeMessage"),
                                          unreadable: model.unreadableFiles(for: profile.id)))
            }
            // A profile whose proxy does not work is said by the banner above the list; its check,
            // step by step, opens from there.
            .sheet(item: $proxySheet) { _ in
                ProxyProblemView { id in showProxies(selecting: [id]) }
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
                Text(Self.bulkDeletionMessage(String(format: L("profiles.bulk.delete.message"), names(ids)),
                                              unreadable: ids.compactMap { id in
                                                  summary(id).map { (name: $0.name, files: model.unreadableFiles(for: id)) }
                                              }))
            }
    }

    /// What the command palette (⌘K) offers: making a profile, each profile's own commands, the
    /// proxies, the warm-up queue, Lock and Sync, each section of Settings, the short report.
    private var paletteCommands: [CommandPaletteView.Command] {
        typealias Command = CommandPaletteView.Command
        let actions = self.actions
        var commands = [Command(id: "new", title: L("palette.newProfile"), symbol: "plus", shortcut: "⌘N", run: actions.newProfile)]
        for row in rows {
            let detail = row.paletteDetail
            switch row.activity {
            case .running:
                commands.append(Command(id: "window-\(row.id)", title: String(format: L("palette.newWindow"), row.name),
                                        detail: detail, symbol: "macwindow.badge.plus", group: .profiles, run: { actions.newWindow(row.id) }))
                commands.append(Command(id: "stop-\(row.id)", title: String(format: L("palette.stop"), row.name),
                                        detail: detail, symbol: "stop.circle", group: .profiles, run: { actions.stop(row.id) }))
            case .stopped:
                commands.append(Command(id: "launch-\(row.id)", title: String(format: L("palette.launch"), row.name),
                                        detail: detail, symbol: "play.circle", group: .profiles, run: { actions.launch(row.id) }))
            case .starting, .sealing:
                break
            }
            commands.append(Command(id: "edit-\(row.id)", title: String(format: L("palette.edit"), row.name),
                                    detail: detail, symbol: "slider.horizontal.3", group: .profiles, run: { actions.edit(row.id) }))
            commands.append(Command(id: "warm-\(row.id)", title: String(format: L("palette.warmUp"), row.name),
                                    detail: detail, symbol: "flame", group: .profiles, run: { actions.warmUp(row.id) }))
            commands.append(Command(id: "see-\(row.id)", title: String(format: L("palette.whatSitesSee"), row.name),
                                    detail: detail, symbol: "eye", group: .profiles, run: { actions.whatSitesSee(row.id) }))
        }
        commands.append(Command(id: "proxies", title: L("palette.proxies"), symbol: "network", run: actions.openProxies))
        commands.append(Command(id: "warmQueue", title: L("profiles.menu.warmUpSeveral"), symbol: "flame", run: actions.warmUpQueue))
        if let syncNow = actions.syncNow {
            commands.append(Command(id: "sync", title: L("palette.syncNow"), symbol: "arrow.triangle.2.circlepath", run: syncNow))
        }
        commands.append(Command(id: "lock", title: L("profiles.action.lock"), symbol: "lock", run: actions.lock))
        for section in SettingsSection.allCases {
            commands.append(Command(id: "settings-\(section.rawValue)", title: String(format: L("palette.settings"), L(section.titleKey)),
                                    symbol: section.symbol, group: .settings, run: {
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

    /// The screen, with the sidebar's count of proxies kept current as the list changes.
    @ViewBuilder
    private var screen: some View {
        if let proxyList = model.proxyList {
            ObservingProxyList(proxies: proxyList) { list in
                profilesScreen(proxyCount: list.entries.count,
                               proxyAlerts: list.entries.filter { $0.lastCheck?.failure != nil }.count,
                               proxyEntries: list.entries)
            }
        } else {
            profilesScreen(proxyCount: nil)
        }
    }

    private func profilesScreen(proxyCount: Int?, proxyAlerts: Int = 0, proxyEntries: [ProxyListEntry] = []) -> ProfilesScreen {
        ProfilesScreen(rows: rows(with: proxyEntries), isWorking: model.isWorking, sync: syncLine,
                       filter: $filter, search: $search, actions: actions,
                       section: $section, proxyCount: proxyCount,
                       proxies: AnyView(ProxyListView(selection: $proxySelection)),
                       indexNotice: model.indexNotice, revealVault: { model.revealVaultFolder() },
                       keptDeleted: model.keptDeletedProfiles,
                       bringBack: { id in Task { await model.bringBackDeletedProfile(id) } },
                       removeForGood: { removingDeleted = $0 },
                       revealKeptDeleted: { model.revealProfileFolder($0) },
                       proxyAlerts: proxyAlerts,
                       showsInspector: $showsInspector,
                       inspectorInfo: { id in
                           let details = model.details[id]
                           // The proxy list's last check of the profile's proxy: its city and latency.
                           let check = details?.proxyIdentity.flatMap { identity in
                               proxyEntries.first { ProxyList.identity(of: $0.proxy) == identity }?.lastCheck
                           }
                           return InspectorInfo(details: details, counts: model.inspectorCounts[id], proxyCheck: check)
                       },
                       onInspect: { model.loadInspectorCounts(for: $0) },
                       tunnelCarriesWebRTC: tunnel.canCarryWebRTC,
                       proxyProblem: model.proxyProblems.first.map { problem in
                           ProxyProblemBanner.Item(
                               title: String(format: problem.notStarted ? L("proxyProblem.title.notStarted") : L("proxyProblem.title"),
                                             problem.profileName),
                               text: String(format: problem.notStarted ? L("proxyProblem.subtitle.notStarted") : L("proxyProblem.subtitle"),
                                            problem.proxy.displayAddress),
                               notStarted: problem.notStarted, more: model.proxyProblems.count - 1)
                       },
                       openProxyProblem: { proxySheet = .problems },
                       retryProxyProblem: {
                           guard let problem = model.proxyProblems.first else { return }
                           model.dismissProxyProblem(problem)
                           Task { await model.launch(problem.profileID) }
                       },
                       dismissProxyProblem: {
                           if let problem = model.proxyProblems.first { model.dismissProxyProblem(problem) }
                       })
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
        Self.listed(ids.compactMap { summary($0)?.name })
    }

    /// At most five, then "and N more".
    static func listed(_ items: [String]) -> String {
        guard items.count > 5 else { return items.joined(separator: ", ") }
        return String(format: L("profiles.bulk.namesAndMore"), items.prefix(5).joined(separator: ", "), items.count - 5)
    }

    /// A deletion's confirmation; when the folder it deletes holds files set aside as unreadable
    /// (`ProfileRepository.unreadableFiles`), it says that they go too, by name. The person decides,
    /// knowing (the owner, 1 November): the rule that nothing unreadable is deleted is against
    /// silent loss, not against the person's own decision.
    static func deletionMessage(_ message: String, unreadable: [String]) -> String {
        guard !unreadable.isEmpty else { return message }
        return message + "\n\n" + String(format: L("profiles.delete.unreadable"), unreadable.count, listed(unreadable))
    }

    /// The same for several profiles: which of them hold such files, and how many in all.
    static func bulkDeletionMessage(_ message: String, unreadable: [(name: String, files: [String])]) -> String {
        let holding = unreadable.filter { !$0.files.isEmpty }
        guard !holding.isEmpty else { return message }
        return message + "\n\n" + String(format: L("profiles.bulk.delete.unreadable"), listed(holding.map(\.name)),
                                          holding.reduce(0) { $0 + $1.files.count })
    }

    private var rows: [ProfileRowItem] { rows(with: model.proxyList?.entries ?? []) }

    /// The rows, with where each profile exits by one rule (the owner, 1 November): the country,
    /// with its flag, when it is known — from the profile's last launch through its proxy, else from
    /// the proxy list's last check of that proxy; otherwise the proxy's address, with why its country
    /// is not known; without a proxy, "Direct".
    private func rows(with proxyEntries: [ProxyListEntry]) -> [ProfileRowItem] {
        model.profiles.map { profile in
            let running = model.isRunning(profile.id)
            let busy = model.isBusy(profile.id)
            let details = model.details[profile.id]
            let activity: ProfileRowItem.Activity = busy ? (running ? .starting : .sealing) : (running ? .running : .stopped)
            let warmUp = model.manager?.warmUpStatus(of: profile.id)
            let problem = model.proxyProblems.first { $0.profileID == profile.id }
            // No details: its settings could not be read (`AppModel.refresh`) — not "Direct" (R1).
            var exit = ProfileExit.unreadable
            var exitNote: String?
            let lookupFailed = model.manager?.proxyLocationUnknown.contains(profile.id) ?? false
            if let details {
                if let endpoint = details.proxyEndpoint {
                    let check = details.proxyIdentity.flatMap { identity in
                        proxyEntries.first { ProxyList.identity(of: $0.proxy) == identity }?.lastCheck
                    }
                    let country = details.exitCountryCode ?? (check?.isAlive == true ? check?.countryCode : nil)
                    exit = .proxy(endpoint: endpoint, countryCode: country)
                    if country == nil { exitNote = ProfileRowItem.unknownCountryNote(check: check, lookupFailed: lookupFailed) }
                } else {
                    exit = .direct
                }
            }
            return ProfileRowItem(
                id: profile.id, name: profile.name, activity: activity,
                exit: exit,
                ephemeral: details?.ephemeral ?? false,
                // Settings that could not be read say nothing of how it appears: no default shown for them.
                appearsAs: details.map {
                    ProfileRowItem.appearsAs($0.deviceGeneration, safariVersion: $0.safariVersion, hostSafariVersion: HostSafari.version)
                } ?? "—",
                lastUsed: profile.lastLaunchedAt,
                warmUp: warmUp.flatMap { $0.isRunning ? $0 : nil },
                warmUpQueued: model.warmUps?.isWaiting(profile.id) ?? false,
                exitUnconfirmed: lookupFailed,
                exitNote: exitNote,
                tags: details?.tags ?? [], notes: details?.notes ?? "", avatar: details?.avatar,
                problem: problem.map {
                    String(format: $0.notStarted ? L("proxyProblem.subtitle.notStarted") : L("proxyProblem.subtitle"),
                           $0.proxy.displayAddress)
                },
                deviceSymbol: details.flatMap { ProfileRowItem.deviceSymbol($0.deviceGeneration) })
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
                guard let profile = summary(id) else { return }
                // Settings that cannot be read are not edited: the form would open on defaults —
                // no proxy — and Save would put them in place of the profile's own (R1). The alert
                // says how to get them back.
                do { _ = try model.configuration(for: id) } catch {
                    model.showError(errorText(error))
                    return
                }
                editing = .existing(profile)
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
            showProxy: { id in
                // Looked up, never added: the list is only read here.
                let identity = model.details[id]?.proxyIdentity
                let entry = identity.flatMap { identity in
                    model.proxyList?.entries.first { ProxyList.identity(of: $0.proxy) == identity }
                }
                showProxies(selecting: entry.map { [$0.id] } ?? [])
            },
            launchSeveral: { ids in Task { await model.launchProfiles(ids) } },
            stopSeveral: { ids in Task { await model.stopProfiles(ids) } },
            warmUpSeveral: { ids in warmUpSeveral(ids) },
            assignProxies: { ids in assigningProxies = ProxyAssignView.Request(profileIDs: Set(ids), proxyIDs: []) },
            deleteSeveral: { ids in pendingBulkDelete = ids },
            setTagColor: { tag, color in model.setTagColor(color, for: tag) })
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
    /// Why its proxy's country is not known, when it is not (the row then shows the proxy's address).
    var exitNote: String?
    /// The person's own tags and notes for the profile, and how its glyph looks.
    var tags: [String] = []
    var notes = ""
    var avatar: ProfileAvatarStyle?
    /// Why it did not start, when its last launch failed (a proxy that did not answer): the row is
    /// among "Need attention" and says so.
    var problem: String?
    /// The device it presents as, by its symbol, when not a Mac ("iphone", "ipad").
    var deviceSymbol: String?

    var isRunning: Bool { activity == .running }
    /// Grouped under "Need attention": its last launch failed, or its settings cannot be read (R1).
    var needsAttention: Bool { problem != nil || exit == .unreadable }
    var isBusy: Bool { activity == .starting || activity == .sealing }
    /// Grouped under "Running" (also while it starts or seals).
    var isActive: Bool { activity != .stopped }
    var usesProxy: Bool { if case .proxy = exit { return true } else { return false } }
    var connectsDirectly: Bool { exit == .direct }
    /// Under the profile's commands in the palette (⌘K): the country it exits in, then its tags.
    var paletteDetail: String {
        var parts: [String] = []
        if case let .proxy(_, code?) = exit { parts.append(CountryNames.name(for: code)) }
        return (parts + tags).joined(separator: " · ")
    }

    /// The symbol of the device the profile presents as, when not a Mac.
    static func deviceSymbol(_ generation: DeviceGeneration) -> String? {
        switch generation.platform {
        case .macOS: return nil
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        }
    }

    /// "Mac · Safari 26", "iPhone · Safari 26": the device the profile presents as.
    /// Why a proxy's country is not known: the lookup at its last launch got no answer, the proxy
    /// was never checked (and no launch looked it up), its last check failed, or the check that
    /// passed got no country for its address.
    static func unknownCountryNote(check: ProxyCheckResult?, lookupFailed: Bool) -> String {
        if lookupFailed { return L("profiles.exit.lookupFailed") }
        guard let check else { return L("profiles.exit.unknown.notChecked") }
        return check.isAlive ? L("profiles.exit.unknown.noCountry") : L("profiles.exit.unknown.checkFailed")
    }

    /// How it presents: the device, and the Safari it says it is. On a Mac that is the version its
    /// settings pin, else this Mac's own Safari — what its User-Agent declares
    /// (`DeviceGeneration.userAgent(hostSafariVersion:)`); the catalog's "26" went stale on a Mac
    /// whose Safari is 27 (the owner, 1 November: "Mac · Safari 26" beside a page measuring 27.0.1).
    /// Mobile views declare a fixed Safari, their catalog's.
    static func appearsAs(_ generation: DeviceGeneration, safariVersion: String? = nil, hostSafariVersion: String) -> String {
        let device: String
        switch generation.platform {
        case .macOS: device = L("profiles.device.mac")
        case .iOS: device = L("profiles.device.iphone")
        case .iPadOS: device = L("profiles.device.ipad")
        }
        var version = generation.osVersionLabel
        if generation.matchesEngine {
            let declared = safariVersion.flatMap { DeviceGeneration.isSafariVersion($0) ? $0 : nil } ?? hostSafariVersion
            if DeviceGeneration.isSafariVersion(declared), let major = declared.split(separator: ".").first {
                version = String(major)
            }
        }
        return String(format: L("profiles.appearsAs"), device, version)
    }
}

/// Where a profile's traffic leaves for the web.
enum ProfileExit: Equatable {
    case direct
    /// Through a proxy; its exit country once a lookup through it found one.
    case proxy(endpoint: String, countryCode: String?)
    /// Its settings could not be read: where it would exit is not known, and it does not start
    /// until they are back (R1). Never shown as "Direct".
    case unreadable
}

enum ProfileFilter: Hashable {
    case all, running, proxied, direct, ephemeral
    /// The profiles with this tag, whatever its case.
    case tag(String)

    var title: String {
        switch self {
        case .all: return L("profiles.filter.all")
        case .running: return L("profiles.filter.running")
        case .proxied: return L("profiles.filter.proxied")
        case .direct: return L("profiles.filter.direct")
        case .ephemeral: return L("profiles.filter.ephemeral")
        case .tag(let tag): return tag
        }
    }

    var symbol: String {
        switch self {
        case .all: return "person.2"
        case .running: return "play.circle"
        case .proxied: return "globe"
        case .direct: return "arrow.right"
        case .ephemeral: return "hourglass"
        case .tag: return "number"
        }
    }

    func includes(_ row: ProfileRowItem) -> Bool {
        switch self {
        case .all: return true
        case .running: return row.isActive
        case .proxied: return row.usesProxy
        case .direct: return row.connectsDirectly
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
    /// The proxy list with this profile's proxy selected (its check, step by step).
    var showProxy: (UUID) -> Void = { _ in }
    // Several selected profiles at once (`ProfileBulkBar`), in the order the list shows them.
    var launchSeveral: ([UUID]) -> Void = { _ in }
    var stopSeveral: ([UUID]) -> Void = { _ in }
    /// The hook a warm-up queue takes the selection through.
    var warmUpSeveral: ([UUID]) -> Void = { _ in }
    /// Proxies of the list for these profiles, in turn.
    var assignProxies: ([UUID]) -> Void = { _ in }
    /// Asks once, naming how many, before deleting.
    var deleteSeveral: ([UUID]) -> Void = { _ in }
    /// A tag's colour for the whole vault (`TagColors`); nil takes it away.
    var setTagColor: (String, Int?) -> Void = { _, _ in }
}

// MARK: - The screen

/// The Profiles window (the design's main screen): over the window's black and its two dimmed
/// eclipses, a sidebar (lockup, Profiles and Proxies, the collections, the tags, sync, Lock and
/// Settings), and the profiles in three groups — those that need attention, the running ones,
/// the ones ready to launch. Pure presentation: everything it shows comes in `rows`, everything
/// it does goes out through `actions`.
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
    /// The vault's profile index missing or unreadable, or profile folders it does not list
    /// (AppModel.indexNotice): said above the list, with the vault's folder in the Finder.
    var indexNotice: AppModel.IndexNotice?
    var revealVault: () -> Void = {}
    /// Deleted profiles whose folders are kept (R3), each with what can be done with it.
    var keptDeleted: [ProfileRepository.KeptDeletedProfile] = []
    var bringBack: (UUID) -> Void = { _ in }
    var removeForGood: (ProfileRepository.KeptDeletedProfile) -> Void = { _ in }
    var revealKeptDeleted: (UUID) -> Void = { _ in }
    /// Proxies whose last check failed: said in red beside Proxies.
    var proxyAlerts = 0
    /// The inspector at the right (`ProfileInspectorView`), shown while this is on — the header's
    /// button: beside the list when the window has room for both, over the list's right side when
    /// it has not (the rows keep their columns).
    var showsInspector: Binding<Bool> = .constant(false)
    /// What the inspector shows of a profile beyond its row.
    var inspectorInfo: (UUID) -> InspectorInfo = { _ in InspectorInfo() }
    /// A profile is inspected: what it keeps is counted (`AppModel.loadInspectorCounts`).
    var onInspect: (UUID) -> Void = { _ in }
    var tunnelCarriesWebRTC = false
    /// The profiles selected as the window opens (the snapshots).
    var initialSelection: [UUID] = []
    /// The banners open behind "N more" as the window opens (the snapshots).
    var initialBannersExpanded = false
    /// A profile whose proxy does not work, said above the list (`ProxyProblemBanner`).
    var proxyProblem: ProxyProblemBanner.Item?
    var openProxyProblem: () -> Void = {}
    var retryProxyProblem: () -> Void = {}
    var dismissProxyProblem: () -> Void = {}
    /// Rows selected with a click, ⌘- and ⇧-click or their checkboxes; one is what the inspector
    /// shows, with two or more `ProfileBulkBar` acts on them all.
    @State private var selection = ProfileSelection()
    @State private var appeared = false
    /// The banners behind "N more" are open.
    @State private var bannersExpanded = false
    @ObservedObject private var appearance = AppearancePreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenStillFrame) private var stillFrame
    @Environment(\.lazyProfileListControl) private var lazyListControl

    static let sidebarWidth: CGFloat = 232
    static let inspectorWidth: CGFloat = 320
    /// Where an inspector's content starts: under the title bar's band, as the sidebar's does. Its
    /// panel still runs to the window's top. A scroll view that reaches under the title bar gets
    /// macOS 26's edge effect there, which a window's picture (`cacheDisplay`, the self-test's
    /// snapshots) does not draw: the whole panel came out empty (CI run 555).
    static let inspectorTop: CGFloat = 44
    /// The table drops "Appears as" below these content widths.
    static let minimumWindowWidth: CGFloat = 920
    /// The header: below the title bar's band, its height, its right margin (the self-test clicks
    /// New profile by them).
    static let headerTop: CGFloat = 36
    static let headerHeight: CGFloat = 56
    static let headerTrailing: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            // Beside the list only when the rows keep their columns.
            let inspectorFits = geometry.size.width - Self.sidebarWidth - Self.inspectorWidth >= ProfileColumns.minimumContentWidth
            HStack(spacing: 0) {
                ProfilesSidebar(rows: rows, sync: sync, filter: $filter, section: section, proxyCount: proxyCount,
                                proxyAlerts: proxyAlerts, actions: actions)
                    .frame(width: Self.sidebarWidth)
                    .lumenFrost()
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
                    .opacity(appeared ? 1 : 0)
                main(inspectorOver: inspectorShown && !inspectorFits)
                if inspectorShown && inspectorFits {
                    inspector(top: Self.inspectorTop)
                        .opacity(appeared ? 1 : 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.isReduced(reduceMotion) ? nil : Theme.appearAnimation, value: inspectorShown)
        }
        .background {
            ZStack {
                Theme.backdrop
                if appearance.entryLight {
                    EclipseLight(place: .profiles, brightness: 0.55)
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: rows.map(\.id)) { _, ids in selection.keep(only: Set(ids)) }
        .onChange(of: inspectedID) { _, _ in inspect() }
        .onChange(of: inspectedActivity) { _, _ in inspect() }
        .onChange(of: inspectorShown) { _, _ in inspect() }
        .onAppear {
            if selection.isEmpty, !initialSelection.isEmpty { selection.select(initialSelection) }
            if initialBannersExpanded { bannersExpanded = true }
            enter()
            inspect()
        }
    }

    /// The list (or the proxies), under the header. `inspectorOver`: the window has no room for the
    /// inspector beside the list, so it lies over the list's right side — the list's only: the
    /// header and the banners above it, with their buttons, stay within reach.
    private func main(inspectorOver: Bool) -> some View {
        Group {
            if section.wrappedValue == .proxies, let proxies {
                proxies
            } else {
                VStack(spacing: 0) {
                    header
                    bannerStack
                    content
                        .overlay(alignment: .trailing) {
                            if inspectorOver {
                                inspector(top: 8)
                                    .shadow(color: .black.opacity(0.55), radius: 30, x: -6)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .overlay(alignment: .bottom) {
                            // Floating over the list's foot, while several are selected.
                            if selectedRows.count >= 2 {
                                ProfileBulkBar(rows: selectedRows, visibleCount: displayOrder.count, actions: actions,
                                               selectAll: { selection.select(displayOrder.map(\.id)) },
                                               clear: { selection.clear() })
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 18)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                }
                .animation(Motion.isReduced(reduceMotion) ? nil : Theme.appearAnimation, value: selectedRows.count >= 2)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || Motion.isReduced(reduceMotion) ? 0 : 10)
    }

    // MARK: The banners

    /// What is said above the list, most important first: one banner shows, the others behind
    /// "N more", which opens them in the same order ("collapse" puts them away) — so that solving
    /// one, the person learns of the next (the owner and the designer, 1 November; CONTRACT §8.5
    /// orders the licence's banners the same way, when they come). The vault's index (what the
    /// list shows may be incomplete), then a profile whose proxy does not work (it was just
    /// launched), then deleted profiles whose folders are kept (R3: a decision that can wait).
    private enum ProfilesBanner: Identifiable {
        case index(AppModel.IndexNotice)
        case proxyProblem(ProxyProblemBanner.Item)
        case keptDeleted

        var id: String {
            switch self {
            case .index: return "index"
            case .proxyProblem: return "proxy"
            case .keptDeleted: return "kept"
            }
        }
    }

    private var banners: [ProfilesBanner] {
        var banners: [ProfilesBanner] = []
        if let indexNotice { banners.append(.index(indexNotice)) }
        if let proxyProblem { banners.append(.proxyProblem(proxyProblem)) }
        if !keptDeleted.isEmpty { banners.append(.keptDeleted) }
        return banners
    }

    @ViewBuilder
    private var bannerStack: some View {
        let banners = self.banners
        let shown = bannersExpanded ? banners : Array(banners.prefix(1))
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, banner in
                bannerView(banner)
                    .environment(\.bannerMore, index == 0 && banners.count > 1
                        ? BannerMore(count: banners.count - 1, expanded: bannersExpanded) {
                            withAnimation(Motion.isReduced(reduceMotion) ? nil : Theme.appearAnimation) { bannersExpanded.toggle() }
                        }
                        : nil)
                    .transition(.opacity)
            }
        }
        // Down to one: the next that comes starts behind "1 more" again.
        .onChange(of: banners.count) { _, count in
            if count < 2 { bannersExpanded = false }
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: ProfilesBanner) -> some View {
        switch banner {
        case let .index(notice):
            IndexNoticeBox(notice: notice, reveal: revealVault)
        case let .proxyProblem(item):
            ProxyProblemBanner(item: item, open: openProxyProblem, retry: retryProxyProblem, dismiss: dismissProxyProblem)
        case .keptDeleted:
            KeptDeletedBox(profiles: keptDeleted, isWorking: isWorking, bringBack: bringBack,
                           removeForGood: removeForGood, reveal: revealKeptDeleted)
        }
    }

    // MARK: The inspector

    /// Shown: turned on, over the profiles (not the proxies), and there are profiles.
    private var inspectorShown: Bool {
        showsInspector.wrappedValue && section.wrappedValue == .profiles && !rows.isEmpty
    }

    /// The one profile selected, which the inspector shows.
    private var inspectedID: UUID? {
        guard inspectorShown, selectedRows.count == 1 else { return nil }
        return selectedRows.first?.id
    }

    /// It stopped or started: what it keeps may have changed.
    private var inspectedActivity: ProfileRowItem.Activity? {
        inspectedID.flatMap { id in rows.first { $0.id == id }?.activity }
    }

    private func inspect() {
        if let inspectedID { onInspect(inspectedID) }
    }

    /// `top`: where its content starts — under the title bar's band beside the list
    /// (`inspectorTop`), just under the header over it.
    private func inspector(top: CGFloat) -> some View {
        Group {
            if selectedRows.count == 1, let row = selectedRows.first {
                ProfileInspectorView(row: row, info: inspectorInfo(row.id), actions: actions,
                                     tunnelCarriesWebRTC: tunnelCarriesWebRTC)
                    .id(row.id)
            } else if selectedRows.count > 1 {
                SelectionInspectorView(rows: selectedRows, actions: actions)
            } else {
                EmptyInspectorView()
            }
        }
        .frame(width: Self.inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, top)
        .background(Theme.sidebar.opacity(0.8))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("inspector.title"))
    }

    /// The window comes in: the sidebar fades in, the list rises 10 pt (the design's 0.9 s); under
    /// Reduce Motion only the fade.
    private func enter() {
        guard !appeared else { return }
        if stillFrame {
            appeared = true
            return
        }
        withAnimation(Motion.isReduced(reduceMotion) ? .easeOut(duration: 0.3) : Motion.entry(duration: 0.9).delay(0.2)) {
            appeared = true
        }
    }

    /// The rows in the order the list shows them: those needing attention, the running ones, the others.
    private var displayOrder: [ProfileRowItem] {
        groups.flatMap(\.rows)
    }

    private enum GroupKind: Hashable { case attention, running, ready }

    private struct RowGroup: Identifiable {
        let kind: GroupKind
        let rows: [ProfileRowItem]
        var id: GroupKind { kind }
    }

    private var groups: [RowGroup] {
        [RowGroup(kind: .attention, rows: visibleRows.filter(\.needsAttention)),
         RowGroup(kind: .running, rows: visibleRows.filter { !$0.needsAttention && $0.isActive }),
         RowGroup(kind: .ready, rows: visibleRows.filter { !$0.needsAttention && !$0.isActive })]
            .filter { !$0.rows.isEmpty }
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("profiles.title"))
                    .lumenPageTitle()
                    .foregroundStyle(Theme.textPrimary)
                Text(countLine)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 12)
            if isWorking {
                ProgressView().controlSize(.small).transition(.opacity)
            }
            LumenSearchField(text: $search, prompt: L("profiles.search"), shortcut: "⌘K")
                .frame(maxWidth: 280)
            Button {
                showsInspector.wrappedValue.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(LumenIconButtonStyle(size: 32, isOn: showsInspector.wrappedValue))
            .help(showsInspector.wrappedValue ? L("inspector.hide") : L("inspector.show"))
            .accessibilityLabel(showsInspector.wrappedValue ? L("inspector.hide") : L("inspector.show"))
            // Only what is done rarely, in groups: import, sync, the tunnel, automation and the
            // master password (they are in Settings and ⌘K too).
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
            .frame(width: 30, height: 30)
            .hoverHighlight(cornerRadius: Theme.controlRadius)
            .help(L("profiles.menu.more"))
            .accessibilityLabel(L("profiles.menu.more"))
            Button(action: actions.newProfile) {
                Label(L("profiles.action.new"), systemImage: "plus")
            }
            .buttonStyle(.lumenPrimary)
            .keyboardShortcut("n")
        }
        .frame(height: Self.headerHeight)
        .padding(.leading, 28)
        .padding(.trailing, Self.headerTrailing)
        .padding(.top, Self.headerTop)
        .padding(.bottom, 16)
        .animation(Theme.hoverAnimation, value: isWorking)
    }

    private var countLine: String {
        let running = rows.filter(\.isActive).count
        return running > 0
            ? String(format: L("profiles.countRunning"), rows.count, running)
            : String(format: L("profiles.count"), rows.count)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty, let indexNotice, indexNotice.kind != .unlisted {
            // Not "no profiles yet": the index that lists them is missing or unreadable (the notice
            // above says so), and their folders are kept.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            EmptyProfilesView(onNew: actions.newProfile)
        } else if visibleRows.isEmpty {
            NoMatchesView(query: search.trimmingCharacters(in: .whitespacesAndNewlines)) {
                withAnimation(Theme.appearAnimation) {
                    filter = .all
                    search = ""
                }
            }
        } else {
            GeometryReader { geometry in
                let columns = ProfileColumns(contentWidth: geometry.size.width)
                ScrollView {
                    listStack(columns)
                        .padding(.horizontal, 20)
                        // The last row stays above the floating bar.
                        .padding(.bottom, selectedRows.count >= 2 ? 88 : 24)
                }
                .scrollIndicators(.automatic)
                .animation(Motion.isReduced(reduceMotion) ? nil : Motion.reflow, value: displayOrder.map(\.id))
            }
            .transition(.opacity)
        }
    }

    /// The column header, the groups and the footnote in a plain stack, every row laid out. Not a
    /// lazy one: its items were the whole groups, so it spared nothing (a group's rows were all made
    /// as soon as any of it showed), and it is what the list was when the owner came back from a
    /// profile's window to "Profiles: 29" over a blank list, its rows there only once scrolled up
    /// (1 November) — a profile's row goes up to Running and back while the list is scrolled down.
    /// A plain stack keeps no range of made items for that to leave behind.
    /// `UISnapshots.listAfterReturn` takes those steps in both, `lazyListControl` being the former
    /// shape, for that check's control only.
    @ViewBuilder
    private func listStack(_ columns: ProfileColumns) -> some View {
        if lazyListControl {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) { listItems(columns) }
        } else {
            VStack(alignment: .leading, spacing: 0) { listItems(columns) }
        }
    }

    @ViewBuilder
    private func listItems(_ columns: ProfileColumns) -> some View {
        columnHeader(columns)
        ForEach(groups) { group in
            groupView(group.kind, group.rows, columns)
        }
        footnote
    }

    private func columnHeader(_ columns: ProfileColumns) -> some View {
        HStack(spacing: ProfileColumns.gap) {
            Text(L("profiles.column.name")).lumenCaps().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ProfileColumns.nameInset)
            Text(L("profiles.column.exit")).lumenCaps().frame(width: ProfileColumns.exit, alignment: .leading)
            if columns.showsAppearsAs {
                Text(L("profiles.column.appearsAs")).lumenCaps().frame(width: ProfileColumns.appearsAs, alignment: .leading)
            }
            Text(L("profiles.column.state")).lumenCaps().frame(width: columns.state, alignment: .leading)
            Color.clear.frame(width: ProfileColumns.actions, height: 1)
        }
        .lineLimit(1)
        .padding(.horizontal, ProfileColumns.rowPadding)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func groupView(_ kind: GroupKind, _ rows: [ProfileRowItem], _ columns: ProfileColumns) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(groupTitle(kind)).lumenCaps(kind == .attention ? Theme.danger : Theme.textTertiary)
                Text(verbatim: "\(rows.count)").lumenCaps(kind == .attention ? Theme.danger : Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.leading, ProfileColumns.rowPadding + ProfileColumns.nameInset)
            .frame(height: 42, alignment: .bottomLeading)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                ProfileRow(row: row, columns: columns, actions: actions, isSelected: selection.contains(row.id),
                           showsCheckbox: selectedRows.count >= 2, height: appearance.density.rowHeight,
                           onClick: { click in selection.click(row.id, click, order: displayOrder.map(\.id)) })
            }
        }
    }

    private func groupTitle(_ kind: GroupKind) -> String {
        switch kind {
        case .attention: return L("profiles.group.attention")
        case .running: return L("profiles.group.running")
        case .ready: return L("profiles.group.ready")
        }
    }

    private var footnote: some View {
        Label(L("profiles.footnote.sealed"), systemImage: "lock")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, ProfileColumns.rowPadding + ProfileColumns.nameInset)
            .padding(.top, 18)
    }
}

/// Column widths, and whether "Appears as" fits (the name column takes what is left).
struct ProfileColumns {
    static let gap: CGFloat = 12
    static let rowPadding: CGFloat = 8
    /// The checkbox's slot plus the letters' circle: where names start.
    static let nameInset: CGFloat = 20 + 12 + 30 + 12
    /// Wide enough for "Settings cannot be read" with its sign, whole (R1).
    static let exit: CGFloat = 192
    static let appearsAs: CGFloat = 150
    /// The state column's width while the name keeps its own.
    static let fullState: CGFloat = 196
    /// The narrowest it gets.
    static let minimumState: CGFloat = 132
    static let actions: CGFloat = 68
    /// The name's slot (its letters' circle included).
    static let minimumName: CGFloat = 200

    let showsAppearsAs: Bool
    /// The state column: full, or narrower in a narrow window rather than leaving the name a few
    /// letters ("Mar…", "N…" at the narrowest window: CI run 555's profiles-narrow).
    let state: CGFloat

    /// The narrowest list whose rows keep every column but "Appears as" at their full widths: 20 pt
    /// page margins and the rows' own padding on both sides, the columns, the narrowest name.
    static let minimumContentWidth: CGFloat = 2 * 20 + 2 * Self.rowPadding + Self.exit + Self.fullState + Self.actions + 3 * Self.gap + Self.minimumName

    init(contentWidth: CGFloat) {
        showsAppearsAs = contentWidth >= Self.minimumContentWidth + Self.appearsAs + Self.gap
        let short = max(0, Self.minimumContentWidth - contentWidth)
        state = max(Self.minimumState, Self.fullState - short)
    }
}

// MARK: - Sidebar

private struct ProfilesSidebar: View {
    @Environment(\.tagColors) private var tagColors
    let rows: [ProfileRowItem]
    let sync: SyncLine
    @Binding var filter: ProfileFilter
    @Binding var section: ProfilesSection
    /// Nil: the window has no Proxies section (no list model).
    let proxyCount: Int?
    var proxyAlerts = 0
    let actions: ProfileActions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The window's traffic lights sit in this band.
            Color.clear.frame(height: 44)
            LumenLockup.sidebar
                .padding(.leading, 8)
                .padding(.bottom, 20)
            item(.all, title: L("profiles.title"))
            if let proxyCount { proxiesItem(proxyCount) }
            caption(L("profiles.filters"))
            item(.running)
            item(.proxied)
            item(.direct)
            item(.ephemeral)
            let tags = ProfileFilter.tags(of: rows)
            if !tags.isEmpty {
                caption(L("profiles.tags"))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(tags, id: \.self) { tag in tagItem(tag) }
                    }
                }
                .scrollIndicators(.automatic)
                // Up to eight rows, then the rest scrolls; fewer in a short window, never fewer
                // than two — a fixed eight pushed Lock and Settings out at the window's foot (CI
                // run 557, a 1024 × 768 screen; the window may be 560 pt tall).
                .frame(minHeight: CGFloat(min(tags.count, 2)) * 32, maxHeight: CGFloat(min(tags.count, 8)) * 32)
            }
            Spacer(minLength: 16)
            SyncStatusButton(sync: sync, action: actions.openSync)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                Button(action: actions.lock) {
                    Label(L("profiles.action.lock"), systemImage: "lock")
                }
                .buttonStyle(LumenButtonStyle(kind: .secondary, fullWidth: true))
                .help(L("profiles.action.lock.help"))
                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(LumenIconButtonStyle(size: 30))
                .help(L("profiles.menu.settings"))
                .accessibilityLabel(L("profiles.menu.settings"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .lumenCaps()
            .padding(.leading, 10)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func item(_ value: ProfileFilter, title: String? = nil) -> some View {
        sidebarButton(symbol: value.symbol, title: title ?? value.title, count: rows.filter(value.includes).count,
                      selected: section == .profiles && filter == value) {
            filter = value
            section = .profiles
        }
    }

    /// A tag: its colour's dot in place of "#", and its menu, where the colour is chosen for every
    /// profile with the tag.
    private func tagItem(_ tag: String) -> some View {
        let value = ProfileFilter.tag(tag)
        let color = tagColors.color(of: tag)
        return SidebarItem(symbol: value.symbol, dot: color, title: tag, count: rows.filter(value.includes).count,
                           selected: section == .profiles && filter == value) {
            withAnimation(Theme.appearAnimation) {
                filter = value
                section = .profiles
            }
        }
        .help(L("tags.color.hint"))
        .contextMenu {
            Menu(L("tags.color.menu")) {
                ForEach(0..<ProfileAvatarStyle.colorCount, id: \.self) { index in
                    Toggle(isOn: Binding(get: { color == index }, set: { _ in actions.setTagColor(tag, index) })) {
                        Label { Text(TagDot.name(index)) } icon: { Image(nsImage: Self.dotImage(index)) }
                    }
                }
                Divider()
                Button(L("tags.color.none")) { actions.setTagColor(tag, nil) }
                    .disabled(color == nil)
            }
        }
    }

    /// A colour's dot for a menu item: drawn in its colour, not as a template the menu would tint.
    private static func dotImage(_ color: Int) -> NSImage {
        let tone = NSColor(hex: ProfileAvatar.palette[color % ProfileAvatar.palette.count].text)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            tone.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The proxy list: a section of the window, beside the profiles. Proxies whose last check
    /// failed are counted in red.
    private func proxiesItem(_ count: Int) -> some View {
        sidebarButton(symbol: "globe", title: L("proxies.title"), count: proxyAlerts > 0 ? proxyAlerts : count,
                      alert: proxyAlerts > 0, selected: section == .proxies) {
            section = .proxies
        }
    }

    private func sidebarButton(symbol: String, title: String, count: Int, alert: Bool = false, selected: Bool,
                               choose: @escaping () -> Void) -> some View {
        SidebarItem(symbol: symbol, title: title, count: count, alert: alert, selected: selected) {
            withAnimation(Theme.appearAnimation) { choose() }
        }
    }
}

/// One of the sidebar's items (the design's `nav`): `t2`, white under the pointer and when chosen
/// (on 6.5 % white); its count at the end, in red with a dot when it is an alert.
private struct SidebarItem: View {
    let symbol: String
    /// A tag's colour: its dot in place of the symbol.
    var dot: Int?
    let title: String
    let count: Int
    var alert = false
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let dot {
                        TagDot(color: dot, size: 8)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textTertiary)
                    }
                }
                .frame(width: 18)
                Text(title)
                    .font(.lumenBody)
                    .foregroundStyle(selected || hovered ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if alert {
                        Circle().fill(Theme.danger).frame(width: 5, height: 5)
                    }
                    Text(verbatim: "\(count)")
                        .font(.lumenSecondary)
                        .foregroundStyle(alert ? Theme.danger : Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.rowSelected : (hovered ? Theme.rowHover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.hover(hovered), value: hovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SyncStatusButton: View {
    let sync: SyncLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8)
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
            return String(format: L("profiles.sync.synced"), date.shownRelative)
        }
    }
}

// MARK: - Row

/// One profile (the design's `row`): a checkbox (under the pointer, or while some are selected),
/// its letters with the running dot, its name and tags; where it exits; how sites see it; its
/// state; and, under the pointer or selected, Launch or Stop and the ⋯ menu.
private struct ProfileRow: View {
    @Environment(\.tagColors) private var tagColors
    let row: ProfileRowItem
    let columns: ProfileColumns
    let actions: ProfileActions
    var isSelected = false
    /// Several rows are selected: every row shows its checkbox (one selected — the inspector's — shows its own).
    var showsCheckbox = false
    var height: CGFloat = 52
    /// A click on the row itself (not on its buttons or menu): selects it (`ProfileSelection`).
    var onClick: (ProfileSelection.Click) -> Void = { _ in }
    @State private var hovered = false

    var body: some View {
        HStack(spacing: ProfileColumns.gap) {
            checkbox
            nameCell.frame(maxWidth: .infinity, alignment: .leading)
            exitCell.frame(width: ProfileColumns.exit, alignment: .leading)
            if columns.showsAppearsAs {
                seenCell.frame(width: ProfileColumns.appearsAs, alignment: .leading)
            }
            stateCell.frame(width: columns.state, alignment: .leading)
            actionsCell.frame(width: ProfileColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, ProfileColumns.rowPadding)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? Theme.rowSelected : (hovered ? Theme.rowHover : Color.clear)))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
                .padding(.leading, ProfileColumns.rowPadding + ProfileColumns.nameInset - 18)
        }
        .contentShape(Rectangle())
        // The row's buttons and ⋯ menu take their own clicks; a click anywhere else selects.
        .onTapGesture { onClick(.current) }
        .onHover { hovered = $0 }
        .animation(Motion.hover(hovered), value: hovered)
        .opacity(row.activity == .sealing ? 0.6 : 1)
        .contextMenu { ProfileMenuItems(row: row, actions: actions) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(row.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var checkbox: some View {
        Button {
            onClick(.toggle)
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Theme.textPrimary : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? Theme.textPrimary : Theme.strongBorder, lineWidth: 1.5))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.backdrop)
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSelected || showsCheckbox || hovered ? 1 : 0)
        .accessibilityLabel(String(format: L("profiles.row.select"), row.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var nameCell: some View {
        HStack(spacing: 12) {
            ProfileAvatar(name: row.name, id: row.id, size: 30, style: row.avatar, running: row.isRunning)
            HStack(spacing: 8) {
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
                if !row.tags.isEmpty || row.ephemeral {
                    TagLine.text(row.tags + (row.ephemeral ? [L("profiles.row.ephemeralTag")] : []), colors: tagColors)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .help(row.notes)
    }

    private var exitCell: some View {
        HStack(spacing: 6) {
            ExitLabel(exit: row.exit, note: row.exitNote)
            if row.exitUnconfirmed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .help(L("profiles.exit.lookupFailed"))
                    .accessibilityLabel(L("profiles.exit.lookupFailed"))
            }
        }
    }

    private var seenCell: some View {
        HStack(spacing: 6) {
            if let symbol = row.deviceSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(row.appearsAs)
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var stateCell: some View {
        if let problem = row.problem, row.activity == .stopped {
            Text(L("profiles.row.failed"))
                .font(.lumenBody)
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .help(problem)
        } else {
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
                    HStack(spacing: 8) {
                        RunningDot()
                        Text(L("profiles.row.running")).font(.lumenBody).foregroundStyle(Theme.textPrimary)
                        if let since = row.lastUsed {
                            Text(Self.runningFor(since))
                                .font(.lumenBody)
                                .foregroundStyle(Theme.textTertiary)
                                .monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                }
            case .stopped:
                if row.warmUpQueued {
                    secondaryLine(L("profiles.row.warmUpQueued"))
                } else {
                    Text(lastUsed)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    /// "1 h 12 min": how long the profile has run, in the interface's language.
    static func runningFor(_ since: Date) -> String {
        var calendar = Calendar.current
        let formatter = DateComponentsFormatter(); calendar.locale = Localization.locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = since.timeIntervalSinceNow < -3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: max(60, -since.timeIntervalSinceNow)) ?? ""
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text).font(.lumenBody).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            secondaryLine(text)
        }
    }

    private var lastUsed: String {
        guard let date = row.lastUsed else { return L("profiles.lastUsed.never") }
        return date.shownRelative
    }

    private var actionsCell: some View {
        HStack(spacing: 4) {
            switch row.activity {
            case .running:
                Button { actions.stop(row.id) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .buttonStyle(LumenRingButtonStyle())
                .help(L("profiles.row.stop"))
                .accessibilityLabel(String(format: L("profiles.row.stopFor"), row.name))
            case .stopped:
                Button { actions.launch(row.id) } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(LumenRingButtonStyle())
                .help(L("profiles.row.launch"))
                .accessibilityLabel(String(format: L("profiles.row.launchFor"), row.name))
                .disabled(row.exit == .unreadable)
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
        .opacity(hovered || isSelected ? 1 : 0)
    }
}

/// The round icon button of a row (the design's `ib.ring`): 28 pt, a 16 % ring, brighter under the pointer.
struct LumenRingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RingButton(configuration: configuration)
    }

    private struct RingButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovered ? Theme.raisedInset : Color.clear))
                .overlay(Circle().strokeBorder(hovered ? Theme.edgeStrong : Theme.strongBorder, lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !Motion.isReduced(reduceMotion) ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
                .animation(Motion.hover(hovered), value: hovered)
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
    /// The country's flag beside its name.
    var showsFlag = true
    /// Why the country is not known, when it is not (`ProfileRowItem.unknownCountryNote`).
    var note: String?

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
                // The flag to find it by eye, the words to say what it is — a flag alone tells the
                // Netherlands from France poorly, and nothing to VoiceOver (the owner, 1 November).
                // Short of room, the code ("NL"), never the flag alone.
                if showsFlag {
                    CountryFlag(code: code, size: flagSize)
                        .accessibilityHidden(true)
                }
                ViewThatFits(in: .horizontal) {
                    Text(CountryNames.name(for: code))
                    Text(verbatim: code.uppercased())
                }
                .font(.lumenBody)
                .foregroundStyle(Theme.textPrimary)
                .help(String(format: L("profiles.exit.viaProxy"), endpoint))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CountryNames.name(for: code))
            case let .proxy(endpoint, nil):
                Image(systemName: "network")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: flagSize)
                Text(endpoint)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .truncationMode(.middle)
                    .help(note ?? L("profiles.exit.unknownCountry"))
            case .unreadable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .frame(width: flagSize)
                Text(L("profiles.exit.unreadable"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .help(String(format: L("profiles.exit.unreadable.help"), L("profiles.menu.syncNow"), L("profiles.menu.more")))
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

/// The vault's profile index not read as it should be: what happened, that nothing was deleted,
/// and how to get the profiles back — above the list, in the warning box the app uses elsewhere.
struct IndexNoticeBox: View {
    let notice: AppModel.IndexNotice
    let reveal: () -> Void

    var body: some View {
        LumenBanner(tone: .warning) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(notice))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Text(Self.text(notice))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: L("index.path"), notice.vaultPath))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L("index.reveal"), action: reveal)
                    .buttonStyle(.lumenSecondary)
            }
        }
    }

    static func title(_ notice: AppModel.IndexNotice) -> String {
        switch notice.kind {
        case .missing: return L("index.missing.title")
        case .unreadable: return L("index.unreadable.title")
        case .unlisted: return L("index.unlisted.title")
        case .takenIn: return L("index.takenIn.title")
        }
    }

    static func text(_ notice: AppModel.IndexNotice) -> String {
        switch notice.kind {
        case .missing: return String(format: L("index.missing.text"), notice.folders)
        case .unreadable: return String(format: L("index.unreadable.text"), notice.folders)
        case .unlisted: return String(format: L("index.unlisted.text"), notice.folders)
        case .takenIn: return String(format: L("index.takenIn.text"), notice.folders)
        }
    }
}

/// Deleted profiles whose folders are kept (R3, docs/DESTRUCTIVE_PATHS.md): deleted on another
/// device, or their folder put back from a backup. Not removed by anything but the person: each can
/// be brought back (as a new profile; its old folder stays until removed) or removed for good. One
/// whose folder cannot be read is never removed by the app: it can be shown in the Finder.
struct KeptDeletedBox: View {
    let profiles: [ProfileRepository.KeptDeletedProfile]
    var isWorking = false
    let bringBack: (UUID) -> Void
    let removeForGood: (ProfileRepository.KeptDeletedProfile) -> Void
    let reveal: (UUID) -> Void

    static func name(_ profile: ProfileRepository.KeptDeletedProfile) -> String {
        profile.name ?? L("profiles.kept.unnamed")
    }

    static func removeTitle(_ profile: ProfileRepository.KeptDeletedProfile) -> String {
        String(format: profile.broughtBack ? L("profiles.kept.removeTitle.broughtBack") : L("profiles.kept.removeTitle"), name(profile))
    }

    /// What is said under its name: that it cannot be read, that it was brought back, or when it was made.
    static func state(_ profile: ProfileRepository.KeptDeletedProfile) -> String? {
        if !profile.isReadable { return L("profiles.kept.unreadable") }
        if profile.broughtBack { return L("profiles.kept.broughtBack") }
        return profile.createdAt.map { String(format: L("profiles.kept.made"), $0.shown(date: .abbreviated, time: .omitted)) }
    }

    var body: some View {
        LumenBanner(tone: .warning) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("profiles.kept.title"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("profiles.kept.text"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(profiles, id: \.id) { profile in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.name(profile))
                                    .font(.lumenLabel)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                if let state = Self.state(profile) {
                                    Text(state)
                                        .font(.lumenSecondary)
                                        .foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 12)
                            if profile.isReadable {
                                if !profile.broughtBack {
                                    Button(L("profiles.kept.bringBack")) { bringBack(profile.id) }
                                        .buttonStyle(.lumenSecondary)
                                }
                                Button(profile.broughtBack ? L("profiles.kept.removeOld") : L("profiles.kept.remove")) { removeForGood(profile) }
                                    .buttonStyle(.lumenSecondary)
                            } else {
                                Button(L("profiles.kept.reveal")) { reveal(profile.id) }
                                    .buttonStyle(.lumenSecondary)
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }
        }
    }
}

/// A box above the list that asks for the person (the design's banner): a tint of its colour and
/// its line, radius 12, its edges in line with the header's.
struct LumenBanner<Content: View>: View {
    enum Tone { case danger, warning }

    let tone: Tone
    @ViewBuilder let content: () -> Content
    /// The first of several banners: "N more" (or "collapse") at its end.
    @Environment(\.bannerMore) private var more

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let more {
                Button(action: more.toggle) {
                    HStack(spacing: 6) {
                        Text(more.expanded ? L("banners.collapse") : String(format: L("banners.more"), more.count))
                            .monospacedDigit()
                        Image(systemName: more.expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(BannerMoreButtonStyle())
                .fixedSize()
                .help(more.expanded ? L("banners.collapse.help") : L("banners.more.help"))
                .accessibilityLabel(more.expanded ? L("banners.collapse") : String(format: L("banners.more.a11y"), more.count))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tone == .danger ? Theme.dangerTint : Theme.warningTint))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tone == .danger ? Theme.dangerLine : Theme.warningLine, lineWidth: 1))
        .padding(.horizontal, ProfilesScreen.headerTrailing)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }
}

/// The design's "N more" (`.morex`): a capsule 26 pt high with a fine line and a breath of white,
/// the words in full white and the chevron in grey; the line a shade stronger under the pointer,
/// a press sinking to 98 % (not under Reduce Motion), as the other buttons do.
private struct BannerMoreButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration)
    }

    private struct Pill: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(hovered ? 0.07 : 0.04)))
                .overlay(Capsule().strokeBorder(hovered ? Theme.edge : Theme.strongBorder, lineWidth: 1))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !Motion.isReduced(reduceMotion) ? 0.98 : 1)
                .onHover { hovered = $0 }
                .animation(Motion.hover(hovered), value: hovered)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// "N more" on the first of several banners: how many, whether they are open, and what opens them.
struct BannerMore {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void
}

private struct BannerMoreKey: EnvironmentKey {
    static let defaultValue: BannerMore? = nil
}

extension EnvironmentValues {
    var bannerMore: BannerMore? {
        get { self[BannerMoreKey.self] }
        set { self[BannerMoreKey.self] = newValue }
    }
}

/// A profile that did not start — or runs and loads nothing — because its proxy does not work
/// (`AppModel.proxyProblems`), said above the list (the design's banner): which profile, which
/// proxy, and what can be done: open the check (step by step, `ProxyProblemPanel`), launch it
/// again, or put the banner away. Several: the first, and how many more.
struct ProxyProblemBanner: View {
    struct Item: Equatable {
        var title: String
        var text: String
        /// Not started (Settings → Proxies): it can be launched again from here.
        var notStarted: Bool
        var more: Int
    }

    let item: Item
    let open: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        LumenBanner(tone: .danger) {
            HStack(alignment: .center, spacing: 12) {
                Circle().fill(Theme.danger).frame(width: 6, height: 6).accessibilityHidden(true)
                (Text(item.title + ".").font(.lumenLabel).foregroundStyle(Theme.textPrimary)
                    + Text(verbatim: " ")
                    + Text(item.text).font(.lumenBody).foregroundStyle(Theme.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.more > 0 {
                    Text(String(format: L("proxyProblem.more.short"), item.more))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                        .fixedSize()
                }
                Button(L("inspector.failed.open"), action: open)
                    .buttonStyle(.lumenGhost)
                    .fixedSize()
                if item.notStarted {
                    Button(L("inspector.failed.retry"), action: retry)
                        .buttonStyle(.lumenGhost)
                        .fixedSize()
                }
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(LumenIconButtonStyle(size: 26))
                    .help(L("common.close"))
                    .accessibilityLabel(L("common.close"))
            }
        }
    }
}

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

/// Nothing the search and the chosen collection let through (the design's "Nothing found"): what
/// was searched for, and one button that shows every profile again.
private struct NoMatchesView: View {
    let query: String
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L("profiles.noMatches"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 8)
            Text(query.isEmpty ? L("profiles.noMatches.filter") : String(format: L("profiles.noMatches.query"), query))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.bottom, 18)
            Button(L("profiles.showAll"), action: onShowAll)
                .buttonStyle(.lumenSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A search field (the design's `search`): 32 pt, radius 10, 3.5 % white with a 6 % edge; focused,
/// a little lighter with a 16 % edge. Its magnifier, a clear button, and the shortcut that opens
/// the command palette (`shortcut`), when given.
struct LumenSearchField: View {
    @Binding var text: String
    let prompt: String
    var shortcut: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField(text: $text, prompt: Text(verbatim: "")) {
                Text(prompt)
            }
            .textFieldStyle(.plain)
            .font(.lumenBody)
            .foregroundStyle(Theme.textPrimary)
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
            } else if let shortcut {
                KeyCap(keys: shortcut, small: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(Color.white.opacity(focused ? 0.05 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(focused ? Theme.strongBorder : Theme.divider, lineWidth: 1))
        .animation(Theme.hoverAnimation, value: focused)
    }
}
