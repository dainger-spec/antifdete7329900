import BrowserCore
import SwiftUI

/// The profile editor's body: a header with the profile's glyph and where it exits, five tabs,
/// and a footer with Cancel and Save. Pure presentation over a `ProfileDraft` binding, so it can
/// be rendered with sample data (`--render-ui-snapshots`).
struct ProfileEditorForm: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, identity, network, privacy, data
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .general: return "editor.section.general"
            case .identity: return "editor.tab.identity"
            case .network: return "editor.section.network"
            case .privacy: return "editor.section.privacy"
            case .data: return "editor.tab.data"
            }
        }
    }

    @Binding var draft: ProfileDraft
    @Binding var tab: Tab
    var isNew: Bool
    /// Keeps the glyph's colour the same as in the Profiles list.
    var avatarID: UUID
    var error: String?
    /// The network extension can carry WebRTC through a SOCKS5 proxy (TunnelManager).
    var tunnelCarriesWebRTC: Bool
    var onCancel: () -> Void = {}
    var onSave: () -> Void = {}
    var onTunnelSettings: () -> Void = {}

    static let size = CGSize(width: 600, height: 660)

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker(L("editor.tabs"), selection: $tab) {
                ForEach(Tab.allCases) { Text(L($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .general: general
                    case .identity: identity
                    case .network: network
                    case .privacy: privacy
                    case .data: data
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(tab)
                .transition(.opacity)
            }
            .animation(Theme.appearAnimation, value: tab)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.raised)
        .tint(Theme.accentFill)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            ProfileAvatar(name: draft.name.isEmpty ? "?" : draft.name, id: avatarID, size: 36)
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
            if draft.proxyEnabled, let location = draft.knownProxyLocation, let code = location.countryCode {
                CountryFlag(code: code, size: 12)
                Text(verbatim: "\(CountryNames.name(for: code)) · \(location.timeZoneIdentifier)")
            } else if draft.proxyEnabled {
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
            }
            .padding(.horizontal, 24)
            .frame(height: 60)
        }
    }

    // MARK: Tabs

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorField(L("editor.name")) {
                TextField(L("editor.name"), text: $draft.name, prompt: Text(verbatim: "")).lumenField()
            }
            EditorField(L("editor.startURL")) {
                TextField(L("editor.startURL"), text: $draft.startURL, prompt: Text(verbatim: ""))
                    .lumenField("https://example.com", isEmpty: draft.startURL.isEmpty)
            }
            EditorDivider()
            EditorToggle(L("editor.ephemeral.title"), detail: L("editor.ephemeral.detail"), isOn: $draft.ephemeral)
        }
    }

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

    /// With a proxy, WebRTC can only be on through the network extension's relay, and only for SOCKS5.
    private var webRTCLocked: Bool {
        draft.proxyEnabled && !(draft.proxyKind == .socks5 && tunnelCarriesWebRTC)
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorToggle(L("editor.proxy.use.title"), detail: L("editor.proxy.detail"), isOn: $draft.proxyEnabled)
            if draft.proxyEnabled {
                EditorField(L("editor.proxy.type")) {
                    Picker(L("editor.proxy.type"), selection: $draft.proxyKind) {
                        Text(verbatim: "SOCKS5").tag(ProxySettings.Kind.socks5)
                        Text(verbatim: "HTTP CONNECT").tag(ProxySettings.Kind.httpConnect)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                HStack(alignment: .top, spacing: 12) {
                    EditorField(L("editor.proxy.host")) {
                        TextField(L("editor.proxy.host"), text: $draft.proxyHost, prompt: Text(verbatim: ""))
                            .lumenField("proxy.example.com", isEmpty: draft.proxyHost.isEmpty)
                    }
                    EditorField(L("editor.proxy.port")) {
                        TextField(L("editor.proxy.port"), text: $draft.proxyPort, prompt: Text(verbatim: ""))
                            .lumenField("1080", isEmpty: draft.proxyPort.isEmpty)
                    }
                    .frame(width: 96)
                }
                HStack(alignment: .top, spacing: 12) {
                    EditorField(L("editor.proxy.username")) {
                        TextField(L("editor.proxy.username"), text: $draft.proxyUsername, prompt: Text(verbatim: "")).lumenField()
                    }
                    EditorField(L("editor.proxy.password")) {
                        SecureField(L("editor.proxy.password"), text: $draft.proxyPassword, prompt: Text(verbatim: "")).lumenField()
                    }
                }
                if draft.proxyKind == .httpConnect {
                    EditorToggle(L("editor.proxy.tls"), isOn: $draft.proxyTLS)
                }
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
            if draft.proxyEnabled {
                if draft.proxyKind != .socks5 {
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

    private var privacy: some View {
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
            } else if draft.proxyEnabled {
                EditorNote(L("editor.tz.fromProxyHint"))
            }
            EditorDivider()
            EditorToggle(L("editor.safeBrowsing"), isOn: $draft.safeBrowsing)
            EditorNote(L("editor.privacy.footer"))
        }
    }

    static let timeZones = TimeZone.knownTimeZoneIdentifiers.sorted()

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
private struct EditorField<Content: View>: View {
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
