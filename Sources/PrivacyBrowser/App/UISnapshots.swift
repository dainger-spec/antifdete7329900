import AppKit
import BrowserCore
import SwiftUI

/// `Lumen --render-ui-snapshots <folder>`: renders the app's screens with sample data
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
            print("usage: Lumen --render-ui-snapshots <folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Localization.applyProcessLanguage()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // A run took 115 s in CI run 556, before the edge checks and the list's steps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
            print("SNAPSHOTS TIMEOUT after 240 s")
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
    /// A Mac signed out, and one on the Professional plan with two Macs — previews: nothing asked.
    private static func previewLicenses() -> (signedOut: LicenseModel, signedIn: LicenseModel, signedInWithKey: LicenseModel, keyWithEmail: LicenseModel) {
        let now = Date()
        let p = Entitlement(deviceID: "d1", machineID: "m", role: "owner", plan: "pro", status: .active, exportReason: nil,
                            limits: .init(profiles: 50, devices: 3, seats: 1), profilesOnOtherDevices: 12,
                            periodEndsAt: now.addingTimeInterval(28 * 86_400), issuedAt: now.addingTimeInterval(-3_600),
                            refreshAfter: now.addingTimeInterval(20 * 3_600), expiresAt: now.addingTimeInterval(95 * 3_600),
                            graceEndsAt: now.addingTimeInterval(167 * 3_600))
        var record = AccountRecord()
        record.deviceID = "d1"
        record.code = "B119"
        record.deviceToken = ServerToken("lmd_preview")
        record.lastSuccessAt = now.addingTimeInterval(-3_600)
        record.signedInWith = .email
        record.session = .init(sessionToken: ServerToken("lms_preview"), expiresAt: now.addingTimeInterval(20 * 86_400), idleTimeoutSeconds: 604_800)
        let devices = AccountDevices(devices: [
            AccountDevice(deviceID: "d1", code: "B119", label: "Studio", lastSeenAt: now, profileCount: 21, mine: true), // l10n: not text
            AccountDevice(deviceID: "d2", code: "3KQ9", label: "", lastSeenAt: now.addingTimeInterval(-3 * 86_400), profileCount: 9, mine: true),
        ], limit: 3, used: 2, unlinkAvailableAt: nil, unlinkCooldownSeconds: 604_800, offlineWorkSeconds: 604_800)
        let signedIn = LicenseModel(preview: record, state: LicenseState(mode: .full, entitlement: p, check: .valid(p), banners: [],
                                                                         allowedProfilesHere: 38, worksWithoutServerUntil: p.graceEndsAt, now: now),
                                    devices: devices)
        let signedOut = LicenseModel(preview: AccountRecord(), state: LicenseState(mode: .notSignedIn, entitlement: nil, check: nil,
                                                                                    banners: [.notSignedIn], allowedProfilesHere: 0,
                                                                                    worksWithoutServerUntil: nil, now: now))
        // The same Mac, its account a key's: no email, so Lumen warns itself (§17).
        var keyRecord = record
        keyRecord.signedInWith = .key
        keyRecord.session = nil
        let signedInWithKey = LicenseModel(preview: keyRecord, state: LicenseState(mode: .full, entitlement: p, check: .valid(p), banners: [],
                                                                                    allowedProfilesHere: 38, worksWithoutServerUntil: p.graceEndsAt,
                                                                                    now: now))
        // An email linked to the key's purchase (§11.1): a session for the account screen, letters too.
        var linkedRecord = keyRecord
        linkedRecord.emailLinked = true
        linkedRecord.session = record.session
        let keyWithEmail = LicenseModel(preview: linkedRecord, state: LicenseState(mode: .full, entitlement: p, check: .valid(p), banners: [],
                                                                                    allowedProfilesHere: 38, worksWithoutServerUntil: p.graceEndsAt,
                                                                                    now: now), devices: devices)
        return (signedOut, signedIn, signedInWithKey, keyWithEmail)
    }

    private static func settings(into folder: URL, model: AppModel) async -> Int {
        var problems = 0
        for section in SettingsSection.allCases where section != .updates {
            problems += await Shot(name: "settings-\(section.rawValue)", size: SettingsView.size, edges: true) {
                SettingsView(section: section).environmentObject(model)
            }.capture(into: folder)
        }
        // A Mac whose Safari runs a newer engine than profiles, on whatever runner this is.
        EngineWarning.standIn = EngineWarning.Facts(safari: "27.2", engine: "26.6.2", macOS: 26) // l10n: not text
        problems += await Shot(name: "settings-about-engines", size: SettingsView.size, edges: true) {
            SettingsView(section: .about).environmentObject(model)
        }.capture(into: folder)
        EngineWarning.standIn = nil
        let configuration = AppUpdater.Configuration(
            feed: URL(string: "https://updates.example/lumen/appcast.json")!, keys: [:], version: "0.1.0",
            build: BuildVersion("1")!, bundleIdentifier: "io.lumenbrowser.Lumen",
            app: URL(fileURLWithPath: "/Applications/Lumen.app"),
            staging: URL(fileURLWithPath: "/nonexistent/updates"))
        let item = AppcastItem(
            version: "0.2.0", build: "2", minimumSystemVersion: "14.0",
            url: URL(string: "https://updates.example/lumen/Lumen-0.2.0.zip")!, length: 48_210_944,
            sha256: String(repeating: "0", count: 64), keyID: "0123456789abcdef", edSignature: Data(count: 64),
            publishedAt: Date().addingTimeInterval(-2 * 3600),
            notes: "• Safari's chrome: the proxy hook holds on macOS 27.\n• Proxies: a proxy that stays silent after the connection is named as such.\n"
                + "• Files a newer version wrote are refused, never written over.")
        let ready = AppUpdater(preview: .ready(item), configuration: configuration)
        // The account (docs/LICENSING.md): the sign-in with an email and with a key, and Settings ›
        // Account with a plan running — the contract's texts word for word.
        let licenses = previewLicenses()
        problems += await Shot(name: "account-sign-in", size: CGSize(width: 560, height: 780), titled: false) {
            SignInFlow(license: licenses.signedOut, onFinished: {}).environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "account-sign-in-key", size: CGSize(width: 560, height: 780), titled: false) {
            SignInFlow(license: licenses.signedOut, onFinished: {}, method: .key,
                       keyText: "LMK-0123-4567-89AB-CDEF-GHJK-MNMT").environmentObject(model) // l10n: not text
        }.capture(into: folder)
        // The password right, the letter's code first (§5.2): sent a minute ago, two resends left, the
        // next one in a minute — the texts as v2026.11.04 has them.
        let sent = Date().addingTimeInterval(-60)
        let code = LoginCode(challenge: ServerToken("lmc_preview"), codeAttempts: 5, codeSentAt: sent, codeExpiresAt: sent.addingTimeInterval(900),
                             resendAvailableAt: Date().addingTimeInterval(60), resendsLeft: 2)
        problems += await Shot(name: "account-sign-in-code", size: CGSize(width: 560, height: 780), titled: false) {
            SignInFlow(license: licenses.signedOut, onFinished: {}, step: .code, loginCode: code).environmentObject(model)
        }.capture(into: folder)
        // Every banner of the license above the profiles (§8.5), as each reads: the period's end a
        // week and a day ahead (the owner: above all for an account with a key, which gets no
        // letters), grace, the period ended, not signed in, revoked, the clock, a trial.
        let now = Date()
        let shown: [(license: LicenseModel, banner: LicenseBanner)] = [
            (licenses.signedIn, .periodEnding(owner: true, endsAt: now.addingTimeInterval(7 * 86_400), final: false)),
            (licenses.signedInWithKey, .periodEnding(owner: true, endsAt: now.addingTimeInterval(7 * 86_400), final: false)),
            (licenses.signedIn, .periodEnding(owner: true, endsAt: now.addingTimeInterval(86_400), final: true)),
            (licenses.signedInWithKey, .periodEnding(owner: true, endsAt: now.addingTimeInterval(86_400), final: true)),
            (licenses.signedIn, .grace(outdated: false, lastSuccessAt: now.addingTimeInterval(-5 * 86_400), until: now.addingTimeInterval(2 * 86_400))),
            (licenses.signedIn, .periodEnded(owner: true, endedAt: now.addingTimeInterval(-86_400))),
            (licenses.signedOut, .notSignedIn),
            (licenses.signedOut, .deviceRevoked),
            (licenses.signedIn, .clockSkew(seconds: 11 * 60)),
            (licenses.signedIn, .trialStarted(until: now.addingTimeInterval(7 * 86_400))),
            // Export only after the grace, and without a document that checks (v2026.11.04's texts).
            (licenses.signedIn, .expired(outdated: false, lastSuccessAt: now.addingTimeInterval(-9 * 86_400))),
            (licenses.signedIn, .unverified),
            // The app's own (the owner, 3 November): renewals failing for two days, the document's
            // last two days ahead, then the grace.
            (licenses.signedIn, .renewalFailing(since: now.addingTimeInterval(-2 * 86_400), reason: .noAnswer, status: nil,
                                                until: now.addingTimeInterval(5 * 86_400))),
        ]
        // Pictures of five at most: a window no taller than CI's screen (run 594 cut the tenth).
        for (part, range) in [("license-banners", 0..<5), ("license-banners-2", 5..<10), ("license-banners-3", 10..<shown.count)] {
            problems += await Shot(name: part, size: CGSize(width: 1000, height: 560), edges: true) {
                ZStack(alignment: .topLeading) {
                    Theme.surface.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(range), id: \.self) { index in
                            LicenseBannerView(license: shown[index].license, banner: shown[index].banner)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 56)
                }
                .environment(\.colorScheme, .dark)
                .environmentObject(model)
            }.capture(into: folder)
        }
        // Signed in, in the Settings window as the app shows it: a bare scroll view did not reach
        // the window's edges (CI run 585's edge check).
        problems += await Shot(name: "account-page", size: SettingsView.size, edges: true) {
            SettingsView(section: .account, previewLicense: licenses.signedIn).environmentObject(model)
        }.capture(into: folder)
        // A profile's Dock tile: its letters, and the flag of the country its proxy exits in.
        for (name, country) in [("dock-icon-flag", "DE" as String?), ("dock-icon-letters", nil)] {
            if let tiff = DockIcon.image(initials: 2, of: "North wind", country: country)?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        // Signed in with a key alone: the subscription's reminders, offered again here; the key not at
        // hand — the field that asks for it (`key.devices_need_key`); linking an email, a new key (§11.1).
        problems += await Shot(name: "account-page-key", size: SettingsView.size, edges: true) {
            SettingsView(section: .account, previewLicense: licenses.signedInWithKey).environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "account-page-key-email", size: SettingsView.size, edges: true) {
            SettingsView(section: .account, previewLicense: licenses.keyWithEmail).environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-email-link", size: CGSize(width: 500, height: 660), titled: false) {
            EmailLinkSheet(license: licenses.signedInWithKey, close: {}).environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-key-replace", size: CGSize(width: 500, height: 600), titled: false) {
            KeyReplaceSheet(license: licenses.signedInWithKey, label: "", close: {}).environmentObject(model)
        }.capture(into: folder)
        // The new key as it is shown once after a replacement — the server's test vector, not a key.
        if let shownKey = AccountKey(typed: "LMK-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZWB") { // l10n: not text
            problems += await Shot(name: "key-replaced", size: CGSize(width: 500, height: 220), titled: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("contract.key.replaced"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    NewKeyView(key: shownKey)
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.raised)
                .environment(\.colorScheme, .dark)
            }.capture(into: folder)
        }
        problems += await Shot(name: "settings-updates-ready", size: SettingsView.size, edges: true) {
            SettingsView(section: .updates, previewUpdater: ready).environmentObject(model)
        }.capture(into: folder)
        let upToDate = AppUpdater(preview: .upToDate(checkedAt: Date().addingTimeInterval(-25 * 60)), configuration: configuration,
                                  automaticChecks: false, installPolicy: .notifyOnly)
        problems += await Shot(name: "settings-updates-up-to-date", size: SettingsView.size, edges: true) {
            SettingsView(section: .updates, previewUpdater: upToDate).environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "settings-updates-unavailable", size: SettingsView.size, edges: true) {
            SettingsView(section: .updates).environmentObject(model)
        }.capture(into: folder)
        return problems
    }

    /// The room a sheet has in the narrowest Profiles window (`sheetFrame`), and a sheet's size there.
    static let narrowRoom = SheetRoomProvider.room(in: CGSize(width: ProfilesScreen.minimumWindowWidth, height: RootView.minimumHeight))

    static func narrow(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width, narrowRoom.width), height: min(size.height, narrowRoom.height))
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
        let profiles = Shot(name: "profiles", size: CGSize(width: 1180, height: 740), edges: true) {
            ProfilesPreview(rows: rows, sync: .synced(Date().addingTimeInterval(-4 * 60)), actions: actions)
        }
        problems += await profiles.capture(into: folder) { window in
            await clickTest(window, clicks: clicks)
        }
        problems += await Shot(name: "profiles-narrow", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, isWorking: true)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-proxied", size: CGSize(width: 1180, height: 560), edges: true) {
            ProfilesPreview(rows: rows, filter: .proxied, sync: .failed)
        }.capture(into: folder)
        // The inspector: one profile (Northwind), one whose settings cannot be read (R1: said there
        // too, and it does not start), several, and over the list in a window too narrow for both.
        let northwind = rows[1].id
        let inspected = inspectorSample()
        let info: (UUID) -> InspectorInfo = { $0 == northwind ? inspected : InspectorInfo() }
        // With the banner of a profile whose proxy does not work (Marketplace US), as the design has it.
        let banner = ProxyProblemBanner.Item(title: String(format: L("proxyProblem.title.notStarted"), rows[8].name),
                                             text: String(format: L("proxyProblem.subtitle.notStarted"), "us-dal.proxy.example:1080"), // l10n: not text
                                             notStarted: true, more: 0)
        problems += await Shot(name: "profiles-inspector", size: CGSize(width: 1400, height: 860), edges: true) {
            ProfilesPreview(rows: rows, sync: .synced(Date().addingTimeInterval(-4 * 60)), showsInspector: true,
                            selected: [northwind], inspectorInfo: info, proxyProblem: banner)
        }.capture(into: folder)
        // The control: the same inspector alone, in a window without a title bar. Drawn here and not
        // in the window above, the title bar's band is what hides it (CI run 555: the panel empty).
        problems += await Shot(name: "inspector-alone", size: CGSize(width: ProfilesScreen.inspectorWidth, height: 760), titled: false) {
            ProfileInspectorView(row: rows[1], info: inspected, actions: ProfileActions(), guardReady: true)
                .background(Theme.sidebar)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-inspector-unreadable", size: CGSize(width: 1400, height: 860), edges: true) {
            ProfilesPreview(rows: rows, showsInspector: true, selected: [rows[7].id])
        }.capture(into: folder)
        problems += await Shot(name: "profiles-inspector-several", size: CGSize(width: 1400, height: 860), edges: true) {
            ProfilesPreview(rows: rows, showsInspector: true, selected: [rows[1].id, rows[3].id, rows[5].id])
        }.capture(into: folder)
        problems += await Shot(name: "profiles-inspector-over", size: CGSize(width: 1180, height: 740), edges: true) {
            ProfilesPreview(rows: rows, showsInspector: true, selected: [northwind], inspectorInfo: info)
        }.capture(into: folder)
        // The list after a profile's window closed (the owner, 1 November: blank until scrolled up).
        problems += await listAfterReturn(into: folder)
        // The command palette (⌘K), as it opens and with something typed.
        let paletteCommands = paletteSample(rows)
        problems += await Shot(name: "palette", size: CommandPaletteView.size, titled: false) {
            CommandPaletteView(commands: paletteCommands)
        }.capture(into: folder)
        problems += await Shot(name: "palette-search", size: CommandPaletteView.size, titled: false) {
            CommandPaletteView(commands: paletteCommands, query: "north")
        }.capture(into: folder)
        // The app's help (HelpView), as the sidebar's Help, the scenario editor's Commands and the
        // automation settings open it: a page of steps and code, the commands' table, the requests'.
        for topic in [HelpTopic.scenarios, .commands, .api] {
            problems += await Shot(name: "help-\(topic.rawValue)", size: CGSize(width: 1040, height: 760)) {
                HelpView(topic: .constant(topic))
            }.capture(into: folder)
        }
        // A profile's window that is not Safari's: what its chip's popover says, for a structural
        // piece missing and for the sandboxed build (SimplifiedModeNotice).
        problems += await Shot(name: "simplified-mode", size: CGSize(width: 360, height: 290), titled: false) {
            SimplifiedModeExplanation(reason: .missingPieces(["BrowserWindowController"]))
        }.capture(into: folder)
        problems += await Shot(name: "simplified-mode-sandboxed", size: CGSize(width: 360, height: 260), titled: false) {
            SimplifiedModeExplanation(reason: .sandboxed)
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
        problems += await Shot(name: "narrow-what-sites-see", size: narrow(WhatSitesSeeView.size), titled: false) {
            WhatSitesSeeView(name: "Northwind", snapshot: seen()).environment(\.sheetRoom, narrowRoom)
        }.capture(into: folder)
        // The same sheet shown for real, by a window of the narrowest Profiles window's size that
        // gives its sheets their room as RootView does: the sheet lies within the window. The
        // control, a window that does not, shows the sheet at the size it asks for, cut by the
        // window: the check can tell the two apart.
        for givesRoom in [true, false] {
            let name = givesRoom ? "narrow-window-sheet" : "narrow-window-sheet-control"
            problems += await Shot(name: name, size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: RootView.minimumHeight)) {
                SheetHost(givesRoom: givesRoom) {
                    WhatSitesSeeView(name: "Northwind", snapshot: seen())
                }
            }.capture(into: folder) { window in
                await sheetFitTest(window, name: name, givesRoom: givesRoom, into: folder)
            }
        }
        // A tag chosen in the sidebar; the search also finds a profile by its tags and notes.
        problems += await Shot(name: "profiles-tag", size: CGSize(width: 1180, height: 560), edges: true) {
            ProfilesPreview(rows: rows, filter: .tag("ads"), sync: .off)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-search-notes", size: CGSize(width: 1180, height: 520), edges: true) {
            ProfilesPreview(rows: rows, search: "renews", sync: .off)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-empty", size: CGSize(width: 1180, height: 640), edges: true) {
            ProfilesPreview(rows: [], sync: .notYet)
        }.capture(into: folder)
        // The profile index missing, or unreadable, with the profiles' folders kept (never "no
        // profiles yet"); and profile folders a restored, older index does not list.
        let vaultPath = "~/Library/Application Support/Lumen"
        problems += await Shot(name: "profiles-index-missing", size: CGSize(width: 1180, height: 640), edges: true) {
            ProfilesPreview(rows: [], sync: .off, indexNotice: AppModel.IndexNotice(kind: .missing, folders: 12, vaultPath: vaultPath))
        }.capture(into: folder)
        problems += await Shot(name: "profiles-index-unreadable", size: CGSize(width: 1180, height: 640), edges: true) {
            ProfilesPreview(rows: [], sync: .off, indexNotice: AppModel.IndexNotice(kind: .unreadable, folders: 12, vaultPath: vaultPath))
        }.capture(into: folder)
        problems += await Shot(name: "profiles-index-unlisted", size: CGSize(width: 1180, height: 740), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, indexNotice: AppModel.IndexNotice(kind: .unlisted, folders: 3, vaultPath: vaultPath))
        }.capture(into: folder)
        problems += await Shot(name: "profiles-index-taken-in", size: CGSize(width: 1180, height: 740), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, indexNotice: AppModel.IndexNotice(kind: .takenIn, folders: 2, vaultPath: vaultPath))
        }.capture(into: folder)
        // Deleted profiles whose folders are kept (R3): one to bring back or remove, one brought back
        // (its old folder kept until removed), one whose folder cannot be read (the Finder only).
        problems += await Shot(name: "profiles-deleted-kept", size: CGSize(width: 1180, height: 900), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, keptDeleted: [
                .init(id: UUID(), name: "Retail Audit", createdAt: Date().addingTimeInterval(-40 * 86_400)),
                .init(id: UUID(), name: "Fall Promo", createdAt: Date().addingTimeInterval(-90 * 86_400), broughtBack: true),
                .init(id: UUID(), name: nil, createdAt: nil)])
        }.capture(into: folder)
        // Several things to say at once (the owner and the designer, 1 November): the most important
        // shows, "2 more" opens the others in the same order — the index, the proxy, the kept folders.
        let threeAtOnce = ProxyProblemBanner.Item(title: String(format: L("proxyProblem.title.notStarted"), rows[8].name),
                                                  text: String(format: L("proxyProblem.subtitle.notStarted"), "us-dal.proxy.example:1080"), // l10n: not text
                                                  notStarted: true, more: 2)
        let keptOne: [ProfileRepository.KeptDeletedProfile] = [
            .init(id: UUID(), name: "Retail Audit", createdAt: Date().addingTimeInterval(-40 * 86_400))]
        let unlisted = AppModel.IndexNotice(kind: .unlisted, folders: 3, vaultPath: vaultPath)
        problems += await Shot(name: "profiles-banners", size: CGSize(width: 1180, height: 640), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, indexNotice: unlisted, keptDeleted: keptOne, proxyProblem: threeAtOnce)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-banners-open", size: CGSize(width: 1180, height: 900), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, indexNotice: unlisted, keptDeleted: keptOne, proxyProblem: threeAtOnce,
                            bannersExpanded: true)
        }.capture(into: folder)
        // The network guard's notice at the foot (the lead, 7 November): the longest text, the
        // restart's, at the narrowest window, and one with the banners above it.
        problems += await Shot(name: "profiles-guard-restart", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620),
                               edges: true) {
            ProfilesPreview(rows: rows, sync: .off, guardNotice: .restartNeeded)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-engines", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620), edges: true) {
            ProfilesPreview(rows: rows, sync: .off,
                            engineWarning: EngineWarning.Facts(safari: "27.2", engine: "26.6.2", macOS: 26)) // l10n: not text
        }.capture(into: folder)
        // After an update, the launch it made says which version runs now (the lead, 7 November).
        problems += await Shot(name: "profiles-updated", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, updatedTo: "0.1.5") // l10n: not text
        }.capture(into: folder)
        problems += await Shot(name: "profiles-guard-banners", size: CGSize(width: 1180, height: 640), edges: true) {
            ProfilesPreview(rows: rows, sync: .off, indexNotice: unlisted, proxyProblem: threeAtOnce, guardNotice: .notInstalled)
        }.capture(into: folder)
        problems += await Shot(name: "profiles-no-matches", size: CGSize(width: 1180, height: 520), edges: true) {
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
        // The versions of the settings a sync kept beside them (R4, R2), one of them unreadable.
        let now = Date()
        func version(_ file: String, _ origin: KeptSettings.Origin, _ device: String?, host: String?, changed: TimeInterval,
                     kept: TimeInterval) -> KeptSettings {
            KeptSettings(file: file, origin: origin, device: device, keptAt: now.addingTimeInterval(-kept),
                         configuration: ProfileConfiguration(proxy: host.map { ProxySettings(kind: .socks5, host: $0, port: 1080) },
                                                             settingsModifiedAt: now.addingTimeInterval(-changed)))
        }
        var unreadableVersion = version("config.bin.conflict-4", .unknown, nil, host: nil, changed: 0, kept: 9 * 86_400)
        unreadableVersion.configuration = nil
        let versions = [version("config.bin.conflict", .thisMac, "MacBook Pro", host: "de.gateway.example", changed: 3 * 86_400, kept: 2 * 86_400),
                        version("config.bin.conflict-2", .otherDevice, nil, host: "nl.gateway.example", changed: 86_400, kept: 3_600),
                        version("config.bin.conflict-3", .restored, "MacBook Pro", host: nil, changed: 30 * 86_400, kept: 600),
                        unreadableVersion]
        problems += await Shot(name: "editor-profile-versions", size: ProfileEditorForm.size, titled: false) {
            EditorPreview(draft: labelled, topic: .profile, isNew: false, error: nil, keptVersions: versions)
        }.capture(into: folder)
        // The editor in the narrowest Profiles window: no taller than the window has room for.
        problems += await Shot(name: "narrow-editor-location", size: narrow(ProfileEditorForm.size), titled: false) {
            EditorPreview(draft: location, topic: .location, isNew: false, error: nil).environment(\.sheetRoom, narrowRoom)
        }.capture(into: folder)
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
            problems += await Shot(name: "narrow-sheet-passwords-locked", size: narrow(CGSize(width: 780, height: 560)), titled: false) {
                PasswordListView(profile: northwind).environmentObject(model).environment(\.sheetRoom, narrowRoom)
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
        problems += await Shot(name: "sheet-sync", size: CGSize(width: 620, height: 640), titled: false) {
            SyncSettingsView().environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-automation", size: CGSize(width: 620, height: 640), titled: false) {
            AutomationSettingsView().environmentObject(model)
        }.capture(into: folder)
        problems += await Shot(name: "narrow-sheet-automation", size: narrow(CGSize(width: 620, height: 640)), titled: false) {
            AutomationSettingsView().environmentObject(model).environment(\.sheetRoom, narrowRoom)
        }.capture(into: folder)
        problems += await Shot(name: "sheet-change-password", size: CGSize(width: 480, height: 660), titled: false) {
            ChangePasswordView().environmentObject(model)
        }.capture(into: folder)
        problems += await settings(into: folder, model: model)
        problems += await proxyList(into: folder)
        // A real browser window of a running profile (WebKit, toolbar, tab strip, start page).
        problems += await browserWindows(into: folder)
        // The launch screen (the Profiles window before unlocking), also while the vault opens.
        let lockModel = AppModel()
        // The lock screen (the design's "Lock and first launch"), on its eclipses.
        problems += await Shot(name: "launch-unlock", size: CGSize(width: 1180, height: 740), edges: true) {
            LockBackdrop { UnlockView().environmentObject(lockModel) }
        }.capture(into: folder)
        problems += await Shot(name: "launch-setup", size: CGSize(width: 1180, height: 820), edges: true) {
            LockBackdrop { SetupView().environmentObject(lockModel) }
        }.capture(into: folder)
        // §10.1: a master password that is the license's key, refused under its field.
        let refusedModel = AppModel()
        refusedModel.masterPasswordRefusal = L("contract.master_password.same_as_key")
        problems += await Shot(name: "launch-setup-same-as-key", size: CGSize(width: 1180, height: 900), edges: true) {
            LockBackdrop { SetupView().environmentObject(refusedModel) }
        }.capture(into: folder)
        // The first launch's first screen with an account server: the sign-in, the interface's
        // language on it (FirstLaunchLanguagePicker).
        problems += await Shot(name: "launch-sign-in", size: CGSize(width: 1180, height: 820), edges: true) {
            LockBackdrop { SignInFlow(license: previewLicenses().signedOut, onFinished: {}, standalone: false).environmentObject(lockModel) }
        }.capture(into: folder)
        // While the password is checked the eclipses close in; once the vault opens they part.
        problems += await Shot(name: "launch-working", size: CGSize(width: 1180, height: 740), edges: true) {
            LockBackdrop(phase: .busy) {
                LockScreen(title: L("unlock.title"), subtitle: L("unlock.subtitle")) {
                    LockActionButton(title: L("unlock.action.unlock"), working: true, workingTitle: L("unlock.working")) {}
                        .padding(.top, 36)
                }
            }
        }.capture(into: folder)
        problems += await Shot(name: "launch-open", size: CGSize(width: 1180, height: 740), edges: true) {
            LockBackdrop(phase: .open) { VaultOpenView() }
        }.capture(into: folder)
        problems += await Shot(name: "app-icon", size: CGSize(width: 900, height: 640), titled: false) {
            AppIconSheet()
        }.capture(into: folder)
        problems += await Shot(name: "brand", size: CGSize(width: 900, height: 560), titled: false) {
            BrandSheet()
        }.capture(into: folder)
        // The design system ("Eclipse"): the black scale, text, states, every control, profile
        // letters, rows, and the light — what every window is built from.
        problems += await Shot(name: "design-system", size: CGSize(width: 1240, height: 980), titled: false) {
            DesignSystemSheet()
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
        silent.proxyLocationLookupFailed = true
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
                            _ latencies: [Int], asn: String? = nil, organization: String? = nil,
                            udp: ProxyUDPSupport? = nil) -> ProxyCheckResult {
        var result = ProxyCheckResult(checkedAt: Date().addingTimeInterval(-12 * 60), exitIP: ip, countryCode: country,
                                      timeZoneIdentifier: zone,
                                      diagnosis: ProxyDiagnosis(verdict: .works, kinds: [kind], authentication: .accepted,
                                                                connectedAddress: ip, latencies: latencies,
                                                                latencyAttempts: latencies.count),
                                      city: city, asn: asn, organization: organization)
        result.latencyMilliseconds = result.diagnosis?.medianLatency
        result.udp = udp
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
    /// after connecting, login rejected, host not found, a VPN's substitute DNS, refused, no
    /// connection), one whose type the first check is to find, and one given by PrivacyBrowser's
    /// service. Berlin first, the silent one fourth, the VPN's substitute DNS seventh, the
    /// service's last.
    static func sampleProxyEntries() -> [ProxyListEntry] {
        [
            ProxyListEntry(label: "Berlin 1", proxy: ProxySettings(kind: .socks5, host: "203.0.113.10", port: 1080,
                                                                   username: "northwind", password: "sample"),
                           lastCheck: sampleWorks(.socks5, "203.0.113.10", "DE", "Europe/Berlin", "Berlin", [80, 84, 97],
                                                  asn: "AS64500", organization: "Example Networks", udp: .supported)),
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
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "gate.example.org", port: 1080),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .substituteDNS, connectedAddress: "198.18.0.91"))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "192.0.2.99", port: 1080),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .refused))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "198.51.100.77", port: 9000),
                           lastCheck: sampleFailed(ProxyDiagnosis(verdict: .connectTimeout))),
            ProxyListEntry(proxy: ProxySettings(kind: .socks5, host: "gw.example.com", port: 9000, username: "user-country-de",
                                                password: "sample"),
                           kindKnown: false),
            ProxyListEntry(label: "Service DE", proxy: ProxySettings(kind: .socks5, host: "de1.service.example", port: 1080,
                                                                   username: "pb-7f3a", password: "sample"),
                           addedAt: Date(timeIntervalSince1970: 1_790_000_000),
                           lastCheck: sampleWorks(.socks5, "203.0.113.30", "DE", "Europe/Berlin", "Frankfurt", [61, 64, 70]),
                           origin: .service),
        ]
    }

    // MARK: Proxy list

    /// The Proxies section with proxies as checks left them — working (one of them slow), each way
    /// of failing the list tells apart (silent after connecting, login rejected, host not found, a
    /// VPN's substitute DNS, refused, no connection), one whose type the first check is to find,
    /// one from PrivacyBrowser's service — from a temporary vault; its report on the silent one, on
    /// the one behind a VPN's substitute DNS, on the service's and on a working one; the Edit and
    /// Export sheets; and what a profile whose proxy did not work at its launch says. Nothing is
    /// checked here and nothing goes to the network.
    private static func proxyList(into folder: URL) async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-snapshots-proxies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let vault = try MasterVault.create(in: root, password: "snapshots", iterations: 10_000)
            let entries = sampleProxyEntries()
            let berlin = entries[0], silent = entries[3], substitute = entries[6], service = entries[entries.count - 1]
            try ProxyList(entries: entries).save(to: vault)
            let proxies = ProxyListModel(vault: vault) { print("FAIL sample proxy list: \($0)") }
            let counts = [ProxyList.identity(of: berlin.proxy): 3, ProxyList.identity(of: silent.proxy): 2,
                          ProxyList.identity(of: entries[1].proxy): 1]
            // The sample rows' profiles, with their glyphs' colours.
            let sample = sampleRows()
            func using(_ indices: [Int]) -> [ProxyProfileReference] {
                indices.map { ProxyProfileReference(id: sample[$0].id, name: sample[$0].name, avatar: sample[$0].avatar) }
            }
            let names = [ProxyList.identity(of: berlin.proxy): using([1, 2, 4]),
                         ProxyList.identity(of: silent.proxy): using([8, 6]),
                         ProxyList.identity(of: entries[1].proxy): using([3])]
            var problems = 0
            // The Profiles window's Proxies section with its inspector: wide, with a proxy that stays
            // silent selected; in the narrowest window, with one that works (the inspector over the list).
            let rows = sampleRows()
            func section(selecting ids: Set<UUID>) -> AnyView {
                AnyView(ProxyListPanel(proxies: proxies, profileCounts: counts, profilesUsing: names, selection: .constant(ids)))
            }
            problems += await Shot(name: "proxies", size: CGSize(width: 1400, height: 860), edges: true) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: [silent.id]))
            }.capture(into: folder)
            problems += await Shot(name: "proxies-substitute-dns", size: CGSize(width: 1400, height: 860), edges: true) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: [substitute.id]))
            }.capture(into: folder)
            problems += await Shot(name: "proxies-service", size: CGSize(width: 1400, height: 860), edges: true) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: [service.id]))
            }.capture(into: folder)
            problems += await Shot(name: "proxies-working", size: CGSize(width: 1400, height: 860), edges: true) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: [berlin.id]))
            }.capture(into: folder)
            problems += await Shot(name: "proxies-several", size: CGSize(width: 1400, height: 860), edges: true) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count,
                                proxies: section(selecting: [berlin.id, silent.id, entries[1].id]))
            }.capture(into: folder)
            problems += await Shot(name: "proxies-narrow", size: CGSize(width: ProfilesScreen.minimumWindowWidth, height: 620), edges: true) {
                ProfilesPreview(rows: rows, section: .proxies, proxyCount: entries.count, proxies: section(selecting: [berlin.id]))
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
            problems += await Shot(name: "narrow-sheet-proxy-problem", size: narrow(CGSize(width: 580, height: 600)), titled: false) {
                ProxyProblemPanel(problem: problem, more: 1, check: { nil }, close: {}, showInList: {})
                    .environment(\.sheetRoom, narrowRoom)
            }.capture(into: folder)
            return problems
        } catch {
            print("FAIL could not make the sample proxy list: \(error)")
            return 1
        }
    }

    // MARK: The list after a profile comes back

    /// The owner, 1 November: a profile's window closed and the Profiles window came back with
    /// "Profiles: 29" over a blank list, its rows there only once scrolled up. The same steps in a
    /// window of the app's: 29 profiles, none running, the list scrolled to its foot; the last one
    /// launched (its row goes up to Running, at the list's top, out of sight), its window over this
    /// one; stopped (sealing, still among Running), this window back in front; sealed (back among
    /// the others, Running gone). Where the list is scrolled to it must show rows, back in front
    /// and once sealed (`list-return-back.png`, `list-return.png`). The control takes the same
    /// steps with the list in its former shape (`lazyProfileListControl`): blank there, the steps
    /// leave that list as the owner saw it and the check sees it; rows there too, they do not here,
    /// and the check cannot tell — said, not passed.
    private static func listAfterReturn(into folder: URL) async -> Int {
        guard let list = await returnSteps(name: "list-return", lazy: false, into: folder) else { return 1 }
        var problems = 0
        for (moment, sight) in [("back in front", list.back), ("once sealed", list.sealed)] {
            if sight.showsRows {
                print("PASS list-return: \(moment), the list shows its rows where it is scrolled to — \(sight.said)")
            } else {
                print("FAIL list-return: \(moment), the list is blank where it is scrolled to — \(sight.said)")
                problems += 1
            }
        }
        guard let control = await returnSteps(name: "list-return-control", lazy: true, into: folder) else {
            print("FAIL list-return-control: its steps could not be taken — the check cannot tell")
            return problems + 1
        }
        if control.back.showsRows && control.sealed.showsRows {
            print("WARN list-return-control: the list's former shape shows its rows too (back in front: \(control.back.said); "
                + "once sealed: \(control.sealed.said)) — here the steps do not leave it blank, so the check cannot tell")
        } else {
            print("PASS list-return-control: the list's former shape is blank after the same steps (back in front: "
                + "\(control.back.said); once sealed: \(control.sealed.said)) — the check sees what the owner saw")
        }
        return problems
    }

    /// What the list's viewport showed: how far down it was scrolled, and the share of bright
    /// pixels — the rows' text — in its upper and lower halves.
    private struct ReturnSight {
        var scrolledDown: CGFloat
        var contentHeight: CGFloat
        var upper: Double
        var lower: Double

        /// Rows' names are 0.9–3 % of a band of the list in CI run 556's pictures of it; where only
        /// the window's black and its eclipses are drawn, 0 %.
        static let rowsShare = 0.0015
        var showsRows: Bool { upper >= Self.rowsShare && lower >= Self.rowsShare }
        var said: String {
            String(format: "bright %.2f %% above, %.2f %% below, scrolled %ld pt down of %ld", upper * 100, lower * 100,
                   Int(scrolledDown), Int(contentHeight))
        }
    }

    private struct ReturnSights {
        var back: ReturnSight
        var sealed: ReturnSight
    }

    /// 29 profiles, none running, each with a name in the rows' brightest text.
    private static func returnRows() -> [ProfileRowItem] {
        let mac = ProfileRowItem.appearsAs(DeviceGenerations.resolved(id: "macos-26"), hostSafariVersion: HostSafari.version)
        let countries: [String?] = ["DE", "NL", "US", "PT", nil, "FR", "PL"]
        let now = Date()
        return (1...29).map { n -> ProfileRowItem in
            let byte = UInt8(n)
            let exit: ProfileExit = countries[n % countries.count].map {
                .proxy(endpoint: "\($0.lowercased()).gateway.example:1080", countryCode: $0) // l10n: not text
            } ?? .direct
            return ProfileRowItem(id: UUID(uuid: (0x29, byte, 0x5E, 0x17, 0, byte, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, byte)),
                                  name: String(format: "Account %02d", n), activity: .stopped, exit: exit, // l10n: not text
                                  ephemeral: false, appearsAs: mac, lastUsed: now.addingTimeInterval(TimeInterval(-n * 3_600)))
        }
    }

    /// The steps in a window of the app's, the list as it is or (`lazy`) in its former shape; nil
    /// when they could not be taken, which is said.
    private static func returnSteps(name: String, lazy: Bool, into folder: URL) async -> ReturnSights? {
        let live = LiveRows(returnRows())
        guard let last = live.rows.last?.id else { return nil }
        let size = CGSize(width: 1180, height: 740)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        Theme.applyAppWindow(to: window)
        let host = NSHostingView(rootView: LiveProfilesPreview(live: live)
            .environment(\.colorScheme, .dark)
            .environment(\.lumenStillFrame, true)
            .environment(\.lazyProfileListControl, lazy)
            .environment(\.tagColors, sampleTagColors)
            .tint(Theme.accentFill))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        window.makeKey()
        defer {
            window.orderOut(nil)
            window.close()
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let scroll = listScrollView(in: host) else {
            print("FAIL \(name): the list's scroll view was not found — the check cannot tell")
            return nil
        }
        scrollToFoot(scroll)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard scrolledDown(scroll) > 200 else {
            print("FAIL \(name): the list did not scroll down (\(Int(scrolledDown(scroll))) pt of \(Int(contentHeight(scroll)))) — the check cannot tell")
            return nil
        }
        // Launched: its row goes up to Running, at the list's top.
        live.set(last, .starting)
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Its window comes over this one.
        let profileWindow = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20), styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        profileWindow.isReleasedWhenClosed = false
        profileWindow.backgroundColor = .white
        profileWindow.orderFrontRegardless()
        live.set(last, .running)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Stopped: sealing, still among Running.
        live.set(last, .sealing)
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Its window closes; this one comes back in front (AppModel.activateProfilesWindow).
        profileWindow.orderOut(nil)
        profileWindow.close()
        window.orderFrontRegardless()
        window.makeKey()
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard let back = sight(of: host, scroll: scroll, name: "\(name)-back", into: folder) else { return nil }
        // Sealed: back among the others, Running gone.
        live.set(last, .stopped)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let sealed = sight(of: host, scroll: scroll, name: name, into: folder) else { return nil }
        return ReturnSights(back: back, sealed: sealed)
    }

    /// The list's scroll view: of those in the window, the one with the tallest content.
    private static func listScrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            var found = view.subviews.flatMap(all)
            if let scroll = view as? NSScrollView { found.append(scroll) }
            return found
        }
        return all(view).max { contentHeight($0) < contentHeight($1) }
    }

    private static func contentHeight(_ scroll: NSScrollView) -> CGFloat {
        scroll.documentView?.frame.height ?? 0
    }

    /// How far from the top of its content the list is scrolled.
    private static func scrolledDown(_ scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView.bounds
        guard let document = scroll.documentView else { return 0 }
        return document.isFlipped ? clip.minY : document.frame.height - clip.maxY
    }

    private static func scrollToFoot(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let y = document.isFlipped ? max(0, document.frame.height - clip.bounds.height) : 0
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// The window's picture now (`<name>.png`) and what the list's viewport shows in it, without
    /// the rows' left inset and the scroller.
    private static func sight(of host: NSView, scroll: NSScrollView, name: String, into folder: URL) -> ReturnSight? {
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("FAIL no bitmap for \(name)")
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]),
           (try? data.write(to: folder.appendingPathComponent("\(name).png"))) != nil {
            print("WROTE \(name).png (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } else {
            print("FAIL could not write \(name).png")
            return nil
        }
        let frame = scroll.convert(scroll.bounds, to: host)
        let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        let scale = CGFloat(rep.pixelsWide) / max(1, host.bounds.width)
        let x0 = Int((frame.minX + 24) * scale), x1 = Int((frame.maxX - 24) * scale)
        let y0 = Int((top + 8) * scale), y1 = Int((top + frame.height - 8) * scale)
        guard x1 - x0 > 100, y1 - y0 > 100 else {
            print("FAIL \(name): the list's viewport is \(Int(frame.width))×\(Int(frame.height)) pt — the check cannot tell")
            return nil
        }
        func share(_ from: Int, _ to: Int) -> Double {
            var bright = 0, all = 0
            for y in stride(from: from, to: to, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    all += 1
                    let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    if luminance > 0.6 { bright += 1 }
                }
            }
            return all == 0 ? 0 : Double(bright) / Double(all)
        }
        let middle = (y0 + y1) / 2
        return ReturnSight(scrolledDown: scrolledDown(scroll), contentHeight: contentHeight(scroll),
                           upper: share(y0, middle), lower: share(middle, y1))
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
        // New Profile: the header's last button, its right edge `headerTrailing` from the window's,
        // in the middle of the header's height (the layout's own numbers, `ProfilesScreen`).
        click(window, at: NSPoint(x: width - ProfilesScreen.headerTrailing - 30,
                                  y: height - ProfilesScreen.headerTop - ProfilesScreen.headerHeight / 2))
        // Lock: the sidebar's last row, from 12 pt to the Settings button, 14 pt above the bottom, 30 pt high.
        click(window, at: NSPoint(x: ProfilesScreen.sidebarWidth / 2, y: 14 + 15))
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

    /// The sheet a window shows lies within the window, not cut by it: for the window that gives
    /// its sheets their room. For the control, which does not, the sheet is expected cut; one that
    /// fits there too means the check cannot tell, which is said. Writes `<name>-sheet.png`.
    private static func sheetFitTest(_ window: NSWindow, name: String, givesRoom: Bool, into folder: URL) async -> Int {
        var attached: NSWindow?
        for _ in 0..<50 where attached == nil {
            attached = window.attachedSheet
            if attached == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let sheet = attached else {
            print("FAIL \(name): no sheet appeared on the window")
            return 1
        }
        // The sheet slides out of the title bar: its frame is final once that is over.
        try? await Task.sleep(nanoseconds: 800_000_000)
        let fits = window.frame.insetBy(dx: -0.5, dy: -0.5).contains(sheet.frame)
        let sizes = "window \(Int(window.frame.width))×\(Int(window.frame.height)), "
            + "sheet \(Int(sheet.frame.width))×\(Int(sheet.frame.height)) "
            + "at \(Int(sheet.frame.minX - window.frame.minX)), \(Int(window.frame.maxY - sheet.frame.maxY)) from the window's top left"
        var problems = 0
        if let frameView = sheet.contentView?.superview ?? sheet.contentView,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]),
               (try? data.write(to: folder.appendingPathComponent("\(name)-sheet.png"))) != nil {
                print("WROTE \(name)-sheet.png (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            } else {
                print("FAIL could not write \(name)-sheet.png")
                problems += 1
            }
        }
        if givesRoom {
            print("\(fits ? "PASS" : "FAIL") a sheet of the narrowest window lies within it: \(sizes)")
            problems += fits ? 0 : 1
        } else if fits {
            print("WARN \(name): the sheet fits without the room too, so the check cannot tell: \(sizes)")
        } else {
            print("PASS the control's sheet, at the size it asks for, is cut by the window: \(sizes)")
        }
        window.endSheet(sheet)
        sheet.orderOut(nil)
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
        var commands = [CommandPaletteView.Command(id: "new", title: L("palette.newProfile"), symbol: "plus", shortcut: "⌘N", run: {})]
        for row in rows {
            let detail = row.paletteDetail
            let key = row.isRunning ? "palette.newWindow" : "palette.launch"
            commands.append(CommandPaletteView.Command(id: "row-\(row.id)", title: String(format: L(key), row.name),
                                                       detail: detail, symbol: row.isRunning ? "macwindow.badge.plus" : "play.circle",
                                                       group: .profiles, run: {}))
        }
        commands.append(CommandPaletteView.Command(id: "proxies", title: L("palette.proxies"), symbol: "network", run: {}))
        for section in SettingsSection.allCases.prefix(4) {
            commands.append(CommandPaletteView.Command(id: section.rawValue, title: String(format: L("palette.settings"), L(section.titleKey)),
                                                       symbol: section.symbol, group: .settings, run: {}))
        }
        return commands
    }

    /// What the inspector shows of the sample's Northwind: its settings, what it keeps, its proxy's
    /// last check.
    static func inspectorSample() -> InspectorInfo {
        let proxy = ProxySettings(kind: .socks5, host: "proxy.northwind.example", port: 1080) // l10n: not text
        var configuration = ProfileConfiguration(proxy: proxy)
        configuration.matchProxyLocation = true
        configuration.webRTCPolicy = .relayOnly
        configuration.lastProxyLocation = ProxyLocation(timeZoneIdentifier: "Europe/Berlin", countryCode: "DE", // l10n: not text
                                                        proxyEndpoint: ProxyLocation.endpoint(of: proxy), exitIP: "203.0.113.47")
        configuration.languageOverride = "de-DE" // l10n: not text
        configuration.windowSize = .custom(width: 1440, height: 900)
        configuration.tags = ["ads", "DE"] // l10n: not text
        var check = ProxyCheckResult(checkedAt: Date().addingTimeInterval(-40 * 60), exitIP: "203.0.113.47", countryCode: "DE",
                                     timeZoneIdentifier: "Europe/Berlin", latencyMilliseconds: 84,
                                     city: "Frankfurt am Main") // l10n: not text
        check.udp = .unsupported
        return InspectorInfo(details: ProfileDetails(configuration),
                             counts: ProfileCounts(logins: 6, bookmarks: 41, historyEntries: 271, syncedCookies: 1_284),
                             proxyCheck: check)
    }

    /// The sample vault's tags' colours: some coloured, some not, as a person leaves them.
    static let sampleTagColors: TagColors = {
        var colors = TagColors()
        let chosen = Date(timeIntervalSince1970: 1_800_000_000)
        colors.set(0, for: "ads", at: chosen)
        colors.set(1, for: "clients", at: chosen)
        colors.set(2, for: "warm-up", at: chosen)
        colors.set(6, for: "Q4 campaign", at: chosen)
        return colors
    }()

    static func sampleRows() -> [ProfileRowItem] {
        func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0x1C, 0x5E, 0x17, 0, n, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }
        let mac = ProfileRowItem.appearsAs(DeviceGenerations.resolved(id: "macos-26"), hostSafariVersion: HostSafari.version)
        let iPhone = ProfileRowItem.appearsAs(DeviceGenerations.resolved(id: "ios-26"), hostSafariVersion: HostSafari.version)
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
                           tags: ["warm-up", "Q4 campaign", "NL", "mobile"], deviceSymbol: "iphone"),
            ProfileRowItem(id: id(5), name: "Travel", activity: .sealing,
                           exit: .proxy(endpoint: "lisbon.example:1080", countryCode: "PT"), ephemeral: false,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-60)),
            ProfileRowItem(id: id(6), name: "Shopping", activity: .stopped, exit: .direct, ephemeral: true,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-3 * 86_400)),
            // At its last launch no geolocation service answered through its proxy.
            ProfileRowItem(id: id(7), name: "Banking", activity: .stopped,
                           exit: .proxy(endpoint: "10.20.0.2:3128", countryCode: nil), ephemeral: false,
                           appearsAs: mac, lastUsed: nil, exitUnconfirmed: true, tags: ["ads"]),
            // Its settings could not be read: not "Direct", and it does not start (R1).
            ProfileRowItem(id: id(8), name: "Archive", activity: .stopped, exit: .unreadable, ephemeral: false,
                           appearsAs: "—", lastUsed: now.addingTimeInterval(-30 * 86_400)),
            // Its last launch failed, its proxy not answering: among "Need attention".
            ProfileRowItem(id: id(9), name: "Marketplace US", activity: .stopped,
                           exit: .proxy(endpoint: "us-dal.proxy.example:1080", countryCode: "US"), ephemeral: false,
                           appearsAs: mac, lastUsed: now.addingTimeInterval(-2 * 3_600), tags: ["clients"],
                           problem: "us-dal.proxy.example:1080"), // l10n: not text
        ]
    }
}

