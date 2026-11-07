import BrowserCore
import Foundation

/// Safari on this Mac runs an engine of its own, newer than the WebKit macOS gives apps: Safari 27
/// installed on macOS 26 brings its WebKit into its own part of the system (the App cryptex's
/// StagedFrameworks/Safari) and runs it alone (CI runs 718 and 723, the runner image of 2 November).
/// Profiles run the system's WebKit and name its Safari (`HostSafari.declared`), so sites see that
/// older Safari. It stays so across restarts and macOS 26 updates; macOS 27 ends it. Said once in
/// the profiles window for each pair of versions (the lead, 0.1.4), and always in Settings › About.
@MainActor
enum EngineWarning {
    struct Facts: Equatable {
        /// Safari.app's version, e.g. "27.2".
        var safari: String
        /// The Safari profiles name: the one of the WebKit this Mac gives apps, e.g. "26.6.2".
        var engine: String
        /// This Mac's macOS, e.g. 26.
        var macOS: Int
        var nextMacOS: Int { macOS + 1 }
        /// Said once for each pair: a newer Safari, or a new system WebKit, says it again.
        var key: String { "\(safari)|\(engine)" } // l10n: not text
    }

    /// Set by the snapshots only: the state of a Mac with two engines, on whatever runner they run.
    static var standIn: Facts?

    /// Nil when Safari and profiles run one engine, or Safari.app cannot be read.
    static var current: Facts? {
        if let standIn { return standIn }
        guard !HostSafari.declared.sharesEngine, let app = HostSafari.app else { return nil }
        return Facts(safari: app.version, engine: HostSafari.version,
                     macOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    private static let seenKey = "engineWarning.seen" // l10n: not text

    /// What the profiles window says: nil once "OK" was pressed for this pair.
    static func unseen(_ facts: Facts?) -> Facts? {
        guard let facts, UserDefaults.standard.string(forKey: seenKey) != facts.key else { return nil }
        return facts
    }

    static func markSeen(_ facts: Facts) {
        UserDefaults.standard.set(facts.key, forKey: seenKey)
    }

    static func bannerText(_ facts: Facts) -> String {
        String(format: L("engines.banner.text"), facts.safari, facts.engine, "\(facts.nextMacOS)")
    }

    /// Settings › About: what it is, what it means, what to do.
    static func aboutParagraphs(_ facts: Facts) -> [String] {
        [String(format: L("engines.about.what"), facts.safari, "\(facts.macOS)", facts.engine),
         String(format: L("engines.about.risk"), facts.engine, facts.safari),
         String(format: L("engines.about.todo"), "\(facts.nextMacOS)", "\(facts.macOS)")]
    }
}
