import AppKit
import SwiftUI

/// The app's own commands that have keys, in one table: the menus take their keys from it, and the
/// command palette, Settings › Shortcuts and Help › Keyboard Shortcuts list them from it — so a
/// key that works is a key that is shown. Before, the menus, the settings page and the help each
/// had a list of their own: the page named three of the six keys the menus had.
enum AppCommand: String, CaseIterable, Identifiable {
    case commandPalette, newProfile, proxies, scenarios, lock, settings, help, quit

    var id: String { rawValue }

    /// The key, without its modifiers.
    var character: Character {
        switch self {
        case .commandPalette: return "k"
        case .newProfile: return "n"
        case .proxies: return "p"
        case .scenarios: return "e"
        case .lock: return "l"
        case .settings: return ","
        case .help: return "?"
        case .quit: return "q"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .proxies, .scenarios, .lock: return [.command, .shift]
        case .commandPalette, .newProfile, .settings, .help, .quit: return .command
        }
    }

    var keyEquivalent: KeyEquivalent { KeyEquivalent(character) }

    /// As it is shown: "⌘K", "⇧⌘L" — the modifiers in the order macOS writes them.
    var keys: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(character).uppercased()
    }

    /// What it does, as Settings › Shortcuts says it.
    var titleKey: String {
        switch self {
        case .commandPalette: return "menu.commandPalette"
        case .newProfile: return "profiles.action.new"
        case .proxies: return "settings.shortcuts.proxies"
        case .scenarios: return "menu.scenarios"
        case .lock: return "settings.shortcuts.lock"
        case .settings: return "settings.shortcuts.settings"
        case .help: return "menu.help"
        case .quit: return "settings.shortcuts.quit"
        }
    }

    /// The same in Help › Keyboard Shortcuts (the strings tables' `help.` keys, without the prefix).
    var helpKey: String {
        switch self {
        case .commandPalette: return "keys.palette"
        case .newProfile: return "keys.newProfile"
        case .proxies: return "keys.proxies"
        case .scenarios: return "keys.scenarios"
        case .lock: return "keys.lock"
        case .settings: return "keys.settings"
        case .help: return "keys.help"
        case .quit: return "keys.quit"
        }
    }
}

/// What the app's menu commands do, where it is more than one line of the model's.
@MainActor
enum AppCommands {
    /// Lock from the menu, the keyboard or the palette. With profiles running it asks first and
    /// lists what it stops, as Quit does — and under the same setting (Settings › Startup ›
    /// Confirm quit): a key pressed by mistake must not end every session without a word. The Lock
    /// button of the Profiles window is a deliberate click and locks at once, as before.
    static func lock(_ model: AppModel) {
        guard model.phase == .unlocked else { return }
        let running = model.settings.confirmQuit ? model.updateStopsList() : []
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("lock.confirm.title")
            alert.informativeText = lockQuestion(stopping: running)
            alert.addButton(withTitle: L("lock.confirm.lock"))
            alert.addButton(withTitle: L("common.cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await model.lock() }
    }

    /// The question's text: what is stopped, one line each.
    static func lockQuestion(stopping running: [String]) -> String {
        L("quit.confirm.message") + "\n" + running.map { "• " + $0 }.joined(separator: "\n")
    }

    /// The app menu's Check for Updates…: Settings › Updates, and a check started there — its
    /// state, the release's notes and Install are on that page. In a build without an update feed
    /// the page says so.
    static func checkForUpdates(_ model: AppModel, openSettings: () -> Void) {
        model.settingsSection = .updates
        openSettings()
        Task { await model.updater?.checkNow() }
    }
}

/// The command palette's (⌘K) share of the app's own commands, added to what the Profiles window
/// gives it: the keys of the commands that have them, and Check for Updates.
@MainActor
enum AppPalette {
    static func completed(_ commands: [CommandPaletteView.Command], model: AppModel,
                          openSettings: @escaping () -> Void) -> [CommandPaletteView.Command] {
        typealias Command = CommandPaletteView.Command
        var commands = commands.map { command -> Command in
            var command = command
            if command.shortcut == nil, let key = keys[command.id] { command.shortcut = key.keys }
            // Lock from the palette asks as the menu's does: "lo" and Return may have meant a profile.
            if command.id == "lock" { command.run = { AppCommands.lock(model) } }
            return command
        }
        // Among the actions, before the first of the settings: the list is shown by group.
        let firstSetting = commands.firstIndex { $0.group == .settings } ?? commands.endIndex
        commands.insert(Command(id: "updates", title: L("menu.checkForUpdates"), symbol: "arrow.down.to.line",
                                run: { AppCommands.checkForUpdates(model, openSettings: openSettings) }),
                        at: firstSetting)
        return commands
    }

    /// The palette's commands that the menus give keys to, by the palette's ids.
    static let keys: [String: AppCommand] = ["new": .newProfile, "proxies": .proxies, "scenarios": .scenarios, "lock": .lock, "help": .help]
}

private struct AppModelForCommandsKey: EnvironmentKey {
    static let defaultValue: AppModel? = nil
}

extension EnvironmentValues {
    /// The app's model, for the command palette's own commands (`AppPalette`): given by the app's
    /// scene to the Profiles window and its sheets. Nil in a picture of the palette (the UI
    /// snapshots), which then shows the commands it was given and nothing else.
    var appModelForCommands: AppModel? {
        get { self[AppModelForCommandsKey.self] }
        set { self[AppModelForCommandsKey.self] = newValue }
    }
}
