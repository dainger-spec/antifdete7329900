import BrowserCore
import SwiftUI

/// One setting the Settings search can find: the page it is on, and the keys of the texts its row
/// shows there — never a text of the search's own, so that what is found is what the page says.
struct SettingsSearchEntry {
    let section: SettingsSection
    /// The row's title.
    let titleKey: String
    /// The sentence under it, where the row has one that is always the same.
    var detailKey: String?

    init(_ section: SettingsSection, _ titleKey: String, detail detailKey: String? = nil) {
        self.section = section
        self.titleKey = titleKey
        self.detailKey = detailKey
    }
}

/// The Settings window's search (the field above its sections). It looked at the sections' names
/// alone: "zoom", "Dock" or "quit" found nothing, though each is a setting two clicks away. Now it
/// looks through every page's settings — their titles, then the sentences under them — and says
/// which one it found; the page marks that row and scrolls to it. The command palette (⌘K) finds
/// the same settings by name.
enum SettingsSearch {
    /// A page that answers what was typed.
    struct Hit: Equatable {
        let section: SettingsSection
        /// The setting found there, by its row's title; nil: the page's own name answers.
        let setting: String?
        /// How well: a page's name before a setting's title before a description.
        let score: Int
    }

    /// Every setting the search looks through: those every copy of the app shows, and unlocking
    /// with Touch ID where this Mac and this build offer it (`TouchIDUnlock.isOfferedHere`).
    static let entries: [SettingsSearchEntry] = everywhere
        + (TouchIDUnlock.isOfferedHere ? [SettingsSearchEntry(.security, "settings.security.touchID", detail: "settings.security.touchID.detail")] : [])

    private static let everywhere: [SettingsSearchEntry] = [
        SettingsSearchEntry(.account, "license.account.caption.plan"),
        SettingsSearchEntry(.account, "license.account.code", detail: "license.account.codeHint"),
        SettingsSearchEntry(.account, "license.account.signOut"),
        SettingsSearchEntry(.account, "license.account.caption.devices"),
        SettingsSearchEntry(.account, "license.account.cabinet", detail: "license.account.cabinetDetail"),
        SettingsSearchEntry(.account, "reminders.title"),

        SettingsSearchEntry(.startup, "settings.startup.open", detail: "settings.startup.open.detail"),
        SettingsSearchEntry(.startup, "settings.startup.restoreTabs", detail: "settings.startup.restoreTabs.detail"),
        SettingsSearchEntry(.startup, "settings.startup.confirmQuit", detail: "settings.startup.confirmQuit.detail"),

        SettingsSearchEntry(.newProfiles, "settings.newProfiles.matchConnection", detail: "settings.newProfiles.matchConnection.detail"),
        SettingsSearchEntry(.newProfiles, "settings.newProfiles.search", detail: "settings.newProfiles.search.detail"),
        SettingsSearchEntry(.newProfiles, "settings.newProfiles.local", detail: "settings.newProfiles.local.detail"),
        SettingsSearchEntry(.newProfiles, "settings.newProfiles.randomWindow", detail: "settings.newProfiles.randomWindow.detail"),
        SettingsSearchEntry(.newProfiles, "settings.newProfiles.quic", detail: "settings.newProfiles.quic.detail"),

        SettingsSearchEntry(.behavior, "settings.behavior.autoFill", detail: "settings.behavior.autoFill.detail"),
        SettingsSearchEntry(.behavior, "settings.behavior.tabsNextToCurrent", detail: "settings.behavior.tabsNextToCurrent.detail"),
        SettingsSearchEntry(.behavior, "settings.behavior.warnClosing", detail: "settings.behavior.warnClosing.detail"),
        SettingsSearchEntry(.behavior, "settings.behavior.zoom", detail: "settings.behavior.zoom.detail"),
        SettingsSearchEntry(.behavior, "settings.behavior.ownProcesses", detail: "settings.behavior.ownProcesses.detail"),
        SettingsSearchEntry(.behavior, "settings.behavior.dockLetters", detail: "settings.behavior.dockLetters.detail"),

        SettingsSearchEntry(.appearance, "settings.appearance.light", detail: "settings.appearance.light.detail"),
        SettingsSearchEntry(.appearance, "settings.appearance.density", detail: "settings.appearance.density.detail"),
        SettingsSearchEntry(.appearance, "settings.appearance.animations", detail: "settings.appearance.animations.detail"),
        SettingsSearchEntry(.appearance, "settings.appearance.countryBackdrop", detail: "settings.appearance.countryBackdrop.detail"),

        SettingsSearchEntry(.language, "settings.language.title", detail: "settings.language.detail"),
        SettingsSearchEntry(.language, "settings.language.sites.title", detail: "settings.language.sites.detail"),

        SettingsSearchEntry(.downloads, "settings.downloads.folder", detail: "settings.downloads.folder.default"),
        SettingsSearchEntry(.downloads, "settings.downloads.ask", detail: "settings.downloads.ask.detail"),

        SettingsSearchEntry(.proxies, "settings.proxies.list", detail: "settings.proxies.list.detail"),
        SettingsSearchEntry(.proxies, "settings.proxies.checks", detail: "settings.proxies.checks.detail"),
        SettingsSearchEntry(.proxies, "settings.proxies.failure", detail: "settings.proxies.failure.detail"),

        SettingsSearchEntry(.webRTC, "guard.how.relay.title", detail: "guard.how.relay"),
        SettingsSearchEntry(.webRTC, "guard.how.guard.title", detail: "guard.how.guard"),
        SettingsSearchEntry(.webRTC, "guard.how.limits.title", detail: "guard.how.limits"),

        SettingsSearchEntry(.sync, "sync.to"),
        SettingsSearchEntry(.sync, "sync.mode.account", detail: "sync.to.account.detail"),
        SettingsSearchEntry(.sync, "sync.mode.folder", detail: "sync.to.folder.detail"),
        SettingsSearchEntry(.sync, "sync.mode.server", detail: "sync.to.server.detail"),
        SettingsSearchEntry(.sync, "sync.now"),
        SettingsSearchEntry(.sync, "sync.what.row", detail: "sync.footer"),

        SettingsSearchEntry(.security, "settings.security.password", detail: "settings.security.password.detail"),
        SettingsSearchEntry(.security, "settings.security.lock", detail: "profiles.action.lock.help"),
        SettingsSearchEntry(.security, "settings.security.vault"),

        SettingsSearchEntry(.automation, "automation.enabled", detail: "automation.note"),
        SettingsSearchEntry(.automation, "automation.port"),
        SettingsSearchEntry(.automation, "automation.token"),
        SettingsSearchEntry(.automation, "automation.webDriver", detail: "automation.webDriver.detail"),

        SettingsSearchEntry(.diagnostics, "settings.diagnostics.collect", detail: "settings.diagnostics.contents"),
        SettingsSearchEntry(.diagnostics, "settings.diagnostics.copy"),

        SettingsSearchEntry(.updates, "updates.automatic", detail: "updates.privacy"),
        SettingsSearchEntry(.updates, "updates.policy", detail: "settings.updates.policy.detail"),
        SettingsSearchEntry(.updates, "updates.checkNow"),

        SettingsSearchEntry(.about, "settings.about.safari"),
        SettingsSearchEntry(.about, "settings.about.build"),
    ]

