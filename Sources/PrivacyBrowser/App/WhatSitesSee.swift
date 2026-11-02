import AppKit
import BrowserCore
import Foundation

/// "What sites see" for one profile (its ⋯ menu, the command palette): a snapshot of what a page
/// measures in a window of the profile — and, only when the person asks for it, next to what the
/// same page measures in this Mac's own Safari.
///
/// On "Take": the profile starts if it is stopped; a listener of this Mac (`SiteSnapshotServer`,
/// 127.0.0.1 only, while the snapshot is taken) serves one page; the page opens in a new window of
/// the profile and runs the scripts CI's live comparison runs — the fingerprint probe, the
/// window's geometry, the request headers in their order, the APIs — makes an https request whose
/// ClientHello the listener reads, and posts its report back to the listener. Nothing goes
/// anywhere else: the page, its scripts, its requests and its report stay on this Mac.
///
/// On "Compare with Safari", and only then: the same page in a window of this Mac's own Safari —
/// not a profile — through the app's one place for what it hands the system (`SystemOpen`); the
/// two reports are compared signal by signal (`SiteComparison`). Up to 1 November Safari was
/// opened by itself on every snapshot (the owner's finding): the person had not asked for a window
/// of their own browser, outside every profile.
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
    /// What the profile was launched to show sites (its time zone, its first language), from the
    /// manager: an identity signal that is not this is worth a look, not "as it should be".
    @Published private(set) var expected: ExpectedIdentity?
    /// The country the profile takes its place from (its proxy's), for "as it should be"'s why.
    @Published private(set) var countryCode: String?

    let profileID: UUID
    private let manager: () -> ProfileManager?
    private let launch: (UUID) async -> Void
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
        safariDidNotAnswer = false
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
        let identity = manager.launchedIdentities[profileID]
        show(SiteComparison.compare(profile: profile, safari: nil), comparedWithSafari: false, takenAt: Date(),
             expected: identity?.expected, countryCode: identity?.countryCode)
    }

    /// The person's "Compare with Safari": the same page in a window of this Mac's own Safari, its
    /// report next to the profile's last one. Nothing else opens Safari.
    func compareWithSafari() async {
        guard !isTaking, let profile = profileSnapshot else { return }
        guard let scripts = Self.scripts() else {
            step = .failed(L("whatSites.error.scripts"))
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
        step = .measuringSafari
        let safariPage = server.newPage(.safari)
        var safari: SiteSnapshot?
        if await SystemOpen.openInThisMacsSafari(safariPage.url),
           let measured = await server.measured(safariPage.token, timeout: safariTimeout) {
            safari = try? SiteSnapshot(report: measured.report, clientHello: measured.clientHello)
        }
        NSApp.activate(ignoringOtherApps: true)
        safariDidNotAnswer = safari == nil
        show(SiteComparison.compare(profile: profile, safari: safari), comparedWithSafari: safari != nil, takenAt: takenAt ?? Date(),
             expected: expected, countryCode: countryCode)
    }

    /// The last "Compare with Safari" got nothing back from Safari.
    @Published private(set) var safariDidNotAnswer = false

    /// A finished snapshot's list (the UI snapshots show one of sample values).
    func show(_ signals: [SiteSignal], comparedWithSafari: Bool, takenAt: Date,
              expected: ExpectedIdentity? = nil, countryCode: String? = nil) {
        self.signals = signals
        self.comparedWithSafari = comparedWithSafari
        self.takenAt = takenAt
        self.expected = expected
        self.countryCode = countryCode
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

}
