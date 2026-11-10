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
    let text = Faults.isActive(.textsNotTranslated) ? key : Localization.table.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

public enum Localization {
    /// Whether the texts come out in English: the table says so itself.
    public static var isEnglish: Bool { table.localizedString(forKey: "__language", value: "ru", table: nil) == "en" }

    /// Where the texts are looked up: the app's bundle, which follows the iPhone's language. A test
    /// that finds things by their Russian words names the language instead (LUMEN_TEST_LANGUAGE, DEBUG
    /// builds only) — the simulator itself stays in English, with its keyboard and system labels
    /// (CI run 50: started in Russian with -AppleLanguages, the tests' typing came out wrong —
    /// a proxy's login, an account's password).
    static let table: Bundle = {
        #if DEBUG
        if let language = ProcessInfo.processInfo.environment["LUMEN_TEST_LANGUAGE"],
           let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        #endif
        return Bundle.main
    }()
}
