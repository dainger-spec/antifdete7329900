import BrowserCore
import SwiftUI

/// The Profiles window's Virtual machines section (docs/VM.md): profiles that are whole Macs.
///
/// Signed in, the person adds the machines here: the macOS they run is fetched from Apple by the
/// app — none of it is in the app's own download — installed, and set up once; from then on each
/// profile's machine is made from it in a moment. The section says what that takes before it
/// takes it: the gigabytes, the memory, Apple's limit of two machines at once.
struct VirtualMachinesView: View {
    @EnvironmentObject private var model: AppModel
    var openAccount: () -> Void = {}

    var body: some View {
        if let center = model.virtualMachines {
            VirtualMachinesScreen(center: center, license: model.license, proxyList: model.proxyList, openAccount: openAccount)
        } else {
            LumenEmptyHint(symbol: "macwindow.on.rectangle", text: L("vm.unavailable.build"))
        }
    }
}

private struct VirtualMachinesScreen: View {
    @ObservedObject var center: VMCenter
    @ObservedObject var license: LicenseModel
    let proxyList: ProxyListModel?
    let openAccount: () -> Void

    @State private var editing: VMEditorView.Draft?
    @State private var deleting: VMProfile?
    @State private var showingStorage = false
    @State private var error: String?

    private enum Stage: Equatable { case unavailable(String), signedOut, notInPlan, setup, machines }

    /// The plan has virtual machines: the team plan's (`LicenseModel.allowsVirtualMachines`).
    private var allowed: Bool { license.allowsVirtualMachines }

    private var stage: Stage {
        switch VMCenter.availability {
        case .notAppleSilicon: return .unavailable(L("vm.unavailable.intel"))
        case .sandboxed, .notInThisBuild: return .unavailable(L("vm.unavailable.build"))
        case .available: break
        }
        if license.isConfigured, !license.record.isSignedIn { return .signedOut }
        // Machines there are stay in the list whatever became of the plan or of the base system —
        // to be seen, started where they can be, and deleted.
        if center.isReady || !center.profiles.isEmpty { return .machines }
        return allowed ? .setup : .notInPlan
    }

