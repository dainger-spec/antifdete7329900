import Foundation

/// The app's texts in the person's language: Russian, as written in the sources, or English (the
/// owner, 10 November). A text is written once, in Russian, inside `L(…)`; its English is in
/// ios/Lumen/Resources/en.lproj/Localizable.strings under the same words, and any other language of
/// the device gets the English. What varies in a text is passed after it and stands as %@ in both
/// languages. ios/scripts/check_strings.py holds that every text has its English and that no
/// Russian text stands outside `L(…)`.
///
/// Looked up in the app's bundle; the core's own tests have no such table and read the Russian.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    // The planted fault: the table is not asked — every text stays as the sources write it.
    let text = Faults.isActive(.textsNotTranslated) ? key : Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

public enum Localization {
    /// Whether the texts come out in English: the table says so itself.
    public static var isEnglish: Bool { Bundle.main.localizedString(forKey: "__language", value: "ru", table: nil) == "en" }
}
