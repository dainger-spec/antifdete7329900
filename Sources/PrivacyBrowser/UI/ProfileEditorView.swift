import BrowserCore
import SwiftUI

/// Editable, string-based mirror of `ProfileConfiguration` for form binding.
struct ProfileDraft {
    enum GeoMode: String, CaseIterable, Identifiable {
        case deny, fixed
        var id: String { rawValue }
        var labelKey: String { self == .deny ? "editor.geo.deny" : "editor.geo.fixed" }
    }

    /// How the profile reaches the network: three buttons, not menus in menus.
    enum ProxyMode: String, CaseIterable, Identifiable {
        /// Directly.
        case direct
        /// Through a proxy of the list.
        case saved
        /// Through a proxy typed or pasted here.
        case new
        var id: String { rawValue }

        var labelKey: String {
            switch self {
            case .direct: return "editor.proxy.mode.none"
            case .saved: return "editor.proxy.mode.saved"
            case .new: return "editor.proxy.mode.new"
            }
        }
    }

    var name = ""
    var startURL = ""
    var deviceGenerationID = DeviceGenerations.defaultID
    var customUserAgent = false
    var userAgent = ""
    var proxyMode: ProxyMode = .direct
    /// "New": the proxy as typed or pasted, one line.
    var proxyLine = ProxyLine()
    /// "From the list": the entry chosen, as the list had it then (`refreshSavedProxy`).
    var savedProxy: ProxyListEntry?
    /// The profile's own: a proxy of the list carries none.
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
    var safeBrowsing = false
    var historyEnabled = true
    /// 0 = keep forever.
    var historyRetentionDays = 90
    var passwordAutoFill = true
    var syncCookies = true
    var searchEngine = SearchEngine.standard
    /// The person's own labels and notes, and the glyph's colour and letters (nil, empty: the defaults).
    var tags: [String] = []
    var notes = ""
    var avatarColor: Int?
    var avatarLetters = ""

    /// The glyph as these choices make it; nil: the default look.
    var avatarStyle: ProfileAvatarStyle? {
        ProfileAvatarStyle(color: avatarColor, letters: avatarLetters).normalized
    }

    /// The window size as the editor holds it (`WindowSize`).
    enum WindowChoice: Hashable {
        /// As the app opens windows: this Mac as it is.
        case app
        case mac(MacScreen)
        case custom
    }
    var windowChoice = WindowChoice.app
    var windowWidth = ""
    var windowHeight = ""
    /// The size was chosen at random when the profile was made (Settings → New Profiles).
    var windowSizeIsRandom = false

    /// The size chosen, nil for none or for numbers that are not a window.
    var windowSize: WindowSize? {
        switch windowChoice {
        case .app: return nil
        case .mac(let screen): return .mac(screen: screen)
        case .custom:
            guard let width = Int(windowWidth.trimmingCharacters(in: .whitespaces)),
                  let height = Int(windowHeight.trimmingCharacters(in: .whitespaces)) else { return nil }
            let size = WindowSize.custom(width: width, height: height)
            return size.isValid ? size : nil
        }
    }

    mutating func setWindowSize(_ size: WindowSize?) {
        switch size {
        case nil: windowChoice = .app
        case .mac(let screen)?: windowChoice = .mac(screen)
        case let .custom(width, height)?:
            windowChoice = .custom
            windowWidth = String(width)
            windowHeight = String(height)
        }
    }

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

