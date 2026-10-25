import Foundation

/// Localization for the app's own strings.
///
/// Russian is the default UI language; English is the fallback. Rather than rely on the
/// system language or on `AppleLanguages` taking effect mid-launch, every string is looked up
/// from an explicitly chosen `.lproj` bundle, so the language is deterministic in the same run.
///
/// `L(key)` returns a plain `String`. We pass already-localized `String`s into SwiftUI controls
/// and AppKit (`NSAlert`, `NSMenu`, window titles) alike, which sidesteps the SwiftUI-Package
/// pitfall where `Text("literal")` would look in `Bundle.main` and miss the module's resources.
///
/// `build-app.sh` copies `en.lproj` and `ru.lproj` into the app bundle's `Resources`. When the
/// executable is run outside a bundle (`swift run`, the `--self-test` binary) the tables are
/// absent and `L` returns the key unchanged — acceptable, as those paths show no localized UI.
enum Localization {
    /// Supported languages, default first.
    static let supported = ["ru", "en"]

    /// Resolved once. Order: `PRIVACYBROWSER_LANG` env → first supported language (ru).
    static let languageCode: String = {
        if let requested = ProcessInfo.processInfo.environment["PRIVACYBROWSER_LANG"]?.lowercased(),
           supported.contains(requested) {
            return requested
        }
        return supported.first ?? "en"
    }()

    /// The chosen language's bundle, then English, then the main bundle (keys returned verbatim).
    static let bundle: Bundle = {
        for code in [languageCode, "en"] {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }()

    /// Makes the standard AppKit menus and system dialogs (App menu, Edit menu, panels) follow
    /// the chosen language too. Call once, as early as possible in `main`.
    static func applyProcessLanguage() {
        UserDefaults.standard.set([languageCode, "en"], forKey: "AppleLanguages")
    }

    static func string(_ key: String) -> String {
        // `value: key` → if the key is missing from both the chosen and English tables, show the
        // key itself rather than an empty string.
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Shorthand used throughout the UI and AppKit call sites.
func L(_ key: String) -> String { Localization.string(key) }
