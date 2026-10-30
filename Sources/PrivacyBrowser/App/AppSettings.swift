import AppKit
import Foundation

/// What the app's settings say about browsing in every profile — the part a profile's own process
/// needs as well, which the manager sends it over its channel (`ProfileCommand.preferences`) when
/// it starts and whenever the settings change.
///
/// These apply to the app's own browser windows. A profile that shows Safari's own window (a build
/// without the App Sandbox) browses by Safari's settings, in its window's Safari menu.
struct BrowsingPreferences: Codable, Equatable {
    /// Saved passwords are offered (and new ones asked about) at all; a profile has its own switch
    /// as well, and both must be on.
    var passwordAutoFill = true
    /// A new tab opens next to the current one; otherwise after the last.
    var newTabsNextToCurrent = true
    /// Closing a window with more than one tab asks first.
    var warnClosingTabs = true
    /// The zoom of a new tab's pages, 1 = 100 %.
    var pageZoom: Double = 1
    /// Where downloads go; nil: the Downloads folder.
    var downloadFolder: String?
    /// Each download asks where to save it.
    var askWhereToSave = false
    /// How many letters of a profile's name its Dock icon shows, when it runs in a process of its
    /// own; 0: the app's icon as it is.
    var dockInitials = 2

    static let zoomChoices: [Double] = [0.75, 0.85, 0.9, 1, 1.1, 1.15, 1.25, 1.5, 1.75, 2]

    /// What this process's browser windows go by: the app's settings in the manager, what the
    /// manager last sent in a profile's own process.
    @MainActor static var current = BrowsingPreferences()

    /// Where downloads go: the folder chosen, or the Downloads folder.
    var downloadFolderURL: URL {
        downloadFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// As a profile's own process gets them: with the download folder written out, since that
    /// process's home is the profile's own and its Downloads folder would be inside it.
    var forProfileProcess: BrowsingPreferences {
        var sent = self
        sent.downloadFolder = downloadFolderURL.path
        return sent
    }
}

/// The app's own settings (Settings…, ⌘,): how it starts and quits, what a new profile starts
/// with, how browsing behaves (`BrowsingPreferences`), what a proxy that does not work does.
///
/// This Mac's, kept in the app's defaults rather than the vault: they are read before the vault is
/// unlocked, and nothing in them is secret (a download folder is kept as its path, and in the App
/// Sandbox as a bookmark to it). Each one is its own key, read on its own: a build that does not
/// know a key ignores it, and one that finds none takes the default.
@MainActor
final class AppSettings: ObservableObject {
    /// What follows an unlock.
    enum Startup: String, CaseIterable, Identifiable {
        /// The Profiles window, and nothing started.
        case profilesWindow
        /// The profiles that ran when the app was last quit start again.
        case reopenProfiles
        var id: String { rawValue }
    }

    /// What starting a profile whose proxy does not work does.
    enum ProxyFailure: String, CaseIterable, Identifiable {
        /// It starts; its pages load nothing (never around the proxy) and the Profiles window says why.
        case launchAndExplain
        /// It is not started: the proxy is asked first, and the Profiles window says why.
        case doNotLaunch
        var id: String { rawValue }
    }

    private enum Key {
        static let startup = "PBSettingsStartup"
        static let confirmQuit = "PBSettingsConfirmQuit"
        static let newProfileMatchesConnection = "PBSettingsNewProfileMatchesConnection"
        static let proxyFailure = "PBSettingsProxyFailure"
        static let passwordAutoFill = "PBSettingsPasswordAutoFill"
        static let newTabsNextToCurrent = "PBSettingsNewTabsNextToCurrent"
        static let warnClosingTabs = "PBSettingsWarnClosingTabs"
        static let pageZoom = "PBSettingsPageZoom"
        static let downloadFolder = "PBSettingsDownloadFolder"
        static let downloadFolderBookmark = "PBSettingsDownloadFolderBookmark"
        static let askWhereToSave = "PBSettingsAskWhereToSave"
        static let dockInitials = "PBSettingsDockInitials"
        /// `ProfileProcess.isEnabled` reads it: the switch was there before the settings window.
        static let profileProcess = "PBProfileProcess"
    }

    @Published var startup: Startup {
        didSet { defaults.set(startup.rawValue, forKey: Key.startup) }
    }
    @Published var confirmQuit: Bool {
        didSet { defaults.set(confirmQuit, forKey: Key.confirmQuit) }
    }
    /// A new profile takes its time zone and its languages from where its connection comes out.
    @Published var newProfileMatchesConnection: Bool {
        didSet { defaults.set(newProfileMatchesConnection, forKey: Key.newProfileMatchesConnection) }
    }
    @Published var proxyFailure: ProxyFailure {
        didSet { defaults.set(proxyFailure.rawValue, forKey: Key.proxyFailure) }
    }
    @Published var browsing: BrowsingPreferences {
        didSet {
            guard browsing != oldValue else { return }
            store(browsing)
            BrowsingPreferences.current = browsing
            onBrowsingChange?(browsing)
        }
    }

    /// The running profiles in processes of their own get the new preferences (`AppModel`).
    var onBrowsingChange: ((BrowsingPreferences) -> Void)?

