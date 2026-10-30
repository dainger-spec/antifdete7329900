import BrowserCore
import SwiftUI

/// The profile editor's body: a header with the profile's glyph and where it exits, one screen of
/// every setting in parts — an index of them on the left jumps to one — and a footer with Cancel
/// and Save. Pure presentation over a `ProfileDraft` binding, so it can be rendered with sample
/// data (`--render-ui-snapshots`).
struct ProfileEditorForm: View {
    /// The editor's parts, in the order the screen shows them.
    enum Topic: String, CaseIterable, Identifiable {
        case profile, connection, identity, location, privacy, data
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .profile: return "editor.topic.profile"
            case .connection: return "editor.topic.connection"
            case .identity: return "editor.topic.identity"
            case .location: return "editor.topic.location"
            case .privacy: return "editor.topic.privacy"
            case .data: return "editor.topic.data"
            }
        }

        var symbol: String {
            switch self {
            case .profile: return "person.crop.square"
            case .connection: return "network"
            case .identity: return "safari"
            case .location: return "location"
            case .privacy: return "hand.raised"
            case .data: return "externaldrive"
            }
        }
    }

    @Binding var draft: ProfileDraft
    /// The part the index marks, and the one the screen opens on.
    @Binding var topic: Topic
    var isNew: Bool
    /// Keeps the glyph's colour the same as in the Profiles list.
    var avatarID: UUID
    var error: String?
    /// The network extension can carry WebRTC through a SOCKS5 proxy (TunnelManager).
    var tunnelCarriesWebRTC: Bool
    var onCancel: () -> Void = {}
    var onSave: () -> Void = {}
    var onTunnelSettings: () -> Void = {}
    /// The proxy list, for "From the list"; proxies whose type no check has found yet cannot be
    /// chosen (they are given to no profile).
    var savedProxies: [ProxyListEntry] = []
    /// A check run from the editor (Check, or Save finding a type) is under way.
    var checkingProxy = false
    var onCheckProxy: () -> Void = {}
    /// The tags of the other profiles, offered under the tag field.
    var knownTags: [String] = []

    static let size = CGSize(width: 760, height: 660)
    static let indexWidth: CGFloat = 172

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollViewReader { scroller in
                HStack(spacing: 0) {
                    index(scroller)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            ForEach(Topic.allCases) { part in
                                section(part).id(part)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        guard topic != .profile else { return }
                        DispatchQueue.main.async { scroller.scrollTo(topic, anchor: .top) }
                    }
                }
            }
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.raised)
        .tint(Theme.accentFill)
    }

    // MARK: The index and the parts

    private func index(_ scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Topic.allCases) { part in
                let selected = topic == part
                Button {
                    topic = part
                    withAnimation(Theme.appearAnimation) { scroller.scrollTo(part, anchor: .top) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: part.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                            .frame(width: 16)
                        Text(L(part.titleKey))
                            .font(.system(size: 13, weight: selected ? .medium : .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: Self.indexWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    private func section(_ part: Topic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L(part.titleKey))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            sectionContent(part)
        }
    }

    @ViewBuilder
    private func sectionContent(_ part: Topic) -> some View {
        switch part {
        case .profile: profile
        case .connection: connection
        case .identity: identity
        case .location: location
        case .privacy: privacy
        case .data: data
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            ProfileAvatar(name: draft.name.isEmpty ? "?" : draft.name, id: avatarID, size: 36, style: draft.avatarStyle)
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? L("editor.title.new") : (draft.name.isEmpty ? L("editor.title.edit") : draft.name))
                    .font(.lumenSheetTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 6) {
            if draft.hasProxy, let location = draft.knownProxyLocation, let code = location.countryCode {
                CountryFlag(code: code, size: 12)
                Text(verbatim: "\(CountryNames.name(for: code)) · \(location.timeZoneIdentifier)")
            } else if draft.hasProxy {
                Image(systemName: "network").font(.system(size: 11))
                Text(L("editor.subtitle.proxy"))
            } else if isNew {
                Text(L("editor.subtitle.new"))
            } else {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
                Text(L("editor.subtitle.direct"))
            }
        }
        .font(.lumenSecondary)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 8) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if checkingProxy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("editor.footer.checking"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text(L("editor.footer.note"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 12)
                Button(L("common.cancel"), action: onCancel)
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save"), action: onSave)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checkingProxy)
            }
            .padding(.horizontal, 24)
            .frame(height: 60)
        }
    }

    // MARK: Profile

    private var profile: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorField(L("editor.name")) {
                TextField(L("editor.name"), text: $draft.name, prompt: Text(verbatim: "")).lumenField()
            }
            EditorField(L("editor.avatar")) {
                AvatarChoice(draft: $draft, avatarID: avatarID)
            }
            EditorField(L("editor.tags")) {
                TagEditor(tags: $draft.tags, suggestions: knownTags)
            }
            EditorField(L("editor.notes")) {
                TextField(L("editor.notes"), text: $draft.notes, prompt: Text(verbatim: ""), axis: .vertical)
                    .lineLimit(3...8)
                    .lumenField(L("editor.notes.placeholder"), isEmpty: draft.notes.isEmpty, height: nil)
            }
            EditorNote(L("editor.labels.note"))
            EditorDivider()
            EditorField(L("editor.startURL")) {
                TextField(L("editor.startURL"), text: $draft.startURL, prompt: Text(verbatim: ""))
                    .lumenField("https://example.com", isEmpty: draft.startURL.isEmpty)
            }
            EditorRow(L("editor.search")) {
                Picker(L("editor.search"), selection: $draft.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            EditorNote(L("editor.search.note"))
            EditorDivider()
            EditorToggle(L("editor.ephemeral.title"), detail: L("editor.ephemeral.detail"), isOn: $draft.ephemeral)
        }
    }

    // MARK: Identity

    private var identity: some View {
        let generation = DeviceGenerations.resolved(id: draft.deviceGenerationID)
        return VStack(alignment: .leading, spacing: 14) {
            EditorRow(L("editor.generation")) {
                Picker(L("editor.generation"), selection: $draft.deviceGenerationID) {
                    ForEach(DeviceGenerations.all) { Text(L($0.nameKey)).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if !generation.matchesEngine {
                EditorNote(L("editor.generation.inconsistent"), tone: .warning)
            }
            EditorDivider()
            EditorToggle(L("editor.ua.useCustom"), isOn: $draft.customUserAgent)
            if draft.customUserAgent {
                EditorField(L("editor.ua.field")) {
                    TextField(L("editor.ua.field"), text: $draft.userAgent, prompt: Text(verbatim: ""), axis: .vertical)
                        .lineLimit(2...4)
                        .lumenField("Mozilla/5.0 (…)", isEmpty: draft.userAgent.isEmpty, height: nil)
                }
            } else {
                EditorField(L("editor.ua.effective")) {
                    Text(generation.userAgent(hostSafariVersion: HostSafari.version))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
                }
            }
            EditorNote(L("editor.generation.footer"))
        }
    }

    /// With a proxy, WebRTC can only be on through the network extension's relay, and only for
    /// SOCKS5 (a proxy whose type is not known yet is not taken for one).
    private var webRTCLocked: Bool {
        draft.hasProxy && !(draft.chosenProxy?.kind == .socks5 && tunnelCarriesWebRTC)
    }

    // MARK: Connection

    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorField(L("editor.proxy.connection")) {
                Picker(L("editor.proxy.connection"), selection: $draft.proxyMode) {
                    ForEach(ProfileDraft.ProxyMode.allCases) { Text(L($0.labelKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
            switch draft.proxyMode {
            case .direct:
                EditorNote(L("editor.proxy.none.note"))
            case .saved:
                savedProxyChoice
            case .new:
                EditorField(L("proxyLine.field")) {
                    ProxyLineField(line: $draft.proxyLine, checking: checkingProxy, onCheck: onCheckProxy)
                }
                EditorNote(L("editor.proxy.new.note"))
            }
            if draft.hasProxy {
                EditorField(L("editor.proxy.bypass")) {
                    TextField(L("editor.proxy.bypass"), text: $draft.proxyExcludedDomains, prompt: Text(verbatim: ""))
                        .lumenField("localhost, example.com", isEmpty: draft.proxyExcludedDomains.isEmpty)
                }
                ProxyLocationCard(draft: $draft)
                if draft.matchProxyLocation && !draft.overrideTimeZone {
                    EditorNote(L("editor.tz.fromProxy.note"))
                }
                EditorToggle(L("editor.proxy.warnIPChange"), detail: L("editor.proxy.warnIPChange.note"),
                             isOn: $draft.warnOnProxyIPChange)
            }
            EditorDivider()
            EditorRow(L("editor.webrtc")) {
                // The stored choice is kept while the proxy rules it out (ProfileConfiguration.webRTCRouting).
                Picker(L("editor.webrtc"), selection: webRTCLocked ? .constant(WebRTCPolicy.disabled) : $draft.webRTC) {
                    Text(L("editor.webrtc.disabled")).tag(WebRTCPolicy.disabled)
                    Text(L("editor.webrtc.relay")).tag(WebRTCPolicy.relayOnly)
                    Text(L("editor.webrtc.unrestricted")).tag(WebRTCPolicy.unrestricted)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(webRTCLocked)
            }
            // Said for a proxy whose type is known; without one WebRTC stays off.
            if draft.hasProxy, let kind = draft.chosenProxy?.kind {
                if kind != .socks5 {
                    EditorNote(L("editor.webrtc.httpProxy"))
                } else if tunnelCarriesWebRTC {
                    EditorNote(L("editor.webrtc.viaTunnel"))
                } else {
                    EditorNote(L("editor.webrtc.tunnelOff"), tone: .warning)
                    Button(L("editor.webrtc.tunnelSettings"), action: onTunnelSettings)
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.accent)
                }
            }
            EditorNote(L("editor.network.footer"))
        }
    }

    // MARK: Location and language

    private var location: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorRow(L("editor.geo")) {
                Picker(L("editor.geo"), selection: $draft.geoMode) {
                    ForEach(ProfileDraft.GeoMode.allCases) { Text(L($0.labelKey)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if draft.geoMode == .fixed {
                HStack(alignment: .top, spacing: 12) {
                    EditorField(L("editor.geo.lat")) { TextField(L("editor.geo.lat"), text: $draft.latitude, prompt: Text(verbatim: "")).lumenField("52.52", isEmpty: draft.latitude.isEmpty) }
                    EditorField(L("editor.geo.lon")) { TextField(L("editor.geo.lon"), text: $draft.longitude, prompt: Text(verbatim: "")).lumenField("13.405", isEmpty: draft.longitude.isEmpty) }
                    EditorField(L("editor.geo.accuracy")) { TextField(L("editor.geo.accuracy"), text: $draft.accuracy, prompt: Text(verbatim: "")).lumenField("50", isEmpty: draft.accuracy.isEmpty) }
                        .frame(width: 120)
                }
            }
            EditorDivider()
            EditorToggle(L("editor.tz.override"), isOn: $draft.overrideTimeZone)
            if draft.overrideTimeZone {
                EditorRow(L("editor.tz")) {
                    Picker(L("editor.tz"), selection: $draft.timeZone) {
                        ForEach(ProfileEditorForm.timeZones, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } else if draft.hasProxy {
                EditorNote(L("editor.tz.fromProxyHint"))
            }
            EditorNote(L("editor.location.footer"))
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorToggle(L("editor.safeBrowsing"), isOn: $draft.safeBrowsing)
            EditorNote(L("editor.privacy.footer"))
        }
    }

    static let timeZones = TimeZone.knownTimeZoneIdentifiers.sorted()

    /// "From the list": the list's proxies to choose one from, Check for the one chosen, and what
    /// its last check found.
    @ViewBuilder
    private var savedProxyChoice: some View {
        let usable = savedProxies.filter(\.kindKnown)
        if usable.isEmpty {
            EditorNote(L(savedProxies.isEmpty ? "editor.proxy.saved.empty" : "editor.proxy.saved.noneKnown"))
        } else {
            SavedProxyList(entries: usable, selection: Binding(
                get: { draft.savedProxy?.id },
                set: { id in if let entry = usable.first(where: { $0.id == id }) { draft.choose(entry) } }))
            if let chosen = draft.savedProxy.flatMap({ chosen in usable.first { $0.id == chosen.id } }) {
                HStack(spacing: 8) {
                    Text(String(format: L("editor.proxy.saved.chosen"), chosen.displayName))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(action: onCheckProxy) {
                        Label(L("proxyLine.check"), systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.lumenSecondary)
                    .disabled(checkingProxy)
                    .help(L("editor.proxy.saved.check.help"))
                }
                if checkingProxy {
                    ProxyLineCheckView(proxy: chosen.proxy, result: nil, checking: true)
                } else if let check = chosen.lastCheck {
                    ProxyLineCheckView(proxy: chosen.proxy, result: check)
                }
            } else if draft.savedProxy != nil {
                EditorNote(L("editor.proxy.saved.gone"), tone: .warning)
            }
            let hidden = savedProxies.count - usable.count
            if hidden > 0 {
                EditorNote(String(format: L("editor.proxy.saved.hidden"), hidden))
            }
        }
    }

    // MARK: Data

    private var data: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorGroupTitle(L("editor.section.history"))
            EditorToggle(L("editor.history.record"), isOn: $draft.historyEnabled)
            if draft.historyEnabled {
                EditorRow(L("editor.history.keep")) {
                    Picker(L("editor.history.keep"), selection: $draft.historyRetentionDays) {
                        ForEach(ProfileDraft.retentionChoices, id: \.days) { Text(L($0.labelKey)).tag($0.days) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            EditorNote(L("editor.history.footer"))
            EditorDivider()
            EditorGroupTitle(L("editor.section.passwords"))
            EditorToggle(L("editor.passwords.autoFill"), isOn: $draft.passwordAutoFill)
            EditorNote(L("editor.passwords.footer"))
            EditorDivider()
            EditorGroupTitle(L("editor.section.sync"))
            EditorToggle(L("editor.sync.cookies"), isOn: $draft.syncCookies)
                .disabled(draft.ephemeral)
            EditorNote(L(draft.ephemeral ? "editor.sync.footer.ephemeral" : "editor.sync.footer"))
        }
    }
}

// MARK: - The glyph and the tags

/// The glyph's colour — the one the profile's id gives, or one of the palette — and up to two
/// letters of its own instead of the name's first.
private struct AvatarChoice: View {
    @Binding var draft: ProfileDraft
    let avatarID: UUID

    var body: some View {
        HStack(spacing: 8) {
            swatch(nil)
            ForEach(0..<ProfileAvatarStyle.colorCount, id: \.self) { index in swatch(index) }
            Spacer(minLength: 16)
            TextField(L("editor.avatar.letters"), text: letters, prompt: Text(verbatim: ""))
                .lumenField(L("editor.avatar.letters"), isEmpty: draft.avatarLetters.isEmpty)
                .frame(width: 150)
        }
    }

    /// At most two characters, no spaces, as `ProfileAvatarStyle` keeps them.
    private var letters: Binding<String> {
        Binding(get: { draft.avatarLetters },
                set: { draft.avatarLetters = String($0.filter { !$0.isWhitespace }.prefix(ProfileAvatarStyle.maximumLetters)) })
    }

    private func swatch(_ index: Int?) -> some View {
        let colors = index.map { ProfileAvatar.palette[$0] } ?? ProfileAvatar.colors(for: avatarID)
        let selected = draft.avatarColor == index
        let label = index.map { String(format: L("editor.avatar.color"), $0 + 1) } ?? L("editor.avatar.automatic")
        return Button {
            draft.avatarColor = index
        } label: {
            ZStack {
                Circle().fill(Color(hex: colors.fill))
                if index == nil {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: colors.text))
                }
            }
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Tags as chips, each with a button that removes it, a field that adds what is typed (Return,
/// or a comma), and the other profiles' tags offered under it.
private struct TagEditor: View {
    @Binding var tags: [String]
    var suggestions: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(text: tag) { tags.removeAll { $0 == tag } }
                    }
                }
            }
            TextField(L("editor.tags"), text: $text, prompt: Text(verbatim: ""))
                .lumenField(L("editor.tags.placeholder"), isEmpty: text.isEmpty)
                .onSubmit(add)
                .onChange(of: text) { _, typed in
                    if typed.contains(",") { add() }
                }
                .disabled(tags.count >= ProfileTags.maximumCount)
            let offered = suggestions.filter { !ProfileTags.contains(tags, $0) }
            if !offered.isEmpty && tags.count < ProfileTags.maximumCount {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("editor.tags.suggestions"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(offered.prefix(12), id: \.self) { tag in
                            Button { tags = ProfileTags.normalized(tags + [tag]) } label: {
                                TagChip(text: tag)
                            }
                            .buttonStyle(.plain)
                            .help(String(format: L("editor.tags.addSuggested"), tag))
                        }
                    }
                }
            }
        }
    }

    /// What is typed, split at commas, added after the tags there are (each once).
    private func add() {
        let added = ProfileTags.parse(text)
        text = ""
        guard !added.isEmpty else { return }
        tags = ProfileTags.normalized(tags + added)
    }
}

// MARK: - Proxies of the list

/// The list's proxies to choose one from, the ones that answered first (fastest first), each with
/// what its last check found: its state, where it exits, its type and how slow it is.
private struct SavedProxyList: View {
    let entries: [ProxyListEntry]
    @Binding var selection: UUID?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entries.count > 6 {
                LumenSearchField(text: $search, prompt: L("editor.proxy.saved.search"))
            }
            ScrollViewReader { scroller in
                List(selection: $selection) {
                    ForEach(visible) { entry in
                        SavedProxyRow(entry: entry)
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .frame(height: 196)
                .onAppear {
                    if let selection { scroller.scrollTo(selection, anchor: .center) }
                }
            }
        }
    }

    private var visible: [ProxyListEntry] {
        let ordered = ProxyCheckText.pickingOrder(entries)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { entry in
            [entry.label, entry.address, entry.proxy.username ?? "", entry.lastCheck?.city ?? "",
             entry.lastCheck?.countryCode.map(CountryNames.name(for:)) ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

private struct SavedProxyRow: View {
    let entry: ProxyListEntry

    var body: some View {
        HStack(spacing: 10) {
            ProxyStatusIcon(state: entry.state(checking: false))
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
            ProxyExitLabel(check: entry.lastCheck)
                .frame(width: 130, alignment: .leading)
            Text(entry.kindName)
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(ProxyCheckText.latency(entry.lastCheck))
                .font(.lumenBody)
                .foregroundStyle(ProxyCheckText.isSlow(entry.lastCheck) ? Theme.warning : Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The location card

/// Where the proxy exits, as the last lookup through it found (flag, country, time zone, when),
/// with the switch that makes the profile run in that time zone.
private struct ProxyLocationCard: View {
    @Binding var draft: ProfileDraft

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let location = draft.knownProxyLocation, let code = location.countryCode {
                CountryFlag(code: code, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("editor.location.exitsIn"), CountryNames.name(for: code)))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: location.timeZoneIdentifier + " · "
                         + String(format: L("editor.location.checked"), location.resolvedAt.formatted(.relative(presentation: .named))))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Image(systemName: "network")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("editor.location.unknown"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("editor.location.unknown.detail"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if draft.overrideTimeZone {
                Text(String(format: L("editor.location.fixedZone"), draft.timeZone))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            } else {
                Toggle(isOn: $draft.matchProxyLocation) {
                    Text(L("editor.location.followsProxy"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Rows

/// A labelled field: the label (12 / medium, secondary) above its control.
struct EditorField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .accessibilityHidden(true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A setting with a switch on the right: its title, and what it does below.
private struct EditorToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lumenLabel)
                    .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textDisabled)
                if let detail {
                    Text(detail)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// A setting with a control (a menu) on the right.
private struct EditorRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.lumenLabel)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            control
        }
    }
}

/// A sentence of explanation under a setting.
private struct EditorNote: View {
    enum Tone { case plain, warning }
    let text: String
    var tone: Tone = .plain

    init(_ text: String, tone: Tone = .plain) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Group {
            if tone == .warning {
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            } else {
                Text(text).foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.lumenSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditorGroupTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.lumenSection)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct EditorDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 2)
    }
}
