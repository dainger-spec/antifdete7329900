import BrowserCore
import SwiftUI

/// The proxy list (Profiles window → ⋯ → Proxies…): the proxies kept at hand, encrypted in the
/// vault, with what their last check found — alive or not, the exit country and IP, the latency.
/// Import adds a pasted list; Check checks the selection (or all) through each proxy itself;
/// Assign gives the selected proxies to profiles, in turn; Delete removes them from the list
/// (profiles that were given one keep it).
struct ProxyListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let proxies = model.proxyList {
            ProxyListPanel(proxies: proxies)
        }
    }
}

/// The sheet's body over a list model (rendered with a sample list by `--render-ui-snapshots`).
struct ProxyListPanel: View {
    @ObservedObject var proxies: ProxyListModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []
    @State private var search = ""
    @State private var importing = false
    @State private var assigning: ProxyAssignView.Request?
    @State private var confirmingDelete = false
    @State private var renaming: UUID?
    @State private var newLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("proxies.title"), subtitle: L("proxies.explanation"))
            toolbar
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
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
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity)
            SheetFooter(leading: { footerStatus }, buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .frame(width: 860, height: 620)
        .background(Theme.raised)
        .sheet(isPresented: $importing) {
            ProxyImportView(proxies: proxies) { added in selection = Set(added) }
        }
        .sheet(item: $assigning) { request in ProxyAssignView(request: request) }
        .confirmationDialog(String(format: L("proxies.delete.title"), selectedVisible.count), isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button(L("proxies.delete.confirm"), role: .destructive) {
                proxies.remove(selectedVisible)
                selection = []
            }
        } message: {
            Text(L("proxies.delete.message"))
        }
        .alert(L("proxies.rename.title"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("proxies.rename.field"), text: $newLabel)
            Button(L("common.save")) {
                if let renaming { proxies.rename(renaming, to: newLabel) }
                renaming = nil
            }
            Button(L("common.cancel"), role: .cancel) { renaming = nil }
        } message: {
            Text(L("proxies.rename.message"))
        }
    }

    // MARK: What is shown

    private var visible: [ProxyListEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return proxies.entries }
        return proxies.entries.filter { entry in
            [entry.label, entry.address, entry.proxy.username ?? "", entry.lastCheck?.exitIP ?? "",
             entry.lastCheck?.countryCode.map(CountryNames.name(for:)) ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// The selected proxies the list shows: what Check, Assign and Delete act on (a proxy the
    /// search hides is never acted on unseen).
    private var selectedVisible: Set<UUID> {
        selection.intersection(visible.map(\.id))
    }

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
            Button(role: .destructive) { confirmingDelete = true } label: { Label(L("proxies.delete"), systemImage: "trash") }
                .buttonStyle(.lumenDestructive)
                .disabled(selectedVisible.isEmpty)
            Spacer(minLength: 12)
            LumenSearchField(text: $search, prompt: L("proxies.search"))
                .frame(width: 170)
        }
    }

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
            VStack(alignment: .leading, spacing: 6) {
                ProxyColumnHeader()
                List(selection: $selection) {
                    ForEach(visible) { entry in
                        ProxyRow(entry: entry, checking: proxies.checking.contains(entry.id))
                            .tag(entry.id)
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
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        Button(L("proxies.menu.check")) { proxies.check(ids) }
            .disabled(proxies.isChecking)
        if ids.count == 1, let id = ids.first {
            Button(L("proxies.menu.rename")) {
                newLabel = proxies.list.entry(id)?.label ?? ""
                renaming = id
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

    @ViewBuilder
    private var footerStatus: some View {
        if proxies.isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(format: L("proxies.checking.progress"), proxies.checkedCount, proxies.checkTotal))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        } else if !proxies.entries.isEmpty {
            let checked = proxies.entries.compactMap(\.lastCheck)
            Text(String(format: L("proxies.summary"), proxies.entries.count, checked.filter(\.isAlive).count,
                        checked.filter { !$0.isAlive }.count))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - Rows

/// Column widths of the proxy list (the name takes what is left).
private enum ProxyColumns {
    static let status: CGFloat = 16
    static let exit: CGFloat = 150
    static let ip: CGFloat = 124
    static let latency: CGFloat = 64
    static let checked: CGFloat = 104
    static let gap: CGFloat = 12
}

private struct ProxyColumnHeader: View {
    var body: some View {
        HStack(spacing: ProxyColumns.gap) {
            Color.clear.frame(width: ProxyColumns.status, height: 1)
            Text(L("proxies.column.proxy")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("proxies.column.exit")).frame(width: ProxyColumns.exit, alignment: .leading)
            Text(L("proxies.column.ip")).frame(width: ProxyColumns.ip, alignment: .leading)
            Text(L("proxies.column.latency")).frame(width: ProxyColumns.latency, alignment: .trailing)
            Text(L("proxies.column.checked")).frame(width: ProxyColumns.checked, alignment: .leading)
        }
        .font(.lumenColumn)
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        // The list's own row inset, so the titles stand over their columns.
        .padding(.horizontal, 18)
    }
}

private struct ProxyRow: View {
    let entry: ProxyListEntry
    let checking: Bool

    var body: some View {
        HStack(spacing: ProxyColumns.gap) {
            ProxyStatusDot(check: entry.lastCheck, checking: checking)
                .frame(width: ProxyColumns.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.detailLine)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ProxyExitLabel(check: entry.lastCheck, checking: checking)
                .frame(width: ProxyColumns.exit, alignment: .leading)
            Text(entry.lastCheck?.exitIP ?? "")
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: ProxyColumns.ip, alignment: .leading)
            Text(ProxyCheckText.latency(entry.lastCheck))
                .font(.lumenBody)
                .foregroundStyle(ProxyCheckText.isSlow(entry.lastCheck) ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: ProxyColumns.latency, alignment: .trailing)
            Text(entry.lastCheck.map { $0.checkedAt.formatted(.relative(presentation: .named)) } ?? "")
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: ProxyColumns.checked, alignment: .leading)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Alive (green), dead (red), not checked yet (gray), or a spinner while it is being checked.
struct ProxyStatusDot: View {
    let check: ProxyCheckResult?
    let checking: Bool

    var body: some View {
        ZStack {
            if checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
        .help(ProxyCheckText.status(check, checking: checking))
        .accessibilityLabel(ProxyCheckText.status(check, checking: checking))
    }

    private var color: Color {
        guard let check else { return Theme.textDisabled }
        return check.isAlive ? Theme.running : Theme.danger
    }
}

/// Where the proxy exits, as its last check found: the country with its flag; why it is dead; or
/// that it has not been checked.
struct ProxyExitLabel: View {
    let check: ProxyCheckResult?
    var checking = false

    var body: some View {
        HStack(spacing: 8) {
            if checking {
                Text(L("proxies.status.checking")).foregroundStyle(Theme.textSecondary)
            } else if let check, let failure = check.failure {
                Text(ProxyCheckText.failure(failure)).foregroundStyle(Theme.danger)
            } else if let check, let code = check.countryCode {
                CountryFlag(code: code, size: 14)
                Text(CountryNames.name(for: code)).foregroundStyle(Theme.textPrimary)
            } else if check != nil {
                Text(L("proxies.status.alive")).foregroundStyle(Theme.textPrimary)
            } else {
                Text(L("proxies.status.unchecked")).foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.lumenBody)
        .lineLimit(1)
    }
}

// MARK: - Wording

extension ProxyListEntry {
    /// "SOCKS5", "HTTP", or "HTTPS" for TLS to the proxy.
    var kindName: String {
        switch proxy.kind {
        case .socks5: return "SOCKS5"
        case .httpConnect: return proxy.tlsToProxy ? "HTTPS" : "HTTP"
        }
    }

    /// The line under the name: the address (when a label is the name), the kind, the user name.
    var detailLine: String {
        var parts: [String] = []
        if !label.isEmpty { parts.append(address) }
        parts.append(kindName)
        if let user = proxy.username, !user.isEmpty { parts.append(user) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum ProxyCheckText {
    static func failure(_ failure: ProxyCheckResult.Failure) -> String {
        switch failure {
        case .noAnswer: return L("proxies.status.noAnswer")
        case .needsCredentials: return L("proxies.status.needsCredentials")
        case .invalidSettings: return L("proxies.status.invalid")
        }
    }

    static func status(_ check: ProxyCheckResult?, checking: Bool) -> String {
        if checking { return L("proxies.status.checking") }
        guard let check else { return L("proxies.status.unchecked") }
        return check.failure.map(Self.failure) ?? L("proxies.status.alive")
    }

    /// "120 ms"; empty without one.
    static func latency(_ check: ProxyCheckResult?) -> String {
        check?.latencyMilliseconds.map { String(format: L("proxies.latency"), $0) } ?? ""
    }

    /// Slower than a page should wait for its first byte.
    static func isSlow(_ check: ProxyCheckResult?) -> Bool {
        (check?.latencyMilliseconds ?? 0) >= 1500
    }

    /// One line for a menu item (which shows text only): the flag, the name, the address and how
    /// the last check went.
    static func menuTitle(_ entry: ProxyListEntry) -> String {
        var title = entry.displayName
        if !entry.label.isEmpty { title += " — " + entry.address }
        guard let check = entry.lastCheck else { return title }
        if let failure = check.failure { return title + " · " + Self.failure(failure) }
        if let code = check.countryCode, let flag = CountryFlag.emoji(for: code) { title = flag + " " + title }
        if let latency = check.latencyMilliseconds { title += " · " + String(format: L("proxies.latency"), latency) }
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
