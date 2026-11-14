import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// The proxy list, a section of the Profiles window (its sidebar's Proxies): the proxies kept at
/// hand, encrypted in the vault, with what their last check found — working or how not, the type,
/// where they exit, how slow they are, and how many profiles use each. Import adds a pasted list;
/// Check checks the selection (or all) through each proxy itself, step by step; Assign gives the
/// selected proxies to profiles, in turn; Edit changes one, and the profiles that use it follow;
/// Export writes the list out (passwords in plaintext, said so first); Delete removes them from the
/// list (each profile keeps its own copy). The selected proxy's last check, step by step, below;
/// the first proxy is selected when the list opens.
///
/// A section of the window rather than a sheet: the sheet was wider than its own frame (the UI
/// snapshots of run 429 showed it cut on both sides at 940 pt, and a narrow window cut it more),
/// and a proxy, like a profile, is what the window is for.
struct ProxyListView: View {
    /// The selected proxies, kept by the window while another section shows ("Show in Proxies"
    /// selects a profile's proxy).
    @Binding var selection: Set<UUID>
    @EnvironmentObject private var model: AppModel
    /// The inspector at the section's right, as the person left it.
    @AppStorage("proxies.inspector") private var showsInspector = true

    var body: some View {
        if let proxies = model.proxyList {
            ProxyListPanel(proxies: proxies, profileCounts: model.proxyUseCounts, profilesUsing: profilesUsing,
                           selection: $selection, showsInspector: $showsInspector)
        }
    }

    /// The profiles that use each proxy, by `ProxyList.identity(of:)`, in the list's order.
    private var profilesUsing: [String: [ProxyProfileReference]] {
        model.profiles.reduce(into: [:]) { found, profile in
            guard let details = model.details[profile.id], let identity = details.proxyIdentity else { return }
            found[identity, default: []].append(ProxyProfileReference(id: profile.id, name: profile.name, avatar: details.avatar))
        }
    }
}

/// The section's body over a list model (rendered with a sample list by `--render-ui-snapshots`):
/// the design's Proxies screen — its header, the table, and the inspector of the selected proxy.
struct ProxyListPanel: View {
    @ObservedObject var proxies: ProxyListModel
    /// How many profiles use each proxy, by `ProxyList.identity(of:)`.
    var profileCounts: [String: Int] = [:]
    /// Which profiles.
    var profilesUsing: [String: [ProxyProfileReference]] = [:]
    @Binding var selection: Set<UUID>
    /// The inspector at the right, shown while this is on (the header's button): beside the list
    /// when there is room for both, over the list's right side when there is not.
    var showsInspector: Binding<Bool> = .constant(true)

