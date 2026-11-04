import AppKit

/// In a profile shown in Safari's window, Safari's items that show or clear history — History ›
/// Show All History (⌘Y), Safari › Clear History… — act on the profile's own history.
///
/// A profile has one history: its own, encrypted with its key in the vault, which every page of its
/// windows is recorded in (`HostedPageHistory`), which outlives a restart and a change of account
/// (the account switch check, run 681), which sync merges and an export carries. Safari's own history
/// lives in Safari's History service, an XPC service of Safari.app that no other process can start
/// (docs/SAFARI_SUBSYSTEMS.md): in a profile's window Safari's History view showed nothing and its
/// "Clear History…" could not be chosen — the owner's Mac, 0.1.2, 4 November, three pages open and
/// the window empty. So these items open the profile's history in its library window, the same view
/// as "History" in the Profiles window: the person sees what the profile keeps, and clears it there.
@MainActor
final class HistoryMenuRoute: NSObject, NSMenuItemValidation {
    static let shared = HistoryMenuRoute()
    private weak var session: BrowserSession?
    private var isObserving = false

    /// Routes the items now, and again whenever a menu of the menu bar opens (Safari fills its
    /// History menu as it opens).
    static func install(session: BrowserSession) {
        shared.session = session
        shared.route()
        guard !shared.isObserving else { return }
        shared.isObserving = true
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HistoryMenuRoute.shared.route() }
        }
    }

    /// Whether an item shows all history: ⌘Y in the menu bar.
    static func showsAllHistory(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == "y" && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }

    /// Whether an item clears history: its action says so (Safari's "Clear History…" and "Clear
    /// History and Keep Website Data…").
    static func clearsHistory(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return action == #selector(clearProfileHistory(_:)) || NSStringFromSelector(action).lowercased().contains("clearhistory")
    }

    private func route() {
        guard let bar = NSApp.mainMenu else { return }
        walk(bar)
    }

    private func walk(_ menu: NSMenu) {
        for item in menu.items {
            if Self.showsAllHistory(item) {
                item.target = self
                item.action = #selector(showProfileHistory(_:))
            } else if Self.clearsHistory(item), item.action != #selector(clearProfileHistory(_:)) {
                item.target = self
                item.action = #selector(clearProfileHistory(_:))
            }
            if let submenu = item.submenu { walk(submenu) }
        }
    }

    @objc func showProfileHistory(_ sender: Any?) {
        session?.showLibrary(.history)
    }

    /// The profile's history, where its "Clear History" asks how much and clears its own store.
    @objc func clearProfileHistory(_ sender: Any?) {
        session?.showLibrary(.history)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { session != nil }
}
