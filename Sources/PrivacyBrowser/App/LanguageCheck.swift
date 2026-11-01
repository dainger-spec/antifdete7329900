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
        if let index = arguments.firstIndex(of: "--pin-interface"), index + 1 < arguments.count {
            // The interface's language fixed first, then the argument domain given back as the
            // command line had it (the websites' list): what a profile's process would do.
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            var pinned = saved
            pinned["AppleLanguages"] = [arguments[index + 1]]
            UserDefaults.standard.setVolatileDomain(pinned, forName: UserDefaults.argumentDomain)
            let main = Bundle.main.preferredLocalizations
            _ = Bundle.main.localizedString(forKey: "settings.section.about", value: nil, table: nil)
            _ = Bundle.main.path(forResource: "Localizable", ofType: "strings")
            UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
            print("CHROME-LANG pinned \(arguments[index + 1]): main bundle preferred=\(main); argument domain back to \(String(describing: saved["AppleLanguages"]))")
        }
        nibFiles()
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
        print("CHROME-LANG AppKit preferred after install=\(Array(Bundle(for: NSApplication.self).preferredLocalizations.prefix(3))) WebKit preferred=\(Array(Bundle(for: WKWebView.self).preferredLocalizations.prefix(3)))")
        for path in safariApps {
            guard let app = Bundle(path: path) else { continue }
            print("CHROME-LANG \(path) answers MainMenu.nib: \(app.url(forResource: "MainMenu", withExtension: "nib")?.path ?? "nil") preferred=\(Array(app.preferredLocalizations.prefix(2))) localizations=\(app.localizations.count)")
            let nib = NSNib(nibNamed: "MainMenu", bundle: app)
            var objects: NSArray?
            if let nib, nib.instantiate(withOwner: nil, topLevelObjects: &objects),
               let menu = (objects as? [Any])?.compactMap({ $0 as? NSMenu }).first {
                print("CHROME-LANG NSNib(nibNamed: MainMenu, bundle: Safari.app) titles: \(menu.items.map(\.title).joined(separator: " | ")); second menu: \(menu.items.dropFirst().first?.submenu?.items.prefix(6).map(\.title).joined(separator: " | ") ?? "-")")
            } else {
                print("CHROME-LANG NSNib(nibNamed: MainMenu, bundle: Safari.app): \(nib == nil ? "nil" : "did not instantiate")")
            }
            break
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

    static let safariApps = ["/Applications/Safari.app", "/System/Applications/Safari.app",
                             "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]

    /// Which of Safari's bundles carry a nib per language, and which a Base nib with strings.
    static func nibFiles() {
        let frameworks = ["Safari", "SafariShared", "SafariSharedUI", "SafariCore"].flatMap { name in
            ["/System/Library/PrivateFrameworks", "/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks"]
                .map { "\($0)/\(name).framework" }
        }
        let fm = FileManager.default
        for root in safariApps.map({ $0 + "/Contents/Resources" }) + frameworks.flatMap({ [$0 + "/Resources", $0 + "/Versions/A/Resources"] }) {
            guard fm.fileExists(atPath: root) else { continue }
            var line: [String] = []
            for lproj in ["Base.lproj", "en.lproj", "English.lproj", "ru.lproj", "de.lproj"] {
                let files = (try? fm.contentsOfDirectory(atPath: root + "/" + lproj)) ?? []
                guard !files.isEmpty else { continue }
                let nibs = files.filter { $0.hasSuffix(".nib") }.count
                let strings = files.filter { $0.hasSuffix(".strings") || $0.hasSuffix(".loctable") || $0.hasSuffix(".stringsdict") }.count
                let menu = files.filter { $0.hasPrefix("MainMenu") }
                line.append("\(lproj) nibs=\(nibs) strings=\(strings) MainMenu=\(menu)")
            }
            let top = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
            let loose = top.filter { $0.hasSuffix(".nib") }.count
            let tables = top.filter { $0.hasSuffix(".loctable") }
            print("CHROME-LANG files \(root): top nibs=\(loose) loctables=\(tables.prefix(4)) | \(line.joined(separator: " ; "))")
        }
    }
}
