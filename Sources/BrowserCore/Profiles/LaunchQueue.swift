import Foundation

/// A selection's profiles started a few at a time: at most `atOnce` that have been started and whose
/// window has not come up yet; the next one when one of those has its window up, has ended, or has
/// run out of time. Started all at once, a selection ran a Mac's processors out from about twenty
/// profiles, and on macOS 27 its window server: windows came after minutes or not at all
/// (docs/SCALE.md).
public enum LaunchQueue {
    /// How many start at a time (the owner's choice).
    public static let atOnce = 4

    /// Starts each of `ids` in order with `start`, then waits with `windowUp` for its window (which
    /// returns when it is up, the profile has ended, or its time is out); at most `atOnce` of them
    /// between the two. Stops starting when `goesOn` says no — asked as each is queued and again as
    /// its turn comes, so that one queued before the answer changed (the vault locked meanwhile) is
    /// not started after it. Returns when every one started has been waited for.
    @MainActor
    public static func run<ID: Sendable>(_ ids: [ID], atOnce: Int = atOnce,
                                         goesOn: @escaping @Sendable @MainActor () -> Bool = { true },
                                         start: @escaping @Sendable @MainActor (ID) async -> Void,
                                         windowUp: @escaping @Sendable @MainActor (ID) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var starting = 0
            for id in ids {
                if starting >= max(1, atOnce) {
                    await group.next()
                    starting -= 1
                }
                guard goesOn() else { break }
                group.addTask { @MainActor in
                    guard goesOn() else { return }
                    await start(id)
                    await windowUp(id)
                }
                starting += 1
            }
        }
    }
}
