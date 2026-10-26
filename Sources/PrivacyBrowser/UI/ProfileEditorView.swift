import BrowserCore
import SwiftUI

/// Editable, string-based mirror of `ProfileConfiguration` for form binding. Validation turns
/// every mistake into a plain-language message for the field that has it.
struct ProfileDraft: Equatable {
    enum GeoMode: String, CaseIterable, Identifiable {
        case deny, fixed
        var id: String { rawValue }
        var labelKey: String { self == .deny ? "editor.geo.deny" : "editor.geo.fixed" }
    }

    var name = ""
    var startURL = ""
    var ephemeral = false
    var restoreTabs = true
    var proxyEnabled = false
    /// "socks5://203.0.113.5:1080", "http://host:8080", "host:port"… Credentials pasted into it
    /// move to the login fields.
    var proxyAddress = ""
    var proxyUsername = ""
    var proxyPassword = ""
    var proxyExcludedDomains = ""
    var userAgentMode: UserAgentMode = .safariMac
    var customUserAgent = ""
    /// nil = the Mac's language.
    var locale: String?
    /// nil = the Mac's time zone.
    var timeZone: String?
    var geoMode: GeoMode = .deny
    var latitude = ""
    var longitude = ""
    var accuracy = "50"
    var webRTC: WebRTCPolicy = .disabled
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

    /// A form error: which message to show (localization key) and an optional detail.
    struct Problem: Error, Equatable {
        var messageKey: String
        var detail: String?
    }

    init() {}

    init(name: String, configuration c: ProfileConfiguration) {
        self.name = name
        startURL = c.startURL?.absoluteString ?? ""
        ephemeral = c.ephemeral
        restoreTabs = c.restoreTabs
        if let proxy = c.proxy {
            proxyEnabled = true
            var bare = proxy
            bare.username = nil
            bare.password = nil
            proxyAddress = bare.urlString(includePassword: false)
            proxyUsername = proxy.username ?? ""
            proxyPassword = proxy.password ?? ""
            proxyExcludedDomains = proxy.excludedDomains.joined(separator: ", ")
        }
        userAgentMode = c.userAgentMode
        customUserAgent = c.userAgent ?? ""
        locale = c.locale
        timeZone = c.timeZoneIdentifier
        if case let .fixed(lat, lon, acc) = c.geolocation {
            geoMode = .fixed
            latitude = String(lat)
            longitude = String(lon)
            accuracy = String(acc)
        }
        webRTC = c.webRTCPolicy
        safeBrowsing = c.safeBrowsingEnabled
        historyEnabled = c.historyEnabled
        historyRetentionDays = c.historyRetentionDays ?? 0
    }

    /// The proxy as typed, or nil when off. Throws a `Problem` when it can't be understood.
    func proxySettings() throws -> ProxySettings? {
        guard proxyEnabled else { return nil }
        let address = proxyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw Problem(messageKey: "editor.error.proxyEmpty") }
        var settings: ProxySettings
        do {
            settings = try ProxySettings(parsing: address)
        } catch {
            throw Problem(messageKey: "editor.error.proxy", detail: (error as? CoreError)?.description)
        }
        if settings.username == nil {
            let user = proxyUsername.trimmingCharacters(in: .whitespaces)
            settings.username = user.isEmpty ? nil : user
            settings.password = user.isEmpty ? nil : proxyPassword
        }
        settings.excludedDomains = proxyExcludedDomains.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try settings.validate()
        } catch {
            throw Problem(messageKey: "editor.error.proxy", detail: (error as? CoreError)?.description)
        }
        return settings
    }

    func makeConfiguration() throws -> ProfileConfiguration {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Problem(messageKey: "editor.error.name")
        }
        var configuration = ProfileConfiguration()
        let trimmedURL = startURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty {
            let candidate = trimmedURL.contains("://") ? trimmedURL : "https://" + trimmedURL
            guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else {
                throw Problem(messageKey: "editor.error.startURL")
            }
            configuration.startURL = url
        }
        configuration.ephemeral = ephemeral
        configuration.restoreTabs = restoreTabs
        configuration.proxy = try proxySettings()
        configuration.userAgentMode = userAgentMode
        if userAgentMode == .custom {
            let ua = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ua.isEmpty else { throw Problem(messageKey: "editor.error.userAgent") }
            configuration.userAgent = ua
        }
        configuration.locale = locale
        configuration.timeZoneIdentifier = timeZone
        if geoMode == .fixed {
            guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
                  let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")),
                  let acc = Double(accuracy.replacingOccurrences(of: ",", with: ".")) else {
                throw Problem(messageKey: "editor.error.coords")
            }
            configuration.geolocation = .fixed(latitude: lat, longitude: lon, accuracyMeters: acc)
        }
        configuration.webRTCPolicy = webRTC
        configuration.safeBrowsingEnabled = safeBrowsing
        configuration.historyEnabled = historyEnabled
        configuration.historyRetentionDays = historyRetentionDays == 0 ? nil : historyRetentionDays
        do {
            try configuration.validate()
        } catch {
            throw Problem(messageKey: "editor.error.invalid", detail: (error as? CoreError)?.description)
        }
        return configuration
    }
}

