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
        // `--prepare choice=ru|en|none appleLanguages=ru,en|none`: the app's own preferences set the
        // way a person's choice or an earlier version left them, by the app itself, then nothing
        // else — the next start reads them. Not `defaults write <bundle id>`: once the sandboxed
        // build has run, that writes into its container, which this build does not read (CI run 588).
        if let index = CommandLine.arguments.firstIndex(of: "--prepare") {
            for setting in CommandLine.arguments.dropFirst(index + 1) {
                let parts = setting.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key: String, value: CFPropertyList?
                switch parts[0] {
                case "appleLanguages":
                    key = "AppleLanguages"
                    value = parts[1] == "none" ? nil : (parts[1].split(separator: ",").map(String.init) as NSArray)
                case "choice":
                    key = Localization.choiceKey
                    value = parts[1] == "none" ? nil : (parts[1] as NSString)
                default:
                    continue
                }
                Localization.setOnDisk(key, value)
            }
            print("INTERFACE-LANGUAGE prepared")
            exit(0)
        }
        // The app's own domain alone: the effective value would answer with the command line's or
        // this Mac's list too (CI run 583, the first version of this check).
        func onDisk() -> String {
            guard let value = Localization.languagesOnDisk else { return "none" }
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
