import AppKit
import BrowserCore
import os
import WebKit

/// Downloads of a profile shown in Safari's window: saved where the app's settings say
/// (Settings → Downloads: the folder, or asked each time), listed by View › Show Downloads (⌥⌘L),
/// counted on the profile's Dock icon until the list is looked at.
///
/// Until 15 November a download in Safari's window did nothing and said nothing
/// (docs/SAFARI_SUBSYSTEMS.md, O6), and Show Downloads was disabled: Safari's downloads go through
/// services of the real Safari, which a profile's process is refused (`ProfileNetworkGuard`). So a
/// profile's downloads are taken here, at WebKit's own interface, the way a window of ours has
/// always taken them (`BrowserTab`) — nothing of Safari's download code is relied on:
///   * what is a download is decided as Safari decides it — a response the engine cannot show, or
///     one its server sends to be saved (`DownloadPolicy`), and a link with `download` — before
///     Safari's navigation delegate is asked; every other response and action is Safari's to decide;
///   * a download WebKit makes of a navigation, and one Safari gives a delegate of its own, gets
///     this delegate (`ProfileNetworkGuard` covers the delegates as they are set);
///   * its challenges are the profile's, as every delegate's in this process (`ServerTrust`).
///
/// What differs from Safari, on purpose: Safari asks once per site whether it may download; a
/// profile's window of ours never has, and here the file goes where the settings say. A file is
/// never opened and never shown in the Finder from a profile's process (`SystemOpen`, `HandOffs`):
/// the list says where it is. Downloaded files are outside the profile's encrypted storage, as
/// the settings say.
@MainActor
final class HostedDownloads: NSObject, WKDownloadDelegate {
    static let shared = HostedDownloads()
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "HostedDownloads")

    /// This run's downloads (`DownloadLog`).
    private(set) var list = DownloadLog()
    private var entryOfDownload: [ObjectIdentifier: UUID] = [:]
    private var destinations: [UUID: URL] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    /// The addresses that became downloads in this run: a tab left on one is not a page the
    /// profile left open (`SafariTabs`) — opened again at the next start, it would download again.
    private(set) var addresses: Set<URL> = []

    /// What happened to downloads in this process, for the network report: how many responses and
    /// links were taken for downloads here, how many downloads WebKit handed over, how many of
    /// Safari's own delegates were stood in for, and how they ended.
    struct Counts: Equatable {
        var decided = 0
        var handedOver = 0
        var stoodIn = 0
        var asked = 0
        var finished = 0
        var failed = 0

        var text: String {
            "decided \(decided), handed over \(handedOver), stood in for Safari's \(stoodIn), destinations \(asked), finished \(finished), failed \(failed)"
        }
    }

    private(set) static var counts = Counts()

    // MARK: Taking a profile's downloads

    /// Classes of navigation delegates already covered, by name.
    private static var covered: Set<String> = []

    /// Makes the class of `delegate` — a navigation delegate one of Safari's web views is being
    /// given — hand the profile's downloads over: asked about a response or an action that is a
    /// download, it answers "download" before its own code runs, and told that one began, it gives
    /// it this delegate instead of Safari's own. Nothing else of the class changes, and nothing at
    /// all of a delegate of ours (`AnswersProfileChallenges`), outside Safari's window.
    static func cover(navigationDelegate delegate: AnyObject) {
        guard SafariChromeHost.isHosting, !(delegate is AnswersProfileChallenges),
              let delegateClass: AnyClass = object_getClass(delegate) else { return }
        guard covered.insert(NSStringFromClass(delegateClass)).inserted else { return }

        // A download WebKit made of a navigation: this delegate's from the start.
        let began: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { _, webView, _, download in
            guard let download = download as? WKDownload else { return }
            counts.handedOver += 1
            HostedDownloads.shared.take(download, from: webView as? WKWebView)
        }
        for name in ["webView:navigationAction:didBecomeDownload:", "webView:navigationResponse:didBecomeDownload:"] {
            class_replaceMethod(delegateClass, NSSelectorFromString(name), imp_implementationWithBlock(began), "v@:@@@")
        }

        // A response that is a download is one, whatever the class would have answered.
        typealias ResponseDecision = @convention(block) (WKNavigationResponsePolicy) -> Void
        typealias ResponseQuestion = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, ResponseDecision) -> Void
        let responseSelector = NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")
        let responseMethod = class_getInstanceMethod(delegateClass, responseSelector)
        let askResponse = responseMethod.map { unsafeBitCast(method_getImplementation($0), to: ResponseQuestion.self) }
        let responsePolicy: @convention(block) (AnyObject, AnyObject?, AnyObject?, @escaping ResponseDecision) -> Void = { receiver, webView, asked, decide in
            if let response = asked as? WKNavigationResponse, isDownload(response) {
                counts.decided += 1
                decide(.download)
                return
            }
            if let askResponse {
                askResponse(receiver, responseSelector, webView, asked, decide)
            } else {
                decide(.allow)
            }
        }
        class_replaceMethod(delegateClass, responseSelector, imp_implementationWithBlock(responsePolicy),
                            responseMethod.flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) } ?? "v@:@@@?")

        // A link with `download`: whichever of WebKit's three questions about an action the class
        // answers, it answers "download" for such a link. A question the class does not answer is
        // not added: WebKit asks the first one a delegate has.
        typealias ActionDecision = @convention(block) (WKNavigationActionPolicy, AnyObject?) -> Void
        typealias PlainActionDecision = @convention(block) (WKNavigationActionPolicy) -> Void
        let withUserInfo = NSSelectorFromString("_webView:decidePolicyForNavigationAction:preferences:userInfo:decisionHandler:")
        if let method = class_getInstanceMethod(delegateClass, withUserInfo), let types = method_getTypeEncoding(method) {
            typealias Question = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, ActionDecision) -> Void
            let ask = unsafeBitCast(method_getImplementation(method), to: Question.self)
            let actionPolicy: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, @escaping ActionDecision) -> Void = { receiver, webView, asked, preferences, userInfo, decide in
                if (asked as? WKNavigationAction)?.shouldPerformDownload == true {
                    counts.decided += 1
                    decide(.download, preferences)
                    return
                }
                ask(receiver, withUserInfo, webView, asked, preferences, userInfo, decide)
            }
            class_replaceMethod(delegateClass, withUserInfo, imp_implementationWithBlock(actionPolicy), types)
        }
        let withPreferences = NSSelectorFromString("webView:decidePolicyForNavigationAction:preferences:decisionHandler:")
        if let method = class_getInstanceMethod(delegateClass, withPreferences), let types = method_getTypeEncoding(method) {
            typealias Question = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, ActionDecision) -> Void
            let ask = unsafeBitCast(method_getImplementation(method), to: Question.self)
            let actionPolicy: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, @escaping ActionDecision) -> Void = { receiver, webView, asked, preferences, decide in
                if (asked as? WKNavigationAction)?.shouldPerformDownload == true {
                    counts.decided += 1
                    decide(.download, preferences)
                    return
                }
                ask(receiver, withPreferences, webView, asked, preferences, decide)
            }
            class_replaceMethod(delegateClass, withPreferences, imp_implementationWithBlock(actionPolicy), types)
        }
        let plain = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        if let method = class_getInstanceMethod(delegateClass, plain), let types = method_getTypeEncoding(method) {
            typealias Question = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, PlainActionDecision) -> Void
            let ask = unsafeBitCast(method_getImplementation(method), to: Question.self)
            let actionPolicy: @convention(block) (AnyObject, AnyObject?, AnyObject?, @escaping PlainActionDecision) -> Void = { receiver, webView, asked, decide in
                if (asked as? WKNavigationAction)?.shouldPerformDownload == true {
                    counts.decided += 1
                    decide(.download)
                    return
                }
                ask(receiver, plain, webView, asked, decide)
            }
            class_replaceMethod(delegateClass, plain, imp_implementationWithBlock(actionPolicy), types)
        }
        log.notice("Downloads of \(NSStringFromClass(delegateClass), privacy: .public)'s pages are the profile's")
    }

    /// The delegate a download is given in Safari's window: this one, whoever Safari's code names
    /// (a download it starts itself — Download Linked File — or resumes). In a window of ours the
    /// tab's own, as it is.
    static func delegate(inPlaceOf delegate: AnyObject) -> AnyObject {
        guard SafariChromeHost.isHosting, !(delegate is HostedDownloads), !(delegate is BrowserTab) else { return delegate }
        counts.stoodIn += 1
        return shared
    }

    /// A response the engine cannot show, or one its server sends to be saved (`DownloadPolicy`).
    private static func isDownload(_ response: WKNavigationResponse) -> Bool {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        return DownloadPolicy.isDownload(canShow: response.canShowMIMEType, contentDisposition: disposition)
    }

    /// The window a download began in, for its save panel, while its web view may be gone.
    private var windows = NSMapTable<WKDownload, NSWindow>.weakToWeakObjects()

    private func take(_ download: WKDownload, from webView: WKWebView?) {
        if let window = webView?.window { windows.setObject(window, forKey: download) }
        download.delegate = self
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        Self.counts.asked += 1
        for address in [download.originalRequest?.url, response.url] {
            if let address { addresses.insert(address) }
        }
        let preferences = BrowsingPreferences.current
        let decide: (URL?) -> Void = { [weak self] destination in
            if let self, let destination { self.began(download, at: destination) }
            completionHandler(destination)
        }
        guard preferences.askWhereToSave else {
            let folder = preferences.downloadFolderURL
            // The folder the settings name may have been removed since: made again, as a save
            // panel would let the person make it.
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            decide(BrowserTab.uniqueDownloadURL(suggestedFilename: suggestedFilename, in: folder))
            return
        }
        // Asked for every download, as the setting says, over the window it began in — brought
        // out of the Dock for it — or, with that window gone, in a panel of its own. Cancelled:
        // no destination, so WebKit cancels the download and nothing is written.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BrowserTab.safeDownloadName(suggestedFilename)
        panel.directoryURL = preferences.downloadFolderURL
        panel.canCreateDirectories = true
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated { decide(response == .OK ? panel.url : nil) }
        }
        if let window = windows.object(forKey: download) ?? download.webView?.window ?? Self.frontBrowserWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: window, completionHandler: answer)
        } else {
            panel.begin(completionHandler: answer)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        Self.counts.finished += 1
        guard let id = entryOfDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observations[id] = nil
        let size = destinations[id].flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
        list.finish(id, bytes: size?.int64Value)
        showCount()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = entryOfDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observations[id] = nil
        // Cancelled (the save panel's Cancel, a page going away before it began): nothing failed.
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
            list.cancel(id)
            return
        }
        Self.counts.failed += 1
        Self.log.error("A download failed: \(error.logKind, privacy: .public)")
        let name = list.entries.first { $0.id == id }?.name ?? ""
        list.fail(id, reason: error.localizedDescription)
        showCount()
        // Said in the window it was asked for in: nothing else there shows that a download ended.
        SafariChrome.presentNotice(L("downloads.title"), String(format: L("downloads.failed.named"), name, error.localizedDescription))
    }

    /// The destination is decided: listed from here on, with how much of it has come.
    private func began(_ download: WKDownload, at destination: URL) {
        let id = list.begin(name: destination.lastPathComponent, folder: destination.deletingLastPathComponent().path)
        entryOfDownload[ObjectIdentifier(download)] = id
        destinations[id] = destination
        observations[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            // WebKit reports progress on its own queue; the list is the main actor's.
            let known = progress.totalUnitCount > 0
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.list.progress(id, fraction: known ? fraction : nil) }
            }
        }
    }

    /// The number of downloads that ended since the list was looked at, on the profile's Dock icon.
    private func showCount() {
        NSApp.dockTile.badgeLabel = list.unseen > 0 ? String(list.unseen) : nil
    }

    private static func frontBrowserWindow() -> NSWindow? {
        NSApp.orderedWindows.first { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }
    }

    // MARK: Safari's own downloads folder

    /// The key Safari keeps its downloads folder under.
    static let safarisFolderKey = "DownloadsPath"

    /// Safari's own downloads folder is the one the app's settings name, for what Safari's code
    /// does with it itself: an image's "Save Image to “Downloads”" names it and saves there. Unset in
    /// a profile's process, the item read "Save Image to “(null)”" and choosing it said "Safari can't
    /// save the file … to the downloads folder" (the sweep with real input, CI run 43990525206,
    /// macOS 26). Set in this process's argument domain only, as Safari's other settings for a
    /// profile are (`SafariChrome.configureSafarisOwnServices`): nothing is written to a file. Where
    /// a download's file goes is still this delegate's to decide (`delegate(inPlaceOf:)`).
    static func nameFolderForSafari(_ preferences: BrowsingPreferences) {
        let path = preferences.downloadFolderURL.path
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard arguments[safarisFolderKey] as? String != path else { return }
        arguments[safarisFolderKey] = path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: View › Show Downloads

    /// Safari's own action behind View › Show Downloads (⌥⌘L), disabled in a profile's window.
    static let safarisAction = "showDownloads:"

    /// View › Show Downloads lists the profile's downloads: the item keeps its place and its keys.
    /// Routed now and whenever a menu of the menu bar opens, as Safari fills its menus again.
    static func routeMenu() {
        shared.route()
        guard !shared.isObservingMenus else { return }
        shared.isObservingMenus = true
        _ = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HostedDownloads.shared.route() }
        }
    }

    private var isObservingMenus = false
    /// The menu bar has Show Downloads routed here (the network report says so).
    private(set) var isRouted = false

    private func route() {
        guard let bar = NSApp.mainMenu else { return }
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, NSStringFromSelector(action) == Self.safarisAction {
                    item.target = self
                    item.action = #selector(showProfileDownloads(_:))
                    isRouted = true
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(bar)
    }

    /// The list as the window shows it: where this run's files went and how each ended, newest
    /// first; with nothing downloaded yet, where files will go.
    func listText() -> String {
        let folder = BrowsingPreferences.current.downloadFolderURL.path
        guard !list.entries.isEmpty else { return String(format: L("downloads.none"), folder) }
        let lines = list.entries.suffix(20).reversed().map { entry -> String in
            var line = entry.name + " — " + Self.said(entry.state)
            if entry.folder != folder { line += " (" + entry.folder + ")" }
            return line
        }
        return String(format: L("downloads.list"), folder) + "\n" + lines.joined(separator: "\n")
    }

    private static func said(_ state: DownloadLog.Entry.State) -> String {
        switch state {
        case .running(let fraction):
            guard let fraction else { return L("downloads.state.running") }
            return String(format: L("downloads.state.progress"), Int((fraction * 100).rounded(.down)))
        case .finished(let bytes):
            guard let bytes else { return L("downloads.state.finished") }
            return bytes.formatted(.byteCount(style: .file).locale(Localization.locale))
        case .failed(let reason):
            return String(format: L("downloads.state.failed"), reason)
        }
    }

    /// What this profile downloaded in this run, on a sheet of the window in front: a profile's
    /// process shows nothing in the Finder (`SystemOpen`), so the list says where each file is.
    @objc func showProfileDownloads(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L("downloads.title")
        alert.informativeText = listText()
        alert.addButton(withTitle: L("common.ok"))
        let canClear = list.entries.contains(where: \.hasEnded)
        if canClear { alert.addButton(withTitle: L("downloads.clear")) }
        list.markSeen()
        showCount()
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard canClear, response == .alertSecondButtonReturn else { return }
                self?.list.clearEnded()
                self?.showCount()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? Self.frontBrowserWindow() {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }
}

extension HostedDownloads: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}
