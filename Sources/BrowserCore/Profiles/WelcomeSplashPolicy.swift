import Foundation

/// The launch screen's two decisions (the app's `WelcomeSplash`): whether this start of the app
/// shows it, and in which language its greeting is written. The owner, 15 November: a greeting
/// written as with a pen, a couple of seconds, then the app opens smoothly — and, the same day:
/// "only at the first launch of the app". So it is shown once: at the first start a person makes
/// of an app that has no vault yet.
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
        /// The first launch, no vault yet: the greeting, then a button that leads to the setup.
        case firstLaunch
        /// Asked for by hand on a Mac that has a vault (`open -a Lumen --args --welcome`, to look
        /// at it): the greeting, a moment's hold, then the lock screen by itself.
        case returning
    }

    /// Whether a start shows the launch screen, and how.
    ///
    /// - `vaultExists`: a vault is there — not the first launch.
    /// - `shownBefore`: the launch screen was shown on this Mac already (the app remembers it):
    ///   a person who met it and quit before making a vault does not meet it again.
    /// - `asked`: the app was opened with `--welcome`, to look at the launch screen: shown whatever
    ///   the two above say, and not remembered.
    public static func mode(start: Start, vaultExists: Bool, shownBefore: Bool, asked: Bool = false) -> Mode {
        guard start == .interactive else { return .none }
        if asked { return vaultExists ? .returning : .firstLaunch }
        return vaultExists || shownBefore ? .none : .firstLaunch
    }

    /// The greeting to write, as an index into `languages` (the greetings' order): the interface's
    /// own language the first time one is shown (`last` nil, or no longer an index of the list) —
    /// the first launch's — and, when the screen is asked for again (`--welcome`), the next language
    /// each time, round the list. The caller remembers the answer as the next `last`. 0 when the list has no greeting in
    /// the interface's language; -1 when it is empty.
    public static func nextGreeting(languages: [String], last: Int?, interfaceLanguage: String) -> Int {
        guard !languages.isEmpty else { return -1 }
        if let last, languages.indices.contains(last) {
            return (last + 1) % languages.count
        }
        let code = String(interfaceLanguage.lowercased().prefix { $0.isLetter })
        return languages.firstIndex(of: code) ?? 0
    }
}
