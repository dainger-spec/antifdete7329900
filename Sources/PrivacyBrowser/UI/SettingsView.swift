import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The app's settings, in one window (⌘, or ⋯ → Settings…): a section per subject, and every
/// setting with a sentence on what it does and when that takes effect.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State var section: SettingsSection = .startup
    /// The screenshots' updater, in place of the app's (`--render-ui-snapshots`).
    var previewUpdater: AppUpdater?

    static let size = CGSize(width: 840, height: 620)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.divider).frame(width: 1)
            ScrollView {
                pane
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(section)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.raised)
        .tint(Theme.accentFill)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("settings.title"))
                .font(.lumenSheetTitle)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.top, 34)
                .padding(.bottom, 14)
            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    Label(L(item.titleKey), systemImage: item.symbol)
                        .font(.lumenLabel)
                        .foregroundStyle(section == item ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .fill(section == item ? Theme.raisedInset : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .background(Theme.surface)
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .startup: StartupSettings(settings: model.settings)
        case .newProfiles: NewProfileSettings(settings: model.settings)
        case .behavior: BehaviorSettings(settings: model.settings)
        case .proxies: ProxySettingsPane(settings: model.settings)
        case .downloads: DownloadSettings(settings: model.settings)
        case .updates: UpdateSettings(previewUpdater: previewUpdater)
        case .shortcuts: ShortcutSettings()
        case .diagnostics: DiagnosticsSettings()
        case .about: AboutSettings()
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case startup, newProfiles, behavior, proxies, downloads, updates, shortcuts, diagnostics, about
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .startup: return "settings.section.startup"
        case .newProfiles: return "settings.section.newProfiles"
        case .behavior: return "settings.section.behavior"
        case .proxies: return "settings.section.proxies"
        case .downloads: return "settings.section.downloads"
        case .updates: return "settings.section.updates"
        case .shortcuts: return "settings.section.shortcuts"
        case .diagnostics: return "settings.section.diagnostics"
        case .about: return "settings.section.about"
        }
    }

    var symbol: String {
        switch self {
        case .startup: return "power"
        case .newProfiles: return "person.badge.plus"
        case .behavior: return "macwindow"
        case .proxies: return "network"
        case .downloads: return "arrow.down.circle"
        case .updates: return "arrow.triangle.2.circlepath"
        case .shortcuts: return "keyboard"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Building blocks

/// When a setting takes effect, said under it.
enum SettingEffect {
    /// At once, everywhere it applies.
    case now
    /// For tabs opened from then on.
    case newTabs
    /// When a profile next starts.
    case profileLaunch
    /// When the app next starts.
    case appStart
    /// For profiles created from then on; existing ones keep theirs.
    case newProfiles
    /// Not a choice: how it is, always.
    case always

    var text: String {
        switch self {
        case .now: return L("settings.effect.now")
        case .newTabs: return L("settings.effect.newTabs")
        case .profileLaunch: return L("settings.effect.profileLaunch")
        case .appStart: return L("settings.effect.appStart")
        case .newProfiles: return L("settings.effect.newProfiles")
        case .always: return L("settings.effect.always")
        }
    }

    var symbol: String {
        switch self {
        case .now: return "bolt"
        case .newTabs: return "plus.square.on.square"
        case .profileLaunch: return "arrow.clockwise"
        case .appStart: return "power"
        case .newProfiles: return "person.badge.plus"
        case .always: return "lock"
        }
    }
}

/// A section's page: its title, a sentence about it, and its settings one under the other.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.lumenSheetTitle)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.top, 10)
        }
    }
}

/// One setting: its title and its control, a sentence on what it does, and when that takes effect.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    let effect: SettingEffect?
    let control: Control

    init(_ title: String, detail: String, effect: SettingEffect?, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.effect = effect
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                control
            }
            Text(detail)
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let effect {
                Label(effect.text, systemImage: effect.symbol)
                    .font(.lumenCaption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// A switch for a setting row.
struct SettingSwitch: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}

/// A sentence for a whole section (where its settings do not reach, say).
struct SettingsNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.lumenSecondary)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
            .padding(.top, 12)
    }
}

// MARK: - Diagnostics

