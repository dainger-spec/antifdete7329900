import BrowserCore
import Foundation

/// Localization for the app's own strings.
///
/// The interface's language is resolved once per run (`InterfaceLanguage.resolve`): a test's
/// `PRIVACYBROWSER_LANG`, then `-AppleLanguages` given for this run, then the person's choice
/// (Settings › Language, the first screen), then the first of the Mac's own languages the app is
/// translated into, then English. Every string is looked up from that language's `.lproj`, so the
/// language is the same everywhere in the run. Changing the choice takes a restart.
///
/// Until 1 November it was Russian whatever the Mac said, and every start wrote `AppleLanguages =
/// (ru, en)` into the app's preferences on disk (the owner: `open Lumen.app --args -AppleLanguages
/// "(en)"` came up in Russian). The interface's language is never the language websites see
/// (`WebContentLanguage`, a profile's locale): nothing here reads or sets that.
///
/// `L(key)` returns a plain `String`. We pass already-localized `String`s into SwiftUI controls
/// and AppKit (`NSAlert`, `NSMenu`, window titles) alike, which sidesteps the SwiftUI-Package
/// pitfall where `Text("literal")` would look in `Bundle.main` and miss the module's resources.
///
/// `build-app.sh` copies `en.lproj` and `ru.lproj` into the app bundle's `Resources`. When the
/// executable is run outside a bundle (`swift run`, the `--self-test` binary) the tables are
/// absent and `L` returns the key unchanged — acceptable, as those paths show no localized UI.
enum Localization {
    /// Supported languages.
    static let supported = InterfaceLanguage.supported

    /// Where the person's choice is kept: the app's own preferences (a setting, not a secret).
    static let choiceKey = "PBInterfaceLanguage"

    /// The person's choice (Settings › Language, the first screen). Takes effect at the next start.
    static var choice: InterfaceLanguage.Choice {
        get { UserDefaults.standard.string(forKey: choiceKey).flatMap(InterfaceLanguage.Choice.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: choiceKey) }
    }

    /// Resolved once (`InterfaceLanguage.resolve`). In a profile's own process the manager gives it
    /// by name (`PRIVACYBROWSER_LANG`, `ProfileProcess`): that process's `-AppleLanguages` is the
    /// websites' list, never read for the interface's.
    static let languageCode: String = InterfaceLanguage.resolve(
        environment: ProcessInfo.processInfo.environment["PRIVACYBROWSER_LANG"],
        commandLine: isProfileProcess ? nil : commandLineLanguages(CommandLine.arguments),
        choice: UserDefaults.standard.string(forKey: choiceKey).flatMap(InterfaceLanguage.Choice.init(rawValue:)),
        system: systemLanguages)

    /// This process is one profile's (`--profile-session`, ProfileSessionHost).
    private static var isProfileProcess: Bool { CommandLine.arguments.contains("--profile-session") }

