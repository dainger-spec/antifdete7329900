import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// Where the time zone and language come from; Manual and Random use `timeZone` and
    /// `language` ("" for language: this Mac's).
    var localeMode = LocaleSource.connection
    var timeZone = TimeZone.current.identifier
    var language = ""
    var matchProxyLocation = true
    /// Carried through unchanged (a cache for launching; see ProfileConfiguration).
    var lastProxyLocation: ProxyLocation?
    var warnOnProxyIPChange = false
    var menusInAppLanguage = false
    /// An iPhone view's full disguise (ProfileConfiguration.phoneDisguise); on by default.
    var phoneFullDisguise = true
    var webRTC: WebRTCPolicy = .disabled
    /// What a page's camera (and, with it, the microphone) is handed; `.off` by default
    /// (`CameraSubstitution`). Bound field by field in the editor's Camera part.
    var camera = CameraSubstitution.off
    /// The resolution and frame rate as the editor holds them, parsed on Save.
    var cameraWidth = "1280"
    var cameraHeight = "720"
    var cameraFrameRate = "30"
    /// Video trim, in seconds, as the editor holds them (0 end = to the end).
    var cameraVideoStart = "0"
    var cameraVideoEnd = "0"
    /// The name of a freshly chosen image or video, for the editor to show; nil when none was
    /// chosen this session (its bytes may still be set, from the stored profile).
    var cameraImageName: String?
    var cameraVideoName: String?
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

    /// The Safari version the profile names in its User-Agent; nil: this Mac's (Auto).
    var safariVersion: String?
    var localRequests = LocalRequests.protected
    /// Cookies to import when the editor saves: pasted as text, or a file read
    /// (`CookieImporter`), with what reading them found.
    var cookieText = ""
    var cookieFileName: String?
    var cookieReport: CookieImportReport?

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
        localeMode = c.effectiveLocaleSource
        timeZone = c.timeZoneIdentifier ?? TimeZone.current.identifier
        language = c.languageOverride ?? ""
        matchProxyLocation = c.matchProxyLocation
        // With a proxy it does not follow and nothing of its own: this Mac's time zone and
        // languages, which is a choice of its own — Manual, with this Mac's values.
        if localeMode == .connection && !c.matchProxyLocation && c.proxy != nil { localeMode = .manual }
        lastProxyLocation = c.lastProxyLocation
        warnOnProxyIPChange = c.warnOnProxyIPChange
        menusInAppLanguage = c.menusInAppLanguage
        phoneFullDisguise = c.phoneDisguise == .full
        webRTC = c.webRTCPolicy
        camera = c.cameraSubstitution
        cameraWidth = String(c.cameraSubstitution.width)
        cameraHeight = String(c.cameraSubstitution.height)
        cameraFrameRate = String(c.cameraSubstitution.frameRate)
        cameraVideoStart = String(format: "%g", c.cameraSubstitution.playback.startOffset)
        cameraVideoEnd = String(format: "%g", c.cameraSubstitution.playback.endOffset)
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
        safariVersion = c.safariVersion
        localRequests = c.localRequests
    }

    var hasProxy: Bool { proxyMode != .direct }

    /// Reads what was pasted as a cookie export, as Import Cookies reads a file.
    mutating func readCookieText() {
        let text = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        cookieFileName = nil
        cookieReport = text.isEmpty ? nil : CookieImporter.read(Data(text.utf8))
    }

    /// A cookie file read instead of pasted text.
    mutating func takeCookieFile(named name: String, report: CookieImportReport) {
        cookieText = ""
        cookieFileName = name
        cookieReport = report
    }

    mutating func clearCookies() {
        cookieText = ""
        cookieFileName = nil
        cookieReport = nil
    }

    /// The place a random choice picked, when the time zone and language are one.
    var randomPlace: LocalePlaces.Place? { LocalePlaces.place(timeZone: timeZone, language: language) }

    /// Random: another place's time zone and language.
    mutating func pickRandomPlace() {
        var generator = SystemRandomNumberGenerator()
        let place = LocalePlaces.random(using: &generator, otherThan: localeMode == .random ? randomPlace : nil)
        timeZone = place.timeZone
        language = place.language
        localeMode = .random
    }

    /// Geolocation back to Deny, its coordinates forgotten.
    mutating func resetGeolocation() {
        geoMode = .deny
        latitude = ""
        longitude = ""
        accuracy = "50"
    }

    /// The camera substitution the profile is to use, with its numbers parsed and a device secret
    /// made when it is first turned on. Throws, in words for the person, when a number is not one.
    func makeCamera() throws -> CameraSubstitution {
        var cam = camera
        cam.deviceLabel = String(cam.deviceLabel.prefix(CameraSubstitution.maxDeviceLabelLength))
        guard cam.isActive else { return .off }
        guard let width = Int(cameraWidth.trimmingCharacters(in: .whitespaces)),
              let height = Int(cameraHeight.trimmingCharacters(in: .whitespaces)),
              let rate = Int(cameraFrameRate.trimmingCharacters(in: .whitespaces)) else {
            throw DraftProblem(L("editor.camera.error.numbers"))
        }
        cam.width = width
        cam.height = height
        cam.frameRate = rate
        cam.playback.startOffset = max(0, Double(cameraVideoStart.trimmingCharacters(in: .whitespaces)) ?? 0)
        cam.playback.endOffset = max(0, Double(cameraVideoEnd.trimmingCharacters(in: .whitespaces)) ?? 0)
        if cam.deviceSecret.isEmpty { cam.deviceSecret = CameraSubstitution.newDeviceSecret() }
        return cam
    }

    /// A chosen image for the substituted camera (its bytes, read by the host view).
    mutating func takeCameraImage(named name: String, data: Data, type: String) {
        camera.imageData = data
        camera.imageType = type
        camera.source = .image
        cameraImageName = name
    }

    /// A chosen video for the substituted camera.
    mutating func takeCameraVideo(named name: String, data: Data, type: String) {
        camera.videoData = data
        camera.videoType = type
        camera.source = .video
        cameraVideoName = name
    }

    mutating func clearCameraImage() {
        camera.imageData = nil
        camera.imageType = nil
        cameraImageName = nil
    }

    mutating func clearCameraVideo() {
        camera.videoData = nil
        camera.videoType = nil
        cameraVideoName = nil
    }

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

    /// At the profile's last launch no geolocation service answered through its proxy (the
    /// manager knows; not saved): the location card says so.
    var proxyLocationLookupFailed = false

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
        switch localeMode {
        case .connection:
            configuration.timeZoneIdentifier = nil
            configuration.languageOverride = nil
            configuration.matchProxyLocation = true
        case .manual, .random:
            configuration.timeZoneIdentifier = timeZone
            configuration.languageOverride = language.isEmpty ? nil : language
            configuration.matchProxyLocation = false
        }
        // Manual and the connection are said by the fields themselves; only Random is written.
        configuration.localeSource = localeMode == .random ? .random : nil
        configuration.lastProxyLocation = lastProxyLocation
        configuration.warnOnProxyIPChange = warnOnProxyIPChange
        configuration.menusInAppLanguage = menusInAppLanguage
        configuration.phoneDisguise = phoneFullDisguise ? .full : .engineOnly
        configuration.webRTCPolicy = webRTC
        configuration.cameraSubstitution = try makeCamera()
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
        configuration.safariVersion = safariVersion
        configuration.localRequests = localRequests
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
    @State private var showingGuard = false
    @State private var showingWhatSitesSee = false
    @State private var topic: ProfileEditorForm.Topic = .profile
    /// A check run from the editor: Check, or Save finding a proxy's type.
    @State private var checking = false
    @State private var choosingCookieFile = false
    @State private var choosingCameraImage = false
    @State private var choosingCameraVideo = false
    /// Feeds the separate camera preview window live (`CameraPreviewWindowController`).
    @StateObject private var cameraMirror = CameraMirror()
    /// The cookies pasted are being imported after Save: no second Save meanwhile.
    @State private var savingCookies = false
    /// The profile's settings could not be read: the form shows defaults, not them, and is never
    /// saved over them (R1). The Profiles list does not open the editor then; this is for settings
    /// that went bad while it was opening.
    @State private var settingsUnreadable = false
    /// The versions of the settings kept beside them (R4, R2), and the one the person asked to remove.
    @State private var keptVersions: [KeptSettings] = []
    @State private var removingVersion: String?
    @ObservedObject private var networkGuard = NetworkGuard.shared

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
        .onChange(of: draft.camera) { cameraMirror.camera = draft.camera }
        .sheet(isPresented: $showingGuard) { NetworkGuardSettingsView() }
        .sheet(isPresented: $showingWhatSitesSee) {
            if case .existing(let profile) = target {
                WhatSitesSeeView(name: profile.name, snapshot: WhatSitesSee(profileID: profile.id, manager: { model.manager },
                                                                            launch: { await model.launch($0) }),
                                 mobileView: DeviceGenerations.resolved(id: draft.deviceGenerationID).platform != .macOS)
            }
        }
        .fileImporter(isPresented: $choosingCookieFile, allowedContentTypes: [.json, .plainText, .text, .data]) { result in
            if case let .success(url) = result { readCookieFile(url) }
        }
        .fileImporter(isPresented: $choosingCameraImage, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result { readCameraMedia(url, isVideo: false) }
        }
        .fileImporter(isPresented: $choosingCameraVideo, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            if case let .success(url) = result { readCameraMedia(url, isVideo: true) }
        }
        .alert(L("editor.versions.removeTitle"), isPresented: Binding(get: { removingVersion != nil },
                                                                      set: { if !$0 { removingVersion = nil } })) {
            Button(L("editor.versions.remove"), role: .destructive) {
                if let file = removingVersion { removeVersion(file) }
                removingVersion = nil
            }
            Button(L("common.cancel"), role: .cancel) { removingVersion = nil }
        } message: {
            Text(L("editor.versions.removeMessage"))
        }
    }

    /// An image or video chosen for the substituted camera: its bytes are read into the draft (the
    /// app reads the file; the profile's pages never touch the disk). Too large, or unreadable, and
    /// the camera part shows why.
    private func readCameraMedia(_ url: URL, isVideo: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limit = isVideo ? CameraSubstitution.maxVideoBytes : CameraSubstitution.maxImageBytes
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= limit else {
                error = String(format: L("editor.camera.error.tooLarge"), limit / (1024 * 1024))
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? (isVideo ? "video/mp4" : "image/jpeg")
            if isVideo { draft.takeCameraVideo(named: url.lastPathComponent, data: data, type: type) }
            else { draft.takeCameraImage(named: url.lastPathComponent, data: data, type: type) }
            error = nil
        } catch {
            self.error = String(format: L("editor.camera.error.read"), url.lastPathComponent)
        }
    }

    /// Opens the separate live preview window, which follows these settings and writes the crop and
    /// adjustments back.
    private func openCameraPreview() {
        cameraMirror.camera = draft.camera
        let cameraBinding = $draft.camera
        CameraPreviewWindowController.shared.present(mirror: cameraMirror) { camera in
            cameraBinding.wrappedValue = camera
        }
    }

    /// A cookie file chosen or dropped, read as Import Cookies reads one.
    private func readCookieFile(_ url: URL) {
        Task {
            let report = await model.readCookieFile(url)
            draft.takeCookieFile(named: url.lastPathComponent, report: report)
        }
    }

    private func form(saved: [ProxyListEntry]) -> some View {
        ProfileEditorForm(draft: $draft, topic: $topic, isNew: target.isNew, avatarID: avatarID, error: error,
                          guardReady: networkGuard.state == .ready,
                          onCancel: { dismiss() }, onSave: save, onGuardSettings: { showingGuard = true },
                          savedProxies: saved, checkingProxy: checking, onCheckProxy: checkProxy,
                          knownTags: knownTags, visibleScreen: WindowSizing.visibleScreen,
                          onChooseCookieFile: { choosingCookieFile = true }, onDropCookieFile: readCookieFile,
                          onChooseCameraImage: { choosingCameraImage = true },
                          onChooseCameraVideo: { choosingCameraVideo = true },
                          onOpenCameraPreview: openCameraPreview,
                          cameraAllowed: model.allowsCamera,
                          isSaving: savingCookies, saveRefused: settingsUnreadable,
                          keptVersions: keptVersions, onUseVersion: useVersion, onRemoveVersion: { removingVersion = $0 },
                          onWhatSitesSee: target.isNew ? nil : { showingWhatSitesSee = true })
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
                draft.proxyLocationLookupFailed = model.manager?.proxyLocationUnknown.contains(summary.id) ?? false
                keptVersions = model.keptSettings(for: summary.id)
            } catch {
                settingsUnreadable = true
                self.error = String(format: L("editor.error.decrypt"), error.localizedDescription)
            }
        } else {
            draft.name = String(format: L("editor.defaultName"), model.profiles.count + 1)
            // Settings → New Profiles.
            if !model.settings.newProfileMatchesConnection {
                draft.localeMode = .manual
            }
            draft.searchEngine = model.settings.newProfileSearchEngine
            draft.localRequests = model.settings.newProfileBlocksLocalRequests ? .protected : .allowed
            if model.settings.newProfileRandomWindowSize, let visible = WindowSizing.visibleScreen {
                var generator = SystemRandomNumberGenerator()
                draft.setWindowSize(WindowSize.randomSafe(fitting: (Int(visible.width), Int(visible.height)), using: &generator))
                draft.windowSizeIsRandom = true
            }
        }
    }

    /// "Use this version": the kept version becomes the profile's settings at once, the settings it
    /// replaces kept in its place; the form shows them. What the form held unsaved goes with it.
    private func useVersion(_ file: String) {
        guard case .existing(let summary) = target else { return }
        do {
            try model.useKeptSettings(file, for: summary.id)
            draft = ProfileDraft(name: summary.name, configuration: try model.configuration(for: summary.id),
                                 savedProxies: model.proxyList?.entries ?? [])
            keptVersions = model.keptSettings(for: summary.id)
            error = nil
        } catch {
            self.error = errorText(error)
        }
    }

    /// Removes a kept version once the person said so in the alert.
    private func removeVersion(_ file: String) {
        guard case .existing(let summary) = target else { return }
        do {
            try model.removeKeptSettings(file, for: summary.id)
            keptVersions = model.keptSettings(for: summary.id)
        } catch {
            self.error = errorText(error)
        }
    }

    /// Check: a proxy of the list through the list — what it finds is the entry's, as a check in
    /// the Proxies section — or the line of "New" on its own (nothing is added to the list).
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
        guard !checking, !savingCookies, !settingsUnreadable else { return }
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
            let id: UUID?
            switch target {
            case .new:
                id = try model.createProfile(name: draft.name, configuration: configuration)
            case .existing(let summary):
                try model.updateProfile(summary.id, name: draft.name, configuration: configuration)
                id = summary.id
            }
            // The cookies pasted or dropped: into the profile now if it runs, else queued
            // (encrypted) for its next launch, before its first page loads — as Import Cookies.
            if let id, let cookies = draft.cookieReport?.cookies, !cookies.isEmpty {
                savingCookies = true
                Task {
                    do {
                        _ = try await model.importCookies(cookies, into: id)
                    } catch {
                        model.showError(String(format: L("editor.cookies.error"), error.localizedDescription))
                    }
                    dismiss()
                }
                return
            }
            dismiss()
        } catch {
            self.error = errorText(error)
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
