import Foundation

/// The language of the app's own interface: its windows, its menus, and Safari's chrome in a
/// profile's window. Never the language websites see — `ProfileConfiguration`'s locale and
/// `WebContentLanguage` decide that, from the profile alone. The two are apart in both directions
/// (the owner, 1 November: an interface in Russian, a profile that looks American to every site).
///
/// Until 1 November the interface was Russian whatever the Mac or the command line said: the
/// language was taken from `PRIVACYBROWSER_LANG` or else the first supported one, and every start
/// wrote `AppleLanguages = (ru, en)` into the app's own preferences on disk — so `open Lumen.app
/// --args -AppleLanguages "(en)"` still came up in Russian (the owner's finding).
public enum InterfaceLanguage {
    /// The languages the app is translated into, the fallback last.
    public static let supported = ["ru", "en"]
    public static let fallback = "en"

    /// What the person chose in Settings › Language (or on the first screen).
    public enum Choice: String, CaseIterable, Sendable {
        /// As the Mac's own language list says.
        case system
        case ru
        case en
    }

    /// The interface's language, in this order:
    ///
    /// 1. `environment`: `PRIVACYBROWSER_LANG`, the self-test's and CI's;
    /// 2. `commandLine`: `-AppleLanguages` given for this run (`open … --args -AppleLanguages
    ///    "(en)"`, Xcode's scheme language) — for this run only;
    /// 3. the person's `choice`, unless it is "as the system";
    /// 4. the first of the Mac's own languages (`system`, the global domain's AppleLanguages) the
    ///    app is translated into;
    /// 5. English.
    public static func resolve(environment: String?, commandLine: [String]?, choice: Choice?, system: [String]) -> String {
        if let environment = environment?.lowercased(), supported.contains(environment) { return environment }
        if let code = commandLine.flatMap(firstSupported) { return code }
        if let choice, choice != .system { return choice.rawValue }
        return firstSupported(system) ?? fallback
    }

    /// The first of `languages` ("ru-RU", "en-GB", "de") the app is translated into, as its code.
    public static func firstSupported(_ languages: [String]) -> String? {
        for language in languages {
            let code = String(language.lowercased().prefix { $0.isLetter })
            if supported.contains(code) { return code }
        }
        return nil
    }

    /// Whether a value found in the app's own preferences under `AppleLanguages` is the one this
    /// app's earlier versions wrote at every start (`[ru, en]`, or `[en, en]` with
    /// `PRIVACYBROWSER_LANG=en`) — removed once, at the next start; anything else is the person's
    /// own (`defaults write`) and stays.
    public static func isEarlierVersionsWrite(_ value: Any?) -> Bool {
        guard let list = value as? [String] else { return false }
        return list == ["ru", "en"] || list == ["en", "en"]
    }
}
