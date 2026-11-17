import BrowserCore
import Foundation

/// Whether this start of the app shows the launch screen (WelcomeSplash) — decided once, as the
/// app model is made (`AppModel.welcome`), by WelcomeSplashPolicy: at the first start only, once,
/// unless Settings → Appearance → "Greet with the welcome window at every start" is on; always the
/// English greeting (the owner, 16 November).
///
/// Only the app as a person opens it can show it: main.swift says so in that branch alone, so a
/// profile's own process, the self-test, the UI snapshots, `--webdriver-serve` and every other CI
/// check or command-line run never do, and read and write nothing here. A window opened again while
/// the app runs is no start (the model outlives it).
@MainActor
enum WelcomeLaunch {
    struct Decision {
        /// No vault yet: the button leads on to the setup.
        let firstLaunch: Bool
        let greeting: WelcomeLettering
    }

    /// The app as a person opened it, set by main.swift before the app starts — not for
    /// `--settings-window-check`, CI's run of the same branch.
    static var interactiveStart = false

    enum Keys {
        /// The launch screen was shown on this Mac: without the setting, it is shown once.
        static let shown = "welcome.shown"
    }

    private static var decided = false

    /// The launch screen of this start; nil: none. Remembers that it was shown.
    static func decide(firstLaunch: Bool, defaults: UserDefaults = .standard) -> Decision? {
        guard interactiveStart, !decided else { return nil }
        decided = true
        let mode = WelcomeSplashPolicy.mode(start: .interactive, vaultExists: !firstLaunch,
                                            shownBefore: defaults.bool(forKey: Keys.shown),
                                            everyStart: AppearancePreferences.greetsEveryStart(defaults))
        guard mode != .none,
              let greeting = WelcomeLettering.all.first(where: { $0.code == WelcomeSplashPolicy.greetingLanguage }) else { return nil }
        defaults.set(true, forKey: Keys.shown)
        // The glass's shader compiles in the background while the window comes up.
        WelcomeGlassRenderer.prepare()
        return Decision(firstLaunch: mode == .firstLaunch, greeting: greeting)
    }
}
