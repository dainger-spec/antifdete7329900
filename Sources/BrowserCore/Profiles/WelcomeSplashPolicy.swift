import Foundation

/// The launch screen's two decisions (the app's `WelcomeSplash`): whether this start of the app
/// shows it, and in which language its greeting is written. The owner, 15 November: a greeting
/// written as with a pen, a couple of seconds, then the app opens smoothly — and, the same day:
/// "only at the first launch of the app"; and on 16 November, having seen it: at every full quit
/// and start, and always the English "welcome". So every start a person makes of the app shows it.
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

    /// Whether a start shows the launch screen, and how: every start a person makes does — with a
    /// vault it leads to the lock screen by itself, without one to the setup by its button. The
    /// executable's other runs never show it.
    public static func mode(start: Start, vaultExists: Bool) -> Mode {
        guard start == .interactive else { return .none }
        return vaultExists ? .returning : .firstLaunch
    }

    /// The one greeting written: the English one, whatever the interface's language.
    public static let greetingLanguage = "en"
}
