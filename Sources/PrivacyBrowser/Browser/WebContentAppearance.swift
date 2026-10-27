import AppKit

/// Web content follows this Mac's light/dark setting, as it does in Safari, while the app's own
/// chrome is always dark: a page gets the `prefers-color-scheme` (and form controls, scroll bars)
/// Safari would give it, not the app's theme.
///
/// The app never sets `NSApp.appearance`, so `NSApp.effectiveAppearance` is the system's. A web
/// view's container gets that appearance explicitly (it would otherwise inherit its dark
/// window's), and again whenever the system setting changes.
@MainActor
final class WebContentAppearance {
    static let shared = WebContentAppearance()

    private var observation: NSKeyValueObservation?
    private let views = NSHashTable<NSView>.weakObjects()

    /// The system's appearance.
    var current: NSAppearance { NSApp.effectiveAppearance }

    /// Gives `view` — the container of a window's web views — the system's appearance, now and
    /// after every change of the setting.
    func follow(_ view: NSView) {
        view.appearance = current
        views.add(view)
        guard observation == nil else { return }
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        let appearance = current
        for view in views.allObjects where view.appearance !== appearance {
            view.appearance = appearance
        }
    }
}
