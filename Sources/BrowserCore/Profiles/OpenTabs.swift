import Foundation

/// The tabs a profile had open when it last stopped, window by window, for its next start to open
/// again (the app's Settings → Startup → restore tabs).
///
/// This Mac's only — never synced, never exported — and encrypted with the profile's key
/// (`tabs.bin`, `ProfileRepository.saveOpenTabs`). Only web addresses are kept (http and https),
/// and only so many: what was open, nothing of the pages themselves.
public struct OpenTabs: Codable, Equatable, Sendable {
    /// At most this many windows, and tabs in each.
    public static let maximumWindows = 20
    public static let maximumTabs = 100

    public struct Window: Codable, Equatable, Sendable {
        public var tabs: [URL]
        /// The tab that was shown, an index into `tabs`.
        public var selected: Int

        public init(tabs: [URL], selected: Int = 0) {
            self.tabs = tabs
            self.selected = selected
        }
    }

    var format = 1
    public private(set) var windows: [Window]
    public var savedAt: Date

    /// Keeps of `windows` what can be opened again: http and https addresses, at most
    /// `maximumTabs` per window and `maximumWindows` windows; a window left with no tab is dropped,
    /// and the selected tab is the one shown, or the first.
    public init(windows: [Window], savedAt: Date = Date()) {
        self.savedAt = savedAt
        self.windows = windows.prefix(Self.maximumWindows).compactMap { window in
            var kept: [URL] = []
            var selected = 0
            for (index, url) in window.tabs.enumerated() where Self.isRestorable(url) && kept.count < Self.maximumTabs {
                if index == window.selected { selected = kept.count }
                kept.append(url)
            }
            return kept.isEmpty ? nil : Window(tabs: kept, selected: selected)
        }
    }

    /// An address a start can open again: a web page, not a file, a script or an internal page.
    public static func isRestorable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case format, windows, savedAt
    }

    /// What was stored is filtered again: a file is never trusted to hold only what this build
    /// would have written.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let windows = try c.decodeIfPresent([Window].self, forKey: .windows) ?? []
        self.init(windows: windows, savedAt: try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0))
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
    }
}

/// One tab as a browser window's chrome names it — which window it is in, the page it shows and
/// whether it is the one in front — for `OpenTabs.windows(of:)`. Safari's window, hosted in a
/// profile's process, hands its tabs out as one list for every window; our own windows know theirs.
public struct ObservedTab: Equatable, Sendable {
    /// The window the tab is in: any number that the tabs of one window share.
    public var window: Int
    /// The tab's page; nil for a tab without one (the start page, an empty tab).
    public var url: URL?
    public var isSelected: Bool

    public init(window: Int, url: URL?, isSelected: Bool = false) {
        self.window = window
        self.url = url
        self.isSelected = isSelected
    }
}

extension OpenTabs {
    /// What stands for a tab without a page while a window is put together: never kept (`init`).
    static let noPage = URL(string: "about:blank")!

    /// `tabs` window by window: the windows in the order their first tab comes, each with its tabs
    /// in the order given and the one shown. A tab without a page keeps its place until the pages
    /// are filtered (`init(windows:)`), so the tab shown stays the right one.
    public static func windows(of tabs: [ObservedTab]) -> [Window] {
        var order: [Int] = []
        var byWindow: [Int: Window] = [:]
        for tab in tabs {
            var window = byWindow[tab.window] ?? Window(tabs: [])
            if byWindow[tab.window] == nil { order.append(tab.window) }
            if tab.isSelected { window.selected = window.tabs.count }
            window.tabs.append(tab.url ?? noPage)
            byWindow[tab.window] = window
        }
        return order.compactMap { byWindow[$0] }
    }

    /// How a window whose tab `current` is shown gets to tab `wanted` with the two commands every
    /// browser has — next tab and previous tab, which go round — in the fewest presses: how many,
    /// and whether they are "next". Nothing to press for one tab, the tab already shown, or an
    /// index the window does not have.
    public static func selectionSteps(from current: Int, to wanted: Int, count: Int) -> (presses: Int, forward: Bool) {
        guard count > 1, (0..<count).contains(current), (0..<count).contains(wanted), current != wanted else { return (0, true) }
        let forward = (wanted - current + count) % count
        let backward = count - forward
        return forward <= backward ? (forward, true) : (backward, false)
    }
}
