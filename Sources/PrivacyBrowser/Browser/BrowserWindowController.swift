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
    private let passwordVault: PasswordVault
    private let library: ProfileLibrary

    private(set) var tabs: [BrowserTab] = []
    private var selectedIndex = 0
    /// URLs of recently closed tabs, most recent last (⇧⌘T).
    private var recentlyClosed: [URL] = []

    private let tabStrip = TabStripView()
    private let webContainer = NSView()
    private let addressField = AddressField()
    private let securityIcon = NSImageView()
    private let progressLine = ProgressLine()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var bookmarkButton: NSButton!
    private var downloadsButton: NSButton!
    private let proxyButton = NSButton(title: "", target: nil, action: nil)
    private var downloadsPopover: NSPopover?
    private var libraryObservation: AnyCancellable?
    private var proxyObservation: AnyCancellable?
    private var downloadsObservation: AnyCancellable?
    private var isClosing = false
    private let log = Logger(subsystem: "PrivacyBrowser", category: "BrowserWindow")

    /// Search used for address-bar input that is not a URL. Queries go through the profile's proxy.
    static let searchURLTemplate = "https://duckduckgo.com/?q="

    init(session: BrowserSession) {
        self.session = session
        self.profileName = session.profileName
        self.passwordVault = session.passwordVault
        self.library = session.library

        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        proxyObservation = session.proxyCenter?.$statuses.sink { [weak self] _ in
            Task { @MainActor in self?.updateProxyButton() }
        }
        downloadsObservation = session.downloads.$items.sink { [weak self] _ in
            Task { @MainActor in self?.updateDownloadsButton() }
        }
        updateProxyButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var tabCount: Int { tabs.count }
    var selectedTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    // MARK: Interface

    private func buildInterface(in window: NSWindow) {
        backButton = toolbarButton("chevron.left", L("browser.back.help"), #selector(goBack))
        forwardButton = toolbarButton("chevron.right", L("browser.forward.help"), #selector(goForward))
        reloadButton = toolbarButton("arrow.clockwise", L("browser.reload.help"), #selector(reload))
        bookmarkButton = toolbarButton("star", L("browser.bookmark.help"), #selector(toggleBookmark))
        let bookmarksMenuButton = toolbarButton("book", L("browser.bookmarks.help"), #selector(showBookmarksMenu(_:)))
        let historyButton = toolbarButton("clock.arrow.circlepath", L("browser.history.help"), #selector(showHistory))
        downloadsButton = toolbarButton("arrow.down.circle", L("browser.downloads.help"), #selector(showDownloads(_:)))
        let fillButton = toolbarButton("key.fill", L("browser.fillPassword.help"), #selector(fillPassword(_:)))
        let saveButton = toolbarButton("key.viewfinder", L("browser.savePassword.help"), #selector(savePassword))

        addressField.placeholderString = L("browser.address.placeholder")
        addressField.delegate = self
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.font = .systemFont(ofSize: NSFont.systemFontSize)
        addressField.bezelStyle = .roundedBezel

        securityIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        securityIcon.contentTintColor = .secondaryLabelColor
        securityIcon.setContentHuggingPriority(.required, for: .horizontal)

        proxyButton.target = self
        proxyButton.action = #selector(proxyButtonClicked)
        proxyButton.bezelStyle = .inline
        proxyButton.imagePosition = .imageLeading
        proxyButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        proxyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let badge = NSTextField(labelWithString: profileName)
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, securityIcon, addressField, bookmarkButton,
                                      bookmarksMenuButton, historyButton, downloadsButton, fillButton, saveButton,
                                      proxyButton, badge])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tabStrip.delegate = self
        let container = NSView()
        for view in [tabStrip, bar, progressLine, webContainer] as [NSView] {
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
            progressLine.topAnchor.constraint(equalTo: bar.bottomAnchor),
            progressLine.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2),
            webContainer.topAnchor.constraint(equalTo: progressLine.bottomAnchor),
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

    /// Rebuilds a window from the saved session: every tab is created, only the selected one loads.
    func restoreTabs(_ state: SessionState.Window) {
        guard let session else { return }
        for saved in state.tabs {
            let tab = BrowserTab(configuration: session.makeWebViewConfiguration(), context: session.tabContext,
                                 pending: saved)
            tab.host = self
            tabs.append(tab)
        }
        if tabs.isEmpty {
            addTab(url: nil)
        } else {
            selectTab(at: min(max(state.selectedIndex, 0), tabs.count - 1))
        }
    }

    /// This window as the saved session stores it.
    var sessionWindow: SessionState.Window {
        var saved: [SessionState.Tab] = []
        var selected = 0
        for (index, tab) in tabs.enumerated() {
            guard let item = tab.sessionTab else { continue }
            if index == selectedIndex { selected = saved.count }
            saved.append(item)
        }
        return SessionState.Window(tabs: saved, selectedIndex: selected)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        tabs[index].loadPendingIfNeeded()
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
        if tabs[index].url != nil { window?.makeFirstResponder(webView) }
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
                              toolTip: [tab.displayTitle, tab.url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
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
                                     accessibilityDescription: tab.isLoading ? L("browser.stop.help") : L("browser.reload.help"))
        reloadButton.toolTip = tab.isLoading ? L("browser.stop.help") : L("browser.reload.help")
        updateSecurityIcon(tab)
        progressLine.update(fraction: tab.estimatedProgress, visible: tab.isLoading)
        updateBookmarkButton()
    }

    private func updateSecurityIcon(_ tab: BrowserTab) {
        let scheme = tab.url?.scheme?.lowercased()
        let symbol: String?
        let help: String
        if tab.failedURL != nil || scheme == nil || scheme == "about" {
            symbol = nil; help = ""
        } else if tab.isSecure {
            symbol = "lock.fill"; help = L("browser.secure.help")
        } else if scheme == "https" {
            symbol = "lock.trianglebadge.exclamationmark"; help = L("browser.mixed.help")
        } else {
            symbol = "exclamationmark.triangle"; help = L("browser.insecure.help")
        }
        securityIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: help) }
        securityIcon.toolTip = help
        securityIcon.isHidden = symbol == nil
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
                                        accessibilityDescription: bookmarked ? L("browser.unbookmark.help") : L("browser.bookmark.help"))
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

    // MARK: Downloads and proxy

    @objc private func showDownloads(_ sender: NSButton) {
        guard let session else { return }
        if let popover = downloadsPopover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DownloadsView(controller: session.downloads))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        downloadsPopover = popover
    }

    func showDownloadsFromMenu() {
        if let button = downloadsButton { showDownloads(button) }
    }

    private func updateDownloadsButton() {
        guard let session, let button = downloadsButton else { return }
        let active = session.downloads.activeCount > 0
        button.image = NSImage(systemSymbolName: active ? "arrow.down.circle.fill" : "arrow.down.circle",
                               accessibilityDescription: L("browser.downloads.help"))
        button.contentTintColor = active ? .controlAccentColor : nil
    }

    private func updateProxyButton() {
        guard let session else { return }
        let status = session.proxyCenter?.status(for: session.profileID, hasProxy: session.hasProxy)
            ?? (session.hasProxy ? .unchecked : .direct)
        let name = session.configuration.proxy.map(\.displayName) ?? L("proxy.none")
        proxyButton.title = session.hasProxy ? (session.configuration.proxy?.kindLabel ?? "") : L("proxy.none.short")
        proxyButton.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: L(status.labelKey))
        switch status {
        case .working: proxyButton.contentTintColor = .systemGreen
        case .failed: proxyButton.contentTintColor = .systemRed
        case .checking, .unchecked: proxyButton.contentTintColor = .secondaryLabelColor
        case .direct: proxyButton.contentTintColor = .secondaryLabelColor
        }
        var help = "\(name) — \(L(status.labelKey))"
        if case .failed(let message) = status { help += "\n" + L(message.messageKey) }
        if session.hasProxy { help += "\n" + L("proxy.clickToCheck") }
        proxyButton.toolTip = help
    }

    @objc private func proxyButtonClicked() {
        guard let session, let proxy = session.configuration.proxy, let center = session.proxyCenter else { return }
        let id = session.profileID
        Task { await center.check(id, settings: proxy) }
    }

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
                let item = NSMenuItem(title: entry.username.isEmpty ? L("passwords.noUsername") : entry.username,
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
        if !isClosing { session?.windowWillClose(self, state: sessionWindow) }
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
        proxyObservation = nil
        downloadsObservation = nil
        downloadsPopover?.close()
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

// MARK: - Address field and progress line

/// The address bar: selects its whole text when clicked into, like Safari's, so typing replaces
/// the address.
final class AddressField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
        }
        return became
    }
}

/// A thin accent-colored bar under the toolbar showing page load progress.
final class ProgressLine: NSView {
    private var fraction: Double = 0

    override var isFlipped: Bool { true }

    func update(fraction: Double, visible: Bool) {
        let value = visible ? min(max(fraction, 0.05), 1) : 0
        guard value != self.fraction else { return }
        self.fraction = value
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard fraction > 0 else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height).fill()
    }
}

extension ProxySettings {
    /// Short label for the toolbar: "SOCKS5", "HTTP", "HTTPS".
    var kindLabel: String {
        switch kind {
        case .socks5: return "SOCKS5"
        case .httpConnect: return tlsToProxy ? "HTTPS" : "HTTP"
        }
    }
}
