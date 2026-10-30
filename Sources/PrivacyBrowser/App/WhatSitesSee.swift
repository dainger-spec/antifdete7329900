import AppKit
import BrowserCore
import Foundation

/// "What sites see" for one profile (its ⋯ menu, the command palette): a snapshot of what a page
/// measures in a window of the profile, next to what it measures in this Mac's Safari.
///
/// On the button: the profile starts if it is stopped; a listener of this Mac (`SiteSnapshotServer`,
/// 127.0.0.1 only, while the snapshot is taken) serves one page; the page opens in a new window of
/// the profile, then in Safari, and in each runs the scripts CI's live comparison runs — the
/// fingerprint probe, the window's geometry, the request headers in their order, the APIs — makes
/// an https request whose ClientHello the listener reads, and posts its report back to the
/// listener. Nothing goes anywhere else: the page, its scripts, its requests and its report stay
/// on this Mac. The two reports are compared signal by signal (`SiteComparison`).
@MainActor
final class WhatSitesSee: ObservableObject {
    enum Step: Equatable {
        case ready, starting, measuringProfile, measuringSafari, done
        case failed(String)
    }

    @Published private(set) var step: Step = .ready
    @Published private(set) var signals: [SiteSignal] = []
    /// Safari answered: without it the list is the profile's alone.
    @Published private(set) var comparedWithSafari = false
    @Published private(set) var takenAt: Date?

    let profileID: UUID
    private let manager: () -> ProfileManager?
    private let launch: (UUID) async -> Void
    /// Opens the page in this Mac's Safari; the self-test's stands in for it.
    var openInSafari: @MainActor (URL) async -> Bool = { url in await WhatSitesSee.openInThisMacsSafari(url) }
    var profileTimeout: TimeInterval = 60
    var safariTimeout: TimeInterval = 90
    /// The profile's own snapshot of the last run (the self-test reads it).
    private(set) var profileSnapshot: SiteSnapshot?

    init(profileID: UUID, manager: @escaping () -> ProfileManager?, launch: @escaping (UUID) async -> Void) {
        self.profileID = profileID
        self.manager = manager
        self.launch = launch
    }

    var isTaking: Bool {
        switch step {
        case .starting, .measuringProfile, .measuringSafari: return true
        case .ready, .done, .failed: return false
        }
    }

    func take() async {
        guard !isTaking else { return }
        signals = []
        comparedWithSafari = false
        profileSnapshot = nil
        guard let scripts = Self.scripts() else {
            step = .failed(L("whatSites.error.scripts"))
            return
        }
        if manager()?.isRunning(profileID) != true {
            step = .starting
            await launch(profileID)
        }
        guard let manager = manager(), manager.isRunning(profileID) else {
            step = .failed(L("whatSites.error.notStarted"))
            return
        }
        let server = SiteSnapshotServer { token, tlsPort in
            SiteSnapshotPage.html(scripts: scripts, tlsPort: tlsPort, token: token, title: L("whatSites.page.title"),
                                  measuring: L("whatSites.page.measuring"), done: L("whatSites.page.done"))
        }
        guard await server.start() else {
            step = .failed(L("whatSites.error.listen"))
            return
        }
        defer { server.stop() }

        step = .measuringProfile
        let profilePage = server.newPage(.profile)
        manager.openWindow(profileID, url: profilePage.url)
        guard let measured = await server.measured(profilePage.token, timeout: profileTimeout),
              let profile = try? SiteSnapshot(report: measured.report, clientHello: measured.clientHello) else {
            step = .failed(L("whatSites.error.profileSilent"))
            return
        }
        profileSnapshot = profile
        closeMeasuringWindows(manager)

        step = .measuringSafari
        let safariPage = server.newPage(.safari)
        var safari: SiteSnapshot?
        if await openInSafari(safariPage.url), let measured = await server.measured(safariPage.token, timeout: safariTimeout) {
            safari = try? SiteSnapshot(report: measured.report, clientHello: measured.clientHello)
        }
        NSApp.activate(ignoringOtherApps: true)
        show(SiteComparison.compare(profile: profile, safari: safari), comparedWithSafari: safari != nil, takenAt: Date())
    }

    /// A finished snapshot's list (the UI snapshots show one of sample values).
    func show(_ signals: [SiteSignal], comparedWithSafari: Bool, takenAt: Date) {
        self.signals = signals
        self.comparedWithSafari = comparedWithSafari
        self.takenAt = takenAt
        step = .done
    }

    /// The measuring page's window, in a profile of this process. One in Safari's own window (a
    /// profile's process) is left to the user: the page says it is done.
    private func closeMeasuringWindows(_ manager: ProfileManager) {
        guard let session = manager.session(for: profileID) else { return }
        for controller in session.windowControllers
        where controller.tabs.contains(where: { $0.url.map(SiteSnapshotPage.isMeasuringPage) == true }) {
            controller.close()
        }
    }

    /// The probe and the local pages' scripts from the app's resources: the files CI's live
    /// comparison runs (Resources/fingerprint_probe.js, Resources/SiteProbes).
    static func scripts() -> [String: String]? {
        func read(_ url: URL?) -> String? { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        guard let probe = read(Bundle.main.url(forResource: "fingerprint_probe", withExtension: "js")) else { return nil }
        var scripts = ["probe": probe]
        for name in ["geometry", "apis", "headers"] {
            guard let text = read(Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "SiteProbes")) else { return nil }
            scripts[name] = text
        }
        return scripts
    }

    /// This Mac's Safari, asked to open the page (a new tab of its own).
    static func openInThisMacsSafari(_ url: URL) async -> Bool {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return false }
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }
}
