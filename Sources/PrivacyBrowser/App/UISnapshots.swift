import AppKit
import BrowserCore
import SwiftUI

/// `PrivacyBrowser --render-ui-snapshots <folder>`: renders the app's screens with sample data
/// into PNG files, so the design can be reviewed from CI (no vault, no WebKit, no network).
///
/// Each screen is shown in a real window like the app's own (dark, title bar transparent over
/// full-size content) and captured with its AppKit controls. Pictures cannot show whether the
/// controls under the transparent title bar still take clicks, so that is checked too: a click is
/// posted onto the header's New Profile button, and one onto the sidebar's Lock button as the
/// control. Exit code 0 when every capture was written and both clicks arrived.
@MainActor
enum UISnapshots {
    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let index = arguments.firstIndex(of: "--render-ui-snapshots"), arguments.indices.contains(index + 1) else {
            print("usage: PrivacyBrowser --render-ui-snapshots <folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Localization.applyProcessLanguage()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            print("SNAPSHOTS TIMEOUT after 180 s")
            exit(3)
        }
        Task { @MainActor in
            let problems = await run(into: folder)
            print("SNAPSHOTS \(problems == 0 ? "DONE" : "FAILED (\(problems))") in \(folder.path)")
            exit(problems == 0 ? 0 : 1)
        }
        app.run()
    }

    /// The Settings window, a picture per section; Updates three times: a release downloaded and
    /// ready, with its notes; up to date with automatic checks off; and a build without an update
    /// feed. Previews fetch nothing.
    private static func settings(into folder: URL, model: AppModel) async -> Int {
        var problems = 0
        for section in SettingsSection.allCases where section != .updates {
            problems += await Shot(name: "settings-\(section.rawValue)", size: SettingsView.size, titled: false) {
                SettingsView(section: section).environmentObject(model)
            }.capture(into: folder)
        }
        let configuration = AppUpdater.Configuration(
            feed: URL(string: "https://updates.example/privacybrowser/appcast.json")!, keys: [:], version: "0.1.0",
            build: BuildVersion("1")!, bundleIdentifier: "dev.local.PrivacyBrowser",
            app: URL(fileURLWithPath: "/Applications/PrivacyBrowser.app"),
            staging: URL(fileURLWithPath: "/nonexistent/updates"))
        let item = AppcastItem(
            version: "0.2.0", build: "2", minimumSystemVersion: "14.0",
            url: URL(string: "https://updates.example/privacybrowser/PrivacyBrowser-0.2.0.zip")!, length: 48_210_944,
            sha256: String(repeating: "0", count: 64), keyID: "0123456789abcdef", edSignature: Data(count: 64),
            publishedAt: Date().addingTimeInterval(-2 * 3600),
            notes: "• Safari's chrome: the proxy hook holds on macOS 27.\n• Proxies: a proxy that stays silent after the connection is named as such.\n"
                + "• Files a newer version wrote are refused, never written over.")
        let ready = AppUpdater(preview: .ready(item), configuration: configuration)
        problems += await Shot(name: "settings-updates-ready", size: SettingsView.size, titled: false) {
            SettingsView(section: .updates, previewUpdater: ready).environmentObject(model)
        }.capture(into: folder)
        let upToDate = AppUpdater(preview: .upToDate(checkedAt: Date().addingTimeInterval(-25 * 60)), configuration: configuration,
                                  automaticChecks: false, installPolicy: .notifyOnly)
        problems += await Shot(name: "settings-updates-up-to-date", size: SettingsView.size, titled: false) {
            SettingsView(section: .updates, previewUpdater: upToDate).environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "settings-updates-unavailable", size: SettingsView.size, titled: false) {
            SettingsView(section: .updates).environmentObject(model)
        }.capture(into: folder)
        return problems
    }

    private static func run(into folder: URL) async -> Int {
        var problems = 0
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("FAIL cannot create \(folder.path): \(error)")
            return 1
        }
        NSApp.activate(ignoringOtherApps: true)
        let rows = sampleRows()
        let clicks = ClickLog()
        var actions = ProfileActions()
        actions.newProfile = { clicks.newProfile += 1 }
        actions.lock = { clicks.lock += 1 }

