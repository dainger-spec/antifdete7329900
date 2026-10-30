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

    var body: some View {
        if let proxies = model.proxyList {
            ProxyListPanel(proxies: proxies, profileCounts: model.proxyUseCounts, selection: $selection)
        }
    }
}

/// The section's body over a list model (rendered with a sample list by `--render-ui-snapshots`).
struct ProxyListPanel: View {
    @ObservedObject var proxies: ProxyListModel
    /// How many profiles use each proxy, by `ProxyList.identity(of:)`.
    var profileCounts: [String: Int] = [:]
    @Binding var selection: Set<UUID>

    @State private var search = ""
    @State private var adding = false
    @State private var importing = false
    @State private var exporting = false
    @State private var assigning: ProxyAssignView.Request?
    @State private var editing: ProxyListEntry?
    @State private var confirmingDelete = false
    /// The selected proxy's report, measured: its pane is as tall as the report, up to half of what
    /// the section has under its toolbar, and scrolls beyond that.
    @State private var reportHeight: CGFloat = 210

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            toolbar
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            if let loadError = proxies.loadError {
                Label(String(format: L("proxies.error.loadDetail"), loadError), systemImage: "exclamationmark.triangle.fill")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            content
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity)
            // One proxy selected: its last check. Nothing selected, or several: no pane, rather than
            // half a window saying to select one.
            if let entry = single {
                reportPane(entry)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
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

    /// The one selected proxy, for Edit and the report.
    private var single: ProxyListEntry? {
        guard selectedVisible.count == 1, let id = selectedVisible.first else { return nil }
        return proxies.list.entry(id)
    }

    /// With nothing of the list selected, its first proxy: the report shows a check at once.
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

    // MARK: The header and the toolbar

    /// The window's header band, as the profiles have theirs: the title and how the list stands,
    /// the search, the rarer actions (⋯) and Add.
    private var header: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    title
                    Text(summary)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                title
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if proxies.isChecking {
                ProgressView().controlSize(.small).transition(.opacity)
            }
            LumenSearchField(text: $search, prompt: L("proxies.search"))
                .frame(width: 200)
            moreMenu
            Button { adding = true } label: { Label(L("proxies.add"), systemImage: "plus") }
                .buttonStyle(.lumenPrimary)
                .disabled(proxies.loadError != nil)
                .help(L("proxies.add.help"))
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 52)
        .animation(Theme.hoverAnimation, value: proxies.isChecking)
    }

    private var title: some View {
        Text(L("proxies.title"))
            .font(.lumenTitle)
            .kerning(-0.2)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize()
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

    /// Edit, Export and Delete: each also in a proxy's own menu (a right click), and Delete on the
    /// Delete key.
    private var moreMenu: some View {
        Menu {
            Button(L("proxies.edit")) { editing = single }
                .disabled(single == nil || proxies.loadError != nil)
            Button(L("proxies.export")) { exporting = true }
                .disabled(proxies.entries.isEmpty)
            Divider()
            Button(L("proxies.delete"), role: .destructive) { confirmingDelete = true }
                .disabled(selectedVisible.isEmpty)
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
    }

    /// What is done to the list most: no wider than the narrowest window has room for.
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { importing = true } label: { Label(L("proxies.import"), systemImage: "square.and.arrow.down") }
                .buttonStyle(.lumenSecondary)
                .disabled(proxies.loadError != nil)
            if proxies.isChecking {
                Button { proxies.stopChecking() } label: { Label(L("proxies.check.stop"), systemImage: "stop.circle") }
                    .buttonStyle(.lumenSecondary)
            } else {
                Button {
                    proxies.check(selectedVisible.isEmpty ? nil : selectedVisible)
                } label: {
                    Label(selectedVisible.isEmpty ? L("proxies.check.all") : L("proxies.check.selected"), systemImage: "checkmark.shield")
                }
                .buttonStyle(.lumenSecondary)
                .disabled(proxies.entries.isEmpty)
                .help(L("proxies.check.help"))
            }
            Button {
                assigning = ProxyAssignView.Request(profileIDs: [], proxyIDs: selectedVisible)
            } label: {
                Label(L("proxies.assign"), systemImage: "person.2")
            }
            .buttonStyle(.lumenSecondary)
            .disabled(proxies.entries.isEmpty)
            Spacer(minLength: 0)
        }
    }

    // MARK: The list and the report

    @ViewBuilder
    private var content: some View {
        if proxies.entries.isEmpty {
            VStack(spacing: 14) {
                LumenEmptyHint(symbol: "network", text: L("proxies.empty"))
                    .frame(maxHeight: 160)
                Button { importing = true } label: { Label(L("proxies.import"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(.lumenPrimary)
                    .disabled(proxies.loadError != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card(fill: Theme.raisedInset)
        } else {
            GeometryReader { geometry in
                let columns = ProxyColumns(contentWidth: geometry.size.width)
                VStack(alignment: .leading, spacing: 6) {
                    ProxyColumnHeader(columns: columns)
                    ScrollViewReader { scroller in
                        List(selection: $selection) {
                            ForEach(visible) { entry in
                                ProxyRow(entry: entry, checking: proxies.checking.contains(entry.id), profiles: profileCount(entry),
                                         columns: columns)
                                    .tag(entry.id)
                                    .id(entry.id)
                            }
                        }
                        .overlay {
                            if visible.isEmpty {
                                Text(L("proxies.noMatches")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .background(Theme.raisedInset)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
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

    /// The selected proxy's last check, step by step, with what to do about it.
    private func reportPane(_ entry: ProxyListEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entry.lastCheck == nil, !proxies.checking.contains(entry.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.displayName).font(.lumenSection).foregroundStyle(Theme.textPrimary)
                        Text(entry.kindKnown ? L("proxies.report.unchecked") : L("proxies.type.unknown.help"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProxyReportView(report: ProxyReport(proxy: entry.proxy, check: entry.lastCheck,
                                                        checking: proxies.checking.contains(entry.id)),
                                    checkedAt: proxies.checking.contains(entry.id) ? nil : entry.lastCheck?.checkedAt)
                }
                Text(entry.originLine)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { reportHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in reportHeight = height }
            })
        }
        // The stack gives the pane, the less flexible of the two, up to half of the room first; the
        // list takes the rest. A short report keeps its pane short.
        .frame(minHeight: min(reportHeight, 150), maxHeight: reportHeight)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.raisedInset))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        Button(L("proxies.menu.check")) { proxies.check(ids) }
            .disabled(proxies.isChecking)
        if ids.count == 1, let id = ids.first {
            Button(L("proxies.menu.edit")) { editing = proxies.list.entry(id) }
                .disabled(proxies.loadError != nil)
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
}

// MARK: - Rows

/// Column widths of the proxy list, and which optional columns fit (the name takes what is
/// left): below these widths the list drops the exit IP, then when it was checked, as the
/// profiles' table drops its own optional columns.
struct ProxyColumns {
    static let status: CGFloat = 18
    // Wide enough for "Неизвестен" and for a country with its city ("Нидерланды, Amsterdam"); a
    // longer place is cut and shown whole in its tooltip.
    static let kind: CGFloat = 84
    static let exit: CGFloat = 196
    static let ip: CGFloat = 118
    static let latency: CGFloat = 58
    static let checked: CGFloat = 92
    static let profiles: CGFloat = 56
    static let gap: CGFloat = 10
    static let minimumName: CGFloat = 150
    /// The list's own row inset, on both sides.
    static let inset: CGFloat = 18

    let showsIP: Bool
    let showsChecked: Bool

    init(contentWidth: CGFloat) {
        let fixed = 2 * Self.inset + Self.status + Self.kind + Self.exit + Self.latency + Self.profiles + 5 * Self.gap + Self.minimumName
        showsChecked = contentWidth >= fixed + Self.checked + Self.gap
        showsIP = contentWidth >= fixed + Self.checked + Self.ip + 2 * Self.gap
    }
}

private struct ProxyColumnHeader: View {
    let columns: ProxyColumns

    var body: some View {
        HStack(spacing: ProxyColumns.gap) {
            Color.clear.frame(width: ProxyColumns.status, height: 1)
            Text(L("proxies.column.proxy")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("proxies.column.type")).frame(width: ProxyColumns.kind, alignment: .leading)
            Text(L("proxies.column.exit")).frame(width: ProxyColumns.exit, alignment: .leading)
            if columns.showsIP {
                Text(L("proxies.column.ip")).frame(width: ProxyColumns.ip, alignment: .leading)
            }
            Text(L("proxies.column.latency")).frame(width: ProxyColumns.latency, alignment: .trailing)
            if columns.showsChecked {
                Text(L("proxies.column.checked")).frame(width: ProxyColumns.checked, alignment: .leading)
            }
            Text(L("proxies.column.profiles")).frame(width: ProxyColumns.profiles, alignment: .trailing)
        }
        .font(.lumenColumn)
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        // The list's own row inset, so the titles stand over their columns.
        .padding(.horizontal, ProxyColumns.inset)
    }
}

private struct ProxyRow: View {
    let entry: ProxyListEntry
    let checking: Bool
    let profiles: Int
    let columns: ProxyColumns

    var body: some View {
        HStack(spacing: ProxyColumns.gap) {
            ProxyStatusIcon(state: entry.state(checking: checking))
                .frame(width: ProxyColumns.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.detailLine.isEmpty {
                    Text(entry.detailLine)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.kindKnown ? entry.kindName : L("proxies.type.unknown"))
                .font(.lumenBody)
                .foregroundStyle(entry.kindKnown ? Theme.textSecondary : Theme.textTertiary)
                .lineLimit(1)
                .frame(width: ProxyColumns.kind, alignment: .leading)
                .help(entry.kindKnown ? "" : L("proxies.type.unknown.help"))
            ProxyExitLabel(check: entry.lastCheck, checking: checking, showsCity: true)
                .frame(width: ProxyColumns.exit, alignment: .leading)
            if columns.showsIP {
                Text(entry.lastCheck?.isAlive == true ? (entry.lastCheck?.exitIP ?? "") : "")
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: ProxyColumns.ip, alignment: .leading)
            }
            Text(ProxyCheckText.latency(entry.lastCheck))
                .font(.lumenBody)
                .foregroundStyle(ProxyCheckText.isSlow(entry.lastCheck) ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: ProxyColumns.latency, alignment: .trailing)
            if columns.showsChecked {
                Text(entry.lastCheck.map { $0.checkedAt.formatted(.relative(presentation: .named)) } ?? "")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(width: ProxyColumns.checked, alignment: .leading)
            }
            Text(profiles.formatted())
                .font(.lumenBody)
                .foregroundStyle(profiles > 0 ? Theme.textSecondary : Theme.textTertiary)
                .monospacedDigit()
                .frame(width: ProxyColumns.profiles, alignment: .trailing)
                .help(String(format: L("proxies.profiles.help"), profiles))
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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
        let date = addedAt.timeIntervalSince1970 > 0 ? addedAt.formatted(date: .long, time: .omitted) : nil
        switch origin {
        case .user: return date.map { String(format: L("proxies.origin.user.since"), $0) } ?? L("proxies.origin.user")
        case .service: return date.map { String(format: L("proxies.origin.service.since"), $0) } ?? L("proxies.origin.service")
        }
    }
}

@MainActor
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

    /// `line`: what the field starts with (the screenshots' samples); by default the entry's proxy.
    init(proxies: ProxyListModel, entry: ProxyListEntry?, profileCount: Int, line: ProxyLine? = nil,
         onAdded: @escaping (UUID) -> Void = { _ in }) {
        _proxies = ObservedObject(wrappedValue: proxies)
        self.entry = entry
        self.profileCount = profileCount
        self.onAdded = onAdded
        _label = State(initialValue: entry?.label ?? "")
        _line = State(initialValue: line ?? entry.map { ProxyLine(proxy: $0.proxy, kindKnown: $0.kindKnown) } ?? ProxyLine())
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
        // A check from here, of the proxy as it is now, is its last check.
        let check = line.currentCheck?.result
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lineLabel : label
        if let entry {
            if let problem = proxies.update(entry.id, label: name, proxy: proxy, kindKnown: kindKnown, check: check) {
                error = problem
                return
            }
        } else {
            switch proxies.addOne(label: name, proxy: proxy, kindKnown: kindKnown, check: check) {
            case .added(let id): onAdded(id)
            case .failed(let problem):
                error = problem
                return
            }
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
                    Picker(L("proxies.export.which"), selection: $onlySelected) {
                        Text(String(format: L("proxies.export.selected"), selection.count)).tag(true)
                        Text(String(format: L("proxies.export.all"), proxies.entries.count)).tag(false)
                    }
                    .pickerStyle(.radioGroup)
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
            self.error = String(format: L("proxies.export.failed"), (error as? CoreError)?.description ?? error.localizedDescription)
        }
    }
}