/// What support needs, without what is the user's: a ZIP saved where the person chooses, and a
/// short report to paste (`Diagnostics`). Nothing is sent.
private struct DiagnosticsSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var report = ""
    @State private var collecting = false
    @State private var outcome: String?
    @State private var copied = false

    var body: some View {
        SettingsPage(title: L("settings.section.diagnostics"), subtitle: L("settings.diagnostics.subtitle")) {
            HStack(spacing: 8) {
                Button {
                    collect()
                } label: {
                    Label(L("settings.diagnostics.collect"), systemImage: "archivebox")
                }
                .buttonStyle(.lumenPrimary)
                .disabled(collecting)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                } label: {
                    Label(L(copied ? "settings.diagnostics.copied" : "settings.diagnostics.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.lumenSecondary)
                .disabled(report.isEmpty)
                if collecting { ProgressView().controlSize(.small) }
            }
            .padding(.top, 12)
            if let outcome {
                Text(outcome)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
            Text(L("settings.diagnostics.report"))
                .font(.lumenSection)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 16)
            ScrollView {
                Text(verbatim: report.isEmpty ? "…" : report) // l10n: the report is for support, in English
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
            .padding(.top, 6)
            SettingsNote(text: L("settings.diagnostics.contents"))
        }
        .task {
            let snapshot = Diagnostics.snapshot(model: model)
            report = Diagnostics.shortReport(snapshot, checks: await Diagnostics.checks(snapshot))
        }
    }

    /// The ZIP, saved where the person chooses.
    private func collect() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Diagnostics.suggestedFileName()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        collecting = true
        outcome = nil
        Task {
            let data = await Diagnostics.bundle(Diagnostics.snapshot(model: model))
            do {
                try data.write(to: url, options: .atomic)
                outcome = String(format: L("settings.diagnostics.saved"), url.lastPathComponent)
            } catch {
                outcome = String(format: L("settings.diagnostics.failed"), error.localizedDescription)
            }
            collecting = false
        }
    }
}

// MARK: - Startup

private struct StartupSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: L("settings.section.startup"), subtitle: L("settings.startup.subtitle")) {
            SettingRow(L("settings.startup.open"), detail: L("settings.startup.open.detail"), effect: .appStart) {
                Picker(L("settings.startup.open"), selection: $settings.startup) {
                    Text(L("settings.startup.open.window")).tag(AppSettings.Startup.profilesWindow)
                    Text(L("settings.startup.open.reopen")).tag(AppSettings.Startup.reopenProfiles)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(L("settings.startup.restoreTabs"), detail: L("settings.startup.restoreTabs.detail"), effect: .profileLaunch) {
                SettingSwitch(isOn: $settings.browsing.restoreTabs, label: L("settings.startup.restoreTabs"))
            }
            SettingRow(L("settings.startup.confirmQuit"), detail: L("settings.startup.confirmQuit.detail"), effect: .now) {
                SettingSwitch(isOn: $settings.confirmQuit, label: L("settings.startup.confirmQuit"))
            }
        }
    }
}

// MARK: - New profiles

