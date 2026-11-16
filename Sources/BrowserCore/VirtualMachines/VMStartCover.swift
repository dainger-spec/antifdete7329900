import Foundation

/// A step of a machine's start, as the cover over its screen names it. The guest's boot script
/// says which one it is at (`LUMEN_STAGE`, tools 13); `boot` is the cover's own word for the time
/// before the script has said anything at this start.
public enum VMSetupStage: String, CaseIterable, Comparable, Sendable {
    /// Nothing from this start's boot script yet: macOS is starting.
    case boot
    /// The script runs, and waits for the person's session (the automatic sign-in).
    case signin
    /// The language and region, the keyboard.
    case locale
    /// The appearance and accent colour, the clock and week, the scroll bars, the Dock.
    case look
    /// Lumen's desktop picture.
    case wallpaper
    /// The settings are in; Safari is being opened.
    case safari
    /// All of it is done.
    case ready

    /// The steps the cover counts, in order: `ready` has them all done.
    public static let steps: [VMSetupStage] = [.boot, .signin, .locale, .look, .wallpaper, .safari]

    /// How many of `steps` are behind at this stage: 0 at `boot`, all of them at `ready`.
    public var stepsDone: Int {
        Self.steps.firstIndex(of: self) ?? Self.steps.count
    }

    public static func < (lhs: VMSetupStage, rhs: VMSetupStage) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

/// When the cover over a profile's machine's screen goes (the helper's `MachineRunner`).
///
/// A machine's macOS shows its desktop well before the boot script has made it the profile's —
/// its language and region, its look, its Dock, its picture —, and what the person opens in that
/// time (Safari, in the base's language) stays as it was opened. So from the start of its macOS
/// the machine's window shows a cover that takes every click and key, and gives the screen only
/// once the guest says this start's settings are in. Never for good: "Show the screen" is offered
/// after a minute, and the cover goes by itself when the guest says nothing in time.
///
/// Pure: what the status file says (read by the helper, `VMShareFile`), when it was written, and
/// the clock — tested on Linux.
public enum VMStartCover {
    /// After this long a quiet "Show the screen" is offered under the steps.
    public static let offerAfter: TimeInterval = 60
    /// The cover goes by itself after this long when the guest's script has said nothing at this
    /// start: an older script that cannot say, a share that did not appear, a machine that does
    /// not get as far as its script.
    public static let silentLimit: TimeInterval = 120
    /// And after this long when the script is at work and says so, a step at a time: a machine's
    /// first start, a Mac it has never seen, is slower than its later ones.
    public static let workingLimit: TimeInterval = 180

    /// Why the cover goes.
    public enum Reveal: String, Equatable, Sendable {
        /// The guest says this start's settings are in (tools 13: `LUMEN_READY_REVISION`; a machine
        /// shown as a browser: Safari is open, `LUMEN_APPLIED_REVISION`).
        case ready
        /// An older script says it applied this start's settings (`LUMEN_APPLIED_REVISION`,
        /// which it writes after everything — Safari opened too).
        case applied
        /// Nothing said in time: the screen is given as it is, with a word about it.
        case timedOut
    }

    /// Whether a start of a machine is covered at all: a profile's (one with settings its guest
    /// puts in place, `VMHelperRequest.settingsRevision`) whose macOS starts. Not the base system,
    /// whose window is for its setup; and not a machine woken from a saved state — it is as it was
    /// closed, with the very settings it was put to sleep with (a state is tied to them,
    /// `VMHelperRequest.stamp`: changed, the machine starts anew, and that start is covered).
    ///
    /// Unless it was put to sleep before those settings were in (closed during its first start):
    /// its script goes on with them as it wakes, and the wake is covered until they are. What the
    /// script said last before the sleep is `asleepWith`; only tools 13 and on say it.
    public static func covers(settingsRevision: String?, woken: Bool, asleepWith status: VMGuestStatus? = nil) -> Bool {
        guard let settingsRevision, !settingsRevision.isEmpty else { return false }
        guard woken else { return true }
        guard let status, (status.toolsVersion ?? 0) >= VMGuestTools.saysWhenReady else { return false }
        return status.readyRevision != settingsRevision && status.appliedRevision != settingsRevision
    }

    /// What the cover shows, and whether it goes.
    public struct State: Equatable, Sendable {
        /// The step it names.
        public var stage: VMSetupStage
        /// "Show the screen" is offered.
        public var offersReveal: Bool
        /// Nil: the cover stays.
        public var reveal: Reveal?

        public init(stage: VMSetupStage, offersReveal: Bool = false, reveal: Reveal? = nil) {
            self.stage = stage
            self.offersReveal = offersReveal
            self.reveal = reveal
        }
    }

    /// The cover's state `now`, for a machine whose macOS started at `startedAt` with the settings
    /// `revision`. `status` is what its status file says (nil: none yet, or none to read) and
    /// `written` when that file was last written: a file from before the start is of a macOS that
    /// has since shut down, and says nothing of this start.
    ///
    /// A machine shown as a browser (`browserMode`) is let in only once Safari is open — the
    /// helper then puts it over the machine's whole screen: what its script writes after Safari
    /// was opened (`LUMEN_APPLIED_REVISION`), whatever its version.
    public static func state(status: VMGuestStatus?, written: Date?, startedAt: Date, revision: String,
                             browserMode: Bool = false, now: Date) -> State {
        let elapsed = now.timeIntervalSince(startedAt)
        var stage = VMSetupStage.boot
        var said: VMGuestStatus?
        if let status, let written, written >= startedAt { said = status }
        if let said {
            let tools = said.toolsVersion ?? 0
            // An older script says nothing of its steps: it is at work, from its first word on.
            stage = tools >= VMGuestTools.saysWhenReady ? max(said.stage ?? .signin, .signin) : .signin
            if !revision.isEmpty {
                if said.appliedRevision == revision {
                    return State(stage: .ready, reveal: tools >= VMGuestTools.saysWhenReady ? .ready : .applied)
                }
                if !browserMode, tools >= VMGuestTools.saysWhenReady, said.readyRevision == revision {
                    return State(stage: .ready, reveal: .ready)
                }
            }
        }
        if elapsed >= (said == nil ? silentLimit : workingLimit) {
            return State(stage: stage, offersReveal: true, reveal: .timedOut)
        }
        return State(stage: stage, offersReveal: elapsed >= offerAfter)
    }
}