        // The Profiles window, wide enough for every column.
        let profiles = Shot(name: "profiles", size: CGSize(width: 1180, height: 740)) {
            ProfilesPreview(rows: rows, sync: .synced(Date().addingTimeInterval(-4 * 60)), actions: actions)
        }
        problems += await profiles.capture(into: folder) { window in
            await clickTest(window, clicks: clicks)
        }
        problems += await Shot(name: "profiles-narrow", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620)) {
            ProfilesPreview(rows: rows, sync: .off, isWorking: true)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-proxied", size: CGSize(width: 1180, height: 560)) {
            ProfilesPreview(rows: rows, filter: .proxied, sync: .failed)
        }.capture(into: folder)
        // The command palette (⌘K), as it opens and with something typed.
        let paletteCommands = paletteSample(rows)
        problems += await Shot(name: "palette", size: CommandPaletteView.size, titled: false) {
            CommandPaletteView(commands: paletteCommands)
        }.capture(into: folder)
        problems += await Shot(name: "palette-search", size: CommandPaletteView.size, titled: false) {
            CommandPaletteView(commands: paletteCommands, query: "north")
        }.capture(into: folder)
        // What sites see: before a snapshot, its differences, every signal, and Safari silent.
        func seen(comparedWithSafari: Bool = true) -> WhatSitesSee {
            let snapshot = WhatSitesSee(profileID: UUID(), manager: { nil }, launch: { _ in })
            let sample = whatSitesSeeSample()
            snapshot.show(SiteComparison.compare(profile: sample.profile, safari: comparedWithSafari ? sample.safari : nil),
                          comparedWithSafari: comparedWithSafari, takenAt: Date(timeIntervalSince1970: 1_793_000_000))
            return snapshot
        }
        problems += await Shot(name: "what-sites-see-empty", size: WhatSitesSeeView.size, titled: false) {
            WhatSitesSeeView(name: "Northwind", snapshot: WhatSitesSee(profileID: UUID(), manager: { nil }, launch: { _ in }))
        }.capture(into: folder)
        problems += await Shot(name: "what-sites-see", size: WhatSitesSeeView.size, titled: false) {
            WhatSitesSeeView(name: "Northwind", snapshot: seen())
        }.capture(into: folder)
        problems += await Shot(name: "what-sites-see-all", size: WhatSitesSeeView.size, titled: false) {
            WhatSitesSeeView(name: "Northwind", snapshot: seen(), onlyDifferences: false)
        }.capture(into: folder)
        problems += await Shot(name: "what-sites-see-no-safari", size: WhatSitesSeeView.size, titled: false) {
            WhatSitesSeeView(name: "Northwind", snapshot: seen(comparedWithSafari: false), onlyDifferences: false)
        }.capture(into: folder)
        // A tag chosen in the sidebar; the search also finds a profile by its tags and notes.
        problems += await Shot(name: "profiles-tag", size: CGSize(width: 1180, height: 560)) {
            ProfilesPreview(rows: rows, filter: .tag("ads"), sync: .off)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-search-notes", size: CGSize(width: 1180, height: 520)) {
            ProfilesPreview(rows: rows, search: "renews", sync: .off)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-empty", size: CGSize(width: 1180, height: 640)) {
            ProfilesPreview(rows: [], sync: .notYet)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-no-matches", size: CGSize(width: 1180, height: 520)) {
            ProfilesPreview(rows: rows, search: "zzz", sync: .syncing)
        }.capture(into: folder)
        // The profile editor: one screen, a picture opened on each of its parts (sheets have no
        // title bar).
        let draft = sampleDraft()
        var newProfile = ProfileDraft()
        newProfile.name = String(format: L("editor.defaultName"), 8)
        var labelled = draft
        labelled.tags = ["ads", "US", "warm-up"]
        labelled.notes = "Bought 2026-10 from Example Networks, renews monthly. Two-factor on the phone in the drawer."
        labelled.avatarColor = 5
        labelled.avatarLetters = "NW"
        var directAllowed = newProfile
        directAllowed.name = "Local tools"
        directAllowed.localRequests = .allowed
        var withCookies = newProfile
        withCookies.cookieText = #"[{"domain":".example.org","name":"session","value":"a1b2c3","path":"/","secure":true,"expirationDate":4102444800},{"domain":"","name":"broken"}]"#
        withCookies.readCookieText()
        var namedVersion = draft
        namedVersion.safariVersion = SafariVersions.recent.last
        var location = draft
        location.geoMode = .fixed
        location.latitude = "52.52"
        location.longitude = "13.405"
        location.localeMode = .manual
        location.timeZone = "Europe/Berlin"
        location.language = "de-DE"
        var randomLocale = draft
        randomLocale.localeMode = .random
        randomLocale.timeZone = "Asia/Tokyo"
        randomLocale.language = "ja-JP"
        var ephemeral = draft
        ephemeral.ephemeral = true
        let editors: [(String, ProfileDraft, ProfileEditorForm.Topic, Bool, String?)] = [
            ("editor-profile-new", newProfile, .profile, true, nil),
            ("editor-profile-labelled", labelled, .profile, false, nil),
            ("editor-identity", draft, .identity, false, nil),
            ("editor-identity-safari-version", namedVersion, .identity, false, nil),
            ("editor-location", location, .location, false, nil),
            ("editor-location-random-mismatch", randomLocale, .location, false, nil),
            ("editor-privacy", draft, .privacy, false, nil),
            ("editor-privacy-direct-allowed", directAllowed, .privacy, false, nil),
            ("editor-data-ephemeral", ephemeral, .data, false, L("editor.proxy.error.kindUnknown")),
            ("editor-data-cookies-new", withCookies, .data, true, nil),
        ]
        for (name, sample, topic, isNew, error) in editors {
            problems += await Shot(name: name, size: ProfileEditorForm.size, titled: false) {
                EditorPreview(draft: sample, topic: topic, isNew: isNew, error: error)
            }.capture(into: folder)
        }
        // The window size, against a sample screen (a 16-inch MacBook Pro's, less menu bar and
        // Dock; a 13-inch's for the one that does not fit).
        var preset = draft
        preset.setWindowSize(.mac(screen: .pro14))
        var random = newProfile
        random.setWindowSize(.custom(width: 1284, height: 806))
        random.windowSizeIsRandom = true
        var tooLarge = draft
        tooLarge.setWindowSize(.mac(screen: .pro16))
        let windows: [(String, ProfileDraft, Bool, CGSize)] = [
            ("editor-window-preset", preset, false, CGSize(width: 1728, height: 1024)),
            ("editor-window-random", random, true, CGSize(width: 1728, height: 1024)),
            ("editor-window-too-large", tooLarge, false, CGSize(width: 1470, height: 862)),
        ]
        for (name, sample, isNew, visible) in windows {
            problems += await Shot(name: name, size: ProfileEditorForm.size, titled: false) {
                EditorPreview(draft: sample, topic: .window, isNew: isNew, visibleScreen: visible)
            }.capture(into: folder)
        }
        problems += await proxyFieldInEditor(into: folder, draft: draft)
        // The other sheets, as they open.
        let model = AppModel()
        if let northwind = sampleSummary(name: "Northwind", id: rows[1].id) {
            problems += await Shot(name: "sheet-passwords-locked", size: CGSize(width: 780, height: 560), titled: false) {
                PasswordListView(profile: northwind).environmentObject(model)
            }.capture(into: folder)
            problems += await Shot(name: "sheet-cookie-import", size: CGSize(width: 680, height: 560), titled: false) {
                CookieImportView(profile: northwind).environmentObject(model)
            }.capture(into: folder)
            problems += await Shot(name: "sheet-cookie-export", size: CGSize(width: 480, height: 400), titled: false) {
                CookieExportView(profile: northwind).environmentObject(model)
            }.capture(into: folder)
            problems += await Shot(name: "sheet-profile-export", size: CGSize(width: 480, height: 420), titled: false) {
                ProfileExportView(profile: northwind).environmentObject(model)
            }.capture(into: folder)
            problems += await Shot(name: "sheet-profile-import", size: CGSize(width: 480, height: 300), titled: false) {
                ProfileImportView().environmentObject(model)
            }.capture(into: folder)
        } else {
            print("FAIL could not make a sample profile summary")
            problems += 1
        }
        problems += await Shot(name: "sheet-sync", size: CGSize(width: 540, height: 460), titled: false) {
            SyncSettingsView().environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-automation", size: CGSize(width: 560, height: 620), titled: false) {
            AutomationSettingsView().environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-change-password", size: CGSize(width: 420, height: 330), titled: false) {
            ChangePasswordView().environmentObject(model)
        }.capture(into: folder)
        problems += await settings(into: folder, model: model)
        problems += await proxyList(into: folder)
        // A real browser window of a running profile (WebKit, toolbar, tab strip, start page).
        problems += await browserWindows(into: folder)
        // The launch screen (the Profiles window before unlocking), also while the vault opens.
        let lockModel = AppModel()
        problems += await Shot(name: "launch-unlock", size: CGSize(width: 1180, height: 740)) {
            UnlockView().environmentObject(lockModel)
        }.capture(into: folder)
        problems += await Shot(name: "launch-setup", size: CGSize(width: 1180, height: 740)) {
            SetupView().environmentObject(lockModel)
        }.capture(into: folder)
        problems += await Shot(name: "launch-working", size: CGSize(width: 1180, height: 740)) {
            LockScreen(title: L("unlock.title"), subtitle: L("unlock.subtitle"), isWorking: true,
                       workingLabel: L("unlock.working")) { Color.clear.frame(width: 300, height: 80) }
        }.capture(into: folder)
        problems += await Shot(name: "app-icon", size: CGSize(width: 900, height: 640), titled: false) {
            AppIconSheet()
        }.capture(into: folder)
        problems += await Shot(name: "brand", size: CGSize(width: 900, height: 560), titled: false) {
            BrandSheet()
        }.capture(into: folder)
        problems += await Shot(name: "flags", size: CGSize(width: 900, height: 620), titled: false) {
            FlagSheet()
        }.capture(into: folder)
        return problems
    }

    // MARK: One proxy, one line

    /// The editor's network tab with each way of choosing a proxy: a pasted line that was checked
    /// (it works, its type from the scheme); one without a scheme, not checked yet; a proxy of the
    /// list; a line that is not a proxy (said at once under the field); and one whose check found
    /// it silent after the connection. Nothing is checked here: the results are samples.
    private static func proxyFieldInEditor(into folder: URL, draft: ProfileDraft) async -> Int {
        let entries = sampleProxyEntries()
        var problems = 0
        var checked = draft
        if let proxy = checked.proxyLine.checkable {
            checked.proxyLine.check = ProxyLine.Check(proxy: proxy, result: sampleWorks(.socks5, "203.0.113.10", "DE", "Europe/Berlin",
                                                                                        "Berlin", [80, 84, 97], asn: "AS64500",
                                                                                        organization: "Example Networks"))
        }
        var saved = draft
        saved.proxyMode = .saved
        saved.choose(entries[0])
        var unknownKind = draft
        unknownKind.proxyLine = ProxyLine(text: "203.0.113.10:1080:nw-team:correct-horse")
        unknownKind.lastProxyLocation = nil
        var unreadable = draft
        unreadable.proxyLine = ProxyLine(text: "proxy.northwind.example:80800:nw-team:correct-horse")
        unreadable.lastProxyLocation = nil
        var silent = draft
        silent.proxyLine = ProxyLine(text: "198.51.100.40:8000")
        silent.lastProxyLocation = nil
        if let proxy = silent.proxyLine.checkable {
            silent.proxyLine.check = ProxyLine.Check(proxy: proxy, result: sampleFailed(ProxyDiagnosis(verdict: .silent,
                                                                                                         connectedAddress: "198.51.100.40")))
        }
        let shots: [(String, ProfileDraft)] = [
            ("editor-network", checked),
            ("editor-network-unchecked", unknownKind),
            ("editor-network-saved", saved),
            ("editor-network-unreadable", unreadable),
            ("editor-network-silent", silent),
        ]
        for (name, sample) in shots {
            problems += await Shot(name: name, size: ProfileEditorForm.size, titled: false) {
                EditorPreview(draft: sample, topic: .connection, savedProxies: entries)
            }.capture(into: folder)
        }
        return problems
    }

    /// A check that found the proxy working, `checkedAt` 12 minutes ago.
    static func sampleWorks(_ kind: ProxySettings.Kind, _ ip: String, _ country: String, _ zone: String, _ city: String,
                            _ latencies: [Int], asn: String? = nil, organization: String? = nil) -> ProxyCheckResult {
        var result = ProxyCheckResult(checkedAt: Date().addingTimeInterval(-12 * 60), exitIP: ip, countryCode: country,
                                      timeZoneIdentifier: zone,
                                      diagnosis: ProxyDiagnosis(verdict: .works, kinds: [kind], authentication: .accepted,
                                                                connectedAddress: ip, latencies: latencies,
                                                                latencyAttempts: latencies.count),
                                      city: city, asn: asn, organization: organization)
        result.latencyMilliseconds = result.diagnosis?.medianLatency
        return result
    }

    /// A check that found the proxy not working, as `diagnosis` says.
    static func sampleFailed(_ diagnosis: ProxyDiagnosis) -> ProxyCheckResult {
        var result = ProxyCheckResult.dead(diagnosis.verdict == .credentialsNeeded ? .needsCredentials : .noAnswer,
                                           at: Date().addingTimeInterval(-12 * 60))
        result.diagnosis = diagnosis
        return result
    }

    /// The sample list: working (one of them slow), each way of failing the list tells apart (silent
    /// after connecting, login rejected, host not found, refused, no connection), and one whose type
    /// the first check is to find. Berlin first, the silent one fourth.
    static func sampleProxyEntries() -> [ProxyListEntry] {
        [
            ProxyListEntry(label: "Berlin 1", proxy: ProxySettings(kind: .socks5, host: "203.0.113.10", port: 1080,
                                                                   username: "northwind", password: "sample"),
                           lastCheck: sampleWorks(.socks5, "203.0.113.10", "DE", "Europe/Berlin", "Berlin", [80, 84, 97],
                                                  asn: "AS64500", organization: "Example Networks")),
            ProxyListEntry(proxy: ProxySettings(kind: .httpConnect, host: "proxy.example.net", port: 3128),
                           lastCheck: sampleWorks(.httpConnect, "198.51.100.23", "NL", "Europe/Amsterdam", "Amsterdam", [138, 142, 160])),
            ProxyListEntry(label: "Tokyo", proxy: ProxySettings(kind: .httpConnect, host: "192.0.2.44", port: 8443, tlsToProxy: true),
                           lastCheck: sampleWorks(.httpConnect, "192.0.2.44", "JP", "Asia/Tokyo", "Tokyo", [1730])),
            ProxyListEntry(label: "Whitelisted", proxy: ProxySettings(kind: .httpConnect, host: "198.51.100.40", port: 8000),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .silent, connectedAddress: "198.51.100.40"))),
            ProxyListEntry(label: "Old provider", proxy: ProxySettings(kind: .socks5, host: "192.0.2.7", port: 1080,
                                                                     username: "olduser", password: "expired"),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .credentialsRejected, kinds: [.socks5],
                                                                  authentication: .rejected, answer: "SOCKS5 login refused (status 1)",
                                                                  connectedAddress: "192.0.2.7"))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "proxy.example.invalid", port: 1080),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .hostNotFound))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "192.0.2.99", port: 1080),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .refused))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "198.51.100.77", port: 9000),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .connectTimeout))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "gw.example.com", port: 9000, username: "user-country-de",
                                                password: "sample"),
                           kindKnown: false),
        ]
    }

    // MARK: Proxy list

    /// The Proxies section with proxies as checks left them — working (one of them slow), each way
    /// of failing the list tells apart (silent after connecting, login rejected, host not found,
    /// refused, no connection), one whose type the first check is to find — from a temporary
    /// vault; its report on the silent one and on a working one; the Edit and Export sheets; and
    /// what a profile whose proxy did not work at its launch says. Nothing is checked here and
    /// nothing goes to the network.
    private static func proxyList(into folder: URL) async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-snapshots-proxies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let vault = try MasterVault.create(in: root, password: "snapshots", iterations: 10_000)
            let entries = sampleProxyEntries()
            let berlin = entries[0], silent = entries[3]
            try ProxyList(entries: entries).save(to: vault)
            let proxies = ProxyListModel(vault: vault) { print("FAIL sample proxy list: \($0)") }
            let counts = [ProxyList.identity(of: berlin.proxy): 3, ProxyList.identity(of: silent.proxy): 2,
                          ProxyList.identity(of: entries[1].proxy): 1]
            var problems = 0
            // The Profiles window's Proxies section: wide, with a proxy that stays silent selected; in
            // the narrowest window, with one that works.
            let rows = sampleRows()
            func section(selecting id: UUID) -> AnyView {
                AnyView(ProxyListPanel(proxies: proxies, profileCounts: counts, selection: .constant([id])))
            }
            problems += await Shot(name: "proxies", size: CGSize(width: 1180, height: 740)) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: silent.id))
            }.capture(into: folder)
            problems += await Shot(name: "proxies-narrow", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620)) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: berlin.id))
            }.capture(into: folder)
            problems += await Shot(name: "sheet-proxy-edit", size: CGSize(width: 560, height: 400), titled: false) {
                ProxyEditView(proxies: proxies, entry: berlin, profileCount: 3)
            }.capture(into: folder)
            // Add: a line without a scheme, checked — the type the check found, where it exits.
            var added = ProxyLine(text: "198.51.100.23:3128:dave:correct-horse")
            if let proxy = added.checkable {
                added.check = ProxyLine.Check(proxy: proxy, result: sampleWorks(.httpConnect, "198.51.100.23", "NL", "Europe/Amsterdam",
                                                                                "Amsterdam", [138, 142, 160]))
            }
            let addLine = added
            problems += await Shot(name: "sheet-proxy-add", size: CGSize(width: 560, height: 470), titled: false) {
                ProxyEditView(proxies: proxies, entry: nil, profileCount: 0, line: addLine)
            }.capture(into: folder)
            problems += await Shot(name: "sheet-proxy-add-unreadable", size: CGSize(width: 560, height: 380), titled: false) {
                ProxyEditView(proxies: proxies, entry: nil, profileCount: 0, line: ProxyLine(text: "1.2.3.4:1080:alice"))
            }.capture(into: folder)
            problems += await Shot(name: "sheet-proxy-export", size: CGSize(width: 500, height: 360), titled: false) {
                ProxyExportView(proxies: proxies, selection: [berlin.id, silent.id])
            }.capture(into: folder)
            let problem = ProxyProblem(profileID: UUID(), profileName: "Northwind", proxy: silent.proxy,
                                       diagnosis: ProxyDiagnosis(verdict: .silent, connectedAddress: "198.51.100.40"))
            problems += await Shot(name: "sheet-proxy-problem", size: CGSize(width: 580, height: 600), titled: false) {
                ProxyProblemPanel(problem: problem, more: 1, check: { nil }, close: {}, showInList: {})
            }.capture(into: folder)
            return problems
        } catch {
            print("FAIL could not make the sample proxy list: \(error)")
            return 1
        }
    }

    // MARK: Click test

    /// Posts a click onto the New Profile button (in the band under the transparent title bar)
    /// and onto the Lock button (at the sidebar's foot) and reports whether each reached its action.
    private static func clickTest(_ window: NSWindow, clicks: ClickLog) async -> Int {
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // The content view runs under the title bar (full-size content): its top is the window's top.
        let height = window.contentView?.bounds.height ?? window.frame.height
        let width = window.contentView?.bounds.width ?? window.frame.width
        // New Profile: right-aligned 16 pt from the edge, centred in the 52 pt header.
        click(window, at: NSPoint(x: width - 16 - 50, y: height - 26))
        // Lock: full sidebar width, 14 pt above the bottom, 28 pt high.
        click(window, at: NSPoint(x: ProfilesScreen.sidebarWidth / 2, y: 14 + 14))
        try? await Task.sleep(nanoseconds: 600_000_000)
        var problems = 0
        for (name, count) in [("header New Profile (under the title bar)", clicks.newProfile), ("sidebar Lock", clicks.lock)] {
            if count == 1 {
                print("PASS click reached \(name)")
            } else {
                print("FAIL click on \(name) arrived \(count) times (window key: \(window.isKeyWindow))")
                problems += 1
            }
        }
        return problems
    }

    private static func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    // MARK: Browser window

    /// Opens a real browser window of a running profile — ephemeral, through a SOCKS5 proxy whose
    /// last known exit is Germany, with a few bookmarks and visited pages — and captures it with
    /// its start page, then with three tabs. Nothing listens on the proxy's port, and nothing here
    /// is loaded from the network.
    private static func browserWindows(into folder: URL) async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let repository = try ProfileRepository(vault: MasterVault.create(in: root, password: "snapshots", iterations: 10_000))
            let proxy = ProxySettings(kind: .socks5, host: "127.0.0.1", port: 9)
            let profile = try repository.create(name: "Northwind", configuration: ProfileConfiguration(
                proxy: proxy, ephemeral: true, matchProxyLocation: false))
            let key = try repository.profileKey(for: profile.id)
            let configuration = try repository.loadConfiguration(profile.id, key: key)
            let library = ProfileLibrary(
                history: try repository.historyStore(for: profile.id, key: key, policy: configuration.historyPolicy, persistent: false),
                bookmarks: try repository.bookmarkStore(for: profile.id, key: key),
                recordsHistory: true)
            let passwordSettings = ProfilePasswordSettings(repository: repository, profileID: profile.id, profileName: profile.name,
                                                           launchConfiguration: configuration)
            // As a launch with a proxy does (ProfileManager.launch).
            await ContentRules.prepare()
            let session = try BrowserSession(profileID: profile.id, profileName: profile.name, configuration: configuration,
                                             passwordVault: try repository.passwordVault(for: profile.id),
                                             passwordSettings: passwordSettings, library: library)
            defer { session.shutDown() }
            session.exitLocation = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE",
                                                 proxyEndpoint: ProxyLocation.endpoint(of: proxy))
            let favourites = [("Northwind App", "https://app.northwind.example/"), ("Team Docs", "https://docs.northwind.example/"),
                              ("Mail", "https://mail.northwind.example/"), ("Calendar", "https://calendar.northwind.example/"),
                              ("Analytics", "https://analytics.northwind.example/"), ("Status", "https://status.northwind.example/")]
            for (title, address) in favourites {
                if let url = URL(string: address) { _ = library.addBookmark(title: title, url: url) }
            }
            let visited = [("Inbox — Mail", "https://mail.northwind.example/inbox"),
                           ("Q3 report — Team Docs", "https://docs.northwind.example/q3"),
                           ("Dashboard — Northwind", "https://app.northwind.example/dashboard")]
            for (title, address) in visited {
                if let url = URL(string: address) { library.recordVisit(url: url, title: title) }
            }
            let controller = session.openWindow(url: nil)
            guard let window = controller.window else {
                print("FAIL no browser window")
                return 1
            }
            var problems = 0
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            problems += capture(window, name: "browser-start", into: folder)
            for title in ["Northwind — Dashboard", "Q3 report — Team Docs"] {
                let tab = controller.addTab(url: nil, select: false, afterSelected: false)
                tab?.webView.loadHTMLString("<!doctype html><title>\(title)</title><body></body>", baseURL: nil)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            problems += capture(window, name: "browser-tabs", into: folder)
            window.close()
            return problems
        } catch {
            print("FAIL browser window snapshot: \(error)")
            return 1
        }
    }

    /// Writes `window` as it is on screen (its frame view: title bar and toolbar included).
    static func capture(_ window: NSWindow, name: String, into folder: URL) -> Int {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("FAIL no bitmap for \(name)")
            return 1
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("FAIL could not encode \(name)")
            return 1
        }
        do {
            try data.write(to: folder.appendingPathComponent("\(name).png"))
            print("WROTE \(name).png (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            return 0
        } catch {
            print("FAIL could not write \(name): \(error)")
            return 1
        }
    }

    /// A proxied profile whose last lookup found Germany, two minutes ago.
    static func sampleDraft() -> ProfileDraft {
        var draft = ProfileDraft()
        draft.name = "Northwind"
        draft.warnOnProxyIPChange = true
        let proxy = ProxySettings(kind: .socks5, host: "proxy.northwind.example", port: 1080, username: "nw-team",
                                  password: "correct-horse")
        draft.proxyMode = .new
        draft.proxyLine = ProxyLine(proxy: proxy)
        draft.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE",
                                                proxyEndpoint: ProxyLocation.endpoint(of: proxy),
                                                resolvedAt: Date().addingTimeInterval(-120))
        return draft
    }

    /// `ProfileSummary` has no public initialiser; a sample is decoded like a stored one.
    static func sampleSummary(name: String, id: UUID) -> ProfileSummary? {
        let json = #"{"id":"\#(id.uuidString)","name":"\#(name)","createdAt":0,"revision":1}"#
        return try? JSONDecoder().decode(ProfileSummary.self, from: Data(json.utf8))
    }

    final class ClickLog {
        var newProfile = 0
        var lock = 0
    }

    // MARK: Sample data

    /// A profile in this app's window and Safari, as a snapshot of each might read: the same
    /// engine, Safari's own interfaces missing, the window's bars of another height.
    static func whatSitesSeeSample() -> (profile: SiteSnapshot, safari: SiteSnapshot) {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
        let shared: [String: String] = [
            "probe.ua": ua, "probe.platform": "MacIntel", "probe.language": "de-DE", "probe.languages": "de-DE",
            "probe.hardwareConcurrency": "8", "probe.timeZone": "Europe/Berlin", "probe.tzOffset": "-60",
            "probe.screen": "1512x982", "probe.colorDepth": "30", "geometry.devicePixelRatio": "2",
            "geometry.screen": "1512x982x1512x944x0x38", "probe.webgl.renderer": "Apple GPU", "probe.fonts": "13",
            "headers.navigation.order": "Host,Upgrade-Insecure-Requests,Accept,User-Agent,Accept-Language,Priority,Accept-Encoding,Connection",
            "headers.navigation.user-agent": ua, "headers.navigation.accept-language": "de-DE,de;q=0.9",
            "tls.ja4": "t13d2014h2_a09f3c656075_e42f34c56612", "tls.alpn": "h2,http/1.1",
            "tls.supportedGroups": "0x11ec,0x001d,0x0017,0x0018,0x0019", "apis.quota": "1006632960",
            "apis.permission.geolocation": "prompt",
        ]
        var profile = shared, safari = shared
        profile["probe.safari"] = "undefined"
        safari["probe.safari"] = "[object SafariRemoteNotification]|pushNotification"
        profile["probe.features.window.ApplePaySetup"] = "undefined"
        safari["probe.features.window.ApplePaySetup"] = "function"
        profile["probe.windowOwnCount"] = "1029"
        safari["probe.windowOwnCount"] = "1044"
        profile["geometry.chrome"] = "0x80"
        safari["geometry.chrome"] = "0x87"
        profile["geometry.outer"] = "1470x919"
        safari["geometry.outer"] = "1280x800"
        safari["apis.voices"] = "184"
        return (SiteSnapshot(values: profile), SiteSnapshot(values: safari))
    }

    /// The palette's commands for the sample rows, as the Profiles window builds them.
    static func paletteSample(_ rows: [ProfileRowItem]) -> [CommandPaletteView.Command] {
        var commands = [CommandPaletteView.Command(id: "new", title: L("palette.newProfile"), symbol: "plus", run: {})]
        for row in rows {
            let detail = row.paletteDetail
            let key = row.isRunning ? "palette.newWindow" : "palette.launch"
            commands.append(CommandPaletteView.Command(id: "row-\(row.id)", title: String(format: L(key), row.name),
                                                       detail: detail, symbol: row.isRunning ? "macwindow.badge.plus" : "play.circle", run: {}))
        }
        commands.append(CommandPaletteView.Command(id: "proxies", title: L("palette.proxies"), symbol: "network", run: {}))
        for section in SettingsSection.allCases.prefix(4) {
            commands.append(CommandPaletteView.Command(id: section.rawValue, title: String(format: L("palette.settings"), L(section.titleKey)),
                                                       symbol: section.symbol, run: {}))
        }
        return commands
    }

    static func sampleRows() -> [ProfileRowItem] {
        func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0x1C, 0x5E, 0x17, 0, n, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }
        let mac = ProfileRowItem.appearsAs(DeviceGenerations.resolved(id: "macos-26"))
        let iPhone = ProfileRowItem.appearsAs(DeviceGenerations.resolved(id: "ios-26"))
        let now = Date()
        return [
            ProfileRowItem(id: id(1), name: "Personal", activity: .running, exit: .direct, ephemeral: false,
                           appearsAs: mac, lastUsed: now),
            ProfileRowItem(id: id(2), name: "Northwind", activity: .running,
                           exit: .proxy(endpoint: "proxy.northwind.example:1080", countryCode: "DE"), ephemeral: false,
                           appearsAs: mac, lastUsed: now, warmUp: WarmUpStatus(phase: .running, visited: 3, total: 12, cookies: 84),
                           tags: ["ads", "DE"], notes: "Renews monthly", avatar: ProfileAvatarStyle(color: 5, letters: "NW")),
            ProfileRowItem(id: id(3), name: "Launch Review", activity: .starting,
                           exit: .proxy(endpoint: "us-east.gateway.example:8080", countryCode: "US"), ephemeral: false,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-3_600)),
            ProfileRowItem(id: id(4), name: "Research", activity: .stopped,
                           exit: .proxy(endpoint: "nl.gateway.example:1080", countryCode: "NL"), ephemeral: false,
                           appearsAs: iPhone, lastUsed: now.addingTimeInterval(-86_400),
                           tags: ["warm-up", "Q4 campaign", "NL", "mobile"]),
            ProfileRowItem(id: id(5), name: "Travel", activity: .sealing,
                           exit: .proxy(endpoint: "lisbon.example:1080", countryCode: "PT"), ephemeral: false,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-60)),
            ProfileRowItem(id: id(6), name: "Shopping", activity: .stopped, exit: .direct, ephemeral: true,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-3 * 86_400)),
            ProfileRowItem(id: id(7), name: "Banking", activity: .stopped,
                           exit: .proxy(endpoint: "10.20.0.2:3128", countryCode: nil), ephemeral: false,
                           appearsAs: mac, lastUsed: nil, tags: ["ads"]),
        ]
    }
}