// MARK: - Capturing

/// One screen to capture: a SwiftUI view in a window of the app's style.
///
/// For design review, not a check of the app's windows: the window is this file's own, made here,
/// and `cacheDisplay` draws the content alone — not the title bar or a toolbar the window server
/// adds. A Settings window with a grey band at its top passed here (the owner, 2 November); the real
/// one is checked by `SettingsWindowCheck`.
@MainActor
private struct Shot {
    let name: String
    let size: CGSize
    var titled = true
    /// A window of the app's own (Profiles, Settings, the lock screen): hosted as the app hosts it —
    /// filling whatever the window gives, not forced to `size` — over a window background in a probe
    /// colour no screen uses. Where that colour, or nothing at all, shows along an edge, the content
    /// does not reach the window's edge there (`edgeProblems`): the owner's Settings window had a
    /// band of the system's grey at its foot (1 November), and a window background in the content's
    /// own tone had hidden it from every snapshot.
    var edges = false
    let content: () -> AnyView

    init<V: View>(name: String, size: CGSize, titled: Bool = true, edges: Bool = false,
                  @ViewBuilder content: @escaping () -> V) {
        self.name = name
        self.size = size
        self.titled = titled
        self.edges = edges
        self.content = { AnyView(content()) }
    }

    /// A colour no screen of the app uses.
    private static let probe = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

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
        window.backgroundColor = edges ? Self.probe : Theme.NS.backdrop
        // The state a window settles in: no entry animation is caught half-way.
        let root = edges ? AnyView(content().frame(maxWidth: .infinity, maxHeight: .infinity))
            : AnyView(content().frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root
            .environment(\.colorScheme, .dark)
            .environment(\.lumenStillFrame, true)
            .environment(\.tagColors, UISnapshots.sampleTagColors)
            .tint(Theme.accentFill))
        // The window keeps the size it is given; the content does not set it.
        if edges { host.sizingOptions = [] }
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
            if edges { problems += Self.edgeProblems(rep, name: name) }
        } else {
            print("FAIL no bitmap for \(name)")
            problems += 1
        }
        if let extra { problems += await extra(window) }
        window.orderOut(nil)
        window.close()
        return problems
    }

    /// Each edge of the picture, in a band of 3 pixels and without its corners (the window's
    /// rounding): any pixel there in the probe's colour, or not drawn at all, is the window's own
    /// background showing — the content stops short of that edge.
    private static func edgeProblems(_ rep: NSBitmapImageRep, name: String) -> Int {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let band = 3, corner = 16
        guard width > 2 * corner, height > 2 * corner else { return 0 }
        func showsWindow(_ x: Int, _ y: Int) -> Bool {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return true }
            if color.alphaComponent < 0.98 { return true }
            return color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent > 0.8
        }
        var found: [String] = []
        let across = corner..<(width - corner), down = corner..<(height - corner)
        let edges: [(String, [(Int, Int)])] = [
            ("top", across.flatMap { x in (0..<band).map { (x, $0) } }),
            ("bottom", across.flatMap { x in (0..<band).map { (x, height - 1 - $0) } }),
            ("left", down.flatMap { y in (0..<band).map { ($0, y) } }),
            ("right", down.flatMap { y in (0..<band).map { (width - 1 - $0, y) } }),
        ]
        for (edge, points) in edges {
            let showing = points.filter { showsWindow($0.0, $0.1) }.count
            if showing > 0 { found.append("\(edge) \(showing) px") }
        }
        guard found.isEmpty else {
            print("FAIL \(name): the window's own background shows at its edges — \(found.joined(separator: ", ")) (the content does not reach the window's edge)")
            return 1
        }
        print("PASS \(name): the content reaches every edge of its window")
        return 0
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

