import AppKit
import BrowserCore
import ObjCExceptions
import os
import SwiftUI

/// Whose window this is, said in Safari's own window: the profile's name and colour.
///
/// With several profiles open, each in Safari's window, nothing in a window said which profile it
/// was — only the Dock icon's letters did (`DockIcon`) — and acting in the wrong profile is the
/// mistake a person with many accounts must not make (the owner, 15 November: yes to the name and
/// the colour in the window). Two things, neither of which a page can measure:
///
///   * a chip at the trailing end of Safari's toolbar (`SafariProfileMarkerView`): the profile's
///     glyph, its name and where it exits, on the profile's own colour — what a window of ours
///     shows in its toolbar (`ProfileChipView`). It is a titlebar accessory, which AppKit lays
///     beside the toolbar's items in the room the toolbar has: the toolbar's height, the window's
///     frame and the page's area stay as they are. That is checked, not assumed: the window's
///     frame, its content's area and the page's own frame are read before the chip goes in and
///     after, and a chip that changed any of them is taken out again and stays out for the run
///     (`droppedForGeometry`); the self-test compares what a page measures with and without it.
///   * the window's title, which Safari sets to the page's: it begins with the profile's name
///     (`ProfileWindowTitle`, as a window of ours is titled) wherever the system lists windows by
///     title — the Window menu, the Dock's menu, Mission Control. Safari's toolbar shows no title.
///
/// Nothing of it reaches a page: no script, no style, no change of the web view. `PB_PROFILE_MARKER=0`
/// in the app's environment leaves Safari's window as Safari draws it.
@MainActor
enum SafariProfileMarker {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariProfileMarker")
    static let environmentVariable = "PB_PROFILE_MARKER"
    private static let identifier = NSUserInterfaceItemIdentifier("PBProfileMarker")

    /// Off for this process by its environment.
    static var isTurnedOff: Bool { ProcessInfo.processInfo.environment[environmentVariable] == "0" }

    private static var model: BrowserChromeModel?
    private static weak var session: BrowserSession?
    /// The windows that say whose they are, held weakly.
    private static let marked = NSHashTable<NSWindow>.weakObjects()
    private static var isWatching = false
    /// A chip changed what a page can measure on this Mac and was taken out: none is put in again
    /// in this run. The title stays.
    private(set) static var droppedForGeometry = false
    /// The self-test's comparison: the marker taken out of every window, and put back.
    private(set) static var isSuspended = false

