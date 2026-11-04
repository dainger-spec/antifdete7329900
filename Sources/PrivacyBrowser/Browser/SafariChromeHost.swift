import AppKit
import BrowserCore
import os
import WebKit

/// Safari's chrome as the window of a profile, in the profile's own process.
///
/// `SafariChrome` can host Safari's window in any process; this is the piece that gives that
/// window a profile's content. Safari's chrome builds its web views itself, and they are built
/// with the profile's data — its store, which carries its proxy, its preferences and its
/// scripts — through Safari's configuration factories, patched here, and through the initializer
/// every web view goes through (`ProfileNetworkGuard`, which also makes sure that a web view
/// either path misses loads nothing rather than loading as this Mac). The frame is Safari's,
/// everything behind it is the profile's.
///
/// Only in a per-profile child process (`ProfileSessionHost`): hosting Safari's chrome needs
/// `NSApp` to be Safari's own application object and the process to have a home of its own, and
/// neither is true of the process that shows the profile list. `PB_SAFARI_CHROME=0` turns it off
/// and the profile opens our own window instead, which is also what happens on a macOS where the
/// private frameworks no longer load.
@MainActor
enum SafariChromeHost {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChromeHost")
    private static var isPrepared = false
    static var isTurnedOff: Bool { ProcessInfo.processInfo.environment["PB_SAFARI_CHROME"] == "0" }
    /// This process hosts Safari's chrome: its windows are Safari's own.
    static var isHosting: Bool { isPrepared }

    /// Why a profile's window is the app's own rather than Safari's — which is a simplified mode:
    /// without Safari's frameworks hosting the window, the profile is plain WebKit to a site. The
    /// window says so, with this (`SimplifiedModeNotice`), never only the log.
    enum OwnWindowReason: Equatable {
        /// An iPhone or iPad profile: our window presents the device; Safari's is a Mac's.
        case deviceProfile
        /// A build with the App Sandbox: Safari's chrome cannot be hosted in it.
        case sandboxed
        /// `PB_SAFARI_CHROME=0`.
        case turnedOff
        /// Profiles run in the app's own process (`ProfileProcess.isEnabled` off): Safari's chrome
        /// is hosted only in a profile's own process.
        case notInProfileProcess
        /// Safari's private frameworks did not load on this macOS.
        case frameworksDidNotLoad
        /// This Safari lacks pieces without which its chrome is not hosted (by name).
        case missingPieces([String])
        /// The process could not make Safari's application object its `NSApp`.
        case notSafarisApplication
        /// Everything was prepared, and Safari's window factory gave no window.
        case windowDidNotOpen
    }

    /// What went wrong in this process, preparing Safari's chrome or opening its window: the
    /// reason a profile's window here is ours. Nil while nothing has.
    private(set) static var failure: OwnWindowReason?

    /// Why `configuration`'s window, opened in this process, is ours: a profile that presents a
    /// device, then what failed here, then what this process is (a sandboxed build, the chrome
    /// turned off, a profile not in a process of its own).
    static func reasonForOwnWindow(_ configuration: ProfileConfiguration) -> OwnWindowReason {
        if !canHost(configuration) { return .deviceProfile }
        if let failure { return failure }
        if AppEnvironment.isSandboxed { return .sandboxed }
        if isTurnedOff { return .turnedOff }
        return .notInProfileProcess
    }

