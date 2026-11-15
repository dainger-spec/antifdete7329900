import Foundation

/// The launch screen's two decisions (the app's `WelcomeSplash`; the owner, 15 November: "at the
/// first launch, and at a launch after a full quit, a greeting written as with a pen, in different
/// languages, a couple of seconds, then the app opens smoothly"): whether this start of the app
/// shows it, and in which language its greeting is written.
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
        /// A later cold start: the greeting, a moment's hold, then the lock screen by itself.
        case returning
    }

    /// How long a mark left by the app's own restart stands for the next start: Settings ›
    /// Language's restart reopens the app within seconds, an update's installer once it has checked
    /// and swapped the release (it gives up after 10 minutes of waiting, a request is good for 15).
    public static let seamlessWindow: TimeInterval = 15 * 60

    /// Whether a start shows the launch screen, and how.
    ///
    /// - `enabled`: Settings › Appearance › "Greeting at launch" (on unless turned off).
    /// - `vaultExists`: a vault is there — not the first launch.
    /// - `seamlessRelaunchAt`: when this app last quit to be opened again by itself (Settings ›
    ///   Language, an update's installer). The start that follows within `seamlessWindow` is that
    ///   reopening, which the person is waiting through to see a change: it is seamless, no
    ///   greeting. A mark from the future (a clock set back) is not believed.
    public static func mode(start: Start, enabled: Bool, vaultExists: Bool, seamlessRelaunchAt: Date?,
                            now: Date) -> Mode {
        guard start == .interactive, enabled else { return .none }
        if let marked = seamlessRelaunchAt {
            let since = now.timeIntervalSince(marked)
            if since >= -60, since <= seamlessWindow { return .none }
        }
        return vaultExists ? .returning : .firstLaunch
    }

    /// The greeting to write, as an index into `languages` (the greetings' order): the interface's
    /// own language the first time one is shown (`last` nil, or no longer an index of the list), and
    /// after that the next language each time, round the list — the person meets them all over
    /// time. The caller remembers the answer as the next `last`. 0 when the list has no greeting in
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
