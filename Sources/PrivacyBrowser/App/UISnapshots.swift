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
        problems += await Shot(name: "profiles-empty", size: CGSize(width: 1180, height: 640)) {
            ProfilesPreview(rows: [], sync: .notYet)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-no-matches", size: CGSize(width: 1180, height: 520)) {
            ProfilesPreview(rows: rows, search: "zzz", sync: .syncing)
        }.capture(into: folder)
        // The profile editor, one picture per tab (sheets have no title bar).
        let draft = sampleDraft()
        var unknownExit = draft
        unknownExit.lastProxyLocation = nil
        var newProfile = ProfileDraft()
        newProfile.name = String(format: L("editor.defaultName"), 8)
        var privacy = draft
        privacy.geoMode = .fixed
        privacy.latitude = "52.52"
        privacy.longitude = "13.405"
        privacy.overrideTimeZone = true
        privacy.timeZone = "Europe/Berlin"
        var ephemeral = draft
        ephemeral.ephemeral = true
        let editors: [(String, ProfileDraft, ProfileEditorForm.Tab, Bool, String?)] = [
            ("editor-network", draft, .network, false, nil),
            ("editor-network-unchecked", unknownExit, .network, false, nil),
            ("editor-general-new", newProfile, .general, true, nil),
            ("editor-identity", draft, .identity, false, nil),
            ("editor-privacy", privacy, .privacy, false, nil),
            ("editor-data-ephemeral", ephemeral, .data, false, L("editor.error.port")),
        ]
        for (name, sample, tab, isNew, error) in editors {
            problems += await Shot(name: name, size: ProfileEditorForm.size, titled: false) {
                EditorPreview(draft: sample, tab: tab, isNew: isNew, error: error)
            }.capture(into: folder)
        }
        // The other sheets, as they open.
        let model = AppModel()
        if let northwind = sampleSummary(name: "Northwind", id: rows[1].id) {
            problems += await Shot(name: "sheet-passwords-locked", size: CGSize(width: 780, height: 560), titled: false) {
                PasswordListView(profile: northwind).environmentObject(model)
            }.capture(into: folder)
            problems += await Shot(name: "sheet-cookie-import", size: CGSize(width: 680, height: 560), titled: false) {
                CookieImportView(profile: northwind).environmentObject(model)
            }.capture(into: folder)
        } else {
            print("FAIL could not make a sample profile summary")
            problems += 1
        }
        problems += await Shot(name: "sheet-sync", size: CGSize(width: 540, height: 460), titled: false) {
            SyncSettingsView().environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-change-password", size: CGSize(width: 420, height: 330), titled: false) {
            ChangePasswordView().environmentObject(model)
        }.capture(into: folder)
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
        draft.proxyEnabled = true
        draft.proxyKind = .socks5
        draft.proxyHost = "proxy.northwind.example"
        draft.proxyPort = "1080"
        draft.proxyUsername = "nw-team"
        draft.proxyPassword = "correct-horse"
        draft.warnOnProxyIPChange = true
        if let proxy = try? draft.makeProxy() {
            draft.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE",
                                                    proxyEndpoint: ProxyLocation.endpoint(of: proxy),
                                                    resolvedAt: Date().addingTimeInterval(-120))
        }
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
                           appearsAs: mac, lastUsed: now, warmUp: .fixed(page: 3, of: 12)),
            ProfileRowItem(id: id(3), name: "Launch Review", activity: .starting,
                           exit: .proxy(endpoint: "us-east.gateway.example:8080", countryCode: "US"), ephemeral: false,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-3_600)),
            ProfileRowItem(id: id(4), name: "Research", activity: .stopped,
                           exit: .proxy(endpoint: "nl.gateway.example:1080", countryCode: "NL"), ephemeral: false,
                           appearsAs: iPhone, lastUsed: now.addingTimeInterval(-86_400)),
            ProfileRowItem(id: id(5), name: "Travel", activity: .sealing,
                           exit: .proxy(endpoint: "lisbon.example:1080", countryCode: "PT"), ephemeral: false,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-60)),
            ProfileRowItem(id: id(6), name: "Shopping", activity: .stopped, exit: .direct, ephemeral: true,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-3 * 86_400)),
            ProfileRowItem(id: id(7), name: "Banking", activity: .stopped,
                           exit: .proxy(endpoint: "10.20.0.2:3128", countryCode: nil), ephemeral: false,
                           appearsAs: mac, lastUsed: nil),
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

/// The editor's form with its draft and tab held in state, as the sheet holds them.
private struct EditorPreview: View {
    @State var draft: ProfileDraft
    @State var tab: ProfileEditorForm.Tab
    var isNew = false
    var error: String?

    var body: some View {
        ProfileEditorForm(draft: $draft, tab: $tab, isNew: isNew, avatarID: UISnapshots.sampleRows()[1].id,
                          error: error, tunnelCarriesWebRTC: false)
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

    var body: some View {
        ProfilesScreen(rows: rows, isWorking: isWorking, sync: sync, filter: $filter, search: $search, actions: actions)
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