    @State private var search = ""
    @State private var adding = false
    @State private var importing = false
    @State private var exporting = false
    @State private var assigning: ProxyAssignView.Request?
    @State private var editing: ProxyListEntry?
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let inspectorFits = geometry.size.width - ProfilesScreen.inspectorWidth >= ProxyColumns.minimumContentWidth
            HStack(spacing: 0) {
                main(inspectorOver: inspectorShown && !inspectorFits)
                if inspectorShown && inspectorFits {
                    inspector(top: ProfilesScreen.inspectorTop)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.isReduced(reduceMotion) ? nil : Theme.appearAnimation, value: inspectorShown)
        }
        .onAppear(perform: selectFirstIfNone)
        .onChange(of: proxies.entries.map(\.id)) { _, _ in selectFirstIfNone() }
        .sheet(isPresented: $adding) {
            ProxyEditView(proxies: proxies, entry: nil, profileCount: 0) { added in selection = [added] }
        }
        .sheet(isPresented: $importing) {
            ProxyImportView(proxies: proxies) { added in selection = Set(added) }
        }
        .sheet(isPresented: $exporting) {
            ProxyExportView(proxies: proxies, selection: selectedVisible)
        }
        .sheet(item: $assigning) { request in ProxyAssignView(request: request) }
        .sheet(item: $editing) { entry in
            ProxyEditView(proxies: proxies, entry: entry, profileCount: profileCount(entry))
        }
        .confirmationDialog(String(format: L("proxies.delete.title"), selectedVisible.count), isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button(L("proxies.delete.confirm"), role: .destructive) {
                proxies.remove(selectedVisible)
                selection = []
            }
        } message: {
            Text(deleteMessage)
        }
    }

    /// `inspectorOver`: no room beside the table — the inspector lies over the table only, and the
    /// header's buttons (Import…, Check all) stay within reach.
    private func main(inspectorOver: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let loadError = proxies.loadError {
                Label(String(format: L("proxies.error.loadDetail"), loadError), systemImage: "exclamationmark.triangle.fill")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            content
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    if inspectorOver {
                        inspector(top: 8)
                            .shadow(color: .black.opacity(0.55), radius: 30, x: -6)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: What is shown

    private var visible: [ProxyListEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return proxies.entries }
        return proxies.entries.filter { entry in
            [entry.label, entry.address, entry.proxy.username ?? "", entry.lastCheck?.exitIP ?? "", entry.lastCheck?.city ?? "",
             entry.lastCheck?.countryCode.map(CountryNames.name(for:)) ?? "", entry.state(checking: false).shortText,
             entry.origin == .service ? L("proxies.origin.service.short") : ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// The selected proxies the list shows: what Check, Assign, Export and Delete act on (a proxy
    /// the search hides is never acted on unseen).
    private var selectedVisible: Set<UUID> {
        selection.intersection(visible.map(\.id))
    }

    /// The one selected proxy, for Edit and the inspector.
    private var single: ProxyListEntry? {
        guard selectedVisible.count == 1, let id = selectedVisible.first else { return nil }
        return proxies.list.entry(id)
    }

    /// With nothing of the list selected, its first proxy: the inspector shows a check at once.
    private func selectFirstIfNone() {
        if selection.intersection(proxies.entries.map(\.id)).isEmpty, let first = visible.first {
            selection = [first.id]
        }
    }

    private func profileCount(_ entry: ProxyListEntry) -> Int {
        profileCounts[ProxyList.identity(of: entry.proxy)] ?? 0
    }

    /// Profiles keep their own copy of a proxy: removing it from the list takes it from none.
    private var deleteMessage: String {
        let used = proxies.entries.filter { selectedVisible.contains($0.id) }.reduce(0) { $0 + profileCount($1) }
        guard used > 0 else { return L("proxies.delete.message") }
        return L("proxies.delete.message") + " " + String(format: L("proxies.delete.used"), used)
    }

    // MARK: The header

    /// As the profiles have theirs: the title and how the list stands under it, the search, the
    /// inspector's button, Check, the rarer actions (⋯) and Import.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("proxies.title"))
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
            if proxies.isChecking {
                ProgressView().controlSize(.small).transition(.opacity)
            }
            LumenSearchField(text: $search, prompt: L("proxies.search"))
                .frame(maxWidth: 240)
            Button {
                showsInspector.wrappedValue.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(LumenIconButtonStyle(size: 32, isOn: showsInspector.wrappedValue))
            .help(showsInspector.wrappedValue ? L("inspector.hide") : L("inspector.show"))
            .accessibilityLabel(showsInspector.wrappedValue ? L("inspector.hide") : L("inspector.show"))
            checkButton
            moreMenu
            Button { importing = true } label: { Label(L("proxies.import"), systemImage: "plus") }
                .buttonStyle(.lumenPrimary)
                .disabled(proxies.loadError != nil)
        }
        .frame(height: ProfilesScreen.headerHeight)
        .padding(.leading, 28)
        .padding(.trailing, ProfilesScreen.headerTrailing)
        .padding(.top, ProfilesScreen.headerTop)
        .padding(.bottom, 16)
        .animation(Theme.hoverAnimation, value: proxies.isChecking)
    }

    /// "Checked 3 of 9" while a check runs; else how many answered at their last check.
    private var summary: String {
        if proxies.isChecking {
            return String(format: L("proxies.checking.progress"), proxies.checkedCount, proxies.checkTotal)
        }
        let checked = proxies.entries.compactMap(\.lastCheck)
        return String(format: L("proxies.summary"), proxies.entries.count, checked.filter(\.isAlive).count,
                      checked.filter { !$0.isAlive }.count)
    }

    /// Check all, or the selected (several); Stop while a check runs.
    @ViewBuilder
    private var checkButton: some View {
        if proxies.isChecking {
            Button { proxies.stopChecking() } label: { Text(L("proxies.check.stop")) }
                .buttonStyle(.lumenGhost)
        } else {
            Button {
                proxies.check(selectedVisible.count > 1 ? selectedVisible : nil)
            } label: {
                Text(selectedVisible.count > 1 ? L("proxies.check.selected") : L("proxies.check.all"))
            }
            .buttonStyle(.lumenGhost)
            .disabled(proxies.entries.isEmpty)
            .help(L("proxies.check.help"))
        }
    }

    /// Add one, Assign, Edit, Export and Delete: each also in a proxy's own menu (a right click),
    /// and Delete on the Delete key.
    private var moreMenu: some View {
        MoreMenu {
            Button(L("proxies.add")) { adding = true }
                .disabled(proxies.loadError != nil)
            Button(L("proxies.assign")) {
                assigning = ProxyAssignView.Request(profileIDs: [], proxyIDs: selectedVisible)
            }
            .disabled(proxies.entries.isEmpty)
            Divider()
            Button(L("proxies.edit")) { editing = single }
                .disabled(single == nil || proxies.loadError != nil)
            Button(L("proxies.export")) { exporting = true }
                .disabled(proxies.entries.isEmpty)
            Divider()
            Button(L("proxies.delete"), role: .destructive) { confirmingDelete = true }
                .disabled(selectedVisible.isEmpty)
        }
        .help(L("profiles.menu.more"))
        .accessibilityLabel(L("profiles.menu.more"))
    }

    // MARK: The list

    @ViewBuilder
    private var content: some View {
        if proxies.entries.isEmpty {
            VStack(spacing: 14) {
                LumenEmptyHint(symbol: "network", text: L("proxies.empty"))
                    .frame(maxHeight: 160)
                HStack(spacing: 8) {
                    Button { importing = true } label: { Label(L("proxies.import"), systemImage: "plus") }
                        .buttonStyle(.lumenPrimary)
                    Button(L("proxies.add")) { adding = true }
                        .buttonStyle(.lumenGhost)
                }
                .disabled(proxies.loadError != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let columns = ProxyColumns(contentWidth: geometry.size.width)
                VStack(alignment: .leading, spacing: 0) {
                    ProxyColumnHeader(columns: columns)
                    ScrollViewReader { scroller in
                        List(selection: $selection) {
                            ForEach(visible) { entry in
                                ProxyRow(entry: entry, checking: proxies.checking.contains(entry.id), profiles: profileCount(entry),
                                         columns: columns)
                                    .tag(entry.id)
                                    .id(entry.id)
                                    .listRowSeparatorTint(Theme.divider)
                                    // The design's selected row, as the profiles' (the system's grey off).
                                    .listRowBackground(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selection.contains(entry.id) ? Theme.rowSelected : Color.clear))
                                    .background(SystemListHighlightOff().accessibilityHidden(true))
                            }
                        }
                        .listStyle(.plain)
                        .overlay {
                            if visible.isEmpty {
                                Text(L("proxies.noMatches")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            if !ids.isEmpty { menu(for: ids) }
                        } primaryAction: { ids in
                            // Double-click: check them again.
                            if !proxies.isChecking { proxies.check(ids) }
                        }
                        .onDeleteCommand {
                            if !selectedVisible.isEmpty { confirmingDelete = true }
                        }
                        .onAppear {
                            // Opened for one proxy (a profile's): it is in view.
                            if selection.count == 1, let id = selection.first { scroller.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        Button(L("proxies.menu.check")) { proxies.check(ids) }
            .disabled(proxies.isChecking)
        if ids.count == 1, let id = ids.first {
            Button(L("proxies.menu.edit")) { editing = proxies.list.entry(id) }
                .disabled(proxies.loadError != nil)
            if proxies.list.entry(id)?.changeIPURL != nil {
                Button(L("proxies.ipChange.action")) { Task { await proxies.changeIP(id) } }
                    .disabled(proxies.changingIP.contains(id) || proxies.loadError != nil)
            }
        }
        Button(L("proxies.menu.assign")) {
            assigning = ProxyAssignView.Request(profileIDs: [], proxyIDs: ids)
        }
        Divider()
        Button(L("proxies.menu.delete"), role: .destructive) {
            selection = ids
            confirmingDelete = true
        }
    }

    // MARK: The inspector

    /// Shown: turned on, and there are proxies.
    private var inspectorShown: Bool {
        showsInspector.wrappedValue && !proxies.entries.isEmpty
    }

    /// `top`: where its content starts (`ProfilesScreen.inspector(top:)`).
    private func inspector(top: CGFloat) -> some View {
        Group {
            if let entry = single {
                ProxyInspectorView(entry: entry, checking: proxies.checking.contains(entry.id),
                                   profiles: profilesUsing[ProxyList.identity(of: entry.proxy)] ?? [],
                                   changingIP: proxies.changingIP.contains(entry.id),
                                   lastIPChange: proxies.ipChanges[entry.id],
                                   changeIP: entry.changeIPURL == nil || proxies.loadError != nil ? nil : { Task { await proxies.changeIP(entry.id) } },
                                   check: { proxies.check([entry.id]) },
                                   edit: proxies.loadError == nil ? { editing = entry } : nil,
                                   assign: { assigning = ProxyAssignView.Request(profileIDs: [], proxyIDs: [entry.id]) })
                    .id(entry.id)
            } else if selectedVisible.count > 1 {
                ProxySelectionInspectorView(count: selectedVisible.count, checking: proxies.isChecking,
                                            check: { proxies.check(selectedVisible) },
                                            assign: { assigning = ProxyAssignView.Request(profileIDs: [], proxyIDs: selectedVisible) },
                                            delete: { confirmingDelete = true })
            } else {
                LumenEmptyHint(symbol: "sidebar.right", text: L("inspector.proxy.empty"))
                    .padding(24)
            }
        }
        .frame(width: ProfilesScreen.inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, top)
        .background(Theme.sidebar.opacity(0.8))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("inspector.proxy.title"))
    }
}

// MARK: - Rows


/// Column widths of the proxy list (the design's table), and whether the exit IP fits (the name
/// takes what is left).
struct ProxyColumns {
    static let kind: CGFloat = 72
    static let exit: CGFloat = 132
    static let ip: CGFloat = 118
    static let latency: CGFloat = 104
    static let state: CGFloat = 156
    static let gap: CGFloat = 12
    static let minimumName: CGFloat = 170
    /// The rows' own inset, on both sides.
    static let inset: CGFloat = 8
    /// The narrowest list (with the section's 20 pt margins) whose rows keep every column but the IP.
    static let minimumContentWidth: CGFloat = 2 * 20 + 2 * Self.inset + Self.kind + Self.exit + Self.latency + Self.state
        + 4 * Self.gap + Self.minimumName

    let showsIP: Bool

    init(contentWidth: CGFloat) {
        showsIP = contentWidth + 2 * 20 >= Self.minimumContentWidth + Self.ip + Self.gap
    }
}

private struct ProxyColumnHeader: View {
    let columns: ProxyColumns

    var body: some View {
        HStack(spacing: ProxyColumns.gap) {
            Text(L("proxies.column.proxy")).lumenCaps().frame(maxWidth: .infinity, alignment: .leading)
            Text(L("proxies.column.type")).lumenCaps().frame(width: ProxyColumns.kind, alignment: .leading)
            Text(L("proxies.column.exit")).lumenCaps().frame(width: ProxyColumns.exit, alignment: .leading)
            if columns.showsIP {
                Text(L("proxies.column.ip")).lumenCaps().frame(width: ProxyColumns.ip, alignment: .leading)
            }
            Text(L("proxies.column.latency")).lumenCaps().frame(width: ProxyColumns.latency, alignment: .leading)
            Text(L("proxies.column.state")).lumenCaps().frame(width: ProxyColumns.state, alignment: .leading)
        }
        .lineLimit(1)
        // The list's own row inset, so the titles stand over their columns.
        .padding(.horizontal, ProxyColumns.inset + 8)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct ProxyRow: View {
    let entry: ProxyListEntry
    let checking: Bool
    let profiles: Int
    let columns: ProxyColumns

    var body: some View {
        let state = entry.state(checking: checking)
        HStack(spacing: ProxyColumns.gap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.displayName)
                        .font(.lumenRowTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.origin == .service {
                        Text(L("proxies.origin.service.short"))
                            .font(.lumenCaption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let check = entry.lastCheck, let label = check.udpLabel {
                        Text(ProxyUDPText.short(label))
                            .font(.lumenCaption)
                            .foregroundStyle(label == .unsupported ? Theme.warning : Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .help(ProxyUDPText.help(check))
                    }
                }
                if !subline.isEmpty {
                    Text(subline)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(String(format: L("proxies.profiles.help"), profiles))
            Text(entry.kindKnown ? entry.kindName : "—") // l10n: not text
                .font(.lumenBody)
                .foregroundStyle(entry.kindKnown ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(1)
                .frame(width: ProxyColumns.kind, alignment: .leading)
                .help(entry.kindKnown ? "" : L("proxies.type.unknown.help"))
            Text(exitPlace)
                .font(.lumenBody)
                .foregroundStyle(entry.lastCheck?.countryCode == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .frame(width: ProxyColumns.exit, alignment: .leading)
                .help(exitHelp)
            if columns.showsIP {
                Text(entry.lastCheck?.isAlive == true ? (entry.lastCheck?.exitIP ?? "—") : "—") // l10n: not text
                    .font(.lumenMono)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: ProxyColumns.ip, alignment: .leading)
            }
            ProxyLatency(check: entry.lastCheck)
                .frame(width: ProxyColumns.latency, alignment: .leading)
            HStack(spacing: 7) {
                if checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(state == .unchecked ? Color.clear : state.color).frame(width: 6, height: 6)
                }
                Text(state.shortText)
                    .font(.lumenBody)
                    .foregroundStyle(state.isWorking ? Theme.textPrimary : (state == .unchecked ? Theme.textTertiary : state.color))
                    .lineLimit(1)
            }
            .frame(width: ProxyColumns.state, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// Under the name: the address (when a label is the name) and the user name.
    private var subline: String {
        var parts: [String] = []
        if !entry.label.isEmpty { parts.append(entry.address) }
        if let user = entry.proxy.username, !user.isEmpty { parts.append(user) }
        return parts.joined(separator: " · ") // l10n: not text
    }

    /// Where its last check found it exits; "—" before one, or when it did not say.
    private var exitPlace: String {
        guard let code = entry.lastCheck?.countryCode else {
            return entry.lastCheck == nil ? L("proxies.status.unchecked") : "—" // l10n: not text
        }
        return CountryNames.name(for: code)
    }

    private var exitHelp: String {
        guard let check = entry.lastCheck, let code = check.countryCode else { return "" }
        guard let city = check.city, !city.isEmpty else { return CountryNames.name(for: code) }
        return CountryNames.name(for: code) + ", " + city // l10n: not text
    }
}

/// How long it takes to get through a proxy (the design's latency): a short bar against 500 ms and
/// the milliseconds, amber when slower than a page should wait; "—" without a measure.
struct ProxyLatency: View {
    let check: ProxyCheckResult?

    var body: some View {
        if let check, check.isAlive, let latency = check.latencyMilliseconds {
            let slow = ProxyCheckText.isSlow(check)
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(slow ? Theme.warning : Theme.textPrimary)
                        .frame(width: max(3, 48 * min(1, CGFloat(latency) / 500)))
                }
                .frame(width: 48, height: 2)
                .accessibilityHidden(true)
                Text(String(format: L("proxies.latency"), latency))
                    .font(.lumenSecondary)
                    .foregroundStyle(slow ? Theme.warning : Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else {
            Text(verbatim: "—")
                .font(.lumenBody)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Where the proxy exits, as its last check found: the country with its flag (and the city);
/// how it fails, in its state's colour; or that it has not been checked.
struct ProxyExitLabel: View {
    let check: ProxyCheckResult?
    var checking = false
    var showsCity = false

    var body: some View {
        let state = ProxyState(check: check, checking: checking)
        HStack(spacing: 8) {
            if state == .checking {
                Text(state.shortText).foregroundStyle(Theme.textSecondary)
            } else if state == .unchecked {
                Text(state.shortText).foregroundStyle(Theme.textTertiary)
            } else if !state.isWorking {
                Text(state.shortText).foregroundStyle(state.color)
            } else if let check, let code = check.countryCode {
                CountryFlag(code: code, size: 14)
                Text(place(code, city: check.city)).foregroundStyle(Theme.textPrimary)
                    .help(place(code, city: check.city))
            } else {
                Text(state.shortText).foregroundStyle(Theme.textPrimary)
            }
        }
        .font(.lumenBody)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func place(_ code: String, city: String?) -> String {
        guard showsCity, let city, !city.isEmpty else { return CountryNames.name(for: code) }
        return CountryNames.name(for: code) + ", " + city // l10n: not text
    }
}

// MARK: - Wording

extension ProxyListEntry {
    /// "SOCKS5", "HTTP", or "HTTPS" for TLS to the proxy.
    var kindName: String { ProxyReport.kindName(proxy.kind, tls: proxy.tlsToProxy) }

    /// The line under the name: the address (when a label is the name) and the user name.
    var detailLine: String {
        var parts: [String] = []
        // The service's proxies say so where every list shows them; the user's own are the rule.
        if origin == .service { parts.append(L("proxies.origin.service.short")) }
        if !label.isEmpty { parts.append(address) }
        if let user = proxy.username, !user.isEmpty { parts.append(user) }
        return parts.joined(separator: " · ") // l10n: not text
    }

    func state(checking: Bool) -> ProxyState { ProxyState(check: lastCheck, checking: checking) }

    /// Where the proxy came from, and since when, for its report.
    var originLine: String {
        let date = addedAt.timeIntervalSince1970 > 0 ? addedAt.shown(date: .long, time: .omitted) : nil
        switch origin {
        case .user: return date.map { String(format: L("proxies.origin.user.since"), $0) } ?? L("proxies.origin.user")
        case .service: return date.map { String(format: L("proxies.origin.service.since"), $0) } ?? L("proxies.origin.service")
        }
    }
}

@MainActor
/// What the list and a profile's card say of a proxy's UDP (`ProxyCheckResult.udpLabel`): a
/// word beside it, and on hover what it means for WebRTC in profiles with it.
enum ProxyUDPText {
    static func short(_ label: ProxyUDPLabel) -> String {
        switch label {
        case .supported: return L("proxies.udp.supported")
        case .unsupported: return L("proxies.udp.unsupported")
        case .unchecked: return L("proxies.udp.unchecked")
        }
    }

    static func help(_ check: ProxyCheckResult) -> String {
        switch check.udp {
        case .supported: return L("proxies.udp.supported.help")
        case .elsewhere: return L("proxies.udp.elsewhere.help")
        case .unsupported: return L("proxies.udp.unsupported.help")
        case .unknown, .exitUnknown, nil: return L("proxies.udp.unchecked.help")
        }
    }
}

enum ProxyCheckText {
    /// "120 ms"; empty without one, and for a proxy that does not work.
    static func latency(_ check: ProxyCheckResult?) -> String {
        guard let check, check.isAlive else { return "" }
        return check.latencyMilliseconds.map { String(format: L("proxies.latency"), $0) } ?? ""
    }

    /// Slower than a page should wait for its first byte.
    static func isSlow(_ check: ProxyCheckResult?) -> Bool {
        check?.isAlive == true && (check?.latencyMilliseconds ?? 0) >= 1500
    }

    /// One line for a menu item (which shows text only): the flag, the name, the address and how
    /// the last check went.
    static func menuTitle(_ entry: ProxyListEntry) -> String {
        var title = entry.displayName
        if !entry.label.isEmpty { title += " — " + entry.address } // l10n: not text
        let state = entry.state(checking: false)
        guard let check = entry.lastCheck else { return title }
        if !state.isWorking { return title + " · " + state.shortText } // l10n: not text
        if let code = check.countryCode, let flag = CountryFlag.emoji(for: code) { title = flag + " " + title }
        if let latency = check.latencyMilliseconds { title += " · " + String(format: L("proxies.latency"), latency) } // l10n: not text
        return title
    }

    /// For a picker: proxies that answered first (fastest first), then the unchecked, then the dead.
    static func pickingOrder(_ entries: [ProxyListEntry]) -> [ProxyListEntry] {
        func rank(_ entry: ProxyListEntry) -> Int {
            guard let check = entry.lastCheck else { return 1 }
            return check.isAlive ? 0 : 2
        }
        return entries.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (la, lb) = (a.element.lastCheck?.latencyMilliseconds ?? .max, b.element.lastCheck?.latencyMilliseconds ?? .max)
            if la != lb { return la < lb }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Add and edit

/// Adds one proxy to the list, or changes one: its name, and the proxy as one line in any of the
/// forms providers sell (`ProxyLineField`), with Check beside it. The profiles that use an edited
/// proxy as it was follow (`ProfileRepository.follow`); a changed proxy loses its last check — or
/// gets the one just run from here. The type comes from the scheme; without one, from a check — or
/// it stays the entry's own while the line still names that proxy. A proxy whose type was not
/// known yet (a new one, or an import line without a scheme) may stay so until its first check;
/// one whose type was known is never made unknown: Save checks it first.
struct ProxyEditView: View {
    @ObservedObject var proxies: ProxyListModel
    /// Nil: a new proxy (Add).
    let entry: ProxyListEntry?
    let profileCount: Int
    /// The proxy just added (the list selects it).
    var onAdded: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var line: ProxyLine
    @State private var checking = false
    @State private var error: String?
    /// The provider's IP-change link as typed, and whether a launch changes the IP first.
    @State private var changeLink: String
    @State private var changesOnLaunch: Bool

    /// `line`: what the field starts with (the screenshots' samples); by default the entry's proxy.
    init(proxies: ProxyListModel, entry: ProxyListEntry?, profileCount: Int, line: ProxyLine? = nil,
         onAdded: @escaping (UUID) -> Void = { _ in }) {
        _proxies = ObservedObject(wrappedValue: proxies)
        self.entry = entry
        self.profileCount = profileCount
        self.onAdded = onAdded
        _label = State(initialValue: entry?.label ?? "")
        _line = State(initialValue: line ?? entry.map { ProxyLine(proxy: $0.proxy, kindKnown: $0.kindKnown) } ?? ProxyLine())
        _changeLink = State(initialValue: entry?.changeIPURL?.absoluteString ?? "")
        _changesOnLaunch = State(initialValue: entry?.changesIPOnLaunch ?? false)
    }

    /// The link typed, or — the field empty — one pasted with the proxy (`[https://…]` after it).
    private var linkText: String {
        let typed = changeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if case .proxy(let read) = line.field, let link = read.changeIPURL { return link.absoluteString }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L(entry == nil ? "proxies.add.title" : "proxies.edit.title"),
                        subtitle: L(entry == nil ? "proxies.add.explanation" : "proxies.edit.explanation"))
            VStack(alignment: .leading, spacing: 14) {
                EditorField(L("proxies.edit.name")) {
                    TextField(L("proxies.edit.name"), text: $label, prompt: Text(verbatim: ""))
                        .lumenField(entry?.address ?? L("proxies.edit.name.placeholder"), isEmpty: label.isEmpty)
                }
                EditorField(L("proxies.edit.proxy")) {
                    ProxyLineField(line: $line, checking: checking, onCheck: check)
                }
                // Mobile proxies: the provider's link that gives the modem a new IP.
                EditorField(L("proxies.ipChange.link")) {
                    TextField(L("proxies.ipChange.link"), text: $changeLink, prompt: Text(verbatim: ""))
                        .lumenField(linkText.isEmpty ? L("proxies.ipChange.link.placeholder") : linkText, isEmpty: changeLink.isEmpty)
                        .autocorrectionDisabled()
                    // Where the link is opened from: this Mac's own connection, not the proxy.
                    Text(L("proxies.ipChange.link.note"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                EditorToggle(L("proxies.ipChange.onLaunch"), detail: L("proxies.ipChange.onLaunch.detail"), isOn: $changesOnLaunch)
                    .disabled(linkText.isEmpty)
                if profileCount > 0 {
                    Text(String(format: L("proxies.edit.profiles"), profileCount))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
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
            SheetFooter {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L(entry == nil ? "proxies.add.action" : "common.save"), action: save)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || proxies.loadError != nil)
            }
        }
        .sheetFrame(width: 560)
        .background(Theme.raised)
    }

    /// Check: the proxy the line names, on its own; what it finds goes to the list with Save.
    private func check() {
        guard !checking, let proxy = line.checkable else { return }
        checking = true
        Task {
            let result = await ProxyChecker.check(proxy)
            checking = false
            line.check = ProxyLine.Check(proxy: proxy, result: result)
        }
    }

    private func save() {
        guard !checking else { return }
        error = nil
        let proxy: ProxySettings
        var kindKnown = true
        var lineLabel = ""
        if case .proxy(let read) = line.field { lineLabel = read.label }
        switch line.reading {
        case .empty:
            error = L("editor.proxy.error.empty")
            return
        case .problem(let message):
            error = message
            return
        case .proxy(let read, _):
            proxy = read
        case .kindUnknown(let read):
            if let entry, entry.kindKnown {
                // Known before: profiles may use it. Never made unknown — checked first.
                guard let checkable = line.checkable else { return }
                checking = true
                Task {
                    let result = await ProxyChecker.check(checkable)
                    checking = false
                    line.check = ProxyLine.Check(proxy: checkable, result: result)
                    if case .kindUnknown = line.reading {
                        if line.currentCheck?.proxy == checkable { error = L("editor.proxy.error.kindNotFound") }
                        return
                    }
                    guard result.isAlive else {
                        error = L("editor.proxy.error.notWorking")
                        return
                    }
                    save()
                }
                return
            }
            proxy = read
            kindKnown = false
        }
        // The IP-change link, read before anything is saved: a link that is not one is said.
        let link: URL?
        if linkText.isEmpty {
            link = nil
        } else if let read = ProxyIPChange.link(from: linkText) {
            link = read
        } else {
            error = L("proxies.ipChange.badLink")
            return
        }
        // A check from here, of the proxy as it is now, is its last check.
        let check = line.currentCheck?.result
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lineLabel : label
        let id: UUID
        if let entry {
            if let problem = proxies.update(entry.id, label: name, proxy: proxy, kindKnown: kindKnown, check: check) {
                error = problem
                return
            }
            id = entry.id
        } else {
            switch proxies.addOne(label: name, proxy: proxy, kindKnown: kindKnown, check: check) {
            case .added(let added):
                id = added
                onAdded(added)
            case .failed(let problem):
                error = problem
                return
            }
        }
        if let problem = proxies.setIPChange(id, link: link, onLaunch: changesOnLaunch) {
            error = problem
            return
        }
        dismiss()
    }
}

// MARK: - Export

/// Writes proxies of the list to a text file, one per line, as Import reads them back — with the
/// user names and passwords in plaintext, which the sheet says before anything is written. The
/// file is its owner's alone (0600).
struct ProxyExportView: View {
    @ObservedObject var proxies: ProxyListModel
    let selection: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    @State private var onlySelected: Bool
    @State private var saved: URL?
    @State private var error: String?

    init(proxies: ProxyListModel, selection: Set<UUID>) {
        _proxies = ObservedObject(wrappedValue: proxies)
        self.selection = selection
        _onlySelected = State(initialValue: !selection.isEmpty)
    }

    private var count: Int { onlySelected ? selection.count : proxies.entries.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("proxies.export.title"), subtitle: L("proxies.export.explanation"))
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text(L("proxies.export.warning"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.warning.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1))
                if !selection.isEmpty {
                    // The design's segmented choice, not the system's radio buttons (drawn in the
                    // app's white tint, their chosen dot white on white).
                    LumenSegmented(selection: $onlySelected,
                                   options: [(value: true, title: String(format: L("proxies.export.selected"), selection.count)),
                                             (value: false, title: String(format: L("proxies.export.all"), proxies.entries.count))])
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(L("proxies.export.which"))
                        .disabled(saved != nil)
                }
                if let saved {
                    Label(String(format: L("proxies.export.done"), saved.lastPathComponent), systemImage: "checkmark.circle")
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.running)
                }
                if let error {
                    Text(error).font(.lumenSecondary).foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            SheetFooter {
                Button(L(saved == nil ? "common.cancel" : "common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                if saved == nil {
                    Button(String(format: L("proxies.export.action"), count), action: export)
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(count == 0)
                }
            }
        }
        .sheetFrame(width: 500)
        .background(Theme.raised)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("proxies.export.fileName") + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        let text = proxies.exportText(onlySelected ? selection : nil)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try SecureFile.writeOwnerOnly(Data(text.utf8), over: url)
            saved = url
        } catch {
            self.error = String(format: L("proxies.export.failed"), errorText(error))
        }
    }
}
