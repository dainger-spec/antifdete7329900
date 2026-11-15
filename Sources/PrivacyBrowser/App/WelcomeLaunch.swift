import BrowserCore
import Foundation

/// Whether this start of the app shows the launch screen (WelcomeSplash), and which greeting —
/// decided once, as the app model is made (`AppModel.welcome`), by WelcomeSplashPolicy: only at
/// the first launch, once (the owner, 15 November: "only at the first launch of the app").
///
/// Only the app as a person opens it can show it: main.swift says so in that branch alone, so a
/// profile's own process, the self-test, the UI snapshots, `--webdriver-serve` and every other CI
/// check or command-line run never do, and read and write nothing here. A window opened again while
/// the app runs is no start (the model outlives it). `open -a Lumen --args --welcome` shows it on
/// any Mac, to look at it.
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

    /// The app was opened with `--welcome`: the launch screen is shown, to be looked at.
    static var asked = false

    enum Keys {
        /// The index (`WelcomeLettering.all`) of the greeting the last launch screen wrote.
        static let lastGreeting = "welcome.lastGreeting"
        /// The launch screen was shown on this Mac: it is shown once.
        static let shown = "welcome.shown"
    }

    private static var decided = false

    /// The launch screen of this start; nil: none. Remembers that it was shown, and the greeting
    /// it chose.
    static func decide(firstLaunch: Bool, defaults: UserDefaults = .standard) -> Decision? {
        guard interactiveStart, !decided else { return nil }
        decided = true
        let mode = WelcomeSplashPolicy.mode(start: .interactive, vaultExists: !firstLaunch,
                                            shownBefore: defaults.bool(forKey: Keys.shown), asked: asked)
        guard mode != .none else { return nil }
        let all = WelcomeLettering.all
        let index = WelcomeSplashPolicy.nextGreeting(languages: all.map(\.code),
                                                     last: defaults.object(forKey: Keys.lastGreeting) as? Int,
                                                     interfaceLanguage: Localization.languageCode)
        guard all.indices.contains(index) else { return nil }
        defaults.set(index, forKey: Keys.lastGreeting)
        if !asked { defaults.set(true, forKey: Keys.shown) }
        // The glass's shader compiles in the background while the window comes up.
        WelcomeGlassRenderer.prepare()
        return Decision(firstLaunch: mode == .firstLaunch, greeting: all[index])
    }
}