// MARK: - Capturing

/// One screen to capture: a SwiftUI view in a window of the app's style.
@MainActor
private struct Shot {
    let name: String
    let size: CGSize
    var titled = true
    let content: () -> AnyView

    init<V: View>(name: String, size: CGSize, titled: Bool = true, @ViewBuilder content: @escaping () -> V) {
        self.name = name
        self.size = size
        self.titled = titled
        self.content = { AnyView(content()) }
    }

    /// Shows the window, lets SwiftUI and AppKit settle, writes `<name>.png` (the whole window,
    /// title bar included) and returns the number of problems (`extra` runs before the window closes).
    func capture(into folder: URL, extra: ((NSWindow) async -> Int)? = nil) async -> Int {
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        Theme.applyChrome(to: window)
        window.backgroundColor = NSColor(hex: 0x161920)
        let host = NSHostingView(rootView: content()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .tint(Theme.accentFill))
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 900_000_000)
        host.layoutSubtreeIfNeeded()
        host.display()
        var problems = 0
        let frameView = window.contentView?.superview ?? host
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            problems += write(rep, to: folder.appendingPathComponent("\(name).png"))
        } else {
            print("FAIL no bitmap for \(name)")
            problems += 1
        }
        if let extra { problems += await extra(window) }
        window.orderOut(nil)
        window.close()
        return problems
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) -> Int {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("FAIL could not encode \(url.lastPathComponent)")
            return 1
        }
        do {
            try data.write(to: url)
            print("WROTE \(url.lastPathComponent) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            return 0
        } catch {
            print("FAIL could not write \(url.path): \(error)")
            return 1
        }
    }
}