    /// Starts saying whose windows these are: Safari's browser windows of this process, the ones
    /// opened from here and the ones Safari opens itself (a tab moved to a new window), as each
    /// comes to the front.
    static func install(session: BrowserSession) {
        guard !isTurnedOff else { return }
        if Self.session !== session {
            Self.session = session
            model = BrowserChromeModel(profileName: session.profileName, profileID: session.profileID,
                                       exit: exit(of: session), avatar: session.configuration.avatar)
        }
        keepTitlesMarked()
        guard !isWatching else { return }
        isWatching = true
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if SafariChromeHost.isBrowserWindow(window) { mark(window) }
                }
            }
        }
    }

    private static func exit(of session: BrowserSession) -> ProfileExit {
        guard let proxy = session.configuration.proxy else { return .direct }
        return .proxy(endpoint: "\(proxy.host):\(proxy.port)", countryCode: session.exitLocation?.countryCode)
    }

    /// Where the profile exits became known after its window was up: the chip shows the flag.
    static func exitChanged() {
        guard let session, let model else { return }
        model.exit = exit(of: session)
        // The chip is wider or narrower by a flag: its place in the toolbar follows.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for window in marked.allObjects { fit(accessory(of: window)) }
            }
        }
    }

    /// Whether `window` says whose it is: by its title, and by the chip when it has one.
    static func state(of window: NSWindow) -> (title: Bool, chip: Bool) {
        let name = model?.profileName ?? ""
        let titled = !name.isEmpty && ProfileWindowTitle.marked(window.title, profile: name) == window.title
        return (titled, accessory(of: window) != nil)
    }

    // MARK: A window

    /// Makes `window`, one of Safari's browser windows, say whose it is. Once per window.
    static func mark(_ window: NSWindow) {
        guard !isTurnedOff, !isSuspended, let model, !marked.contains(window) else { return }
        marked.add(window)
        // Through the title's setter, which puts the name before it (`keepTitlesMarked`).
        window.title = window.title
        guard !droppedForGeometry else { return }
        let before = geometry(of: window)
        let host = NSHostingView(rootView: SafariProfileMarkerView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: SafariProfileMarkerView.height))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
        ])
        let controller = NSTitlebarAccessoryViewController()
        controller.identifier = identifier
        // Beside the toolbar's items, at its trailing end: never under the toolbar, which would
        // make the window's chrome taller — a height every page measures.
        controller.layoutAttribute = .trailing
        controller.view = container
        fit(controller)
        if let exception = PBCatchException({ window.addTitlebarAccessoryViewController(controller) }) {
            log.error("Safari's window took no chip: \(exception.name.rawValue, privacy: .public)")
            return
        }
        // What a page can measure is as it was, or the chip goes.
        if geometry(of: window) != before {
            remove(controller, from: window)
            droppedForGeometry = true
            log.error("The profile's chip changed the size of Safari's window or of its page: taken out, the title alone says whose window it is")
        }
    }

    /// The chip's room: as wide as the chip is now.
    private static func fit(_ controller: NSTitlebarAccessoryViewController?) {
        guard let controller, let host = controller.view.subviews.first else { return }
        let width = min(host.fittingSize.width, SafariProfileMarkerView.maximumWidth) + 12
        controller.view.setFrameSize(NSSize(width: width, height: max(controller.view.frame.height, SafariProfileMarkerView.height)))
    }

    private static func accessory(of window: NSWindow) -> NSTitlebarAccessoryViewController? {
        window.titlebarAccessoryViewControllers.first { $0.identifier == identifier }
    }

    private static func remove(_ controller: NSTitlebarAccessoryViewController, from window: NSWindow) {
        guard let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === controller }) else { return }
        window.removeTitlebarAccessoryViewController(at: index)
    }

    /// What a page can measure of `window`: its frame (outerWidth, outerHeight, screenX, screenY),
    /// the area its content has under the toolbar, and the frame of the page in front
    /// (innerWidth, innerHeight), in the window's coordinates.
    private static func geometry(of window: NSWindow) -> [NSRect] {
        window.layoutIfNeeded()
        var rects = [window.frame, window.contentLayoutRect, window.contentView?.frame ?? .zero]
        if let page = SafariChromeHost.frontPage(in: window) { rects.append(page.convert(page.bounds, to: nil)) }
        return rects
    }

    // MARK: The title

    private static var titlesKept = false

    /// Safari sets its window's title to the page's, at every page and every tab: whatever title a
    /// marked window is given begins with the profile's name. Every other window's title is as
    /// it is given.
    private static func keepTitlesMarked() {
        guard !titlesKept else { return }
        titlesKept = true
        let selector = NSSelectorFromString("setTitle:")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, NSString?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let replacement: @convention(block) (AnyObject, NSString?) -> Void = { receiver, title in
            guard let window = receiver as? NSWindow, !isSuspended, marked.contains(window), let name = model?.profileName else {
                original(receiver, selector, title)
                return
            }
            original(receiver, selector, ProfileWindowTitle.marked((title as String?) ?? "", profile: name) as NSString)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    // MARK: The self-test's comparison

    /// Takes the marker out of every window — the chip, and the name before the title — or puts it
    /// back: what a page measures is compared between the two (`WindowProbe`). Sent by the
    /// self-test only, never by the app.
    static func suspend(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        if suspended {
            isSuspended = true
            let name = model?.profileName ?? ""
            for window in marked.allObjects {
                if let controller = accessory(of: window) { remove(controller, from: window) }
                window.title = ProfileWindowTitle.unmarked(window.title, profile: name)
            }
            marked.removeAllObjects()
        } else {
            isSuspended = false
            for window in NSApp.windows where SafariChromeHost.isBrowserWindow(window) && window.isVisible { mark(window) }
        }
    }
}