/// A window's content that shows one sheet as the Profiles window shows its own: giving it its
/// room (`providesSheetRoom`, RootView's) or, as the control, not.
private struct SheetHost<Sheet: View>: View {
    let givesRoom: Bool
    @ViewBuilder let sheet: () -> Sheet
    @State private var showing = false

    var body: some View {
        let host = Color.clear
            .sheet(isPresented: $showing) { sheet() }
            // Shown once the window is on screen, as a sheet opened from it would be.
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                showing = true
            }
        if givesRoom {
            host.providesSheetRoom()
        } else {
            host
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
    var keptVersions: [KeptSettings] = []

    var body: some View {
        // A saved profile's editor has its What Sites See button, as ProfileEditorView gives it.
        ProfileEditorForm(draft: $draft, topic: $topic, isNew: isNew, avatarID: UISnapshots.sampleRows()[1].id,
                          error: error, guardReady: false, savedProxies: savedProxies,
                          knownTags: ["ads", "DE", "US", "warm-up", "Q4 campaign"], visibleScreen: visibleScreen,
                          keptVersions: keptVersions, onWhatSitesSee: isNew ? nil : {})
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
    var indexNotice: AppModel.IndexNotice?
    var keptDeleted: [ProfileRepository.KeptDeletedProfile] = []
    var showsInspector = false
    var selected: [UUID] = []
    var inspectorInfo: (UUID) -> InspectorInfo = { _ in InspectorInfo() }
    var proxyProblem: ProxyProblemBanner.Item?
    var bannersExpanded = false
    var guardNotice: WebRTCProtectionNotice?
    var engineWarning: EngineWarning.Facts?
    var updatedTo: String?

    var body: some View {
        ProfilesScreen(rows: rows, isWorking: isWorking, sync: sync, filter: $filter, search: $search, actions: actions,
                       section: .constant(section), proxyCount: proxyCount, proxies: proxies, indexNotice: indexNotice,
                       keptDeleted: keptDeleted, showsInspector: .constant(showsInspector), inspectorInfo: inspectorInfo,
                       guardReady: true, initialSelection: selected, initialBannersExpanded: bannersExpanded,
                       proxyProblem: proxyProblem, guardNotice: guardNotice, engineWarning: engineWarning,
                       updatedTo: updatedTo)
    }
}

/// Rows that change while their window is shown, as the app's model changes them
/// (`UISnapshots.listAfterReturn`).
@MainActor
private final class LiveRows: ObservableObject {
    @Published var rows: [ProfileRowItem]

    init(_ rows: [ProfileRowItem]) {
        self.rows = rows
    }

    func set(_ id: UUID, _ activity: ProfileRowItem.Activity) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].activity = activity
    }
}

