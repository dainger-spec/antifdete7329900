import BrowserCore
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
            return String(format: L("error.update.staleAppcast"), generated.formatted(date: .abbreviated, time: .shortened),
                          newest.formatted(date: .abbreviated, time: .shortened))
        case .invalidItem(let detail): return String(format: L("error.update.invalidItem"), detail)
        case .notNewer(let build, let running): return String(format: L("error.update.notNewer"), build, running)
        case .needsNewerSystem(let minimum): return String(format: L("error.update.needsNewerSystem"), minimum)
        case .archiveLength(let expected, let found): return String(format: L("error.update.archiveLength"), found, expected)
        case .archiveHash: return L("error.update.archiveHash")
        }
    }
    return nil
}
