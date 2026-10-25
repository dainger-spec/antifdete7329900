import BrowserCore
import SwiftUI

/// Editable, string-based mirror of `ProfileConfiguration` for form binding.
struct ProfileDraft {
    enum GeoMode: String, CaseIterable, Identifiable {
        case deny = "Deny", fixed = "Fixed coordinates"
        var id: String { rawValue }
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
        var label: String
    }

    static let retentionChoices = [
        RetentionChoice(days: 7, label: "1 week"), RetentionChoice(days: 30, label: "1 month"),
        RetentionChoice(days: 90, label: "3 months"), RetentionChoice(days: 365, label: "1 year"),
        RetentionChoice(days: 0, label: "Forever"),
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
            guard let url = URL(string: trimmedURL) else { throw CoreError.invalidConfiguration("start URL is not a URL") }
            configuration.startURL = url
        }
        if customUserAgent {
            configuration.userAgent = userAgent.trimmingCharacters(in: .whitespaces)
        }
        if proxyEnabled {
            guard let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)) else {
                throw CoreError.invalidConfiguration("proxy port must be a number")
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
                throw CoreError.invalidConfiguration("latitude, longitude and accuracy must be numbers")
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

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $draft.name)
                TextField("Start URL", text: $draft.startURL, prompt: Text("https://example.com"))
                Toggle("Ephemeral (no website data or history written to disk)", isOn: $draft.ephemeral)
            }
            Section {
                Toggle("Record history", isOn: $draft.historyEnabled)
                if draft.historyEnabled {
                    Picker("Keep history for", selection: $draft.historyRetentionDays) {
                        ForEach(ProfileDraft.retentionChoices, id: \.days) { Text($0.label).tag($0.days) }
                    }
                }
            } header: { Text("History") } footer: {
                Text("History and bookmarks are encrypted with the profile key. Ephemeral profiles keep history in memory only; bookmarks are always saved.")
            }
            Section {
                Toggle("Custom user agent", isOn: $draft.customUserAgent)
                if draft.customUserAgent {
                    TextField("User agent", text: $draft.userAgent, axis: .vertical).lineLimit(2...4)
                }
            } header: { Text("User agent") } footer: {
                Text("Native (HTTP header + navigator.userAgent). The engine is still WebKit: a Chrome/Firefox UA is inconsistent with feature detection and TLS fingerprint.")
            }
            Section {
                Toggle("Use proxy", isOn: $draft.proxyEnabled)
                if draft.proxyEnabled {
                    Picker("Type", selection: $draft.proxyKind) {
                        Text("SOCKS5").tag(ProxySettings.Kind.socks5)
                        Text("HTTP CONNECT").tag(ProxySettings.Kind.httpConnect)
                    }
                    TextField("Host", text: $draft.proxyHost)
                    TextField("Port", text: $draft.proxyPort)
                    TextField("Username (optional)", text: $draft.proxyUsername)
                    SecureField("Password", text: $draft.proxyPassword)
                    if draft.proxyKind == .httpConnect {
                        Toggle("TLS to proxy (HTTPS proxy)", isOn: $draft.proxyTLS)
                    }
                    TextField("Bypass domains (comma-separated)", text: $draft.proxyExcludedDomains)
                }
            } header: { Text("Network") } footer: {
                Text("Native per-profile proxy, fail-closed (no direct fallback). WebRTC UDP is not proxied.")
            }
            Section {
                Picker("WebRTC", selection: $draft.webRTC) {
                    Text("Disabled").tag(WebRTCPolicy.disabled)
                    Text("Relay (TURN) only").tag(WebRTCPolicy.relayOnly)
                    Text("Unrestricted").tag(WebRTCPolicy.unrestricted)
                }
                Picker("Geolocation", selection: $draft.geoMode) {
                    ForEach(ProfileDraft.GeoMode.allCases) { Text($0.rawValue).tag($0) }
                }
                if draft.geoMode == .fixed {
                    TextField("Latitude", text: $draft.latitude)
                    TextField("Longitude", text: $draft.longitude)
                    TextField("Accuracy (m)", text: $draft.accuracy)
                }
                Toggle("Override time zone", isOn: $draft.overrideTimeZone)
                if draft.overrideTimeZone {
                    Picker("Time zone", selection: $draft.timeZone) {
                        ForEach(Self.timeZones, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Safe Browsing (lookups bypass the proxy)", isOn: $draft.safeBrowsing)
            } header: { Text("Privacy") } footer: {
                Text("WebRTC, geolocation and time zone are JavaScript shims (not applied in workers, detectable). See docs/ISOLATION_AND_LIMITATIONS.md.")
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .existing(let summary) = target {
            do {
                draft = ProfileDraft(name: summary.name, configuration: try model.configuration(for: summary.id))
            } catch {
                self.error = "Could not decrypt profile: \(error.localizedDescription)"
            }
        } else {
            draft.name = "Profile \(model.profiles.count + 1)"
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
