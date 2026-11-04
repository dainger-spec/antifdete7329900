import AppKit
import BrowserCore

/// A profile's window size (`WindowSize`) on a window of its: the frame asked for, or as large as
/// the screen's visible area allows — never larger than the screen, which a page could measure.
@MainActor
enum WindowSizing {
    /// This Mac's main screen less its menu bar and Dock: what a window can be at most.
    static var visibleScreen: CGSize? { NSScreen.main?.visibleFrame.size }

    /// The frame `size` gets within `visible`.
    nonisolated static func fitted(_ size: WindowSize, in visible: CGSize) -> CGSize {
        let frame = size.frame
        return CGSize(width: min(CGFloat(frame.width), visible.width), height: min(CGFloat(frame.height), visible.height))
    }

    /// Gives `window` that frame, centred in its screen's visible area.
    static func apply(_ size: WindowSize, to window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let target = fitted(size, in: visible.size)
        let origin = NSPoint(x: (visible.midX - target.width / 2).rounded(), y: (visible.midY - target.height / 2).rounded())
        window.setFrame(NSRect(origin: origin, size: target), display: false)
    }
}