    /// The opening and the setup stand in the middle of the section when it is taller than they
    /// are; a list starts at its top.
    private var centersContent: Bool { stage != .machines }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    content(width: geometry.size.width)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 1180, alignment: .leading)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height,
                               alignment: centersContent ? .leading : .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { draft in
            VMEditorView(center: center, proxies: proxyList?.entries ?? [], draft: draft)
        }
        .sheet(isPresented: $showingStorage) {
            VMStorageView(center: center)
        }
        .confirmationDialog(deleting.map { String(format: L("vm.delete.title"), $0.name) } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(L("vm.delete.confirm"), role: .destructive) {
                if let profile = deleting { delete(profile) }
            }
        } message: {
            Text(L("vm.delete.message"))
        }
    }

    // MARK: The header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("vm.title"))
                    .lumenPageTitle()
                    .foregroundStyle(Theme.textPrimary)
                Text(summary)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 12)
            // What the machines take on disk, and how to have it back: wherever anything is there.
            if center.totalDiskUsage > 0 {
                Button { showingStorage = true } label: {
                    Label(VMText.bytes(center.totalDiskUsage), systemImage: "internaldrive")
                }
                .buttonStyle(.lumenGhost)
                .help(L("vm.storage.open"))
            }
            if stage == .machines {
                moreMenu
                Button { newMachine() } label: { Label(L("vm.new"), systemImage: "plus") }
                    .buttonStyle(.lumenPrimary)
                    .disabled(center.loadError != nil || !allowed || !center.isReady)
                    .help(center.isReady ? L("vm.new") : L("vm.new.needsBase"))
            }
        }
        .frame(height: ProfilesScreen.headerHeight)
        .padding(.leading, 28)
        .padding(.trailing, ProfilesScreen.headerTrailing)
        .padding(.top, ProfilesScreen.headerTop)
        .padding(.bottom, 16)
    }

    private var summary: String {
        guard stage == .machines else { return L("vm.subtitle") }
        return String(format: L("vm.summary"), center.profiles.count, center.running.count)
    }

    private var moreMenu: some View {
        Menu {
            Button(L("vm.storage.open")) { showingStorage = true }
            Button(L("vm.base.open")) { center.openBase() }
                .disabled(center.activity != nil || !allowed || !center.isReady)
            Button(L("vm.reveal")) { SystemOpen.revealInFinder([center.library.root]) }
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
    }

    // MARK: What is shown

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch stage {
        case .unavailable(let why):
            LumenEmptyHint(symbol: "macwindow.on.rectangle", text: why)
                .frame(minHeight: 220)
        case .signedOut:
            VMHero(title: L("vm.intro.title"), text: L("vm.intro.text"), actionTitle: L("vm.signIn"),
                   actionSymbol: "person.crop.circle", footnote: L("vm.signIn.note"), facts: facts, width: width,
                   action: openAccount)
        case .notInPlan:
            // The plan has no machines: the same opening — what a machine is and gives — with the
            // plan that has them named above it, and the way to it in the button's place.
            VMHero(badge: L("vm.plan.badge"), title: L("vm.intro.title"), text: L("vm.plan.text"),
                   actionTitle: L("vm.plan.upgrade"), actionSymbol: "arrow.up.right", footnote: L("vm.plan.note"),
                   facts: facts, width: width, action: choosePlan)
        case .setup:
            if center.activity == nil, center.setup == .none {
                VMHero(title: L("vm.intro.title"), text: L("vm.intro.text"), actionTitle: L("vm.add"),
                       actionEnabled: !center.requirements.contains(where: VMRequirements.stops),
                       footnote: L("vm.hero.note"), facts: facts,
                       problems: center.requirements, error: center.setupError, width: width,
                       action: { center.continueSetup() })
            } else {
                VMSetupPanel(center: center, width: width)
            }
        case .machines:
            machines
        }
    }

    /// What the machines take, in three figures: the room on disk while they are set up, the
    /// time, how many run at once.
    private var facts: [VMFact] {
        [VMFact(id: 0, value: VMText.bytes(center.setupNeedsBytes), label: L("vm.fact.disk")),
         VMFact(id: 1, value: L("vm.fact.time.value"), label: L("vm.fact.time")),
         VMFact(id: 2, value: String(VMRequirements.runningLimit), label: L("vm.fact.limit"))]
    }

    /// The plans' page of the site (a key's license without an email is paid for on the key's page),
    /// or the account's settings where the build knows no site.
    private func choosePlan() {
        if let url = license.configuration?.site(license.hasNoEmail ? "/key" : "/pricing") {
            SystemOpen.openWebsite(url)
        } else {
            openAccount()
        }
    }

    @ViewBuilder
    private var machines: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !allowed {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VMNote(L("vm.plan.machines"), tone: .warning)
                    Button(L("vm.plan.choose"), action: choosePlan)
                        .buttonStyle(.lumenSecondary)
                }
            }
            baseState
            if let loadError = center.loadError {
                VMNote(String(format: L("vm.error.load"), loadError), tone: .warning)
            }
            if let error {
                VMNote(error, tone: .danger)
            }
            if center.isReady, let setupError = center.setupError {
                VMNote(setupError, tone: .danger)
            }
            if center.isReady, center.activity == .guestSetup {
                VMNote(L("vm.base.isOpen"), tone: .plain, symbol: "macwindow")
            }
            if center.isReady, center.activity == nil,
               VMGuestTools.mustBeInstalledAgain(center.library.baseInfo()?.toolsVersion) {
                VMNote(L("vm.tools.old"), tone: .warning)
            }
            if center.runningCount >= VMRequirements.runningLimit {
                VMNote(String(format: L("vm.limit.reached"), VMRequirements.runningLimit), tone: .plain, symbol: "info.circle")
            }
            if center.profiles.isEmpty {
                VStack(spacing: 14) {
                    LumenEmptyHint(symbol: "macwindow.on.rectangle", text: L("vm.empty"))
                        .frame(height: 130)
                    Button { newMachine() } label: { Label(L("vm.new"), systemImage: "plus") }
                        .buttonStyle(.lumenPrimary)
                        .disabled(center.loadError != nil || !allowed || !center.isReady)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 8) {
                    ForEach(center.profiles) { profile in
                        VMRow(profile: profile, state: center.running[profile.id], problem: center.problems[profile.id],
                              exit: center.exits[profile.id], guest: center.guests[profile.id],
                              disk: center.diskUsage[profile.id],
                              canStart: allowed && center.runningCount < VMRequirements.runningLimit,
                              startRefusal: allowed ? nil : L("vm.error.notInPlan"),
                              start: { center.start(profile.id) }, stop: { center.stop(profile.id) },
                              forceStop: { center.forceStop(profile.id) },
                              edit: { editing = VMEditorView.Draft(profile: profile, isNew: false) },
                              delete: { deleting = profile })
                    }
                }
            }
            baseLine
            VMNote(L("vm.note.disks"), tone: .plain, symbol: "lock.open")
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    /// Above the list, while there is no base system to make new machines from: its setup, where
    /// it stands — or, with nothing of it left, the way to add it again.
    @ViewBuilder
    private var baseState: some View {
        if !center.isReady {
            if center.activity != nil || center.setup != .none {
                VMSetupPanel(center: center, compact: true)
            } else if allowed {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VMNote(L("vm.base.missing"), tone: .plain, symbol: "internaldrive")
                    Button(L("vm.base.add")) { center.continueSetup() }
                        .buttonStyle(.lumenSecondary)
                        .disabled(center.requirements.contains(where: VMRequirements.stops))
                }
                if let setupError = center.setupError {
                    VMNote(setupError, tone: .danger)
                }
            }
        }
    }

    /// Which macOS the machines are made from, and what the base takes.
    @ViewBuilder
    private var baseLine: some View {
        if case .ready(let info) = center.setup {
            let size = center.diskUsage[VMCenter.baseID].map { VMText.bytes($0) } ?? "…"
            let version = info.build.isEmpty ? info.version : "\(info.version) (\(info.build))"
            Text(String(format: L("vm.base.line"), version, size))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 6)
        }
    }

    // MARK: Actions

    private func newMachine() {
        error = nil
        let names = Set(center.profiles.map(\.name))
        var number = center.profiles.count + 1
        var name = String(format: L("vm.new.name"), number)
        while names.contains(name) {
            number += 1
            name = String(format: L("vm.new.name"), number)
        }
        // A new machine gets an accent colour at random, as Macs differ in theirs: the editor
        // shows it, and the person may change it.
        // As much memory as this Mac can spare a machine: with too little, macOS in it stutters.
        let memory = VMRequirements.recommendedMemoryGB(hostMemory: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
        editing = VMEditorView.Draft(profile: VMProfile(name: name, memoryGB: memory, accent: VMAccent.random().rawValue), isNew: true)
    }

    /// The person's Delete, confirmed: the one caller of the machines' one deletion path.
    private func delete(_ profile: VMProfile) {
        do {
            try center.deleteMachineBecauseThePersonAsked(profile.id)
            error = nil
        } catch {
            self.error = errorText(error)
        }
        deleting = nil
    }
}

