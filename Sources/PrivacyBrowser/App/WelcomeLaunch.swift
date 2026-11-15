import BrowserCore
import Foundation

/// Whether this start of the app shows the launch screen (WelcomeSplash), and which greeting —
/// decided once, as the app model is made (`AppModel.welcome`), by WelcomeSplashPolicy.
///
/// Only the app as a person opens it can show it: main.swift says so in that branch alone, so a
/// profile's own process, the self-test, the UI snapshots, `--webdriver-serve` and every other CI
/// check or command-line run never do, and read and write nothing here. A window opened again while
/// the app runs is no start (the model outlives it). The app's own restarts are seamless: Settings ›
/// Language reopens the app to change the language, an update's installer to start the new build —
/// the person is waiting to see that, not a greeting (`markSeamlessRelaunch`).
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
        /// The index (`WelcomeLettering.all`) of the greeting the last launch screen wrote.
        static let lastGreeting = "welcome.lastGreeting"
        /// When the app last quit to be opened again by itself.
        static let seamlessRelaunch = "welcome.seamlessRelaunchAt"
    }

    private static var decided = false

    /// The launch screen of this start; nil: none. Remembers the greeting it chose, so the next
    /// start writes the next language, and takes away the mark of the app's own restart.
    static func decide(firstLaunch: Bool, defaults: UserDefaults = .standard, now: Date = Date()) -> Decision? {
        guard interactiveStart, !decided else { return nil }
        decided = true
        let marked = defaults.object(forKey: Keys.seamlessRelaunch) as? Date
        defaults.removeObject(forKey: Keys.seamlessRelaunch)
        let enabled = defaults.object(forKey: AppearancePreferences.Keys.welcome) as? Bool ?? true
        let mode = WelcomeSplashPolicy.mode(start: .interactive, enabled: enabled, vaultExists: !firstLaunch,
                                            seamlessRelaunchAt: marked, now: now)
        guard mode != .none else { return nil }
        let all = WelcomeLettering.all
        let index = WelcomeSplashPolicy.nextGreeting(languages: all.map(\.code),
                                                     last: defaults.object(forKey: Keys.lastGreeting) as? Int,
                                                     interfaceLanguage: Localization.languageCode)
        guard all.indices.contains(index) else { return nil }
        defaults.set(index, forKey: Keys.lastGreeting)
        return Decision(firstLaunch: mode == .firstLaunch, greeting: all[index])
    }

    /// This app quits now to be opened again by itself (SystemOpen: Settings › Language's restart,
    /// an update's installer): the start that follows shows no launch screen.
    static func markSeamlessRelaunch(defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(now, forKey: Keys.seamlessRelaunch)
    }
}
