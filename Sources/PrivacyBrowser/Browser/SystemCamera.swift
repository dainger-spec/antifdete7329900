import AppKit
import BrowserCore
import Foundation
import os
import SystemExtensions

/// The app's side of the system virtual camera (the CMIO Camera Extension; docs/CAMERA.md). It
/// installs and switches the extension on through `OSSystemExtensionManager` (as `NetworkGuard`
/// does the content filter), remembers in the shared app group whether it is active so every
/// profile's process can gate the global device (`PrivacyScripts.patchSystemCamera`), and writes
/// the active profile's render settings there for the extension to draw.
///
/// The extension and the app group are present only in a signed build that embedded the extension
/// (`CAM=1 scripts/build-app.sh`); without them this does nothing and `isActive` is false.
@MainActor
final class SystemCamera: NSObject, ObservableObject {
    static let shared = SystemCamera()

    /// Where the installed extension stands.
    enum State: Equatable {
        /// This build did not embed the camera extension.
        case notInBuild
        case notInstalled
        case installing
        case awaitingApproval
        case active
        /// macOS finishes installing it at the next restart.
        case restartNeeded
        case failed(String)
    }

    /// What stopped the last attempt, said in words for the settings page.
    enum Problem: Equatable {
        case reboot
        case location
        case signing
        case authorization
        case policy
        case other(String)
    }

    @Published private(set) var state: State
    @Published private(set) var problem: Problem?

    /// The extension's bundle identifier, from the app's Info.plist (`CAM=1 scripts/build-app.sh`).
    let extensionIdentifier: String?
    /// The shared app group both the app and the extension are entitled to; nil without the extension.
    let appGroup: String?

    private let log = Logger(subsystem: "PrivacyBrowser", category: "SystemCamera")
    private var pendingRequest: OSSystemExtensionRequest?

    /// Info.plist keys `CAM=1 scripts/build-app.sh` writes on the app.
    static let extensionKey = "PBCameraExtensionBundleIdentifier"
    static let appGroupKey = "PBCameraAppGroup"
    /// The flag in the shared defaults a profile's process reads to gate the global device.
    static let activeDefaultsKey = "PBCameraExtensionActive"
    static let configFileName = "camera.json"

    override init() {
        extensionIdentifier = Bundle.main.object(forInfoDictionaryKey: Self.extensionKey) as? String
        appGroup = Bundle.main.object(forInfoDictionaryKey: Self.appGroupKey) as? String
        state = extensionIdentifier == nil ? .notInBuild : .notInstalled
        super.init()
    }

    /// The extension is installed and switched on, as the shared flag records — readable from any
    /// of the profiles' processes (`sharedDefaults`), so each gates the Mac-global device.
    var isActive: Bool {
        guard extensionIdentifier != nil else { return false }
        return Self.sharedDefaults(appGroup)?.bool(forKey: Self.activeDefaultsKey) ?? false
    }

    /// The shared defaults for the app group, or nil without one.
    static func sharedDefaults(_ appGroup: String?) -> UserDefaults? {
        guard let appGroup else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    /// Asks macOS to install the extension (its prompt, then a switch in System Settings).
    func install() {
        guard let identifier = extensionIdentifier else { return }
        problem = nil
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Switches the extension off and forgets it.
    func deactivate() {
        guard let identifier = extensionIdentifier else { return }
        problem = nil
        setActiveFlag(false)
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
        state = .notInstalled
    }

    func openSystemSettings() {
        SystemOpen.openSystemSettingsForExtensions()
    }

    /// Writes what the extension should draw for `camera` to the shared app group. The device is
    /// one and global, so the last profile to launch with the system camera sets what it shows.
    func writeRenderConfig(for camera: CameraSubstitution) {
        guard let appGroup,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let url = container.appendingPathComponent(Self.configFileName)
        do {
            let data = try JSONEncoder().encode(camera.systemCameraRender())
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("could not write the camera config: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func setActiveFlag(_ active: Bool) {
        Self.sharedDefaults(appGroup)?.set(active, forKey: Self.activeDefaultsKey)
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension SystemCamera: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // The app's own extension replaces an older copy (an update): allowed once, for this team.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { state = .awaitingApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            pendingRequest = nil
            switch result {
            case .completed:
                setActiveFlag(true)
                state = .active
            case .willCompleteAfterReboot:
                problem = .reboot
                state = .restartNeeded
            @unknown default:
                state = .failed("\(result.rawValue)")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            pendingRequest = nil
            log.error("camera extension request failed: \(error.localizedDescription, privacy: .private)")
            switch (error as? OSSystemExtensionError)?.code {
            case .requestCanceled?: break
            case .unsupportedParentBundleLocation?: problem = .location
            case .missingEntitlement?, .codeSignatureInvalid?, .validationFailed?, .extensionNotFound?, .extensionMissingIdentifier?:
                problem = .signing
            case .authorizationRequired?: problem = .authorization
            case .forbiddenBySystemPolicy?: problem = .policy
            default: problem = .other(error.localizedDescription)
            }
            state = .notInstalled
        }
    }
}
