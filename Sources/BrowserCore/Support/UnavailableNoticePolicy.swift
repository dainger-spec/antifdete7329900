import Foundation

/// When a profile's window may tell the person that one of Safari's features failed there
/// ("This Safari feature is not available in a profile"), after AppKit's run loop caught an
/// Objective-C exception of Safari's code.
///
/// A customer could type nothing into Safari's address bar (0.1.17 or earlier): each key press
/// threw somewhere in Safari's code, the run loop caught it, and the window put the notice up over
/// the field at every key, taking the keyboard from it — the customer uninstalled the app. So a
/// caught exception never makes the window unusable:
///
///   * a key press with no menu item behind it, while text is being typed — the address bar, the
///     find bar, a page's field — is never told about: written to the log only. Typing must go on.
///   * a menu item's failure is told once per item (the person chose it, and should know why
///     nothing happened), and not again for that item while the process runs;
///   * anything else asked for by a key or a click is told once per process;
///   * and never two notices within `cooldown` of each other, whatever they are about.
///
/// Pure and in BrowserCore so that its rules are tested (`UnavailableNoticePolicyTests`); the
/// profile's process holds one (`SafariChrome.showUnavailable`).
public struct UnavailableNoticePolicy: Sendable {
    /// What the person was doing when the run loop caught the exception.
    public enum Cause: Equatable, Sendable {
        /// A menu item was chosen (by a click or its shortcut) moments before; its title, or "".
        case menuItem(String)
        /// A key press; `intoText` when the key went to something that takes text (a field editor,
        /// a text field or view, a web view).
        case key(intoText: Bool)
        /// A click.
        case click
        /// Nothing the person did: a timer, a page loading.
        case other
    }

    public enum Decision: Equatable, Sendable {
        /// Tell the person; with the menu item's title when there was one.
        case show(menuItem: String?)
        /// Write it in the log only, and why.
        case logOnly(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case typing, notAskedFor, itemAlreadyTold, alreadyToldOnce, coolingDown
    }

    /// The least time between two notices.
    public var cooldown: TimeInterval

    private var toldItems: Set<String> = []
    private var toldGeneral = false
    private var lastShown: Date?

    public init(cooldown: TimeInterval = 60) {
        self.cooldown = cooldown
    }

    /// What to do about one caught exception, at `now`; a `.show` is counted as shown.
    public mutating func decide(_ cause: Cause, now: Date = Date()) -> Decision {
        switch cause {
        case .other:
            return .logOnly(.notAskedFor)
        case .key(intoText: true):
            return .logOnly(.typing)
        case .menuItem(let title):
            if toldItems.contains(title) { return .logOnly(.itemAlreadyTold) }
            if isCooling(now) { return .logOnly(.coolingDown) }
            toldItems.insert(title)
            lastShown = now
            return .show(menuItem: title)
        case .key(intoText: false), .click:
            if toldGeneral { return .logOnly(.alreadyToldOnce) }
            if isCooling(now) { return .logOnly(.coolingDown) }
            toldGeneral = true
            lastShown = now
            return .show(menuItem: nil)
        }
    }

    private func isCooling(_ now: Date) -> Bool {
        guard let lastShown else { return false }
        return now.timeIntervalSince(lastShown) < cooldown
    }
}
