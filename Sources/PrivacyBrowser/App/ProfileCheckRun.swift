import BrowserCore
import Foundation

/// A profile's check, run (`ProfileCheck` judges; this gathers): the profile's own page says what
/// it sees (`WhatSitesSee`, a page of this Mac); a lookup through the profile's proxy — the one a
/// launch makes anyway, with nothing of the profile in it — says where it leaves for the
/// internet; the profile's process says where its web views' traffic goes. Then the findings, and
/// for each fix the settings changed, to be taken at the profile's next start.
@MainActor
final class ProfileCheckRun: ObservableObject {
    enum Step: Equatable {
        case ready, page, exit, network, done
        case failed(String)
    }

    @Published private(set) var step: Step = .ready
    @Published private(set) var findings: [ProfileCheck.Finding] = []
    @Published private(set) var checkedAt: Date?
    /// Fixes made since the last check: their settings are saved, the running profile has the old ones.
    @Published private(set) var fixesMade: Set<ProfileCheck.Fix> = []
    @Published var fixError: String?

    /// What a check needs of the app around it: the profile's settings, read and changed; the
    /// manager that runs it; a way to stop it.
    struct Environment {
        var configuration: () throws -> ProfileConfiguration
        var applyFix: (ProfileCheck.Fix, ProfileCheck.Coordinate?) throws -> Void
        var manager: () -> ProfileManager?
        var stop: () async -> Void
    }

    let profileID: UUID
    let snapshot: WhatSitesSee
    private let environment: () -> Environment?
    /// Where the profile left for the internet at the last check: what "at the exit" fixes move to.
    private var exitCoordinate: ProfileCheck.Coordinate?

    init(profileID: UUID, snapshot: WhatSitesSee, environment: @escaping () -> Environment?) {
        self.profileID = profileID
        self.snapshot = snapshot
        self.environment = environment
    }

    /// In the app: the profile `profileID` of `model`'s vault.
    convenience init(profileID: UUID, snapshot: WhatSitesSee, model: @escaping () -> AppModel?) {
        self.init(profileID: profileID, snapshot: snapshot) {
            guard let model = model() else { return nil }
            return Environment(configuration: { try model.configuration(for: profileID) },
                               applyFix: { fix, exit in try model.applyCheckFix(fix, to: profileID, exit: exit) },
                               manager: { model.manager },
                               stop: { await model.stop(profileID) })
        }
    }

    var isRunning: Bool {
        switch step {
        case .page, .exit, .network: return true
        case .ready, .done, .failed: return false
        }
    }

    /// How many findings a site can hold against the profile.
    var attention: Int { ProfileCheck.attention(in: findings) }

    func run() async {
        guard !isRunning, let environment = environment() else { return }
        findings = []
        fixError = nil
        step = .page
        await snapshot.take()
        guard let values = snapshot.profileSnapshot?.values else {
            if case let .failed(reason) = snapshot.step { step = .failed(reason) } else { step = .failed(L("whatSites.error.profileSilent")) }
            return
        }
        guard let configuration = try? environment.configuration() else {
            step = .failed(L("check.error.settings"))
            return
        }
        var facts = ProfileCheck.Facts(configuration: configuration, hostSafariVersion: HostSafari.version,
                                       webRTC: Self.webRTC(configuration, guardReady: NetworkGuard.shared.state == .ready))
        facts.isMobileView = configuration.deviceGeneration.platform != .macOS
        facts.page = ProfileCheck.Page(snapshot: values)

        step = .exit
        let lookup = await ProxyGeoLookup.lookUp(proxy: configuration.proxy,
                                                 userAgent: configuration.userAgent(hostSafariVersion: HostSafari.version))
        facts.exit = lookup.location
        facts.lookupAnswered = lookup.answered
        facts.proxyNeedsCredentials = lookup.proxyRequiresCredentials
        if let latitude = lookup.details.latitude, let longitude = lookup.details.longitude {
            facts.exitCoordinate = ProfileCheck.Coordinate(latitude: latitude, longitude: longitude)
        }
        exitCoordinate = facts.exitCoordinate

        step = .network
        if let report = await environment.manager()?.networkReport(of: profileID) {
            facts.network = ProfileCheck.Network(webViewsOffProfile: report.webViewsOffProfile, webViewsWithWebRTC: report.webViewsWithWebRTC,
                                                 webViewsWithDNSPrefetch: report.webViewsWithDNSPrefetch, udpClosed: report.udpClosed)
        }
        show(ProfileCheck.findings(facts), at: Date())
    }

    /// A finished check's findings (the UI snapshots show one of sample values).
    func show(_ findings: [ProfileCheck.Finding], at date: Date, fixesMade: Set<ProfileCheck.Fix> = []) {
        self.findings = findings
        self.fixesMade = fixesMade
        checkedAt = date
        step = .done
    }

    /// The fix made: the profile's settings changed. The running profile keeps what it started
    /// with; "Restart and check again" shows the result.
    func fix(_ fix: ProfileCheck.Fix) {
        guard let environment = environment() else { return }
        do {
            try environment.applyFix(fix, exitCoordinate)
            fixesMade.insert(fix)
            fixError = nil
        } catch {
            fixError = error.localizedDescription
        }
    }

    /// The profile stopped and started again — with the settings the fixes saved — and checked anew.
    func restartAndRun() async {
        guard !isRunning, let environment = environment() else { return }
        step = .page
        if environment.manager()?.isRunning(profileID) == true { await environment.stop() }
        step = .ready
        await run()
    }

    /// How a launch of `configuration` does WebRTC, as the inspector says it: off; through the
    /// proxy (SOCKS5, the network guard holding the profile's process); or, with no proxy, direct.
    static func webRTC(_ configuration: ProfileConfiguration, guardReady: Bool) -> ProfileCheck.WebRTC {
        guard configuration.webRTCPolicy != .disabled else { return .off }
        guard let proxy = configuration.proxy else { return .direct }
        return proxy.kind == .socks5 && guardReady ? .throughProxy : .off
    }
}
