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

    /// Loads Safari's frameworks and makes this process the kind of process its chrome expects,
    /// with Safari's own services set the way `configuration` needs them. Must run before anything
    /// touches `NSApplication.shared`, and after `ProfileNetworkGuard.engage` — the frameworks
    /// start their own clients as soon as they load. False when the chrome is not available, and
    /// then nothing about this process has been changed but the frameworks being loaded.
    @discardableResult
    static func prepareForChildProcess(configuration: ProfileConfiguration) -> Bool {
        guard !isPrepared else { return true }
        guard !isTurnedOff else { return false }
        guard canHost(configuration) else {
            log.notice("An iPhone or iPad profile: our own window, which presents that device, rather than Safari's desktop chrome")
            return false
        }
        // Before the frameworks load: some of what they read, they read as they load.
        SafariChrome.configureSafarisOwnServices(for: configuration)
        guard SafariChrome.load() else { return false }
        // Before any of Safari's code runs: its own folders are the profile's (SafariPaths).
        if let realHome = SafariPaths.realHome, let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            SafariPaths.redirectGetters(from: realHome, to: home)
        }
        let structural = SafariChrome.missingStructuralPieces()
        guard structural.isEmpty else {
            log.error("This Safari lacks what its chrome needs here (\(structural.joined(separator: ", "), privacy: .public)): our own window instead")
            return false
        }
        guard SafariChrome.installApplication() else {
            log.error("NSApp is not Safari's application object: Safari's chrome is not hosted here")
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
        // Registered before the window exists: Safari builds the first web view while opening it,
        // and that web view must already get the profile's data store.
        ProfileNetworkGuard.register(session: session)
        let address = url ?? session.configuration.startURL
        guard let controller = SafariChrome.openWindow(address: address) else {
            log.error("Safari's chrome did not open a window for \(session.profileName, privacy: .private); using ours")
            return false
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        log.notice("A profile runs in Safari's chrome")
        return true
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
        follower.observations = [
            webView.observe(\.url, options: [.new]) { webView, _ in
                MainActor.assumeIsolated {
                    guard let url = webView.url, isRecorded(webView, url),
                          webView.backForwardList.currentItem?.url == url, url != follower.lastRecorded else { return }
                    follower.lastRecorded = url
                    ProfileNetworkGuard.session?.library.recordVisit(url: url, title: webView.title)
                }
            },
            webView.observe(\.title, options: [.new]) { webView, _ in
                MainActor.assumeIsolated {
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
