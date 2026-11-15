import Foundation

/// Where a machine's window was when the person last moved or resized it, kept beside the
/// machine's disk (`VMLibrary.MachineFiles.window`) — this machine's alone, and not in the app's
/// preferences, which every machine would share. The next start opens the window there instead
/// of in the middle of the main screen: on the display the person put it on, at the size they
/// gave it, and not exactly over the other machine's window.
public struct VMWindowPlacement: Codable, Equatable, Sendable {
    /// A rectangle in the screens' coordinates, as AppKit has them: the origin at the bottom
    /// left, `y` growing upwards.
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var isUsable: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
        }

        /// How much of `other` this rectangle covers: the width and height of what they share.
        func shared(with other: Rect) -> (width: Double, height: Double) {
            let width = min(x + self.width, other.x + other.width) - max(x, other.x)
            let height = min(y + self.height, other.y + other.height) - max(y, other.y)
            return (max(0, width), max(0, height))
        }
    }

    /// The window's frame.
    public var frame: Rect
    /// The machine's screen in pixels when the frame was kept. The window has that screen's
    /// proportions: a machine given another screen since opens as a new one does.
    public var pixelsWide: Int
    public var pixelsHigh: Int

    public init(frame: Rect, pixelsWide: Int, pixelsHigh: Int) {
        self.frame = frame
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
    }

    /// The smallest window worth going back to, and how much of its title bar — the strip of
    /// `titleBarHeight` at its top — must be on a screen for the person to take hold of it.
    public static let minimumSide: Double = 200
    public static let titleBarHeight: Double = 28
    public static let reachableWidth: Double = 120
    public static let reachableHeight: Double = 20

    /// The frame to open the window at on a Mac whose screens' usable areas are `screens`, for a
    /// machine whose screen is `pixelsWide` × `pixelsHigh` now — or nil, and the window opens as
    /// a new one does. Nil when the machine's screen has changed; when the frame is no window's
    /// (not finite, smaller than `minimumSide`); when it is larger than the screen most of it
    /// is on (kept on a larger display that is gone); or when too little of its title bar is on
    /// that screen to take hold of (the display it was on is not connected).
    public func restored(onScreens screens: [Rect], pixelsWide: Int, pixelsHigh: Int) -> Rect? {
        guard pixelsWide == self.pixelsWide, pixelsHigh == self.pixelsHigh, frame.isUsable,
              frame.width >= Self.minimumSide, frame.height >= Self.minimumSide else { return nil }
        // The screen most of the window is on.
        var best: (screen: Rect, area: Double)?
        for screen in screens where screen.isUsable {
            let shared = frame.shared(with: screen)
            let area = shared.width * shared.height
            if area > (best?.area ?? 0) { best = (screen, area) }
        }
        guard let screen = best?.screen, frame.width <= screen.width + 1, frame.height <= screen.height + 1 else { return nil }
        let titleBar = Rect(x: frame.x, y: frame.y + frame.height - Self.titleBarHeight, width: frame.width, height: Self.titleBarHeight)
        let reachable = titleBar.shared(with: screen)
        guard reachable.width >= Self.reachableWidth, reachable.height >= Self.reachableHeight else { return nil }
        return frame
    }

    /// The note as it was kept; nil when there is none, or it is not one (a note is a few
    /// hundred bytes).
    public static func read(from url: URL) -> VMWindowPlacement? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= 4096, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder.decode(VMWindowPlacement.self, from: data)
    }

    public func write(to url: URL) throws {
        try SecureFile.write(try JSONCoding.encoder.encode(self), to: url)
    }
}
