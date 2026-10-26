import AppKit

/// Quit (⌘Q, the app menu, the Dock, a script, logout) while profiles run, launch or seal:
/// every window closes and every profile is sealed before the process exits.
///
/// The seal must not run while AppKit waits inside `terminate:` (`.terminateLater`): whatever
/// called `terminate:` stays on the stack until the reply. On ⌘Q in a focused page that caller
/// is WebKit itself — it re-sends the key event the page did not handle while retaining the web
/// view (`WebViewImpl::doneWithKeyEvent`) — and the web view keeps the profile's data store in
/// use: `WKWebsiteDataStore.remove(forIdentifier:)` failed for as long as the seal retried, and
/// the profile stayed unsealed ("WebKit did not release the data store…"). Closing the window
/// with its close button never has WebKit below it, which is why only ⌘Q failed.
///
/// So the first `terminate:` is cancelled; the stack unwinds, windows close and profiles seal in
/// the normal run loop, and `terminate:` is sent again once nothing is left (`.terminateNow`).
/// Only a logout, restart or shutdown waits inside `terminate:` — cancelling it would cancel the
/// logout — and its quit Apple Event has no web view below it.
@MainActor
final class QuitCoordinator {
    private let hasActivity: @MainActor () -> Bool
    private let lockForQuit: @MainActor () async -> Void
    private let willSeal: @MainActor () -> Void
    private let terminate: @MainActor () -> Void
    private var quitTask: Task<Void, Never>?
    private var replyPending = false
    private var sealed = false

    /// - Parameters:
    ///   - hasActivity: a profile is running, launching or sealing, or a Lock is under way.
    ///   - lockForQuit: closes every window and seals every profile; returns when done.
    ///   - willSeal: called once when a cancelled quit starts sealing (shows the progress).
    ///   - terminate: sends `terminate:` again (`NSApp.terminate(nil)`; the self-test records it).
    init(hasActivity: @escaping @MainActor () -> Bool,
         lockForQuit: @escaping @MainActor () async -> Void,
         willSeal: @escaping @MainActor () -> Void = {},
         terminate: @escaping @MainActor () -> Void) {
        self.hasActivity = hasActivity
        self.lockForQuit = lockForQuit
        self.willSeal = willSeal
        self.terminate = terminate
        _ = Self.powerOffObserver
    }

    /// The answer for `applicationShouldTerminate(_:)`.
    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sealed (or nothing to seal): this is the second terminate:.
        guard !sealed, hasActivity() else { return .terminateNow }
        if Self.powerOffRequested || Self.isSystemQuitEvent(NSAppleEventManager.shared().currentAppleEvent) {
            if !replyPending {
                replyPending = true
                Task { @MainActor in
                    await self.sealEverything()
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        if quitTask == nil {
            // Starts once the event that called terminate: has returned, i.e. once WebKit's
            // frames (and the web view they hold) are off the stack.
            quitTask = Task { @MainActor in
                self.willSeal()
                await self.sealEverything()
                self.quitTask = nil
                self.terminate()
            }
        }
        return .terminateCancel // ⌘Q again while sealing: the quit under way finishes it
    }

    private func sealEverything() async {
        // `lockForQuit` returns when nothing runs, launches or seals any more. Another round is
        // needed only if a Lock already under way finished just before this quit could join it.
        // Bounded: data that still could not be sealed is re-sealed at the next unlock.
        var rounds = 0
        while hasActivity() && rounds < 3 {
            rounds += 1
            await lockForQuit()
        }
        sealed = true
    }

    // MARK: Logout, restart, shutdown

    private static var powerOffRequested = false
    private static let powerOffObserver: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { QuitCoordinator.powerOffRequested = true }
    }

    /// The quit Apple Event of a logout, restart or shutdown carries a quit reason attribute;
    /// one from the Dock or a script has none.
    static func isSystemQuitEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == coreEventClass, event.eventID == quitApplicationEvent else { return false }
        return event.attributeDescriptor(forKeyword: quitReasonKeyword) != nil
    }
}

// Four-character codes from AppleEvents.h (kCoreEventClass, kAEQuitApplication, kAEQuitReason).
private let coreEventClass: AEEventClass = 0x6165_7674 // 'aevt'
private let quitApplicationEvent: AEEventID = 0x7175_6974 // 'quit'
private let quitReasonKeyword: AEKeyword = 0x7768_793F // 'why?'
