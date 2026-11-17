import AppKit
import BrowserCore
import ObjCExceptions
import os
import WebKit

/// Return in Safari's address bar of a profile: what the person asked for happens, whatever
/// Safari's code throws on the way.
///
/// A customer on macOS 27.2.1 typed "google" and pressed Return: the field showed the committed
/// search, the page under it stayed empty, and the window said "This Safari feature is not
/// available in a profile". Safari's commit — the field's action, the search address built with
/// the profile's engine, the top hit, the typed address recorded in history, the completion chosen
/// — threw, and nothing loaded.
///
/// So the Return key's event in an address bar is watched (`-[NSWindow sendEvent:]`, where every
/// key reaches a window): what the field holds then is the person's intent. The event itself is
/// handled inside an Objective-C @try; the commit's own methods are too (`SafariTypingGuard`'s
/// commit methods), and the run loop's catch is told first. If Safari's code threw anywhere on the
/// way and no page started loading in the window's front tab, the profile's process loads it
/// itself: the typed address, or a search with the profile's engine (`AddressBarIntent`), in the
/// front tab — through the tab as the address bar does, then in its web view. Nothing fails
/// silently: every throw is written down with the method it came out of, every load done here as
/// well, and should even that load not happen, the window says so.
@MainActor
enum AddressBarCommit {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "SafariChrome")
    private static var isInstalled = false

    /// Return pressed in an address bar, while it is being done.
    final class Intent {
        let typed: String
        let at = Date()
        weak var window: NSWindow?
        weak var page: WKWebView?
        let pageURL: URL?
        /// A page started loading in the window since (its address or its loading changed, or
        /// another page came in front).
        var navigationStarted = false
        /// Where Safari's code threw since Return: "-[Class selector] Name", "the run loop", ...
        var thrownIn: [String] = []
        var rescued: URL?
        var settled = false
        var observations: [NSKeyValueObservation] = []

        init(typed: String, window: NSWindow, page: WKWebView?) {
            self.typed = typed
            self.window = window
            self.page = page
            self.pageURL = page?.url
        }
    }

    /// The Return being done now, for `freshness` seconds.
    private(set) static var current: Intent?
    static let freshness: TimeInterval = 4

    // What the address bar check reads.
    private(set) static var returns = 0
    /// "where Safari threw → what was loaded here" of every load done here.
    private(set) static var rescues: [String] = []
    /// Where Safari's code threw after a Return, every time.
    private(set) static var thrownAfterReturn: [String] = []
    /// The frames that started the last page a Return loaded (Safari's commit path, by name).
    private(set) static var lastNavigationFrames: [String] = []

    /// The Return key: Return and the keypad's Enter.
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        watchReturn()
        SafariTypingGuard.onCaught = { key, name in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AddressBarCommit.noteThrow("-[\(key)] \(name)") }
            }
        }
    }

    /// `-[NSWindow sendEvent:]`: a Return pressed in an address bar starts an intent, and the event
    /// is handled inside an Objective-C @try. Every other event goes through untouched.
    private static func watchReturn() {
        typealias SendEvent = @convention(c) (NSWindow, Selector, NSEvent) -> Void
        let selector = #selector(NSWindow.sendEvent(_:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
            log.error("No -[NSWindow sendEvent:]: Return in the address bar is not watched")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: SendEvent.self)
        let replacement: @convention(block) (NSWindow, NSEvent) -> Void = { window, event in
            guard event.type == .keyDown, AddressBarCommit.returnKeyCodes.contains(event.keyCode), Thread.isMainThread,
                  MainActor.assumeIsolated({ AddressBarCommit.begin(in: window) }) else {
                original(window, selector, event)
                return
            }
            if let exception = PBCatchException({ original(window, selector, event) }) {
                MainActor.assumeIsolated {
                    AddressBarCommit.noteThrow("the Return key's event (-[NSWindow sendEvent:]) \(exception.name.rawValue)")
                }
            }
            MainActor.assumeIsolated { AddressBarCommit.settleLater() }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The field editor of Safari's address bar, when it is `window`'s first responder.
    static func addressBarEditor(in window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField,
              String(describing: type(of: field)).contains("UnifiedField") else { return nil }
        return editor
    }

    /// A Return in `window`'s address bar: the intent, from what the field holds now. False when the
    /// key is not the address bar's.
    private static func begin(in window: NSWindow) -> Bool {
        guard SafariChromeHost.isHosting, let editor = addressBarEditor(in: window) else { return false }
        let intent = Intent(typed: editor.string, window: window, page: SafariChromeHost.frontPage(in: window))
        if let page = intent.page {
            let started: @MainActor (WKWebView) -> Void = { _ in
                guard !intent.navigationStarted else { return }
                intent.navigationStarted = true
                // The commit's own frames, by name: the path from Return to a page loading.
                AddressBarCommit.lastNavigationFrames = Array(Thread.callStackSymbols.dropFirst(2).prefix(36).map { line in
                    line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().filter { !$0.hasPrefix("0x") }.joined(separator: " ")
                })
            }
            intent.observations = [
                page.observe(\.url, options: [.new]) { page, _ in MainActor.assumeIsolated { started(page) } },
                page.observe(\.isLoading, options: [.new]) { page, _ in MainActor.assumeIsolated { started(page) } },
            ]
        }
        current = intent
        returns += 1
        return true
    }

    /// Safari's code threw somewhere: written down for the Return being done, if there is one.
    static func noteThrow(_ place: String) {
        guard let intent = current, Date().timeIntervalSince(intent.at) < freshness else { return }
        intent.thrownIn.append(place)
        thrownAfterReturn.append(place)
        log.error("Safari's code threw after Return in the address bar: \(place, privacy: .public)")
        if intent.settled, !intent.navigationStarted, intent.rescued == nil {
            // Thrown after the Return was looked at (a block it scheduled): looked at again.
            intent.settled = false
            settleLater()
        }
    }

    /// The run loop caught an exception: true when it is the Return being done that it belongs to,
    /// which then does what was asked itself — the window says nothing of it.
    static func takesCaughtException(_ exception: NSException) -> Bool {
        guard let intent = current, Date().timeIntervalSince(intent.at) < freshness else { return false }
        noteThrow("the run loop \(exception.name.rawValue)")
        return true
    }

    private static func settleLater() {
        guard let intent = current else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated { AddressBarCommit.settle(intent, last: false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated { AddressBarCommit.settle(intent, last: true) }
        }
    }

    /// Whether a page started loading in the intent's window since Return.
    private static func started(_ intent: Intent) -> Bool {
        if intent.navigationStarted { return true }
        guard let window = intent.window else { return false }
        let front = SafariChromeHost.frontPage(in: window)
        if front !== intent.page { return front != nil }
        return front?.url != intent.pageURL
    }

    private static func settle(_ intent: Intent, last: Bool) {
        guard !intent.settled, intent.rescued == nil else { return }
        if started(intent) {
            intent.settled = true
            intent.observations = []
            if !intent.thrownIn.isEmpty {
                log.notice("After Return Safari's code threw (\(intent.thrownIn.joined(separator: "; "), privacy: .public)), and a page started loading all the same")
            }
            return
        }
        // Nothing thrown: what Safari did (or did not) is Safari's own — an empty field, a tab switched to.
        guard !intent.thrownIn.isEmpty else {
            if last { intent.settled = true }
            return
        }
        intent.settled = true
        rescue(intent)
    }

    /// Loads what the field held at Return in the front tab of its window.
    private static func rescue(_ intent: Intent) {
        let place = intent.thrownIn.first ?? "?"
        guard let url = AddressBarIntent.destination(typed: intent.typed, engine: SafariChrome.profileSearchEngine) else {
            log.error("Safari's code threw after Return in an empty address bar (\(place, privacy: .public)): nothing to load")
            return
        }
        intent.rescued = url
        let shown = url.host ?? url.scheme ?? "?"
        log.error("Safari's code threw after Return in the address bar (\(place, privacy: .public)): the profile's process loads what was asked itself (\(shown, privacy: .private))")
        rescues.append("\(place) → \(url.absoluteString)")
        guard let window = intent.window else {
            failedToLoad(place)
            return
        }
        let tab = SafariTabs.tabs().first { $0.window === window && $0.isSelected }?.item
        if let tab, SafariChrome.load(url, in: tab) {
            // Safari's own tab took it: if it does not start loading, its web view is told directly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated {
                    guard !started(intent) else { return }
                    loadInPage(url, of: window, place: place)
                }
            }
            return
        }
        loadInPage(url, of: window, place: place)
    }

    private static func loadInPage(_ url: URL, of window: NSWindow, place: String) {
        guard let page = SafariChromeHost.frontPage(in: window) else {
            failedToLoad(place)
            return
        }
        page.load(URLRequest(url: url))
        log.notice("The address bar's request was loaded in the front tab's web view")
    }

    /// Nothing could load what was asked: the window says so, never silence.
    private static func failedToLoad(_ place: String) {
        log.error("What the address bar asked for could not be loaded after Safari's code threw (\(place, privacy: .public))")
        SafariChrome.presentNotice(L("safari.unavailable.title"), L("safari.unavailable.action"))
    }
}
