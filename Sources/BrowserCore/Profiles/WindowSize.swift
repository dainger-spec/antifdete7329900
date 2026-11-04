import Foundation

/// How large a profile's browser windows open (`ProfileConfiguration.windowSize`): a real window
/// of that size, which is what a page measures (`outerWidth`, `innerWidth`, its viewport) — never
/// a size only told to the page.
///
/// The screen a page is told about stays this Mac's own. WebKit on macOS takes it from the
/// window's real `NSScreen` and has no way to declare another (its screen-size override is
/// iOS-only), and a script that claimed one would be given away by CSS (`device-width`, read by
/// the engine from the same real screen) and by full screen. So a size is a window, never a
/// screen; one larger than this Mac's screen cannot be had, and the editor says so.
public enum WindowSize: Codable, Equatable, Sendable {
    /// As large as a zoomed Safari window on that Mac's screen: its width, and its height below
    /// the menu bar.
    case mac(screen: MacScreen)
    /// A window of this size, in points.
    case custom(width: Int, height: Int)

    public static let minimumWidth = 800
    public static let minimumHeight = 600
    public static let maximumWidth = 7680
    public static let maximumHeight = 4320

    /// The window's frame, in points.
    public var frame: (width: Int, height: Int) {
        switch self {
        case .mac(let screen): return (screen.points.width, screen.points.height - MacScreen.menuBarHeight)
        case let .custom(width, height): return (width, height)
        }
    }

    /// Within the limits a window can have.
    public var isValid: Bool {
        let frame = self.frame
        return (Self.minimumWidth...Self.maximumWidth).contains(frame.width)
            && (Self.minimumHeight...Self.maximumHeight).contains(frame.height)
    }

    /// A size for a new profile (Settings → New Profiles), so that profiles do not all open with
    /// the same window: each way between two thirds and nine tenths of `visible` — this Mac's
    /// screen less its menu bar and Dock — and never under the minimum, so it always fits.
    public static func randomSafe<G: RandomNumberGenerator>(fitting visible: (width: Int, height: Int),
                                                         using generator: inout G) -> WindowSize {
        func pick(_ available: Int, minimum: Int) -> Int {
            let low = max(minimum, available * 2 / 3)
            let high = max(low, available * 9 / 10)
            return Int.random(in: low...high, using: &generator)
        }
        return .custom(width: pick(visible.width, minimum: minimumWidth), height: pick(visible.height, minimum: minimumHeight))
    }
}

/// The screens of the Macs a window size can be taken from, at their default resolution.
public enum MacScreen: String, Codable, CaseIterable, Sendable {
    case air13 = "macbook-air-13"
    case pro14 = "macbook-pro-14"
    case air15 = "macbook-air-15"
    case pro16 = "macbook-pro-16"

    /// The menu bar of a MacBook with a notch, which a zoomed window stays below.
    public static let menuBarHeight = 37

    /// The screen in points (each at 2× pixels).
    public var points: (width: Int, height: Int) {
        switch self {
        case .air13: return (1470, 956)
        case .pro14: return (1512, 982)
        case .air15: return (1710, 1107)
        case .pro16: return (1728, 1117)
        }
    }

    /// The diagonal in inches, as Apple gives it.
    public var diagonal: String {
        switch self {
        case .air13: return "13.6"
        case .pro14: return "14.2"
        case .air15: return "15.3"
        case .pro16: return "16.2"
        }
    }

    /// "MacBook Air", "MacBook Pro".
    public var family: String {
        switch self {
        case .air13, .air15: return "MacBook Air"
        case .pro14, .pro16: return "MacBook Pro"
        }
    }
}
