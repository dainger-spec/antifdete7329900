import Foundation

/// The self-test's checks of how things are found in the app (`--self-test`, the group "finding
/// settings, help and commands"): the Settings search over the settings themselves, the palette's
/// single settings, the one table of the app's keys. No window, no vault, no network: the texts
/// are this build's own tables, in each language the app is translated into.
@MainActor
enum UsabilityChecks {
    struct Result {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// A key's text in one language's table of this build; nil: the build carries no such table
    /// (a bare executable, outside the .app).
    static func table(_ language: String) -> ((String) -> String)? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return { bundle.localizedString(forKey: $0, value: $0, table: nil) }
    }

    /// The checks made so far, in order.
    private final class Checks {
        var results: [Result] = []

        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            results.append(Result(name: "finding: " + name, passed: passed, detail: passed ? "" : detail()))
        }
    }

    /// One language's table: its code, and a key's text in it.
    private typealias Table = (language: String, text: (String) -> String)

    static func run() -> [Result] {
        let checks = Checks()
        var tables: [Table] = []
        for language in Localization.supported {
            if let text = table(language) { tables.append((language: language, text: text)) }
        }
        checks.check("this build carries a strings table for every language of the interface",
                     tables.count == Localization.supported.count, "found \(tables.map { $0.language }) of \(Localization.supported)")
        settingsSearch(tables, checks)
        commandKeys(tables, checks)
        return checks.results
    }

    // MARK: Settings search

    private static func settingsSearch(_ tables: [Table], _ checks: Checks) {
        // Every entry of the index is a text the page itself shows: a key that is in the tables.
        var missing: [String] = []
        for (language, text) in tables {
            for entry in SettingsSearch.entries {
                for key in [entry.titleKey, entry.detailKey].compactMap({ $0 }) where text(key) == key {
                    missing.append("\(language): \(key)")
                }
            }
        }
        checks.check("settings search: every setting it looks through is a text of its page, in every language (\(SettingsSearch.entries.count) settings)",
              !tables.isEmpty && missing.isEmpty, missing.joined(separator: ", "))
        let pagesWithout = SettingsSection.allCases.filter { section in
            section != .shortcuts && !SettingsSearch.entries.contains { $0.section == section }
        }
        checks.check("settings search: every page but Shortcuts has settings to find", pagesWithout.isEmpty, "\(pagesWithout.map { $0.rawValue })")

        // What a person types finds the page that holds the setting, and says which setting.
        let wanted: [(language: String, query: String, section: SettingsSection, titleKey: String?)] = [
            ("en", "zoom", .behavior, "settings.behavior.zoom"),
            ("en", "dock", .behavior, "settings.behavior.ownProcesses"),
            ("en", "quit", .startup, "settings.startup.confirmQuit"),
            ("en", "master password", .security, "settings.security.password"),
            ("en", "download folder", .downloads, nil),
            ("en", "token", .automation, "automation.token"),
            ("en", "updates", .updates, nil),
            ("en", "greeting every start", .appearance, "settings.appearance.welcome"),
            ("ru", "масштаб", .behavior, "settings.behavior.zoom"),
            ("ru", "выход", .startup, "settings.startup.confirmQuit"),
            ("ru", "мастер-пароль", .security, "settings.security.password"),
            ("ru", "загрузок", .downloads, nil),
            ("ru", "обновления", .updates, nil),
            ("ru", "приветствие при каждом запуске", .appearance, "settings.appearance.welcome"),
        ]
        var wrong: [String] = []
        for item in wanted {
            guard let text = tables.first(where: { $0.language == item.language })?.text else { continue }
            let hits = SettingsSearch.hits(item.query, text: text)
            guard let hit = hits.first(where: { $0.section == item.section }) else {
                wrong.append("\(item.language) “\(item.query)”: \(item.section.rawValue) not among \(hits.map { $0.section.rawValue })")
                continue
            }
            if let key = item.titleKey, hit.setting != text(key) {
                wrong.append("\(item.language) “\(item.query)”: says “\(hit.setting ?? "the page")”, not “\(text(key))”")
            }
            if item.titleKey == nil, SettingsSearch.best(hits)?.section != item.section {
                wrong.append("\(item.language) “\(item.query)”: Return opens \(SettingsSearch.best(hits)?.section.rawValue ?? "nothing")")
            }
        }
        checks.check("settings search: “zoom”, “dock”, “quit”, «масштаб», «выход» and the like find their page and name the setting",
              !tables.isEmpty && wrong.isEmpty, wrong.joined(separator: " | "))

        // The control: what is nowhere finds nothing, and nothing typed lists every page.
        let english = tables.first { $0.language == "en" }?.text ?? { $0 }
        let nothing = SettingsSearch.hits("qwertyuiop", text: english)
        let all = SettingsSearch.hits("  ", text: english)
        checks.check("settings search: what is in no setting finds nothing, and nothing typed lists every page without a setting named",
              nothing.isEmpty && all.map { $0.section } == SettingsSection.allCases && all.allSatisfy { $0.setting == nil },
              "\(nothing.map { $0.section.rawValue }); \(all.count) pages")

        // The palette: a single setting is offered only once its words are typed.
        let commands = SettingsSearch.paletteCommands { _, _ in }
        let listed = CommandPaletteView.rank(commands, query: "")
        let found = CommandPaletteView.rank(commands, query: L("settings.behavior.zoom"))
        let loose = CommandPaletteView.rank(commands, query: "zzqx")
        checks.check("palette: single settings are not listed before anything is typed, are found by their names, and not by letters in order",
              listed.isEmpty && found.first?.id == "setting-behavior-settings.behavior.zoom" && loose.isEmpty,
              "listed \(listed.count), found \(found.first?.id ?? "none"), loose \(loose.count)")
    }

    // MARK: The app's keys

    private static func commandKeys(_ tables: [Table], _ checks: Checks) {
        let app = AppCommand.allCases
        let keys = app.map { $0.keys }
        // The keys the app's own browser windows and its Scenarios window already have.
        let others = ShortcutSettings.groups.dropFirst().flatMap { group in group.shortcuts.map { $0.keys } } + ["⌘S"]
        let twice = Set(keys.filter { key in keys.filter { $0 == key }.count > 1 || others.contains(key) })
        checks.check("keys: no two of the app's commands share a key, and none takes a key of the browser windows (\(keys.joined(separator: " ")))",
              twice.isEmpty, twice.sorted().joined(separator: " "))
        checks.check("keys: written as macOS writes them — ⇧⌘L locks, ⇧⌘P shows the proxies, ⌘K the palette",
              AppCommand.lock.keys == "⇧⌘L" && AppCommand.proxies.keys == "⇧⌘P" && AppCommand.commandPalette.keys == "⌘K"
                && AppCommand.settings.keys == "⌘," && AppCommand.help.keys == "⌘?",
              keys.joined(separator: " "))
        var missing: [String] = []
        for (language, text) in tables {
            for command in app {
                for key in [command.titleKey, "help." + command.helpKey] where text(key) == key { missing.append("\(language): \(key)") }
            }
        }
        checks.check("keys: every command with a key is named in Settings › Shortcuts and in Help, in every language",
              !tables.isEmpty && missing.isEmpty, missing.joined(separator: ", "))
        // Both lists are the table's: a key the menus have is a key that is shown.
        let page = ShortcutSettings.groups.first?.shortcuts.map { $0.keys } ?? []
        var help: [String] = []
        for block in HelpContent.blocks(.keys) {
            if case .shortcuts(let rows) = block, help.isEmpty { help = rows.map { $0.keys } }
        }
        checks.check("keys: Settings › Shortcuts and Help › Keyboard Shortcuts both list every one of them", page == keys && help == keys,
              "page \(page), help \(help)")
        checks.check("keys: the palette shows the keys of Proxies and Lock",
              AppPalette.keys["proxies"] == .proxies && AppPalette.keys["lock"] == .lock)
        // Lock's question names what it stops, one line each.
        let question = AppCommands.lockQuestion(stopping: ["Northwind", "Harbor"])
        checks.check("lock: the question lists what is stopped", question.contains("• Northwind") && question.contains("• Harbor"), question)
    }
}
