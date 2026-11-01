import AppKit
import BrowserCore
import WebKit

/// MEASUREMENT (branch claude/measure-language). Which language this app's interface takes and
/// from where, and — in a process like a profile's — which language Safari's chrome and menus take
/// and which language websites see, when the two are given apart.
@MainActor
enum LanguageCheck {
    private static func appDomain() -> Any? {
        CFPreferencesCopyAppValue("AppleLanguages" as CFString, (Bundle.main.bundleIdentifier ?? "io.lumenbrowser.Lumen") as CFString)
    }

    private static func global() -> Any? {
        CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func report(_ tag: String) {
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"]
        print("\(tag) languageCode=\(Localization.languageCode) L(settings.section.about)=\(L("settings.section.about"))")
        print("\(tag) AppleLanguages as read=\(UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [])")
        print("\(tag) argument domain=\(String(describing: argument)) app domain on disk=\(String(describing: appDomain())) global=\(String(describing: global()))")
        print("\(tag) Locale.preferredLanguages=\(Locale.preferredLanguages)")
        print("\(tag) main bundle localizations=\(Bundle.main.localizations) preferred=\(Bundle.main.preferredLocalizations)")
        print("\(tag) AppKit preferred=\(Array(Bundle(for: NSApplication.self).preferredLocalizations.prefix(3)))")
        print("\(tag) en.lproj=\(Bundle.main.path(forResource: "en", ofType: "lproj") ?? "MISSING") ru.lproj=\(Bundle.main.path(forResource: "ru", ofType: "lproj") ?? "MISSING")")
    }

    /// `--language-check`: the app as it starts.
    static func run(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        report("LANG-CHECK before")
        Localization.applyProcessLanguage()
        report("LANG-CHECK after applyProcessLanguage")
        exit(0)
    }

    /// `--chrome-language-check [--sites-languages en-US,en]`: Safari's chrome in a process like a
    /// profile's; with `--sites-languages`, the argument domain's AppleLanguages switched to it after
    /// the menus are made and before any web process starts.
    static func runChrome(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard SafariChrome.prepareForCheck(arguments: arguments) else {
            print("CHROME-LANG Safari's chrome cannot be hosted in this build")
            exit(2)
        }
        report("CHROME-LANG start")
        _ = SafariChrome.installMainMenu()
        NSApplication.shared.setActivationPolicy(.regular)
        print("CHROME-LANG menu titles after install: \((NSApp.mainMenu?.items.map(\.title) ?? []).joined(separator: " | "))")
        if let safariClass = NSClassFromString("BrowserWindowController") {
            let safari = Bundle(for: safariClass)
            print("CHROME-LANG Safari.framework \(safari.bundleIdentifier ?? "?") preferred=\(Array(safari.preferredLocalizations.prefix(3))) has ru=\(safari.localizations.contains("ru")) en=\(safari.localizations.contains("en") || safari.localizations.contains("English"))")
        }
        if let index = arguments.firstIndex(of: "--sites-languages"), index + 1 < arguments.count {
            let sites = arguments[index + 1].split(separator: ",").map(String.init)
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain["AppleLanguages"] = sites
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            print("CHROME-LANG switched the argument domain's AppleLanguages to \(sites) for WebKit")
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.loadHTMLString("<html><body>language</body></html>", baseURL: URL(string: "https://language.selftest.invalid/"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                let controller = SafariChrome.openWindow(address: URL(string: "about:blank"))
                controller?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                print("CHROME-LANG Safari's window \(controller == nil ? "did not open" : "is open")")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                print("CHROME-LANG menu titles with the window: \((NSApp.mainMenu?.items.map(\.title) ?? []).joined(separator: " | "))")
                let file = NSApp.mainMenu?.items.dropFirst().first?.submenu?.items.prefix(6).map(\.title) ?? []
                print("CHROME-LANG second menu's first items: \(file.joined(separator: " | "))")
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Browser") }) ?? NSApp.windows.first(where: \.isVisible) {
                    print("CHROME-LANG window \(window.className) title=\(window.title) toolbar=\((window.toolbar?.items.map { $0.label.isEmpty ? $0.paletteLabel : $0.label } ?? []).joined(separator: " | "))")
                }
                report("CHROME-LANG end")
                webView.evaluateJavaScript("navigator.language + ' / ' + navigator.languages.join(',') + ' / ' + Intl.DateTimeFormat().resolvedOptions().locale") { value, error in
                    print("CHROME-LANG what a page sees: \(value.map { "\($0)" } ?? "error \(String(describing: error))")")
                    exit(0)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(3) }
        NSApplication.shared.run()
        exit(0)
    }
}