    /// `-AppleLanguages` as given on this process's command line — `(en)`, `(de-DE, en)`, `en` —
    /// read from the arguments themselves: what the app later sets for WebKit in the same key (the
    /// websites' language) is never taken for the interface's.
    static func commandLineLanguages(_ arguments: [String]) -> [String]? {
        guard let index = arguments.firstIndex(of: "-AppleLanguages"), index + 1 < arguments.count else { return nil }
        let list = arguments[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "() \"'"))
            .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }

    /// The Mac's own languages: the global domain's list, without this app's preferences.
    static var systemLanguages: [String] {
        (CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                kCFPreferencesAnyHost) as? [String]) ?? []
    }

    /// The chosen language's bundle, then English, then the main bundle (keys returned verbatim).
    static let bundle: Bundle = {
        for code in [languageCode, "en"] {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }()

    /// Makes the standard AppKit menus and system dialogs (App menu, Edit menu, panels) follow the
    /// interface's language too: this run's argument domain, never the preferences on disk. Takes
    /// out, once, the `AppleLanguages` earlier versions wrote there at every start — only when it
    /// is exactly what they wrote; a list the person set stays. Call once, as early as possible in
    /// `main`, before AppKit builds its menus.
    static func applyProcessLanguage() {
        if InterfaceLanguage.isEarlierVersionsWrite(languagesOnDisk) {
            CFPreferencesSetValue("AppleLanguages" as CFString, nil, appDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(appDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [languageCode]
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// The app's own preferences on disk: its domain alone, not the search list
    /// (`CFPreferencesCopyAppValue` answers with the command line's or the Mac's list as well).
    private static var appDomain: CFString { (Bundle.main.bundleIdentifier ?? "io.lumenbrowser.Lumen") as CFString }

    /// `AppleLanguages` in the app's own preferences on disk, nil when there is none there.
    static var languagesOnDisk: Any? {
        CFPreferencesCopyValue("AppleLanguages" as CFString, appDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// In a profile's own process, first thing in `main`: AppKit, Safari's chrome and the
    /// frameworks take the interface's language, and WebKit — which reads `AppleLanguages` itself,
    /// later, for what pages see — the websites' list the process was started with
    /// (`ProfileProcess`). A bundle's language is chosen the first time it is asked and kept, and
    /// the frameworks take the main bundle's: so the main bundle is asked here with the interface's
    /// language in place, and the command line's list is put back before anything reads it.
    static func pinInterfaceLanguage() {
        let commandLine = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var pinned = commandLine
        pinned["AppleLanguages"] = [languageCode]
        UserDefaults.standard.setVolatileDomain(pinned, forName: UserDefaults.argumentDomain)
        _ = Bundle.main.preferredLocalizations
        _ = Bundle.main.path(forResource: "Localizable", ofType: "strings")
        UserDefaults.standard.setVolatileDomain(commandLine, forName: UserDefaults.argumentDomain)
    }

    /// The language this process's bundles took (the main bundle's; the frameworks follow it):
    /// what AppKit's and Safari's own words are in. Reported by a profile's process
    /// (`ProfileEvent.interfaceLanguage`), checked by the self-test.
    static var bundlesLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "?"
    }

    static func string(_ key: String) -> String {
        // `value: key` → if the key is missing from both the chosen and English tables, show the
        // key itself rather than an empty string.
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The interface's locale: its language, with this Mac's region and preferences. Dates, times,
    /// sizes and lists in the app's own windows are written with it (`Date.shown`). The system's
    /// locale follows the Mac's language, not the interface's: a Russian interface on a Mac set to
    /// English said "yesterday" and "Oct 31" among Russian words (CI run 541's snapshots). The
    /// system's own locale, untouched, when its language is the interface's. Only the app's own
    /// text uses it: what a page sees of languages and formats is WebContentLanguage's.
    static let locale: Locale = {
        let current = Locale.autoupdatingCurrent
        if current.language.languageCode?.identifier == languageCode { return current }
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(languageCode: Locale.LanguageCode(languageCode),
                                                                   script: nil, region: current.region)
        return Locale(components: components)
    }()
}

/// Shorthand used throughout the UI and AppKit call sites.
func L(_ key: String) -> String { Localization.string(key) }

extension Date {
    /// This date as the interface says it (`Localization.locale`): `formatted(date:time:)` in the
    /// interface's language.
    func shown(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: Localization.locale))
    }

    /// "yesterday", "in 2 hours", as the interface says it (`Localization.locale`).
    var shownRelative: String {
        formatted(.relative(presentation: .named).locale(Localization.locale))
    }
}

/// The text shown for `error`, in the person's language (`translatedErrorText`, which the core's
/// errors also give as their `localizedDescription` once `installErrorTranslation` has run).
func errorText(_ error: Error) -> String {
    translatedErrorText(error) ?? error.localizedDescription
}

/// Makes every error of the core describe itself in the person's language wherever the app shows
/// `localizedDescription` (`CoreErrorText`). Called first thing in `main`, in every process.
func installErrorTranslation() {
    CoreErrorText.translate = { translatedErrorText($0) }
}

/// The core's errors in the person's language. What an error carries in detail — a file's name,
/// the reason the code gives, in English — follows in parentheses; the sentence itself is
/// translated. Nil for errors that are not the core's.
func translatedErrorText(_ error: Error) -> String? {
    if let error = error as? CoreError {
        switch error {
        case .authenticationFailed: return L("error.core.authenticationFailed")
        case .wrongPassword: return L("error.core.wrongPassword")
        case .vaultAlreadyExists: return L("error.core.vaultAlreadyExists")
        case .vaultNotFound: return L("error.core.vaultNotFound")
        case .corruptData(let detail): return String(format: L("error.core.corruptData"), detail)
        case .cryptoFailure(let detail): return String(format: L("error.core.cryptoFailure"), detail)
        case .invalidConfiguration(let detail): return String(format: L("error.core.invalidConfiguration"), detail)
        case .profileNotFound: return L("error.core.profileNotFound")
        case .unsupportedFormat(let detail): return String(format: L("error.core.unsupportedFormat"), detail)
        // A file that a newer version of the app wrote, with what to do about it (docs/UPDATES.md §4).
        case .newerFormat(let what, _, _): return String(format: L("error.newerFormat"), what)
        case .unsafeArchivePath(let path): return String(format: L("error.core.unsafeArchivePath"), path)
        case .syncConflict: return L("error.core.syncConflict")
        case .syncServer(let status, let message):
            if status == 401 || status == 403 { return String(format: L("error.core.syncServerToken"), status) }
            return String(format: L("error.core.syncServer"), status, message.isEmpty ? "—" : message)
        case .io(let detail): return String(format: L("error.core.io"), detail)
        case .notGranted(let detail): return String(format: L("error.core.notGranted"), detail)
        // Settings that could not be read (R1): the profile does not start, and how to get them
        // back — a backup's copy of the file, or the server's through Sync Now (named as its menu
        // item is).
        case .unreadableSettings(let id, let profile, _):
            return String(format: L("error.core.unreadableSettings"), profile, "profiles/\(id.uuidString)/config.bin",
                          L("profiles.menu.syncNow"), L("profiles.menu.more"))
        }
    }
    if let error = error as? PasswordVaultError {
        return L(error == .duplicate ? "passwords.error.duplicate" : "passwords.error.notFound")
    }
    if let error = error as? UpdateError {
        switch error {
        case .notAnAppcast: return L("error.update.notAnAppcast")
        case .newerAppcastFormat(let format): return String(format: L("error.update.newerAppcastFormat"), format)
        case .unknownKey(let id): return String(format: L("error.update.unknownKey"), id)
        case .badSignature(let what): return L(what == "appcast" ? "error.update.badSignature.appcast" : "error.update.badSignature.archive")
        case .staleAppcast(let generated, let newest):
            return String(format: L("error.update.staleAppcast"), generated.shown(date: .abbreviated, time: .shortened),
                          newest.shown(date: .abbreviated, time: .shortened))
        case .invalidItem(let detail): return String(format: L("error.update.invalidItem"), detail)
        case .notNewer(let build, let running): return String(format: L("error.update.notNewer"), build, running)
        case .needsNewerSystem(let minimum): return String(format: L("error.update.needsNewerSystem"), minimum)
        case .archiveLength(let expected, let found): return String(format: L("error.update.archiveLength"), found, expected)
        case .archiveHash: return L("error.update.archiveHash")
        }
    }
    return nil
}