    private let defaults: UserDefaults
    /// The chosen download folder, while it is in use: in the App Sandbox it is reached through the
    /// bookmark the folder panel's choice gave.
    private var downloadFolderAccess: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startup = defaults.string(forKey: Key.startup).flatMap(Startup.init) ?? .profilesWindow
        confirmQuit = defaults.object(forKey: Key.confirmQuit) as? Bool ?? true
        newProfileMatchesConnection = defaults.object(forKey: Key.newProfileMatchesConnection) as? Bool ?? true
        proxyFailure = defaults.string(forKey: Key.proxyFailure).flatMap(ProxyFailure.init) ?? .launchAndExplain
        var browsing = BrowsingPreferences()
        browsing.passwordAutoFill = defaults.object(forKey: Key.passwordAutoFill) as? Bool ?? true
        browsing.newTabsNextToCurrent = defaults.object(forKey: Key.newTabsNextToCurrent) as? Bool ?? true
        browsing.warnClosingTabs = defaults.object(forKey: Key.warnClosingTabs) as? Bool ?? true
        if let zoom = defaults.object(forKey: Key.pageZoom) as? Double, BrowsingPreferences.zoomChoices.contains(zoom) {
            browsing.pageZoom = zoom
        }
        browsing.downloadFolder = defaults.string(forKey: Key.downloadFolder)
        browsing.askWhereToSave = defaults.object(forKey: Key.askWhereToSave) as? Bool ?? false
        if let initials = defaults.object(forKey: Key.dockInitials) as? Int, (0...3).contains(initials) {
            browsing.dockInitials = initials
        }
        self.browsing = browsing
        BrowsingPreferences.current = browsing
        openDownloadFolder()
    }

    private func store(_ browsing: BrowsingPreferences) {
        defaults.set(browsing.passwordAutoFill, forKey: Key.passwordAutoFill)
        defaults.set(browsing.newTabsNextToCurrent, forKey: Key.newTabsNextToCurrent)
        defaults.set(browsing.warnClosingTabs, forKey: Key.warnClosingTabs)
        defaults.set(browsing.pageZoom, forKey: Key.pageZoom)
        defaults.set(browsing.askWhereToSave, forKey: Key.askWhereToSave)
        defaults.set(browsing.dockInitials, forKey: Key.dockInitials)
        if let folder = browsing.downloadFolder {
            defaults.set(folder, forKey: Key.downloadFolder)
        } else {
            defaults.removeObject(forKey: Key.downloadFolder)
            defaults.removeObject(forKey: Key.downloadFolderBookmark)
        }
    }

    // MARK: Profiles in processes of their own

    /// Profiles run in processes of their own — each its own app in the Dock, and Safari's own
    /// window where the build can host it — rather than all in this one (`ProfileProcess`).
    var profilesInOwnProcesses: Bool {
        get { ProfileProcess.isEnabled }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.profileProcess)
        }
    }

    /// The switch is offered where a profile's own process is the build's own way of running it:
    /// a build without the App Sandbox. A sandboxed build runs every profile in its own window here.
    static var canChooseProfileProcesses: Bool { !AppEnvironment.isSandboxed }

    // MARK: Downloads

    /// Takes `folder` (from the folder panel) for downloads; nil: back to the Downloads folder.
    func chooseDownloadFolder(_ folder: URL?) {
        downloadFolderAccess?.stopAccessingSecurityScopedResource()
        downloadFolderAccess = nil
        guard let folder else {
            browsing.downloadFolder = nil
            return
        }
        if AppEnvironment.isSandboxed,
           let bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Key.downloadFolderBookmark)
        }
        browsing.downloadFolder = folder.path
        openDownloadFolder()
    }

    /// In the App Sandbox the chosen folder is reached through its bookmark, opened for as long as
    /// the app runs. A folder that cannot be opened any more (moved, deleted) is forgotten:
    /// downloads go to the Downloads folder again, and the setting says so.
    private func openDownloadFolder() {
        guard AppEnvironment.isSandboxed, browsing.downloadFolder != nil else { return }
        var stale = false
        guard let bookmark = defaults.data(forKey: Key.downloadFolderBookmark),
              let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            browsing.downloadFolder = nil
            return
        }
        downloadFolderAccess = url
        if browsing.downloadFolder != url.path { browsing.downloadFolder = url.path }
    }
}

/// Settings → Startup → reopen: which profiles a quit keeps, and which of them an unlock starts.
enum StartupReopen {
    /// The profiles with a window — not one only warming up, starting or being encrypted.
    static func toRecord(_ activity: [(id: UUID, activity: ProfileManager.Activity)]) -> [UUID] {
        activity.compactMap { item in
            if case .window = item.activity { return item.id }
            return nil
        }
    }

    /// The recorded profiles that still exist, in the order they were recorded, each once.
    static func toLaunch(recorded: [UUID], existing: [UUID]) -> [UUID] {
        let existing = Set(existing)
        var seen = Set<UUID>()
        return recorded.filter { existing.contains($0) && seen.insert($0).inserted }
    }
}
