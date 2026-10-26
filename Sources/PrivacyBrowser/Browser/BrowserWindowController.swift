import AppKit
import BrowserCore
import Combine
import os
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
    private let passwordVault: PasswordVault
    private let library: ProfileLibrary

    private(set) var tabs: [BrowserTab] = []
    private var selectedIndex = 0
    /// URLs of recently closed tabs, most recent last (⇧⌘T).
    private var recentlyClosed: [URL] = []

    private let tabStrip = TabStripView()
    private let webContainer = NSView()
    private let addressField = NSTextField()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var bookmarkButton: NSButton!
    private var libraryObservation: AnyCancellable?
    private var isClosing = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserWindow")

    /// Search used for address-bar input that is not a URL. Queries go through the profile's proxy.
    static let searchURLTemplate = "https://duckduckgo.com/?q="

    init(session: BrowserSession) {
        self.session = session
        self.profileName = session.profileName
        self.passwordVault = session.passwordVault
        self.library = session.library

        // A mobile generation's window is the declared device's screen: its web content can never
        // be wider or taller than the screen the page is told about (see PrivacyScripts).
        let deviceScreen = PrivacyScripts.deviceScreenSize(for: session.configuration)
        let contentSize = deviceScreen ?? CGSize(width: 1200, height: 820)
        let window = BrowserWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        if let deviceScreen { window.contentMaxSize = deviceScreen }
        window.isReleasedWhenClosed = false
        // Never saved as restorable state at quit: AppKit would write the title — the profile's
        // name — to ~/Library/Saved Application State in plaintext.
        window.isRestorable = false
        window.title = "[\(session.profileName)]"
        // Our own tab strip replaces AppKit window tabbing (which would allow merging windows
        // and needs one NSWindow per tab).
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window)
        window.center()
        // @Published emits before the value changes; read the store on the next main-actor turn.
        libraryObservation = library.$bookmarks.sink { [weak self] _ in
            Task { @MainActor in self?.updateBookmarkButton() }
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
        let fillButton = toolbarButton("key.fill", "Fill saved password", #selector(fillPassword(_:)))
        let saveButton = toolbarButton("key.viewfinder", "Save password from this page", #selector(savePassword))

        addressField.placeholderString = "Search or enter address"
        addressField.delegate = self
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressEntered)

        let badge = NSTextField(labelWithString: profileName)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, bookmarkButton,
                                      bookmarksMenuButton, historyButton, fillButton, saveButton, badge])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tabStrip.delegate = self
        let container = NSView()
        for view in [tabStrip, bar, webContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: container.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),
            bar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
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
        let index = afterSelected && !tabs.isEmpty ? selectedIndex + 1 : tabs.count
        tabs.insert(tab, at: index)
        if !select && index <= selectedIndex { selectedIndex += 1 }
        if let url { tab.load(url) }
        if select || tabs.count == 1 {
            selectTab(at: index)
            if url == nil && configuration == nil { focusAddressBar() }
        } else {
            refreshChrome()
        }
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        let webView = tabs[index].webView
        if webView.superview !== webContainer {
            webContainer.subviews.forEach { $0.removeFromSuperview() }
            webView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
        }
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
    }

    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
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
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" "), text.contains(".") || text.hasPrefix("localhost"), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        return URL(string: searchURLTemplate + query)
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

    @objc private func fillPassword(_ sender: NSButton) {
        guard let tab = selectedTab, let url = tab.url, let origin = PasswordEntry.normalizedOrigin(for: url) else { return }
        let entries = passwordVault.entries(for: url)
        switch entries.count {
        case 0:
            tab.showMessage(String(format: L("pw.noSaved"), origin))
        case 1:
            fill(entries[0], origin: origin, in: tab)
        default:
            let menu = NSMenu()
            for entry in entries {
                let item = NSMenuItem(title: entry.username.isEmpty ? "(no username)" : entry.username,
                                      action: #selector(fillFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    @objc private func fillFromMenu(_ item: NSMenuItem) {
        guard let tab = selectedTab, let id = item.representedObject as? UUID, let url = tab.url,
              let origin = PasswordEntry.normalizedOrigin(for: url),
              let entry = passwordVault.entries(for: url).first(where: { $0.id == id }) else { return }
        fill(entry, origin: origin, in: tab)
    }

    private func fill(_ entry: PasswordEntry, origin: String, in tab: BrowserTab) {
        PasswordAutofill.fill(entry, origin: origin, in: tab.webView) { [weak tab] filled in
            if !filled { tab?.showMessage(L("pw.noField")) }
        }
    }

    @objc private func savePassword() {
        guard let tab = selectedTab, let url = tab.url, let origin = PasswordEntry.normalizedOrigin(for: url) else { return }
        PasswordAutofill.capture(origin: origin, in: tab.webView) { [weak self, weak tab] captured in
            guard let self, let tab else { return }
            guard let captured else {
                tab.showMessage(L("pw.typeFirst"))
                return
            }
            let alert = NSAlert()
            alert.messageText = String(format: L("pw.saveTitle"), captured.origin)
            alert.informativeText = captured.username.isEmpty ? L("pw.noUsernameDetected") : String(format: L("pw.usernameLabel"), captured.username)
            alert.addButton(withTitle: L("common.save"))
            alert.addButton(withTitle: L("common.cancel"))
            guard let window = self.window else { return }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    try self.passwordVault.upsert(PasswordEntry(origin: captured.origin, username: captured.username,
                                                                password: captured.password))
                } catch {
                    tab.showMessage(String(format: L("pw.couldNotSave"), error.localizedDescription))
                }
            }
        }
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

// MARK: - TabStripViewDelegate

extension BrowserWindowController: TabStripViewDelegate {
    func tabStrip(_ strip: TabStripView, didSelect index: Int) { selectTab(at: index) }
    func tabStrip(_ strip: TabStripView, didClose index: Int) { closeTab(at: index) }
    func tabStripDidRequestNewTab(_ strip: TabStripView) { newTab() }
}