// MARK: - Small parts

/// The section's words for sizes and speeds, as the interface says them.
enum VMText {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file).locale(Localization.locale))
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    /// "about 12 min left", from what is still to fetch and how fast it comes.
    static func remaining(bytes: Int64, speed: Double?) -> String? {
        guard let speed, speed > 50_000, bytes > 0 else { return nil }
        let minutes = Int((Double(bytes) / speed / 60).rounded(.up))
        if minutes >= 60 {
            return String(format: L("vm.setup.remaining.hours"), minutes / 60, minutes % 60)
        }
        return String(format: L("vm.setup.remaining.minutes"), max(1, minutes))
    }

    static func problem(_ problem: VMRequirements.Problem) -> String {
        switch problem {
        case .notAppleSilicon: return L("vm.unavailable.intel")
        case .unavailableInThisBuild: return L("vm.unavailable.build")
        case .notEnoughDisk(let needed, let free):
            return String(format: L("vm.requirement.disk"), bytes(needed), bytes(free))
        case .littleMemory(let machine, let host):
            return String(format: L("vm.requirement.memory"), bytes(host), bytes(machine))
        }
    }
}

struct VMNote: View {
    enum Tone { case plain, warning, danger }
    let text: String
    var tone: Tone = .plain
    var symbol: String?

