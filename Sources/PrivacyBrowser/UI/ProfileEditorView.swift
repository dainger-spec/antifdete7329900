import BrowserCore
import SwiftUI

/// Editable, string-based mirror of `ProfileConfiguration` for form binding.
struct ProfileDraft {
    enum GeoMode: String, CaseIterable, Identifiable {
        case deny, fixed
        var id: String { rawValue }
        var labelKey: String { self == .deny ? "editor.geo.deny" : "editor.geo.fixed" }
    }

    var name = ""
    var startURL = ""
    var deviceGenerationID = DeviceGenerations.defaultID
    var customUserAgent = false
    var userAgent = ""
    var proxyEnabled = false
    var proxyKind: ProxySettings.Kind = .socks5
    var proxyHost = ""
    var proxyPort = ""
    var proxyUsername = ""
    var proxyPassword = ""
    var proxyTLS = false
    var proxyExcludedDomains = ""
    var geoMode: GeoMode = .deny
    var latitude = ""
    var longitude = ""
    var accuracy = "50"
    var overrideTimeZone = false
    var timeZone = TimeZone.current.identifier
    var matchProxyLocation = true
    /// Carried through unchanged (a cache for launching; see ProfileConfiguration).
    var lastProxyLocation: ProxyLocation?
    var warnOnProxyIPChange = false
    var webRTC: WebRTCPolicy = .disabled
    var ephemeral = false
    var useSafariChrome = false
    var safeBrowsing = false
    var historyEnabled = true
    /// 0 = keep forever.
    var historyRetentionDays = 90
    var passwordAutoFill = true
    var syncCookies = true

    struct RetentionChoice: Hashable {
        var days: Int
        var labelKey: String
    }

    static let retentionChoices = [
        RetentionChoice(days: 7, labelKey: "editor.retain.week"),
        RetentionChoice(days: 30, labelKey: "editor.retain.month"),
        RetentionChoice(days: 90, labelKey: "editor.retain.quarter"),
        RetentionChoice(days: 365, labelKey: "editor.retain.year"),
        RetentionChoice(days: 0, labelKey: "editor.retain.forever"),
    ]

    init() {}

    init(name: String, configuration c: ProfileConfiguration) {
        self.name = name
        startURL = c.startURL?.absoluteString ?? ""
        deviceGenerationID = c.deviceGenerationID ?? DeviceGenerations.defaultID
        customUserAgent = c.userAgent != nil
        userAgent = c.userAgent ?? ""
        if let proxy = c.proxy {
            proxyEnabled = true
            proxyKind = proxy.kind
            proxyHost = proxy.host
            proxyPort = String(proxy.port)
            proxyUsername = proxy.username ?? ""
            proxyPassword = proxy.password ?? ""
            proxyTLS = proxy.tlsToProxy
            proxyExcludedDomains = proxy.excludedDomains.joined(separator: ", ")
        }
        if case let .fixed(lat, lon, acc) = c.geolocation {
            geoMode = .fixed
            latitude = String(lat)
            longitude = String(lon)
            accuracy = String(acc)
        }
        overrideTimeZone = c.timeZoneIdentifier != nil
        timeZone = c.timeZoneIdentifier ?? TimeZone.current.identifier
        matchProxyLocation = c.matchProxyLocation
        lastProxyLocation = c.lastProxyLocation
        warnOnProxyIPChange = c.warnOnProxyIPChange
        webRTC = c.webRTCPolicy
        ephemeral = c.ephemeral
        useSafariChrome = c.useSafariChrome
        safeBrowsing = c.safeBrowsingEnabled
        historyEnabled = c.historyEnabled
        historyRetentionDays = c.historyRetentionDays ?? 0
        passwordAutoFill = c.passwordAutoFill
        syncCookies = c.syncCookies
    }

