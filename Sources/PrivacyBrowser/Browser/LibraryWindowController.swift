import AppKit
import SwiftUI

/// Hosts `LibraryView` (bookmarks + history) for one running profile. Closed automatically
/// when the profile stops.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private let navigation: LibraryNavigation
    private let onClose: () -> Void

    init(session: BrowserSession, open: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        let navigation = LibraryNavigation()
        self.navigation = navigation
        self.onClose = onClose
        let hosting = NSHostingController(rootView: LibraryView(library: session.library, navigation: navigation, open: open))
        let window = NSWindow(contentViewController: hosting)
        window.title = "[\(session.profileName)] Library"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 540))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(_ section: LibraryView.Section) {
        navigation.section = section
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