/// The editor's form with its draft and part held in state, as the sheet holds them.
private struct EditorPreview: View {
    @State var draft: ProfileDraft
    @State var topic: ProfileEditorForm.Topic
    var isNew = false
    var error: String?
    var savedProxies: [ProxyListEntry] = []
    var visibleScreen: CGSize? = CGSize(width: 1728, height: 1024)

    var body: some View {
        // A saved profile's editor has its What Sites See button, as ProfileEditorView gives it.
        ProfileEditorForm(draft: $draft, topic: $topic, isNew: isNew, avatarID: UISnapshots.sampleRows()[1].id,
                          error: error, tunnelCarriesWebRTC: false, savedProxies: savedProxies,
                          knownTags: ["ads", "DE", "US", "warm-up", "Q4 campaign"], visibleScreen: visibleScreen,
                          onWhatSitesSee: isNew ? nil : {})
    }
}

/// `ProfilesScreen` with its bindings held in state, as the window holds them.
private struct ProfilesPreview: View {
    let rows: [ProfileRowItem]
    @State var filter: ProfileFilter = .all
    @State var search = ""
    var sync: SyncLine = .off
    var isWorking = false
    var actions = ProfileActions()
    var section: ProfilesSection = .profiles
    var proxyCount: Int? = 9
    var proxies: AnyView?

