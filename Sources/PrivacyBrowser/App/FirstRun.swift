import BrowserCore
import Darwin
import Foundation

/// The first run's steps after the vault is made (the owner, 17 November: on a fresh Mac nothing
/// asked to set up Touch ID, the network guard or the virtual camera; the guard's notice came only
/// once a profile with a SOCKS5 proxy existed). After the account and the master password:
///
/// 1. «Входить по Touch ID?» — on a Mac with Touch ID, where this build can keep the key, once;
/// 2. «Настройка защиты» — the network guard (WebRTC through the proxy) and, where the plan has
///    the camera, the virtual camera; each with its install and a mark that turns green.
///
/// Each is shown once per Mac (this Mac's preferences), and both are in Settings later. Inside a
/// virtual machine, where macOS does not install system extensions, the setup says so once and the
/// Profiles window does not remind.
enum FirstRunStep: String, Equatable {
    case touchID
    case protection
}

/// What turning Touch ID on at the first run came to.
enum FirstRunTouchIDOutcome: Equatable {
    case on
    case cancelled
    case failed(String)
}

enum FirstRun {
    enum Keys {
        static let touchIDOffered = "firstRun.touchIDOffered"
        static let protectionShown = "firstRun.protectionShown"
    }

    /// This Mac is a virtual machine (`kern.hv_vmm_present`): macOS there does not install system
    /// extensions, so neither the guard nor the camera is offered as something to do.
    static let isVirtualMachine: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }()

    /// The network guard is in this build: there is something to install.
    @MainActor static var guardInBuild: Bool { NetworkGuard.shared.extensionIdentifier != nil }

    /// The virtual camera is in this build.
    @MainActor static var cameraInBuild: Bool { SystemCamera.shared.extensionIdentifier != nil }

    /// The steps this first run shows, each once per Mac.
    @MainActor static func steps(defaults: UserDefaults = .standard) -> [FirstRunStep] {
        var steps: [FirstRunStep] = []
        if TouchIDUnlock.isOfferedHere, !defaults.bool(forKey: Keys.touchIDOffered) { steps.append(.touchID) }
        if guardInBuild || cameraInBuild, !defaults.bool(forKey: Keys.protectionShown) { steps.append(.protection) }
        return steps
    }

    /// The step was shown: not again on this Mac.
    static func shown(_ step: FirstRunStep, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: step == .touchID ? Keys.touchIDOffered : Keys.protectionShown)
    }
}

extension AppModel {
    /// After the vault is made (or brought from its sync location): the first run's steps.
    func planFirstRun() {
        firstRunSteps = FirstRun.steps()
        if let first = firstRunSteps.first { FirstRun.shown(first) }
    }

    /// The step shown is done: the next one, or the profiles.
    func finishFirstRunStep() {
        guard !firstRunSteps.isEmpty else { return }
        firstRunSteps.removeFirst()
        if let next = firstRunSteps.first { FirstRun.shown(next) }
    }

    /// The Profiles window's calm reminder at its foot while the network guard is missing — also
    /// with no profile yet, not only once a profile with a SOCKS5 proxy wants it; never inside a
    /// virtual machine, where it cannot be installed. Closed, it comes back at the next start.
    var guardReminderWanted: Bool {
        !FirstRun.isVirtualMachine
    }
}
