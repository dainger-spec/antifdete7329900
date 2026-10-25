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
    var webRTC: WebRTCPolicy = .disabled
    var ephemeral = false
    var safeBrowsing = false
    var historyEnabled = true
    /// 0 = keep forever.
    var historyRetentionDays = 90

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
        webRTC = c.webRTCPolicy
        ephemeral = c.ephemeral
        safeBrowsing = c.safeBrowsingEnabled
        historyEnabled = c.historyEnabled
        historyRetentionDays = c.historyRetentionDays ?? 0
    }

    func makeConfiguration() throws -> ProfileConfiguration {
        var configuration = ProfileConfiguration()
        let trimmedURL = startURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            guard let url = URL(string: trimmedURL) else { throw CoreError.invalidConfiguration(L("editor.error.startURL")) }
            configuration.startURL = url
        }
        if customUserAgent {
            configuration.userAgent = userAgent.trimmingCharacters(in: .whitespaces)
        }
        if proxyEnabled {
            guard let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)) else {
                throw CoreError.invalidConfiguration(L("editor.error.port"))
            }
            let user = proxyUsername.trimmingCharacters(in: .whitespaces)
            configuration.proxy = ProxySettings(
                kind: proxyKind,
                host: proxyHost.trimmingCharacters(in: .whitespaces),
                port: port,
                username: user.isEmpty ? nil : user,
                password: user.isEmpty ? nil : proxyPassword,
                tlsToProxy: proxyTLS,
                excludedDomains: proxyExcludedDomains.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if geoMode == .fixed {
            guard let lat = Double(latitude), let lon = Double(longitude), let acc = Double(accuracy) else {
                throw CoreError.invalidConfiguration(L("editor.error.coords"))
            }
            configuration.geolocation = .fixed(latitude: lat, longitude: lon, accuracyMeters: acc)
        }
        configuration.timeZoneIdentifier = overrideTimeZone ? timeZone : nil
        configuration.webRTCPolicy = webRTC
        configuration.ephemeral = ephemeral
        configuration.safeBrowsingEnabled = safeBrowsing
        configuration.historyEnabled = historyEnabled
        configuration.historyRetentionDays = historyRetentionDays == 0 ? nil : historyRetentionDays
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

    private static let timeZones = TimeZone.knownTimeZoneIdentifiers.sorted()
    private static let customUAID = "__custom__"

    /// Which UA preset the current text matches ("custom" when it matches none).
    private var selectedPresetID: String {
        UserAgentPresets.matching(userAgent: draft.customUserAgent ? draft.userAgent : nil)?.id ?? Self.customUAID
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(target.isNew ? L("editor.title.new") : L("editor.title.edit"))
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal], 20)
            Form {
                generalSection
                identitySection
                historySection
                networkSection
                privacySection
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 540, height: 660)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("common.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(L("common.save"), action: save) }
        }
        .onAppear(perform: load)
    }

    private var generalSection: some View {
        Section(L("editor.section.general")) {
            TextField(L("editor.name"), text: $draft.name)
            TextField(L("editor.startURL"), text: $draft.startURL, prompt: Text(verbatim: "https://example.com"))
            Toggle(L("editor.ephemeral"), isOn: $draft.ephemeral)
        }
    }

    private var identitySection: some View {
        Section {
            Picker(L("editor.ua.preset"), selection: Binding(
                get: { selectedPresetID },
                set: { applyPreset(id: $0) })) {
                ForEach(UserAgentPresets.all) { preset in
                    Text(L(preset.nameKey)).tag(preset.id)
                }
                Text(L("editor.ua.custom")).tag(Self.customUAID)
            }
            Toggle(L("editor.ua.useCustom"), isOn: $draft.customUserAgent)
            if draft.customUserAgent {
                TextField(L("editor.ua.field"), text: $draft.userAgent, axis: .vertical).lineLimit(2...4)
            }
            if let preset = UserAgentPresets.matching(userAgent: draft.customUserAgent ? draft.userAgent : nil),
               !preset.matchesEngine {
                Label(L("editor.ua.inconsistent"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: { Text(L("editor.section.identity")) } footer: {
            Text(L("editor.ua.footer"))
        }
    }

    private var historySection: some View {
        Section {
            Toggle(L("editor.history.record"), isOn: $draft.historyEnabled)
            if draft.historyEnabled {
                Picker(L("editor.history.keep"), selection: $draft.historyRetentionDays) {
                    ForEach(ProfileDraft.retentionChoices, id: \.days) { Text(L($0.labelKey)).tag($0.days) }
                }
            }
        } header: { Text(L("editor.section.history")) } footer: {
            Text(L("editor.history.footer"))
        }
    }

    private var networkSection: some View {
        Section {
            Toggle(L("editor.proxy.use"), isOn: $draft.proxyEnabled)
            if draft.proxyEnabled {
                Picker(L("editor.proxy.type"), selection: $draft.proxyKind) {
                    Text(verbatim: "SOCKS5").tag(ProxySettings.Kind.socks5)
                    Text(verbatim: "HTTP CONNECT").tag(ProxySettings.Kind.httpConnect)
                }
                TextField(L("editor.proxy.host"), text: $draft.proxyHost)
                TextField(L("editor.proxy.port"), text: $draft.proxyPort)
                TextField(L("editor.proxy.username"), text: $draft.proxyUsername)
                SecureField(L("editor.proxy.password"), text: $draft.proxyPassword)
                if draft.proxyKind == .httpConnect {
                    Toggle(L("editor.proxy.tls"), isOn: $draft.proxyTLS)
                }
                TextField(L("editor.proxy.bypass"), text: $draft.proxyExcludedDomains)
            }
        } header: { Text(L("editor.section.network")) } footer: {
            Text(L("editor.network.footer"))
        }
    }

    private var privacySection: some View {
        Section {
            Picker(L("editor.webrtc"), selection: $draft.webRTC) {
                Text(L("editor.webrtc.disabled")).tag(WebRTCPolicy.disabled)
                Text(L("editor.webrtc.relay")).tag(WebRTCPolicy.relayOnly)
                Text(L("editor.webrtc.unrestricted")).tag(WebRTCPolicy.unrestricted)
            }
            Picker(L("editor.geo"), selection: $draft.geoMode) {
                ForEach(ProfileDraft.GeoMode.allCases) { Text(L($0.labelKey)).tag($0) }
            }
            if draft.geoMode == .fixed {
                TextField(L("editor.geo.lat"), text: $draft.latitude)
                TextField(L("editor.geo.lon"), text: $draft.longitude)
                TextField(L("editor.geo.accuracy"), text: $draft.accuracy)
            }
            Toggle(L("editor.tz.override"), isOn: $draft.overrideTimeZone)
            if draft.overrideTimeZone {
                Picker(L("editor.tz"), selection: $draft.timeZone) {
                    ForEach(Self.timeZones, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
            Toggle(L("editor.safeBrowsing"), isOn: $draft.safeBrowsing)
        } header: { Text(L("editor.section.privacy")) } footer: {
            Text(L("editor.privacy.footer"))
        }
    }

    private func applyPreset(id: String) {
        if id == Self.customUAID {
            draft.customUserAgent = true
            if UserAgentPresets.matching(userAgent: draft.userAgent) != nil { draft.userAgent = "" }
        } else if let preset = UserAgentPresets.preset(id: id) {
            draft.customUserAgent = true
            draft.userAgent = preset.userAgent
        }
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
