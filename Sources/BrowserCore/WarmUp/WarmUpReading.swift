import Foundation

/// What the robot measures of a page before it decides how long to stay and how far to scroll.
public struct WarmUpPageMeasure: Codable, Equatable, Sendable {
    /// Characters of readable text (the page's main part where it has one).
    public var textLength: Double
    /// The document's height and the viewport's, in CSS pixels.
    public var pageHeight: Double
    public var viewportHeight: Double

    public init(textLength: Double, pageHeight: Double, viewportHeight: Double) {
        self.textLength = textLength
        self.pageHeight = pageHeight
        self.viewportHeight = viewportHeight
    }

    /// Screens the page is tall.
    public var screens: Double { viewportHeight > 0 ? max(1, pageHeight / viewportHeight) : 1 }
}

/// Reading a page as a person does: for as long as it is, scrolling in bursts with pauses.
public enum WarmUpReading {
    /// Characters a person takes in a second while skimming a web page (about 240 words a minute of
    /// which a page is read in part).
    static let charactersPerSecond = 28.0
    /// The share of a page's text a visitor reads: nobody reads a news front page to its end.
    static let readShare = 0.35

    /// Seconds on a page: what its text takes at a skimming pace, a little for each screen of its
    /// height (pictures are looked at too), spread by a person's own pace (×0.6…1.5), and kept
    /// within the plan's two times. A page with nothing on it is left at the shortest stay.
    public static func dwell(_ measure: WarmUpPageMeasure, range: ClosedRange<TimeInterval>,
                             using generator: inout some RandomNumberGenerator) -> TimeInterval {
        let reading = max(0, measure.textLength) * readShare / charactersPerSecond
        let looking = min(measure.screens, 12) * 2.5
        let pace = Double.random(in: 0.6...1.5, using: &generator)
        return min(range.upperBound, max(range.lowerBound, (reading + looking) * pace))
    }

    /// How far down a visitor gets (0…1 of what can be scrolled): most of a short page, a part of
    /// a long one.
    public static func depth(_ measure: WarmUpPageMeasure, using generator: inout some RandomNumberGenerator) -> Double {
        let screens = measure.screens
        guard screens > 1.05 else { return 0 }
        let wanted = screens <= 3 ? Double.random(in: 0.7...1, using: &generator) : Double.random(in: 0.25...0.7, using: &generator)
        return min(1, wanted)
    }

    /// Scroll gestures over a stay of `dwell` seconds on a page of this measure: bursts of two or
    /// three flicks with a reading pause between the bursts, down to `depth` of the page and no
    /// further, now and then a little back up; nothing in the first second and a half, nor the last.
    /// A page that fits its window gets none.
    public static func gestures(_ measure: WarmUpPageMeasure, over dwell: TimeInterval,
                                using generator: inout some RandomNumberGenerator) -> [WarmUpTiming.Gesture] {
        let room = max(0, measure.pageHeight - measure.viewportHeight)
        let usable = dwell - 2.5
        guard room > 40, usable > 1 else { return [] }
        var remaining = room * depth(measure, using: &generator)
        var gestures: [WarmUpTiming.Gesture] = []
        var at = 1.5 + Double.random(in: 0...min(2, usable / 3), using: &generator)
        while remaining > 30, at < dwell - 1, gestures.count < 40 {
            let flicks = Int.random(in: 2...3, using: &generator)
            for _ in 0..<flicks where remaining > 30 && at < dwell - 1 {
                let up = !gestures.isEmpty && Double.random(in: 0..<1, using: &generator) < 0.1
                let distance = up ? -Double.random(in: 80...220, using: &generator)
                    : min(remaining, Double.random(in: 260...min(760, max(261, measure.viewportHeight * 0.9)), using: &generator))
                let steps = Int.random(in: 8...14, using: &generator)
                let total = Double(steps * (steps + 1) / 2)
                let deltas = (0..<steps).map { (distance * Double(steps - $0) / total).rounded() }
                gestures.append(WarmUpTiming.Gesture(at: at, deltas: deltas, interval: Double.random(in: 0.016...0.035, using: &generator)))
                remaining -= distance
                at += Double.random(in: 0.7...1.6, using: &generator)
            }
            // The reading pause: longer where there is time left for it.
            at += Double.random(in: 2.5...max(3, min(9, usable / 4)), using: &generator)
        }
        return gestures
    }

    /// The pause before the next site: a few seconds mostly, now and then a longer one — a person
    /// looks away, answers a message.
    public static func pause(using generator: inout some RandomNumberGenerator) -> TimeInterval {
        if Double.random(in: 0..<1, using: &generator) < 0.12 { return Double.random(in: 12...40, using: &generator) }
        return Double.random(in: 1.5...6, using: &generator)
    }
}

/// When a run's pages stop loading one after the other, the proxy is gone: going on would only
/// spend the plan's time on timeouts.
public struct WarmUpHealth: Equatable, Sendable {
    /// This many pages in a row that do not load end the run.
    public static let failuresInARow = 3

    public private(set) var streak = 0
    public private(set) var loaded = 0

    public init() {}

    /// Records a page; true when the run should end as "the proxy does not answer".
    public mutating func record(loaded isLoaded: Bool) -> Bool {
        if isLoaded {
            streak = 0
            loaded += 1
        } else {
            streak += 1
        }
        return streak >= Self.failuresInARow
    }
}

/// How many profiles a queue warms at once when the person leaves it to the app.
public enum WarmUpConcurrency {
    public static let range: ClosedRange<Int> = 1...8

    /// By this Mac's memory and processors: a profile being warmed takes about a third of a
    /// gigabyte with its pages (docs/SCALE.md: 130–180 MB a profile with one page, measured), and
    /// its pages a share of a processor. Half the processors, a profile for every three gigabytes
    /// beyond the first four, never fewer than one nor more than eight.
    public static func automatic(memoryBytes: UInt64, processors: Int) -> Int {
        let gigabytes = Double(memoryBytes) / 1_073_741_824
        let byMemory = Int(((gigabytes - 4) / 3).rounded(.down))
        let byProcessors = processors / 2
        return min(range.upperBound, max(range.lowerBound, min(byMemory, byProcessors)))
    }
}
