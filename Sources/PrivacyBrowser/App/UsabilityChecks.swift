import Foundation

/// The self-test's checks of how things are found in the app (`--self-test`, the group "finding
/// settings, help and commands"): the one table of the app's keys. No window, no vault, no
/// network: the texts are this build's own tables, in each language the app is translated into.
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
        commandKeys(tables, checks)
        return checks.results
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