    /// `savedProxies`: the list's proxies — a profile whose proxy is one of them, reached the same
    /// way (`ProxyList.sameConnection`), opens on "From the list" with it chosen.
    init(name: String, configuration c: ProfileConfiguration, savedProxies: [ProxyListEntry] = []) {
        self.name = name
        startURL = c.startURL?.absoluteString ?? ""
        deviceGenerationID = c.deviceGenerationID ?? DeviceGenerations.defaultID
        customUserAgent = c.userAgent != nil
        userAgent = c.userAgent ?? ""
        if let proxy = c.proxy {
            proxyLine = ProxyLine(proxy: proxy)
            proxyExcludedDomains = proxy.excludedDomains.joined(separator: ", ")
            if let entry = savedProxies.first(where: { $0.kindKnown && ProxyList.sameConnection($0.proxy, proxy) }) {
                proxyMode = .saved
                savedProxy = entry
            } else {
                proxyMode = .new
            }
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
        safeBrowsing = c.safeBrowsingEnabled
        historyEnabled = c.historyEnabled
        historyRetentionDays = c.historyRetentionDays ?? 0
        passwordAutoFill = c.passwordAutoFill
        syncCookies = c.syncCookies
        searchEngine = c.searchEngine ?? .standard
        tags = c.tags
        notes = c.notes
        avatarColor = c.avatar?.color
        avatarLetters = c.avatar?.letters ?? ""
        setWindowSize(c.windowSize)
    }

    var hasProxy: Bool { proxyMode != .direct }

    /// The proxy the profile is to use, when it is chosen and its type is known.
    var chosenProxy: ProxySettings? {
        switch proxyMode {
        case .direct: return nil
        case .saved: return savedProxy?.usableProxy
        case .new: return proxyLine.proxy
        }
    }

    /// "From the list": `entry`. What its last check found about where it exits becomes what the
    /// profile knows, as when the list assigns it (`ProfileConfiguration.assigning`).
    mutating func choose(_ entry: ProxyListEntry) {
        savedProxy = entry
        remember(entry.lastCheck, for: entry.proxy)
    }

    /// Keeps where `proxy` exits as `check` found it — the header, the location card and the time
    /// zone show it before the first launch — as a launch's lookup through it would remember it:
    /// the exit IP only while the profile asks to be warned when it changes.
    mutating func remember(_ check: ProxyCheckResult?, for proxy: ProxySettings) {
        guard var location = check?.location(for: proxy) else { return }
        if !warnOnProxyIPChange { location.exitIP = nil }
        lastProxyLocation = location
    }

    /// The proxy of the chosen mode (nil: none). Throws, in words for the person, when "From the
    /// list" has none chosen, or the line is not one proxy, or its type is not known yet.
    func makeProxy() throws -> ProxySettings? {
        var proxy: ProxySettings
        switch proxyMode {
        case .direct:
            return nil
        case .saved:
            guard let entry = savedProxy else { throw DraftProblem(L("editor.proxy.error.noneChosen")) }
            guard let usable = entry.usableProxy else { throw DraftProblem(L("editor.proxy.error.kindUnknown")) }
            proxy = usable
        case .new:
            switch proxyLine.reading {
            case .empty: throw DraftProblem(L("editor.proxy.error.empty"))
            case .problem(let message): throw DraftProblem(message)
            case .kindUnknown: throw DraftProblem(L("editor.proxy.error.kindUnknown"))
            case .proxy(let read, _): proxy = read
            }
        }
        proxy.excludedDomains = proxyExcludedDomains.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return proxy
    }

    /// "New" holds a proxy without a scheme whose type no check has found yet: Save checks it first.
    var needsKindCheck: Bool {
        guard proxyMode == .new, case .kindUnknown = proxyLine.reading else { return false }
        return true
    }

    /// What the last lookup through the proxy found, while these fields still describe that proxy
    /// (`ProxyLocation.endpoint(of:)`): nil once host, port or credentials name another one.
    var knownProxyLocation: ProxyLocation? {
        guard let location = lastProxyLocation, let proxy = chosenProxy else { return nil }
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
        configuration.safeBrowsingEnabled = safeBrowsing
        configuration.historyEnabled = historyEnabled
        configuration.historyRetentionDays = historyRetentionDays == 0 ? nil : historyRetentionDays
        // The "Never for This Website" list is the browser's; saving keeps the stored one
        // (ProfileConfiguration.keepingStoredState).
        configuration.passwordAutoFill = passwordAutoFill
        configuration.syncCookies = syncCookies
        // The standard engine is stored as none, as every profile from before the choice has it:
        // saving such a profile unchanged is no edit.
        configuration.searchEngine = searchEngine == .standard ? nil : searchEngine
        configuration.tags = ProfileTags.normalized(tags)
        configuration.notes = String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ProfileConfiguration.maximumNotesLength))
        configuration.avatar = avatarStyle
        if windowChoice == .custom && windowSize == nil {
            throw CoreError.invalidConfiguration(String(format: L("editor.window.error"), WindowSize.minimumWidth,
                                                        WindowSize.maximumWidth, WindowSize.minimumHeight, WindowSize.maximumHeight))
        }
        configuration.windowSize = windowSize
        try configuration.validate()
        return configuration
    }
}