private struct LiveProfilesPreview: View {
    @ObservedObject var live: LiveRows
    @State private var filter: ProfileFilter = .all
    @State private var search = ""

    var body: some View {
        ProfilesScreen(rows: live.rows, filter: $filter, search: $search)
    }
}

// MARK: - Brand and flags sheets

/// The design system on one sheet (the design's "Palette and components").
private struct DesignSystemSheet: View {
    @State private var segment = 1
    @State private var on = true
    @State private var off = false
    @State private var text = "de-fra.proxy.example"
    @State private var wrong = "108000"

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 22) {
                Text(verbatim: "Lumen").lumenPageTitle().foregroundStyle(Theme.textPrimary)
                part("Black scale") {
                    HStack(spacing: 8) {
                        ForEach(Array([Theme.backdrop, Theme.sidebar, Theme.card, Theme.raisedInset, Theme.field].enumerated()), id: \.offset) { _, color in
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                                .frame(width: 56, height: 40)
                        }
                    }
                }
                part("Text") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "t1 Northwind · Хранилище заблокировано").foregroundStyle(Theme.textPrimary)
                        Text(verbatim: "t2 Пояснения, счётчики").foregroundStyle(Theme.textSecondary)
                        Text(verbatim: "t3 Подписи разделов, мета").foregroundStyle(Theme.textTertiary)
                        Text(verbatim: "t4 Только неактивное").foregroundStyle(Theme.textDisabled)
                    }
                    .font(.lumenBody)
                }
                part("States") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { RunningDot(); Text(verbatim: "Работает").foregroundStyle(Theme.textPrimary) }
                        HStack(spacing: 8) { Text(verbatim: "Прогрев 4/12").foregroundStyle(Theme.textPrimary); LumenProgressBar(fraction: 0.33, width: 48) }
                        Text(verbatim: "Нужен логин").foregroundStyle(Theme.warning)
                        Text(verbatim: "Не запустился").foregroundStyle(Theme.danger)
                        Text(verbatim: "вчера").foregroundStyle(Theme.textTertiary)
                    }
                    .font(.lumenBody)
                }
                part("Light") {
                    ZStack {
                        Theme.backdrop
                        EclipseLight(place: .thumbnail)
                        Text(verbatim: "Хранилище заблокировано").font(.lumenSection).foregroundStyle(Theme.textPrimary)
                    }
                    .frame(width: 400, height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                }
            }
            VStack(alignment: .leading, spacing: 22) {
                part("Buttons") {
                    HStack(spacing: 10) {
                        Button {} label: { Label { Text(verbatim: "Новый профиль") } icon: { Image(systemName: "plus") } }
                            .buttonStyle(.lumenPrimary)
                        Button(String("Открыть список")) {}.buttonStyle(.lumenSecondary)
                        Button(String("Отмена")) {}.buttonStyle(.lumenGhost)
                        Button(String("Удалить…")) {}.buttonStyle(.lumenDestructive)
                        Button(String("Неактивна")) {}.buttonStyle(.lumenPrimary).disabled(true)
                    }
                }
                part("Switches, checkboxes, choices") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 18) {
                            Toggle(String("off"), isOn: $off).toggleStyle(LumenSwitchStyle(showsLabel: false))
                            Toggle(String("on"), isOn: $on).toggleStyle(LumenSwitchStyle(showsLabel: false))
                            Toggle(String("Только отличия"), isOn: $off).toggleStyle(.lumenCheckbox)
                            Toggle(String("Выбран"), isOn: $on).toggleStyle(.lumenCheckbox)
                        }
                        HStack(spacing: 18) {
                            LumenRadio(title: "Запускать и говорить почему", isOn: true) {} // l10n: not text
                            LumenRadio(title: "Не запускать", isOn: false) {} // l10n: not text
                        }
                        LumenSegmented(selection: $segment, options: [(0, "Без прокси"), (1, "Из списка"), (2, "Новый")])
                    }
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                }
                part("Fields") {
                    HStack(spacing: 10) {
                        TextField("", text: $text).lumenField().frame(width: 220)
                        TextField("", text: $wrong).lumenField(error: true).frame(width: 120)
                        KeyCap(keys: "⌘K", small: true)
                        KeyCap(keys: "⇧⌘T")
                    }
                }
                part("Profiles") {
                    HStack(spacing: 14) {
                        ProfileAvatar(name: "Личный", id: UUID(), size: 30, running: true)
                        ProfileAvatar(name: "Northwind", id: UUID(), size: 30)
                        ProfileAvatar(name: "QA", id: UUID(), size: 30, style: ProfileAvatarStyle(letters: "QA"))
                        ProfileAvatar(name: "Northwind", id: UUID(), size: 56, running: true)
                        TagChips(tags: ["Работа", "QA"])
                    }
                }
                part("Rows") {
                    VStack(spacing: 2) {
                        designRow("Northwind", detail: "Работа", state: "Прогрев 4/12", fill: .clear)
                        designRow("Atlas · клиент", detail: "выбрана", state: "Работает 38 мин", fill: Theme.rowSelected)
                        designRow("Исследование", detail: "наведение", state: "вчера", fill: Theme.rowHover)
                    }
                    .frame(width: 560)
                }
                part("Type") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Хранилище заблокировано").lumenDisplayTitle()
                        Text(verbatim: "Профили").lumenPageTitle()
                        Text(verbatim: "Northwind").lumenHeadingTitle()
                        Text(verbatim: "Восстанавливать вкладки").font(.lumenRowTitle)
                        Text(verbatim: "Запущенные · подборки · сеть").lumenCaps()
                        Text(verbatim: "203.0.113.47 · de-fra.proxy.example:1080").font(.lumenMono).foregroundStyle(Theme.textSecondary)
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.backdrop)
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).lumenCaps()
            content()
        }
    }

    private func designRow(_ name: String, detail: String, state: String, fill: Color) -> some View {
        HStack(spacing: 10) {
            ProfileAvatar(name: name, id: UUID(), size: 22)
            Text(verbatim: name).font(.lumenLabel).foregroundStyle(Theme.textPrimary)
            Text(verbatim: detail).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(verbatim: state).font(.lumenBody).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
    }
}

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
