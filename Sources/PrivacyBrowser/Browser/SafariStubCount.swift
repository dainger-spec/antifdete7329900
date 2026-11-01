import Foundation

/// How often each of Safari's methods replaced by a counted stub was reached in this process, by
/// "-[Class selector]": what the self-test reads back from a profile's process (its network
/// report), so that a check of a stub shows the stub was reached — by the page that needs it —
/// and not only that nothing went wrong. Any thread.
enum SafariStubCount {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func reached(_ key: String) {
        lock.withLock { counts[key, default: 0] += 1 }
    }

    static var snapshot: [String: Int] {
        lock.withLock { counts }
    }
}
