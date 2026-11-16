import BrowserCore
import Foundation

/// Whether this start of the app shows the launch screen (WelcomeSplash) — decided once, as the
/// app model is made (`AppModel.welcome`), by WelcomeSplashPolicy: at every start a person makes,
/// after a full quit too, and always the English greeting (the owner, 16 November).
///
/// Only the app as a person opens it can show it: main.swift says so in that branch alone, so a
/// profile's own process, the self-test, the UI snapshots, `--webdriver-serve` and every other CI
/// check or command-line run never do. A window opened again while the app runs is no start (the
/// model outlives it).
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

    private static var decided = false

    /// The launch screen of this start; nil: none.
    static func decide(firstLaunch: Bool) -> Decision? {
        guard interactiveStart, !decided else { return nil }
        decided = true
        let mode = WelcomeSplashPolicy.mode(start: .interactive, vaultExists: !firstLaunch)
        guard mode != .none,
              let greeting = WelcomeLettering.all.first(where: { $0.code == WelcomeSplashPolicy.greetingLanguage }) else { return nil }
        // The glass's shader compiles in the background while the window comes up.
        WelcomeGlassRenderer.prepare()
        return Decision(firstLaunch: mode == .firstLaunch, greeting: greeting)
    }
}