    var body: some View {
        ProfilesScreen(rows: rows, isWorking: isWorking, sync: sync, filter: $filter, search: $search, actions: actions,
                       section: .constant(section), proxyCount: proxyCount, proxies: proxies)
    }
}

// MARK: - Brand and flags sheets

private struct BrandSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .bottom, spacing: 24) {
                ForEach([128, 64, 32, 24, 20, 16, 14] as [CGFloat], id: \.self) { size in
                    VStack(spacing: 8) {
                        LumenMark(size: size)
                        Text(verbatim: "\(Int(size))").font(.lumenCaption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            HStack(alignment: .center, spacing: 28) {
                LumenLockup.large
                LumenLockup.sidebar
                ForEach([40, 24, 16] as [CGFloat], id: \.self) { size in LumenGlyph(size: size) }
            }
            VStack(alignment: .leading, spacing: 12) {
                LumenWordmark(height: 40)
                LumenWordmark(height: 22)
                LumenWordmark(height: 11.2)
            }
            HStack(spacing: 24) {
                LumenLockup(markSize: 36, wordmarkHeight: 22, gap: 14, color: Theme.primaryText)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF2F3F6)))
                LumenMark(size: 48).padding(16).background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF2F3F6)))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.backdrop)
    }
}

/// The app icon as drawn for the .icns, at Dock and Finder sizes on dark and light backgrounds.
private struct AppIconSheet: View {
    private let sizes: [CGFloat] = [256, 128, 64, 32, 16]