    init(_ text: String, tone: Tone = .plain, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    private var color: Color {
        switch tone {
        case .plain: return Theme.textSecondary
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        }
    }

    var body: some View {
        Label(text, systemImage: symbol ?? (tone == .plain ? "info.circle" : "exclamationmark.triangle.fill"))
            .font(.lumenSecondary)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One profile's machine: what it is (where its proxy comes out, its screen, memory, system),
/// what it is doing, and what can be done with it.
private struct VMRow: View {
    let profile: VMProfile
    let state: VMCenter.Running?
    let problem: String?
    let exit: ProxyCheckResult?
    let guest: VMGuestStatus?
    let disk: Int64?
    let canStart: Bool
    /// Why Start is off, when it is not Apple's limit (the plan has no machines).
    var startRefusal: String?
    let start: () -> Void
    let stop: () -> Void
    let forceStop: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VMGlyph(profile: profile, running: state != nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.lumenRowTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let status {
                        Text(status)
                            .font(.lumenCaption)
                            .foregroundStyle(state?.phase == .running ? Theme.running : Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    if let country {
                        CountryFlag(code: country, size: 12)
                    }
                    Text(details)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !profile.notes.isEmpty {
                    Text(profile.notes)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let problem {
                    Text(problem)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let guest, VMGuestTools.mustBeInstalledAgain(guest.toolsVersion) {
                    // A machine made from a base with the first tools: its boot script takes no
                    // newer one, so what later versions set is not applied in it.
                    Text(L("vm.row.tools.old"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if profile.lumenWallpaper, let guest, guest.wallpaperFailed {
                    Text(String(format: L("vm.row.wallpaper.failed"), guest.wallpaperNote ?? "—"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.warning)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let trouble = state?.trouble, state?.phase == .running {
                    // A machine without a proxy that reaches nothing: why, in the person's words.
                    Label(L("vm.row.trouble.\(trouble.rawValue)"), systemImage: "wifi.exclamationmark")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = state?.troubleDetail, !detail.isEmpty {
                        // The helper's own words, as they are: for whoever is asked what is wrong.
                        Text(String(format: L("vm.row.trouble.detail"), detail))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if state?.viaSystemProxy == true, state?.phase == .running {
                    Text(L("vm.row.viaSystemProxy"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            if let state, state.phase == .running {
                Text(verbatim: "↑ \(VMText.bytes(state.bytesUp))  ↓ \(VMText.bytes(state.bytesDown))")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(L("vm.row.traffic.help"))
            }
            action
            menu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
    }

    private var country: String? {
        guard profile.proxy != nil else { return nil }
        return (exit?.countryCode ?? profile.countryCode)?.uppercased()
    }

    private var status: String? {
        switch state?.phase {
        case .checkingProxy?: return L("vm.row.checkingProxy")
        case .starting?: return L("vm.row.starting")
        case .running?: return L("vm.row.running")
        case .stopping?: return L("vm.row.stopping")
        case nil: return nil
        }
    }

    /// "Germany · 203.0.113.7 · MacBook Air 13″ · 4 GB · macOS 26.1, Safari 26.1 · 6.2 GB on disk".
    private var details: String {
        var parts: [String] = []
        if let proxy = profile.proxy {
            if let country { parts.append(CountryNames.name(for: country)) }
            parts.append(exit?.exitIP ?? "\(proxy.host):\(proxy.port)")
        } else {
            parts.append(L("vm.row.direct"))
        }
        parts.append(profile.display.name)
        parts.append(String(format: L("vm.row.memory"), profile.memoryGB))
        if let guest, let system = guest.systemVersion, !system.isEmpty {
            if let safari = guest.safariVersion, !safari.isEmpty {
                parts.append(String(format: L("vm.row.system.safari"), system, safari))
            } else {
                parts.append(String(format: L("vm.row.system"), system))
            }
        }
        if let disk, disk > 0 { parts.append(String(format: L("vm.row.disk"), VMText.bytes(disk))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        switch state?.phase {
        case nil:
            Button(action: start) { Label(L("vm.row.start"), systemImage: "play.fill") }
                .buttonStyle(.lumenSecondary)
                .disabled(!canStart)
                .help(canStart ? L("vm.row.start.help")
                    : startRefusal ?? String(format: L("vm.limit.reached"), VMRequirements.runningLimit))
        case .checkingProxy?, .starting?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button(L("vm.row.stop"), action: stop)
                    .buttonStyle(.lumenGhost)
            }
        case .running?:
            Button(L("vm.row.stop"), action: stop)
                .buttonStyle(.lumenGhost)
                .help(L("vm.row.stop.help"))
        case .stopping?:
            ProgressView().controlSize(.small)
        }
    }

    private var menu: some View {
        Menu {
            Button(L("vm.row.edit"), action: edit)
            if state != nil {
                Button(L("vm.row.forceStop"), action: forceStop)
            }
            Divider()
            Button(L("vm.row.delete"), role: .destructive, action: delete)
                .disabled(state != nil)
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
    }
}

// MARK: - The editor

/// A machine's sign in the list: the Mac its screen is, on the machine's colour.
struct VMGlyph: View {
    let profile: VMProfile
    var running = false
    var size: CGFloat = 34

    /// The machine's colour: the one chosen for it, or one by its id.
    static func colorIndex(of profile: VMProfile) -> Int {
        let count = ProfileAvatar.palette.count
        if let chosen = profile.colorIndex, (0..<count).contains(chosen) { return chosen }
        return ProfileAvatarStyle.color(for: profile.id) % count
    }

    var body: some View {
        let colors = ProfileAvatar.palette[Self.colorIndex(of: profile)]
        Image(systemName: profile.display.id.hasPrefix("macbook") ? "laptopcomputer" : "desktopcomputer")
            .font(.system(size: size * 0.44, weight: .regular))
            .foregroundStyle(Color(hex: colors.text))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color(hex: colors.fill)))
            .overlay(alignment: .bottomTrailing) {
                if running {
                    Circle().fill(Theme.greenDot)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A virtual machine's profile, new or changed, by what the settings are about: the machine
/// itself, where it goes out, where it says it is, the Mac it is, how its system looks, and what
/// happens at its start. What is changed here takes effect at the machine's next start.
struct VMEditorView: View {
    struct Draft: Identifiable {
        var profile: VMProfile
        var isNew: Bool
        var id: UUID { profile.id }
    }

    @ObservedObject var center: VMCenter
    let proxies: [ProxyListEntry]
    let draft: Draft
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var notes: String
    @State private var colorIndex: Int
    /// "": this Mac's connection. "current": the proxy the profile has, which the list no longer
    /// holds. Else a list entry's id.
    @State private var proxyChoice: String
    @State private var followsProxy: Bool
    @State private var timeZone: String
    @State private var language: String
    @State private var displayID: String
    @State private var memoryGB: Int
    /// 0: as a Mac has them.
    @State private var cores: Int
    @State private var soundEnabled: Bool
    /// "": as the base system has it.
    @State private var appearance: String
    @State private var accent: String
    @State private var computerName: String
    @State private var opensSafari: Bool
    @State private var lumenWallpaper: Bool
    @State private var startURL: String
    @State private var error: String?

    init(center: VMCenter, proxies: [ProxyListEntry], draft: Draft) {
        self.center = center
        // A machine's network speaks to a proxy in the clear (SOCKS5, HTTP): one reached over TLS
        // is not offered, and a proxy whose type no check has found is given to no profile.
        let usable = proxies.filter { $0.kindKnown && !$0.proxy.tlsToProxy }
        self.proxies = usable
        self.draft = draft
        let profile = draft.profile
        _name = State(initialValue: profile.name)
        _notes = State(initialValue: profile.notes)
        _colorIndex = State(initialValue: VMGlyph.colorIndex(of: profile))
        var choice = ""
        if let proxy = profile.proxy {
            let identity = ProxyList.identity(of: proxy)
            choice = usable.first { ProxyList.identity(of: $0.proxy) == identity }?.id.uuidString ?? "current"
        }
        _proxyChoice = State(initialValue: choice)
        _followsProxy = State(initialValue: profile.localeFollowsProxy)
        _timeZone = State(initialValue: profile.timeZoneIdentifier ?? TimeZone.current.identifier)
        _language = State(initialValue: profile.language ?? "")
        _displayID = State(initialValue: profile.displayID)
        _memoryGB = State(initialValue: profile.memoryGB)
        _cores = State(initialValue: profile.cores ?? 0)
        _soundEnabled = State(initialValue: profile.soundEnabled)
        _appearance = State(initialValue: profile.appearance ?? "")
        _accent = State(initialValue: profile.accent ?? "")
        _computerName = State(initialValue: profile.computerName ?? "")
        _opensSafari = State(initialValue: profile.opensSafari)
        _lumenWallpaper = State(initialValue: profile.lumenWallpaper)
        _startURL = State(initialValue: profile.startURL ?? "")
    }

    private var chosenEntry: ProxyListEntry? { proxies.first { $0.id.uuidString == proxyChoice } }

    /// The base system's tools are older than the settings of the system's look need: said under
    /// them, with what to do.
    private var toolsAreOld: Bool {
        VMGuestTools.mustBeInstalledAgain(center.library.baseInfo()?.toolsVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: draft.isNew ? L("vm.editor.title.new") : String(format: L("vm.editor.title"), draft.profile.name),
                        subtitle: L("vm.editor.subtitle"))
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section(L("vm.editor.section.machine")) { machineFields }
                    section(L("vm.editor.section.network")) { proxyField }
                    section(L("vm.editor.section.region")) { localeFields }
                    section(L("vm.editor.section.device")) { deviceFields }
                    section(L("vm.editor.section.system")) { systemFields }
                    section(L("vm.editor.section.start")) { startFields }
                    if center.isRunning(draft.profile.id) {
                        note(L("vm.editor.nextStart"), warns: true)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
            .frame(minHeight: 360, maxHeight: 620)
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? L("vm.editor.create") : L("common.save"), action: save)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheetFrame(width: 580)
        .background(Theme.raised)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).lumenCaps()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The machine

    @ViewBuilder
    private var machineFields: some View {
        EditorField(L("vm.editor.name")) {
            TextField(L("vm.editor.name"), text: $name, prompt: Text(verbatim: ""))
                .lumenField(L("vm.editor.name.placeholder"), isEmpty: name.isEmpty)
        }
        EditorField(L("vm.editor.color")) {
            HStack(spacing: 8) {
                ForEach(Array(ProfileAvatar.palette.enumerated()), id: \.offset) { index, colors in
                    Button {
                        colorIndex = index
                    } label: {
                        Circle()
                            .fill(Color(hex: colors.text))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: colorIndex == index ? 2 : 0).padding(-3))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                }
            }
        }
        EditorField(L("vm.editor.notes")) {
            TextField(L("vm.editor.notes"), text: $notes, prompt: Text(verbatim: ""))
                .lumenField(L("vm.editor.notes.placeholder"), isEmpty: notes.isEmpty)
        }
    }

    // MARK: Where it goes out

    private var proxyField: some View {
        EditorField(L("vm.editor.proxy")) {
            Picker(L("vm.editor.proxy"), selection: $proxyChoice) {
                Text(L("vm.editor.proxy.none")).tag("")
                if proxyChoice == "current", let proxy = draft.profile.proxy {
                    Text(verbatim: "\(proxy.host):\(proxy.port)").tag("current")
                }
                ForEach(proxies) { entry in
                    Text(verbatim: Self.title(of: entry)).tag(entry.id.uuidString)
                }
            }
            .labelsHidden()
            .fixedSize()
            note(proxyChoice.isEmpty ? L("vm.editor.proxy.direct.note") : L("vm.editor.proxy.note"), warns: proxyChoice.isEmpty)
            if proxies.isEmpty {
                note(L("vm.editor.proxy.empty"))
            }
        }
    }

    // MARK: Where it says it is

    @ViewBuilder
    private var localeFields: some View {
        EditorToggle(L("vm.editor.follow"), detail: L(proxyChoice.isEmpty ? "vm.editor.follow.direct" : "vm.editor.follow.detail"),
                     isOn: $followsProxy)
        if !followsProxy {
            EditorField(L("editor.tz")) {
                Picker(L("editor.tz"), selection: $timeZone) {
                    ForEach(ProfileEditorForm.timeZones, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            EditorField(L("editor.language")) {
                Picker(L("editor.language"), selection: $language) {
                    Text(L("vm.editor.language.base")).tag("")
                    ForEach(ProfileEditorForm.languageChoices(including: language), id: \.self) { tag in
                        Text(verbatim: ProfileEditorForm.languageName(tag)).tag(tag)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: The Mac it is

    @ViewBuilder
    private var deviceFields: some View {
        EditorField(L("vm.editor.display")) {
            Picker(L("vm.editor.display"), selection: $displayID) {
                ForEach(VMDisplay.presets) { display in
                    Text(verbatim: "\(display.name) — \(display.pointsWide) × \(display.pointsHigh)").tag(display.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            note(L("vm.editor.display.note"))
        }
        EditorField(L("vm.editor.memory")) {
            LumenSegmented(selection: $memoryGB,
                           options: VMRequirements.memoryChoices.map { (value: $0, title: String(format: L("vm.row.memory"), $0)) })
            note(memoryNote, warns: memoryIsTight || memoryIsLow)
        }
        EditorField(L("vm.editor.cores")) {
            LumenSegmented(selection: $cores, options: [(value: 0, title: L("vm.editor.cores.mac"))]
                + VMRequirements.coreChoices.filter { $0 < VMRequirements.coresWanted }
                    .map { (value: $0, title: String(format: L("vm.editor.cores.count"), $0)) })
            note(cores == 0 ? L("vm.editor.cores.note") : L("vm.editor.cores.fewer"), warns: cores != 0)
        }
        EditorToggle(L("vm.editor.sound"), detail: L("vm.editor.sound.detail"), isOn: $soundEnabled)
    }

    // MARK: How its system looks

    @ViewBuilder
    private var systemFields: some View {
        EditorField(L("vm.editor.appearance")) {
            LumenSegmented(selection: $appearance, options: [
                (value: "", title: L("vm.editor.asBase")),
                (value: VMAppearance.light.rawValue, title: L("vm.editor.appearance.light")),
                (value: VMAppearance.dark.rawValue, title: L("vm.editor.appearance.dark")),
                (value: VMAppearance.auto.rawValue, title: L("vm.editor.appearance.auto")),
            ])
            note(L("vm.editor.appearance.note"))
        }
        EditorField(L("vm.editor.accent")) {
            Picker(L("vm.editor.accent"), selection: $accent) {
                Text(L("vm.editor.asBase")).tag("")
                ForEach(VMAccent.allCases, id: \.rawValue) { value in
                    Text(L("vm.editor.accent.\(value.rawValue)")).tag(value.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            note(L("vm.editor.accent.note"))
        }
        EditorField(L("vm.editor.computerName")) {
            TextField(L("vm.editor.computerName"), text: $computerName, prompt: Text(verbatim: ""))
                .lumenField(L("vm.editor.computerName.placeholder"), isEmpty: computerName.isEmpty)
            note(L("vm.editor.computerName.note"))
        }
        EditorToggle(L("vm.editor.wallpaper"), detail: L("vm.editor.wallpaper.detail"), isOn: $lumenWallpaper)
        if toolsAreOld {
            note(L("vm.editor.tools.old"), warns: true)
        }
    }

    // MARK: Its start

    @ViewBuilder
    private var startFields: some View {
        EditorToggle(L("vm.editor.opensSafari"), detail: L("vm.editor.opensSafari.detail"), isOn: $opensSafari)
        EditorField(L("vm.editor.start")) {
            TextField(L("vm.editor.start"), text: $startURL, prompt: Text(verbatim: ""))
                .lumenField("https://", isEmpty: startURL.isEmpty)
        }
        .disabled(!opensSafari)
    }

    /// "Berlin 1 — Germany", as the proxy list names it and where it came out at its last check.
    private static func title(of entry: ProxyListEntry) -> String {
        guard let country = entry.lastCheck?.countryCode, entry.lastCheck?.isAlive == true else { return entry.displayName }
        return "\(entry.displayName) — \(CountryNames.name(for: country.uppercased()))"
    }

    private var memoryIsTight: Bool {
        Int64(clamping: ProcessInfo.processInfo.physicalMemory) - Int64(memoryGB) * VMRequirements.gibibyte < 4 * VMRequirements.gibibyte
    }

    private var recommendedMemoryGB: Int {
        VMRequirements.recommendedMemoryGB(hostMemory: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
    }

    /// Less than this Mac can spare a machine, and little for macOS with Safari: it will stutter.
    private var memoryIsLow: Bool { memoryGB < recommendedMemoryGB }

    private var memoryNote: String {
        if memoryIsTight {
            return String(format: L("vm.editor.memory.tight"), VMText.bytes(Int64(clamping: ProcessInfo.processInfo.physicalMemory)))
        }
        if memoryIsLow { return String(format: L("vm.editor.memory.low"), memoryGB, recommendedMemoryGB) }
        return L("vm.editor.memory.note")
    }

    private func note(_ text: String, warns: Bool = false) -> some View {
        Text(text)
            .font(.lumenSecondary)
            .foregroundStyle(warns ? Theme.warning : Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        var profile = draft.profile
        profile.name = name
        profile.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.colorIndex = colorIndex
        profile.displayID = displayID
        profile.memoryGB = memoryGB
        profile.cores = cores == 0 ? nil : cores
        profile.soundEnabled = soundEnabled
        profile.appearance = appearance.isEmpty ? nil : appearance
        profile.accent = accent.isEmpty ? nil : accent
        profile.opensSafari = opensSafari
        profile.lumenWallpaper = lumenWallpaper
        profile.localeFollowsProxy = followsProxy
        let computer = computerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if computer.isEmpty {
            profile.computerName = nil
        } else {
            guard let checked = VMGuestSettings.computerName(computer) else {
                error = L("vm.editor.error.computerName")
                return
            }
            profile.computerName = checked
        }
        let start = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if start.isEmpty {
            profile.startURL = nil
        } else {
            // "example.com" is taken as the address it means.
            let address = start.contains("://") ? start : "https://" + start
            guard let checked = VMGuestSettings.startURL(address) else {
                error = L("vm.editor.error.start")
                return
            }
            profile.startURL = checked
        }
        var lastCheck: ProxyCheckResult?
        switch proxyChoice {
        case "":
            profile.proxy = nil
            profile.countryCode = nil
        case "current":
            break
        default:
            guard let entry = chosenEntry else { break }
            profile.proxy = entry.proxy
            lastCheck = entry.lastCheck
            profile.countryCode = entry.lastCheck?.countryCode?.uppercased()
        }
        if followsProxy {
            if profile.proxy == nil {
                // This Mac's connection: sites see this Mac's address, and this Mac's time zone.
                profile.timeZoneIdentifier = TimeZone.current.identifier
                profile.language = nil
            } else {
                // What the list's last check found, until the check at the machine's start.
                profile = profile.followingProxy(check: lastCheck)
            }
        } else {
            profile.timeZoneIdentifier = timeZone
            profile.language = language.isEmpty ? nil : language
        }
        do {
            try center.save(profile)
            center.measureDisk()
            dismiss()
        } catch {
            self.error = errorText(error)
        }
    }
}
