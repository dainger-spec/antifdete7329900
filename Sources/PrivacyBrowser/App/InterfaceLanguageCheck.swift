import AppKit
import BrowserCore

/// `--interface-language-check`: which language the interface takes as the app starts, and from
/// where, printed as `INTERFACE-LANGUAGE key=value` lines for CI (`scripts/interface_language_check.sh`).
///
/// Until 1 November the interface was Russian whatever the Mac or the command line said, and every
/// start wrote `AppleLanguages = (ru, en)` into the app's preferences on disk (the owner's finding:
/// `open Lumen.app --args -AppleLanguages "(en)"` came up in Russian; measured in CI run 577). CI
/// runs this plain, with `-AppleLanguages`, with a choice made, and after such a write.
@MainActor
enum InterfaceLanguageCheck {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let domain = (Bundle.main.bundleIdentifier ?? "io.lumenbrowser.Lumen") as CFString
        func onDisk() -> String {
            guard let value = CFPreferencesCopyAppValue("AppleLanguages" as CFString, domain) else { return "none" }
            return (value as? [String])?.joined(separator: ",") ?? "\(value)"
        }
        let before = onDisk()
        Localization.applyProcessLanguage()
        let lines = [
            "language=\(Localization.languageCode)",
            // A word of the interface, from the table the language chose.
            "word=\(L("settings.section.about"))",
            "choice=\(Localization.choice.rawValue)",
            "onDiskBefore=\(before)",
            "onDiskAfter=\(onDisk())",
            // What AppKit and the frameworks take (the main bundle's, which they follow).
            "bundles=\(Localization.bundlesLanguage)",
            "appKit=\(Bundle(for: NSApplication.self).preferredLocalizations.first ?? "?")",
        ]
        for line in lines { print("INTERFACE-LANGUAGE \(line)") }
        exit(0)
    }
}
