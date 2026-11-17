import Foundation

/// The launch screen's two decisions (the app's `WelcomeSplash`): whether this start of the app
/// shows it, and in which language its greeting is written. The owner, 15 November: a greeting
/// written as with a pen, a couple of seconds, then the app opens smoothly — "only at the first
/// launch of the app"; on 16 November, at every start and always the English "welcome"; and later
/// the same day, having lived with it: only at the first start after all, with a setting (Settings →
/// Appearance, off by default) that greets at every start for whoever wants it.
public enum WelcomeSplashPolicy {
    /// How this process came to run.
    public enum Start: Equatable, Sendable {
        /// The app as a person opens it — Finder, the Dock, Spotlight, `open`: a cold start of its
        /// process. A window opened again while the app runs is not a start.
        case interactive
        /// Anything else the executable runs as: a profile's own process, the self-test, the UI
        /// snapshots, a CI check, `--webdriver-serve`, a command-line tool.
        case other
    }

    /// What the launch screen does this time.
    public enum Mode: Equatable, Sendable {
        /// Not shown: straight to the first screen (sign-in or setup) or the lock screen.
        case none
        /// No vault yet: the greeting, then a button that leads to the setup.
        case firstLaunch
        /// A Mac that has a vault: the greeting, a moment's hold, then the lock screen by itself.
        case returning
    }

    /// Whether a start shows the launch screen, and how.
    ///
    /// - `vaultExists`: a vault is there — not the first launch.
    /// - `shownBefore`: the launch screen was shown on this Mac already (the app remembers it): a
    ///   person who met it and quit before making a vault does not meet it again.
    /// - `everyStart`: the setting "Greet with the welcome window at every start" (off by default):
    ///   every start a person makes shows it — with a vault it leads to the lock screen by itself.
    ///
    /// The executable's other runs never show it.
    public static func mode(start: Start, vaultExists: Bool, shownBefore: Bool, everyStart: Bool = false) -> Mode {
        guard start == .interactive else { return .none }
        if everyStart { return vaultExists ? .returning : .firstLaunch }
        return vaultExists || shownBefore ? .none : .firstLaunch
    }

    /// The one greeting written: the English one, whatever the interface's language.
    public static let greetingLanguage = "en"
}