    /// Loads Safari's frameworks and makes this process the kind of process its chrome expects,
    /// with Safari's own services set the way `configuration` needs them. Must run before anything
    /// touches `NSApplication.shared`, and after `ProfileNetworkGuard.engage` — the frameworks
    /// start their own clients as soon as they load. False when the chrome is not available, and
    /// then nothing about this process has been changed but the frameworks being loaded.
    @discardableResult
    static func prepareForChildProcess(configuration: ProfileConfiguration) -> Bool {
        guard !isPrepared else { return true }
        guard !isTurnedOff else {
            failure = .turnedOff
            return false
        }
        guard canHost(configuration) else {
            log.notice("An iPhone or iPad profile: our own window, which presents that device, rather than Safari's desktop chrome")
            return false
        }
        // Before the frameworks load: some of what they read, they read as they load.
        SafariChrome.configureSafarisOwnServices(for: configuration)
        guard SafariChrome.load() else {
            failure = .frameworksDidNotLoad
            return false
        }
        // Before any of Safari's code runs: its own folders are the profile's (SafariPaths).
        if let realHome = SafariPaths.realHome, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            SafariPaths.redirectGetters(from: realHome, to: home)
        }
        // And Safari's own defaults are the profile's domain, where the standard defaults are.
        SafariDefaults.keepSafarisOwnInProfileHome()
        let structural = SafariChrome.missingStructuralPieces()
        guard structural.isEmpty else {
            log.error("This Safari lacks what its chrome needs here (\(structural.joined(separator: ", "), privacy: .public)): our own window instead")
            failure = .missingPieces(structural)
            return false
        }
        guard SafariChrome.installApplication() else {
            log.error("NSApp is not Safari's application object: Safari's chrome is not hosted here")
            failure = .notSafarisApplication
            return false
        }
        // NSApp exists now, and nothing of Safari's has run yet: WebKit's default store is closed
        // before the menu brings up the rest of Safari's application.
        ProfileNetworkGuard.takeOverDefaultStore()
        SafariChrome.prepare()
        SafariChrome.installMainMenu()
        giveSafarisWebViewsTheProfilesData()
        isPrepared = true
        return true
    }

    /// Every web view Safari's chrome makes for page content is built from a configuration from
    /// one factory. Patched so that the configuration stays Safari's — its process pool, its
    /// content controller — while the data store in it is the profile's, its privacy preferences
    /// are the profile's, and the profile's scripts are added to it.
    ///
    /// This is the whole point, and it replaces trying to put a web view of ours into Safari's
    /// tab: the chrome navigates, opens tabs, keeps history and shows its start page exactly as
    /// Safari does, and the pages it loads do so with the profile's cookies, storage and proxy.
    private static func giveSafarisWebViewsTheProfilesData() {
        guard let cls = NSClassFromString("WebKitPreferencesManager") else {
            log.notice("No WebKitPreferencesManager: Safari's web views get the profile's data from their initializer only")
            return
        }
        // Opaque arguments and an unmanaged return on purpose. These three factories do not share
        // one signature — one of them takes a BOOL where the others take an object — and letting
        // Swift treat that BOOL as an object would have ARC retain the value 1 and take the
        // process down. Nothing here touches the arguments: they are passed through as the bits
        // they arrived as, and only the configuration that comes back is read.
        typealias Factory = @convention(c) (AnyObject, Selector, Int, OpaquePointer?, OpaquePointer?) -> Unmanaged<AnyObject>?
        var patched: [String] = []
        for selectorName in SafariChrome.configurationFactories {
            let selector = NSSelectorFromString(selectorName)
            guard let method = class_getClassMethod(cls, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let replacement: @convention(block) (AnyObject, Int, OpaquePointer?, OpaquePointer?) -> Unmanaged<AnyObject>? = { receiver, mode, second, third in
                let result = original(receiver, selector, mode, second, third)
                if let configuration = result?.takeUnretainedValue() as? WKWebViewConfiguration {
                    ProfileNetworkGuard.give(configuration, builtBy: "A configuration factory of Safari's")
                }
                return result
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            patched.append(String(selectorName.prefix(while: { $0 != ":" })))
        }
        if patched.isEmpty {
            // Which is what a macOS that renamed them looks like: the web views are then given the
            // profile's data by the initializer alone (ProfileNetworkGuard), whose report counts
            // them, and this line says to go and find the new names (docs/SAFARI_PROCESS.md).
            log.error("None of WebKitPreferencesManager's configuration factories is in this Safari: its own names have changed")
        } else {
            log.notice("Safari's configuration factories patched: \(patched.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Opens Safari's window for `session` and lets Safari build the profile's web view in its
    /// tab. False when the chrome is not hosted here, and the caller opens our own window as before.
    /// Safari's chrome is the Mac's: a profile that presents an iPhone or an iPad would show its
    /// device's navigator and screen next to a Mac's window and User-Agent, which no real device
    /// does. Those profiles run in our own window, which presents their device.
    static func canHost(_ configuration: ProfileConfiguration) -> Bool {
        configuration.deviceGeneration.platform == .macOS
    }

    static func open(session: BrowserSession, url: URL?) -> Bool {
        guard isPrepared else { return false }
        watchWindows()
        // Registered before the window exists: Safari builds the first web view while opening it,
        // and that web view must already get the profile's data store.
        ProfileNetworkGuard.register(session: session)
        let address = url ?? session.configuration.startURL
        guard let controller = SafariChrome.openWindow(address: address) else {
            log.error("Safari's chrome did not open a window for \(session.profileName, privacy: .private); using ours")
            failure = .windowDidNotOpen
            return false
        }
        // The first window opens where the user last left one of the profile's (`SavedWindowFrame`);
        // the first time, or once its window size was changed in the editor, at that size. One
        // Safari opens later (⌘N) is Safari's.
        if let window = controller.window {
            let size = session.configuration.windowSize
            savedFrameSize = size
            if let saved = SavedWindowFrame.read(for: size), let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                window.setFrame(SavedWindowFrame.fitted(saved, in: visible), display: false)
            } else if let size {
                WindowSizing.apply(size, to: window)
            }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        log.notice("A profile runs in Safari's chrome")
        return true
    }

    // MARK: Safari's windows as the profile's windows

    /// The last of Safari's browser windows has closed: the profile's process quits, which seals
    /// its data — as closing a profile's last window of ours does (`BrowserSession`). Without this
    /// the profile went on running with no window, until stopped from the Profiles window.
    static var onLastWindowClosed: (() -> Void)?
    private static var isWatchingWindows = false
    private static var isClosingEveryWindow = false

    private static func watchWindows() {
        guard !isWatchingWindows else { return }
        isWatchingWindows = true
        _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                // Where it was, for the profile's next first window — closed by the user, or by a
                // stop or a quit before the seal.
                if isBrowserWindow(closing) { SavedWindowFrame.save(closing.frame, for: savedFrameSize) }
                guard !isClosingEveryWindow, isBrowserWindow(closing) else { return }
                let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && isBrowserWindow($0) }
                if others.isEmpty {
                    log.notice("Safari's last window of this profile closed: the profile quits")
                    onLastWindowClosed?()
                }
            }
        }
    }

    /// The profile's window size the frames of this run are saved under.
    private static var savedFrameSize: WindowSize?

    /// A browser window of Safari's: its controller is Safari's `BrowserWindowController` (ours,
    /// of the same name, lives in this module and is named with it).
    static func isBrowserWindow(_ window: NSWindow) -> Bool {
        guard let controller = window.windowController else { return false }
        return NSStringFromClass(type(of: controller)) == "BrowserWindowController"
    }

    /// Closes every browser window of Safari's as its close button does (`performClose:`): Safari
    /// keeps such a window's pages for reopening it, and the last one closing quits the process
    /// (`onLastWindowClosed`). What `ProfileCommand.closeWindows` asks; the self-test's way of
    /// ending a profile as a person does.
    static func performCloseEveryWindow() {
        for window in NSApp.windows where isBrowserWindow(window) && window.isVisible {
            window.performClose(nil)
        }
    }

    /// Closes every browser window of Safari's, as a quit or a stop does before the profile's data
    /// is sealed: the windows go when the user quits, rather than staying up through the seal.
    static func closeEveryWindow() {
        isClosingEveryWindow = true
        defer { isClosingEveryWindow = false }
        for window in NSApp.windows where isBrowserWindow(window) && window.isVisible {
            window.close()
        }
    }
}

/// The profile's history is the profile's encrypted library (`ProfileLibrary`), whatever window
/// the pages were in: what a page of Safari's chrome visits goes there too, as a tab of ours
/// records it — committed loads and same-document navigations, with their titles. Safari keeps its
/// own history besides, in the profile's home (sealed with it), for its own menus; the library is
/// what the Library window shows, what syncs and what an export carries.
@MainActor
enum HostedPageHistory {
    private static let followed = NSMapTable<WKWebView, Follower>.weakToStrongObjects()

    private final class Follower {
        var observations: [NSKeyValueObservation] = []
        var lastRecorded: URL?
    }

    /// Records `webView`'s visits from now on. Our own tabs record theirs themselves, and are left
    /// alone; so are pages that are not web addresses (Safari's start page, a file).
    static func follow(_ webView: WKWebView) {
        guard followed.object(forKey: webView) == nil else { return }
        let follower = Follower()
        // A visit is the committed page: its address is then the back-forward list's current item.
        // The address changes when a load starts — the list still holds the page before — and again
        // only when it changes after (a redirect, a same-document navigation): a load without either
        // was never recorded (the account switch check, run 677: none of 8 visits in the history).
        // So whatever follows a commit — the address, the title, the end of the load — tries again.
        let attempt: @MainActor (WKWebView) -> Void = { webView in
            guard let url = webView.url, isRecorded(webView, url),
                  webView.backForwardList.currentItem?.url == url, url != follower.lastRecorded else { return }
            follower.lastRecorded = url
            ProfileNetworkGuard.session?.library.recordVisit(url: url, title: webView.title)
        }
        follower.observations = [
            webView.observe(\.url, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { attempt(webView) }
            },
            webView.observe(\.isLoading, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { attempt(webView) }
            },
            webView.observe(\.title, options: [.new]) { webView, _ in
                MainActor.assumeIsolated {
                    attempt(webView)
                    guard let url = webView.url, isRecorded(webView, url) else { return }
                    ProfileNetworkGuard.session?.library.updateTitle(url: url, title: webView.title)
                }
            },
        ]
        followed.setObject(follower, forKey: webView)
    }

    private static func isRecorded(_ webView: WKWebView, _ url: URL) -> Bool {
        !(webView.navigationDelegate is BrowserTab) && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// Where a profile's first window opens: where the user last left a window of it, as Safari does —
/// kept in the profile's own defaults (in its home, sealed with it, beside Safari's own sidebar and
/// toolbar state). The profile's window size is used the first time, and again once it has been
/// changed in the editor: a frame is kept with the size it was saved under. Up to 1 November the
/// window size was put on every launch, over what the user had made of the window (the owner's
/// Mac, 31 October: moved and resized, it came back at the profile's size, centred).
enum SavedWindowFrame {
    static let frameKey = "PBProfileWindowFrame"
    static let sizeKey = "PBProfileWindowFrameSize"

    /// The window size a frame is kept with, as text: "none" for a profile without one.
    nonisolated static func marker(_ size: WindowSize?) -> String {
        guard let size else { return "none" }
        return "\(size.frame.width)x\(size.frame.height)"
    }

    /// The frame kept for `size`, or nil — none kept, or kept under another window size.
    static func read(for size: WindowSize?, in defaults: UserDefaults = .standard) -> NSRect? {
        guard defaults.string(forKey: sizeKey) == marker(size), let text = defaults.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(text)
        return frame.width >= 200 && frame.height >= 150 ? frame : nil
    }

    static func save(_ frame: NSRect, for size: WindowSize?, in defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(frame), forKey: frameKey)
        defaults.set(marker(size), forKey: sizeKey)
    }

    /// `frame` on the screen whose visible area is `visible`: never larger than it (a page could
    /// measure that), moved in where it would hang outside.
    nonisolated static func fitted(_ frame: NSRect, in visible: NSRect) -> NSRect {
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