struct ProfileEditorView: View {
    enum Target: Equatable {
        case new
        case existing(UUID)
    }

    let target: Target
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProfileDraft()
    @State private var problem: ProfileDraft.Problem?
    @State private var loaded = false
    @State private var proxyCheck: ProxyStatus?
    @State private var showAdvancedProxy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if case .existing(let id) = target {
                    ProfileAvatar(name: draft.name.isEmpty ? "?" : draft.name, id: id, size: 32)
                } else {
                    IconBadge(symbol: "plus", size: 32)
                }
                Text(target == .new ? L("editor.title.new") : L("editor.title.edit")).font(.title3.bold())
                Spacer()
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 6)

            Form {
                generalSection
                networkSection
                regionSection
                browserSection
                privacySection
                historySection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(problem.messageKey))
                            if let detail = problem.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target == .new ? L("editor.create") : L("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 580, height: 700)
        .onAppear(perform: load)
        .onChange(of: draft) { _, _ in problem = nil }
        .onChange(of: draft.proxyAddress) { _, _ in proxyCheck = nil }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            TextField(L("editor.name"), text: $draft.name, prompt: Text(L("editor.name.prompt")))
            TextField(L("editor.startURL"), text: $draft.startURL, prompt: Text(verbatim: "https://example.com"))
            Toggle(L("editor.restoreTabs"), isOn: $draft.restoreTabs)
                .disabled(draft.ephemeral)
            Toggle(L("editor.ephemeral"), isOn: $draft.ephemeral)
        } header: {
            Text(L("editor.section.general"))
        } footer: {
            Text(L("editor.general.footer")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        Section {
            Toggle(L("editor.proxy.use"), isOn: $draft.proxyEnabled)
            if draft.proxyEnabled {
                TextField(L("editor.proxy.address"), text: $draft.proxyAddress,
                          prompt: Text(verbatim: "socks5://203.0.113.5:1080"))
                    .autocorrectionDisabled()
                TextField(L("editor.proxy.username"), text: $draft.proxyUsername)
                SecureField(L("editor.proxy.password"), text: $draft.proxyPassword)
                HStack {
                    Button(L("proxy.check"), action: checkProxy)
                        .disabled(proxyCheck == .checking)
                    if let proxyCheck {
                        if proxyCheck == .checking { ProgressView().controlSize(.small) }
                        ProxyStatusDot(status: proxyCheck)
                        Text(proxyCheckText(proxyCheck))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DisclosureGroup(L("editor.proxy.advanced"), isExpanded: $showAdvancedProxy) {
                    TextField(L("editor.proxy.bypass"), text: $draft.proxyExcludedDomains,
                              prompt: Text(verbatim: "intranet.example.com, *.local"))
                }
            }
        } header: {
            Text(L("editor.section.network"))
        } footer: {
            Text(draft.proxyEnabled ? L("editor.network.proxy.footer") : L("editor.network.direct.footer"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var regionSection: some View {
        Section {
            Picker(L("editor.language"), selection: $draft.locale) {
                Text(L("editor.asSystem")).tag(String?.none)
                Divider()
                ForEach(LocaleOption.choices(including: draft.locale), id: \.self) { code in
                    Text(LocaleOption.label(code)).tag(Optional(code))
                }
            }
            Picker(L("editor.tz"), selection: $draft.timeZone) {
                Text(L("editor.asSystem")).tag(String?.none)
                Divider()
                ForEach(TimeZoneOption.choices(including: draft.timeZone), id: \.self) { zone in
                    Text(TimeZoneOption.label(zone)).tag(Optional(zone))
                }
            }
        } header: {
            Text(L("editor.section.region"))
        } footer: {
            Text(L("editor.region.footer")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var browserSection: some View {
        Section {
            Picker(L("editor.ua.mode"), selection: $draft.userAgentMode) {
                ForEach(UserAgentMode.allCases, id: \.self) { mode in
                    Text(L(UserAgentOption.labelKey(mode))).tag(mode)
                }
            }
            if draft.userAgentMode == .custom {
                TextField(L("editor.ua.field"), text: $draft.customUserAgent, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.callout.monospaced())
            } else {
                LabeledContent(L("editor.ua.effective")) {
                    Text(effectiveUserAgent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if draft.userAgentMode == .iPhone || draft.userAgentMode == .iPad {
                Label(L("editor.ua.mobileNote"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("editor.section.browser"))
        } footer: {
            Text(L("editor.ua.footer")).font(.caption).foregroundStyle(.secondary)
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
                TextField(L("editor.geo.lat"), text: $draft.latitude, prompt: Text(verbatim: "52.52"))
                TextField(L("editor.geo.lon"), text: $draft.longitude, prompt: Text(verbatim: "13.405"))
                TextField(L("editor.geo.accuracy"), text: $draft.accuracy)
            }
            Toggle(L("editor.safeBrowsing"), isOn: $draft.safeBrowsing)
        } header: {
            Text(L("editor.section.privacy"))
        } footer: {
            Text(L("editor.privacy.footer")).font(.caption).foregroundStyle(.secondary)
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
        } header: {
            Text(L("editor.section.history"))
        } footer: {
            Text(L("editor.history.footer")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private var effectiveUserAgent: String {
        let resolution = UserAgentBuilder.resolve(mode: draft.userAgentMode, customUserAgent: nil, safari: SafariInfo.version)
        if let full = resolution.customUserAgent { return full }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + (resolution.applicationNameForUserAgent ?? "")
    }

    private func proxyCheckText(_ status: ProxyStatus) -> String {
        switch status {
        case .working(let ms?): return String(format: L("proxy.status.workingMs"), ms)
        case .failed(let message): return L(message.messageKey)
        default: return L(status.labelKey)
        }
    }

    private func checkProxy() {
        do {
            guard let settings = try draft.proxySettings() else { return }
            proxyCheck = .checking
            Task {
                let result = await ProxyChecker.check(settings)
                proxyCheck = result
                if case .existing(let id) = target, draft.proxyEnabled,
                   (try? draft.proxySettings()) == model.configurations[id]?.proxy {
                    model.proxyStatus.set(result, for: id)
                }
            }
        } catch let problem as ProfileDraft.Problem {
            self.problem = problem
        } catch {}
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .existing(let id) = target {
            do {
                draft = ProfileDraft(name: model.summary(id)?.name ?? "", configuration: try model.configuration(for: id))
            } catch {
                problem = .init(messageKey: "editor.error.decrypt", detail: Log.describe(error))
            }
        } else {
            draft.name = String(format: L("editor.defaultName"), model.profiles.count + 1)
        }
    }

    private func save() {
        do {
            let configuration = try draft.makeConfiguration()
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch target {
            case .new:
                try model.createProfile(name: name, configuration: configuration)
            case .existing(let id):
                try model.updateProfile(id, name: name, configuration: configuration)
            }
            dismiss()
        } catch let problem as ProfileDraft.Problem {
            self.problem = problem
        } catch {
            problem = .init(messageKey: "editor.error.save", detail: Log.describe(error))
        }
    }
}

// MARK: - Choices

enum UserAgentOption {
    static func labelKey(_ mode: UserAgentMode) -> String {
        switch mode {
        case .safariMac: return "ua.mode.safariMac"
        case .iPhone: return "ua.mode.iPhone"
        case .iPad: return "ua.mode.iPad"
        case .custom: return "ua.mode.custom"
        }
    }
}

/// Time zones offered in the editor: common ones first, then every zone the system knows.
enum TimeZoneOption {
    static let common = [
        "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin", "Europe/Amsterdam",
        "Europe/Madrid", "Europe/Rome", "Europe/Warsaw", "Europe/Prague", "Europe/Stockholm", "Europe/Helsinki",
        "Europe/Kyiv", "Europe/Istanbul", "Europe/Moscow", "Asia/Dubai", "Asia/Tbilisi", "Asia/Almaty",
        "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo",
        "Asia/Seoul", "Australia/Sydney", "America/New_York", "America/Chicago", "America/Denver",
        "America/Los_Angeles", "America/Toronto", "America/Mexico_City", "America/Sao_Paulo",
        "America/Buenos_Aires", "Africa/Cairo", "Africa/Johannesburg", "UTC",
    ]

    static let all: [String] = {
        let rest = TimeZone.knownTimeZoneIdentifiers.filter { !common.contains($0) }.sorted()
        return common + rest
    }()

    static func choices(including current: String?) -> [String] {
        guard let current, !all.contains(current) else { return all }
        return [current] + all
    }

    static func label(_ identifier: String) -> String {
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        guard let zone = TimeZone(identifier: identifier) else { return city }
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "−" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        let offset = minutes == 0 ? "UTC\(sign)\(hours)" : "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
        return "\(city) (\(offset))"
    }
}

/// Languages offered in the editor (BCP 47, as WebKit and macOS write them).
enum LocaleOption {
    static let common = [
        "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "pt-PT", "nl-NL", "pl-PL",
        "cs-CZ", "sv-SE", "fi-FI", "da-DK", "nb-NO", "tr-TR", "uk-UA", "ru-RU", "kk-KZ", "ka-GE",
        "ja-JP", "ko-KR", "zh-CN", "zh-TW", "ar-AE", "he-IL", "hi-IN", "th-TH", "vi-VN", "id-ID",
    ]

    static func choices(including current: String?) -> [String] {
        guard let current, !common.contains(current) else { return common }
        return [current] + common
    }

    static func label(_ code: String) -> String {
        let name = Locale(identifier: Localization.languageCode).localizedString(forIdentifier: code) ?? code
        return "\(name.prefix(1).uppercased())\(name.dropFirst()) — \(code)"
    }
}