    /// The pages that answer `query`, in the sidebar's order, each with the setting found on it.
    /// Nothing typed: every page, none with a setting. `text` gives a key's text (the interface's
    /// language; the self-test asks in each language).
    static func hits(_ query: String, text: (String) -> String = { L($0) }) -> [Hit] {
        guard !TextSearch.words(query).isEmpty else {
            return SettingsSection.allCases.map { Hit(section: $0, setting: nil, score: 0) }
        }
        return SettingsSection.allCases.compactMap { section -> Hit? in
            var best = TextSearch.score(query, in: text(section.titleKey)).map { Hit(section: section, setting: nil, score: $0 * 100) }
            for entry in entries where entry.section == section {
                let title = text(entry.titleKey)
                var score = TextSearch.score(query, in: title).map { $0 * 10 }
                if score == nil, let detailKey = entry.detailKey {
                    score = TextSearch.score(query, in: title + " " + text(detailKey), insideWords: false)
                }
                if let score, score > (best?.score ?? 0) { best = Hit(section: section, setting: title, score: score) }
            }
            return best
        }
    }

    /// The page Return opens: the best answer, the earlier page among equals.
    static func best(_ hits: [Hit]) -> Hit? {
        hits.enumerated().max { ($0.element.score, -$0.offset) < ($1.element.score, -$1.offset) }?.element
    }

    /// The palette's (⌘K) commands for single settings: "Settings: Page zoom", under it the page it
    /// is on. Found by typing — they are not listed before anything is typed, and a setting is
    /// offered only when the words typed are really in its name.
    static func paletteCommands(open: @escaping (SettingsSection, String) -> Void) -> [CommandPaletteView.Command] {
        entries.map { entry in
            let title = L(entry.titleKey)
            let page = L(entry.section.titleKey)
            return CommandPaletteView.Command(id: "setting-\(entry.section.rawValue)-\(entry.titleKey)",
                                              title: String(format: L("palette.settings"), title),
                                              detail: page, symbol: entry.section.symbol, group: .settings,
                                              foundBy: title + " " + page, run: { open(entry.section, title) })
        }
    }
}

// MARK: - The row the search found

private struct SettingsFoundKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The title of the setting the Settings search, or the palette, led to: its row marks itself.
    var settingsFound: String? {
        get { self[SettingsFoundKey.self] }
        set { self[SettingsFoundKey.self] = newValue }
    }
}

/// A setting's row, when it is the one that was looked for: a tone of white behind it (the list's
/// own selection colour), and the page's anchor to scroll to.
struct FoundSettingMark: ViewModifier {
    let title: String
    @Environment(\.settingsFound) private var found

    /// What the page scrolls to (`SettingsView`).
    static let anchor = "settings.found"

    func body(content: Content) -> some View {
        if found == title {
            content
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.rowSelected)
                    .padding(.horizontal, -12))
                .id(Self.anchor)
                .accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}