/// What is wrong with a draft, in words for the person (shown as it is, without a prefix).
struct DraftProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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
    @State private var topic: ProfileEditorForm.Topic = .profile
    /// A check run from the editor: Check, or Save finding a proxy's type.
    @State private var checking = false
    @ObservedObject private var tunnel = TunnelManager.shared

    /// The glyph colour of a profile not created yet (it has no id).
    private static let newProfileAvatarID = UUID(uuid: (0x4C, 0x55, 0x4D, 0x45, 0x4E, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))

    var body: some View {
        Group {
            // The list as it changes: a check from here shows in its rows.
            if let proxies = model.proxyList {
                ObservingProxyList(proxies: proxies) { form(saved: $0.entries) }
            } else {
                form(saved: [])
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showingTunnel) { TunnelSettingsView() }
    }

    private func form(saved: [ProxyListEntry]) -> some View {
        ProfileEditorForm(draft: $draft, topic: $topic, isNew: target.isNew, avatarID: avatarID, error: error,
                          tunnelCarriesWebRTC: tunnel.canCarryWebRTC,
                          onCancel: { dismiss() }, onSave: save, onTunnelSettings: { showingTunnel = true },
                          savedProxies: saved, checkingProxy: checking, onCheckProxy: checkProxy,
                          knownTags: knownTags, visibleScreen: WindowSizing.visibleScreen)
    }

    /// The tags of every profile, each once, for the tag field to offer.
    private var knownTags: [String] {
        var seen = Set<String>()
        return model.details.values.flatMap(\.tags)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
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
                draft = ProfileDraft(name: summary.name, configuration: try model.configuration(for: summary.id),
                                     savedProxies: model.proxyList?.entries ?? [])
            } catch {
                self.error = String(format: L("editor.error.decrypt"), error.localizedDescription)
            }
        } else {
            draft.name = String(format: L("editor.defaultName"), model.profiles.count + 1)
            // Settings → New Profiles.
            draft.matchProxyLocation = model.settings.newProfileMatchesConnection
            draft.searchEngine = model.settings.newProfileSearchEngine
            if model.settings.newProfileRandomWindowSize, let visible = WindowSizing.visibleScreen {
                var generator = SystemRandomNumberGenerator()
                draft.setWindowSize(WindowSize.randomSafe(fitting: (Int(visible.width), Int(visible.height)), using: &generator))
                draft.windowSizeIsRandom = true
            }
        }
    }

    /// Check: a proxy of the list through the list — what it finds is the entry's, as a check in
    /// the Proxies sheet — or the line of "New" on its own (nothing is added to the list).
    private func checkProxy() {
        guard !checking else { return }
        switch draft.proxyMode {
        case .direct:
            return
        case .saved:
            guard let entry = draft.savedProxy else { return }
            checking = true
            Task {
                let result: ProxyCheckResult
                if let proxies = model.proxyList {
                    result = await proxies.checkProfileProxy(entry.proxy)
                } else {
                    result = await ProxyChecker.check(entry.proxy)
                }
                checking = false
                refreshSavedProxy()
                // Still the one chosen: where it exits is what the profile knows now.
                if let chosen = draft.savedProxy, chosen.id == entry.id { draft.remember(result, for: chosen.proxy) }
            }
        case .new:
            guard let proxy = draft.proxyLine.checkable else { return }
            checking = true
            Task {
                let result = await ProxyChecker.check(proxy)
                checking = false
                take(result, for: proxy)
            }
        }
    }

    /// A check of the line's proxy: kept by the line, and — while the line still names that proxy —
    /// where it exits is what the profile knows now.
    private func take(_ result: ProxyCheckResult, for proxy: ProxySettings) {
        draft.proxyLine.check = ProxyLine.Check(proxy: proxy, result: result)
        if draft.proxyLine.currentCheck?.proxy == proxy, let resolved = draft.proxyLine.proxy {
            draft.remember(result, for: resolved)
        }
    }

    /// "From the list" holds the entry as it was when chosen: a check since may have found another
    /// type, and the list may have lost it.
    private func refreshSavedProxy() {
        guard let chosen = draft.savedProxy, let proxies = model.proxyList else { return }
        draft.savedProxy = proxies.list.entry(chosen.id)
    }

    private func save() {
        guard !checking else { return }
        error = nil
        // A line without a scheme whose type no check has found: Save checks it first — both
        // handshakes are tried, and the one that answers is the type. A proxy that answers neither
        // way is not saved; the field says why.
        if draft.needsKindCheck, let proxy = draft.proxyLine.checkable {
            checking = true
            Task {
                let result = await ProxyChecker.check(proxy)
                checking = false
                take(result, for: proxy)
                guard !draft.needsKindCheck else {
                    if draft.proxyLine.currentCheck?.proxy == proxy { error = L("editor.proxy.error.kindNotFound") }
                    return
                }
                // The type is known now; a proxy that does not work is not saved unseen: the check
                // is under the field, and Save again saves it as it is.
                guard result.isAlive else {
                    error = L("editor.proxy.error.notWorking")
                    return
                }
                save()
            }
            return
        }
        if draft.proxyMode == .saved { refreshSavedProxy() }
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

/// Shows `content` again whenever the proxy list changes.
struct ObservingProxyList<Content: View>: View {
    @ObservedObject var proxies: ProxyListModel
    @ViewBuilder let content: (ProxyListModel) -> Content

    var body: some View { content(proxies) }
}