private struct NewProfileSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: L("settings.section.newProfiles"), subtitle: L("settings.newProfiles.subtitle")) {
            SettingRow(L("settings.newProfiles.matchConnection"), detail: L("settings.newProfiles.matchConnection.detail"),
                       effect: .newProfiles) {
                SettingSwitch(isOn: $settings.newProfileMatchesConnection, label: L("settings.newProfiles.matchConnection"))
            }
            SettingRow(L("settings.newProfiles.search"), detail: L("settings.newProfiles.search.detail"), effect: .newProfiles) {
                Picker(L("settings.newProfiles.search"), selection: $settings.newProfileSearchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { Text(verbatim: $0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(L("settings.newProfiles.local"), detail: L("settings.newProfiles.local.detail"), effect: .newProfiles) {
                SettingSwitch(isOn: $settings.newProfileBlocksLocalRequests, label: L("settings.newProfiles.local"))
            }
            SettingRow(L("settings.newProfiles.randomWindow"), detail: L("settings.newProfiles.randomWindow.detail"),
                       effect: .newProfiles) {
                SettingSwitch(isOn: $settings.newProfileRandomWindowSize, label: L("settings.newProfiles.randomWindow"))
            }
            SettingRow(L("settings.newProfiles.quic"), detail: L("settings.newProfiles.quic.detail"), effect: .always) {
                Text(L("settings.newProfiles.quic.value"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Behavior

private struct BehaviorSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: L("settings.section.behavior"), subtitle: L("settings.behavior.subtitle")) {
            SettingRow(L("settings.behavior.autoFill"), detail: L("settings.behavior.autoFill.detail"), effect: .now) {
                SettingSwitch(isOn: $settings.browsing.passwordAutoFill, label: L("settings.behavior.autoFill"))
            }
            SettingRow(L("settings.behavior.tabsNextToCurrent"), detail: L("settings.behavior.tabsNextToCurrent.detail"), effect: .now) {
                SettingSwitch(isOn: $settings.browsing.newTabsNextToCurrent, label: L("settings.behavior.tabsNextToCurrent"))
            }
            SettingRow(L("settings.behavior.warnClosing"), detail: L("settings.behavior.warnClosing.detail"), effect: .now) {
                SettingSwitch(isOn: $settings.browsing.warnClosingTabs, label: L("settings.behavior.warnClosing"))
            }
            SettingRow(L("settings.behavior.zoom"), detail: L("settings.behavior.zoom.detail"), effect: .newTabs) {
                Picker(L("settings.behavior.zoom"), selection: $settings.browsing.pageZoom) {
                    ForEach(BrowsingPreferences.zoomChoices, id: \.self) { zoom in
                        Text(zoom.formatted(.percent.precision(.fractionLength(0)))).tag(zoom)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if AppSettings.canChooseProfileProcesses {
                SettingRow(L("settings.behavior.ownProcesses"), detail: L("settings.behavior.ownProcesses.detail"), effect: .profileLaunch) {
                    SettingSwitch(isOn: Binding(get: { settings.profilesInOwnProcesses },
                                                set: { settings.profilesInOwnProcesses = $0 }),
                                  label: L("settings.behavior.ownProcesses"))
                }
            } else {
                SettingRow(L("settings.behavior.ownProcesses"), detail: L("settings.behavior.ownProcesses.sandboxed"), effect: .always) {
                    Text(L("settings.behavior.ownProcesses.off"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            SettingRow(L("settings.behavior.dockLetters"), detail: L("settings.behavior.dockLetters.detail"), effect: .now) {
                Picker(L("settings.behavior.dockLetters"), selection: $settings.browsing.dockInitials) {
                    Text(L("settings.behavior.dockLetters.none")).tag(0)
                    ForEach(1...3, id: \.self) { count in Text(verbatim: "\(count)").tag(count) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.profilesInOwnProcesses)
            }
            if AppSettings.canChooseProfileProcesses {
                SettingsNote(text: L("settings.behavior.safariNote"))
            }
        }
    }
}

// MARK: - Proxies

private struct ProxySettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: L("settings.section.proxies"), subtitle: L("settings.proxies.subtitle")) {
            SettingRow(L("settings.proxies.list"), detail: L("settings.proxies.list.detail"), effect: nil) {
                Button(L("settings.proxies.list.open")) { model.showProxyList() }
                    .buttonStyle(.lumenSecondary)
                    .disabled(model.proxyList == nil)
            }
            SettingRow(L("settings.proxies.checks"), detail: L("settings.proxies.checks.detail"), effect: .always) {
                Text(L("settings.proxies.checks.value"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
            }
            SettingRow(L("settings.proxies.failure"), detail: L("settings.proxies.failure.detail"), effect: .profileLaunch) {
                Picker(L("settings.proxies.failure"), selection: $settings.proxyFailure) {
                    Text(L("settings.proxies.failure.launch")).tag(AppSettings.ProxyFailure.launchAndExplain)
                    Text(L("settings.proxies.failure.doNotLaunch")).tag(AppSettings.ProxyFailure.doNotLaunch)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Downloads

private struct DownloadSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(title: L("settings.section.downloads"), subtitle: L("settings.downloads.subtitle")) {
            SettingRow(L("settings.downloads.folder"), detail: folderText, effect: .now) {
                HStack(spacing: 8) {
                    if settings.browsing.downloadFolder != nil {
                        Button(L("settings.downloads.folder.default")) { settings.chooseDownloadFolder(nil) }
                            .buttonStyle(.lumenGhost)
                    }
                    Button(L("settings.downloads.folder.choose"), action: chooseFolder)
                        .buttonStyle(.lumenSecondary)
                }
            }
            SettingRow(L("settings.downloads.ask"), detail: L("settings.downloads.ask.detail"), effect: .now) {
                SettingSwitch(isOn: $settings.browsing.askWhereToSave, label: L("settings.downloads.ask"))
            }
            SettingsNote(text: L("settings.downloads.note"))
        }
    }

    /// Where downloads go now.
    private var folderText: String {
        let folder = settings.browsing.downloadFolder.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return String(format: L("settings.downloads.folder.detail"), folder.path)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("settings.downloads.folder.choosePrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.chooseDownloadFolder(url)
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @EnvironmentObject private var model: AppModel
    var previewUpdater: AppUpdater?

    var body: some View {
        SettingsPage(title: L("settings.section.updates"), subtitle: nil) {
            if let updater = previewUpdater ?? model.updater {
                UpdatesPane(updater: updater)
            } else {
                SettingRow(L("updates.version"), detail: L("updates.unavailable"), effect: nil) {
                    Text(verbatim: UpdatesPane.runningVersion)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Shortcuts

/// The app's keyboard shortcuts, as its menus define them.
struct ShortcutSettings: View {
    struct Shortcut: Identifiable {
        let keys: String
        let titleKey: String
        var id: String { titleKey }
    }

    struct ShortcutGroup: Identifiable {
        let titleKey: String
        let shortcuts: [Shortcut]
        var id: String { titleKey }
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(titleKey: "settings.shortcuts.app", shortcuts: [
            Shortcut(keys: "⌘,", titleKey: "settings.shortcuts.settings"),
            Shortcut(keys: "⌘Q", titleKey: "settings.shortcuts.quit"),
        ]),
        ShortcutGroup(titleKey: "settings.shortcuts.tabs", shortcuts: [
            Shortcut(keys: "⌘T", titleKey: "menu.newTab"),
            Shortcut(keys: "⇧⌘T", titleKey: "menu.reopenClosedTab"),
            Shortcut(keys: "⌘W", titleKey: "settings.shortcuts.closeTab"),
            Shortcut(keys: "⌃⇥", titleKey: "menu.showNextTab"),
            Shortcut(keys: "⌃⇧⇥", titleKey: "menu.showPreviousTab"),
            Shortcut(keys: "⌘1 – ⌘8", titleKey: "settings.shortcuts.tabN"),
            Shortcut(keys: "⌘9", titleKey: "menu.selectLastTab"),
        ]),
        ShortcutGroup(titleKey: "settings.shortcuts.pages", shortcuts: [
            Shortcut(keys: "⌘L", titleKey: "menu.openLocation"),
            Shortcut(keys: "⌘R", titleKey: "menu.reload"),
            Shortcut(keys: "⌘[", titleKey: "menu.back"),
            Shortcut(keys: "⌘]", titleKey: "menu.forward"),
            Shortcut(keys: L("settings.shortcuts.commandClick"), titleKey: "settings.shortcuts.backgroundTab"),
        ]),
        ShortcutGroup(titleKey: "settings.shortcuts.library", shortcuts: [
            Shortcut(keys: "⌘D", titleKey: "menu.bookmarkThisPage"),
            Shortcut(keys: "⌥⌘B", titleKey: "menu.showAllBookmarks"),
            Shortcut(keys: "⌘Y", titleKey: "menu.showHistory"),
        ]),
    ]

    var body: some View {
        SettingsPage(title: L("settings.section.shortcuts"), subtitle: L("settings.shortcuts.subtitle")) {
            ForEach(Self.groups) { group in
                Text(L(group.titleKey))
                    .font(.lumenSection)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                ForEach(group.shortcuts) { shortcut in
                    HStack(spacing: 16) {
                        Text(L(shortcut.titleKey))
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 12)
                        Text(verbatim: shortcut.keys)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raisedInset))
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            SettingsNote(text: L("settings.shortcuts.safariNote"))
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        SettingsPage(title: L("settings.section.about"), subtitle: nil) {
            HStack(spacing: 14) {
                if let icon = AppIcon.image(pixels: 128) {
                    Image(nsImage: NSImage(cgImage: icon, size: NSSize(width: 64, height: 64)))
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.appName)
                        .font(.lumenSheetTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: L("settings.about.version"), UpdatesPane.runningVersion))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 12)
            ForEach(Self.facts) { fact in
                HStack(spacing: 16) {
                    Text(fact.name).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 12)
                    Text(verbatim: fact.value).font(.lumenBody).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                }
                .padding(.vertical, 5)
            }
            if !Self.links.isEmpty {
                HStack(spacing: 16) {
                    ForEach(Self.links) { link in
                        Link(link.name, destination: link.url)
                            .font(.lumenLabel)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    struct Fact: Identifiable {
        let name: String
        let value: String
        var id: String { name }
    }

    struct WebLink: Identifiable {
        let name: String
        let url: URL
        var id: String { name }
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PrivacyBrowser" // l10n: not text
    }

    /// What the app runs on: this Mac's system, its Safari and WebKit, and how the app is built.
    static var facts: [Fact] {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var facts = [Fact(name: L("settings.about.macOS"), value: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"),
                     Fact(name: L("settings.about.safari"), value: HostSafari.version)]
        if let webKit = Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            facts.append(Fact(name: L("settings.about.webKit"), value: webKit))
        }
        facts.append(Fact(name: L("settings.about.build"),
                          value: L(AppEnvironment.isSandboxed ? "settings.about.build.sandboxed" : "settings.about.build.unsandboxed")))
        return facts
    }

    /// The links a release names in its Info.plist (`PBWebsiteURL`, `PBSupportURL`); a build
    /// without them shows none.
    static var links: [WebLink] {
        let info = Bundle.main.infoDictionary ?? [:]
        var links: [WebLink] = []
        for (key, title) in [("PBWebsiteURL", "settings.about.website"), ("PBSupportURL", "settings.about.support")] {
            if let text = info[key] as? String, let url = URL(string: text), url.scheme == "https" {
                links.append(WebLink(name: L(title), url: url))
            }
        }
        return links
    }
}
