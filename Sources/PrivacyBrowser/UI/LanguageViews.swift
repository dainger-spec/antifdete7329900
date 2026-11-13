import AppKit
import BrowserCore
import SwiftUI

/// The interface's language: as the system, Russian, or English (the owner, 1 November). The
/// app's windows, its menus and Safari's chrome in a profile's window take it at the next start.
/// It is never the language websites see: that is a profile's own (its editor), and nothing here
/// reads or sets it (`InterfaceLanguage`, the self-test's "interface language apart from the
/// websites'" group).
struct LanguageSettings: View {
    @State private var choice = Localization.choice

    var body: some View {
        SettingsPage(title: L("settings.section.language"), subtitle: L("settings.language.subtitle")) {
            SettingRow(L("settings.language.title"), detail: L("settings.language.detail"), effect: .appStart) {
                InterfaceLanguageChoicePicker(choice: $choice, offersSystem: true)
            }
            if commandLineOverrides {
                // This run's language is the command line's: the choice applies from the next
                // ordinary start, and a restart from here would not keep the command line either.
                SettingCustomRow(L("settings.language.commandLine.title")) {
                    Text(L("settings.language.commandLine.detail"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } control: {
                    EmptyView()
                }
            } else if pendingLanguage != Localization.languageCode {
                SettingCustomRow(L("settings.language.restart.title")) {
                    Text(L("settings.language.restart.detail"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } control: {
                    Button(L("settings.language.restart")) { SystemOpen.relaunchAfterQuit() }
                        .buttonStyle(.lumenPrimary)
                }
            }
            SettingCustomRow(L("settings.language.sites.title")) {
                Text(L("settings.language.sites.detail"))
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } control: {
                EmptyView()
            }
        }
        .onChange(of: choice) { _, new in Localization.choice = new }
    }

    /// The language the next start will take with this choice.
    private var pendingLanguage: String {
        InterfaceLanguage.resolve(environment: ProcessInfo.processInfo.environment["PRIVACYBROWSER_LANG"],
                                  commandLine: nil, choice: choice, system: Localization.systemLanguages)
    }

    /// This run's language came from `-AppleLanguages` on the command line, not from the choice.
    private var commandLineOverrides: Bool {
        Localization.commandLineLanguages(CommandLine.arguments).flatMap(InterfaceLanguage.firstSupported) != nil
    }
}

/// The three (or two) languages, each named in its own language.
struct InterfaceLanguageChoicePicker: View {
    @Binding var choice: InterfaceLanguage.Choice
    /// "As the system" offered (Settings); the first screen shows the two languages, the system's
    /// already chosen.
    var offersSystem: Bool

    var body: some View {
        LumenSegmented(selection: $choice, options: options)
            .accessibilityLabel(L("settings.language.title"))
            .fixedSize()
    }

    private var options: [(value: InterfaceLanguage.Choice, title: String)] {
        let languages: [(value: InterfaceLanguage.Choice, title: String)] = [
            (value: .ru, title: "Русский"), // l10n: not text — a language's own name
            (value: .en, title: "English"), // l10n: not text — a language's own name
        ]
        return offersSystem ? [(value: .system, title: L("settings.language.system"))] + languages : languages
    }
}

/// The first screen's language, before the vault exists (the owner: an element of the same screen,
/// not a step of its own). It shows the language this start took — the system's, unless the person
/// chose — and a change starts the app again in the other one: nothing is open yet to lose.
struct FirstLaunchLanguagePicker: View {
    @State private var choice: InterfaceLanguage.Choice = Localization.languageCode == "ru" ? .ru : .en

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            InterfaceLanguageChoicePicker(choice: $choice, offersSystem: false)
        }
        .onChange(of: choice) { _, new in
            guard new.rawValue != Localization.languageCode else { return }
            Localization.choice = new
            SystemOpen.relaunchAfterQuit()
        }
    }
}