    var body: some View {
        VStack(spacing: 0) {
            row(background: Color(hex: 0x0B0C0F))
            row(background: Color(hex: 0xECECEC))
        }
    }

    private func row(background: Color) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            ForEach(sizes, id: \.self) { size in
                if let image = AppIcon.image(pixels: Int(size * 2)) {
                    Image(nsImage: NSImage(cgImage: image, size: NSSize(width: size, height: size)))
                        .interpolation(.high)
                        .frame(width: size, height: size)
                }
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
    }
}

private struct FlagSheet: View {
    static let codes = ["DE", "NL", "PT", "FR", "IT", "ES", "GB", "US", "CH", "SE", "NO", "DK", "FI", "IS", "PL",
                        "UA", "RU", "AT", "BE", "IE", "CZ", "GR", "TR", "CN", "JP", "IN", "AR", "CL", "AE", "IL",
                        "LV", "LT", "EE", "HU", "RO", "BG", "LU", "TH", "CO", "BD", "KR", "BR", "CA", "MX", "AU",
                        "SK", "RS", "ZA", "SG", "XX"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(160), alignment: .leading), count: 5), alignment: .leading, spacing: 10) {
                ForEach(Self.codes, id: \.self) { code in
                    HStack(spacing: 8) {
                        CountryFlag(code: code, size: 14)
                        Text(CountryNames.name(for: code)).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(["DE", "NL", "PT", "US", "GB", "JP", "KR", "BR"], id: \.self) { code in
                    CountryFlag(code: code, size: 28)
                }
                ForEach(["DE", "NL", "PT", "US"], id: \.self) { code in
                    CountryFlag(code: code, size: 12)
                }
            }
            HStack(spacing: 24) {
                ExitLabel(exit: .proxy(endpoint: "proxy.example:1080", countryCode: "DE"))
                ExitLabel(exit: .proxy(endpoint: "10.20.0.2:3128", countryCode: nil))
                ExitLabel(exit: .direct)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
    }
}
