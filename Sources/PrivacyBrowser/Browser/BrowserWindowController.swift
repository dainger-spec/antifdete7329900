import AppKit
import BrowserCore
import Combine
import os
import SwiftUI
import WebKit

/// Window subclass so that File ▸ Close (⌘W) closes the current tab while the window's
/// close button still closes the whole window.
final class BrowserWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if sender is NSMenuItem, let controller = windowController as? BrowserWindowController, controller.tabCount > 1 {
            controller.closeSelectedTab()
            return
        }
        super.performClose(sender)
    }
}

/// A browser window of one profile: tab strip, toolbar, and the selected tab's web view.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private weak var session: BrowserSession?
    private let profileName: String
    private let library: ProfileLibrary

    private(set) var tabs: [BrowserTab] = []
    private var selectedIndex = 0
    /// URLs of recently closed tabs, most recent last (⇧⌘T).
    private var recentlyClosed: [URL] = []

    private let tabStrip = TabStripView()
    /// The profile chip and the start page (see BrowserChrome.swift).
    private let chrome: BrowserChromeModel
    /// Over the web views while the selected tab is an empty new tab.
    private var startPage: NSHostingView<StartPageView>!
    /// 0 with one tab: like Safari, the tab bar shows from the second tab on.
    private var tabStripHeight: NSLayoutConstraint!
    /// A mobile generation's viewport (nil for macOS): the tab strip adds to the window, not
    /// takes from the page, as a phone's Safari keeps its viewport whatever the tabs.
    private let deviceViewport: CGSize?
    /// The address field's width: what the other toolbar items leave, up to 680 pt (`fitAddressField`).
    private var addressWidth: NSLayoutConstraint!
    private let webContainer = NSView()
    private let addressField = AddressBarField()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var bookmarkButton: NSButton!
    /// The toolbar's items, in order (see `NSToolbarDelegate` below).
    private var toolbarViews: [(NSToolbarItem.Identifier, String, NSView)] = []
    private var libraryObservation: AnyCancellable?
    private var startPageObservation: AnyCancellable?
    private var isClosing = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserWindow")

    /// Search used for address-bar input that is not a URL (`WebAddress`). Queries go through the
    /// profile's proxy.
    static let searchURLTemplate = WebAddress.searchURLTemplate

    init(session: BrowserSession) {
        self.session = session
        self.profileName = session.profileName
        self.library = session.library
        self.chrome = BrowserChromeModel(profileName: session.profileName, profileID: session.profileID,
                                         exit: BrowserWindowController.profileExit(of: session))

        // A mobile generation's window is the viewport Safari leaves a page on the declared device:
        // its web content is never wider than the screen the page is told about, and lower than
        // it, as on the device (see PrivacyScripts.deviceViewportSize).
        let viewport = PrivacyScripts.deviceViewportSize(for: session.configuration)
        deviceViewport = viewport
        let contentSize = viewport ?? CGSize(width: 1200, height: 820)
        let window = BrowserWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        if let viewport { window.contentMaxSize = viewport }
        window.isReleasedWhenClosed = false
        // Never saved as restorable state at quit: AppKit would write the title — the profile's
        // name — to ~/Library/Saved Application State in plaintext.
        window.isRestorable = false
        window.title = "[\(session.profileName)]"
        // Safari's window: the controls in a unified toolbar, no separate title row. A page measures
        // the browser's chrome as outerHeight − innerHeight; this gives Safari's (52 pt with one tab).
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        // Our own tab strip replaces AppKit window tabbing (which would allow merging windows
        // and needs one NSWindow per tab).
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        // Dark chrome; the pages inside keep the system's light or dark (as in Safari). The toolbar
        // is flat (the window's colour under a transparent title bar), not a material. Its height —
        // which pages measure as outerHeight − innerHeight — stays Safari's.
        Theme.applyChrome(to: window)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = Theme.NS.toolbar
        buildInterface(in: window)
        WebContentAppearance.shared.follow(webContainer)
        window.center()
        // @Published emits before the value changes; read the store on the next main-actor turn.
        libraryObservation = library.$bookmarks.sink { [weak self] _ in
            Task { @MainActor in self?.updateBookmarkButton() }
        }
        startPageObservation = library.$bookmarks.combineLatest(library.$historyRevision).sink { [weak self] _ in
            Task { @MainActor in self?.refreshStartPage() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var tabCount: Int { tabs.count }
    var selectedTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    // MARK: Interface

    private func buildInterface(in window: NSWindow) {
        backButton = toolbarButton("chevron.left", "Back (⌘[)", #selector(goBack))
        forwardButton = toolbarButton("chevron.right", "Forward (⌘])", #selector(goForward))
        reloadButton = toolbarButton("arrow.clockwise", "Reload (⌘R)", #selector(reload))
        bookmarkButton = toolbarButton("star", "Bookmark this page (⌘D)", #selector(toggleBookmark))
        let bookmarksMenuButton = toolbarButton("book", "Bookmarks", #selector(showBookmarksMenu(_:)))
        let historyButton = toolbarButton("clock.arrow.circlepath", "History (⌘Y)", #selector(showHistory))
        let fillButton = toolbarButton("key.fill", L("toolbar.fillPassword"), #selector(fillPassword(_:)))
        let saveButton = toolbarButton("key.viewfinder", L("toolbar.savePassword"), #selector(savePassword))

        addressField.placeholderAttributedString = NSAttributedString(
            string: L("toolbar.address.placeholder"),
            attributes: [.foregroundColor: Theme.NS.textTertiary, .font: NSFont.systemFont(ofSize: 13)])
        addressField.delegate = self
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressEntered)

        // The profile chip: its glyph, name and the flag of where it exits.
        let badge = NSHostingView(rootView: ProfileChipView(model: chrome))
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The app's mark, where Safari has its sidebar button.
        let mark = NSHostingView(rootView: LumenMark(size: 20))
        mark.setFrameSize(NSSize(width: 20, height: 20))

        // The address field takes the room the toolbar has left.
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressWidth = addressField.widthAnchor.constraint(equalToConstant: 680)
        addressWidth.priority = .defaultLow
        NSLayoutConstraint.activate([addressField.heightAnchor.constraint(equalToConstant: 28),
                                     addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
                                     addressField.widthAnchor.constraint(lessThanOrEqualToConstant: 680), addressWidth])

        toolbarViews = [
            (.init("mark"), "Lumen", mark),
            (.init("back"), "Back", backButton!), (.init("forward"), "Forward", forwardButton!),
            (.init("reload"), "Reload", reloadButton!), (.init("address"), "Address", addressField),
            (.init("bookmark"), "Bookmark", bookmarkButton!), (.init("bookmarks"), "Bookmarks", bookmarksMenuButton),
            (.init("history"), "History", historyButton), (.init("fill"), "Fill Password", fillButton),
            (.init("save"), "Save Password", saveButton), (.init("profile"), profileName, badge),
        ]
        let toolbar = NSToolbar(identifier: "PrivacyBrowser.BrowserWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        tabStrip.delegate = self
        let container = NSView()
        startPage = NSHostingView(rootView: StartPageView(
            model: chrome,
            open: { [weak self] url in self?.openFromStartPage(url) },
            submit: { [weak self] text in
                guard let url = BrowserWindowController.url(fromAddressBarInput: text) else { return }
                self?.openFromStartPage(url)
            }))
        // Part of the chrome (dark), unlike the web views beside it (the system's appearance).
        startPage.appearance = Theme.chromeAppearance
        startPage.isHidden = true
        for view in [tabStrip, webContainer, startPage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: container.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabStripHeight,
            webContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            startPage.topAnchor.constraint(equalTo: webContainer.topAnchor),
            startPage.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            startPage.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            startPage.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        window.contentView = container
        fitAddressField()
    }

    /// NSToolbar gives the address field its preferred width and sends the items that no longer
    /// fit to the overflow menu, rather than narrowing the field: so the field asks only for what
    /// the other items leave (between its 160 and 680 pt).
    private func fitAddressField() {
        guard let window else { return }
        // Each item with the toolbar's spacing (measured on macOS 26: 24 pt between icons).
        let others = toolbarViews.filter { $0.0.rawValue != "address" }
            .reduce(CGFloat(0)) { $0 + max($1.2.fittingSize.width, $1.2.frame.width) + 26 }
        // The traffic lights and the toolbar's own margins.
        addressWidth.constant = min(680, max(160, window.frame.width - others - 120))
    }

    func windowDidResize(_ notification: Notification) {
        fitAddressField()
    }

    private func toolbarButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    // MARK: Tabs

    /// Adds a tab. `configuration` is only passed for popups (WebKit supplies it); otherwise the
    /// session's standard configuration is used.
    @discardableResult
    func addTab(url: URL?, configuration: WKWebViewConfiguration? = nil, select: Bool = true,
                afterSelected: Bool = true) -> BrowserTab? {
        guard let session else { return nil }
        let tab = BrowserTab(configuration: configuration ?? session.makeWebViewConfiguration(),
                             context: session.tabContext)
        tab.host = self
        tab.startsEmpty = url == nil && configuration == nil
        let index = afterSelected && !tabs.isEmpty ? selectedIndex + 1 : tabs.count
        tabs.insert(tab, at: index)
        if !select && index <= selectedIndex { selectedIndex += 1 }
        attach(tab)
        if select || tabs.count == 1 {
            if let url { tab.load(url) }
            selectTab(at: index)
            if url == nil && configuration == nil { focusAddressBar() }
        } else {
            refreshChrome()
            // Laid out before its page starts loading (the tab strip may just have appeared).
            window?.contentView?.layoutSubtreeIfNeeded()
            if let url { tab.load(url) }
        }
        return tab
    }

    /// Every tab's web view is in the window, filling the web area; only the selected one is shown.
    /// A tab behind the shown one (⌘-click, or the one the user left) thus has its window, screen
    /// and size, as in Safari: its page measures the viewport and window it will be shown in — not
    /// a 0×0 view outside any window, what headless browsers report — and WebKit keeps its window
    /// frame current when the window is moved or resized (a view taken out of the window would keep
    /// the frame it had then). Hidden, the page is not visible to WebKit (`document.visibilityState`
    /// 'hidden', timers throttled), as a background tab's.
    private func attach(_ tab: BrowserTab) {
        let webView = tab.webView
        webView.isHidden = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTab?.passwords.closeSuggestions()
        selectedIndex = index
        let webView = tabs[index].webView
        // Shown before the others are hidden: a hidden first responder hands focus on to the next view.
        webView.isHidden = false
        for tab in tabs where tab.webView !== webView { tab.webView.isHidden = true }
        refreshChrome()
        if webView.url != nil { window?.makeFirstResponder(webView) }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 {
            close() // windowWillClose tears everything down
            return
        }
        let tab = tabs.remove(at: index)
        if let url = tab.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            recentlyClosed.append(url)
            if recentlyClosed.count > 25 { recentlyClosed.removeFirst() }
        }
        tab.tearDown()
        if index < selectedIndex || selectedIndex >= tabs.count {
            selectedIndex = max(0, selectedIndex - 1)
        }
        selectTab(at: selectedIndex)
    }

    func closeSelectedTab() { closeTab(at: selectedIndex) }

    @objc func newTab() { addTab(url: nil) }

    func reopenClosedTab() {
        guard let url = recentlyClosed.popLast() else { return }
        addTab(url: url)
    }

    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        selectTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    /// ⌘1…⌘8 select that tab, ⌘9 the last one (Safari/Chrome convention).
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        selectTab(at: number >= 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1))
    }

    /// Updates tab strip, address bar, buttons and window title from the selected tab.
    private func refreshChrome() {
        let showsTabStrip = tabs.count > 1
        let stripChanges = (tabStripHeight.constant > 0) != showsTabStrip
        tabStrip.isHidden = !showsTabStrip
        tabStripHeight.constant = showsTabStrip ? TabStripView.height : 0
        if stripChanges, let deviceViewport, let window {
            let strip = showsTabStrip ? TabStripView.height : -TabStripView.height
            let content = window.contentRect(forFrameRect: window.frame).size
            window.contentMaxSize = CGSize(width: deviceViewport.width, height: deviceViewport.height + tabStripHeight.constant)
            // The top edge stays where it is: the window grows or shrinks at the bottom.
            var frame = window.frame
            let height = window.frameRect(forContentRect: NSRect(origin: .zero, size: CGSize(width: content.width, height: content.height + strip))).height
            frame.origin.y -= height - frame.height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
        updateStartPage()
        tabStrip.update(items: tabs.map { tab in
            TabStripView.Item(title: tab.displayTitle,
                              toolTip: [tab.webView.title, tab.url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                              isLoading: tab.isLoading)
        }, selectedIndex: selectedIndex)
        guard let tab = selectedTab else { return }
        window?.title = String(format: L("window.browser.title"), profileName, tab.displayTitle)
        if addressField.currentEditor() == nil { // don't overwrite what the user is typing
            addressField.stringValue = tab.url?.absoluteString ?? ""
        }
        backButton.isEnabled = tab.webView.canGoBack
        forwardButton.isEnabled = tab.webView.canGoForward
        reloadButton.image = NSImage(systemSymbolName: tab.isLoading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: tab.isLoading ? "Stop" : "Reload")
        updateBookmarkButton()
    }

    // MARK: Navigation

    func load(_ url: URL) {
        guard let tab = selectedTab else {
            addTab(url: url)
            return
        }
        addressField.stringValue = url.absoluteString
        tab.load(url)
        updateStartPage()
    }

    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
    }

    /// A favourite, a recent page or a search from the start page: in the empty tab itself.
    private func openFromStartPage(_ url: URL) {
        load(url)
        if let webView = selectedTab?.webView { window?.makeFirstResponder(webView) }
    }

    /// The start page covers the selected tab while it is an empty new tab.
    private func updateStartPage() {
        let shows = selectedTab?.showsStartPage ?? false
        guard startPage.isHidden == shows else { return }
        startPage.isHidden = !shows
        guard shows, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        startPage.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            startPage.animator().alphaValue = 1
        }
    }

    // MARK: Chrome

    private static func profileExit(of session: BrowserSession) -> ProfileExit {
        guard let proxy = session.configuration.proxy else { return .direct }
        return .proxy(endpoint: "\(proxy.host):\(proxy.port)", countryCode: session.exitLocation?.countryCode)
    }

    /// The session learnt where its proxy exits (a lookup that finished after launch).
    func exitLocationDidChange() {
        guard let session else { return }
        chrome.exit = Self.profileExit(of: session)
    }

    private func refreshStartPage() {
        chrome.update(bookmarks: library.bookmarks, history: library.historyEntries(matching: "", limit: 12))
    }

    @objc func goBack() { selectedTab?.webView.goBack() }
    @objc func goForward() { selectedTab?.webView.goForward() }

    @objc func reload() {
        guard let webView = selectedTab?.webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    @objc private func addressEntered() {
        guard let url = Self.url(fromAddressBarInput: addressField.stringValue) else { return }
        load(url)
        if let webView = selectedTab?.webView { window?.makeFirstResponder(webView) }
    }

    /// Escape in the address bar restores the current URL.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === addressField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        addressField.stringValue = selectedTab?.url?.absoluteString ?? ""
        if let webView = selectedTab?.webView { window?.makeFirstResponder(webView) }
        return true
    }

    static func url(fromAddressBarInput input: String) -> URL? {
        WebAddress.url(fromAddressBarInput: input)
    }

    // MARK: Bookmarks and history

    private func updateBookmarkButton() {
        let bookmarked = library.bookmark(for: selectedTab?.url) != nil
        bookmarkButton?.image = NSImage(systemSymbolName: bookmarked ? "star.fill" : "star",
                                        accessibilityDescription: bookmarked ? "Remove bookmark" : "Bookmark this page")
        bookmarkButton?.isEnabled = selectedTab?.url.flatMap { HistoryStore.normalizedURL($0) } != nil
    }

    /// Adds the current page, or removes its bookmark if it already has one.
    @objc func toggleBookmark() {
        guard let tab = selectedTab, let url = tab.url else { return }
        if let existing = library.bookmark(for: url) {
            library.removeBookmark(id: existing.id)
        } else {
            library.addBookmark(title: tab.webView.title ?? "", url: url)
        }
        updateBookmarkButton()
    }

    @objc private func showBookmarksMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let bookmarks = library.bookmarks
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: L("bookmarks.menu.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        var folderMenus: [String: NSMenu] = [:]
        for bookmark in bookmarks {
            let item = NSMenuItem(title: bookmark.title, action: #selector(openBookmarkFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bookmark.url
            item.toolTip = bookmark.url
            if let folder = bookmark.folder {
                if folderMenus[folder] == nil {
                    let submenu = NSMenu(title: folder)
                    let folderItem = NSMenuItem(title: folder, action: nil, keyEquivalent: "")
                    folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    folderItem.submenu = submenu
                    menu.addItem(folderItem)
                    folderMenus[folder] = submenu
                }
                folderMenus[folder]?.addItem(item)
            } else {
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: L("menu.showAllBookmarks"), action: #selector(showBookmarks), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openBookmarkFromMenu(_ item: NSMenuItem) {
        guard let string = item.representedObject as? String, let url = URL(string: string) else { return }
        // ⌘ held → new tab, as for links.
        if NSEvent.modifierFlags.contains(.command) { addTab(url: url) } else { load(url) }
    }

    @objc func showHistory() { session?.showLibrary(.history, from: self) }
    @objc func showBookmarks() { session?.showLibrary(.bookmarks, from: self) }

    // MARK: Passwords

    /// The key button: the page's saved logins, under the button (as the list under a login field).
    @objc private func fillPassword(_ sender: NSButton) {
        selectedTab?.passwords.showSuggestionsFromToolbar(anchor: sender)
    }

    /// Saves what the page's password fields hold (the question a sign-in asks, on demand).
    @objc private func savePassword() {
        selectedTab?.passwords.saveFromPage()
    }

    // MARK: Lifecycle

    func windowWillClose(_ notification: Notification) {
        tearDown()
        // CRASH FIX: `windowDidClose` removes this controller from `session.windows`, which can
        // drop the last strong reference to it (and to its NSWindow). Releasing the window while
        // AppKit is still executing this window's close machinery is a use-after-free. Capture
        // `self` strongly and hand off on the next main-run-loop turn, so the window stays alive
        // until AppKit has finished closing it; the strong capture is released when the block runs.
        let session = self.session
        DispatchQueue.main.async { [self] in
            session?.windowDidClose(self)
        }
    }

    /// Tears down every tab so the web views (and with them the profile's data store) can be
    /// deallocated promptly.
    func tearDown() {
        guard !isClosing else { return }
        isClosing = true
        libraryObservation = nil
        startPageObservation = nil
        tabs.forEach { $0.tearDown() }
        tabs.removeAll()
        window?.delegate = nil
    }
}

// MARK: - BrowserTabHost

extension BrowserWindowController: BrowserTabHost {
    var hostWindow: NSWindow? { window }

    func tabDidChange(_ tab: BrowserTab) {
        guard !isClosing else { return }
        refreshChrome()
    }

    func tab(_ tab: BrowserTab, createTabWith configuration: WKWebViewConfiguration) -> WKWebView? {
        // The configuration WebKit passes in carries the opener's data store and user scripts.
        addTab(url: nil, configuration: configuration, select: true)?.webView
    }

    func tab(_ tab: BrowserTab, openInBackground request: URLRequest) {
        guard let url = request.url else { return }
        addTab(url: url, select: false)
    }

    func tabDidRequestClose(_ tab: BrowserTab) {
        if let index = tabs.firstIndex(where: { $0 === tab }) { closeTab(at: index) }
    }

    func tabNeedsAttention(_ tab: BrowserTab) {
        if let index = tabs.firstIndex(where: { $0 === tab }), index != selectedIndex { selectTab(at: index) }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSToolbarDelegate

extension BrowserWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarViews.map(\.0)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarViews.map(\.0)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let entry = toolbarViews.first(where: { $0.0 == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = entry.1
        item.view = entry.2
        // Flat items on the toolbar's own colour: no glass platters behind them (macOS 26 gives
        // bordered items one), the same look on every macOS.
        item.isBordered = false
        switch itemIdentifier.rawValue {
        case "address", "profile": item.visibilityPriority = .high
        case "mark": item.visibilityPriority = .low
        default: break
        }
        return item
    }
}

// MARK: - TabStripViewDelegate

extension BrowserWindowController: TabStripViewDelegate {
    func tabStrip(_ strip: TabStripView, didSelect index: Int) { selectTab(at: index) }
    func tabStrip(_ strip: TabStripView, didClose index: Int) { closeTab(at: index) }
    func tabStripDidRequestNewTab(_ strip: TabStripView) { newTab() }
}
