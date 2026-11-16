import Foundation

/// When a machine's display is put to sleep and woken again, for a machine whose display sleeps
/// while its window is out of sight (`VMProfile.sleepsScreenWhenHidden`; docs/VM.md, "How smooth a
/// machine is").
///
/// A machine's macOS draws its screen whether or not anybody sees the window: the pages in it
/// animate, its window server composes them, and the virtual graphics card and this Mac's
/// processors do that work for nobody — for the second of two machines, all the time. With this
/// setting the helper leaves a word in the shared folder (`VMGuestSettings.screenSleepFileName`)
/// once the window has been out of sight — minimised, covered, on another desktop, this Mac's
/// screen off — for `after` seconds; the boot script puts the display to sleep while the word is
/// there (tools 14), as a Mac's display sleeps, and wakes it when the word is gone: the moment the
/// window is seen again.
///
/// Decided here, and unit-tested; the helper (`MachineRunner`) tells it the window's sight and the
/// time, and leaves or takes back the word as it is told.
public struct VMScreenSleep: Equatable, Sendable {
    /// How long the window is out of sight before the display is put to sleep: a glance at another
    /// window, or at the other machine for a moment, is not worth a dark screen on coming back.
    public static let after: TimeInterval = 30

    public enum Step: Equatable, Sendable {
        /// Leave the word: the display may sleep.
        case sleep
        /// Take the word back: the display is to be awake.
        case wake
    }

    /// The profile chose it, and the machine is a profile's (not the base during its setup).
    public let enabled: Bool
    /// Since when the window has been out of sight; nil while it is seen.
    public private(set) var hiddenSince: Date?
    /// The word is left for the guest.
    public private(set) var asked = false
    /// The guest left its display on, its screen lock being on: not asked again while this
    /// machine runs (waking a display behind a lock would ask the person for the password).
    public private(set) var refused = false

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    /// For the machine a helper's request starts: a profile's whose profile chose it — never the
    /// base during its setup, whose window is the person's to work in.
    public init(request: VMHelperRequest) {
        self.init(enabled: request.mode == .run && request.sleepsScreenWhenHidden == true && request.settingsRevision != nil)
    }

    /// The window came into sight, or went out of it, at `now`.
    public mutating func window(seen: Bool, at now: Date) -> Step? {
        guard seen else {
            if hiddenSince == nil { hiddenSince = now }
            return nil
        }
        hiddenSince = nil
        guard asked else { return nil }
        asked = false
        return .wake
    }

    /// When to look again (`check`); nil: nothing will be due while things stand as they are.
    public var due: Date? {
        guard enabled, !refused, !asked, let hiddenSince else { return nil }
        return hiddenSince.addingTimeInterval(Self.after)
    }

    /// Looked at once `due` has come. `busy`: the machine is starting behind its cover, being
    /// woken or being closed — its display is left as it is, and looked at again `after` from now.
    public mutating func check(at now: Date, busy: Bool) -> Step? {
        guard let due, now >= due else { return nil }
        if busy {
            hiddenSince = now
            return nil
        }
        asked = true
        return .sleep
    }

    /// What the guest said since the word was left (`VMGuestStatus.screenSleep`): a display it
    /// left on because the person's screen lock is on is not asked for again in this run, and the
    /// word is taken back.
    public mutating func guestSaid(_ status: VMGuestStatus) -> Step? {
        guard asked, status.screenSleepWouldLock else { return nil }
        refused = true
        asked = false
        return .wake
    }
}