    /// The proxy these fields describe (nil without one). The Host field often holds a pasted
    /// proxy string (socks5://user:pass@host:port, host:port, host:port:user:pass): it is split into
    /// its parts; what is not a host is rejected.
    func makeProxy() throws -> ProxySettings? {
        guard proxyEnabled else { return nil }
        let field: ProxyHostField
        do {
            field = try ProxyHostField.parse(proxyHost)
        } catch {
            throw CoreError.invalidConfiguration(String(format: L("editor.error.proxyHost"),
                                                        proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        var portText = proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pastedPort = field.port {
            guard portText.isEmpty || Int(portText) == pastedPort else {
                throw CoreError.invalidConfiguration(L("editor.error.proxyPortConflict"))
            }
            portText = String(pastedPort)
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw CoreError.invalidConfiguration(L("editor.error.port"))
        }
        var user = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        var password = proxyPassword
        if let pastedUser = field.username {
            guard user.isEmpty || user == pastedUser else {
                throw CoreError.invalidConfiguration(L("editor.error.proxyUserConflict"))
            }
            user = pastedUser
            password = field.password ?? ""
        }
        // A scheme in the pasted string is more specific than the picker.
        let kind = field.kind ?? proxyKind
        return ProxySettings(
            kind: kind,
            host: field.host,
            port: port,
            username: user.isEmpty ? nil : user,
            password: user.isEmpty ? nil : password,
            // The TLS toggle is shown for HTTP CONNECT only; its hidden value must not leak into SOCKS5.
            tlsToProxy: kind == .httpConnect && (field.tlsToProxy ?? proxyTLS),
            excludedDomains: proxyExcludedDomains.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// What the last lookup through the proxy found, while these fields still describe that proxy
    /// (`ProxyLocation.endpoint(of:)`): nil once host, port or credentials name another one.
    var knownProxyLocation: ProxyLocation? {
        guard let location = lastProxyLocation, let proxy = try? makeProxy() else { return nil }
        return location.proxyEndpoint == ProxyLocation.endpoint(of: proxy) ? location : nil
    }

    func makeConfiguration() throws -> ProfileConfiguration {
        var configuration = ProfileConfiguration()
        let trimmedURL = startURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            guard let url = URL(string: trimmedURL) else { throw CoreError.invalidConfiguration(L("editor.error.startURL")) }
            configuration.startURL = url
        }
        configuration.deviceGenerationID = deviceGenerationID
        if customUserAgent {
            configuration.userAgent = userAgent.trimmingCharacters(in: .whitespaces)
        }
        configuration.proxy = try makeProxy()
        if geoMode == .fixed {
            guard let lat = Double(latitude), let lon = Double(longitude), let acc = Double(accuracy) else {
                throw CoreError.invalidConfiguration(L("editor.error.coords"))
            }
            configuration.geolocation = .fixed(latitude: lat, longitude: lon, accuracyMeters: acc)
        }
        configuration.timeZoneIdentifier = overrideTimeZone ? timeZone : nil
        configuration.matchProxyLocation = matchProxyLocation
        configuration.lastProxyLocation = lastProxyLocation
        configuration.warnOnProxyIPChange = warnOnProxyIPChange
        configuration.webRTCPolicy = webRTC
        configuration.ephemeral = ephemeral
        configuration.useSafariChrome = useSafariChrome
        configuration.safeBrowsingEnabled = safeBrowsing
        configuration.historyEnabled = historyEnabled
        configuration.historyRetentionDays = historyRetentionDays == 0 ? nil : historyRetentionDays
        // The "Never for This Website" list is the browser's; saving keeps the stored one
        // (ProfileConfiguration.keepingStoredState).
        configuration.passwordAutoFill = passwordAutoFill
        configuration.syncCookies = syncCookies
        try configuration.validate()
        return configuration
    }
}

struct ProfileEditorView: View {
    enum Target: Identifiable {
        case new
        case existing(ProfileSummary)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let summary): return summary.id.uuidString
            }
        }
    }

    let target: Target
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProfileDraft()
    @State private var error: String?
    @State private var loaded = false
    @State private var showingTunnel = false
    @State private var tab: ProfileEditorForm.Tab = .general
    @ObservedObject private var tunnel = TunnelManager.shared

    /// The glyph colour of a profile not created yet (it has no id).
    private static let newProfileAvatarID = UUID(uuid: (0x4C, 0x55, 0x4D, 0x45, 0x4E, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))

    var body: some View {
        ProfileEditorForm(draft: $draft, tab: $tab, isNew: target.isNew, avatarID: avatarID, error: error,
                          tunnelCarriesWebRTC: tunnel.canCarryWebRTC,
                          onCancel: { dismiss() }, onSave: save, onTunnelSettings: { showingTunnel = true })
            .onAppear(perform: load)
            .sheet(isPresented: $showingTunnel) { TunnelSettingsView() }
    }

    private var avatarID: UUID {
        if case .existing(let summary) = target { return summary.id }
        return Self.newProfileAvatarID
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .existing(let summary) = target {
            do {
                draft = ProfileDraft(name: summary.name, configuration: try model.configuration(for: summary.id))
            } catch {
                self.error = String(format: L("editor.error.decrypt"), error.localizedDescription)
            }
        } else {
            draft.name = String(format: L("editor.defaultName"), model.profiles.count + 1)
        }
    }

    private func save() {
        do {
            let configuration = try draft.makeConfiguration()
            switch target {
            case .new:
                try model.createProfile(name: draft.name, configuration: configuration)
            case .existing(let summary):
                try model.updateProfile(summary.id, name: draft.name, configuration: configuration)
            }
            dismiss()
        } catch {
            self.error = (error as? CoreError)?.description ?? error.localizedDescription
        }
    }
}

private extension ProfileEditorView.Target {
    var isNew: Bool { if case .new = self { return true } else { return false } }
}
